package moves

import "../constants"
import "../utils"

get_king_moves :: proc(
	king: u64,
	occupancy: u64,
	own_pieces: u64,
	castling_rights: int,
	side: int,
	move_list: ^[dynamic]Move,
) {
	bitboard := king
	source, target: int
	attacks: u64

	// Standard King Moves
	if bitboard != 0 {
		source = utils.pop_lsb(&bitboard)

		// Generate attacks for this square
		// King offsets: +/- 1, 7, 8, 9
		// We use a lookup or direct calculation.
		// Let's use direct calculation for now as we did before.

		attacks = 0
		src_bit := u64(1) << u64(source)

		// North (+8), South (-8)
		attacks |= (src_bit << 8)
		attacks |= (src_bit >> 8)

		// East (+1), NE (+9), SE (-7) - Mask File H
		attacks |= (src_bit & ~constants.FILE_H) << 1
		attacks |= (src_bit & ~constants.FILE_H) << 9
		attacks |= (src_bit & ~constants.FILE_H) >> 7

		// West (-1), NW (+7), SW (-9) - Mask File A
		attacks |= (src_bit & ~constants.FILE_A) >> 1
		attacks |= (src_bit & ~constants.FILE_A) << 7
		attacks |= (src_bit & ~constants.FILE_A) >> 9

		// Mask out own pieces
		attacks &= ~own_pieces

		// Append standard moves
		for attacks != 0 {
			target = utils.pop_lsb(&attacks)
			is_capture := (occupancy & (1 << u64(target))) != 0
			append(move_list, create_move(source, target, constants.KING, is_capture))
		}

		// Castling Moves
		// We assume the King is at the correct starting square (E1 or E8) if rights are set.
		// But we should verify source is E1 (4) or E8 (60).

		if side == constants.WHITE {
			if source == 4 {
				// King Side (G1) - Requires WK (1)
				if (castling_rights & 1) != 0 {
					// Check path F1(5), G1(6) empty
					if (occupancy & ((1 << 5) | (1 << 6))) == 0 {
						// Add Castling Move
						// We don't check attacks here (handled in make_move/is_legal)
						move := create_move(4, 6, constants.KING, false)
						move.castling = true
						append(move_list, move)
					}
				}
				// Queen Side (C1) - Requires WQ (2)
				if (castling_rights & 2) != 0 {
					// Check path B1(1), C1(2), D1(3) empty
					if (occupancy & ((1 << 1) | (1 << 2) | (1 << 3))) == 0 {
						move := create_move(4, 2, constants.KING, false)
						move.castling = true
						append(move_list, move)
					}
				}
			}
		} else {
			if source == 60 {
				// King Side (G8) - Requires BK (4)
				if (castling_rights & 4) != 0 {
					// Check path F8(61), G8(62) empty
					if (occupancy & ((1 << 61) | (1 << 62))) == 0 {
						move := create_move(60, 62, constants.KING, false)
						move.castling = true
						append(move_list, move)
					}
				}
				// Queen Side (C8) - Requires BQ (8)
				if (castling_rights & 8) != 0 {
					// Check path B8(57), C8(58), D8(59) empty
					if (occupancy & ((1 << 57) | (1 << 58) | (1 << 59))) == 0 {
						move := create_move(60, 58, constants.KING, false)
						move.castling = true
						append(move_list, move)
					}
				}
			}
		}
	}
}

// Helper to get attacks for a single square (used by is_square_attacked)
get_king_attacks_bitboard :: proc(square: int) -> u64 {
	attacks: u64 = 0
	src_bit := u64(1) << u64(square)

	// North (+8), South (-8)
	attacks |= (src_bit << 8)
	attacks |= (src_bit >> 8)

	// East (+1), NE (+9), SE (-7) - Mask File H
	attacks |= (src_bit & ~constants.FILE_H) << 1
	attacks |= (src_bit & ~constants.FILE_H) << 9
	attacks |= (src_bit & ~constants.FILE_H) >> 7

	// West (-1), NW (+7), SW (-9) - Mask File A
	attacks |= (src_bit & ~constants.FILE_A) >> 1
	attacks |= (src_bit & ~constants.FILE_A) << 7
	attacks |= (src_bit & ~constants.FILE_A) >> 9

	return attacks
}
