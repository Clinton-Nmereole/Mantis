package nnue

import "../board"
import "../constants"
import "../moves"
import "core:fmt"
import "core:os"
import "core:simd"

// NNUE Constants (Standard HalfKP-256x2-32-32)
// Input Dimensions:
// KingSquare (64) * Side (2) * PieceType (5) * PieceSquare (64) ?
// HalfKP usually maps: (KingSq * 640) + (PieceType * 64) + PieceSq?
// Actually, standard HalfKP is:
// 64 King Squares * 5 Piece Types * 2 Colors * 64 Squares = 40960 inputs?
// No, usually it's 41024 to align.

INPUT_SIZE :: 41024
HIDDEN_SIZE :: 256

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
	// Layer 1: 512 (2x256) -> 32
	l1_weights:      [512 * 32]i8,
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

// Initialize / Load Network
init_nnue :: proc(filename: string) -> bool {
	handle, err := os.open(filename)
	if err != os.ERROR_NONE {
		fmt.printf("Error opening file: %v\n", err)
		return false
	}
	defer os.close(handle)

	// Get file size
	file_size, _ := os.file_size(handle)
	data, read_success := os.read_entire_file(filename)
	if !read_success {
		fmt.println("Error reading file.")
		return false
	}
	defer delete(data)

	// Parse Data
	// Standard NNUE file format (Stockfish/Marlinflow compatible usually has a header)
	// Header: 4 bytes version (usually) + 4 bytes hash?
	// Or sometimes just raw weights.
	// Let's assume standard architecture:
	// Feature Transformer:
	//   Biases: 256 * 2 (i16) = 512 bytes
	//   Weights: 41024 * 256 * 2 (i16) = 20,971,520 bytes approx
	// Layer 1:
	//   Biases: 32 * 4 (i32) = 128 bytes
	//   Weights: 512 * 32 (i8) = 16,384 bytes
	// Layer 2:
	//   Biases: 32 * 4 (i32) = 128 bytes
	//   Weights: 32 * 32 (i8) = 1024 bytes
	// Output:
	//   Bias: 4 (i32) = 4 bytes
	//   Weights: 32 (i8) = 32 bytes

	// Total size check?
	// Let's try to read sequentially.

	offset := 0

	// Skip Header (usually 176 bytes or similar for recent formats, or just check magic)
	// Simple check: if file size is exactly what we expect for raw weights.
	// Raw size = 512 + 21004288 + 128 + 16384 + 128 + 1024 + 4 + 32 = ~21MB

	// Let's assume a specific format or try to read raw.
	// Many engines use a specific layout.
	// Layout:
	// FeatureTransformer:
	//   bias: [256]i16
	//   weight: [41024][256]i16 (Column Major? Row Major? Usually [Input][Output])
	// Layer 1:
	//   bias: [32]i32
	//   weight: [32][512]i8 (Usually [Output][Input])
	// Layer 2:
	//   bias: [32]i32
	//   weight: [32][32]i8
	// Output:
	//   bias: [1]i32
	//   weight: [1][32]i8

	// NOTE: Stockfish puts the header at the start.
	// Header is usually: version (4 bytes), hash (4 bytes), description length (4 bytes), description...
	// We will skip the header by finding the start of data?
	// Or just assume a fixed header size if we use a specific net.
	// Let's just try to read the weights directly. If the numbers look garbage, we know.

	// Actually, reading raw bytes into structs is unsafe if endianness differs, but usually Little Endian.

	// Helper to read
	read_i16 :: proc(data: []byte, offset: ^int) -> i16 {
		val := (^i16)(&data[offset^])^
		offset^ += 2
		return val
	}

	read_i32 :: proc(data: []byte, offset: ^int) -> i32 {
		val := (^i32)(&data[offset^])^
		offset^ += 4
		return val
	}

	read_i8 :: proc(data: []byte, offset: ^int) -> i8 {
		val := (^i8)(&data[offset^])^
		offset^ += 1
		return val
	}

	// Skip Header?
	// Let's try to detect.
	// Valid NNUE file usually starts with specific magic.
	// For now, let's assume we are loading a "raw" dump or we skip 0 bytes.
	// If the user provides a .nnue file from Stockfish, it has a header.
	// The header size varies.
	// But the weights are huge.

	// Let's try to read Feature Transformer Biases first.
	for i in 0 ..< HIDDEN_SIZE {
		current_network.feature_biases[i] = read_i16(data, &offset)
	}

	// Feature Weights
	// Order: [Input][Hidden] (41024 * 256)
	for i in 0 ..< INPUT_SIZE * HIDDEN_SIZE {
		current_network.feature_weights[i] = read_i16(data, &offset)
	}

	// Layer 1 Biases
	for i in 0 ..< 32 {
		current_network.l1_biases[i] = read_i32(data, &offset)
	}

	// Layer 1 Weights
	// Order: [Output][Input] (32 * 512)
	// My struct has [512 * 32].
	// If the file is [32][512], we need to transpose or index correctly.
	// Stockfish stores [Output][Input].
	// So file has: 32 rows of 512 weights.
	// Row 0: w(0,0), w(0,1)... w(0,511) -> Weights for Output Neuron 0.
	// My forward pass:
	// for j in 0..<32 { l1_out[j] += input[i] * weight[i*32 + j] }
	// This implies my struct is [Input][Output].
	// So I need to transpose.

	for r in 0 ..< 32 { 	// Output
		for c in 0 ..< 512 { 	// Input
			val := read_i8(data, &offset)
			// Store at [Input][Output] -> [c][r] -> c*32 + r
			current_network.l1_weights[c * 32 + r] = val
		}
	}

	// Layer 2 Biases
	for i in 0 ..< 32 {
		current_network.l2_biases[i] = read_i32(data, &offset)
	}

	// Layer 2 Weights
	// Order: [Output][Input] (32 * 32)
	for r in 0 ..< 32 {
		for c in 0 ..< 32 {
			val := read_i8(data, &offset)
			// Store at [Input][Output] -> [c][r] -> c*32 + r
			current_network.l2_weights[c * 32 + r] = val
		}
	}

	// Output Bias
	current_network.output_bias = read_i32(data, &offset)

	// Output Weights
	// Order: [1][Input] (1 * 32)
	for i in 0 ..< 32 {
		current_network.output_weights[i] = read_i8(data, &offset)
	}

	is_initialized = true
	fmt.println("NNUE Initialized.")
	return true
}

// Evaluate using NNUE
evaluate :: proc(b: ^board.Board) -> int {
	if !is_initialized {
		return 0 // Should fallback to HCE
	}

	// 1. Refresh Accumulators (if needed)
	// Ideally we update them incrementally in make_move.
	// For now, we compute from scratch.

	white_acc := compute_accumulator(b, constants.WHITE)
	black_acc := compute_accumulator(b, constants.BLACK)

	// 2. Forward Pass
	// Perspective: Side to move
	stm := b.side

	input: [512]i16

	// Concat accumulators based on perspective
	// [Us, Them]
	if stm == constants.WHITE {
		for i in 0 ..< 256 {input[i] = white_acc.values[i]}
		for i in 0 ..< 256 {input[256 + i] = black_acc.values[i]}
	} else {
		for i in 0 ..< 256 {input[i] = black_acc.values[i]}
		for i in 0 ..< 256 {input[256 + i] = white_acc.values[i]}
	}

	// Clamp and Activation (Clipped ReLU: 0..127)
	// The accumulator values are i16.
	// We need to clamp them to 0..QA (255) or similar?
	// Standard NNUE uses Clipped ReLU on the output of the feature transformer?
	// Actually, usually the accumulator stores raw sums.
	// The activation is applied before the next layer.

	// Layer 1
	l1_out: [32]i32
	for i in 0 ..< 32 {l1_out[i] = current_network.l1_biases[i]}

	for i in 0 ..< 512 {
		val := input[i]
		// Activation: Clipped ReLU (0..127 usually for i8 weights?)
		// Actually, SF uses 0..127.
		if val < 0 {val = 0}
		if val > 127 {val = 127}

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
		if val > 127 {val = 127} 	// Quantization scaling might differ

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
		if val > 127 {val = 127}

		output += val * i32(current_network.output_weights[i])
	}

	// Scale to Centipawns
	// Usually output is roughly cp * constant
	return int(output / 16) // Example scaling
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

// Helper: Get Piece at Square (Slow, should use bitboards)
get_piece_at :: proc(b: ^board.Board, sq: int) -> int {
	for p in 0 ..< 12 {
		if (b.bitboards[p] & (u64(1) << u64(sq))) != 0 {
			return p
		}
	}
	return -1
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

	// Map Piece Type to 0-10 (excluding King)
	// P(0), N(1), B(2), R(3), Q(4)
	// p(6)->5, n(7)->6, b(8)->7, r(9)->8, q(10)->9
	// Kings are 5 and 11.

	idx := 0
	if p_type < 5 {idx = p_type} else // Own pieces
	if p_type > 5 && p_type < 11 {idx = p_type - 1} else // Enemy pieces (skip King 5)
	{return 0} 	// Should not happen if King excluded

	return k_sq * 640 + idx * 64 + p_sq
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
	piece := move.piece + (side == constants.WHITE ? 0 : 6)

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
		final_piece = move.promoted + (side == constants.WHITE ? 0 : 6)
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
