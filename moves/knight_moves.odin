package moves

import "../constants"
import "../utils"

// Pre-computed Knight Attacks
// We can either pre-compute them at runtime or hardcode them.
// For simplicity and "wow" factor of cleanliness, let's compute them on the fly first,
// then we can optimize to a lookup table if needed.
// Actually, for a "full engine", a lookup table is standard.
// Let's make a `init_knight_attacks` function or just compute on fly for now to save space/time in this turn.
// Computing on fly is very fast for knights anyway.

// Helper to get attacks for a single square (used by is_square_attacked)
get_knight_attacks_bitboard :: proc(square: int) -> u64 {
	attacks: u64 = 0
	src_bit := u64(1) << u64(square)

	// NNE (+17) - Mask File H
	attacks |= (src_bit & ~constants.FILE_H) << 17
	// NNW (+15) - Mask File A
	attacks |= (src_bit & ~constants.FILE_A) << 15
	// WWN (+6) - Mask File A, B
	attacks |= (src_bit & ~(constants.FILE_A | 0x0202020202020202)) << 6
	// WWS (-10) - Mask File A, B
	attacks |= (src_bit & ~(constants.FILE_A | 0x0202020202020202)) >> 10
	// EEN (+10) - Mask File G, H
	attacks |= (src_bit & ~(constants.FILE_H | 0x4040404040404040)) << 10
	// EES (-6) - Mask File G, H
	attacks |= (src_bit & ~(constants.FILE_H | 0x4040404040404040)) >> 6
	// SSE (-15) - Mask File H
	attacks |= (src_bit & ~constants.FILE_H) >> 15
	// SSW (-17) - Mask File A
	attacks |= (src_bit & ~constants.FILE_A) >> 17

	return attacks
}

get_knight_moves :: proc(
	knights: u64,
	occupancy: u64,
	own_pieces: u64,
	move_list: ^[dynamic]Move,
) {
	bitboard := knights
	source, target: int
	attacks: u64

	for bitboard != 0 {
		source = utils.pop_lsb(&bitboard)

		// Generate attacks for this square
		attacks = get_knight_attacks_bitboard(source)

		// Mask out own pieces
		attacks &= ~own_pieces

		// Now append moves
		for attacks != 0 {
			target = utils.pop_lsb(&attacks)
			is_capture := (occupancy & (1 << u64(target))) != 0
			append(move_list, create_move(source, target, constants.KNIGHT, is_capture))
		}
	}
}
