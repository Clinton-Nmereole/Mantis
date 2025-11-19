package moves

import "../constants"
import "../utils" // Added for utils.pop_lsb

// Colors
WHITE :: 0
BLACK :: 1

get_pawn_moves :: proc(
	side: int,
	pawns: u64,
	occupancy: u64,
	enemy_pieces: u64,
	en_passant_target: u64,
	move_list: ^[dynamic]Move,
) {
	empty := ~occupancy

	// Temporary bitboards
	bitboard, attacks: u64
	source, target: int

	if side == constants.WHITE {
		// --- WHITE PAWNS ---

		// 1. Single Push
		// Shift North (<< 8) into empty squares
		bitboard = (pawns << 8) & empty
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target - 8

			// Check Promotion (Rank 8 is 56-63)
			if target >= 56 {
				// Add promotion moves
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.QUEEN,
						false,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.ROOK,
						false,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.BISHOP,
						false,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.KNIGHT,
						false,
						false,
						false,
						false,
					},
				)
			} else {
				append(move_list, create_move(source, target, constants.PAWN))
			}
		}

		// 2. Double Push
		// From Rank 2 (8-15), push 16. Must be empty at +8 and +16.
		// We already calculated single pushes that landed on Rank 3 (16-23).
		// So we can take (single_pushes & RANK_3) << 8 & empty.
		// Re-calculate single push for this logic to be safe/clear
		single_push := (pawns << 8) & empty
		bitboard = ((single_push & constants.RANK_3) << 8) & empty
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target - 16
			append(move_list, Move{source, target, constants.PAWN, -1, false, true, false, false})
		}

		// 3. Captures
		// North-West (<< 7). Mask File A.
		attacks = (pawns & ~constants.FILE_A) << 7

		// Normal Capture
		bitboard = attacks & enemy_pieces
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target - 7

			if target >= 56 { 	// Capture Promotion
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.QUEEN,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.ROOK,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.BISHOP,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.KNIGHT,
						true,
						false,
						false,
						false,
					},
				)
			} else {
				append(move_list, create_move(source, target, constants.PAWN, true))
			}
		}

		// En Passant Capture (North-West)
		if en_passant_target != 0 {
			bitboard = attacks & en_passant_target
			for bitboard != 0 {
				target = utils.pop_lsb(&bitboard)
				source = target - 7
				append(
					move_list,
					Move{source, target, constants.PAWN, -1, true, false, true, false},
				)
			}
		}

		// North-East (<< 9). Mask File H.
		attacks = (pawns & ~constants.FILE_H) << 9

		// Normal Capture
		bitboard = attacks & enemy_pieces
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target - 9

			if target >= 56 { 	// Capture Promotion
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.QUEEN,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.ROOK,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.BISHOP,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.KNIGHT,
						true,
						false,
						false,
						false,
					},
				)
			} else {
				append(move_list, create_move(source, target, constants.PAWN, true))
			}
		}

		// En Passant Capture (North-East)
		if en_passant_target != 0 {
			bitboard = attacks & en_passant_target
			for bitboard != 0 {
				target = utils.pop_lsb(&bitboard)
				source = target - 9
				append(
					move_list,
					Move{source, target, constants.PAWN, -1, true, false, true, false},
				)
			}
		}

	} else {
		// --- BLACK PAWNS ---

		// 1. Single Push (South >> 8)
		bitboard = (pawns >> 8) & empty
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target + 8

			// Check Promotion (Rank 1 is 0-7)
			if target <= 7 {
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.QUEEN,
						false,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.ROOK,
						false,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.BISHOP,
						false,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.KNIGHT,
						false,
						false,
						false,
						false,
					},
				)
			} else {
				append(move_list, create_move(source, target, constants.PAWN))
			}
		}

		// 2. Double Push (South >> 16)
		single_push := (pawns >> 8) & empty
		bitboard = ((single_push & constants.RANK_6) >> 8) & empty
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target + 16
			append(move_list, Move{source, target, constants.PAWN, -1, false, true, false, false})
		}

		// 3. Captures
		// South-East (>> 7). Mask File H.
		attacks = (pawns & ~constants.FILE_H) >> 7

		// Normal Capture
		bitboard = attacks & enemy_pieces
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target + 7

			if target <= 7 { 	// Capture Promotion
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.QUEEN,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.ROOK,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.BISHOP,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.KNIGHT,
						true,
						false,
						false,
						false,
					},
				)
			} else {
				append(move_list, create_move(source, target, constants.PAWN, true))
			}
		}

		// En Passant (South-East)
		if en_passant_target != 0 {
			bitboard = attacks & en_passant_target
			for bitboard != 0 {
				target = utils.pop_lsb(&bitboard)
				source = target + 7
				append(
					move_list,
					Move{source, target, constants.PAWN, -1, true, false, true, false},
				)
			}
		}

		// South-West (>> 9). Mask File A.
		attacks = (pawns & ~constants.FILE_A) >> 9

		// Normal Capture
		bitboard = attacks & enemy_pieces
		for bitboard != 0 {
			target = utils.pop_lsb(&bitboard)
			source = target + 9

			if target <= 7 { 	// Capture Promotion
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.QUEEN,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.ROOK,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.BISHOP,
						true,
						false,
						false,
						false,
					},
				)
				append(
					move_list,
					Move {
						source,
						target,
						constants.PAWN,
						constants.KNIGHT,
						true,
						false,
						false,
						false,
					},
				)
			} else {
				append(move_list, create_move(source, target, constants.PAWN, true))
			}
		}

		// En Passant (South-West)
		if en_passant_target != 0 {
			bitboard = attacks & en_passant_target
			for bitboard != 0 {
				target = utils.pop_lsb(&bitboard)
				source = target + 9
				append(
					move_list,
					Move{source, target, constants.PAWN, -1, true, false, true, false},
				)
			}
		}
	}
}
