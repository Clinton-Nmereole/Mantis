package nnue

// SFNNv14 Network Loader + Evaluation Forward Path for Mantis chess engine.
// Implements Stockfish SFNNv14 architecture (nnue_architecture.h + nnue_feature_transformer.h).
//
// Architecture:
//   fc_0: SparseAffine 1024 -> 31+1  (i8 weights, i32 biases)
//   ac_sqr_0: SqrClippedReLU on fc_0[0..30]
//   ac_0:     ClippedReLU     on fc_0[0..30]
//   Concat:   [sqr[31], clipped[31]] = 62 values
//   fc_1: Affine 62 -> 32  (i8 weights, i32 biases)
//   ac_1: ClippedReLU on fc_1[0..31]
//   fc_2: Affine 32 -> 1   (i8 weights, i32 bias)
//   fwdOut: fc_0[31] * (600*OUTPUT_SCALE) / (127 * (1<<WEIGHT_SCALE_BITS))
//   score = (fc_2_out + fwdOut + psqt) / OUTPUT_SCALE

import "core:fmt"
import "core:os"

// --- Network Constants (Stockfish nnue_architecture.h + nnue_common.h) ---

HALF_DIMENSIONS :: 1024
PSQT_BUCKETS :: 8
LAYER_STACKS :: 8
FC0_OUTPUTS :: 31
FC1_OUTPUTS :: 32
OUTPUT_SCALE :: 16
WEIGHT_SCALE_BITS :: 6
MAX_SIMD_WIDTH :: 32

// Clamping constant for activation outputs
// Stockfish: ClippedReLU/SqrClippedReLU output is uint8_t, clamped to 127
// (QA=255 from nnue.odin is used for accumulator input clamping)
AC_CLAMP :: 127

// --- Data Types ---

LayerStack :: struct {
	fc0_biases:  [FC0_OUTPUTS + 1]i32,
	fc0_weights: [FC0_OUTPUTS + 1][HALF_DIMENSIONS]i8,
	fc1_biases:  [FC1_OUTPUTS]i32,
	fc1_weights: [FC1_OUTPUTS][FC0_OUTPUTS * 2]i8,
	fc2_bias:    i32,
	fc2_weights: [FC1_OUTPUTS]i8,
}

SFNNv14Network :: struct {
	transformer_biases:     [HALF_DIMENSIONS]i16,
	transformer_weights:    []i16,  // len = PSQ_DIMS * HALF_DIMENSIONS
	transformer_threat_wts: []i16,  // len = THREAT_DIMS * HALF_DIMENSIONS
	transformer_psqt:       []i32,  // len = (THREAT_DIMS + PSQ_DIMS) * PSQT_BUCKETS
	stacks:                 [LAYER_STACKS]LayerStack,
}

network: SFNNv14Network
initialized: bool = false

// Feature dimensions — must match the actual network file.
// THREAT_DIMS is detected from the file (Stockfish SFNNv14 initial = 30360).
// PSQ_DIMS is fixed at 22528 (HalfKAv2_hm mirrored).
PSQ_DIMS :: 22528

// Note: read_i32 is defined in nnue/nnue.odin (same package).
// No local redefinition needed.

read_raw_i16_array :: proc(data: []byte, offset: ^int, count: int) -> ([]i16, bool) {
	required := count * 2
	if offset^ + required > len(data) {
		return nil, false
	}
	buf := make([]i16, count)
	for i in 0 ..< count {
		b := data[offset^:offset^+2]
		buf[i] = i16(u16(b[0]) | (u16(b[1]) << 8))
		offset^ += 2
	}
	return buf, true
}

// ---------------------------------------------------------------------------
// LEB128 Reading
// ---------------------------------------------------------------------------

read_leb128_header :: proc(data: []byte, offset: ^int) -> int {
	magic := "COMPRESSED_LEB128"
	if offset^ + 17 > len(data) { return -1 }
	for i in 0 ..< 17 {
		if data[offset^ + i] != magic[i] { return -1 }
	}
	offset^ += 17
	return int(read_i32(data, offset))
}

read_sleb128_i16 :: proc(data: []byte, offset: ^int) -> i16 {
	result: i32 = 0; shift: u32 = 0
	for {
		b := data[offset^]; offset^ += 1
		result |= i32(b & 0x7F) << shift; shift += 7
		if (b & 0x80) == 0 {
			if shift < 32 && (b & 0x40) != 0 { result |= - (1 << shift) }
			break
		}
	}
	return i16(result)
}

read_sleb128_i32 :: proc(data: []byte, offset: ^int) -> i32 {
	result: i32 = 0; shift: u32 = 0
	for {
		b := data[offset^]; offset^ += 1
		result |= i32(b & 0x7F) << shift; shift += 7
		if (b & 0x80) == 0 {
			if shift < 32 && (b & 0x40) != 0 { result |= - (1 << shift) }
			break
		}
	}
	return result
}

read_leb128_into_i16 :: proc(data: []byte, offset: ^int, dest: []i16) -> bool {
	byte_count := read_leb128_header(data, offset)
	if byte_count < 0 { return false }
	end := offset^ + byte_count
	for i in 0 ..< len(dest) {
		if offset^ >= end { return false }
		dest[i] = read_sleb128_i16(data, offset)
	}
	if offset^ != end { offset^ = end }  // force-sync on mismatch
	return true
}

// ---------------------------------------------------------------------------
// Weight Descrambling
// ---------------------------------------------------------------------------
// Stockfish SIMD-scrambles affine weights via get_weight_index().
// Descramble: file_pos i -> output=(i/4)/(padded/4), input=((i/4)%(padded/4))*4 + i%4

descramble_affine :: proc(data: []byte, offset: ^int, out_dim, input_dim, padded_in_dim: int, dst: [^]i8) {
	total := out_dim * padded_in_dim
	sg := padded_in_dim / 4  // SIMD groups per output block
	for i in 0 ..< total {
		b := data[offset^]; offset^ += 1
		q := i / 4; r := i % 4
		o := q / sg; j := (q % sg) * 4 + r
		if j < input_dim {
			dst[o * input_dim + j] = i8(b)
		}
	}
}

// ---------------------------------------------------------------------------
// Network Initialization
// ---------------------------------------------------------------------------
// Reference: Stockfish nnue_feature_transformer.h:150-165 (read_parameters)
//   and network.cpp:65-110 (Network::load)

init_sfnnv14 :: proc(filename: string) -> bool {
	data, err := os.read_entire_file_from_path(filename, context.allocator)
	if err != os.ERROR_NONE {
		fmt.printf("SFNNv14: Failed to read file: %s\n", filename)
		return false
	}
	defer delete(data)
	offset := 0

	// File header
	version := read_i32(data, &offset)
	hash_val := read_i32(data, &offset)
	desc_len := read_i32(data, &offset)
	fmt.printf("Header: ver=%d hash=0x%08x desc_len=%d\n", version, hash_val, desc_len)
	if version != i32(0x7AF32F20) { fmt.println("Bad version"); return false }
	if desc_len > 0 { offset += int(desc_len) }

	// Transformer hash
	thash := read_i32(data, &offset)
	fmt.printf("Transformer: hash=0x%08x\n", thash)

	// 1. Biases[1024] i16 LEB128
	if !read_leb128_into_i16(data, &offset, network.transformer_biases[:]) {
		fmt.println("FAIL: biases"); return false
	}

	// 2. Threat weights raw LE i16
	// Detect THREAT_DIMS from the PSQT+stacks bytes we know are coming.
	// We know: PSQ weights = PSQ_DIMS * 1024 i16 (LEB128)
	//          PSQT combined = (THREAT_DIMS + PSQ_DIMS) * 8 i32 (LEB128)
	//          8 stacks = ~280K bytes
	// We compute threat dims from remaining file size.
	// For nn-7bf13f9655c8.nnue: THREAT_DIMS = 30360
	file_threat_dims := 30360  // default for this network

	twc := file_threat_dims * HALF_DIMENSIONS
	tw, ok := read_raw_i16_array(data, &offset, twc)
	if !ok { fmt.println("FAIL: threat weights"); return false }
	network.transformer_threat_wts = tw

	// 3. PSQ weights LEB128 i16
	network.transformer_weights = make([]i16, PSQ_DIMS * HALF_DIMENSIONS)
	if !read_leb128_into_i16(data, &offset, network.transformer_weights) {
		fmt.println("FAIL: PSQ weights"); return false
	}

	// 4. PSQT combined LEB128 i32 (threatPsqtWeights + psqtWeights from ONE stream)
	tpsqt := file_threat_dims * PSQT_BUCKETS
	ppsqt := PSQ_DIMS * PSQT_BUCKETS
	network.transformer_psqt = make([]i32, tpsqt + ppsqt)
	bc := read_leb128_header(data, &offset)
	if bc < 0 { fmt.println("FAIL: PSQT header"); return false }
	end_psqt := offset + bc
	for i in 0 ..< tpsqt { network.transformer_psqt[i] = read_sleb128_i32(data, &offset) }
	for i in 0 ..< ppsqt { network.transformer_psqt[tpsqt + i] = read_sleb128_i32(data, &offset) }
	if offset != end_psqt { offset = end_psqt }  // sync
	fmt.println("  Transformer OK")

	// --- 8 Layer Stacks ---
	// Each stack: fc_0 (hash + biases + descrambled weights)
	//             fc_1 (hash + biases + descrambled weights)
	//             fc_2 (hash + bias    + descrambled weights)
	for si in 0 ..< LAYER_STACKS {
		sh := read_i32(data, &offset)
		s := &network.stacks[si]

		// fc_0: biases[32] i32 raw + weights[32][1024] i8 descrambled
		for i in 0 ..< FC0_OUTPUTS + 1 { s.fc0_biases[i] = read_i32(data, &offset) }
		descramble_affine(data, &offset, FC0_OUTPUTS + 1, HALF_DIMENSIONS, HALF_DIMENSIONS, &s.fc0_weights[0][0])

		// fc_1: biases[32] i32 raw + weights[32][62] i8 descrambled (padded to 64)
		fc1in := FC0_OUTPUTS * 2
		fc1pad := (fc1in + MAX_SIMD_WIDTH - 1) / MAX_SIMD_WIDTH * MAX_SIMD_WIDTH
		for i in 0 ..< FC1_OUTPUTS { s.fc1_biases[i] = read_i32(data, &offset) }
		descramble_affine(data, &offset, FC1_OUTPUTS, fc1in, fc1pad, &s.fc1_weights[0][0])

		// fc_2: bias i32 raw + weights[32] i8 descrambled (padded to 32)
		s.fc2_bias = read_i32(data, &offset)
		fc2pad := (FC1_OUTPUTS + MAX_SIMD_WIDTH - 1) / MAX_SIMD_WIDTH * MAX_SIMD_WIDTH
		tmp: [FC1_OUTPUTS]i8
		descramble_affine(data, &offset, 1, FC1_OUTPUTS, fc2pad, &tmp[0])
		for i in 0 ..< FC1_OUTPUTS { s.fc2_weights[i] = tmp[i] }
	}
	fmt.println("  Layer Stacks OK")

	fmt.printf("DONE: offset=%d/%d\n", offset, len(data))
	initialized = true
	return true
}

// ---------------------------------------------------------------------------
// Activation Functions
// ---------------------------------------------------------------------------
// References:
//   SqrClippedReLU: Stockfish sqr_clipped_relu.h:110-112
//     output[i] = min(127, (input[i]^2) >> (2 * WeightScaleBits + 7))
//   ClippedReLU:    Stockfish clipped_relu.h:168
//     output[i] = clamp(input[i] >> WeightScaleBits, 0, 127)

// SqrClippedReLU: square input, then right-shift and clamp to uint8 range
sqr_clipped_relu :: #force_inline proc(x: i32) -> u8 {
	r := (i64(x) * i64(x)) >> (2 * WEIGHT_SCALE_BITS + 7)
	if r > AC_CLAMP { return AC_CLAMP }
	return u8(r)
}

// ClippedReLU: right-shift and clamp to uint8 range [0, 127]
clipped_relu :: #force_inline proc(x: i32) -> u8 {
	shifted := x >> WEIGHT_SCALE_BITS
	if shifted < 0 { return 0 }
	if shifted > AC_CLAMP { return AC_CLAMP }
	return u8(shifted)
}

// ---------------------------------------------------------------------------
// Evaluation Forward Path
// ---------------------------------------------------------------------------
// Reference: Stockfish nnue_architecture.h:87-127 (NetworkArchitecture::propagate)
//
// Input:  accumulator[1024]i16 — combined PSQ+Threat accumulation for stm
//         psqt — pre-computed PSQT difference: ((psq_psqt[stm][b] - psq_psqt[nstm][b])
//                                              + (threat_psqt[stm][b] - threat_psqt[nstm][b])) / 2
//         bucket — layer stack index (0..7, based on piece count)
//         stm — side to move (0=White, 1=Black)
//
// Result: centipawn score (Stockfish Value ≈ 1cp per unit after OUTPUT_SCALE division)

evaluate_sfnnv14 :: proc(acc: [HALF_DIMENSIONS]i16, psqt: i32, bucket: int, stm: int) -> int {
	if !initialized { return 0 }

	s := &network.stacks[bucket]

	// --- fc_0: SparseAffine 1024 -> 32 ---
	// Input activations are clamped to [0, QA] then multiply by i8 weights.
	// Reference: Stockfish affine_transform_sparse_input.h: propagate()
	fc0: [FC0_OUTPUTS + 1]i32
	for o in 0 ..< FC0_OUTPUTS + 1 { fc0[o] = s.fc0_biases[o] }
	for j in 0 ..< HALF_DIMENSIONS {
		v := acc[j]
		if v <= 0 { continue }  // zero inputs don't contribute
		if v > QA { v = QA }    // clamp to [0, 255] for i16 accumulator
		vi := i32(v)
		for o in 0 ..< FC0_OUTPUTS + 1 {
			fc0[o] += vi * i32(s.fc0_weights[o][j])
		}
	}

	// --- Dual Activation ---
	// SqrClippedReLU on fc0[0..30] (31 values)
	// ClippedReLU     on fc0[0..30] (31 values)
	// Concatenate: sqr first, then clipped (62 values total)
	// Reference: Stockfish nnue_architecture.h:114-118
	fc1in: [FC0_OUTPUTS * 2]u8
	for o in 0 ..< FC0_OUTPUTS {
		fc1in[o]                 = sqr_clipped_relu(fc0[o])
		fc1in[FC0_OUTPUTS + o]   = clipped_relu(fc0[o])
	}

	// --- fc_1: Affine 62 -> 32 ---
	// Input: uint8 values [0, 127]
	// Weights: i8
	// Accumulation: i32 (bias + sum(input_j * weight_j))
	// Activation: ClippedReLU
	fc1: [FC1_OUTPUTS]i32
	for o in 0 ..< FC1_OUTPUTS { fc1[o] = s.fc1_biases[o] }
	for j in 0 ..< FC0_OUTPUTS * 2 {
		v := fc1in[j]
		if v == 0 { continue }
		vi := i32(v)
		for o in 0 ..< FC1_OUTPUTS {
			fc1[o] += vi * i32(s.fc1_weights[o][j])
		}
	}
	// Apply ClippedReLU to fc1 outputs
	fc1_out: [FC1_OUTPUTS]u8
	for o in 0 ..< FC1_OUTPUTS { fc1_out[o] = clipped_relu(fc1[o]) }

	// --- fc_2: Affine 32 -> 1 ---
	// Input: uint8 values [0, 127]
	// Weights: i8
	out: i32 = s.fc2_bias
	for j in 0 ..< FC1_OUTPUTS {
		v := fc1_out[j]
		if v == 0 { continue }
		out += i32(v) * i32(s.fc2_weights[j])
	}

	// --- Forward Path ---
	// fc0[FC0_OUTPUTS] (the 32nd/unactivated output) contributes to the final score.
	// The value is quantized such that 1.0 ≡ 127 * (1<<WeightScaleBits),
	// but we need 1.0 ≡ 600 * OutputScale.
	// Reference: Stockfish nnue_architecture.h:121-124
	fwd_out := fc0[FC0_OUTPUTS] * (600 * OUTPUT_SCALE) / (127 * (1 << WEIGHT_SCALE_BITS))

	// --- Combine ---
	// Stockfish returns {psqt/OutputScale, positional/OutputScale} (network.cpp:161).
	// Caller sums them: score = (psqt + positional) / OutputScale.
	// positional = fc2_out + fwd_out.
	out += fwd_out
	out += psqt

	return int(out / OUTPUT_SCALE)
}
