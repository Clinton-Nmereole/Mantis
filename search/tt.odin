package search

import "../eval"
import "../moves"
import "core:fmt"
import "core:sync"

// Transposition Table Constants
TT_FLAG_EXACT :: 0
TT_FLAG_ALPHA :: 1 // Upper Bound (Fail Low) - Score <= Alpha
TT_FLAG_BETA :: 2 // Lower Bound (Fail High) - Score >= Beta

TTEntry :: struct {
	key:   u64, // Atomic read/write for thread safety
	move:  moves.Move,
	score: int,
	depth: int,
	flag:  u8,
}

// Global Transposition Table
tt: []TTEntry

// Initialize TT
init_tt :: proc(size_mb: int) {
	// Calculate number of entries
	entry_size := size_of(TTEntry)
	count := (size_mb * 1024 * 1024) / entry_size

	if len(tt) > 0 {
		delete(tt)
	}

	tt = make([]TTEntry, count)
	clear_tt()
	fmt.printf("Transposition Table Initialized: %d MB, %d Entries\n", size_mb, count)
}

// Clear TT
clear_tt :: proc() {
	for i in 0 ..< len(tt) {
		tt[i] = TTEntry{}
	}
}

// Probe TT
// Returns: score, found
probe_tt :: proc(key: u64, alpha: int, beta: int, depth: int) -> (int, bool) {
	if len(tt) == 0 {return 0, false}

	index := key % u64(len(tt))
	entry := &tt[index]

	// Atomic key read for thread safety
	entry_key := sync.atomic_load(&entry.key)

	if entry_key == key {
		if entry.depth >= depth {
			if entry.flag == TT_FLAG_EXACT {
				return entry.score, true
			}
			if entry.flag == TT_FLAG_ALPHA && entry.score <= alpha {
				return alpha, true
			}
			if entry.flag == TT_FLAG_BETA && entry.score >= beta {
				return beta, true
			}
		}
	}

	return 0, false
}

// Get TT Move (for move ordering)
get_tt_move :: proc(key: u64) -> moves.Move {
	if len(tt) == 0 {return moves.Move{}}

	index := key % u64(len(tt))
	entry := &tt[index]

	// Atomic key read for thread safety
	entry_key := sync.atomic_load(&entry.key)

	if entry_key == key {
		return entry.move
	}

	return moves.Move{} // Empty move
}

// Store TT
store_tt :: proc(key: u64, move: moves.Move, score: int, depth: int, flag: u8) {
	if len(tt) == 0 {return}

	index := key % u64(len(tt))
	entry := &tt[index]

	// Replacement Scheme: Don't replace much deeper entries
	// Atomic key read to check existing entry
	old_key := sync.atomic_load(&entry.key)
	if old_key != 0 && old_key != key && entry.depth > depth + 2 {
		return // Keep deeper entry
	}

	// Write entry data first
	entry.move = move
	entry.score = score
	entry.depth = depth
	entry.flag = flag

	// Write key atomically last - this "publishes" the entry
	// Other threads checking the key will see complete data
	sync.atomic_store(&entry.key, key)
}
