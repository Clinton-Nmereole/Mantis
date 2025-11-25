package nnue

import "../board"
import "../constants"
import "../moves"
import "core:fmt"
import "core:os"


// NNUE Constants (HalfKAv2_hm)
// Input: 45056 (HalfKAv2)
// Hidden: 1024 (likely for this file size)
INPUT_SIZE :: 45056
HIDDEN_SIZE :: 2048

// Quantization
QA :: 255
QB :: 64
QO :: 127 // Output quantization

// Network Weights Structure
Network :: struct {
	// Feature Transformer (Input -> Hidden)
	feature_weights: [INPUT_SIZE * HIDDEN_SIZE]i16,
	feature_biases:  [HIDDEN_SIZE]i16,

	// Hidden Layers (Hidden -> Output)
	// Layer 1: 1024 (2x512) -> 32 ? Or 1024 -> 32?
	// Usually: (Accumulator 2x512) -> Layer1 (32) -> Layer2 (32) -> Output (1)
	// Wait, if Hidden is 1024, is it 2x512? Yes.
	// Layer 1: 1024 -> 32
	l1_weights:      [1024 * 32]i8,
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
	data, read_success := os.read_entire_file(filename)
	if !read_success {
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
		// Read only 1024 biases (File has 1024 biases but 2048 weights)
		for i in 0 ..< 1024 {
			current_network.feature_biases[i] = i16(read_sleb128(data, &offset))
		}
	} else {
		return false
	}

	// 2. Feature Transformer Weights
	_, l_type = read_layer_header(data, &offset)
	if l_type == "COMPRESSED_LEB128" {
		// Read 2048 * INPUT_SIZE weights
		for i in 0 ..< INPUT_SIZE * 2048 {
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

// Evaluate using NNUE
evaluate :: proc(b: ^board.Board) -> int {
	if !is_initialized {
		return 0 // Should fallback to HCE
	}

	// Use the incrementally updated accumulators from the board
	// (These are updated by update_accumulators in search)
	white_acc := b.accumulators[constants.WHITE]
	black_acc := b.accumulators[constants.BLACK]

	// 2. Forward Pass
	// Perspective: Side to move

	stm := b.side

	input: [HIDDEN_SIZE]i16

	// Use Accumulator directly (2048 size)
	if stm == constants.WHITE {
		for i in 0 ..< HIDDEN_SIZE {input[i] = white_acc.values[i]}
	} else {
		for i in 0 ..< HIDDEN_SIZE {input[i] = black_acc.values[i]}
	}

	// Layer 1
	l1_out: [32]i32
	for i in 0 ..< 32 {l1_out[i] = current_network.l1_biases[i]}

	for i in 0 ..< HIDDEN_SIZE {
		val := input[i]
		// Activation: Clipped ReLU (0..QA)
		if val < 0 {val = 0}
		if val > QA {val = QA}

		if val != 0 {
			for j in 0 ..< 32 {
				l1_out[j] += i32(val) * i32(current_network.l1_weights[i * 32 + j])
			}
		}
	}

	// Layer 2
	l2_out: [32]i32
	for i in 0 ..< 32 {l2_out[i] = current_network.l2_biases[i]}

	for i in 0 ..< 32 {
		val := l1_out[i]
		// Activation
		if val < 0 {val = 0}
		if val > QA {val = QA}

		if val != 0 {
			for j in 0 ..< 32 {
				l2_out[j] += val * i32(current_network.l2_weights[i * 32 + j])
			}
		}
	}

	// Output
	output := current_network.output_bias
	for i in 0 ..< 32 {
		val := l2_out[i]
		if val < 0 {val = 0}
		if val > QO {val = QO}

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

	// Add active features
	// Feature Index: HalfKP
	// King Square (0-63)
	king_sq := board.get_king_square(b, side)

	// Iterate all pieces (of both sides)
	// Pieces are indexed 0-11.
	// 0-5: White P,N,B,R,Q,K
	// 6-11: Black P,N,B,R,Q,K

	// For HalfKP:
	// We need to map pieces relative to the King's perspective.
	// If side is White, King is White King.
	//   White Pieces: 0-4 (P-Q). Index = PieceType * 64 + Square.
	//   Black Pieces: 0-4 (P-Q). Index = (PieceType + 5) * 64 + Square.
	//   (King is excluded from features usually, as it defines the bucket)

	// If side is Black, King is Black King.
	//   We mirror the board vertically?
	//   Usually HalfKP mirrors the board so the King is always "White" effectively, or uses separate weights.
	//   Standard: orient everything to White perspective, but for Black, we flip ranks.

	// Let's implement a simple feature mapper.

	// Iterate all squares
	for sq in 0 ..< 64 {
		piece := get_piece_at(b, sq)
		if piece != -1 && piece != constants.KING && piece != (constants.KING + 6) {
			// Calculate Feature Index
			feature_idx := get_feature_index(king_sq, sq, piece, side)

			// Add weights
			for i in 0 ..< HIDDEN_SIZE {
				acc.values[i] += current_network.feature_weights[feature_idx * HIDDEN_SIZE + i]
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
	// Orient to perspective
	k_sq := king_sq
	p_sq := sq
	p_type := piece // 0-11

	if side == constants.BLACK {
		k_sq = k_sq ~ 56 // Flip Rank
		p_sq = p_sq ~ 56 // Flip Rank

		// Flip Colors in Piece Type
		// 0-5 (White) -> 6-11 (Black)
		// 6-11 (Black) -> 0-5 (White)
		if p_type < 6 {p_type += 6} else {p_type -= 6}
	}

	// Map Piece Type to 0-10
	// Own: P(0), N(1), B(2), R(3), Q(4), K(5 - skipped for own)
	// Enemy: p(6)->5, n(7)->6, b(8)->7, r(9)->8, q(10)->9, k(11)->10

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
	// Copy old accumulators to new board
	new_board.accumulators = old_board.accumulators

	if !is_initialized {return}

	side := old_board.side
	piece_type := move.piece

	// 1. Check for King Move (Refresh own accumulator)
	if piece_type == constants.KING {
		// Refresh the accumulator for the side that moved the King
		// We use the NEW board state for this
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
				// If King moved, we already refreshed its accumulator (which accounts for the capture).
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
	for i in 0 ..< HIDDEN_SIZE {
		acc.values[i] -= current_network.feature_weights[idx_rem * HIDDEN_SIZE + i]
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
	for i in 0 ..< HIDDEN_SIZE {
		acc.values[i] += current_network.feature_weights[idx_add * HIDDEN_SIZE + i]
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
	for i in 0 ..< HIDDEN_SIZE {
		acc.values[i] -= current_network.feature_weights[idx * HIDDEN_SIZE + i]
	}
}
