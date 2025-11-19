package moves

import "../constants"
import "../utils"

// --- Magic Bitboard Constants ---

// Relevant occupancy bits count for each square (Rook)
RookBits: [64]int = {
	12,
	11,
	11,
	11,
	11,
	11,
	11,
	12,
	11,
	10,
	10,
	10,
	10,
	10,
	10,
	11,
	11,
	10,
	10,
	10,
	10,
	10,
	10,
	11,
	11,
	10,
	10,
	10,
	10,
	10,
	10,
	11,
	11,
	10,
	10,
	10,
	10,
	10,
	10,
	11,
	11,
	10,
	10,
	10,
	10,
	10,
	10,
	11,
	11,
	10,
	10,
	10,
	10,
	10,
	10,
	11,
	12,
	11,
	11,
	11,
	11,
	11,
	11,
	12,
}

// Relevant occupancy bits count for each square (Bishop)
BishopBits: [64]int = {
	6,
	5,
	5,
	5,
	5,
	5,
	5,
	6,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	7,
	7,
	7,
	7,
	5,
	5,
	5,
	5,
	7,
	9,
	9,
	7,
	5,
	5,
	5,
	5,
	7,
	9,
	9,
	7,
	5,
	5,
	5,
	5,
	7,
	7,
	7,
	7,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	5,
	6,
	5,
	5,
	5,
	5,
	5,
	5,
	6,
}

// Magic Numbers (These are standard known magics)
// For brevity in this file, I will use a small subset or generate them?
// Actually, hardcoding 128 u64s is messy.
// I will implement a "Magic Finder" that runs on startup.
// It takes <1 second usually.
// This is "robust" because it doesn't rely on copy-pasting magic numbers that might be wrong.
// It finds valid ones for the current hash function.

// Tables
// We need a flat array for the attacks.
// Rook table size: ~102,400 entries (sum of 1<<bits)
// Bishop table size: ~5,248 entries
// We will use dynamic arrays or large fixed arrays.

RookTable: [dynamic]u64
BishopTable: [dynamic]u64

// Magic Entries to store the multiplier and shift for each square
MagicEntry :: struct {
	mask:   u64,
	magic:  u64,
	shift:  int,
	offset: int, // Offset into the global table
}

RookMagics: [64]MagicEntry
BishopMagics: [64]MagicEntry

// --- Initialization ---

init_sliders :: proc() {
	init_magics(true) // Rooks
	init_magics(false) // Bishops
}

// Generate moves for a slider (used during magic generation)
// This is the "slow" version used to populate the table.
get_slider_attacks_slow :: proc(square: int, occupancy: u64, is_rook: bool) -> u64 {
	attacks: u64 = 0

	if is_rook {
		// North
		for r := square + 8; r < 64; r += 8 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
		// South
		for r := square - 8; r >= 0; r -= 8 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
		// East
		for r := square + 1; r % 8 != 0; r += 1 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
		// West
		for r := square - 1; r % 8 != 7 && r >= 0; r -= 1 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
	} else {
		// Bishop
		// NE
		for r := square + 9; r < 64 && (r % 8 != 0); r += 9 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
		// NW
		for r := square + 7; r < 64 && (r % 8 != 7); r += 7 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
		// SE
		for r := square - 7; r >= 0 && (r % 8 != 0); r -= 7 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
		// SW
		for r := square - 9; r >= 0 && (r % 8 != 7); r -= 9 {
			attacks |= (1 << u64(r))
			if (occupancy & (1 << u64(r))) != 0 {break}
		}
	}
	return attacks
}

// Mask relevant occupancy bits for magic generation
// (Edges are not relevant for occupancy because you can't go further anyway)
get_relevant_occupancy_mask :: proc(square: int, is_rook: bool) -> u64 {
	mask: u64 = 0
	r, f: int
	tr := square / 8
	tf := square % 8

	if is_rook {
		// North (stop 1 before edge)
		for r = tr + 1; r < 7; r += 1 {mask |= (1 << u64(r * 8 + tf))}
		// South
		for r = tr - 1; r > 0; r -= 1 {mask |= (1 << u64(r * 8 + tf))}
		// East
		for f = tf + 1; f < 7; f += 1 {mask |= (1 << u64(tr * 8 + f))}
		// West
		for f = tf - 1; f > 0; f -= 1 {mask |= (1 << u64(tr * 8 + f))}
	} else {
		// NE
		for r, f = tr + 1, tf + 1;
		    r < 7 && f < 7;
		    r, f = r + 1, f + 1 {mask |= (1 << u64(r * 8 + f))}
		// NW
		for r, f = tr + 1, tf - 1;
		    r < 7 && f > 0;
		    r, f = r + 1, f - 1 {mask |= (1 << u64(r * 8 + f))}
		// SE
		for r, f = tr - 1, tf + 1;
		    r > 0 && f < 7;
		    r, f = r - 1, f + 1 {mask |= (1 << u64(r * 8 + f))}
		// SW
		for r, f = tr - 1, tf - 1;
		    r > 0 && f > 0;
		    r, f = r - 1, f - 1 {mask |= (1 << u64(r * 8 + f))}
	}
	return mask
}

// Random Number Generator (Xorshift)
rng_state: u64 = 1804289383 // Seed

get_random_u64 :: proc() -> u64 {
	x := rng_state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	rng_state = x
	return x
}

get_random_u64_fewbits :: proc() -> u64 {
	return get_random_u64() & get_random_u64() & get_random_u64()
}

// Initialize Magics
init_magics :: proc(is_rook: bool) {
	// Allocate global table if needed
	// We do this incrementally

	for square in 0 ..< 64 {
		mask := get_relevant_occupancy_mask(square, is_rook)
		bits_count := utils.count_bits(mask)
		permutations := 1 << u64(bits_count)

		// Allocate space in the global table
		offset := 0
		if is_rook {
			offset = len(RookTable)
			resize(&RookTable, len(RookTable) + permutations)
		} else {
			offset = len(BishopTable)
			resize(&BishopTable, len(BishopTable) + permutations)
		}

		// Generate all occupancy variations
		occupancies := make([dynamic]u64, permutations)
		attacks := make([dynamic]u64, permutations)
		defer delete(occupancies)
		defer delete(attacks)

		for i in 0 ..< permutations {
			occupancy: u64 = 0
			// Map index 'i' to the mask bits
			temp_mask := mask
			bit_idx := 0
			for temp_mask != 0 {
				lsb := utils.pop_lsb(&temp_mask)
				if (i & (1 << u64(bit_idx))) != 0 {
					occupancy |= (1 << u64(lsb))
				}
				bit_idx += 1
			}
			occupancies[i] = occupancy
			attacks[i] = get_slider_attacks_slow(square, occupancy, is_rook)
		}

		// Find Magic Number
		found := false
		for !found {
			magic := get_random_u64_fewbits()

			// Verify Magic
			// We need to ensure that (occupancy * magic) >> (64 - bits) maps to a unique index for every distinct attack set.

			// Let's try to fill the table
			table := is_rook ? &RookTable : &BishopTable

			// Clear the part of the table we are using
			// (In a real implementation we use a separate temp table to check)
			used := make([dynamic]u64, permutations)
			defer delete(used)
			// Initialize with a marker (e.g., max u64, but attacks can be anything. Let's use a separate 'visited' array or just clear)
			// Since 0 is a valid attack (no moves), we need a flag.
			// Let's use a 'used' array of bools or similar.
			used_indices := make([dynamic]bool, permutations)
			defer delete(used_indices)

			fail := false

			for i in 0 ..< permutations {
				idx := int((occupancies[i] * magic) >> u64(64 - bits_count))

				if idx >= permutations {fail = true; break} 	// Should not happen if shift is correct

				if used_indices[idx] {
					// Collision!
					// If the attack is the same, it's fine.
					if used[idx] != attacks[i] {
						fail = true
						break
					}
				} else {
					used_indices[idx] = true
					used[idx] = attacks[i]
				}
			}

			if !fail {
				found = true

				// Save the Magic Entry
				entry := MagicEntry {
					mask   = mask,
					magic  = magic,
					shift  = 64 - bits_count,
					offset = offset,
				}

				if is_rook {
					RookMagics[square] = entry
					// Copy used to global table
					for i in 0 ..< permutations {
						idx := int((occupancies[i] * magic) >> u64(64 - bits_count))
						RookTable[offset + idx] = attacks[i]
					}
				} else {
					BishopMagics[square] = entry
					for i in 0 ..< permutations {
						idx := int((occupancies[i] * magic) >> u64(64 - bits_count))
						BishopTable[offset + idx] = attacks[i]
					}
				}
			}
		}
	}
}

// --- Fast Lookups ---

get_rook_attacks :: proc(square: int, occupancy: u64) -> u64 {
	entry := &RookMagics[square]
	occupancy_masked := occupancy & entry.mask
	idx := (occupancy_masked * entry.magic) >> u64(entry.shift)
	return RookTable[entry.offset + int(idx)]
}

get_bishop_attacks :: proc(square: int, occupancy: u64) -> u64 {
	entry := &BishopMagics[square]
	occupancy_masked := occupancy & entry.mask
	idx := (occupancy_masked * entry.magic) >> u64(entry.shift)
	return BishopTable[entry.offset + int(idx)]
}

get_queen_attacks :: proc(square: int, occupancy: u64) -> u64 {
	return get_rook_attacks(square, occupancy) | get_bishop_attacks(square, occupancy)
}

// Move Generation Wrappers (Same as before, but now using fast lookups)

get_rook_moves :: proc(rooks: u64, occupancy: u64, own_pieces: u64, move_list: ^[dynamic]Move) {
	bitboard := rooks
	for bitboard != 0 {
		source := utils.pop_lsb(&bitboard)
		attacks := get_rook_attacks(source, occupancy) & ~own_pieces
		for attacks != 0 {
			target := utils.pop_lsb(&attacks)
			is_capture := (occupancy & (1 << u64(target))) != 0
			append(move_list, create_move(source, target, constants.ROOK, is_capture))
		}
	}
}

get_bishop_moves :: proc(
	bishops: u64,
	occupancy: u64,
	own_pieces: u64,
	move_list: ^[dynamic]Move,
) {
	bitboard := bishops
	for bitboard != 0 {
		source := utils.pop_lsb(&bitboard)
		attacks := get_bishop_attacks(source, occupancy) & ~own_pieces
		for attacks != 0 {
			target := utils.pop_lsb(&attacks)
			is_capture := (occupancy & (1 << u64(target))) != 0
			append(move_list, create_move(source, target, constants.BISHOP, is_capture))
		}
	}
}

get_queen_moves :: proc(queens: u64, occupancy: u64, own_pieces: u64, move_list: ^[dynamic]Move) {
	bitboard := queens
	for bitboard != 0 {
		source := utils.pop_lsb(&bitboard)
		attacks := get_queen_attacks(source, occupancy) & ~own_pieces
		for attacks != 0 {
			target := utils.pop_lsb(&attacks)
			is_capture := (occupancy & (1 << u64(target))) != 0
			append(move_list, create_move(source, target, constants.QUEEN, is_capture))
		}
	}
}
