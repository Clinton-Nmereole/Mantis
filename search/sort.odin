package search

import "../board"
import "../constants"
import "../moves"

// Score a move for sorting
// Score a move for sorting
score_move :: proc(
	move: moves.Move,
	b: ^board.Board,
	tt_move: moves.Move,
	ply: int = 0,
	prev_move: moves.Move = moves.Move{},
) -> int {
	// 1. Hash Move (Highest Priority)
	if move.source == tt_move.source &&
	   move.target == tt_move.target &&
	   move.promoted == tt_move.promoted {
		return 20000
	}

	// 2. Counter Move (between TT and killers)
	if prev_move.source != 0 {
		counter := get_counter_move(prev_move)
		if counter.source != 0 && move.source == counter.source && move.target == counter.target {
			return 15000
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
			// We iterate through all piece bitboards to find the victim
			// Optimization: Start from P (0) to K (5) + offset
			// Victim is opposite color
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
			score = 10000 + victim_value - attacker_value
		}
	}

	if move.promoted != -1 {
		score += constants.PIECE_VALUES[move.promoted]
	}

	// 3. Killer moves (for quiet moves)
	if !move.capture && move.promoted == -1 {
		killer_type := is_killer(move, ply)
		if killer_type == 1 {
			return 9000 // Primary killer
		} else if killer_type == 2 {
			return 8000 // Secondary killer
		}

		// 4. History score (for non-killer quiet moves)
		return get_history_score(move)
	}

	return score
}

// Sort moves in descending order of score
sort_moves :: proc(
	move_list: ^[dynamic]moves.Move,
	b: ^board.Board,
	tt_move: moves.Move = moves.Move{},
	ply: int = 0,
	prev_move: moves.Move = moves.Move{}, // For counter moves
) {
	if len(move_list) < 2 {return}

	scores := make([dynamic]int, len(move_list))
	defer delete(scores)

	for i in 0 ..< len(move_list) {
		scores[i] = score_move(move_list[i], b, tt_move, ply, prev_move)
	}

	// Insertion Sort (Descending)
	for i in 0 ..< len(move_list) {
		for j in i + 1 ..< len(move_list) {
			if scores[j] > scores[i] {
				// Swap scores
				temp_score := scores[i]
				scores[i] = scores[j]
				scores[j] = temp_score

				// Swap moves
				temp_move := move_list[i]
				move_list[i] = move_list[j]
				move_list[j] = temp_move
			}
		}
	}
}
