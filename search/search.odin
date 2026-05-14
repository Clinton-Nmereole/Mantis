package search

import "../board"
import "../constants"
import "../eval"
import "../moves"
import "../nnue"
import "../tb"
import "../zobrist"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:time"

// Search Constants
MAX_PLY :: 64

// LMR Table — precomputed logarithmic reductions
lmr_table: [64][64]int

// Initialize LMR table (call once at startup)
init_lmr_table :: proc() {
	for d in 1 ..< 64 {
		for m in 1 ..< 64 {
			// Stockfish-like formula: ln(depth) * ln(move_count) / 1.5
			lmr_table[d][m] = int(math.ln(f64(d)) * math.ln(f64(m)) / 1.5 + 0.5)
		}
	}
}

// Search Control - for ponder and stop functionality
// Using i32 for atomic operations (Odin doesn't support atomic_bool directly)
Search_Control :: struct {
	should_stop:         i32, // Set to 1 to stop search immediately
	ponder_mode:         i32, // Set to 1 if searching in ponder mode (infinite time)
	ponderhit_triggered: i32, // Set to 1 when ponderhit received during pondering
}

search_control: Search_Control

// Reset search control for new search
reset_search_control :: proc() {
	sync.atomic_store(&search_control.should_stop, i32(0))
	sync.atomic_store(&search_control.ponder_mode, i32(0))
	sync.atomic_store(&search_control.ponderhit_triggered, i32(0))
}

// Check if search should stop
should_stop_search :: proc() -> bool {
	return sync.atomic_load(&search_control.should_stop) != 0
}

// Signal search to stop
stop_search :: proc() {
	sync.atomic_store(&search_control.should_stop, i32(1))
}


// PV Line Structure
PV_Line :: struct {
	moves: [MAX_PLY]moves.Move,
	count: int,
}

// MultiPV Result - stores move, score, and PV for each line
MultiPV_Result :: struct {
	move:  moves.Move,
	score: int,
	pv:    PV_Line,
}


// Thread-local search state
SearchThread :: struct {
	thread_id:            int,
	nodes:                u64,
	killer_moves:         [MAX_PLY][2]moves.Move,
	history_table:        [12][64]int,
	counter_moves:        [12][64]moves.Move,
	continuation_history: ^[6][64][6][64]int,
	static_eval_stack:    [MAX_PLY]int,
}

// Global atomic node counter for UCI reporting
total_nodes: u64 = 0

// Initialize a SearchThread
init_search_thread :: proc(st: ^SearchThread, id: int) {
	st.thread_id = id
	st.nodes = 0
	clear_killers(st)
	clear_history(st)
	clear_counter_moves(st)
	init_continuation_history(st)
}

// Store a killer move
store_killer :: proc(st: ^SearchThread, move: moves.Move, ply: int) {
	if ply < 0 || ply >= MAX_PLY {return}

	// If not already primary killer
	if st.killer_moves[ply][0].source != move.source || st.killer_moves[ply][0].target != move.target {
		// Shift primary to secondary
		st.killer_moves[ply][1] = st.killer_moves[ply][0]
		// New move becomes primary
		st.killer_moves[ply][0] = move
	}
}

// Check if move is killer (returns 1 for primary, 2 for secondary, 0 otherwise)
is_killer :: proc(st: ^SearchThread, move: moves.Move, ply: int) -> int {
	if ply < 0 || ply >= MAX_PLY {return 0}

	if st.killer_moves[ply][0].source == move.source && st.killer_moves[ply][0].target == move.target {
		return 1 // Primary killer
	}
	if st.killer_moves[ply][1].source == move.source && st.killer_moves[ply][1].target == move.target {
		return 2 // Secondary killer
	}
	return 0 // Not a killer
}

// Clear all killer moves
clear_killers :: proc(st: ^SearchThread) {
	for i in 0 ..< MAX_PLY {
		st.killer_moves[i][0] = moves.Move{}
		st.killer_moves[i][1] = moves.Move{}
	}
}

// Update history with result (positive for cutoffs, negative for fails)
update_history :: proc(st: ^SearchThread, move: moves.Move, depth: int, good: bool) {
	// Bonus based on depth (deeper searches = more important)
	bonus := depth * depth
	if !good {
		bonus = -bonus // Penalize moves that don't cause cutoffs
	}

	st.history_table[move.piece][move.target] += bonus

	// Cap to prevent overflow
	if st.history_table[move.piece][move.target] > params.history_max {
		st.history_table[move.piece][move.target] = params.history_max
	}
	if st.history_table[move.piece][move.target] < params.history_min {
		st.history_table[move.piece][move.target] = params.history_min
	}
}

// Age history scores (called periodically to decay old information)
age_history :: proc(st: ^SearchThread) {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			// Reduce by configured ratio to favor recent information
			st.history_table[i][j] = st.history_table[i][j] * params.history_decay_numer / params.history_decay_denom
		}
	}
}

// Get history score for a move
get_history_score :: proc(st: ^SearchThread, move: moves.Move) -> int {
	return st.history_table[move.piece][move.target]
}

// Clear history table
clear_history :: proc(st: ^SearchThread) {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			st.history_table[i][j] = 0
		}
	}
}

// Store a counter move (the refutation to the previous move)
store_counter_move :: proc(st: ^SearchThread, prev_move: moves.Move, refutation: moves.Move) {
	// Bounds checking
	if prev_move.piece < 0 || prev_move.piece >= 12 {return}
	if prev_move.target < 0 || prev_move.target >= 64 {return}

	st.counter_moves[prev_move.piece][prev_move.target] = refutation
}

// Get the counter move for a given move
get_counter_move :: proc(st: ^SearchThread, prev_move: moves.Move) -> moves.Move {
	// Bounds checking
	if prev_move.piece < 0 || prev_move.piece >= 12 {return moves.Move{}}
	if prev_move.target < 0 || prev_move.target >= 64 {return moves.Move{}}

	return st.counter_moves[prev_move.piece][prev_move.target]
}

// Clear all counter moves
clear_counter_moves :: proc(st: ^SearchThread) {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			st.counter_moves[i][j] = moves.Move{}
		}
	}
}

// Initialize continuation history
init_continuation_history :: proc(st: ^SearchThread) {
	if st.continuation_history == nil {
		st.continuation_history = new([6][64][6][64]int)
	}
	// Zero-initialize
	for i in 0 ..< 6 {
		for j in 0 ..< 64 {
			for k in 0 ..< 6 {
				for l in 0 ..< 64 {
					st.continuation_history[i][j][k][l] = 0
				}
			}
		}
	}
}

// Store continuation history score
store_continuation :: proc(st: ^SearchThread, prev_move: moves.Move, curr_move: moves.Move, depth: int, good: bool) {
	// CRITICAL: Extensive bounds checking
	if st.continuation_history == nil {return}
	if prev_move.piece < 0 || prev_move.piece >= 12 {return}
	if curr_move.piece < 0 || curr_move.piece >= 12 {return}
	if prev_move.target < 0 || prev_move.target >= 64 {return}
	if curr_move.target < 0 || curr_move.target >= 64 {return}

	// Get piece types (strip color)
	prev_type := prev_move.piece % 6
	curr_type := curr_move.piece % 6

	// Bonus based on depth
	bonus := depth * depth
	if !good {
		bonus = -bonus
	}

	// Update with clamping
	old_val := st.continuation_history[prev_type][prev_move.target][curr_type][curr_move.target]
	new_val := old_val + bonus

	// Clamp to prevent overflow
	if new_val > params.history_max {new_val = params.history_max}
	if new_val < params.history_min {new_val = params.history_min}

	st.continuation_history[prev_type][prev_move.target][curr_type][curr_move.target] = new_val
}

// Get continuation history score
get_continuation_score :: proc(st: ^SearchThread, prev_move: moves.Move, curr_move: moves.Move) -> int {
	// CRITICAL: Extensive bounds checking
	if st.continuation_history == nil {return 0}
	if prev_move.piece < 0 || prev_move.piece >= 12 {return 0}
	if curr_move.piece < 0 || curr_move.piece >= 12 {return 0}
	if prev_move.target < 0 || prev_move.target >= 64 {return 0}
	if curr_move.target < 0 || curr_move.target >= 64 {return 0}

	prev_type := prev_move.piece % 6
	curr_type := curr_move.piece % 6

	return st.continuation_history[prev_type][prev_move.target][curr_type][curr_move.target]
}

// Count nodes and periodically update global atomic counter
 count_nodes :: proc(st: ^SearchThread) {
	st.nodes += 1
	if st.nodes % 1024 == 0 {
		sync.atomic_add(&total_nodes, 1024)
	}
}

// Get total nodes searched across all threads
get_total_nodes :: proc() -> u64 {
	return sync.atomic_load(&total_nodes)
}

// Negamax Alpha-Beta Search
negamax :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	alpha: int,
	beta: int,
	depth: int,
	ply: int,
	pv_line: ^PV_Line,
	excluded_move: moves.Move = moves.Move{}, // For singular extensions
	is_pv: bool = true, // Is this a PV node?
	prev_move: moves.Move = moves.Move{}, // Previous move for counter-moves
) -> int {
	count_nodes(st)

	// TT Probe
	tt_score, tt_hit := probe_tt(b.hash, alpha, beta, depth, ply)
	if tt_hit {
		return tt_score
	}

	// Syzygy WDL Probe (during search, for exact endgame scores)
	if !is_pv && depth >= 1 {
		tb_score, tb_hit := tb.probe_wdl(b)
		if tb_hit {
			return tb_score
		}
	}

	// Periodic stop check (every 1024 nodes) - for ponder/stop functionality
	if st.nodes % 1024 == 0 {
		if should_stop_search() {
			return alpha // Exit immediately if stop requested
		}
	}

	// Periodic time check (every 1024 nodes)
	if use_time_management && st.nodes % 1024 == 0 {
		if should_stop(search_limits) {
			return alpha // Exit early with fail-low
		}
	}

	// Check if in check (used by multiple features)
	king_sq := board.get_king_square(b, b.side)
	in_check := board.is_square_attacked(b, king_sq, 1 - b.side)

	// Check Extension - extend if in check at frontier
	// Limited to prevent excessive searching
	effective_depth := depth
	if depth == 0 {
		if in_check && ply < params.check_ext_max_ply {	// Don't extend too deep in search
			effective_depth = 1 // Extend by 1 ply when in check
		} else {
			return quiescence(st, b, alpha, beta)
		}
	}

	// Compute static evaluation once and cache it for improving heuristic
	static_eval := eval.evaluate(b)
	st.static_eval_stack[ply] = static_eval

	improving := false
	if ply >= 2 {
		improving = static_eval > st.static_eval_stack[ply - 2]
	}

	// Razoring - drop into quiescence if position is hopeless
	if !is_pv && !in_check && depth <= params.razor_max_depth {
		razor_margin := params.razor_margin * depth
		if static_eval + razor_margin < alpha {
			// Position is so bad even with margin, just do quiescence
			qscore := quiescence(st, b, alpha, beta)
			if qscore < alpha {
				return qscore
			}
		}
	}

	// Null Move Pruning
	// Apply null move if:
	// 1. Not in PV node (use is_pv flag)
	// 2. Not in check
	// 3. Deep enough
	can_null_move := !is_pv && !in_check && depth >= params.nmp_min_depth

	if can_null_move {
		// Make null move
		null_board := b^
		null_board.side = 1 - null_board.side

		// Update hash
		null_board.hash ~= zobrist.side_key
		if b.en_passant != -1 {
			null_board.hash ~= zobrist.en_passant_keys[b.en_passant]
		}
		null_board.en_passant = -1

		// Adaptive reduction - more aggressive at deeper depths
		nmp_reduction := params.nmp_reduction_base + effective_depth / params.nmp_reduction_div

		// Search null move at reduced depth
		null_pv: PV_Line
		null_score := -negamax(
			st,
			&null_board,
			-beta,
			-beta + 1,
			effective_depth - 1 - nmp_reduction,
			ply + 1,
			&null_pv,
			{}, // no excluded move
			false, // not PV
		)

		// If null move fails high, prune
		if null_score >= beta {
			return beta
		}
	}

	// Reverse Futility Pruning (RFP) / Static Null Move Pruning
	// If position is so good that even with a margin, we're above beta, prune
	if !is_pv && !in_check && effective_depth <= params.rfp_depth && excluded_move.source == 0 {
		// Margin based on depth
		rfp_margin := params.rfp_margin * effective_depth

		if static_eval - rfp_margin >= beta {
			return static_eval - rfp_margin
		}
	}

	// TT Move (for probcut and move ordering)
	// Fetch early so probcut can use it for sorting tactical moves.
	tt_move := get_tt_move(b.hash)

	// Probcut
	// If the position is good enough that even a reduced-depth tactical search
	// would fail high, we can prune safely.
	if !is_pv && !in_check && effective_depth >= params.probcut_depth &&
	   abs(beta) < eval.MATE && excluded_move.source == 0 {
		probcut_beta := beta + params.probcut_margin
		if static_eval >= probcut_beta {
			// Try a few tactical moves at reduced depth
			tactical_list: moves.MoveList
			board.generate_all_moves(b, &tactical_list)
			sort_moves(st, &tactical_list, b, tt_move, ply, prev_move)

			for j in 0 ..< tactical_list.count {
				if !tactical_list.moves[j].capture && tactical_list.moves[j].promoted == -1 {
					continue
				}

				t_state: board.StateInfo
				board.make_move_fast(b, tactical_list.moves[j], &t_state)

				king_sq := board.get_king_square(b, 1 - b.side)
				if board.is_square_attacked(b, king_sq, b.side) {
					board.unmake_move(b, &t_state)
					continue
				}

				nnue.update_accumulators(&t_state, b, tactical_list.moves[j])
				probcut_score := -negamax(
					st,
					b,
					-probcut_beta,
					-probcut_beta + 1,
					effective_depth - params.probcut_reduce,
					ply + 1,
					&PV_Line{},
					{},
					false,
					tactical_list.moves[j],
				)
				board.unmake_move(b, &t_state)

				if probcut_score >= probcut_beta {
					return probcut_beta
				}
			}
		}
	}

	// Move Generation
	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated

	board.generate_all_moves(b, &move_list)

	// Internal Iterative Reduction (IIR)
	// If we have no hash move and this is a PV node, reduce depth
	// We don't know what's good here, so search shallower first
	if tt_move.source == 0 && is_pv && effective_depth >= params.iir_min_depth {
		effective_depth -= 1
	}

	// Move Ordering
	sort_moves(st, &move_list, b, tt_move, ply, prev_move)

	// Singular Extensions
	// Test if TT move is "singularly" better than all alternatives
	extension := 0

	if depth >= params.se_depth &&
	   !in_check &&
	   ply > 0 &&
	   tt_move.source != 0 &&
	   excluded_move.source == 0 {	// Don't do SE during SE search

		// Get TT score for singular test
		tt_entry_score, tt_found := probe_tt(b.hash, alpha, beta, depth, ply)

		if tt_found {
			// Singular beta - margin based on depth
			singular_beta := tt_entry_score - depth * params.se_margin

			// Reduced depth for singular search
			reduced_depth := depth / params.se_reduced_div

			// Search all moves EXCEPT TT move
			child_pv: PV_Line
			singular_score := negamax(
				st,
				b,
				singular_beta - 1,
				singular_beta,
				reduced_depth,
				ply,
				&child_pv,
				excluded_move = tt_move, // Exclude TT move
			)

			// If all other moves fail low, TT move is singular
			if singular_score < singular_beta {
				extension = 1
			}
		}
	}

	legal_moves := 0
	best_score := -eval.INF
	current_alpha := alpha
	best_move: moves.Move

	// Futility Pruning - pre-compute for move loop
	do_futility := false
	futility_value := 0
	if !is_pv && !in_check && depth <= params.futility_max_depth {
		futility_margin := params.futility_margin * depth
		futility_value = eval.evaluate(b) + futility_margin
		if futility_value < alpha {
			do_futility = true
		}
	}

	// Late Move Pruning (LMP)
	// Skip quiet moves beyond a certain threshold.
	// The idea: if we've searched the best moves and none raised alpha,
	// the remaining quiet moves are unlikely to help.
	lmp_threshold := 9999 // Default: effectively disabled
	if !is_pv && !in_check && depth <= params.lmp_max_depth {
		// Threshold grows with depth: deeper = search more moves
		lmp_threshold = params.lmp_base + depth * depth / params.lmp_div
	}

	for i in 0 ..< move_list.count {
		// Skip excluded move (for singular extensions)
		if excluded_move.source != 0 &&
		   move_list.moves[i].source == excluded_move.source &&
		   move_list.moves[i].target == excluded_move.target {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move_list.moves[i], &state)

		// Check legality: king of side that moved must not be in check
		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			continue
		}

		// Update NNUE Accumulators (state holds the old board for reference)
		nnue.update_accumulators(&state, b, move_list.moves[i])

		// Late Move Pruning (LMP)
		// Skip quiet moves that are late in the move list.
		// Only prune if we've already searched enough moves without finding a good one.
		if !is_pv && !in_check && legal_moves >= lmp_threshold &&
		   !move_list.moves[i].capture && move_list.moves[i].promoted == -1 {
			board.unmake_move(b, &state)
			continue
		}

		// Futility Pruning - skip quiet moves that can't raise alpha
		if do_futility && legal_moves > 0 && !move_list.moves[i].capture && move_list.moves[i].promoted == -1 {
			board.unmake_move(b, &state)
			continue
		}

		child_pv: PV_Line
		score := 0

		// Combine check extension with singular extension
		combined_depth := effective_depth + extension

		if legal_moves == 0 {
			// First move (PV node): Full window search
			score = -negamax(
				st,
				b,
				-beta,
				-current_alpha,
				combined_depth - 1,
				ply + 1,
				&child_pv,
				{}, // no excluded move
				true, // is PV
				move_list.moves[i], // prev_move for counter-moves
			)
		} else {
			// Subsequent moves: PVS with LMR

			// Late Move Reductions (LMR)
			// Use precomputed table + standard adjustments.
			reduction := 0

			if combined_depth >= params.lmr_min_depth &&
			   !move_list.moves[i].capture &&
			   move_list.moves[i].promoted == -1 {
				// Base reduction from precomputed logarithmic table
				d_idx := combined_depth
				if d_idx > 63 { d_idx = 63 }
				m_idx := legal_moves
				if m_idx > 63 { m_idx = 63 }
				reduction = lmr_table[d_idx][m_idx]

				// Reduce less when position is improving
				if improving {
					reduction += params.lmr_improving_adj
				}

				// History-based adjustment
				history_score := get_history_score(st, move_list.moves[i])
				if history_score > params.lmr_history_good_thresh {
					reduction += params.lmr_history_good_adj
				} else if history_score < params.lmr_history_bad_thresh {
					reduction += params.lmr_history_bad_adj
				}

				// Clamp: never reduce below 0, never into quiescence
				if reduction < 0 { reduction = 0 }
				if reduction > combined_depth - 2 { reduction = combined_depth - 2 }
			}

			// Null window search with reduction
			score = -negamax(
				st,
				b,
				-current_alpha - 1,
				-current_alpha,
				combined_depth - 1 - reduction,
				ply + 1,
				&child_pv,
				{}, // no excluded move
				false, // not PV (null window)
				move_list.moves[i], // prev_move for counter-moves
			)

			// Re-search if reduced search raised alpha
			if score > current_alpha && reduction > 0 {
				// Re-search at full depth with null window
				score = -negamax(
					st,
					b,
					-current_alpha - 1,
					-current_alpha,
					combined_depth - 1,
					ply + 1,
					&child_pv,
					{}, // no excluded move
					false, // not PV (null window)
					move_list.moves[i], // prev_move for counter-moves
				)
			}

			// Re-search if within bounds (PVS)
			if score > current_alpha && score < beta {
				score = -negamax(
					st,
					b,
					-beta,
					-current_alpha,
					combined_depth - 1,
					ply + 1,
					&child_pv,
					{}, // no excluded move
					true, // is PV
					move_list.moves[i], // prev_move for counter-moves
				)
			}
		}

		board.unmake_move(b, &state)
		legal_moves += 1

		if score > best_score {
			best_score = score
			best_move = move_list.moves[i]
			// Update PV
			pv_line.moves[0] = move_list.moves[i]
			for i in 0 ..< child_pv.count {
				pv_line.moves[i + 1] = child_pv.moves[i]
			}
			pv_line.count = child_pv.count + 1
		}

		if score > current_alpha {
			current_alpha = score
		}

		if current_alpha >= beta {
			// Beta Cutoff - store killer, history, and counter move for quiet moves
			if !move_list.moves[i].capture && move_list.moves[i].promoted == -1 {
				store_killer(st, move_list.moves[i], ply)
				update_history(st, move_list.moves[i], effective_depth, true)

				// Store as counter move if we have a previous move
				if prev_move.source != 0 {
					store_counter_move(st, prev_move, move_list.moves[i])

					// Continuation history - DISABLED (caused regression)
					// store_continuation(st, prev_move, move, effective_depth, true)
				}
			}
			break
		}
	}

	// Checkmate / Stalemate Detection
	if legal_moves == 0 {
		// If in check -> Checkmate
		// We need `is_in_check`.
		// Let's use `is_square_attacked` on King.
		king_sq := board.get_king_square(b, b.side)
		if board.is_square_attacked(b, king_sq, 1 - b.side) {
			return -eval.MATE + (MAX_PLY - depth) // Prefer shorter mates
		} else {
			return 0 // Stalemate
		}
	}

	// TT Store
	flag: u8 = TT_FLAG_EXACT
	if best_score <= alpha {
		flag = TT_FLAG_ALPHA
	} else if best_score >= beta {
		flag = TT_FLAG_BETA
	}

	store_tt(b.hash, best_move, best_score, depth, flag, ply)

	return best_score
}

// Simplified Static Exchange Evaluation
// Returns estimated material balance for a capture
// Negative = losing capture, Positive = winning capture
see_capture :: proc(b: ^board.Board, move: moves.Move) -> int {
	// Get victim value
	victim_value := 0
	if move.en_passant {
		victim_value = constants.PIECE_VALUES[constants.PAWN]
	} else {
		// Find captured piece
		victim_idx := b.mailbox[move.target]
		if victim_idx != -1 {
			victim_piece := victim_idx % 6
			victim_value = constants.PIECE_VALUES[victim_piece]
		}
	}

	// Get attacker value
	attacker_piece := move.piece % 6
	attacker_value := constants.PIECE_VALUES[attacker_piece]

	// Simple SEE: If target is defended, assume we lose our attacker
	if board.is_square_attacked(b, move.target, 1 - b.side) {
		return victim_value - attacker_value
	}

	// Free capture
	return victim_value
}

// Quiescence Search
quiescence :: proc(st: ^SearchThread, b: ^board.Board, alpha: int, beta: int) -> int {
	count_nodes(st)

	evaluation := eval.evaluate(b)

	if evaluation >= beta {
		return beta
	}

	current_alpha := alpha
	if evaluation > current_alpha {
		current_alpha = evaluation
	}

	// Delta Pruning
	// If even capturing a queen won't raise alpha, stop searching.
	// Delta = maximum material gain from a single capture.
	if current_alpha + params.delta_pruning_margin < alpha {
		return current_alpha
	}

	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated
	board.generate_all_moves(b, &move_list)

	// Move Ordering for Quiescence
	sort_moves(st, &move_list, b)

	for i in 0 ..< move_list.count {
		if move_list.moves[i].capture {
			// SEE Pruning - skip obviously losing captures
			// Conservative threshold: only skip if we lose more than a pawn
			see_score := see_capture(b, move_list.moves[i])
			if see_score < params.see_prune_threshold {
				continue // Skip this losing capture
			}

			state: board.StateInfo
			board.make_move_fast(b, move_list.moves[i], &state)

			// Check legality
			king_sq := board.get_king_square(b, 1 - b.side)
			if board.is_square_attacked(b, king_sq, b.side) {
				board.unmake_move(b, &state)
				continue
			}

			nnue.update_accumulators(&state, b, move_list.moves[i])
			score := -quiescence(st, b, -beta, -current_alpha)

			board.unmake_move(b, &state)

			if score >= beta {
				return beta
			}
			if score > current_alpha {
				current_alpha = score
			}
		}
	}

	return current_alpha
}

// Root Search
search_position :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	depth: int,
	multi_pv_count: int = 1,
	output_bestmove: bool = true,
) {
	// fmt.println("DEBUG: Entering search_position")
	st.nodes = 0
	clear_killers(st) // Clear killer moves for new search
	clear_history(st) // Clear history table for new search
	clear_counter_moves(st) // Clear counter moves for new search
	init_continuation_history(st) // Initialize continuation history
	// fmt.printf("DEBUG: NNUE Initialized: %v\n", nnue.is_initialized)
	// os.flush(os.stdout)
	best_move: moves.Move
	best_pv: PV_Line // Store the best PV line

	// Syzygy root probe — if position is in TB, return immediately
	if output_bestmove {
		tb_score, tb_move, tb_hit := tb.probe_root(b)
		if tb_hit {
			fmt.printf("info depth 1 score cp %d nodes 0 time 0 nps 0 pv ", tb_score)
			board.print_move(tb_move)
			fmt.println()
			fmt.printf("bestmove ")
			board.print_move(tb_move)
			fmt.printf("\n")
			os.flush(os.stdout)
			return
		}
	}

	start_time := time.now()

	// Aspiration Windows - narrower for faster convergence
	prev_score := 0

	// MultiPV storage - track best N moves
	multi_pv_results: [dynamic]MultiPV_Result
	defer delete(multi_pv_results)

	// Iterative Deepening
	for current_depth in 1 ..= depth {
		// fmt.printf("DEBUG: Starting depth %d\n", current_depth)

		// Clear MultiPV results for this depth
		clear(&multi_pv_results)

		// Generate all root moves once
		all_moves: moves.MoveList
		// deferred delete removed: MoveList is stack-allocated
		board.generate_all_moves(b, &all_moves)

		// Track which moves have been searched for MultiPV
		excluded_moves: [dynamic]moves.Move
		defer delete(excluded_moves)

		// Search each PV line
		pv_lines_to_search := multi_pv_count
		if pv_lines_to_search > all_moves.count {
			pv_lines_to_search = all_moves.count
		}

		for pv_index in 0 ..< pv_lines_to_search {
			root_pv: PV_Line
			alpha := -eval.INF
			beta := eval.INF

			// Use aspiration windows for depth >= 4 (was 5) and first PV only
			if current_depth >= 4 && pv_index == 0 {
				alpha = prev_score - params.aspiration_window
				beta = prev_score + params.aspiration_window
			}

			// Create move list excluding previously found PVs
			move_list: moves.MoveList
			// deferred delete removed: MoveList is stack-allocated

			for i in 0 ..< all_moves.count {
				// Check if this move is in excluded list
				is_excluded := false
				for j in 0 ..< len(excluded_moves) {
					if all_moves.moves[i].source == excluded_moves[j].source &&
					   all_moves.moves[i].target == excluded_moves[j].target &&
					   all_moves.moves[i].promoted == excluded_moves[j].promoted {
						is_excluded = true
						break
					}
				}
				if !is_excluded {
					moves.append_move(&move_list, all_moves.moves[i])
				}
			}

			if move_list.count == 0 {
				break // No more moves to search
			}

			best_score := -eval.INF
			current_best_move: moves.Move
			found_move := false

			current_alpha := alpha

			for i in 0 ..< move_list.count {
				state: board.StateInfo
				board.make_move_fast(b, move_list.moves[i], &state)

				// Check legality
				king_sq := board.get_king_square(b, 1 - b.side)
				if board.is_square_attacked(b, king_sq, b.side) {
					board.unmake_move(b, &state)
					continue
				}

				nnue.update_accumulators(&state, b, move_list.moves[i])

				child_pv: PV_Line
				score := -negamax(
					st,
					b,
					-beta,
					-current_alpha,
					current_depth - 1,
					0,
					&child_pv,
				)

				board.unmake_move(b, &state)

				if score > best_score {
					best_score = score
					current_best_move = move_list.moves[i]
					found_move = true

					// Update best PV line
					best_pv.moves[0] = move_list.moves[i]
					for i in 0 ..< child_pv.count {
						best_pv.moves[i + 1] = child_pv.moves[i]
					}
					best_pv.count = child_pv.count + 1
				}

				if score > current_alpha {
					current_alpha = score
				}
			}

			// Re-search if outside aspiration window (first PV only)
			if current_depth >= 5 && pv_index == 0 {
				if best_score <= alpha {
					// Failed low - re-search with lower bound
					alpha = -eval.INF
					best_score = -eval.INF
					current_alpha = alpha

					for i in 0 ..< move_list.count {
						state: board.StateInfo
						board.make_move_fast(b, move_list.moves[i], &state)

						// Check legality
						king_sq := board.get_king_square(b, 1 - b.side)
						if board.is_square_attacked(b, king_sq, b.side) {
							board.unmake_move(b, &state)
							continue
						}

						nnue.update_accumulators(&state, b, move_list.moves[i])
						child_pv: PV_Line
						score := -negamax(
							st,
							b,
							-beta,
							-current_alpha,
							current_depth - 1,
							0,
							&child_pv,
						)

						board.unmake_move(b, &state)

						if score > best_score {
							best_score = score
							current_best_move = move_list.moves[i]

							// Update best PV line
							best_pv.moves[0] = move_list.moves[i]
							for i in 0 ..< child_pv.count {
								best_pv.moves[i + 1] = child_pv.moves[i]
							}
							best_pv.count = child_pv.count + 1
						}

						if score > current_alpha {
							current_alpha = score
						}
					}
				} else if best_score >= beta {
					// Failed high - re-search with upper bound
					beta = eval.INF
					best_score = -eval.INF
					current_alpha = alpha

					for i in 0 ..< move_list.count {
						state: board.StateInfo
						board.make_move_fast(b, move_list.moves[i], &state)

						// Check legality
						king_sq := board.get_king_square(b, 1 - b.side)
						if board.is_square_attacked(b, king_sq, b.side) {
							board.unmake_move(b, &state)
							continue
						}

						nnue.update_accumulators(&state, b, move_list.moves[i])
						child_pv: PV_Line
						score := -negamax(
							st,
							b,
							-beta,
							-current_alpha,
							current_depth - 1,
							0,
							&child_pv,
						)

						board.unmake_move(b, &state)

						if score > best_score {
							best_score = score
							current_best_move = move_list.moves[i]

							// Update best PV line
							best_pv.moves[0] = move_list.moves[i]
							for i in 0 ..< child_pv.count {
								best_pv.moves[i + 1] = child_pv.moves[i]
							}
							best_pv.count = child_pv.count + 1
						}

						if score > current_alpha {
							current_alpha = score
						}
					}
				}
			}

			if found_move {
				// Store this PV result
				result: MultiPV_Result
				result.move = current_best_move
				result.score = best_score
				result.pv = best_pv
				append(&multi_pv_results, result)

				// Add to excluded list for next PV
				append(&excluded_moves, current_best_move)

				// Update prev_score from first PV
				if pv_index == 0 {
					prev_score = best_score
					best_move = current_best_move
				}
			}
		}

		// Flush local nodes to global counter for accurate reporting
		sync.atomic_add(&total_nodes, st.nodes % 1024)
		st.nodes = 0

		// Print all PV lines for this depth
		os.flush(os.stdout)
		duration := time.since(start_time)
		ms := time.duration_milliseconds(duration)
		os.flush(os.stdout)

		nps := u64(0)
		ms_int := int(ms) // Convert to int for output
		if ms_int > 0 {
			nps = get_total_nodes() * 1000 / u64(ms_int)
		}

		// Only output info lines if we're the main thread
		if output_bestmove {
			// Output each PV line
			for pv_idx in 0 ..< len(multi_pv_results) {
				result := &multi_pv_results[pv_idx]

				if multi_pv_count > 1 {
					// MultiPV format
					fmt.printf(
						"info depth %d multipv %d score cp %d nodes %d time %d nps %d pv ",
						current_depth,
						pv_idx + 1,
						result.score,
						get_total_nodes(),
						ms_int,
						nps,
					)
				} else {
					// Standard format
					fmt.printf(
						"info depth %d score cp %d nodes %d time %d nps %d pv ",
						current_depth,
						result.score,
						get_total_nodes(),
						ms_int,
						nps,
					)
				}

				// Print PV line
				for i in 0 ..< result.pv.count {
					board.print_move(result.pv.moves[i])
					if i < result.pv.count - 1 {
						fmt.printf(" ")
					}
				}
				fmt.println()
				os.flush(os.stdout)
			}
		}

		// Check for stop signal (from ponder stop or user interrupt)
		if should_stop_search() {
			break // Exit immediately if stop requested
		}

		// If ponderhit was triggered during pondering, enable time management
		if sync.atomic_load(&search_control.ponderhit_triggered) != 0 {
			use_time_management = true
			sync.atomic_store(&search_control.ponder_mode, i32(0))
		}

		// Check if we should stop iterative deepening
		// Skip time check if still in ponder mode (infinite search)
		is_pondering := sync.atomic_load(&search_control.ponder_mode)
		if is_pondering == 0 && use_time_management && exceeded_optimal(search_limits) {
			break // Stop if we've used our optimal time
		}
	}

	// Add remaining local nodes to global counter
	sync.atomic_add(&total_nodes, st.nodes % 1024)

	// Only output bestmove if requested (main thread only)
	if output_bestmove {
		fmt.printf("bestmove ")
		board.print_move(best_move)
		fmt.printf("\n")
		os.flush(os.stdout)
	}
}
