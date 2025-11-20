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
import "core:time"

// Search Constants
MAX_PLY :: 64

// PV Line Structure
PV_Line :: struct {
	moves: [MAX_PLY]moves.Move,
	count: int,
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

// Update history on beta cutoff
update_history :: proc(move: moves.Move, depth: int) {
	// Bonus based on depth (deeper searches = more important)
	bonus := depth * depth

	history_table[move.piece][move.target] += bonus

	// Cap to prevent overflow
	if history_table[move.piece][move.target] > 10000 {
		history_table[move.piece][move.target] = 10000
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

// Negamax Alpha-Beta Search
negamax :: proc(
	b: ^board.Board,
	alpha: int,
	beta: int,
	depth: int,
	ply: int,
	pv_line: ^PV_Line,
) -> int {
	nodes += 1

	// TT Probe
	tt_score, tt_hit := probe_tt(b.hash, alpha, beta, depth)
	if tt_hit {
		return tt_score
	}

	// Periodic time check (every 1024 nodes)
	if use_time_management && nodes % 1024 == 0 {
		if should_stop(search_limits) {
			return alpha // Exit early with fail-low
		}
	}

	// fmt.printf("DEBUG: negamax depth %d alpha %d beta %d\n", depth, alpha, beta)
	// os.flush(os.stdout)

	// Check Extension - extend if in check at frontier
	effective_depth := depth
	if depth == 0 {
		king_sq := board.get_king_square(b, b.side)
		in_check := board.is_square_attacked(b, king_sq, 1 - b.side)

		if in_check {
			effective_depth = 1 // Extend by 1 ply when in check
		} else {
			return quiescence(b, alpha, beta)
		}
	}

	// Null Move Pruning
	NMP_MIN_DEPTH :: 3
	NMP_REDUCTION :: 2

	// Check if we're in check
	king_sq := board.get_king_square(b, b.side)
	in_check := board.is_square_attacked(b, king_sq, 1 - b.side)

	// Apply null move if:
	// 1. Not in PV node (beta - alpha > 1)
	// 2. Not in check
	// 3. Deep enough
	can_null_move := (beta - alpha > 1) && !in_check && depth >= NMP_MIN_DEPTH

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

		// Search null move at reduced depth
		null_pv: PV_Line
		null_score := -negamax(
			&null_board,
			-beta,
			-beta + 1,
			effective_depth - 1 - NMP_REDUCTION,
			ply + 1,
			&null_pv,
		)

		// If null move fails high, prune
		if null_score >= beta {
			return beta
		}
	}

	// Move Generation
	move_list := make([dynamic]moves.Move)
	defer delete(move_list)

	board.generate_all_moves(b, &move_list)

	// TT Move (Hash Move)
	tt_move := get_tt_move(b.hash)

	// Move Ordering
	sort_moves(&move_list, b, tt_move, ply)

	legal_moves := 0
	best_score := -eval.INF
	current_alpha := alpha
	best_move: moves.Move

	for move in move_list {
		// Copy Board
		next_board := b^

		if board.make_move(&next_board, move, b.side) {


			// Update NNUE Accumulators
			nnue.update_accumulators(b, &next_board, move)

			child_pv: PV_Line
			score := 0
			if legal_moves == 0 {
				// First move (PV node): Full window search
				score = -negamax(
					&next_board,
					-beta,
					-current_alpha,
					effective_depth - 1,
					ply + 1,
					&child_pv,
				)
			} else {
				// Subsequent moves: PVS with LMR

				// LMR Parameters
				LMR_MIN_DEPTH :: 3
				LMR_MOVE_THRESHOLD :: 3

				reduction := 0

				// Apply LMR if:
				// 1. Deep enough (depth >= LMR_MIN_DEPTH)
				// 2. Not a tactical move (capture, promotion, check)
				// 3. Not one of the first few moves
				if effective_depth >= LMR_MIN_DEPTH &&
				   !move.capture &&
				   move.promoted == -1 &&
				   legal_moves >= LMR_MOVE_THRESHOLD {
					// Logarithmic reduction formula
					reduction = int(
						math.ln(f64(effective_depth)) * math.ln(f64(legal_moves)) / 2.5,
					)

					// Clamp to reasonable range
					if reduction < 1 {reduction = 1}
					if reduction > effective_depth - 1 {reduction = effective_depth - 1}
				}

				// Null window search with reduction
				score = -negamax(
					&next_board,
					-current_alpha - 1,
					-current_alpha,
					effective_depth - 1 - reduction,
					ply + 1,
					&child_pv,
				)

				// Re-search if reduced search raised alpha
				if score > current_alpha && reduction > 0 {
					// Re-search at full depth with null window
					score = -negamax(
						&next_board,
						-current_alpha - 1,
						-current_alpha,
						effective_depth - 1,
						ply + 1,
						&child_pv,
					)
				}

				// Re-search if within bounds (PVS)
				if score > current_alpha && score < beta {
					score = -negamax(
						&next_board,
						-beta,
						-current_alpha,
						effective_depth - 1,
						ply + 1,
						&child_pv,
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
				// Beta Cutoff - store killer and update history for quiet moves
				if !move.capture && move.promoted == -1 {
					store_killer(move, ply)
					update_history(move, effective_depth)
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
search_position :: proc(b: ^board.Board, depth: int) {
	// fmt.println("DEBUG: Entering search_position")
	nodes = 0
	clear_killers() // Clear killer moves for new search
	clear_history() // Clear history table for new search
	// fmt.printf("DEBUG: NNUE Initialized: %v\n", nnue.is_initialized)
	// os.flush(os.stdout)
	best_move: moves.Move
	best_pv: PV_Line // Store the best PV line

	start_time := time.now()

	// Aspiration Windows
	ASPIRATION_WINDOW :: 50
	prev_score := 0

	// Iterative Deepening
	for current_depth in 1 ..= depth {
		// fmt.printf("DEBUG: Starting depth %d\n", current_depth)
		root_pv: PV_Line
		alpha := -eval.INF
		beta := eval.INF

		// Use aspiration windows for depth >= 5
		if current_depth >= 5 {
			alpha = prev_score - ASPIRATION_WINDOW
			beta = prev_score + ASPIRATION_WINDOW
		}

		move_list := make([dynamic]moves.Move)
		defer delete(move_list)
		// fmt.println("DEBUG: Generating moves...")
		board.generate_all_moves(b, &move_list)
		// fmt.printf("DEBUG: Generated %d moves\n", len(move_list))

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

		// Re-search if outside aspiration window
		if current_depth >= 5 {
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
			best_move = current_best_move
		}

		// Update previous score for next iteration
		prev_score = best_score

		// Print Info
		os.flush(os.stdout)
		duration := time.since(start_time)
		// fmt.println("DEBUG: Duration calculated.")
		// os.flush(os.stdout)
		ms := time.duration_milliseconds(duration)
		// fmt.println("DEBUG: MS calculated.")
		// fmt.println(ms)
		// fmt.println("DEBUG: Nodes:")
		// fmt.println(nodes)
		os.flush(os.stdout)

		nps := u64(0)
		ms_int := int(ms) // Convert to int for output
		if ms_int > 0 {
			nps = nodes * 1000 / u64(ms_int)
		}
		// fmt.println("DEBUG: Time calculated.")
		// os.flush(os.stdout)

		// fmt.println("DEBUG: Printing info...")
		fmt.printf(
			"info depth %d score cp %d nodes %d time %d nps %d pv ",
			current_depth,
			best_score,
			nodes,
			ms_int,
			nps,
		)

		// Print full PV line
		for i in 0 ..< best_pv.count {
			board.print_move(best_pv.moves[i])
			if i < best_pv.count - 1 {
				fmt.printf(" ")
			}
		}
		fmt.println()
		os.flush(os.stdout)

		// Check if we should stop iterative deepening
		if use_time_management && exceeded_optimal(search_limits) {
			break // Stop if we've used our optimal time
		}
	}

	fmt.printf("bestmove ")
	board.print_move(best_move)
	fmt.printf("\n")
	os.flush(os.stdout)
}
