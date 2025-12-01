package search

import "../board"
import "../constants"
import "../eval"
import "../moves"
import "../nnue"
import "../zobrist"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:time"

// Search Constants
MAX_PLY :: 64

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


// Search Info
nodes: u64 = 0

// Killer Moves - 2 killers per ply
killer_moves: [MAX_PLY][2]moves.Move

// Store a killer move
store_killer :: proc(move: moves.Move, ply: int) {
	if ply < 0 || ply >= MAX_PLY {return}

	// If not already primary killer
	if killer_moves[ply][0].source != move.source || killer_moves[ply][0].target != move.target {
		// Shift primary to secondary
		killer_moves[ply][1] = killer_moves[ply][0]
		// New move becomes primary
		killer_moves[ply][0] = move
	}
}

// Check if move is killer (returns 1 for primary, 2 for secondary, 0 otherwise)
is_killer :: proc(move: moves.Move, ply: int) -> int {
	if ply < 0 || ply >= MAX_PLY {return 0}

	if killer_moves[ply][0].source == move.source && killer_moves[ply][0].target == move.target {
		return 1 // Primary killer
	}
	if killer_moves[ply][1].source == move.source && killer_moves[ply][1].target == move.target {
		return 2 // Secondary killer
	}
	return 0 // Not a killer
}

// Clear all killer moves
clear_killers :: proc() {
	for i in 0 ..< MAX_PLY {
		killer_moves[i][0] = moves.Move{}
		killer_moves[i][1] = moves.Move{}
	}
}

// History Heuristic - piece-to-square success rates
history_table: [12][64]int // [piece][to_square]

// Update history with result (positive for cutoffs, negative for fails)
update_history :: proc(move: moves.Move, depth: int, good: bool) {
	// Bonus based on depth (deeper searches = more important)
	bonus := depth * depth
	if !good {
		bonus = -bonus // Penalize moves that don't cause cutoffs
	}

	history_table[move.piece][move.target] += bonus

	// Cap to prevent overflow
	if history_table[move.piece][move.target] > 10000 {
		history_table[move.piece][move.target] = 10000
	}
	if history_table[move.piece][move.target] < -10000 {
		history_table[move.piece][move.target] = -10000
	}
}

// Age history scores (called periodically to decay old information)
age_history :: proc() {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			// Reduce by 10% to favor recent information
			history_table[i][j] = history_table[i][j] * 9 / 10
		}
	}
}

// Get history score for a move
get_history_score :: proc(move: moves.Move) -> int {
	return history_table[move.piece][move.target]
}

// Clear history table
clear_history :: proc() {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			history_table[i][j] = 0
		}
	}
}

// Counter Moves Heuristic - track refutation moves
// counter_moves[piece][to_square] = the move that refutes this move
counter_moves: [12][64]moves.Move

// Store a counter move (the refutation to the previous move)
store_counter_move :: proc(prev_move: moves.Move, refutation: moves.Move) {
	// Bounds checking
	if prev_move.piece < 0 || prev_move.piece >= 12 {return}
	if prev_move.target < 0 || prev_move.target >= 64 {return}

	counter_moves[prev_move.piece][prev_move.target] = refutation
}

// Get the counter move for a given move
get_counter_move :: proc(prev_move: moves.Move) -> moves.Move {
	// Bounds checking
	if prev_move.piece < 0 || prev_move.piece >= 12 {return moves.Move{}}
	if prev_move.target < 0 || prev_move.target >= 64 {return moves.Move{}}

	return counter_moves[prev_move.piece][prev_move.target]
}

// Clear all counter moves
clear_counter_moves :: proc() {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			counter_moves[i][j] = moves.Move{}
		}
	}
}

// Continuation History - 1-ply
// Tracks score for move pairs: [prev_piece_type][prev_to][curr_piece_type][curr_to]
// Using heap allocation for safety
continuation_history: ^[6][64][6][64]int

// Initialize continuation history
init_continuation_history :: proc() {
	if continuation_history == nil {
		continuation_history = new([6][64][6][64]int)
	}
	// Zero-initialize
	for i in 0 ..< 6 {
		for j in 0 ..< 64 {
			for k in 0 ..< 6 {
				for l in 0 ..< 64 {
					continuation_history[i][j][k][l] = 0
				}
			}
		}
	}
}

// Store continuation history score
store_continuation :: proc(prev_move: moves.Move, curr_move: moves.Move, depth: int, good: bool) {
	// CRITICAL: Extensive bounds checking
	if continuation_history == nil {return}
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
	old_val := continuation_history[prev_type][prev_move.target][curr_type][curr_move.target]
	new_val := old_val + bonus

	// Clamp to prevent overflow
	if new_val > 10000 {new_val = 10000}
	if new_val < -10000 {new_val = -10000}

	continuation_history[prev_type][prev_move.target][curr_type][curr_move.target] = new_val
}

// Get continuation history score
get_continuation_score :: proc(prev_move: moves.Move, curr_move: moves.Move) -> int {
	// CRITICAL: Extensive bounds checking
	if continuation_history == nil {return 0}
	if prev_move.piece < 0 || prev_move.piece >= 12 {return 0}
	if curr_move.piece < 0 || curr_move.piece >= 12 {return 0}
	if prev_move.target < 0 || prev_move.target >= 64 {return 0}
	if curr_move.target < 0 || curr_move.target >= 64 {return 0}

	prev_type := prev_move.piece % 6
	curr_type := curr_move.piece % 6

	return continuation_history[prev_type][prev_move.target][curr_type][curr_move.target]
}

// Negamax Alpha-Beta Search
negamax :: proc(
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
	nodes += 1

	// TT Probe
	tt_score, tt_hit := probe_tt(b.hash, alpha, beta, depth)
	if tt_hit {
		return tt_score
	}

	// Periodic stop check (every 1024 nodes) - for ponder/stop functionality
	if nodes % 1024 == 0 {
		if should_stop_search() {
			return alpha // Exit immediately if stop requested
		}
	}

	// Periodic time check (every 1024 nodes)
	if use_time_management && nodes % 1024 == 0 {
		if should_stop(search_limits) {
			return alpha // Exit early with fail-low
		}
	}

	// fmt.printf("DEBUG: negamax depth %d alpha %d beta %d\n", depth, alpha, beta)
	// os.flush(os.stdout)

	// Check if in check (used by multiple features)
	king_sq := board.get_king_square(b, b.side)
	in_check := board.is_square_attacked(b, king_sq, 1 - b.side)

	// Check Extension - extend if in check at frontier
	// Limited to prevent excessive searching
	effective_depth := depth
	if depth == 0 {
		if in_check && ply < 40 { 	// Don't extend too deep in search
			effective_depth = 1 // Extend by 1 ply when in check
		} else {
			return quiescence(b, alpha, beta)
		}
	}

	// Razoring - drop into quiescence if position is hopeless
	if !is_pv && !in_check && depth <= 3 {
		evaluation := eval.evaluate(b)
		razor_margin := 300 * depth
		if evaluation + razor_margin < alpha {
			// Position is so bad even with margin, just do quiescence
			qscore := quiescence(b, alpha, beta)
			if qscore < alpha {
				return qscore
			}
		}
	}

	// Null Move Pruning
	NMP_MIN_DEPTH :: 3

	// Apply null move if:
	// 1. Not in PV node (use is_pv flag)
	// 2. Not in check
	// 3. Deep enough
	can_null_move := !is_pv && !in_check && depth >= NMP_MIN_DEPTH

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
		nmp_reduction := 2 + effective_depth / 6

		// Search null move at reduced depth
		null_pv: PV_Line
		null_score := -negamax(
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
	RFP_DEPTH :: 7
	if !is_pv && !in_check && effective_depth <= RFP_DEPTH && excluded_move.source == 0 {
		evaluation := eval.evaluate(b)

		// Margin based on depth (90 centipawns per ply - tuned for aggression)
		rfp_margin := 90 * effective_depth

		if evaluation - rfp_margin >= beta {
			return evaluation - rfp_margin
		}
	}

	// Move Generation
	move_list := make([dynamic]moves.Move)
	defer delete(move_list)

	board.generate_all_moves(b, &move_list)

	// TT Move (Hash Move)
	tt_move := get_tt_move(b.hash)

	// Internal Iterative Reduction (IIR)
	// If we have no hash move and this is a PV node, reduce depth
	// We don't know what's good here, so search shallower first
	if tt_move.source == 0 && is_pv && effective_depth >= 4 {
		effective_depth -= 1
	}

	// Move Ordering
	sort_moves(&move_list, b, tt_move, ply, prev_move)

	// Singular Extensions
	// Test if TT move is "singularly" better than all alternatives
	extension := 0
	SE_DEPTH :: 8

	if depth >= SE_DEPTH &&
	   !in_check &&
	   ply > 0 &&
	   tt_move.source != 0 &&
	   excluded_move.source == 0 { 	// Don't do SE during SE search

		// Get TT score for singular test
		tt_entry_score, tt_found := probe_tt(b.hash, alpha, beta, depth)

		if tt_found {
			// Singular beta - margin based on depth
			singular_beta := tt_entry_score - depth * 2

			// Reduced depth for singular search
			reduced_depth := depth / 2

			// Search all moves EXCEPT TT move
			child_pv: PV_Line
			singular_score := negamax(
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
	if !is_pv && !in_check && depth <= 3 {
		futility_margin := 250 * depth // Tuned for more aggressive pruning
		futility_value = eval.evaluate(b) + futility_margin
		if futility_value < alpha {
			do_futility = true
		}
	}

	for move in move_list {
		// Skip excluded move (for singular extensions)
		if excluded_move.source != 0 &&
		   move.source == excluded_move.source &&
		   move.target == excluded_move.target {
			continue
		}

		// Copy Board
		next_board := b^

		if board.make_move(&next_board, move, b.side) {


			// Update NNUE Accumulators
			nnue.update_accumulators(b, &next_board, move)

			// Futility Pruning - skip quiet moves that can't raise alpha
			if do_futility && legal_moves > 0 && !move.capture && move.promoted == -1 {
				// Skip this quiet move - position is too bad
				continue
			}

			child_pv: PV_Line
			score := 0

			// Combine check extension with singular extension
			combined_depth := effective_depth + extension

			if legal_moves == 0 {
				// First move (PV node): Full window search
				score = -negamax(
					&next_board,
					-beta,
					-current_alpha,
					combined_depth - 1,
					ply + 1,
					&child_pv,
					{}, // no excluded move
					true, // is PV
					move, // prev_move for counter-moves
				)
			} else {
				// Subsequent moves: PVS with LMR

				// LMR Parameters - Aggressive but stable
				LMR_MIN_DEPTH :: 1 // Apply at all depths
				LMR_MOVE_THRESHOLD :: 0 // Apply to all moves after PV

				reduction := 0

				// Apply LMR if:
				// 1. Deep enough (depth >= 1)
				// 2. Not a tactical move (capture, promotion)
				// 3. After first move (PV move)
				if combined_depth >= LMR_MIN_DEPTH &&
				   !move.capture &&
				   move.promoted == -1 &&
				   legal_moves > LMR_MOVE_THRESHOLD {
					// Logarithmic reduction formula - aggressive but safe
					reduction = int(math.ln(f64(combined_depth)) * math.ln(f64(legal_moves)) / 1.5)

					// Clamp to reasonable range
					if reduction < 1 {reduction = 1}
					if reduction > combined_depth - 1 {reduction = combined_depth - 1}
				}

				// Null window search with reduction
				score = -negamax(
					&next_board,
					-current_alpha - 1,
					-current_alpha,
					combined_depth - 1 - reduction,
					ply + 1,
					&child_pv,
					{}, // no excluded move
					false, // not PV (null window)
					move, // prev_move for counter-moves
				)

				// Re-search if reduced search raised alpha
				if score > current_alpha && reduction > 0 {
					// Re-search at full depth with null window
					score = -negamax(
						&next_board,
						-current_alpha - 1,
						-current_alpha,
						combined_depth - 1,
						ply + 1,
						&child_pv,
						{}, // no excluded move
						false, // not PV (null window)
						move, // prev_move for counter-moves
					)
				}

				// Re-search if within bounds (PVS)
				if score > current_alpha && score < beta {
					score = -negamax(
						&next_board,
						-beta,
						-current_alpha,
						combined_depth - 1,
						ply + 1,
						&child_pv,
						{}, // no excluded move
						true, // is PV
						move, // prev_move for counter-moves
					)
				}
			}
			legal_moves += 1

			if score > best_score {
				best_score = score
				best_move = move
				// Update PV
				pv_line.moves[0] = move
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
				if !move.capture && move.promoted == -1 {
					store_killer(move, ply)
					update_history(move, effective_depth, true)

					// Store as counter move if we have a previous move
					if prev_move.source != 0 {
						store_counter_move(prev_move, move)

						// Continuation history - DISABLED (caused regression)
						// store_continuation(prev_move, move, effective_depth, true)
					}
				}
				break
			}
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

	store_tt(b.hash, best_move, best_score, depth, flag)

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
quiescence :: proc(b: ^board.Board, alpha: int, beta: int) -> int {
	nodes += 1
	evaluation := eval.evaluate(b)

	if evaluation >= beta {
		return beta
	}

	current_alpha := alpha
	if evaluation > current_alpha {
		current_alpha = evaluation
	}

	move_list := make([dynamic]moves.Move)
	defer delete(move_list)
	board.generate_all_moves(b, &move_list)

	// Move Ordering for Quiescence
	sort_moves(&move_list, b)

	for move in move_list {
		if move.capture {
			// SEE Pruning - skip obviously losing captures
			// Conservative threshold: only skip if we lose more than a pawn
			see_score := see_capture(b, move)
			if see_score < -100 {
				continue // Skip this losing capture
			}

			next_board := b^
			if board.make_move(&next_board, move, b.side) {
				nnue.update_accumulators(b, &next_board, move)
				score := -quiescence(&next_board, -beta, -current_alpha)

				if score >= beta {
					return beta
				}
				if score > current_alpha {
					current_alpha = score
				}
			}
		}
	}

	return current_alpha
}

// Root Search
search_position :: proc(
	b: ^board.Board,
	depth: int,
	multi_pv_count: int = 1,
	output_bestmove: bool = true,
) {
	// fmt.println("DEBUG: Entering search_position")
	nodes = 0
	clear_killers() // Clear killer moves for new search
	clear_history() // Clear history table for new search
	clear_counter_moves() // Clear counter moves for new search
	init_continuation_history() // Initialize continuation history
	// fmt.printf("DEBUG: NNUE Initialized: %v\n", nnue.is_initialized)
	// os.flush(os.stdout)
	best_move: moves.Move
	best_pv: PV_Line // Store the best PV line

	start_time := time.now()

	// Aspiration Windows - narrower for faster convergence
	ASPIRATION_WINDOW :: 25 // Sweet spot for performance
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
		all_moves := make([dynamic]moves.Move)
		defer delete(all_moves)
		board.generate_all_moves(b, &all_moves)

		// Track which moves have been searched for MultiPV
		excluded_moves: [dynamic]moves.Move
		defer delete(excluded_moves)

		// Search each PV line
		pv_lines_to_search := multi_pv_count
		if pv_lines_to_search > len(all_moves) {
			pv_lines_to_search = len(all_moves)
		}

		for pv_index in 0 ..< pv_lines_to_search {
			root_pv: PV_Line
			alpha := -eval.INF
			beta := eval.INF

			// Use aspiration windows for depth >= 4 (was 5) and first PV only
			if current_depth >= 4 && pv_index == 0 {
				alpha = prev_score - ASPIRATION_WINDOW
				beta = prev_score + ASPIRATION_WINDOW
			}

			// Create move list excluding previously found PVs
			move_list := make([dynamic]moves.Move)
			defer delete(move_list)

			for move in all_moves {
				// Check if this move is in excluded list
				is_excluded := false
				for excluded in excluded_moves {
					if move.source == excluded.source &&
					   move.target == excluded.target &&
					   move.promoted == excluded.promoted {
						is_excluded = true
						break
					}
				}
				if !is_excluded {
					append(&move_list, move)
				}
			}

			if len(move_list) == 0 {
				break // No more moves to search
			}

			best_score := -eval.INF
			current_best_move: moves.Move
			found_move := false

			current_alpha := alpha

			for move in move_list {
				next_board := b^
				if board.make_move(&next_board, move, b.side) {
					// Update NNUE Accumulators
					nnue.update_accumulators(b, &next_board, move)

					child_pv: PV_Line
					score := -negamax(
						&next_board,
						-beta,
						-current_alpha,
						current_depth - 1,
						0,
						&child_pv,
					)

					if score > best_score {
						best_score = score
						current_best_move = move
						found_move = true

						// Update best PV line
						best_pv.moves[0] = move
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

			// Re-search if outside aspiration window (first PV only)
			if current_depth >= 5 && pv_index == 0 {
				if best_score <= alpha {
					// Failed low - re-search with lower bound
					alpha = -eval.INF
					best_score = -eval.INF
					current_alpha = alpha

					for move in move_list {
						next_board := b^
						if board.make_move(&next_board, move, b.side) {
							nnue.update_accumulators(b, &next_board, move)
							child_pv: PV_Line
							score := -negamax(
								&next_board,
								-beta,
								-current_alpha,
								current_depth - 1,
								0,
								&child_pv,
							)

							if score > best_score {
								best_score = score
								current_best_move = move

								// Update best PV line
								best_pv.moves[0] = move
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
				} else if best_score >= beta {
					// Failed high - re-search with upper bound
					beta = eval.INF
					best_score = -eval.INF
					current_alpha = alpha

					for move in move_list {
						next_board := b^
						if board.make_move(&next_board, move, b.side) {
							nnue.update_accumulators(b, &next_board, move)
							child_pv: PV_Line
							score := -negamax(
								&next_board,
								-beta,
								-current_alpha,
								current_depth - 1,
								0,
								&child_pv,
							)

							if score > best_score {
								best_score = score
								current_best_move = move

								// Update best PV line
								best_pv.moves[0] = move
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

		// Print all PV lines for this depth
		os.flush(os.stdout)
		duration := time.since(start_time)
		ms := time.duration_milliseconds(duration)
		os.flush(os.stdout)

		nps := u64(0)
		ms_int := int(ms) // Convert to int for output
		if ms_int > 0 {
			nps = nodes * 1000 / u64(ms_int)
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
						nodes,
						ms_int,
						nps,
					)
				} else {
					// Standard format
					fmt.printf(
						"info depth %d score cp %d nodes %d time %d nps %d pv ",
						current_depth,
						result.score,
						nodes,
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

	// Only output bestmove if requested (main thread only)
	if output_bestmove {
		fmt.printf("bestmove ")
		board.print_move(best_move)
		fmt.printf("\n")
		os.flush(os.stdout)
	}
}
