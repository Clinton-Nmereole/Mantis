package zobrist

import "../constants"
import "../utils"
import "core:math/rand"

// Zobrist Keys
// We need keys for:
// - Pieces (12 types) on Squares (64) = 12 * 64 = 768
// - En Passant Files (8) (We only care about the file, not the rank)
// - Castling Rights (16 combinations)
// - Side to Move (1)

piece_keys: [12][64]u64
en_passant_keys: [64]u64 // We'll map the square index directly for simplicity
castling_keys: [16]u64
side_key: u64

// Initialize Zobrist Keys
init_zobrist :: proc() {
	// Use a fixed seed for reproducibility
	rand.reset(1804289383)

	// Piece Keys
	for p in 0 ..< 12 {
		for s in 0 ..< 64 {
			piece_keys[p][s] = rand.uint64()
		}
	}

	// En Passant Keys
	for s in 0 ..< 64 {
		en_passant_keys[s] = rand.uint64()
	}

	// Castling Keys
	for c in 0 ..< 16 {
		castling_keys[c] = rand.uint64()
	}

	// Side Key
	side_key = rand.uint64()
}
