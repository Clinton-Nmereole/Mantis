package search

import "../board"
import "../constants"
import "../moves"

// Score a move for sorting
score_move :: proc(
	st: ^SearchThread,
	move: moves.Move,
	b: ^board.Board,
	tt_move: moves.Move,
	ply: int = 0,
	prev_move: moves.Move = moves.Move{},
) -> int {
	// 1. Hash Move (Highest Priority)
	if !moves.is_empty_move(tt_move) &&
	   move.source == tt_move.source &&
	   move.target == tt_move.target &&
	   move.promoted == tt_move.promoted {
		return params.hash_move_score
	}

	// 2. Counter Move (between TT and killers)
	if !moves.is_empty_move(prev_move) {
		counter := get_counter_move(st, prev_move)
		if !moves.is_empty_move(counter) &&
		   move.source == counter.source &&
		   move.target == counter.target &&
		   move.promoted == counter.promoted {
			return params.counter_move_score
		}
	}

	score := 0

	if move.capture {
		// MVV-LVA
		victim_piece := -1
		victim_value := 0

		if move.en_passant {
			victim_piece = constants.PAWN
			victim_value = constants.PIECE_VALUES[constants.PAWN]
		} else {
			// Find piece at target
			start_piece := 0
			end_piece := 6
			if b.side == constants.WHITE {
				start_piece = 6
				end_piece = 12
			}

			for i in start_piece ..< end_piece {
				if (b.bitboards[i] & (1 << u64(move.target))) != 0 {
					victim_piece = i % 6
					victim_value = constants.PIECE_VALUES[victim_piece]
					break
				}
			}
		}

		attacker_piece := move.piece % 6
		attacker_value := constants.PIECE_VALUES[attacker_piece]

		if victim_piece != -1 {
			score = params.capture_base_score + victim_value - attacker_value
		}
	}

	if move.promoted != -1 {
		score += constants.PIECE_VALUES[move.promoted]
	}

	// 3. Killer moves (for quiet moves)
	if !move.capture && move.promoted == -1 {
		killer_type := is_killer(st, move, ply)
		if killer_type == 1 {
			return params.killer1_score // Primary killer
		} else if killer_type == 2 {
			return params.killer2_score // Secondary killer
		}

		// 4. History score (for non-killer quiet moves)
		hist := get_history_score(st, move)

		// Opening priority: prefer center pawn pushes at root only.
		// NNUE rates all opening moves ~equal; this biases toward sound openings
		if ply == 0 && move.piece % 6 == constants.PAWN {
			target := move.target
			if target == 27 || target == 28 { hist += 1200 } // d4, e4
			if target == 35 || target == 36 { hist += 1200 } // d5, e5
			if target == 18 || target == 21 || target == 42 || target == 45 { hist += 450 } // c3, f3, c6, f6
			if target == 26 || target == 29 || target == 34 || target == 37 { hist += 350 } // c4, f4, c5, f5
			// Penalize early wing pawn moves that commonly waste opening tempi.
			if target == 16 || target == 17 || target == 22 || target == 23 ||
			   target == 24 || target == 25 || target == 30 || target == 31 ||
			   target == 32 || target == 33 || target == 38 || target == 39 ||
			   target == 40 || target == 41 || target == 46 || target == 47 {
				hist -= 1200
			}
		}
		if ply == 0 && move.piece % 6 == constants.KNIGHT {
			target := move.target
			if target == 2 || target == 5 || target == 58 || target == 61 { hist += 350 }  // c3/f3/c6/f6
			// Penalize knight to rim
			if target == 0 || target == 7 || target == 56 || target == 63 { hist -= 200 }  // a3, h3, a6, h6
		}

		return hist
	}

	return score
}

// Sort moves in descending order of score
sort_moves :: proc(
	st: ^SearchThread,
	move_list: ^moves.MoveList,
	b: ^board.Board,
	tt_move: moves.Move = moves.Move{},
	ply: int = 0,
	prev_move: moves.Move = moves.Move{},
) {
	if move_list.count < 2 {return}

	scores: [256]int

	for i in 0 ..< move_list.count {
		scores[i] = score_move(st, move_list.moves[i], b, tt_move, ply, prev_move)
	}

	// Insertion Sort (Descending)
	for i in 0 ..< move_list.count {
		for j in i + 1 ..< move_list.count {
			if scores[j] > scores[i] {
				// Swap scores
				temp_score := scores[i]
				scores[i] = scores[j]
				scores[j] = temp_score

				// Swap moves
				temp_move := move_list.moves[i]
				move_list.moves[i] = move_list.moves[j]
				move_list.moves[j] = temp_move
			}
		}
	}
}
