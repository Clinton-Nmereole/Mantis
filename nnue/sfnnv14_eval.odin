package nnue

// SFNNv14 Network Loader + Evaluation Forward Path for Mantis chess engine.
// Implements Stockfish SFNNv14 architecture (nnue_architecture.h + nnue_feature_transformer.h).

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

// Feature dimensions
THREAT_DIMENSIONS :: 30360      // SFNNv14 initial FullThreats (later doubled to 60720)
PSQ_DIMENSIONS :: 22528
PSQT_COMBINED_SIZE :: (THREAT_DIMENSIONS + PSQ_DIMENSIONS) * PSQT_BUCKETS  // = 423104

// --- Data Types ---

Accumulator :: struct {
	values: [HALF_DIMENSIONS]i16,
}

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
	transformer_weights:    []i16,
	transformer_threat_wts: []i16,
	transformer_psqt:       []i32,
	stacks:                 [LAYER_STACKS]LayerStack,
}

network: SFNNv14Network
initialized: bool = false

// --- Low-Level Helpers ---

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

// --- LEB128 Reading ---

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

// --- Weight Descrambling ---
// Stockfish SIMD-scrambles affine weights via get_weight_index().
// Inverse: file_pos i -> output = (i/4) / (padded/4), input = (i/4) % (padded/4) * 4 + i%4

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

// --- Network Initialization ---

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
	if !read_leb128_into_i16(data, &offset, network.transformer_biases[:]) { fmt.println("FAIL: biases"); return false }

	// 2. Threat weights raw LE i16
	twc := THREAT_DIMENSIONS * HALF_DIMENSIONS
	tw, ok := read_raw_i16_array(data, &offset, twc)
	if !ok { fmt.println("FAIL: threat weights"); return false }
	network.transformer_threat_wts = tw

	// 3. PSQ weights LEB128 i16
	network.transformer_weights = make([]i16, PSQ_DIMENSIONS * HALF_DIMENSIONS)
	if !read_leb128_into_i16(data, &offset, network.transformer_weights) { fmt.println("FAIL: PSQ weights"); return false }

	// 4. PSQT combined LEB128 i32 (threatPsqtWeights + psqtWeights from ONE stream)
	tpsqt := THREAT_DIMENSIONS * PSQT_BUCKETS
	ppsqt := PSQ_DIMENSIONS * PSQT_BUCKETS
	network.transformer_psqt = make([]i32, tpsqt + ppsqt)
	bc := read_leb128_header(data, &offset)
	if bc < 0 { fmt.println("FAIL: PSQT header"); return false }
	end_psqt := offset + bc
	for i in 0 ..< tpsqt { network.transformer_psqt[i] = read_sleb128_i32(data, &offset) }
	for i in 0 ..< ppsqt { network.transformer_psqt[tpsqt + i] = read_sleb128_i32(data, &offset) }
	if offset != end_psqt { offset = end_psqt }  // sync
	fmt.println("  Transformer OK")

	// --- 8 Layer Stacks ---
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

// --- Evaluation Forward Path ---

clipped_relu :: #force_inline proc(x: i32) -> i32 {
	shifted := x >> WEIGHT_SCALE_BITS
	if shifted > QA { return QA }
	if shifted < 0 { return 0 }
	return shifted
}

sqr_clipped_relu :: #force_inline proc(x: i32) -> i32 {
	r := (i64(x) * i64(x)) >> (2 * WEIGHT_SCALE_BITS + 7)
	if r > 127 { return 127 }
	return i32(r)
}

evaluate_sfnnv14 :: proc(white_acc: Accumulator, black_acc: Accumulator, stm: int) -> int {
	if !initialized { return 0 }
	bucket := 0  // TODO: proper bucket selection
	input := white_acc.values
	if stm == 1 { input = black_acc.values }
	s := &network.stacks[bucket]

	// fc_0: sparse 1024 -> 32
	fc0: [FC0_OUTPUTS + 1]i32
	for o in 0..<FC0_OUTPUTS+1 { fc0[o] = s.fc0_biases[o] }
	for j in 0..<HALF_DIMENSIONS {
		v := input[j]; if v < 0 { v = 0 }; if v > QA { v = QA }; if v == 0 { continue }
		for o in 0..<FC0_OUTPUTS+1 { fc0[o] += i32(v) * i32(s.fc0_weights[o][j]) }
	}

	// Dual activation
	sqr: [FC0_OUTPUTS]i32; clip: [FC0_OUTPUTS]i32
	for o in 0..<FC0_OUTPUTS { sqr[o] = sqr_clipped_relu(fc0[o]); clip[o] = clipped_relu(fc0[o]) }

	// Concat [sqr, clip] = 62 -> fc_1
	fc1in: [FC0_OUTPUTS * 2]i32
	for o in 0..<FC0_OUTPUTS { fc1in[o] = sqr[o]; fc1in[FC0_OUTPUTS + o] = clip[o] }

	// fc_1: 62 -> 32
	fc1: [FC1_OUTPUTS]i32
	for o in 0..<FC1_OUTPUTS { fc1[o] = s.fc1_biases[o] }
	for j in 0..<FC0_OUTPUTS*2 { v := fc1in[j]; if v == 0 { continue }; for o in 0..<FC1_OUTPUTS { fc1[o] += v * i32(s.fc1_weights[o][j]) } }
	for o in 0..<FC1_OUTPUTS { fc1[o] = clipped_relu(fc1[o]) }

	// fc_2: 32 -> 1
	out := s.fc2_bias
	for j in 0..<FC1_OUTPUTS { v := fc1[j]; if v == 0 { continue }; out += v * i32(s.fc2_weights[j]) }

	// Forward path: fc0[31] * (600*OUTPUT_SCALE) / (127 * (1<<WEIGHT_SCALE_BITS))
	out += fc0[FC0_OUTPUTS] * (600 * OUTPUT_SCALE) / (127 * (1 << WEIGHT_SCALE_BITS))
	return int(out / OUTPUT_SCALE)
}
