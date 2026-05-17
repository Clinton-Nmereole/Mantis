package nnue

import "../board"
import "../constants"
import "../moves"
import "base:intrinsics"
import "core:fmt"
import "core:os"

// NNUE Constants (HalfKAv2_hm)
// Input: 45056 (HalfKAv2)
// Hidden: 1024 (per perspective accumulator)
INPUT_SIZE :: 45056
HIDDEN_SIZE :: constants.NNUE_HIDDEN_SIZE

// Quantization
QA :: 255
QB :: 64
QO :: 127 // Output quantization

// ---------------------------------------------------------------------------
// Network Weights Structure
// ---------------------------------------------------------------------------

Network :: struct {
	// Feature Transformer (Input -> Hidden)
	feature_weights: [INPUT_SIZE * HIDDEN_SIZE]i16,
	feature_biases:  [HIDDEN_SIZE]i16,

	// Hidden Layers (Hidden -> Output)
	// Layer 1: HIDDEN_SIZE -> 32
	// l1_weights is stored input-major (c*32+r) for compatibility.
	// l1_weights_t is transposed output-major (r*HIDDEN_SIZE+c) for SIMD.
	l1_weights:      [HIDDEN_SIZE * 32]i8,
	l1_weights_t:    [32 * HIDDEN_SIZE]i8,
	l1_biases:       [32]i32,

	// Layer 2: 32 -> 32
	l2_weights:      [32 * 32]i8,
	l2_biases:       [32]i32,

	// Output Layer: 32 -> 1
	output_weights:  [32]i8,
	output_bias:     i32,
}

// Global Network Instance
current_network: Network
is_initialized: bool = false

// SFNNv14 active flag — set when an SFNNv14 network is loaded
sfnnv14_active: bool = false

// Helper to read LEB128
read_uleb128 :: proc(data: []byte, offset: ^int) -> u32 {
	result: u32 = 0
	shift: u32 = 0
	for {
		byte_val := data[offset^]
		offset^ += 1
		result |= u32(byte_val & 0x7F) << shift
		if (byte_val & 0x80) == 0 {
			break
		}
		shift += 7
	}
	return result
}

read_sleb128 :: proc(data: []byte, offset: ^int) -> i32 {
	result: i32 = 0
	shift: u32 = 0
	byte_val: byte
	for {
		byte_val = data[offset^]
		offset^ += 1
		result |= i32(byte_val & 0x7F) << shift
		shift += 7
		if (byte_val & 0x80) == 0 {
			break
		}
	}
	// Sign extension
	if (shift < 32) && ((byte_val & 0x40) != 0) {
		result |= (~i32(0)) << shift
	}
	return result
}

// Helper to read standard types
read_i16 :: proc(data: []byte, offset: ^int) -> i16 {
	b1 := data[offset^]; offset^ += 1
	b2 := data[offset^]; offset^ += 1
	return i16(u16(b1) | (u16(b2) << 8))
}

read_i32 :: proc(data: []byte, offset: ^int) -> i32 {
	b1 := data[offset^]; offset^ += 1
	b2 := data[offset^]; offset^ += 1
	b3 := data[offset^]; offset^ += 1
	b4 := data[offset^]; offset^ += 1
	return i32(u32(b1) | (u32(b2) << 8) | (u32(b3) << 16) | (u32(b4) << 24))
}

read_i8 :: proc(data: []byte, offset: ^int) -> i8 {
	val := (^i8)(&data[offset^])^
	offset^ += 1
	return val
}

// Initialize / Load Network
init_nnue :: proc(filename: string) -> bool {
	handle, err := os.open(filename)
	if err != os.ERROR_NONE {
		return false
	}
	// Get file size
	file_size, _ := os.file_size(handle)
	data, read_err := os.read_entire_file_from_path(filename, context.allocator)
	if read_err != os.ERROR_NONE {
		return false
	}
	// defer delete(data) // Removed for debug

	offset := 0

	// Read Header
	version := read_i32(data, &offset)
	hash := read_i32(data, &offset)
	desc_len := read_i32(data, &offset)

	if desc_len > 0 {
		offset += int(desc_len)
	}

	// Helper to read layer header
	read_layer_header :: proc(data: []byte, offset: ^int) -> (i32, string) {
		l_hash := read_i32(data, offset)
		l_type := ""
		if offset^ + 17 <= len(data) {
			type_str := string(data[offset^:offset^ + 17])
			if type_str == "COMPRESSED_LEB128" {
				l_type = type_str
				offset^ += 17
			}
		}
		if l_type == "" {
			l_type_len := read_i32(data, offset)
			if offset^ + int(l_type_len) <= len(data) {
				l_type_bytes := data[offset^:offset^ + int(l_type_len)]
				l_type = string(l_type_bytes)
				offset^ += int(l_type_len)
			}
		}
		return l_hash, l_type
	}

	// 1. Feature Transformer Biases
	_, l_type := read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		// Read HIDDEN_SIZE biases (1024 for standard networks)
		for i in 0 ..< HIDDEN_SIZE {
			current_network.feature_biases[i] = i16(read_sleb128(data, &offset))
		}
	} else {
		return false
	}

	// 2. Feature Transformer Weights
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		// Read INPUT_SIZE * HIDDEN_SIZE weights
		for i in 0 ..< INPUT_SIZE * HIDDEN_SIZE {
			current_network.feature_weights[i] = i16(read_sleb128(data, &offset))
		}
	} else {
		return false
	}

	// 3. Layer 1 Biases
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		for i in 0 ..< 32 {
			current_network.l1_biases[i] = read_sleb128(data, &offset)
		}
	} else {
		return false
	}

	// 4. Layer 1 Weights
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		for r in 0 ..< 32 {
			for c in 0 ..< HIDDEN_SIZE {
				val := i8(read_sleb128(data, &offset))
				current_network.l1_weights[c * 32 + r] = val
				current_network.l1_weights_t[r * HIDDEN_SIZE + c] = val
			}
		}
	}

	// 5. Layer 2 Biases
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		for i in 0 ..< 32 {
			current_network.l2_biases[i] = read_sleb128(data, &offset)
		}
	}

	// 6. Layer 2 Weights
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		for r in 0 ..< 32 {
			for c in 0 ..< 32 {
				val := i8(read_sleb128(data, &offset))
				current_network.l2_weights[c * 32 + r] = val
			}
		}
	}

	// 7. Output Bias
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		current_network.output_bias = read_sleb128(data, &offset)
	}

	// 8. Output Weights
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		for i in 0 ..< 32 {
			current_network.output_weights[i] = i8(read_sleb128(data, &offset))
		}
	}

	is_initialized = true
	return true
}

// Evaluate using NNUE — dispatches to SFNNv14 or legacy based on active flag
evaluate :: proc(b: ^board.Board) -> int {
	// SFNNv14 path
	if sfnnv14_active {
		acc, psqt, bucket := prepare_sfnnv14_evaluation(b)
		return evaluate_sfnnv14(acc, psqt, bucket, b.side)
	}

	// Legacy path
	if !is_initialized {
		return 0 // Should fallback to HCE
	}

	// Use the incrementally updated accumulators from the board
	white_acc := b.accumulators[constants.WHITE]
	black_acc := b.accumulators[constants.BLACK]

	stm := b.side

	input: [HIDDEN_SIZE]i16
	if stm == constants.WHITE {
		for i in 0 ..< HIDDEN_SIZE { input[i] = white_acc.values[i] }
	} else {
		for i in 0 ..< HIDDEN_SIZE { input[i] = black_acc.values[i] }
	}

	// Layer 1: HIDDEN_SIZE -> 32
	l1_out: [32]i32
	for i in 0 ..< 32 {
		l1_out[i] = current_network.l1_biases[i]
	}

	// Layer 1 forward pass — scalar, cache-friendly with input-major weights.
	for i in 0 ..< HIDDEN_SIZE {
		val := input[i]
		// Activation: Clipped ReLU (0..QA)
		if val < 0 { val = 0 }
		if val > QA { val = QA }

		if val != 0 {
			for j in 0 ..< 32 {
				l1_out[j] += i32(val) * i32(current_network.l1_weights[i * 32 + j])
			}
		}
	}

	// Layer 2: 32 -> 32  (small enough to keep scalar)
	l2_out: [32]i32
	for i in 0 ..< 32 {
		l2_out[i] = current_network.l2_biases[i]
	}

	for i in 0 ..< 32 {
		val := l1_out[i]
		if val < 0 { val = 0 }
		if val > QA { val = QA }

		if val != 0 {
			for j in 0 ..< 32 {
				l2_out[j] += val * i32(current_network.l2_weights[i * 32 + j])
			}
		}
	}

	// Output: 32 -> 1
	output := current_network.output_bias
	for i in 0 ..< 32 {
		val := l2_out[i]
		if val < 0 { val = 0 }
		if val > QO { val = QO }

		output += val * i32(current_network.output_weights[i])
	}

	// Scale to Centipawns
	final_score := int(output / 16)
	return final_score
}

// Compute Accumulator from scratch
compute_accumulator :: proc(b: ^board.Board, side: int) -> board.Accumulator {
	acc: board.Accumulator
	// Init with biases
	acc.values = current_network.feature_biases

	king_sq := board.get_king_square(b, side)

	// Add active features using SIMD vector add
	for sq in 0 ..< 64 {
		piece := get_piece_at(b, sq)
		if piece != -1 && piece != constants.KING && piece != (constants.KING + 6) {
			feature_idx := get_feature_index(king_sq, sq, piece, side)
			weights := current_network.feature_weights[feature_idx * HIDDEN_SIZE : (feature_idx + 1) * HIDDEN_SIZE]

			for i := 0; i < HIDDEN_SIZE; i += 16 {
				acc_vec := (^#simd[16]i16)(&acc.values[i])^
				w_vec   := (^#simd[16]i16)(&weights[i])^
				acc_vec  = intrinsics.simd_add(acc_vec, w_vec)
				(^#simd[16]i16)(&acc.values[i])^ = acc_vec
			}
		}
	}

	return acc
}

// Helper: Get Piece at Square (FAST O(1) using mailbox)
get_piece_at :: proc(b: ^board.Board, sq: int) -> int {
	return int(b.mailbox[sq])
}

// Helper: Get Feature Index
get_feature_index :: proc(king_sq: int, sq: int, piece: int, side: int) -> int {
	k_sq := king_sq
	p_sq := sq
	p_type := piece // 0-11

	if side == constants.BLACK {
		k_sq = k_sq ~ 56 // Flip Rank
		p_sq = p_sq ~ 56 // Flip Rank

		// Flip Colors in Piece Type
		if p_type < 6 { p_type += 6 } else { p_type -= 6 }
	}

	// Map Piece Type to 0-10
	idx := 0
	if p_type < 5 {
		idx = p_type
	} else if p_type > 5 && p_type < 11 {
		idx = p_type - 1
	} else if p_type == 11 {
		idx = 10 // Enemy King
	} else {
		return 0 // Own King (should be skipped by caller) or invalid
	}

	return k_sq * 704 + idx * 64 + p_sq
}

// Update Accumulators Incrementally
update_accumulators :: proc(old_board: ^board.Board, new_board: ^board.Board, move: moves.Move) {
	// Always copy both accumulator types for consistency
	new_board.accumulators = old_board.accumulators
	new_board.sfnnv14_accumulators = old_board.sfnnv14_accumulators

	// SFNNv14 path
	if sfnnv14_active {
		update_sfnnv14_accumulators(old_board, new_board, move)
		return
	}

	// Legacy path
	if !is_initialized { return }

	side := old_board.side
	piece_type := move.piece

	// 1. Check for King Move (Refresh own accumulator)
	if piece_type == constants.KING {
		// Refresh the accumulator for the side that moved the King
		new_board.accumulators[side] = compute_accumulator(new_board, side)

		// For the other side, it's just a piece move (Enemy King moved)
		// If King is not a feature, we don't update for the move itself.
		// But we must handle captures.
	} else {
		// Normal Piece Move: Update both accumulators
		update_single_accumulator(
			&new_board.accumulators[constants.WHITE],
			old_board,
			move,
			constants.WHITE,
		)
		update_single_accumulator(
			&new_board.accumulators[constants.BLACK],
			old_board,
			move,
			constants.BLACK,
		)
	}

	// Handle Captures (Remove captured piece)
	if move.capture {
		captured_piece := get_piece_at(old_board, move.target)

		if captured_piece != -1 {
			if piece_type == constants.KING {
				// If King moved, we already refreshed its accumulator.
				// We only need to update the OTHER side.
				remove_feature(
					&new_board.accumulators[1 - side],
					old_board,
					move.target,
					captured_piece,
					1 - side,
				)
			} else {
				// Normal move: Remove from both
				remove_feature(
					&new_board.accumulators[constants.WHITE],
					old_board,
					move.target,
					captured_piece,
					constants.WHITE,
				)
				remove_feature(
					&new_board.accumulators[constants.BLACK],
					old_board,
					move.target,
					captured_piece,
					constants.BLACK,
				)
			}
		}
	}
}

// Helper: Update single accumulator for a piece move
update_single_accumulator :: proc(
	acc: ^board.Accumulator,
	b: ^board.Board,
	move: moves.Move,
	perspective: int,
) {
	// Moving Piece
	side := b.side
	piece := move.piece
	if side == constants.BLACK {
		piece += 6
	}

	// Remove from Source
	idx_rem := get_feature_index(
		board.get_king_square(b, perspective),
		move.source,
		piece,
		perspective,
	)
	weights_rem := current_network.feature_weights[idx_rem * HIDDEN_SIZE : (idx_rem + 1) * HIDDEN_SIZE]
	for i := 0; i < HIDDEN_SIZE; i += 16 {
		acc_vec := (^#simd[16]i16)(&acc.values[i])^
		w_vec   := (^#simd[16]i16)(&weights_rem[i])^
		acc_vec  = intrinsics.simd_sub(acc_vec, w_vec)
		(^#simd[16]i16)(&acc.values[i])^ = acc_vec
	}

	// Add to Target (Handle Promotion)
	final_piece := piece
	if move.promoted != -1 {
		final_piece = move.promoted
		if side == constants.BLACK {
			final_piece += 6
		}
	}

	idx_add := get_feature_index(
		board.get_king_square(b, perspective),
		move.target,
		final_piece,
		perspective,
	)
	weights_add := current_network.feature_weights[idx_add * HIDDEN_SIZE : (idx_add + 1) * HIDDEN_SIZE]
	for i := 0; i < HIDDEN_SIZE; i += 16 {
		acc_vec := (^#simd[16]i16)(&acc.values[i])^
		w_vec   := (^#simd[16]i16)(&weights_add[i])^
		acc_vec  = intrinsics.simd_add(acc_vec, w_vec)
		(^#simd[16]i16)(&acc.values[i])^ = acc_vec
	}
}

// Helper: Remove feature
remove_feature :: proc(
	acc: ^board.Accumulator,
	b: ^board.Board,
	sq: int,
	piece: int,
	perspective: int,
) {
	idx := get_feature_index(board.get_king_square(b, perspective), sq, piece, perspective)
	weights := current_network.feature_weights[idx * HIDDEN_SIZE : (idx + 1) * HIDDEN_SIZE]
	for i := 0; i < HIDDEN_SIZE; i += 16 {
		acc_vec := (^#simd[16]i16)(&acc.values[i])^
		w_vec   := (^#simd[16]i16)(&weights[i])^
		acc_vec  = intrinsics.simd_sub(acc_vec, w_vec)
		(^#simd[16]i16)(&acc.values[i])^ = acc_vec
	}
}
