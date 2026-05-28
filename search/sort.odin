package search

import "../board"
import "../constants"
import "../moves"

SEE_SCORE_UNKNOWN :: -1_000_000_000
use_staged_move_picker: bool = false

MovePicker :: struct {
	move_list:       ^moves.MoveList,
	scores:          [256]int,
	see_scores:      [256]int,
	index:           int,
	staged:          bool,
	has_see_scores:  bool,
	current_ordered: bool,
}

// Score a move for sorting
score_move :: proc(
	st: ^SearchThread,
	move: moves.Move,
	b: ^board.Board,
	tt_move: moves.Move,
	ply: int = 0,
	prev_move: moves.Move = moves.Move{},
	see_score: int = SEE_SCORE_UNKNOWN,
) -> int {
	// 1. Hash Move (Highest Priority)
	if !moves.is_empty_move(tt_move) &&
	   move.source == tt_move.source &&
	   move.target == tt_move.target &&
	   move.promoted == tt_move.promoted {
		stat_add(&search_stats.tt_move_ordered)
		if ply == 0 {
			stat_add(&search_stats.root_pv_ordered)
		}
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
			cached_see := see_score
			if cached_see == SEE_SCORE_UNKNOWN {
				cached_see = see_capture(b, move)
			}
			capture_hist := get_capture_history_score(st, move)
			if cached_see >= 0 {
				score = params.capture_base_score + cached_see + capture_hist / 4 + victim_value - attacker_value / 16
			} else {
				score = cached_see + capture_hist / 16
			}
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
		if !moves.is_empty_move(prev_move) {
			hist += get_continuation_score(st, prev_move, move) / 16
		}

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
	see_scores: ^[256]int = nil,
) {
	scores: [256]int

	for i in 0 ..< move_list.count {
		see_score := SEE_SCORE_UNKNOWN
		if see_scores != nil {
			if move_list.moves[i].capture {
				see_score = see_capture(b, move_list.moves[i])
			}
			see_scores[i] = see_score
		}
		scores[i] = score_move(st, move_list.moves[i], b, tt_move, ply, prev_move, see_score)
	}

	if move_list.count < 2 {return}

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

				if see_scores != nil {
					temp_see := see_scores[i]
					see_scores[i] = see_scores[j]
					see_scores[j] = temp_see
				}
			}
		}
	}
}

init_move_picker :: proc(
	mp: ^MovePicker,
	st: ^SearchThread,
	move_list: ^moves.MoveList,
	b: ^board.Board,
	tt_move: moves.Move = moves.Move{},
	ply: int = 0,
	prev_move: moves.Move = moves.Move{},
	with_see_scores: bool = false,
) {
	mp.move_list = move_list
	mp.index = 0
	mp.staged = use_staged_move_picker
	mp.has_see_scores = with_see_scores
	mp.current_ordered = false

	if !mp.staged {
		if with_see_scores {
			sort_moves(st, move_list, b, tt_move, ply, prev_move, &mp.see_scores)
		} else {
			sort_moves(st, move_list, b, tt_move, ply, prev_move)
		}
		return
	}

	for i in 0 ..< move_list.count {
		see_score := SEE_SCORE_UNKNOWN
		if with_see_scores {
			if move_list.moves[i].capture {
				see_score = see_capture(b, move_list.moves[i])
			}
			mp.see_scores[i] = see_score
		}
		mp.scores[i] = score_move(st, move_list.moves[i], b, tt_move, ply, prev_move, see_score)
	}
}

move_picker_prepare_current :: proc(mp: ^MovePicker) {
	if mp.index >= mp.move_list.count {return}
	if !mp.staged || mp.current_ordered {return}

	i := mp.index
	for j in i + 1 ..< mp.move_list.count {
		if mp.scores[j] > mp.scores[i] {
			temp_score := mp.scores[i]
			mp.scores[i] = mp.scores[j]
			mp.scores[j] = temp_score

			temp_move := mp.move_list.moves[i]
			mp.move_list.moves[i] = mp.move_list.moves[j]
			mp.move_list.moves[j] = temp_move

			if mp.has_see_scores {
				temp_see := mp.see_scores[i]
				mp.see_scores[i] = mp.see_scores[j]
				mp.see_scores[j] = temp_see
			}
		}
	}

	mp.current_ordered = true
}

move_picker_next :: proc(
	mp: ^MovePicker,
	out_move: ^moves.Move,
	out_see_score: ^int = nil,
) -> bool {
	if mp.index >= mp.move_list.count {return false}

	move_picker_prepare_current(mp)
	out_move^ = mp.move_list.moves[mp.index]
	if out_see_score != nil {
		if mp.has_see_scores {
			out_see_score^ = mp.see_scores[mp.index]
		} else {
			out_see_score^ = SEE_SCORE_UNKNOWN
		}
	}

	mp.index += 1
	mp.current_ordered = false
	return true
}
