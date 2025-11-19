package board

import "../constants"
import "../moves"
import "../utils"
import "core:fmt"
import "core:time"

// Make Move
// Returns false if the move is illegal (leaves king in check)
make_move :: proc(board: ^Board, move: moves.Move, side: int) -> bool {
	// Copy board state to restore if illegal?
	// For perft, we usually do Copy-Make or Make-Unmake.
	// Copy-Make is slower but easier to implement safely first.
	// Make-Unmake is faster but requires careful implementation.
	// Let's do Copy-Make for simplicity and robustness first.
	// Actually, Odin structs are value types, so passing by value creates a copy.
	// But here we passed a pointer.

	// We need to update bitboards

	// Note: move.piece stores Piece Type (0-5). We need to adjust for color.
	// If we stored the full piece index (0-11) in the Move struct, this offset calculation
	// would not be necessary, as we could index bitboards directly.
	piece_idx := move.piece + (side == constants.WHITE ? 0 : 6)

	// 1. Remove piece from source
	board.bitboards[piece_idx] &= ~(u64(1) << u64(move.source))

	// 2. Add piece to target
	board.bitboards[piece_idx] |= (u64(1) << u64(move.target))

	// 3. Captures
	if move.capture {
		// We need to find which enemy piece was at target and remove it
		start_piece := (side == constants.WHITE) ? 6 : 0
		end_piece := (side == constants.WHITE) ? 12 : 6

		for i in start_piece ..< end_piece {
			if (board.bitboards[i] & (u64(1) << u64(move.target))) != 0 {
				board.bitboards[i] &= ~(u64(1) << u64(move.target))
				break
			}
		}
	}

	// 4. Promotions
	if move.promoted != -1 {
		// Remove the pawn from target (we just added it)
		board.bitboards[piece_idx] &= ~(u64(1) << u64(move.target))
		// Add the promoted piece
		// Note: move.promoted is 0-5 (piece type). We need to adjust for color.
		promoted_index := move.promoted + (side == constants.WHITE ? 0 : 6)
		board.bitboards[promoted_index] |= (u64(1) << u64(move.target))
	}

	// 5. En Passant Capture
	if move.en_passant {
		// The captured pawn is not at target, but behind it.
		// White moves to E6, captures pawn on E5.
		// Black moves to E3, captures pawn on E4.
		capture_square := (side == constants.WHITE) ? move.target - 8 : move.target + 8
		enemy_pawn := (side == constants.WHITE) ? constants.PAWN + 6 : constants.PAWN
		board.bitboards[enemy_pawn] &= ~(1 << u64(capture_square))
	}

	// 6. Castling
	// We need to move the rook.
	// King move is already handled by generic logic (piece at source -> target).
	// But we need to move the rook.
	// White King Side: E1->G1. Rook H1->F1.
	// White Queen Side: E1->C1. Rook A1->D1.
	// Black King Side: E8->G8. Rook H8->F8.
	// Black Queen Side: E8->C8. Rook A8->D8.

	// We don't have a 'castling' flag in Move struct yet?
	// Wait, we do: `castling: bool`
	// But we need to know WHICH castling.
	// We can infer from source/target of King.

	if move.piece == constants.KING || move.piece == (constants.KING + 6) {
		// Castling Logic
		if abs(move.target - move.source) == 2 {
			// White King Side
			if move.target == 6 { 	// G1
				// Move Rook H1 (7) -> F1 (5)
				board.bitboards[constants.ROOK] &= ~(u64(1) << 7)
				board.bitboards[constants.ROOK] |= (u64(1) << 5)
			} else if move.target == 2 { 	// C1
				// Move Rook A1 (0) -> D1 (3)
				board.bitboards[constants.ROOK] &= ~(u64(1) << 0)
				board.bitboards[constants.ROOK] |= (u64(1) << 3)
			} else if move.target == 62 { 	// G8
				// Move Rook H8 (63) -> F8 (61)
				board.bitboards[constants.ROOK + 6] &= ~(u64(1) << 63)
				board.bitboards[constants.ROOK + 6] |= (u64(1) << 61)
			} else if move.target == 58 { 	// C8
				// Move Rook A8 (56) -> D8 (59)
				board.bitboards[constants.ROOK + 6] &= ~(u64(1) << 56)
				board.bitboards[constants.ROOK + 6] |= (u64(1) << 59)
			}
		}
	}

	// Update Occupancies
	update_occupancies(board)

	// Check for legality (King in Check)
	if is_square_attacked(board, get_king_square(board, side), 1 - side) {
		return false
	}

	// Castling Legality: Cannot castle out of or through check
	if move.castling {
		row := (side == constants.WHITE) ? 0 : 56
		// King Side (Target G1/G8)
		if move.target == (row + 6) {
			// Check E1/E8 (Source) and F1/F8 (Crossing)
			if is_square_attacked(board, row + 4, 1 - side) {return false}
			if is_square_attacked(board, row + 5, 1 - side) {return false}
		} else if move.target == (row + 2) { 	// Queen Side (Target C1/C8)
			// Check E1/E8 (Source) and D1/D8 (Crossing)
			if is_square_attacked(board, row + 4, 1 - side) {return false}
			if is_square_attacked(board, row + 3, 1 - side) {return false}
		}
	}

	// Update State
	board.side = 1 - side

	// Update En Passant Target
	// If double push, set target. Else reset.
	if move.double_push {
		board.en_passant = (side == constants.WHITE) ? move.target - 8 : move.target + 8
	} else {
		board.en_passant = -1
	}

	// Update Castling Rights
	// If King moves, lose rights.
	// If Rook moves, lose rights for that side.
	// If Rook captured, lose rights for that side.
	// (Simplification: Just mask out rights if King/Rook involved)

	// This is complex to do perfectly in one pass without lookup tables.
	// For now, let's assume we update it later or ignore for perft (Perft requires castling rights update).
	// Let's add a simple update:
	board.castle &= castling_rights_mask[move.source]
	board.castle &= castling_rights_mask[move.target]

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
		// Attacked by White Pawn?
		// Check if a White Pawn is at (square - 7) or (square - 9)
		// (Reverse of pawn capture logic)
		// If we are at 'square', a white pawn at 'square-9' attacks us (North-East).
		// Wait. White pawn at B2 attacks C3.
		// If we are at C3. B2 is (C3 - 9).
		// So yes.
		if (board.bitboards[constants.PAWN] & ((1 << u64(square)) >> 9)) != 0 {return true} 	// Check wrapping?
		// Actually, simpler: Generate attacks FROM square as if it was a pawn of OPPOSITE color, AND with enemy pawns.
		// If we are a Black King at square.
		// Attacks from square (as Black Pawn) -> South-East/South-West.
		// If those hit a White Pawn, then the White Pawn attacks us.

		// Let's use the "Super Piece" method or just reverse lookups.

		// 1. Pawn Attacks
		// White pawns attack 'square' from South-West/South-East.
		// So check square-9 and square-7.
		// Must handle file wrapping.
		// (1 << square) >> 9. If square is H3 (23). >> 9 is G2 (14). Correct.
		// If square is A3 (16). >> 9 is 7 (H1). WRAP!
		// So we must mask.

		// Let's use pre-computed pawn tables later. For now, manual.

		// Attacked by White Pawn from South-West (index - 9)?
		// Only if square is not on File H? No.
		// If square is on A3 (16). Source would be 7 (H1).
		// 7 (H1) attacks 16 (A2)? No. 7 attacks 14, 16?
		// H1 attacks G2 (14).
		// So 16 is NOT attacked by 7.
		// So (1 << 16) >> 9 = 7.
		// We need to check if 7 is a pawn AND if 7->16 is valid.

		// Let's use the `get_pawn_moves` logic in reverse or just re-use `get_pawn_moves` for the enemy?
		// No, `get_pawn_moves` generates moves for ALL pawns.

		// Let's use:
		// attacks_to_square = pawn_attacks(side^1, square)
		// if (attacks_to_square & enemy_pawns) return true

		// White Pawn Attacks from 'sq':
		// (1<<sq) << 9 (NE), (1<<sq) << 7 (NW)
		// Black Pawn Attacks from 'sq':
		// (1<<sq) >> 9 (SW), (1<<sq) >> 7 (SE)

		// If we want to know if 'sq' is attacked by White Pawn:
		// Imagine a Black Pawn at 'sq'. Where does it attack?
		// It attacks SW (>>9) and SE (>>7).
		// If there is a White Pawn at those squares, then 'sq' is attacked.

		attacks := u64(1) << u64(square)
		if ((attacks >> 9) & ~constants.FILE_H & board.bitboards[constants.PAWN]) !=
		   0 {return true}
		if ((attacks >> 7) & ~constants.FILE_A & board.bitboards[constants.PAWN]) !=
		   0 {return true}

	} else {
		// Attacked by Black Pawn?
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
generate_all_moves :: proc(board: ^Board, move_list: ^[dynamic]moves.Move) {
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
perft :: proc(board: Board, depth: int) -> u64 {
	if depth == 0 {return 1}

	nodes: u64 = 0
	move_list := make([dynamic]moves.Move)
	defer delete(move_list)

	// We need to pass a pointer to generate_all_moves, but we have a value 'board'.
	// Make a copy on stack/heap to pass pointer.
	// Actually, 'board' argument is a copy. We can take its address.
	// But Odin parameters are immutable by default unless 'var' or '^'.
	// So we need a mutable copy.
	temp_board := board
	generate_all_moves(&temp_board, &move_list)

	for move in move_list {
		// Copy board state
		next_board := temp_board

		if make_move(&next_board, move, temp_board.side) {
			nodes += perft(next_board, depth - 1)
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
	move_list := make([dynamic]moves.Move)
	defer delete(move_list)

	temp_board := game_board
	generate_all_moves(&temp_board, &move_list)

	for move in move_list {
		next_board := temp_board
		if make_move(&next_board, move, temp_board.side) {
			nodes := perft(next_board, depth - 1)

			// Print Move (e.g. "e2e4: 20")
			// We need a helper to print move in algebraic notation
			print_move(move)
			fmt.printf(": %d\n", nodes)

			total_nodes += nodes
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
		// p, n, b, r, q, k
		// promoted is 0-5. usually we promote to n, b, r, q (1, 2, 3, 4)
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
