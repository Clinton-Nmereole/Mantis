package search

import "../board"
import "../constants"
import "../eval"
import "../moves"
import "../nnue"
import "core:fmt"
import "core:os"
import "core:time"

// Search Constants
MAX_PLY :: 64

// Search Info
nodes: u64 = 0

// Negamax Alpha-Beta Search
negamax :: proc(b: ^board.Board, alpha: int, beta: int, depth: int) -> int {
	nodes += 1

	if depth == 0 {
		// TODO: Quiescence Search
		return eval.evaluate(b)
	}

	// Move Generation
	move_list := make([dynamic]moves.Move)
	defer delete(move_list)

	// We need a copy of the board for move generation?
	// No, generate_all_moves takes a pointer.
	// But we need to be careful not to modify the board state permanently in the loop.
	// We use Copy-Make or Make-Unmake.
	// Our make_move is Copy-Make style (it modifies the board passed to it).
	// So we need to copy the board before passing it to make_move?
	// Wait, my make_move implementation in `perft.odin` was:
	// make_move(board, move, side) -> bool. It modifies `board`.
	// So we MUST copy the board before making a move if we want to backtrack.
	// OR implement unmake_move.

	// For now, Copy-Make is safer but slower.
	// Since Odin structs are value types, `temp_board := b^` creates a copy.

	board.generate_all_moves(b, &move_list)

	legal_moves := 0
	best_score := -eval.INF
	current_alpha := alpha

	for move in move_list {
		// Copy Board
		next_board := b^

		if board.make_move(&next_board, move, b.side) {
			legal_moves += 1

			// Update NNUE Accumulators
			nnue.update_accumulators(b, &next_board, move)

			score := -negamax(&next_board, -beta, -current_alpha, depth - 1)

			if score > best_score {
				best_score = score
			}

			if score > current_alpha {
				current_alpha = score
			}

			if current_alpha >= beta {
				// Beta Cutoff
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

	return best_score
}

// Root Search
search_position :: proc(b: ^board.Board, depth: int) {
	nodes = 0
	best_move: moves.Move

	start_time := time.now()

	// Iterative Deepening (Simplified: just run fixed depth for now)
	// for current_depth in 1 ..= depth { ... }

	alpha := -eval.INF
	beta := eval.INF

	move_list := make([dynamic]moves.Move)
	defer delete(move_list)
	board.generate_all_moves(b, &move_list)

	best_score := -eval.INF

	for move in move_list {
		next_board := b^
		if board.make_move(&next_board, move, b.side) {
			// Update NNUE Accumulators
			nnue.update_accumulators(b, &next_board, move)

			score := -negamax(&next_board, -beta, -alpha, depth - 1)

			if score > best_score {
				best_score = score
				best_move = move

				// Print Info
				fmt.printf("info depth %d score cp %d nodes %d ", depth, score, nodes)
				board.print_move(move)
				fmt.println()
				os.flush(os.stdout)
			}

			if score > alpha {
				alpha = score
			}
		}
	}

	duration := time.since(start_time)

	fmt.printf("bestmove ")
	board.print_move(best_move)
	fmt.printf("\n")

	fmt.printf("Nodes: %d\n", nodes)
	fmt.printf("Time: %v\n", duration)
}
