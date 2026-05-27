package search

import "../eval"
import "../moves"
import "core:fmt"
import "core:sync"

// Transposition Table Constants
TT_FLAG_EXACT :: 0
TT_FLAG_ALPHA :: 1 // Upper Bound (Fail Low) - Score <= Alpha
TT_FLAG_BETA :: 2 // Lower Bound (Fail High) - Score >= Beta

// TT Entry
// Each bucket holds 2 entries.  The key is written atomically last so that
// a matching key read by another thread implies the rest of the fields are
// valid (they were written before the key was published).
TTEntry :: struct {
	key:   u64,        // Atomic read/write for thread safety
	move:  moves.Move,
	score: int,
	depth: int,
	flag:  u8,
	age:   u8,         // Search generation — helps replacement pick stale entries
}

// TT Bucket — 2 entries per hash slot.
// Entry 0: depth-preferred slot
// Entry 1: always-replace slot (filled only when 0 is occupied by deeper data)
// In practice the replacement algorithm below treats both symmetrically.
TTBucket :: struct {
	entries: [2]TTEntry,
}

// Global Transposition Table
tt: []TTBucket

// Current search generation (age).  Incremented on ucinewgame.
tt_age: u8 = 0

// Increment age so that entries from previous games are considered stale.
// Called by ucinewgame (and optionally after very long searches to freshen the table).
increment_tt_age :: proc() {
	tt_age += 1
	if tt_age == 0 {
		// Wrap-around: if we ever hit 0 again, everything would look fresh.
		// In practice 255 games between clears is enough, but be safe and
		// clear the table on wrap.
		clear_tt()
		tt_age = 1
	}
}

// Initialize TT
init_tt :: proc(size_mb: int) {
	bucket_size := size_of(TTBucket)
	count := (size_mb * 1024 * 1024) / bucket_size

	if count < 1 { count = 1 }

	if len(tt) > 0 {
		delete(tt)
	}

	tt = make([]TTBucket, count)
	clear_tt()
	fmt.printf("Transposition Table Initialized: %d MB, %d Buckets (%d Entries)\n",
		   size_mb, count, count * 2)
}

// Clear TT
clear_tt :: proc() {
	for i in 0 ..< len(tt) {
		tt[i] = TTBucket{}
	}
}

// Mate-score helpers — adjust mate distance for the ply we are at.
// A mate score stored at ply 5 must be shifted when read at ply 2.
score_to_tt :: proc(score: int, ply: int) -> int {
	if score >= eval.MATE - MAX_PLY {
		return score + ply
	}
	if score <= -eval.MATE + MAX_PLY {
		return score - ply
	}
	return score
}

score_from_tt :: proc(score: int, ply: int) -> int {
	if score >= eval.MATE - MAX_PLY {
		return score - ply
	}
	if score <= -eval.MATE + MAX_PLY {
		return score + ply
	}
	return score
}

// Probe TT
// Returns: score, found
probe_tt :: proc(key: u64, alpha: int, beta: int, depth: int, ply: int) -> (int, bool) {
	if len(tt) == 0 { return 0, false }
	stat_add(&search_stats.tt_probes)

	index := key % u64(len(tt))
	bucket := &tt[index]

	for i in 0 ..< 2 {
		entry := &bucket.entries[i]
		entry_key := sync.atomic_load(&entry.key)

		if entry_key == key && entry.depth >= depth {
			stat_add(&search_stats.tt_hits)
			score := score_from_tt(entry.score, ply)
			#no_bounds_check {
				if entry.flag == TT_FLAG_EXACT {
					return score, true
				}
				if entry.flag == TT_FLAG_ALPHA && score <= alpha {
					return alpha, true
				}
				if entry.flag == TT_FLAG_BETA && score >= beta {
					return beta, true
				}
			}
		}
	}

	return 0, false
}

// Validate that a TT move has sensible coordinates
is_valid_tt_move :: proc(move: moves.Move) -> bool {
	if moves.is_empty_move(move) {return false}
	if move.source < 0 || move.source > 63 {return false}
	if move.target < 0 || move.target > 63 {return false}
	if move.piece < 0 || move.piece > 11 {return false}
	return true
}

// Get TT Move (for move ordering)
// Scans both entries and returns the move from the deeper one when both match.
get_tt_move :: proc(key: u64) -> moves.Move {
	if len(tt) == 0 { return moves.Move{} }

	index := key % u64(len(tt))
	bucket := &tt[index]

	best_move := moves.Move{}
	best_depth := -1

	for i in 0 ..< 2 {
		entry := &bucket.entries[i]
		entry_key := sync.atomic_load(&entry.key)

		if entry_key == key && entry.depth > best_depth {
			if is_valid_tt_move(entry.move) {
				best_depth = entry.depth
				best_move = entry.move
			}
		}
	}

	return best_move
}

// Store TT
// Replacement strategy:
//  1. If key matches an existing entry, overwrite that entry (preserves the slot).
//  2. Otherwise pick the entry that is easiest to replace:
//     - Prefer stale age (entry.age != tt_age)
//     - Within same age, prefer lower depth
//     - If still tied, prefer entry[1] (always-replace slot)
store_tt :: proc(key: u64, move: moves.Move, score: int, depth: int, flag: u8, ply: int) {
	if len(tt) == 0 { return }
	stat_add(&search_stats.tt_stores)

	index := key % u64(len(tt))
	bucket := &tt[index]

	// Convert mate score for storage
	tt_score := score_to_tt(score, ply)

	// First: try to overwrite an entry with the same key
	for i in 0 ..< 2 {
		entry := &bucket.entries[i]
		old_key := sync.atomic_load(&entry.key)
		if old_key == key {
			// Overwrite same-key entry.  Keep the existing move if the new
			// move is empty and the old one isn't — this is common when we
			// re-store a position after a fail-high with no best move yet.
			best_move := move
			if moves.is_empty_move(best_move) && !moves.is_empty_move(entry.move) {
				best_move = entry.move
			}

			entry.move  = best_move
			entry.score = tt_score
			entry.depth = depth
			entry.flag  = flag
			entry.age   = tt_age
			sync.atomic_store(&entry.key, key)
			return
		}
	}

	// No key match — pick the replacement target
	replace_idx := 0
	for i in 1 ..< 2 {
		entry      := &bucket.entries[i]
		candidate  := &bucket.entries[replace_idx]

		// Prefer stale age
		if entry.age != tt_age && candidate.age == tt_age {
			replace_idx = i
			continue
		}
		if candidate.age != tt_age && entry.age == tt_age {
			continue
		}

		// Same age (or both stale): prefer lower depth
		if entry.depth < candidate.depth {
			replace_idx = i
		}
	}

	// Write the chosen entry (data first, key last)
	entry := &bucket.entries[replace_idx]
	entry.move  = move
	entry.score = tt_score
	entry.depth = depth
	entry.flag  = flag
	entry.age   = tt_age
	sync.atomic_store(&entry.key, key)
}
