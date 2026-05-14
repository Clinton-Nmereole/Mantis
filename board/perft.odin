package board

import "../constants"
import "../moves"
import "../utils"
import "../zobrist"
import "core:fmt"
import "core:time"

// apply_move_to_board performs the actual move application WITHOUT saving state
// or checking legality. Used internally by make_move_fast.
apply_move_to_board :: proc(b: ^Board, move: moves.Move) {
	side := b.side

	// Update Hash: Side
	b.hash ~= zobrist.side_key

	// Update Hash: Castling Rights (Remove old)
	b.hash ~= zobrist.castling_keys[b.castle]

	// Update Hash: En Passant (Remove old)
	if b.en_passant != -1 {
		b.hash ~= zobrist.en_passant_keys[b.en_passant]
	}

	piece_idx := move.piece + (side == constants.WHITE ? 0 : 6)

	// 1. Remove piece from source
	b.bitboards[piece_idx] &= ~(u64(1) << u64(move.source))
	b.mailbox[move.source] = -1
	b.hash ~= zobrist.piece_keys[piece_idx][move.source]

	// 2. Add piece to target (Handle Promotion)
	if move.promoted == -1 {
		b.bitboards[piece_idx] |= (u64(1) << u64(move.target))
		b.mailbox[move.target] = i8(piece_idx)
		b.hash ~= zobrist.piece_keys[piece_idx][move.target]
	} else {
		promoted_index := move.promoted + (side == constants.WHITE ? 0 : 6)
		b.bitboards[promoted_index] |= (u64(1) << u64(move.target))
		b.mailbox[move.target] = i8(promoted_index)
		b.hash ~= zobrist.piece_keys[promoted_index][move.target]
	}

	// 3. Captures
	if move.capture {
		start_piece := (side == constants.WHITE) ? 6 : 0
		end_piece := (side == constants.WHITE) ? 12 : 6

		for i in start_piece ..< end_piece {
			if (b.bitboards[i] & (u64(1) << u64(move.target))) != 0 {
				b.bitboards[i] &= ~(u64(1) << u64(move.target))
				b.hash ~= zobrist.piece_keys[i][move.target]
				break
			}
		}
	}

	// 4. En Passant Capture
	if move.en_passant {
		capture_square := (side == constants.WHITE) ? move.target - 8 : move.target + 8
		enemy_pawn := (side == constants.WHITE) ? constants.PAWN + 6 : constants.PAWN
		b.bitboards[enemy_pawn] &= ~(u64(1) << u64(capture_square))
		b.mailbox[capture_square] = -1
		b.hash ~= zobrist.piece_keys[enemy_pawn][capture_square]
	}

	// 5. Castling
	if move.piece == constants.KING || move.piece == (constants.KING + 6) {
		if abs(move.target - move.source) == 2 {
			if move.target == 6 {		// G1
				b.bitboards[constants.ROOK] &= ~(u64(1) << 7)
				b.bitboards[constants.ROOK] |= (u64(1) << 5)
				b.mailbox[7] = -1
				b.mailbox[5] = i8(constants.ROOK)
				b.hash ~= zobrist.piece_keys[constants.ROOK][7]
				b.hash ~= zobrist.piece_keys[constants.ROOK][5]
			} else if move.target == 2 {	// C1
				b.bitboards[constants.ROOK] &= ~(u64(1) << 0)
				b.bitboards[constants.ROOK] |= (u64(1) << 3)
				b.mailbox[0] = -1
				b.mailbox[3] = i8(constants.ROOK)
				b.hash ~= zobrist.piece_keys[constants.ROOK][0]
				b.hash ~= zobrist.piece_keys[constants.ROOK][3]
			} else if move.target == 62 {	// G8
				b.bitboards[constants.ROOK + 6] &= ~(u64(1) << 63)
				b.bitboards[constants.ROOK + 6] |= (u64(1) << 61)
				b.mailbox[63] = -1
				b.mailbox[61] = i8(constants.ROOK + 6)
				b.hash ~= zobrist.piece_keys[constants.ROOK + 6][63]
				b.hash ~= zobrist.piece_keys[constants.ROOK + 6][61]
			} else if move.target == 58 {	// C8
				b.bitboards[constants.ROOK + 6] &= ~(u64(1) << 56)
				b.bitboards[constants.ROOK + 6] |= (u64(1) << 59)
				b.mailbox[56] = -1
				b.mailbox[59] = i8(constants.ROOK + 6)
				b.hash ~= zobrist.piece_keys[constants.ROOK + 6][56]
				b.hash ~= zobrist.piece_keys[constants.ROOK + 6][59]
			}
		}
	}

	// Update Occupancies
	update_occupancies(b)

	// Update State
	b.side = 1 - side

	// Update En Passant Target
	if move.double_push {
		b.en_passant = (side == constants.WHITE) ? move.target - 8 : move.target + 8
		b.hash ~= zobrist.en_passant_keys[b.en_passant]
	} else {
		b.en_passant = -1
	}

	// Update Castling Rights
	b.castle &= castling_rights_mask[move.source]
	b.castle &= castling_rights_mask[move.target]
	b.hash ~= zobrist.castling_keys[b.castle]
}

// make_move_fast: save state, apply move, NO legality check.
// This is the hot-path function used during search.
make_move_fast :: proc(b: ^Board, move: moves.Move, state: ^StateInfo) {
	state^ = StateInfo(b^)
	apply_move_to_board(b, move)
}

// unmake_move: restore board to previously saved state.
unmake_move :: proc(b: ^Board, state: ^StateInfo) {
	b^ = Board(state^)
}

// make_move: full legal move application. Saves state, applies move,
// checks legality, and auto-restores if the move is illegal.
// Returns true if the move was legal and applied.
make_move :: proc(b: ^Board, move: moves.Move, state: ^StateInfo) -> bool {
	make_move_fast(b, move, state)

	// Check if the king of the side that just moved is in check.
	// b.side has already flipped, so the mover is (1 - b.side).
	king_sq := get_king_square(b, 1 - b.side)
	if is_square_attacked(b, king_sq, b.side) {
		unmake_move(b, state)
		return false
	}

	// Castling legality: cannot castle out of or through check.
	if move.castling {
		row := (1 - b.side == constants.WHITE) ? 0 : 56
		if move.target == (row + 6) {		// King side
			if is_square_attacked(b, row + 4, b.side) || is_square_attacked(b, row + 5, b.side) {
				unmake_move(b, state)
				return false
			}
		} else if move.target == (row + 2) {	// Queen side
			if is_square_attacked(b, row + 4, b.side) || is_square_attacked(b, row + 3, b.side) {
				unmake_move(b, state)
				return false
			}
		}
	}

	return true
}

// Castling Rights Mask Table
// 15 (1111) means keep all.
// Moving from/to specific squares clears specific bits.
castling_rights_mask: [64]int = {
	13,
	15,
	15,
	15,
	12,
	15,
	15,
	14, // Rank 1 (A1=13, E1=12, H1=14)
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	15,
	7,
	15,
	15,
	15,
	3,
	15,
	15,
	11, // Rank 8 (A8=7, E8=3, H8=11)
}

// Helper: Get King Square
get_king_square :: proc(board: ^Board, side: int) -> int {
	king_bitboard :=
		(side == constants.WHITE) ? board.bitboards[constants.KING] : board.bitboards[constants.KING + 6]
	return utils.get_lsb_index(king_bitboard)
}

// Helper: Is Square Attacked
is_square_attacked :: proc(board: ^Board, square: int, attacker_side: int) -> bool {
	// Check Pawn Attacks
	if attacker_side == constants.WHITE {
		attacks := u64(1) << u64(square)
		if ((attacks >> 9) & ~constants.FILE_H & board.bitboards[constants.PAWN]) !=
		   0 {return true}
		if ((attacks >> 7) & ~constants.FILE_A & board.bitboards[constants.PAWN]) !=
		   0 {return true}
	} else {
		attacks := u64(1) << u64(square)
		if ((attacks << 9) & ~constants.FILE_A & board.bitboards[constants.PAWN + 6]) !=
		   0 {return true}
		if ((attacks << 7) & ~constants.FILE_H & board.bitboards[constants.PAWN + 6]) !=
		   0 {return true}
	}

	// 2. Knight Attacks
	knight_attacks := moves.get_knight_attacks_bitboard(square)
	enemy_knights :=
		(attacker_side == constants.WHITE) ? board.bitboards[constants.KNIGHT] : board.bitboards[constants.KNIGHT + 6]
	if (knight_attacks & enemy_knights) != 0 {return true}

	// 3. King Attacks
	king_attacks := moves.get_king_attacks_bitboard(square)
	enemy_king :=
		(attacker_side == constants.WHITE) ? board.bitboards[constants.KING] : board.bitboards[constants.KING + 6]
	if (king_attacks & enemy_king) != 0 {return true}

	// 4. Slider Attacks (Rook/Bishop/Queen)
	occupancy := board.occupancies[constants.BOTH]

	// Rook/Queen (Orthogonal)
	rook_attacks := moves.get_rook_attacks(square, occupancy)
	enemy_rooks :=
		(attacker_side == constants.WHITE) ? board.bitboards[constants.ROOK] : board.bitboards[constants.ROOK + 6]
	enemy_queens :=
		(attacker_side == constants.WHITE) ? board.bitboards[constants.QUEEN] : board.bitboards[constants.QUEEN + 6]
	if (rook_attacks & (enemy_rooks | enemy_queens)) != 0 {return true}

	// Bishop/Queen (Diagonal)
	bishop_attacks := moves.get_bishop_attacks(square, occupancy)
	enemy_bishops :=
		(attacker_side == constants.WHITE) ? board.bitboards[constants.BISHOP] : board.bitboards[constants.BISHOP + 6]
	if (bishop_attacks & (enemy_bishops | enemy_queens)) != 0 {return true}

	return false
}

// Move Generation Wrapper
generate_all_moves :: proc(board: ^Board, move_list: ^moves.MoveList) {
	// Generate all moves for the current side
	side := board.side
	occupancy := board.occupancies[constants.BOTH]
	own_pieces := board.occupancies[side]
	enemy_pieces := board.occupancies[1 - side]

	// Pawns
	pawns :=
		(side == constants.WHITE) ? board.bitboards[constants.PAWN] : board.bitboards[constants.PAWN + 6]
	ep_target := (board.en_passant != -1) ? (1 << u64(board.en_passant)) : u64(0)
	moves.get_pawn_moves(side, pawns, occupancy, enemy_pieces, ep_target, move_list)

	// Knights
	knights :=
		(side == constants.WHITE) ? board.bitboards[constants.KNIGHT] : board.bitboards[constants.KNIGHT + 6]
	moves.get_knight_moves(knights, occupancy, own_pieces, move_list)

	// Kings
	king :=
		(side == constants.WHITE) ? board.bitboards[constants.KING] : board.bitboards[constants.KING + 6]
	moves.get_king_moves(king, occupancy, own_pieces, board.castle, side, move_list)

	// Sliders
	rooks :=
		(side == constants.WHITE) ? board.bitboards[constants.ROOK] : board.bitboards[constants.ROOK + 6]
	moves.get_rook_moves(rooks, occupancy, own_pieces, move_list)

	bishops :=
		(side == constants.WHITE) ? board.bitboards[constants.BISHOP] : board.bitboards[constants.BISHOP + 6]
	moves.get_bishop_moves(bishops, occupancy, own_pieces, move_list)

	queens :=
		(side == constants.WHITE) ? board.bitboards[constants.QUEEN] : board.bitboards[constants.QUEEN + 6]
	moves.get_queen_moves(queens, occupancy, own_pieces, move_list)
}

// Perft Function
perft :: proc(b: ^Board, depth: int) -> u64 {
	if depth == 0 {return 1}

	nodes: u64 = 0
	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated

	generate_all_moves(b, &move_list)

	for i in 0 ..< move_list.count {
		state: StateInfo
		if make_move(b, move_list.moves[i], &state) {
			nodes += perft(b, depth - 1)
			unmake_move(b, &state)
		}
	}

	return nodes
}

// Perft Driver (Prints results)
perft_test :: proc(fen: string, depth: int) {
	fmt.printf("\nPerformance Test\nFEN: %s\nDepth: %d\n", fen, depth)

	game_board := parse_fen(fen)
	print_board(game_board)

	start_time := time.now()

	// Run Perft Divide
	total_nodes: u64 = 0
	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated

	generate_all_moves(&game_board, &move_list)

	for i in 0 ..< move_list.count {
		state: StateInfo
		if make_move(&game_board, move_list.moves[i], &state) {
			nodes := perft(&game_board, depth - 1)

			// Print Move (e.g. "e2e4: 20")
			print_move(move_list.moves[i])
			fmt.printf(": %d\n", nodes)

			total_nodes += nodes
			unmake_move(&game_board, &state)
		}
	}

	duration := time.since(start_time)

	fmt.printf("\nNodes: %d\nTime: %v\n", total_nodes, duration)

	// Calculate NPS
	seconds := time.duration_seconds(duration)
	if seconds > 0 {
		nps := f64(total_nodes) / seconds
		fmt.printf("NPS: %.0f\n", nps)
	}
}

print_move :: proc(move: moves.Move) {
	files := "abcdefgh"
	ranks := "12345678"

	sf := move.source % 8
	sr := move.source / 8
	tf := move.target % 8
	tr := move.target / 8

	fmt.printf("%c%c%c%c", files[sf], ranks[sr], files[tf], ranks[tr])

	if move.promoted != -1 {
		switch move.promoted {
		case constants.KNIGHT:
			fmt.printf("n")
		case constants.BISHOP:
			fmt.printf("b")
		case constants.ROOK:
			fmt.printf("r")
		case constants.QUEEN:
			fmt.printf("q")
		}
	}
}
