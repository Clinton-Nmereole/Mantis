package search

import "../board"
import "../constants"
import "../moves"

SEE_SCORE_UNKNOWN :: -1_000_000_000
use_staged_move_picker: bool = false

MOVE_PICKER_HASH_STAGE :: 0
MOVE_PICKER_COUNTER_STAGE :: 1
MOVE_PICKER_GOOD_CAPTURE_STAGE :: 2
MOVE_PICKER_KILLER1_STAGE :: 3
MOVE_PICKER_KILLER2_STAGE :: 4
MOVE_PICKER_REST_STAGE :: 5
MOVE_PICKER_DONE_STAGE :: 6
LATE_ROOT_PAWN_OPENING_BIAS_DIVISOR :: 4

root_opening_bias_score :: proc(b: ^board.Board, move: moves.Move) -> int {
	bias := 0
	target := move.target

	if move.piece % 6 == constants.PAWN {
		if target == 27 || target == 28 {bias += 1200} // d4, e4
		if target == 35 || target == 36 {bias += 1200} // d5, e5
		if target == 18 || target == 21 || target == 42 || target == 45 {bias += 450} // c3, f3, c6, f6
		if target == 26 || target == 29 || target == 34 || target == 37 {bias += 350} // c4, f4, c5, f5
		// Penalize early wing pawn moves that commonly waste opening tempi.
		if target == 16 || target == 17 || target == 22 || target == 23 ||
		   target == 24 || target == 25 || target == 30 || target == 31 ||
		   target == 32 || target == 33 || target == 38 || target == 39 ||
		   target == 40 || target == 41 || target == 46 || target == 47 {
			bias -= 1200
		}
		if b.fullmove_number > 12 {
			bias /= LATE_ROOT_PAWN_OPENING_BIAS_DIVISOR
		}
	} else if move.piece % 6 == constants.KNIGHT && b.fullmove_number <= 12 {
		if target == 18 || target == 21 || target == 42 || target == 45 {bias += 350} // c3, f3, c6, f6
		// Penalize knights on the rim.
		if target == 16 || target == 23 || target == 40 || target == 47 {bias -= 200} // a3, h3, a6, h6
	}

	return bias
}

MovePicker :: struct {
	move_list:       ^moves.MoveList,
	scores:          [256]int,
	see_scores:      [256]int,
	index:           int,
	stage:           int,
	staged:          bool,
	has_see_scores:  bool,
	current_ordered: bool,
	st:              ^SearchThread,
	tt_move:         moves.Move,
	counter_move:    moves.Move,
	ply:             int,
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
			raw_cont_score := get_continuation_score(st, prev_move, move)
			if search_stats_enabled {
				stat_add(&search_stats.continuation_score_probes)
				if raw_cont_score != 0 {
					stat_add(&search_stats.continuation_score_raw_nonzero)
					abs_raw_cont_score := raw_cont_score
					if raw_cont_score > 0 {
						stat_add(&search_stats.continuation_score_raw_positive)
					} else {
						stat_add(&search_stats.continuation_score_raw_negative)
						abs_raw_cont_score = -abs_raw_cont_score
					}
					stat_add(&search_stats.continuation_score_raw_abs_sum, u64(abs_raw_cont_score))
					if abs_raw_cont_score < 16 {
						stat_add(&search_stats.continuation_score_raw_under_scale)
					}
				}

				cont_score_for_stats := raw_cont_score / 16
				if cont_score_for_stats != 0 {
					stat_add(&search_stats.continuation_score_nonzero)
					abs_cont_score := cont_score_for_stats
					if cont_score_for_stats > 0 {
						stat_add(&search_stats.continuation_score_positive)
					} else {
						stat_add(&search_stats.continuation_score_negative)
						abs_cont_score = -abs_cont_score
					}
					stat_add(&search_stats.continuation_score_abs_sum, u64(abs_cont_score))
				}
			}

			hist += raw_cont_score / 16
		}

		// Opening priority: prefer center pawn pushes at root only.
		// NNUE rates all opening moves ~equal; this biases toward sound openings.
		if ply == 0 {
			hist += root_opening_bias_score(b, move)
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
	force_full_sort: bool = false,
) {
	mp.move_list = move_list
	mp.index = 0
	mp.stage = MOVE_PICKER_HASH_STAGE
	mp.staged = use_staged_move_picker && !force_full_sort
	mp.has_see_scores = with_see_scores
	mp.current_ordered = false
	mp.st = st
	mp.tt_move = tt_move
	mp.ply = ply
	mp.counter_move = moves.Move{}
	if !moves.is_empty_move(prev_move) {
		mp.counter_move = get_counter_move(st, prev_move)
	}

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
		if move_list.moves[i].capture &&
		   !move_picker_same_move(move_list.moves[i], tt_move) &&
		   !move_picker_same_move(move_list.moves[i], mp.counter_move) {
			see_score = see_capture(b, move_list.moves[i])
		}
		if with_see_scores {
			mp.see_scores[i] = see_score
		} else if move_list.moves[i].capture {
			mp.see_scores[i] = see_score
		} else {
			mp.see_scores[i] = SEE_SCORE_UNKNOWN
		}
		mp.scores[i] = score_move(st, move_list.moves[i], b, tt_move, ply, prev_move, see_score)
	}
}

move_picker_same_move :: proc(a, b: moves.Move) -> bool {
	return !moves.is_empty_move(a) &&
		a.source == b.source &&
		a.target == b.target &&
		a.promoted == b.promoted
}

move_picker_stage_match :: proc(mp: ^MovePicker, idx: int) -> bool {
	move := mp.move_list.moves[idx]
	switch mp.stage {
	case MOVE_PICKER_HASH_STAGE:
		return move_picker_same_move(move, mp.tt_move)
	case MOVE_PICKER_COUNTER_STAGE:
		return move_picker_same_move(move, mp.counter_move)
	case MOVE_PICKER_GOOD_CAPTURE_STAGE:
		if move.promoted != -1 {
			return true
		}
		return move.capture && mp.see_scores[idx] >= 0
	case MOVE_PICKER_KILLER1_STAGE:
		return !move.capture && move.promoted == -1 && is_killer(mp.st, move, mp.ply) == 1
	case MOVE_PICKER_KILLER2_STAGE:
		return !move.capture && move.promoted == -1 && is_killer(mp.st, move, mp.ply) == 2
	case MOVE_PICKER_REST_STAGE:
		if move.capture && move.promoted == -1 {
			return mp.see_scores[idx] < 0
		}
		return !move.capture && move.promoted == -1 && is_killer(mp.st, move, mp.ply) == 0
	}
	return false
}

move_picker_select_index :: proc(mp: ^MovePicker) -> int {
	for mp.stage < MOVE_PICKER_DONE_STAGE {
		best_idx := -1
		best_score := -2_000_000_000
		for i in mp.index ..< mp.move_list.count {
			if !move_picker_stage_match(mp, i) {
				continue
			}
			if best_idx == -1 || mp.scores[i] > best_score {
				best_idx = i
				best_score = mp.scores[i]
			}
		}

		if best_idx != -1 {
			return best_idx
		}
		mp.stage += 1
	}

	return -1
}

move_picker_prepare_current :: proc(mp: ^MovePicker) {
	if mp.index >= mp.move_list.count {return}
	if !mp.staged || mp.current_ordered {return}

	i := mp.index
	selected := move_picker_select_index(mp)
	if selected == -1 {
		mp.index = mp.move_list.count
		return
	}
	if selected != i {
		temp_score := mp.scores[i]
		mp.scores[i] = mp.scores[selected]
		mp.scores[selected] = temp_score

		temp_move := mp.move_list.moves[i]
		mp.move_list.moves[i] = mp.move_list.moves[selected]
		mp.move_list.moves[selected] = temp_move

		temp_see := mp.see_scores[i]
		mp.see_scores[i] = mp.see_scores[selected]
		mp.see_scores[selected] = temp_see
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
	if mp.index >= mp.move_list.count {return false}
	out_move^ = mp.move_list.moves[mp.index]
	if out_see_score != nil {
		if mp.has_see_scores || mp.staged {
			out_see_score^ = mp.see_scores[mp.index]
		} else {
			out_see_score^ = SEE_SCORE_UNKNOWN
		}
	}

	mp.index += 1
	mp.current_ordered = false
	return true
}
