package search

import "../board"
import "../constants"
import "../eval"
import "../moves"
import "../nnue"
import "../tb"
import "../utils"
import "../zobrist"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"

// Search Constants
MAX_PLY :: 64
TIGHT_CHECK_EVASION_SEED_LIMIT_MS :: 100
MOVETIME_CHECK_EVASION_TT_CLEAR_LIMIT_MS :: 250

should_clear_movetime_check_evasion_tt :: proc(b: ^board.Board, limits: SearchLimits) -> bool {
	if !limits.is_movetime || limits.is_infinite {
		return false
	}
	if limits.hard_time > MOVETIME_CHECK_EVASION_TT_CLEAR_LIMIT_MS {
		return false
	}

	king_sq := board.get_king_square(b, b.side)
	if king_sq < 0 {
		return false
	}
	return board.is_square_attacked(b, king_sq, 1 - b.side)
}

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
	moves:       [MAX_PLY]moves.Move,
	count:       int,
	tb_terminal: bool,
}

// MultiPV Result - stores move, score, and PV for each line
MultiPV_Result :: struct {
	move:  moves.Move,
	score: int,
	pv:    PV_Line,
}

RootSearchPassEntry :: struct {
	move:         moves.Move,
	order_index:  int,
	score:        int,
	alpha_before: int,
	nodes:        u64,
}

RootSearchPassResult :: struct {
	best_score:    int,
	best_move:     moves.Move,
	best_pv:       PV_Line,
	found_move:    bool,
	completed:     bool,
	root_tt_seen:  bool,
	root_tt_score: int,
	entries:       [256]RootSearchPassEntry,
	count:         int,
}

RootVerifyCandidateSet :: struct {
	include:  [256]bool,
	reason:   [256]string,
	priority: [256]int,
	count:    int,
}

RootVerifySuspectResult :: struct {
	moves: [4]moves.Move,
	count: int,
	nodes: u64,
}


// Thread-local search state
SearchThread :: struct {
	thread_id:            int,
	nodes:                u64,
	killer_moves:         [MAX_PLY][2]moves.Move,
	history_table:        [12][64]int,
	capture_history:      [12][64]int,
	counter_moves:        [12][64]moves.Move,
	continuation_history: ^[6][64][6][64]int,
	static_eval_stack:    [MAX_PLY]int,
	extend_all_checks:    bool,
	root_pawn_only_endgame: bool,
}

// Global atomic node counter for UCI reporting
total_nodes: u64 = 0

last_completed_best_move: moves.Move
last_completed_best_score: int
last_completed_depth: int

reset_shared_search_state :: proc(reset_last_completed: bool = true) {
	if reset_last_completed {
		last_completed_best_move = moves.Move{}
		last_completed_best_score = 0
		last_completed_depth = 0
	}
	sync.atomic_store(&total_nodes, 0)
	reset_search_stats()
}

SearchDebugOptions :: struct {
	disable_tt_cutoffs: bool,
	disable_lmr:        bool,
	disable_futility:   bool,
	disable_lmp:        bool,
	disable_nmp:        bool,
	disable_rfp:        bool,
	disable_razor:      bool,
	disable_probcut:    bool,
	disable_iir:        bool,
}

search_debug_options: SearchDebugOptions

SearchStats :: struct {
	nodes:              u64,
	qnodes:             u64,
	evals:              u64,
	movegen_calls:      u64,
	moves_generated:    u64,
	legal_rejects:      u64,
	tt_probes:          u64,
	tt_hits:            u64,
	tt_cutoffs:         u64,
	tt_stores:          u64,
	tt_exact_hits:      u64,
	tt_alpha_hits:      u64,
	tt_beta_hits:       u64,
	tt_exact_cutoffs:   u64,
	tt_alpha_cutoffs:   u64,
	tt_beta_cutoffs:    u64,
	tt_depth_misses:    u64,
	tt_move_probes:     u64,
	tt_move_hits:       u64,
	tt_move_invalid:    u64,
	tt_move_ordered:    u64,
	tt_move_first:      u64,
	tt_move_first_legal: u64,
	tt_move_legal_rejects: u64,
	root_pv_ordered:    u64,
	root_pv_first:      u64,
	root_pv_first_legal: u64,
	tt_same_key_updates: u64,
	tt_same_key_kept:   u64,
	tt_replacements:    u64,
	tt_empty_replaces:  u64,
	tt_stale_replaces:  u64,
	tt_deeper_replaces: u64,
	tb_probes:          u64,
	tb_hits:            u64,
	nmp_tries:          u64,
	nmp_cutoffs:        u64,
	rfp_cutoffs:        u64,
	razor_tries:        u64,
	razor_cutoffs:      u64,
	probcut_tries:      u64,
	probcut_cutoffs:    u64,
	futility_prunes:    u64,
	lmp_prunes:         u64,
	lmr_searches:       u64,
	lmr_researches:     u64,
	pvs_researches:     u64,
	q_delta_prunes:     u64,
	q_see_prunes:       u64,
	see_calls:          u64,
	see_cache_hits:     u64,
	beta_cutoffs:       u64,
	quiet_beta_cutoffs: u64,
	capture_beta_cutoffs: u64,
	capture_history_updates: u64,
	capture_history_maluses: u64,
	continuation_updates: u64,
	continuation_maluses: u64,
	continuation_score_probes: u64,
	continuation_score_raw_nonzero: u64,
	continuation_score_raw_positive: u64,
	continuation_score_raw_negative: u64,
	continuation_score_raw_abs_sum: u64,
	continuation_score_raw_under_scale: u64,
	continuation_score_nonzero: u64,
	continuation_score_positive: u64,
	continuation_score_negative: u64,
	continuation_score_abs_sum: u64,
	continuation_store_bonus_under_scale: u64,
	continuation_store_bonus_visible: u64,
	continuation_store_result_under_scale: u64,
	continuation_store_result_visible: u64,
	aspiration_fail_low:  u64,
	aspiration_fail_high: u64,
	aspiration_retries:   u64,
	aspiration_verifies:  u64,
}

search_stats_enabled: bool = false
root_debug_trace_enabled: bool = false
search_stats: SearchStats

reset_search_stats :: proc() {
	search_stats = SearchStats{}
}

stat_add :: proc(counter: ^u64, amount: u64 = 1) {
	if search_stats_enabled {
		sync.atomic_add(counter, amount)
	}
}

stat_load :: proc(counter: ^u64) -> u64 {
	return sync.atomic_load(counter)
}

print_search_stats :: proc() {
	if !search_stats_enabled {return}

	nodes := stat_load(&search_stats.nodes)
	qnodes := stat_load(&search_stats.qnodes)
	tt_probes := stat_load(&search_stats.tt_probes)
	tt_hits := stat_load(&search_stats.tt_hits)
	tt_cutoffs := stat_load(&search_stats.tt_cutoffs)
	movegen_calls := stat_load(&search_stats.movegen_calls)
	moves_generated := stat_load(&search_stats.moves_generated)
	see_calls := stat_load(&search_stats.see_calls)

	tt_hit_pct: u64 = 0
	tt_cut_pct: u64 = 0
	avg_moves: u64 = 0
	qnode_pct: u64 = 0
	if tt_probes > 0 {
		tt_hit_pct = tt_hits * 100 / tt_probes
		tt_cut_pct = tt_cutoffs * 100 / tt_probes
	}
	if movegen_calls > 0 {
		avg_moves = moves_generated / movegen_calls
	}
	if nodes > 0 {
		qnode_pct = qnodes * 100 / nodes
	}

	fmt.printf(
		"info string stats nodes=%d qnodes=%d qnode_pct=%d evals=%d movegen=%d avg_moves=%d legal_rejects=%d see=%d\n",
		nodes,
		qnodes,
		qnode_pct,
		stat_load(&search_stats.evals),
		movegen_calls,
		avg_moves,
		stat_load(&search_stats.legal_rejects),
		see_calls,
	)
	fmt.printf(
		"info string stats see cache_hits=%d qsee_prunes=%d\n",
		stat_load(&search_stats.see_cache_hits),
		stat_load(&search_stats.q_see_prunes),
	)
	fmt.printf(
		"info string stats tt probes=%d hits=%d hit_pct=%d cutoffs=%d cut_pct=%d stores=%d tb_probes=%d tb_hits=%d\n",
		tt_probes,
		tt_hits,
		tt_hit_pct,
		tt_cutoffs,
		tt_cut_pct,
		stat_load(&search_stats.tt_stores),
		stat_load(&search_stats.tb_probes),
		stat_load(&search_stats.tb_hits),
	)
	fmt.printf(
		"info string stats ttdetail exact_hits=%d alpha_hits=%d beta_hits=%d exact_cutoffs=%d alpha_cutoffs=%d beta_cutoffs=%d depth_misses=%d\n",
		stat_load(&search_stats.tt_exact_hits),
		stat_load(&search_stats.tt_alpha_hits),
		stat_load(&search_stats.tt_beta_hits),
		stat_load(&search_stats.tt_exact_cutoffs),
		stat_load(&search_stats.tt_alpha_cutoffs),
		stat_load(&search_stats.tt_beta_cutoffs),
		stat_load(&search_stats.tt_depth_misses),
	)
	fmt.printf(
		"info string stats ttmove probes=%d hits=%d invalid=%d ordered=%d same_key_updates=%d same_key_kept=%d replacements=%d empty_replacements=%d stale_replacements=%d deeper_replacements=%d\n",
		stat_load(&search_stats.tt_move_probes),
		stat_load(&search_stats.tt_move_hits),
		stat_load(&search_stats.tt_move_invalid),
		stat_load(&search_stats.tt_move_ordered),
		stat_load(&search_stats.tt_same_key_updates),
		stat_load(&search_stats.tt_same_key_kept),
		stat_load(&search_stats.tt_replacements),
		stat_load(&search_stats.tt_empty_replaces),
		stat_load(&search_stats.tt_stale_replaces),
		stat_load(&search_stats.tt_deeper_replaces),
	)
	fmt.printf(
		"info string stats moveorder tt_first=%d tt_first_legal=%d tt_legal_rejects=%d root_pv_ordered=%d root_pv_first=%d root_pv_first_legal=%d\n",
		stat_load(&search_stats.tt_move_first),
		stat_load(&search_stats.tt_move_first_legal),
		stat_load(&search_stats.tt_move_legal_rejects),
		stat_load(&search_stats.root_pv_ordered),
		stat_load(&search_stats.root_pv_first),
		stat_load(&search_stats.root_pv_first_legal),
	)
	fmt.printf(
		"info string stats prune nmp=%d/%d rfp=%d razor=%d/%d probcut=%d/%d futility=%d lmp=%d qdelta=%d qsee=%d\n",
		stat_load(&search_stats.nmp_cutoffs),
		stat_load(&search_stats.nmp_tries),
		stat_load(&search_stats.rfp_cutoffs),
		stat_load(&search_stats.razor_cutoffs),
		stat_load(&search_stats.razor_tries),
		stat_load(&search_stats.probcut_cutoffs),
		stat_load(&search_stats.probcut_tries),
		stat_load(&search_stats.futility_prunes),
		stat_load(&search_stats.lmp_prunes),
		stat_load(&search_stats.q_delta_prunes),
		stat_load(&search_stats.q_see_prunes),
	)
	fmt.printf(
		"info string stats search beta_cutoffs=%d quiet_beta=%d capture_beta=%d capture_hist_updates=%d capture_hist_maluses=%d cont_updates=%d cont_maluses=%d lmr=%d lmr_research=%d pvs_research=%d asp_low=%d asp_high=%d asp_retry=%d asp_verify=%d\n",
		stat_load(&search_stats.beta_cutoffs),
		stat_load(&search_stats.quiet_beta_cutoffs),
		stat_load(&search_stats.capture_beta_cutoffs),
		stat_load(&search_stats.capture_history_updates),
		stat_load(&search_stats.capture_history_maluses),
		stat_load(&search_stats.continuation_updates),
		stat_load(&search_stats.continuation_maluses),
		stat_load(&search_stats.lmr_searches),
		stat_load(&search_stats.lmr_researches),
		stat_load(&search_stats.pvs_researches),
		stat_load(&search_stats.aspiration_fail_low),
		stat_load(&search_stats.aspiration_fail_high),
		stat_load(&search_stats.aspiration_retries),
		stat_load(&search_stats.aspiration_verifies),
	)
	fmt.printf(
		"info string stats continuation cont_score_probes=%d cont_raw_nonzero=%d cont_raw_positive=%d cont_raw_negative=%d cont_raw_abs_sum=%d cont_raw_under_scale=%d cont_score_nonzero=%d cont_score_positive=%d cont_score_negative=%d cont_score_abs_sum=%d\n",
		stat_load(&search_stats.continuation_score_probes),
		stat_load(&search_stats.continuation_score_raw_nonzero),
		stat_load(&search_stats.continuation_score_raw_positive),
		stat_load(&search_stats.continuation_score_raw_negative),
		stat_load(&search_stats.continuation_score_raw_abs_sum),
		stat_load(&search_stats.continuation_score_raw_under_scale),
		stat_load(&search_stats.continuation_score_nonzero),
		stat_load(&search_stats.continuation_score_positive),
		stat_load(&search_stats.continuation_score_negative),
		stat_load(&search_stats.continuation_score_abs_sum),
	)
	fmt.printf(
		"info string stats continuation_store cont_store_bonus_under_scale=%d cont_store_bonus_visible=%d cont_store_result_under_scale=%d cont_store_result_visible=%d\n",
		stat_load(&search_stats.continuation_store_bonus_under_scale),
		stat_load(&search_stats.continuation_store_bonus_visible),
		stat_load(&search_stats.continuation_store_result_under_scale),
		stat_load(&search_stats.continuation_store_result_visible),
	)
	os.flush(os.stdout)
}

same_move :: proc(a, b: moves.Move) -> bool {
	return !moves.is_empty_move(a) &&
		a.source == b.source &&
		a.target == b.target &&
		a.promoted == b.promoted
}

same_qcapture_move :: proc(a, b: moves.Move) -> bool {
	return a.source == b.source &&
		a.target == b.target &&
		a.piece == b.piece &&
		a.promoted == b.promoted &&
		a.capture == b.capture &&
		a.en_passant == b.en_passant
}

QCaptureOrder :: struct {
	moves: [256]moves.Move,
	count: int,
}

qcapture_order_append :: proc(order: ^QCaptureOrder, move: moves.Move) {
	if order.count < len(order.moves) {
		order.moves[order.count] = move
		order.count += 1
	}
}

collect_qcaptures_from_full_order :: proc(st: ^SearchThread, b: ^board.Board, order: ^QCaptureOrder) {
	move_list: moves.MoveList
	board.generate_all_moves(b, &move_list)

	see_scores: [256]int
	sort_moves(st, &move_list, b, see_scores = &see_scores)

	for i in 0 ..< move_list.count {
		if move_list.moves[i].capture {
			qcapture_order_append(order, move_list.moves[i])
		}
	}
}

order_qcaptures_from_full_order_cached :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	q_see_scores: ^[256]int,
	capture_list: ^moves.MoveList,
	capture_scores: ^[256]int,
	capture_see_scores: ^[256]int,
) -> int {
	full_list: moves.MoveList
	board.generate_all_moves(b, &full_list)

	scores: [256]int
	see_scores: [256]int
	order: [256]int

	for i in 0 ..< full_list.count {
		order[i] = i
		see_score := SEE_SCORE_UNKNOWN
		score := 0
		if full_list.moves[i].capture {
			cached_idx := -1
			for j in 0 ..< capture_list.count {
				if same_qcapture_move(full_list.moves[i], capture_list.moves[j]) {
					cached_idx = j
					break
				}
			}
			if cached_idx != -1 {
				see_score = capture_see_scores[cached_idx]
				score = capture_scores[cached_idx]
			} else {
				see_score = see_capture(b, full_list.moves[i])
				score = score_move(st, full_list.moves[i], b, moves.Move{}, 0, moves.Move{}, see_score)
			}
		} else {
			score = score_move(st, full_list.moves[i], b, moves.Move{}, 0, moves.Move{}, see_score)
		}
		see_scores[i] = see_score
		scores[i] = score
	}

	for i in 0 ..< full_list.count {
		for j in i + 1 ..< full_list.count {
			if scores[order[j]] > scores[order[i]] {
				temp := order[i]
				order[i] = order[j]
				order[j] = temp
			}
		}
	}

	move_list.count = 0
	for i in 0 ..< full_list.count {
		idx := order[i]
		if full_list.moves[idx].capture {
			q_see_scores[move_list.count] = see_scores[idx]
			moves.append_move(move_list, full_list.moves[idx])
		}
	}

	return full_list.count
}

order_qcaptures_from_capture_generator :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	q_see_scores: ^[256]int,
	include_quiet_promotions: bool = false,
) -> int {
	if include_quiet_promotions {
		board.generate_quiescence_moves(b, move_list)
	} else {
		board.generate_capture_moves(b, move_list)
	}

	scores: [256]int
	has_duplicate_scores := false
	for i in 0 ..< move_list.count {
		see_score := SEE_SCORE_UNKNOWN
		if move_list.moves[i].capture {
			see_score = see_capture(b, move_list.moves[i])
		}
		q_see_scores[i] = see_score
		scores[i] = score_move(st, move_list.moves[i], b, moves.Move{}, 0, moves.Move{}, see_score)

		for j in 0 ..< i {
			if scores[j] == scores[i] {
				has_duplicate_scores = true
			}
		}
	}

	if include_quiet_promotions && has_duplicate_scores {
		// The full exchange sort is not stable: high-scoring quiets can
		// indirectly reorder equal-scored captures, so ties need fallback.
		// Quiet promotions are already high-scoring tactical qsearch moves;
		// keep the compact ordering when they are present.
		has_quiet_promotion := false
		for i in 0 ..< move_list.count {
			if !move_list.moves[i].capture && move_list.moves[i].promoted != -1 {
				has_quiet_promotion = true
				break
			}
		}
		if has_quiet_promotion {
			has_duplicate_scores = false
		}
	}

	if has_duplicate_scores {
		capture_list := move_list^
		capture_scores := scores
		capture_see_scores := q_see_scores^
		return order_qcaptures_from_full_order_cached(
			st,
			b,
			move_list,
			q_see_scores,
			&capture_list,
			&capture_scores,
			&capture_see_scores,
		)
	}

	for i in 0 ..< move_list.count {
		for j in i + 1 ..< move_list.count {
			if scores[j] > scores[i] {
				temp_score := scores[i]
				scores[i] = scores[j]
				scores[j] = temp_score

				temp_move := move_list.moves[i]
				move_list.moves[i] = move_list.moves[j]
				move_list.moves[j] = temp_move

				temp_see := q_see_scores[i]
				q_see_scores[i] = q_see_scores[j]
				q_see_scores[j] = temp_see
			}
		}
	}

	return move_list.count
}

collect_qcaptures_from_projected_order :: proc(st: ^SearchThread, b: ^board.Board, order: ^QCaptureOrder) {
	move_list: moves.MoveList
	see_scores: [256]int
	order_qcaptures_from_capture_generator(st, b, &move_list, &see_scores)

	for i in 0 ..< move_list.count {
		qcapture_order_append(order, move_list.moves[i])
	}
}

print_qcapture_mismatch :: proc(full_order, compact_order: ^QCaptureOrder, index: int) {
	fmt.printf("QCapture parity mismatch at index %d\n", index)
	if index < full_order.count {
		fmt.printf("  full:    ")
		board.print_move(full_order.moves[index])
		fmt.println()
	} else {
		fmt.println("  full:    <none>")
	}
	if index < compact_order.count {
		fmt.printf("  projected: ")
		board.print_move(compact_order.moves[index])
		fmt.println()
	} else {
		fmt.println("  projected: <none>")
	}
}

compare_qcapture_orders :: proc(st: ^SearchThread, b: ^board.Board, verbose: bool = false) -> bool {
	full_order: QCaptureOrder
	projected_order: QCaptureOrder

	collect_qcaptures_from_full_order(st, b, &full_order)
	collect_qcaptures_from_projected_order(st, b, &projected_order)

	if full_order.count != projected_order.count {
		if verbose {
			fmt.printf("QCapture count mismatch: full=%d projected=%d fen=%s\n", full_order.count, projected_order.count, board.get_fen(b^))
			print_qcapture_mismatch(&full_order, &projected_order, min(full_order.count, projected_order.count))
		}
		return false
	}

	for i in 0 ..< full_order.count {
		if !same_qcapture_move(full_order.moves[i], projected_order.moves[i]) {
			if verbose {
				fmt.printf("fen=%s\n", board.get_fen(b^))
				print_qcapture_mismatch(&full_order, &projected_order, i)
			}
			return false
		}
	}

	return true
}

validate_qcapture_parity_node :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	depth: int,
	checked: ^u64,
	mismatches: ^u64,
) -> bool {
	king_sq := board.get_king_square(b, b.side)
	in_check := board.is_square_attacked(b, king_sq, 1 - b.side)
	if !in_check {
		checked^ += 1
		if !compare_qcapture_orders(st, b, true) {
			mismatches^ += 1
			return false
		}
	}

	if depth <= 0 {
		return true
	}

	move_list: moves.MoveList
	board.generate_all_moves(b, &move_list)
	for i in 0 ..< move_list.count {
		if !board.is_castling_legal_now(b, move_list.moves[i]) {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move_list.moves[i], &state)

		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			continue
		}

		if !validate_qcapture_parity_node(st, b, depth - 1, checked, mismatches) {
			board.unmake_move(b, &state)
			return false
		}
		board.unmake_move(b, &state)
	}

	return true
}

validate_qcapture_parity_test :: proc(fen: string, depth: int) {
	b := board.parse_fen(fen)
	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	checked: u64 = 0
	mismatches: u64 = 0
	ok := validate_qcapture_parity_node(&st, &b, depth, &checked, &mismatches)
	if ok {
		fmt.printf("QCapture parity OK: positions=%d depth=%d\n", checked, depth)
	} else {
		fmt.printf("QCapture parity FAILED: checked=%d mismatches=%d depth=%d\n", checked, mismatches, depth)
	}
}

clone_search_thread :: proc(src: ^SearchThread) -> SearchThread {
	dst := src^
	if src.continuation_history != nil {
		dst.continuation_history = new([6][64][6][64]int)
		mem.copy(dst.continuation_history, src.continuation_history, size_of([6][64][6][64]int))
	}
	return dst
}

snapshot_tt :: proc() -> []TTBucket {
	snapshot := make([]TTBucket, len(tt))
	if len(tt) > 0 {
		mem.copy(&snapshot[0], &tt[0], len(tt) * size_of(TTBucket))
	}
	return snapshot
}

restore_tt :: proc(snapshot: []TTBucket) {
	if len(tt) == 0 || len(snapshot) == 0 {
		return
	}
	count := len(tt)
	if len(snapshot) < count {
		count = len(snapshot)
	}
	mem.copy(&tt[0], &snapshot[0], count * size_of(TTBucket))
}

move_matches_uci :: proc(move: moves.Move, move_text: string) -> bool {
	if len(move_text) < 4 {
		return false
	}

	sf := int(move_text[0] - 'a')
	sr := int(move_text[1] - '1')
	tf := int(move_text[2] - 'a')
	tr := int(move_text[3] - '1')
	if sf < 0 || sf > 7 || sr < 0 || sr > 7 || tf < 0 || tf > 7 || tr < 0 || tr > 7 {
		return false
	}

	if move.source != sr * 8 + sf || move.target != tr * 8 + tf {
		return false
	}

	if len(move_text) >= 5 {
		promoted := -1
		switch move_text[4] {
		case 'n':
			promoted = constants.KNIGHT
		case 'b':
			promoted = constants.BISHOP
		case 'r':
			promoted = constants.ROOK
		case 'q':
			promoted = constants.QUEEN
		}
		return move.promoted == promoted
	}

	return true
}

refresh_trace_accumulators :: proc(b: ^board.Board) {
	if nnue.sfnnv14_active {
		nnue.refresh_sfnnv14_accumulators(b)
	} else if nnue.is_initialized {
		b.accumulators[constants.WHITE] = nnue.compute_accumulator(b, constants.WHITE)
		b.accumulators[constants.BLACK] = nnue.compute_accumulator(b, constants.BLACK)
	}
}

print_probe_variant :: proc(
	name: string,
	st: ^SearchThread,
	b: ^board.Board,
	tt_snapshot: []TTBucket,
	depth: int,
	alpha_before: int,
	options: SearchDebugOptions,
	full_window: bool = false,
) {
	restore_tt(tt_snapshot)
	probe_st := clone_search_thread(st)
	defer free(probe_st.continuation_history)
	probe_st.nodes = 0

	prev_options := search_debug_options
	prev_stats_enabled := search_stats_enabled
	search_debug_options = options
	search_stats_enabled = true
	reset_search_stats()

	child_pv: PV_Line
	child_alpha := -alpha_before - 1
	child_beta := -alpha_before
	probe_is_pv := false
	if full_window {
		child_alpha = -eval.INF
		child_beta = eval.INF
		probe_is_pv = true
	}

	score := -negamax(
		&probe_st,
		b,
		child_alpha,
		child_beta,
		depth - 1,
		1,
		&child_pv,
		{},
		probe_is_pv,
	)

	nodes := stat_load(&search_stats.nodes)
	tt_cutoffs := stat_load(&search_stats.tt_cutoffs)
	tt_exact := stat_load(&search_stats.tt_exact_cutoffs)
	tt_alpha := stat_load(&search_stats.tt_alpha_cutoffs)
	tt_beta := stat_load(&search_stats.tt_beta_cutoffs)
	lmr := stat_load(&search_stats.lmr_searches)
	lmr_research := stat_load(&search_stats.lmr_researches)
	futility := stat_load(&search_stats.futility_prunes)
	lmp := stat_load(&search_stats.lmp_prunes)
	nmp_tries := stat_load(&search_stats.nmp_tries)
	nmp_cutoffs := stat_load(&search_stats.nmp_cutoffs)
	rfp := stat_load(&search_stats.rfp_cutoffs)
	razor_tries := stat_load(&search_stats.razor_tries)
	razor_cutoffs := stat_load(&search_stats.razor_cutoffs)
	probcut_tries := stat_load(&search_stats.probcut_tries)
	probcut_cutoffs := stat_load(&search_stats.probcut_cutoffs)
	qnodes := stat_load(&search_stats.qnodes)

	search_debug_options = prev_options
	search_stats_enabled = prev_stats_enabled

	raised := "no"
	if score > alpha_before {
		raised = "yes"
	}

	fmt.printf(
		"variant=%s score=%d raises_alpha=%s nodes=%d qnodes=%d tt_cutoffs=%d(exact=%d alpha=%d beta=%d) nmp=%d/%d rfp=%d razor=%d/%d probcut=%d/%d lmr=%d lmr_research=%d futility=%d lmp=%d\n",
		name,
		score,
		raised,
		nodes,
		qnodes,
		tt_cutoffs,
		tt_exact,
		tt_alpha,
		tt_beta,
		nmp_cutoffs,
		nmp_tries,
		rfp,
		razor_cutoffs,
		razor_tries,
		probcut_cutoffs,
		probcut_tries,
		lmr,
		lmr_research,
		futility,
		lmp,
	)
}

root_debug_print_move :: proc(move: moves.Move) {
	if moves.is_empty_move(move) {
		fmt.printf("(none)")
	} else {
		board.print_move(move)
	}
}

root_debug_print_pv :: proc(root_move: moves.Move, child_pv: ^PV_Line) {
	board.print_move(root_move)
	for i in 0 ..< child_pv.count {
		fmt.printf(" ")
		board.print_move(child_pv.moves[i])
	}
}

trace_root_move_scores :: proc(fen: string, depth: int) {
	if depth < 1 {
		fmt.println("Root trace FAILED: depth must be at least 1")
		return
	}

	b := board.parse_fen(fen)
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
	}

	move_list: moves.MoveList
	board.generate_all_moves(&b, &move_list)
	root_tt_move := warmup_best_move
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}
	sort_moves(&st, &move_list, &b, root_tt_move, 0, moves.Move{})

	fmt.printf("Root trace depth=%d warmup_depth=%d warmup_score=%d warmup_best=", depth, warmup_depth, warmup_score)
	if !moves.is_empty_move(root_tt_move) {
		board.print_move(root_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" fen=%s\n", fen)
	fmt.println("idx move full null alpha_before delta nodes_full nodes_null action note")

	current_alpha := -eval.INF
	best_score := -eval.INF
	best_move: moves.Move
	legal_moves := 0
	misses := 0
	researches := 0

	for i in 0 ..< move_list.count {
		move := move_list.moves[i]
		if !board.is_castling_legal_now(&b, move) {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(&b, move, &state)
		king_sq := board.get_king_square(&b, 1 - b.side)
		if board.is_square_attacked(&b, king_sq, b.side) {
			board.unmake_move(&b, &state)
			continue
		}

		nnue.update_accumulators(&state, &b, move)

		alpha_before := current_alpha
		null_score := 0
		null_nodes: u64 = 0
		ran_null := legal_moves > 0 && alpha_before > -eval.INF / 2
		if ran_null {
			tt_snapshot := snapshot_tt()
			null_st := clone_search_thread(&st)
			null_st.nodes = 0
			null_pv: PV_Line
			null_score = -negamax(
				&null_st,
				&b,
				-alpha_before - 1,
				-alpha_before,
				depth - 1,
				1,
				&null_pv,
				{}, // no excluded move
				false, // null-window non-PV probe
			)
			null_nodes = null_st.nodes
			if null_st.continuation_history != nil {
				free(null_st.continuation_history)
			}
			restore_tt(tt_snapshot)
			delete(tt_snapshot)
		}

		full_nodes_before := st.nodes
		child_pv: PV_Line
		full_score := -negamax(
			&st,
			&b,
			-eval.INF,
			eval.INF,
			depth - 1,
			1,
			&child_pv,
		)
		full_nodes := st.nodes - full_nodes_before
		board.unmake_move(&b, &state)

		if full_score > best_score {
			best_score = full_score
			best_move = move
		}

		action := "first"
		note := "ok"
		delta := 0
		if ran_null {
			delta = full_score - null_score
			if null_score > alpha_before {
				action = "research"
				researches += 1
			} else {
				action = "prune"
			}
			if full_score > alpha_before && null_score <= alpha_before {
				note = "MISS_FAIL_HIGH"
				misses += 1
			}
		}

		fmt.printf("%2d ", legal_moves + 1)
		board.print_move(move)
		if ran_null {
			fmt.printf(
				" full=%d null=%d alpha=%d delta=%d nodes_full=%d nodes_null=%d action=%s note=%s\n",
				full_score,
				null_score,
				alpha_before,
				delta,
				full_nodes,
				null_nodes,
				action,
				note,
			)
		} else {
			fmt.printf(
				" full=%d null=NA alpha=NA delta=NA nodes_full=%d nodes_null=0 action=%s note=%s\n",
				full_score,
				full_nodes,
				action,
				note,
			)
		}

		if full_score > current_alpha {
			current_alpha = full_score
		}
		legal_moves += 1
	}

	fmt.printf("summary legal=%d best=", legal_moves)
	if !moves.is_empty_move(best_move) {
		board.print_move(best_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" best_score=%d misses=%d researches=%d\n", best_score, misses, researches)
}

RootParityScore :: struct {
	score: int,
	nodes: u64,
	pv:    PV_Line,
}

trace_score_root_child_from_snapshot :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move: moves.Move,
	tt_snapshot: []TTBucket,
	depth: int,
	alpha: int,
	beta: int,
	is_pv: bool,
) -> RootParityScore {
	restore_tt(tt_snapshot)

	probe_st := clone_search_thread(st)
	defer free(probe_st.continuation_history)
	probe_st.nodes = 0

	state: board.StateInfo
	board.make_move_fast(b, move, &state)
	nnue.update_accumulators(&state, b, move)

	child_pv: PV_Line
	score := -negamax(
		&probe_st,
		b,
		alpha,
		beta,
		depth - 1,
		1,
		&child_pv,
		{}, // no excluded move
		is_pv,
	)

	board.unmake_move(b, &state)
	restore_tt(tt_snapshot)

	return RootParityScore {
		score = score,
		nodes = probe_st.nodes,
		pv    = child_pv,
	}
}

trace_root_parity_targeted :: proc(move: moves.Move, target_moves: []string) -> bool {
	for target in target_moves {
		if move_matches_uci(move, target) {
			return true
		}
	}
	return false
}

trace_root_parity_scores :: proc(fen: string, depth: int, target_moves: []string) {
	if depth < 1 {
		fmt.println("Root parity trace FAILED: depth must be at least 1")
		return
	}

	b := board.parse_fen(fen)
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
	}

	move_list: moves.MoveList
	board.generate_all_moves(&b, &move_list)
	root_tt_move := warmup_best_move
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}
	sort_moves(&st, &move_list, &b, root_tt_move, 0, moves.Move{})

	tt_snapshot := snapshot_tt()
	defer delete(tt_snapshot)

	fmt.printf("Root parity trace depth=%d warmup_depth=%d warmup_score=%d warmup_best=", depth, warmup_depth, warmup_score)
	if !moves.is_empty_move(root_tt_move) {
		board.print_move(root_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" targets=%d fen=%s\n", len(target_moves), fen)
	fmt.println("idx move target alpha full pvs delta full_nodes pvs_nodes pvs_raises note full_pv")

	current_alpha := -eval.INF
	best_score := -eval.INF
	best_move: moves.Move
	legal_moves := 0
	scored_moves := 0
	targets_seen := 0
	default_limit := 12

	for i in 0 ..< move_list.count {
		move := move_list.moves[i]
		if !trace_root_legal_move(&b, move) {
			continue
		}

		is_target := trace_root_parity_targeted(move, target_moves)
		if len(target_moves) == 0 && scored_moves >= default_limit {
			break
		}

		full := trace_score_root_child_from_snapshot(
			&st,
			&b,
			move,
			tt_snapshot,
			depth,
			-eval.INF,
			eval.INF,
			true,
		)

		alpha_before := current_alpha
		pvs_score := 0
		pvs_nodes: u64 = 0
		pvs_raises := false
		delta := 0
		note := "first"
		if legal_moves > 0 && alpha_before > -eval.INF / 2 {
			pvs := trace_score_root_child_from_snapshot(
				&st,
				&b,
				move,
				tt_snapshot,
				depth,
				-alpha_before - 1,
				-alpha_before,
				false,
			)
			pvs_score = pvs.score
			pvs_nodes = pvs.nodes
			pvs_raises = pvs_score > alpha_before
			delta = full.score - pvs_score
			note = "ok"
			if full.score > alpha_before && !pvs_raises {
				note = "PVS_MISS"
			} else if delta != 0 {
				note = "BOUND_DIFF"
			}
		}

		fmt.printf("%2d ", legal_moves + 1)
		board.print_move(move)
		if legal_moves > 0 && alpha_before > -eval.INF / 2 {
			fmt.printf(
				" target=%v alpha=%d full=%d pvs=%d delta=%d full_nodes=%d pvs_nodes=%d pvs_raises=%v note=%s full_pv=",
				is_target,
				alpha_before,
				full.score,
				pvs_score,
				delta,
				full.nodes,
				pvs_nodes,
				pvs_raises,
				note,
			)
		} else {
			fmt.printf(
				" target=%v alpha=NA full=%d pvs=NA delta=NA full_nodes=%d pvs_nodes=0 pvs_raises=false note=%s full_pv=",
				is_target,
				full.score,
				full.nodes,
				note,
			)
		}
		root_debug_print_pv(move, &full.pv)
		fmt.println()
		os.flush(os.stdout)

		if is_target && note == "PVS_MISS" {
			state: board.StateInfo
			board.make_move_fast(&b, move, &state)
			nnue.update_accumulators(&state, &b, move)
			print_probe_variant("snapshot_full", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{}, true)
			print_probe_variant("snapshot_baseline", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{})
			print_probe_variant("snapshot_no_tt", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_tt_cutoffs = true})
			print_probe_variant("snapshot_no_lmr", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_lmr = true})
			print_probe_variant("snapshot_no_futility", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_futility = true})
			print_probe_variant("snapshot_no_lmp", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_lmp = true})
			print_probe_variant("snapshot_no_nmp", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_nmp = true})
			print_probe_variant("snapshot_no_rfp", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_rfp = true})
			print_probe_variant("snapshot_no_razor", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_razor = true})
			print_probe_variant("snapshot_no_probcut", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_probcut = true})
			print_probe_variant("snapshot_no_iir", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_iir = true}, true)
			print_probe_variant(
				"snapshot_no_all_prune_reduce",
				&st,
				&b,
				tt_snapshot,
				depth,
				alpha_before,
				SearchDebugOptions {
					disable_tt_cutoffs = true,
					disable_lmr        = true,
					disable_futility   = true,
					disable_lmp        = true,
					disable_nmp        = true,
					disable_rfp        = true,
					disable_razor      = true,
					disable_probcut    = true,
					disable_iir        = true,
				},
			)
			board.unmake_move(&b, &state)
			restore_tt(tt_snapshot)
		}

		if full.score > best_score {
			best_score = full.score
			best_move = move
		}
		if full.score > current_alpha {
			current_alpha = full.score
		}

		legal_moves += 1
		scored_moves += 1
		if is_target {
			targets_seen += 1
		}
		if len(target_moves) > 0 && targets_seen >= len(target_moves) {
			break
		}
	}

	fmt.printf("summary scored=%d legal_seen=%d best=", scored_moves, legal_moves)
	if !moves.is_empty_move(best_move) {
		board.print_move(best_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" best_score=%d final_alpha=%d targets_seen=%d\n", best_score, current_alpha, targets_seen)
}

RootVerifyTraceEntry :: struct {
	move:        moves.Move,
	order_index: int,
	included:    bool,
	reason:      string,
	score:       int,
	nodes:       u64,
	history:     int,
	see:         int,
}

RootVerifyTraceResult :: struct {
	best_move:  moves.Move,
	best_score: int,
	found_move: bool,
	entries:    [256]RootVerifyTraceEntry,
	count:      int,
	total_nodes: u64,
}

find_root_verify_trace_entry :: proc(result: ^RootVerifyTraceResult, move: moves.Move) -> int {
	for i in 0 ..< result.count {
		if same_move(result.entries[i].move, move) {
			return i
		}
	}
	return -1
}

run_root_verify_trace_pass :: proc(
	result: ^RootVerifyTraceResult,
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	depth: int,
	root_tt_move: moves.Move,
	verify_all: bool = false,
	extra_verify_move_1: moves.Move = moves.Move{},
	extra_verify_move_2: moves.Move = moves.Move{},
	candidate_set: ^RootVerifyCandidateSet = nil,
	tt_snapshot: []TTBucket = nil,
) {
	result.best_score = -eval.INF
	result.best_move = moves.Move{}
	result.found_move = false
	result.count = 0

	for i in 0 ..< move_list.count {
		move := move_list.moves[i]
		included := true
		reason := "forced"
		history_score := 0
		see_score := SEE_SCORE_UNKNOWN

		if candidate_set != nil && i < candidate_set.count {
			included = verify_all || candidate_set.include[i]
			reason = candidate_set.reason[i]
		} else {
			included, reason, _ = root_verify_candidate_decision(
				st,
				b,
				move,
				root_tt_move,
				verify_all,
				extra_verify_move_1,
				extra_verify_move_2,
			)
		}

		if move.capture {
			see_score = see_capture(b, move)
		} else if move.promoted == -1 {
			history_score = get_history_score(st, move)
		}

		entry_index := result.count
		if entry_index < len(result.entries) {
			result.entries[entry_index] = RootVerifyTraceEntry {
				move        = move,
				order_index = i + 1,
				included    = included,
				reason      = reason,
				score       = -eval.INF,
				nodes       = 0,
				history     = history_score,
				see         = see_score,
			}
		}
		result.count += 1

		if !included {
			continue
		}

		if !board.is_castling_legal_now(b, move) {
			if entry_index < len(result.entries) {
				result.entries[entry_index].included = false
				result.entries[entry_index].reason = "castle_illegal"
			}
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move, &state)

		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			if entry_index < len(result.entries) {
				result.entries[entry_index].included = false
				result.entries[entry_index].reason = "self_check"
			}
			continue
		}

		child_pv: PV_Line
		board.unmake_move(b, &state)
		nodes_before := st.nodes
		score := 0
		if len(tt_snapshot) > 0 {
			scored := trace_score_root_child_from_snapshot(
				st,
				b,
				move,
				tt_snapshot,
				depth,
				-eval.INF,
				eval.INF,
				true,
			)
			st.nodes += scored.nodes
			score = scored.score
			child_pv = scored.pv
		} else {
			board.make_move_fast(b, move, &state)
			nnue.update_accumulators(&state, b, move)
			score = -negamax(
				st,
				b,
				-eval.INF,
				eval.INF,
				depth - 1,
				1,
				&child_pv,
			)
			board.unmake_move(b, &state)
		}
		nodes := st.nodes - nodes_before

		if entry_index < len(result.entries) {
			result.entries[entry_index].score = score
			result.entries[entry_index].nodes = nodes
		}

		if score > result.best_score {
			result.best_score = score
			result.best_move = move
			result.found_move = true
		}
	}

	result.total_nodes = st.nodes
}

trace_root_pipeline_is_excluded :: proc(move: moves.Move, excluded: ^[8]moves.Move, excluded_count: int) -> bool {
	for i in 0 ..< excluded_count {
		if same_move(move, excluded[i]) {
			return true
		}
	}
	return false
}

trace_root_pipeline_print_move_result :: proc(label: string, result: ^ContinuationDivTraceResult, move: moves.Move) {
	idx := find_continuation_div_entry(result, move)
	if idx >= 0 {
		entry := &result.entries[idx]
		fmt.printf(" %s=%d@%d/%d", label, entry.score, entry.alpha_before, entry.nodes)
	} else {
		fmt.printf(" %s=NA", label)
	}
}

trace_root_pipeline_print_multipv_result :: proc(
	label: string,
	result: ^ContinuationDivTraceResult,
	ran: bool,
	move: moves.Move,
	excluded: ^[8]moves.Move,
	excluded_count: int,
) {
	if !ran {
		fmt.printf(" %s=NA", label)
		return
	}
	if trace_root_pipeline_is_excluded(move, excluded, excluded_count) {
		fmt.printf(" %s=EXCLUDED", label)
		return
	}
	trace_root_pipeline_print_move_result(label, result, move)
}

trace_root_pipeline_print_verify_result :: proc(ran: bool, result: ^RootVerifyTraceResult, move: moves.Move) {
	if !ran {
		fmt.printf(" verify=not_run")
		return
	}
	idx := find_root_verify_trace_entry(result, move)
	if idx < 0 {
		fmt.printf(" verify=missing")
		return
	}

	entry := &result.entries[idx]
	if entry.included {
		fmt.printf(" verify=%d/%d:%s", entry.score, entry.nodes, entry.reason)
	} else {
		fmt.printf(" verify=skip:%s", entry.reason)
	}
}

root_search_pass_from_continuation_trace :: proc(src: ^ContinuationDivTraceResult) -> RootSearchPassResult {
	result := RootSearchPassResult {
		best_score = src.best_score,
		best_move  = src.best_move,
		found_move = !moves.is_empty_move(src.best_move),
		completed  = true,
	}
	result.count = src.count
	if result.count > len(result.entries) {
		result.count = len(result.entries)
	}
	for i in 0 ..< result.count {
		result.entries[i] = RootSearchPassEntry {
			move         = src.entries[i].move,
			order_index  = src.entries[i].index,
			score        = src.entries[i].score,
			alpha_before = src.entries[i].alpha_before,
			nodes        = src.entries[i].nodes,
		}
	}
	return result
}

trace_root_pipeline_scores :: proc(fen: string, depth: int, target_moves: []string) {
	if depth < 1 {
		fmt.println("Root pipeline trace FAILED: depth must be at least 1")
		return
	}

	root_board := board.parse_fen(fen)
	b := root_board
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
		b = root_board
		refresh_trace_accumulators(&b)
	}

	root_alpha := -eval.INF
	root_beta := eval.INF
	if depth >= 4 {
		root_alpha = warmup_score - params.aspiration_window
		root_beta = warmup_score + params.aspiration_window
	}

	all_moves: moves.MoveList
	board.generate_all_moves(&b, &all_moves)

	root_move_list := all_moves
	root_tt_move := warmup_best_move
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}
	actual_root_tt_move := get_tt_move(b.hash)
	sort_moves(&st, &root_move_list, &b, root_tt_move, 0, moves.Move{})

	base_tt := snapshot_tt()
	defer delete(base_tt)
	base_st := clone_search_thread(&st)
	defer free(base_st.continuation_history)

	prev_stats_enabled := search_stats_enabled
	prev_options := search_debug_options
	search_debug_options = SearchDebugOptions{}
	search_stats_enabled = false
	defer {
		search_stats_enabled = prev_stats_enabled
		search_debug_options = prev_options
	}

	restore_tt(base_tt)
	normal_st := clone_search_thread(&base_st)
	defer free(normal_st.continuation_history)

	initial := ContinuationDivTraceResult {
		warmup_depth  = warmup_depth,
		warmup_score  = warmup_score,
		warmup_best   = warmup_best_move,
		initial_alpha = root_alpha,
		initial_beta  = root_beta,
	}
	run_continuation_div_root_pass(&initial, &normal_st, &b, &root_move_list, depth, root_alpha, root_beta, "initial")

	normal_best := initial.best_move
	normal_score := initial.best_score
	normal_found := !moves.is_empty_move(normal_best)

	root_tt_initial_score := -eval.INF
	root_tt_initial_seen := false
	if !moves.is_empty_move(root_tt_move) {
		root_idx := find_continuation_div_entry(&initial, root_tt_move)
		if root_idx >= 0 {
			root_tt_initial_seen = true
			root_tt_initial_score = initial.entries[root_idx].score
		}
	}
	root_tt_failed_low := root_tt_initial_seen && root_tt_initial_score <= root_alpha && initial.best_score < root_beta
	guard_forced_fail_low := root_tt_failed_low && initial.best_score > root_alpha

	research := ContinuationDivTraceResult {
		warmup_depth  = warmup_depth,
		warmup_score  = warmup_score,
		warmup_best   = warmup_best_move,
		initial_alpha = root_alpha,
		initial_beta  = root_beta,
	}
	retry := ContinuationDivTraceResult {
		warmup_depth  = warmup_depth,
		warmup_score  = warmup_score,
		warmup_best   = warmup_best_move,
		initial_alpha = root_alpha,
		initial_beta  = root_beta,
	}
	verify := RootVerifyTraceResult{}

	research_ran := false
	research_reason := "none"
	retry_ran := false
	verify_ran := false

	if initial.best_score <= root_alpha || root_tt_failed_low {
		research_ran = true
		if initial.best_score <= root_alpha {
			research_reason = "window_fail_low"
		} else {
			research_reason = "root_seed_fail_low_guard"
		}
		run_continuation_div_root_pass(&research, &normal_st, &b, &root_move_list, depth, -eval.INF, root_beta, "fail_low_research")
		if !moves.is_empty_move(research.best_move) {
			normal_best = research.best_move
			normal_score = research.best_score
			normal_found = true
		}

		if depth >= 9 {
			verify_ran = true
			restore_tt(base_tt)
			verify_st := clone_search_thread(&base_st)
			if depth >= ROOT_VERIFY_SUSPECT_MIN_DEPTH {
				base_verify_candidates: RootVerifyCandidateSet
				verify_candidates: RootVerifyCandidateSet
				prepare_root_verify_candidate_set(
					&base_verify_candidates,
					&verify_st,
					&b,
					&root_move_list,
					root_tt_move,
					false,
					normal_best,
					actual_root_tt_move,
				)
				research_as_root := root_search_pass_from_continuation_trace(&research)
				suspect_quiets := collect_root_verify_suspect_quiets(
					&verify_st,
					&b,
					&root_move_list,
					depth,
					&research_as_root,
					base_tt,
					&base_verify_candidates,
				)
				normal_st.nodes += suspect_quiets.nodes
				prepare_root_verify_candidate_set(
					&verify_candidates,
					&verify_st,
					&b,
					&root_move_list,
					root_tt_move,
					false,
					normal_best,
					actual_root_tt_move,
					suspect_quiets.moves[0],
					suspect_quiets.moves[1],
					suspect_quiets.moves[2],
					suspect_quiets.moves[3],
				)
				restore_tt(base_tt)
				run_root_verify_trace_pass(
					&verify,
					&verify_st,
					&b,
					&root_move_list,
					depth,
					root_tt_move,
					false,
					normal_best,
					actual_root_tt_move,
					&verify_candidates,
					base_tt,
				)
			} else {
				run_root_verify_trace_pass(
					&verify,
					&verify_st,
					&b,
					&root_move_list,
					depth,
					root_tt_move,
					false,
					normal_best,
					actual_root_tt_move,
				)
			}
			normal_st.nodes += verify_st.nodes
			if verify_st.continuation_history != nil {
				free(verify_st.continuation_history)
			}
			if verify.found_move {
				normal_best = verify.best_move
				normal_score = verify.best_score
				normal_found = true
			}
		}

		if guard_forced_fail_low && normal_score >= root_beta {
			retry_ran = true
			run_continuation_div_root_pass(&retry, &normal_st, &b, &root_move_list, depth, root_alpha, eval.INF, "fail_low_beta_retry")
			if !moves.is_empty_move(retry.best_move) {
				normal_best = retry.best_move
				normal_score = retry.best_score
				normal_found = true
			}
		}
	} else if initial.best_score >= root_beta {
		research_ran = true
		research_reason = "window_fail_high"
		run_continuation_div_root_pass(&research, &normal_st, &b, &root_move_list, depth, root_alpha, eval.INF, "fail_high_research")
		if !moves.is_empty_move(research.best_move) {
			normal_best = research.best_move
			normal_score = research.best_score
			normal_found = true
		}
	}

	mp_results: [3]ContinuationDivTraceResult
	mp_ran: [3]bool
	mp_excluded_counts: [3]int
	excluded_moves: [8]moves.Move
	excluded_count := 0
	if normal_found {
		excluded_moves[excluded_count] = normal_best
		excluded_count += 1
	}

	for pv_index in 1 ..< 3 {
		mp_excluded_counts[pv_index] = excluded_count
		if excluded_count >= len(excluded_moves) {
			break
		}

		mp_move_list: moves.MoveList
		for i in 0 ..< all_moves.count {
			if !trace_root_pipeline_is_excluded(all_moves.moves[i], &excluded_moves, excluded_count) {
				moves.append_move(&mp_move_list, all_moves.moves[i])
			}
		}
		if mp_move_list.count == 0 {
			break
		}

		sort_moves(&normal_st, &mp_move_list, &b, moves.Move{}, 0, moves.Move{})
		mp_results[pv_index] = ContinuationDivTraceResult {
			warmup_depth  = warmup_depth,
			warmup_score  = warmup_score,
			warmup_best   = warmup_best_move,
			initial_alpha = -eval.INF,
			initial_beta  = eval.INF,
		}
		run_continuation_div_root_pass(&mp_results[pv_index], &normal_st, &b, &mp_move_list, depth, -eval.INF, eval.INF, "multipv")
		mp_ran[pv_index] = true

		if !moves.is_empty_move(mp_results[pv_index].best_move) {
			excluded_moves[excluded_count] = mp_results[pv_index].best_move
			excluded_count += 1
		}
	}

	fmt.printf(
		"Root pipeline trace depth=%d warmup_depth=%d warmup_score=%d window=[%d,%d] targets=%d fen=%s\n",
		depth,
		warmup_depth,
		warmup_score,
		root_alpha,
		root_beta,
		len(target_moves),
		fen,
	)
	fmt.printf("root_seed=")
	root_debug_print_move(root_tt_move)
	fmt.printf(" actual_tt=")
	root_debug_print_move(actual_root_tt_move)
	fmt.printf(" root_seed_initial_seen=%v root_seed_initial_score=%d root_seed_failed_low=%v\n",
		root_tt_initial_seen,
		root_tt_initial_score,
		root_tt_failed_low,
	)
	fmt.printf("normal initial_best=")
	root_debug_print_move(initial.best_move)
	fmt.printf(" initial_score=%d research=%v reason=%s", initial.best_score, research_ran, research_reason)
	if research_ran {
		fmt.printf(" research_best=")
		root_debug_print_move(research.best_move)
		fmt.printf(" research_score=%d", research.best_score)
	}
	fmt.printf(" verify=%v", verify_ran)
	if verify_ran {
		fmt.printf(" verify_best=")
		root_debug_print_move(verify.best_move)
		fmt.printf(" verify_score=%d", verify.best_score)
	}
	fmt.printf(" retry=%v", retry_ran)
	if retry_ran {
		fmt.printf(" retry_best=")
		root_debug_print_move(retry.best_move)
		fmt.printf(" retry_score=%d", retry.best_score)
	}
	fmt.printf(" final_best=")
	root_debug_print_move(normal_best)
	fmt.printf(" final_score=%d\n", normal_score)

	for pv_index in 1 ..< 3 {
		label := pv_index + 1
		fmt.printf("multipv%d ran=%v best=", label, mp_ran[pv_index])
		if mp_ran[pv_index] {
			root_debug_print_move(mp_results[pv_index].best_move)
			fmt.printf(" score=%d excluded_before=%d\n", mp_results[pv_index].best_score, mp_excluded_counts[pv_index])
		} else {
			fmt.printf("(none) score=NA excluded_before=%d\n", mp_excluded_counts[pv_index])
		}
	}

	fmt.println("idx move target seed tt cap promo hist see init fail verify mp2 mp3 isolated note")
	legal_index := 0
	printed := 0
	for i in 0 ..< root_move_list.count {
		move := root_move_list.moves[i]
		if !trace_root_legal_move(&b, move) {
			continue
		}
		legal_index += 1

		is_target := trace_root_parity_targeted(move, target_moves)
		print_row := len(target_moves) == 0 ||
			is_target ||
			same_move(move, normal_best) ||
			(verify_ran && same_move(move, verify.best_move)) ||
			same_move(move, initial.best_move) ||
			same_move(move, research.best_move) ||
			same_move(move, root_tt_move) ||
			same_move(move, actual_root_tt_move)
		if !print_row {
			continue
		}

		history_score := 0
		see_score := SEE_SCORE_UNKNOWN
		if move.capture {
			see_score = see_capture(&b, move)
		} else if move.promoted == -1 {
			history_score = get_history_score(&base_st, move)
		}

		fmt.printf("%2d ", legal_index)
		board.print_move(move)
		fmt.printf(
			" target=%v seed=%v tt=%v cap=%v promo=%d hist=%d",
			is_target,
			same_move(move, root_tt_move),
			same_move(move, actual_root_tt_move),
			move.capture,
			move.promoted,
			history_score,
		)
		if see_score == SEE_SCORE_UNKNOWN {
			fmt.printf(" see=NA")
		} else {
			fmt.printf(" see=%d", see_score)
		}

		trace_root_pipeline_print_move_result("init", &initial, move)
		if research_ran {
			trace_root_pipeline_print_move_result("fail", &research, move)
		} else {
			fmt.printf(" fail=NA")
		}
		trace_root_pipeline_print_verify_result(verify_ran, &verify, move)
		trace_root_pipeline_print_multipv_result("mp2", &mp_results[1], mp_ran[1], move, &excluded_moves, mp_excluded_counts[1])
		trace_root_pipeline_print_multipv_result("mp3", &mp_results[2], mp_ran[2], move, &excluded_moves, mp_excluded_counts[2])

		score_isolated := is_target || (len(target_moves) == 0 && printed < 8)
		isolated_full_score := 0
		isolated_pvs_score := 0
		isolated_has_pvs := false
		if score_isolated {
			full := trace_score_root_child_from_snapshot(
				&base_st,
				&b,
				move,
				base_tt,
				depth,
				-eval.INF,
				eval.INF,
				true,
			)
			isolated_full_score = full.score
			initial_idx := find_continuation_div_entry(&initial, move)
			if initial_idx >= 0 && initial.entries[initial_idx].alpha_before > -eval.INF / 2 {
				alpha_before := initial.entries[initial_idx].alpha_before
				pvs := trace_score_root_child_from_snapshot(
					&base_st,
					&b,
					move,
					base_tt,
					depth,
					-alpha_before - 1,
					-alpha_before,
					false,
				)
				isolated_pvs_score = pvs.score
				isolated_has_pvs = true
				fmt.printf(" isolated=%d/%d:%d", full.score, pvs.score, full.score - pvs.score)
			} else {
				fmt.printf(" isolated=%d/NA:NA", full.score)
			}
		} else {
			fmt.printf(" isolated=NA")
		}

		note := "ok"
		verify_idx := find_root_verify_trace_entry(&verify, move)
		initial_idx := find_continuation_div_entry(&initial, move)
		if verify_ran && verify_idx >= 0 && !verify.entries[verify_idx].included && is_target {
			note = "TARGET_VERIFY_SKIPPED"
		} else if initial_idx >= 0 && initial.entries[initial_idx].alpha_before > -eval.INF / 2 && score_isolated && isolated_has_pvs {
			alpha_before := initial.entries[initial_idx].alpha_before
			if isolated_full_score > alpha_before && isolated_pvs_score <= alpha_before {
				note = "ISOLATED_PVS_MISS"
			}
		}
		fmt.printf(" note=%s\n", note)
		os.flush(os.stdout)
		printed += 1
	}
}

ROOT_VERIFY_SUSPECT_MIN_DEPTH :: 12
ROOT_VERIFY_SUSPECT_PREFILTER_OFFSET :: 3
ROOT_VERIFY_TIMED_SUSPECT_PREFILTER_OFFSET :: 7
ROOT_VERIFY_SUSPECT_ORDER_LIMIT :: 20
ROOT_VERIFY_TIMED_POSITIVE_QUIET_LIMIT :: 2
ROOT_VERIFY_PRIORITY_CORE :: 0
ROOT_VERIFY_PRIORITY_SUSPECT_BASE :: 10
ROOT_VERIFY_PRIORITY_FORCING :: 20
ROOT_VERIFY_PRIORITY_QUIET :: 30
ROOT_VERIFY_PRIORITY_SKIP :: 1000

root_verify_candidate_decision :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move: moves.Move,
	root_tt_move: moves.Move,
	verify_all: bool,
	extra_verify_move_1: moves.Move = moves.Move{},
	extra_verify_move_2: moves.Move = moves.Move{},
	suspect_quiet_1: moves.Move = moves.Move{},
	suspect_quiet_2: moves.Move = moves.Move{},
	suspect_quiet_3: moves.Move = moves.Move{},
	suspect_quiet_4: moves.Move = moves.Move{},
) -> (include: bool, reason: string, priority: int) {
	if verify_all {
		return true, "verify_all", ROOT_VERIFY_PRIORITY_QUIET
	}
	if same_move(move, root_tt_move) {
		return true, "root_seed", ROOT_VERIFY_PRIORITY_CORE
	}
	if same_move(move, extra_verify_move_1) {
		return true, "current_best", ROOT_VERIFY_PRIORITY_CORE
	}
	if same_move(move, extra_verify_move_2) {
		return true, "actual_tt", ROOT_VERIFY_PRIORITY_CORE
	}
	if same_move(move, suspect_quiet_1) {
		return true, "suspect_quiet", ROOT_VERIFY_PRIORITY_SUSPECT_BASE
	}
	if same_move(move, suspect_quiet_2) {
		return true, "suspect_quiet", ROOT_VERIFY_PRIORITY_SUSPECT_BASE + 1
	}
	if same_move(move, suspect_quiet_3) {
		return true, "suspect_quiet", ROOT_VERIFY_PRIORITY_SUSPECT_BASE + 2
	}
	if same_move(move, suspect_quiet_4) {
		return true, "suspect_quiet", ROOT_VERIFY_PRIORITY_SUSPECT_BASE + 3
	}
	if move.promoted != -1 {
		return true, "promotion", ROOT_VERIFY_PRIORITY_FORCING
	}
	if move.capture {
		if see_capture(b, move) < 0 {
			return false, "negative_see_capture", ROOT_VERIFY_PRIORITY_SKIP
		}
		return true, "nonnegative_see_capture", ROOT_VERIFY_PRIORITY_FORCING
	}
	if get_history_score(st, move) <= 0 {
		return false, "quiet_nonpositive_history", ROOT_VERIFY_PRIORITY_SKIP
	}
	return true, "positive_history_quiet", ROOT_VERIFY_PRIORITY_QUIET
}

prepare_root_verify_candidate_set :: proc(
	set: ^RootVerifyCandidateSet,
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	root_tt_move: moves.Move,
	verify_all: bool,
	extra_verify_move_1: moves.Move = moves.Move{},
	extra_verify_move_2: moves.Move = moves.Move{},
	suspect_quiet_1: moves.Move = moves.Move{},
	suspect_quiet_2: moves.Move = moves.Move{},
	suspect_quiet_3: moves.Move = moves.Move{},
	suspect_quiet_4: moves.Move = moves.Move{},
) {
	set^ = RootVerifyCandidateSet{}
	set.count = move_list.count
	for i in 0 ..< move_list.count {
		include, reason, priority := root_verify_candidate_decision(
			st,
			b,
			move_list.moves[i],
			root_tt_move,
			verify_all,
			extra_verify_move_1,
			extra_verify_move_2,
			suspect_quiet_1,
			suspect_quiet_2,
			suspect_quiet_3,
			suspect_quiet_4,
		)
		set.include[i] = include
		set.reason[i] = reason
		set.priority[i] = priority
	}
}

limit_timed_root_verify_candidate_set :: proc(set: ^RootVerifyCandidateSet, include_positive_quiets: bool = false) {
	for i in 0 ..< set.count {
		if !set.include[i] {
			continue
		}

		priority := set.priority[i]
		is_top_suspect := priority >= ROOT_VERIFY_PRIORITY_SUSPECT_BASE &&
		                  priority < ROOT_VERIFY_PRIORITY_SUSPECT_BASE + 2
		is_positive_quiet := include_positive_quiets &&
			(priority == ROOT_VERIFY_PRIORITY_CORE ||
			 priority == ROOT_VERIFY_PRIORITY_QUIET)
		if is_top_suspect || priority == ROOT_VERIFY_PRIORITY_FORCING {
			continue
		}
		if is_positive_quiet {
			continue
		}

		set.include[i] = false
		set.reason[i] = "timed_verify_budget"
		set.priority[i] = ROOT_VERIFY_PRIORITY_SKIP
	}
}

restore_timed_positive_history_quiets :: proc(
	set: ^RootVerifyCandidateSet,
	st: ^SearchThread,
	move_list: ^moves.MoveList,
	max_count: int,
) {
	if max_count <= 0 {
		return
	}

	indices: [ROOT_VERIFY_TIMED_POSITIVE_QUIET_LIMIT]int
	scores: [ROOT_VERIFY_TIMED_POSITIVE_QUIET_LIMIT]int
	for i in 0 ..< len(indices) {
		indices[i] = -1
		scores[i] = -eval.INF
	}

	limit := max_count
	if limit > len(indices) {
		limit = len(indices)
	}

	for i in 0 ..< set.count {
		if i >= move_list.count {
			break
		}
		move := move_list.moves[i]
		if move.capture || move.promoted != -1 {
			continue
		}

		history_score := get_history_score(st, move)
		if history_score <= 0 {
			continue
		}

		insert_at := limit
		for j in 0 ..< limit {
			if history_score > scores[j] {
				insert_at = j
				break
			}
		}
		if insert_at >= limit {
			continue
		}

		for j := limit - 1; j > insert_at; j -= 1 {
			indices[j] = indices[j - 1]
			scores[j] = scores[j - 1]
		}
		indices[insert_at] = i
		scores[insert_at] = history_score
	}

	for rank in 0 ..< limit {
		idx := indices[rank]
		if idx < 0 {
			continue
		}
		set.include[idx] = true
		set.reason[idx] = "timed_positive_history_quiet"
		set.priority[idx] = ROOT_VERIFY_PRIORITY_CORE + 1 + rank
	}
}

root_verify_insert_suspect :: proc(result: ^RootVerifySuspectResult, move: moves.Move, score: int, scores: ^[4]int) {
	insert_at := result.count
	for i in 0 ..< result.count {
		if score > scores[i] {
			insert_at = i
			break
		}
	}
	if insert_at >= len(result.moves) {
		return
	}

	limit := result.count
	if limit >= len(result.moves) {
		limit = len(result.moves) - 1
	}
	for i := limit; i > insert_at; i -= 1 {
		result.moves[i] = result.moves[i - 1]
		scores[i] = scores[i - 1]
	}

	result.moves[insert_at] = move
	scores[insert_at] = score
	if result.count < len(result.moves) {
		result.count += 1
	}
}

collect_root_verify_suspect_quiets :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	depth: int,
	research_pass: ^RootSearchPassResult,
	tt_snapshot: []TTBucket,
	base_candidates: ^RootVerifyCandidateSet,
	timed_budget: bool = false,
) -> RootVerifySuspectResult {
	result: RootVerifySuspectResult
	if depth < ROOT_VERIFY_SUSPECT_MIN_DEPTH {
		return result
	}

	prefilter_offset := ROOT_VERIFY_SUSPECT_PREFILTER_OFFSET
	if timed_budget {
		prefilter_offset = ROOT_VERIFY_TIMED_SUSPECT_PREFILTER_OFFSET
	}
	prefilter_depth := depth - prefilter_offset
	if prefilter_depth < 1 {
		return result
	}

	scores := [4]int{-eval.INF, -eval.INF, -eval.INF, -eval.INF}
	for i in 0 ..< research_pass.count {
		if should_stop_search() {
			break
		}

		entry := research_pass.entries[i]
		if entry.order_index < 1 || entry.order_index > move_list.count {
			continue
		}
		if entry.order_index > ROOT_VERIFY_SUSPECT_ORDER_LIMIT {
			continue
		}

		move_idx := entry.order_index - 1
		if base_candidates.include[move_idx] {
			continue
		}

		move := entry.move
		if move.capture || move.promoted != -1 {
			continue
		}
		if get_history_score(st, move) > 0 {
			continue
		}
		if entry.alpha_before <= -eval.INF / 2 {
			continue
		}
		if entry.score > entry.alpha_before {
			continue
		}

		score := trace_score_root_child_from_snapshot(
			st,
			b,
			move,
			tt_snapshot,
			prefilter_depth,
			-eval.INF,
			eval.INF,
			true,
		)
		result.nodes += score.nodes
		root_verify_insert_suspect(&result, move, score.score, &scores)
	}

	restore_tt(tt_snapshot)
	return result
}

is_legal_root_move :: proc(b: ^board.Board, move: moves.Move) -> bool {
	if !board.is_castling_legal_now(b, move) {
		return false
	}

	state: board.StateInfo
	board.make_move_fast(b, move, &state)
	mover_king_sq := board.get_king_square(b, 1 - b.side)
	opponent_king_sq := board.get_king_square(b, b.side)
	illegal := mover_king_sq < 0 ||
	           opponent_king_sq < 0 ||
	           board.is_square_attacked(b, mover_king_sq, b.side)
	board.unmake_move(b, &state)

	return !illegal
}

trace_root_legal_move :: proc(b: ^board.Board, move: moves.Move) -> bool {
	return is_legal_root_move(b, move)
}

count_legal_root_moves :: proc(b: ^board.Board, move_list: ^moves.MoveList) -> int {
	count := 0
	for i in 0 ..< move_list.count {
		if is_legal_root_move(b, move_list.moves[i]) {
			count += 1
		}
	}
	return count
}

trace_capture_values :: proc(
	b: ^board.Board,
	move: moves.Move,
) -> (
	victim_piece: int,
	victim_value: int,
	attacker_value: int,
) {
	victim_piece = -1
	victim_value = 0
	attacker_value = 0

	if move.piece >= 0 {
		attacker_piece := move.piece % 6
		attacker_value = constants.PIECE_VALUES[attacker_piece]
	}

	if !move.capture {
		return
	}

	if move.en_passant {
		victim_piece = constants.PAWN
		victim_value = constants.PIECE_VALUES[constants.PAWN]
		return
	}

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
			return
		}
	}

	return
}

trace_root_order_scores :: proc(fen: string, depth: int) {
	if depth < 1 {
		fmt.println("Root order trace FAILED: depth must be at least 1")
		return
	}

	b := board.parse_fen(fen)
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
	}

	move_list: moves.MoveList
	board.generate_all_moves(&b, &move_list)
	root_tt_move := warmup_best_move
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}

	see_scores: [256]int
	sort_moves(&st, &move_list, &b, root_tt_move, 0, moves.Move{}, &see_scores)

	fmt.printf("Root order trace depth=%d warmup_depth=%d warmup_score=%d warmup_best=", depth, warmup_depth, warmup_score)
	if !moves.is_empty_move(root_tt_move) {
		board.print_move(root_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" fen=%s\n", fen)
	fmt.println("idx move tag total see hist caphist opening killer victim attacker promo tt capture")

	legal_moves := 0
	for i in 0 ..< move_list.count {
		move := move_list.moves[i]
		if !trace_root_legal_move(&b, move) {
			continue
		}

		see_score := see_scores[i]
		total := score_move(&st, move, &b, root_tt_move, 0, moves.Move{}, see_score)
		history := 0
		capture_history := 0
		opening_bias := 0
		killer := 0
		victim_piece, victim_value, attacker_value := trace_capture_values(&b, move)
		promo_bonus := 0
		if move.promoted != -1 {
			promo_bonus = constants.PIECE_VALUES[move.promoted]
		}

		if move.capture {
			capture_history = get_capture_history_score(&st, move)
		} else if move.promoted == -1 {
			killer = is_killer(&st, move, 0)
			history = get_history_score(&st, move)
			opening_bias = root_opening_bias_score(&b, move)
		}

		tag := "quiet"
		if same_move(move, root_tt_move) {
			tag = "tt"
		} else if move.capture {
			if see_score >= 0 {
				tag = "good_capture"
			} else {
				tag = "bad_capture"
			}
		} else if move.promoted != -1 {
			tag = "promotion"
		} else {
			if killer == 1 {
				tag = "killer1"
			} else if killer == 2 {
				tag = "killer2"
			}
		}

		fmt.printf("%2d ", legal_moves + 1)
		board.print_move(move)
		if move.capture {
			fmt.printf(
				" tag=%s total=%d see=%d hist=%d caphist=%d opening=%d killer=%d victim=%d attacker=%d promo=%d tt=%v capture=%v\n",
				tag,
				total,
				see_score,
				history,
				capture_history,
				opening_bias,
				killer,
				victim_value,
				attacker_value,
				promo_bonus,
				same_move(move, root_tt_move),
				move.capture,
			)
		} else {
			fmt.printf(
				" tag=%s total=%d see=NA hist=%d caphist=%d opening=%d killer=%d victim=%d attacker=%d promo=%d tt=%v capture=%v\n",
				tag,
				total,
				history,
				capture_history,
				opening_bias,
				killer,
				victim_piece,
				attacker_value,
				promo_bonus,
				same_move(move, root_tt_move),
				move.capture,
			)
		}

		legal_moves += 1
	}

	fmt.printf("summary legal=%d pseudo=%d\n", legal_moves, move_list.count)
}

trace_child_continuation_order_scores :: proc(fen: string, depth: int, root_move_text: string) {
	if depth < 1 {
		fmt.println("Continuation trace FAILED: depth must be at least 1")
		return
	}

	root_board := board.parse_fen(fen)
	b := root_board
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
		b = root_board
		refresh_trace_accumulators(&b)
	}

	root_list: moves.MoveList
	board.generate_all_moves(&b, &root_list)
	root_move: moves.Move
	root_found := false
	for i in 0 ..< root_list.count {
		move := root_list.moves[i]
		if move_matches_uci(move, root_move_text) && trace_root_legal_move(&b, move) {
			root_move = move
			root_found = true
			break
		}
	}

	if !root_found {
		fmt.printf("Continuation trace FAILED: root move %s was not legal in root position\n", root_move_text)
		return
	}

	root_state: board.StateInfo
	if !board.make_move(&b, root_move, &root_state) {
		fmt.printf("Continuation trace FAILED: root move %s failed legality check\n", root_move_text)
		return
	}
	defer board.unmake_move(&b, &root_state)

	child_list: moves.MoveList
	board.generate_all_moves(&b, &child_list)
	child_tt_move := get_tt_move(b.hash)
	counter_move := get_counter_move(&st, root_move)
	see_scores: [256]int
	sort_moves(&st, &child_list, &b, child_tt_move, 1, root_move, &see_scores)
	child_fen := board.get_fen(b)
	defer delete(child_fen)

	fmt.printf(
		"Continuation trace depth=%d warmup_depth=%d warmup_score=%d root=%s root_piece=%d root_source=%d root_target=%d active_div=%d warmup_best=",
		depth,
		warmup_depth,
		warmup_score,
		root_move_text,
		root_move.piece,
		root_move.source,
		root_move.target,
		params.continuation_score_div,
	)
	if !moves.is_empty_move(warmup_best_move) {
		board.print_move(warmup_best_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" child_tt=")
	if !moves.is_empty_move(child_tt_move) {
		board.print_move(child_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" counter=")
	if !moves.is_empty_move(counter_move) {
		board.print_move(counter_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" child_fen=%s\n", child_fen)
	fmt.println("idx move tag total total16 total14 total12 total8 no_cont hist raw_cont cont_active cont_used see killer tt counter capture")

	legal_moves := 0
	for i in 0 ..< child_list.count {
		move := child_list.moves[i]
		legal_state: board.StateInfo
		if !board.make_move(&b, move, &legal_state) {
			continue
		}
		board.unmake_move(&b, &legal_state)

		see_score := see_scores[i]
		total := score_move(&st, move, &b, child_tt_move, 1, root_move, see_score)
		history := 0
		killer := 0
		raw_cont := 0
		active_cont := 0
		cont_used := false
		is_tt := same_move(move, child_tt_move)
		is_counter := same_move(move, counter_move)

		if !move.capture && move.promoted == -1 {
			history = get_history_score(&st, move)
			killer = is_killer(&st, move, 1)
			raw_cont = get_continuation_score(&st, root_move, move)
			active_cont = raw_cont / params.continuation_score_div
			cont_used = !is_tt && !is_counter && killer == 0
		}

		no_cont := total
		total16 := total
		total14 := total
		total12 := total
		total8 := total
		if cont_used {
			no_cont = total - active_cont
			total16 = no_cont + raw_cont / 16
			total14 = no_cont + raw_cont / 14
			total12 = no_cont + raw_cont / 12
			total8 = no_cont + raw_cont / 8
		}

		tag := "quiet"
		if is_tt {
			tag = "tt"
		} else if is_counter {
			tag = "counter"
		} else if move.capture {
			if see_score >= 0 {
				tag = "good_capture"
			} else {
				tag = "bad_capture"
			}
		} else if move.promoted != -1 {
			tag = "promotion"
		} else if killer == 1 {
			tag = "killer1"
		} else if killer == 2 {
			tag = "killer2"
		}

		fmt.printf("%2d ", legal_moves + 1)
		board.print_move(move)
		fmt.printf(
			" tag=%s total=%d total16=%d total14=%d total12=%d total8=%d no_cont=%d hist=%d raw_cont=%d cont_active=%d cont_used=%v see=%d killer=%d tt=%v counter=%v capture=%v\n",
			tag,
			total,
			total16,
			total14,
			total12,
			total8,
			no_cont,
			history,
			raw_cont,
			active_cont,
			cont_used,
			see_score,
			killer,
			is_tt,
			is_counter,
			move.capture,
		)

		legal_moves += 1
	}

	fmt.printf("summary legal=%d pseudo=%d\n", legal_moves, child_list.count)
}

trace_continuation_line_order_scores :: proc(
	fen: string,
	depth: int,
	root_move_text: string,
	reply_move_text: string,
) {
	if depth < 1 {
		fmt.println("Continuation line trace FAILED: depth must be at least 1")
		return
	}

	root_board := board.parse_fen(fen)
	b := root_board
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
		b = root_board
		refresh_trace_accumulators(&b)
	}

	root_list: moves.MoveList
	board.generate_all_moves(&b, &root_list)
	root_move: moves.Move
	root_found := false
	for i in 0 ..< root_list.count {
		move := root_list.moves[i]
		if move_matches_uci(move, root_move_text) && trace_root_legal_move(&b, move) {
			root_move = move
			root_found = true
			break
		}
	}

	if !root_found {
		fmt.printf("Continuation line trace FAILED: root move %s was not legal in root position\n", root_move_text)
		return
	}

	root_state: board.StateInfo
	if !board.make_move(&b, root_move, &root_state) {
		fmt.printf("Continuation line trace FAILED: root move %s failed legality check\n", root_move_text)
		return
	}
	defer board.unmake_move(&b, &root_state)

	child_tt_move := get_tt_move(b.hash)
	child_counter_move := get_counter_move(&st, root_move)
	reply_move: moves.Move
	reply_found := false
	reply_source := "none"

	child_list: moves.MoveList
	board.generate_all_moves(&b, &child_list)
	if len(reply_move_text) > 0 {
		for i in 0 ..< child_list.count {
			move := child_list.moves[i]
			if move_matches_uci(move, reply_move_text) && trace_root_legal_move(&b, move) {
				reply_move = move
				reply_found = true
				reply_source = "explicit"
				break
			}
		}
		if !reply_found {
			fmt.printf("Continuation line trace FAILED: reply move %s was not legal after root %s\n", reply_move_text, root_move_text)
			return
		}
	} else {
		if !moves.is_empty_move(child_tt_move) {
			for i in 0 ..< child_list.count {
				move := child_list.moves[i]
				if same_move(move, child_tt_move) && trace_root_legal_move(&b, move) {
					reply_move = move
					reply_found = true
					reply_source = "tt"
					break
				}
			}
		}
		if !reply_found && !moves.is_empty_move(child_counter_move) {
			for i in 0 ..< child_list.count {
				move := child_list.moves[i]
				if same_move(move, child_counter_move) && trace_root_legal_move(&b, move) {
					reply_move = move
					reply_found = true
					reply_source = "counter"
					break
				}
			}
		}
		if !reply_found {
			see_scores: [256]int
			sort_moves(&st, &child_list, &b, child_tt_move, 1, root_move, &see_scores)
			for i in 0 ..< child_list.count {
				move := child_list.moves[i]
				if trace_root_legal_move(&b, move) {
					reply_move = move
					reply_found = true
					reply_source = "first"
					break
				}
			}
		}
	}

	if !reply_found {
		fmt.printf("Continuation line trace FAILED: no legal reply found after root %s\n", root_move_text)
		return
	}

	reply_state: board.StateInfo
	if !board.make_move(&b, reply_move, &reply_state) {
		fmt.printf("Continuation line trace FAILED: selected reply failed legality check\n")
		return
	}
	defer board.unmake_move(&b, &reply_state)

	line_tt_move := get_tt_move(b.hash)
	line_counter_move := get_counter_move(&st, reply_move)
	line_fen := board.get_fen(b)
	defer delete(line_fen)

	fmt.printf(
		"Continuation line trace depth=%d warmup_depth=%d warmup_score=%d root=%s reply_source=%s active_div=%d warmup_best=",
		depth,
		warmup_depth,
		warmup_score,
		root_move_text,
		reply_source,
		params.continuation_score_div,
	)
	if !moves.is_empty_move(warmup_best_move) {
		board.print_move(warmup_best_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" root_reply=")
	board.print_move(reply_move)
	fmt.printf(" child_tt=")
	if !moves.is_empty_move(child_tt_move) {
		board.print_move(child_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" child_counter=")
	if !moves.is_empty_move(child_counter_move) {
		board.print_move(child_counter_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" next_tt=")
	if !moves.is_empty_move(line_tt_move) {
		board.print_move(line_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" next_counter=")
	if !moves.is_empty_move(line_counter_move) {
		board.print_move(line_counter_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" line_fen=%s\n", line_fen)
	fmt.println("idx move tag total total16 total14 total12 total8 no_cont hist raw_cont cont_active cont_used see killer tt counter capture")

	line_list: moves.MoveList
	board.generate_all_moves(&b, &line_list)
	line_see_scores: [256]int
	sort_moves(&st, &line_list, &b, line_tt_move, 2, reply_move, &line_see_scores)

	legal_moves := 0
	for i in 0 ..< line_list.count {
		move := line_list.moves[i]
		legal_state: board.StateInfo
		if !board.make_move(&b, move, &legal_state) {
			continue
		}
		board.unmake_move(&b, &legal_state)

		see_score := line_see_scores[i]
		total := score_move(&st, move, &b, line_tt_move, 2, reply_move, see_score)
		history := 0
		killer := 0
		raw_cont := 0
		active_cont := 0
		cont_used := false
		is_tt := same_move(move, line_tt_move)
		is_counter := same_move(move, line_counter_move)

		if !move.capture && move.promoted == -1 {
			history = get_history_score(&st, move)
			killer = is_killer(&st, move, 2)
			raw_cont = get_continuation_score(&st, reply_move, move)
			active_cont = raw_cont / params.continuation_score_div
			cont_used = !is_tt && !is_counter && killer == 0
		}

		no_cont := total
		total16 := total
		total14 := total
		total12 := total
		total8 := total
		if cont_used {
			no_cont = total - active_cont
			total16 = no_cont + raw_cont / 16
			total14 = no_cont + raw_cont / 14
			total12 = no_cont + raw_cont / 12
			total8 = no_cont + raw_cont / 8
		}

		tag := "quiet"
		if is_tt {
			tag = "tt"
		} else if is_counter {
			tag = "counter"
		} else if move.capture {
			if see_score >= 0 {
				tag = "good_capture"
			} else {
				tag = "bad_capture"
			}
		} else if move.promoted != -1 {
			tag = "promotion"
		} else if killer == 1 {
			tag = "killer1"
		} else if killer == 2 {
			tag = "killer2"
		}

		fmt.printf("%2d ", legal_moves + 1)
		board.print_move(move)
		fmt.printf(
			" tag=%s total=%d total16=%d total14=%d total12=%d total8=%d no_cont=%d hist=%d raw_cont=%d cont_active=%d cont_used=%v see=%d killer=%d tt=%v counter=%v capture=%v\n",
			tag,
			total,
			total16,
			total14,
			total12,
			total8,
			no_cont,
			history,
			raw_cont,
			active_cont,
			cont_used,
			see_score,
			killer,
			is_tt,
			is_counter,
			move.capture,
		)

		legal_moves += 1
	}

	fmt.printf("summary legal=%d pseudo=%d\n", legal_moves, line_list.count)
}

ContinuationDivTraceEntry :: struct {
	move:          moves.Move,
	index:         int,
	score:         int,
	alpha_before:  int,
	nodes:         u64,
	qnodes:        u64,
	tt_cutoffs:    u64,
	lmp:           u64,
	futility:      u64,
	nmp_cutoffs:   u64,
	rfp:           u64,
	razor_cutoffs: u64,
	probcut_cutoffs: u64,
	lmr:           u64,
	lmr_research:  u64,
	pvs_research:  u64,
}

ContinuationDivTraceResult :: struct {
	divisor:       int,
	warmup_depth:  int,
	warmup_score:  int,
	warmup_best:   moves.Move,
	root_alpha:    int,
	root_beta:     int,
	initial_alpha: int,
	initial_beta:  int,
	phase:         string,
	best_move:     moves.Move,
	best_score:    int,
	total_nodes:   u64,
	entries:       [256]ContinuationDivTraceEntry,
	count:         int,
}

SearchCounterSnapshot :: struct {
	qnodes:          u64,
	tt_cutoffs:      u64,
	lmp:             u64,
	futility:        u64,
	nmp_cutoffs:     u64,
	rfp:             u64,
	razor_cutoffs:   u64,
	probcut_cutoffs: u64,
	lmr:             u64,
	lmr_research:    u64,
	pvs_research:    u64,
}

search_counter_snapshot :: proc() -> SearchCounterSnapshot {
	return SearchCounterSnapshot {
		qnodes          = stat_load(&search_stats.qnodes),
		tt_cutoffs      = stat_load(&search_stats.tt_cutoffs),
		lmp             = stat_load(&search_stats.lmp_prunes),
		futility        = stat_load(&search_stats.futility_prunes),
		nmp_cutoffs     = stat_load(&search_stats.nmp_cutoffs),
		rfp             = stat_load(&search_stats.rfp_cutoffs),
		razor_cutoffs   = stat_load(&search_stats.razor_cutoffs),
		probcut_cutoffs = stat_load(&search_stats.probcut_cutoffs),
		lmr             = stat_load(&search_stats.lmr_searches),
		lmr_research    = stat_load(&search_stats.lmr_researches),
		pvs_research    = stat_load(&search_stats.pvs_researches),
	}
}

run_continuation_div_root_pass :: proc(
	result: ^ContinuationDivTraceResult,
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	depth: int,
	alpha: int,
	beta: int,
	phase: string,
) {
	result.root_alpha = alpha
	result.root_beta = beta
	result.phase = phase
	result.count = 0
	result.best_move = moves.Move{}
	result.best_score = -eval.INF

	current_alpha := alpha
	legal_moves := 0

	for i in 0 ..< move_list.count {
		move := move_list.moves[i]
		if !trace_root_legal_move(b, move) {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move, &state)
		nnue.update_accumulators(&state, b, move)

		alpha_before := current_alpha
		nodes_before := st.nodes
		counters_before := search_counter_snapshot()
		child_pv: PV_Line
		score := -negamax(
			st,
			b,
			-beta,
			-current_alpha,
			depth - 1,
			1,
			&child_pv,
		)
		counters_after := search_counter_snapshot()
		nodes := st.nodes - nodes_before
		board.unmake_move(b, &state)

		if legal_moves < len(result.entries) {
			result.entries[legal_moves] = ContinuationDivTraceEntry {
				move             = move,
				index            = legal_moves + 1,
				score            = score,
				alpha_before     = alpha_before,
				nodes            = nodes,
				qnodes           = counters_after.qnodes - counters_before.qnodes,
				tt_cutoffs       = counters_after.tt_cutoffs - counters_before.tt_cutoffs,
				lmp              = counters_after.lmp - counters_before.lmp,
				futility         = counters_after.futility - counters_before.futility,
				nmp_cutoffs      = counters_after.nmp_cutoffs - counters_before.nmp_cutoffs,
				rfp              = counters_after.rfp - counters_before.rfp,
				razor_cutoffs    = counters_after.razor_cutoffs - counters_before.razor_cutoffs,
				probcut_cutoffs  = counters_after.probcut_cutoffs - counters_before.probcut_cutoffs,
				lmr              = counters_after.lmr - counters_before.lmr,
				lmr_research     = counters_after.lmr_research - counters_before.lmr_research,
				pvs_research     = counters_after.pvs_research - counters_before.pvs_research,
			}
			result.count += 1
		}

		if score > result.best_score {
			result.best_score = score
			result.best_move = move
		}

		if score > current_alpha {
			current_alpha = score
		}
		legal_moves += 1
	}

	result.total_nodes = st.nodes
}

collect_continuation_div_trace :: proc(fen: string, depth: int, divisor: int) -> ContinuationDivTraceResult {
	result := ContinuationDivTraceResult{divisor = divisor}
	params.continuation_score_div = divisor
	clear_tt()

	root_board := board.parse_fen(fen)
	b := root_board
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		result.warmup_best = last_completed_best_move
		result.warmup_score = last_completed_best_score
		result.warmup_depth = last_completed_depth
		reset_search_control()
		b = root_board
		refresh_trace_accumulators(&b)
	}

	result.root_alpha = -eval.INF
	result.root_beta = eval.INF
	if depth >= 4 {
		result.root_alpha = result.warmup_score - params.aspiration_window
		result.root_beta = result.warmup_score + params.aspiration_window
	}
	result.initial_alpha = result.root_alpha
	result.initial_beta = result.root_beta

	move_list: moves.MoveList
	board.generate_all_moves(&b, &move_list)
	root_tt_move := result.warmup_best
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}
	sort_moves(&st, &move_list, &b, root_tt_move, 0, moves.Move{})

	prev_stats_enabled := search_stats_enabled
	prev_options := search_debug_options
	search_debug_options = SearchDebugOptions{}
	search_stats_enabled = true
	reset_search_stats()

	run_continuation_div_root_pass(&result, &st, &b, &move_list, depth, result.root_alpha, result.root_beta, "initial")

	pv_initial_score := -eval.INF
	pv_initial_seen := false
	if !moves.is_empty_move(root_tt_move) {
		pv_idx := find_continuation_div_entry(&result, root_tt_move)
		if pv_idx >= 0 {
			pv_initial_seen = true
			pv_initial_score = result.entries[pv_idx].score
		}
	}
	pv_failed_low := pv_initial_seen && pv_initial_score <= result.initial_alpha

	if result.best_score <= result.initial_alpha || (pv_failed_low && result.best_score < result.initial_beta) {
		guard_forced_research := result.best_score > result.initial_alpha && pv_failed_low
		reset_search_stats()
		run_continuation_div_root_pass(&result, &st, &b, &move_list, depth, -eval.INF, result.initial_beta, "fail_low_research")
		if guard_forced_research && result.best_score >= result.initial_beta {
			reset_search_stats()
			run_continuation_div_root_pass(&result, &st, &b, &move_list, depth, result.initial_alpha, eval.INF, "fail_low_beta_retry")
		}
	} else if result.best_score >= result.initial_beta {
		reset_search_stats()
		run_continuation_div_root_pass(&result, &st, &b, &move_list, depth, result.initial_alpha, eval.INF, "fail_high_research")
	}

	result.total_nodes = st.nodes
	search_stats_enabled = prev_stats_enabled
	search_debug_options = prev_options

	return result
}

find_continuation_div_entry :: proc(result: ^ContinuationDivTraceResult, move: moves.Move) -> int {
	for i in 0 ..< result.count {
		if same_move(result.entries[i].move, move) {
			return i
		}
	}
	return -1
}

print_continuation_div_summary :: proc(result: ^ContinuationDivTraceResult) {
	fmt.printf(
		"div=%d warmup_depth=%d warmup_score=%d initial_window=[%d,%d] phase=%s root_window=[%d,%d] best_score=%d total_nodes=%d warmup_best=",
		result.divisor,
		result.warmup_depth,
		result.warmup_score,
		result.initial_alpha,
		result.initial_beta,
		result.phase,
		result.root_alpha,
		result.root_beta,
		result.best_score,
		result.total_nodes,
	)
	if !moves.is_empty_move(result.warmup_best) {
		board.print_move(result.warmup_best)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" best=")
	if !moves.is_empty_move(result.best_move) {
		board.print_move(result.best_move)
	} else {
		fmt.printf("(none)")
	}
	status := "inside"
	if result.best_score <= result.root_alpha {
		status = "fail_low"
	} else if result.best_score >= result.root_beta {
		status = "fail_high"
	}
	fmt.printf(" aspiration=%s root_children=%d\n", status, result.count)
}

print_continuation_div_entry :: proc(prefix: string, entry: ^ContinuationDivTraceEntry) {
	fmt.printf(
		"%sidx=%d move=",
		prefix,
		entry.index,
	)
	board.print_move(entry.move)
	fmt.printf(
		" score=%d alpha=%d nodes=%d q=%d tt=%d lmp=%d fut=%d nmp=%d rfp=%d razor=%d probcut=%d lmr=%d/%d pvs=%d",
		entry.score,
		entry.alpha_before,
		entry.nodes,
		entry.qnodes,
		entry.tt_cutoffs,
		entry.lmp,
		entry.futility,
		entry.nmp_cutoffs,
		entry.rfp,
		entry.razor_cutoffs,
		entry.probcut_cutoffs,
		entry.lmr,
		entry.lmr_research,
		entry.pvs_research,
	)
}

trace_continuation_divergence :: proc(fen: string, depth: int, div_a: int, div_b: int) {
	if depth < 1 {
		fmt.println("Continuation divergence trace FAILED: depth must be at least 1")
		return
	}
	if div_a <= 0 || div_b <= 0 {
		fmt.println("Continuation divergence trace FAILED: divisors must be positive")
		return
	}

	original_div := params.continuation_score_div
	result_a := collect_continuation_div_trace(fen, depth, div_a)
	result_b := collect_continuation_div_trace(fen, depth, div_b)
	params.continuation_score_div = original_div

	fmt.printf("Continuation divergence trace depth=%d div_a=%d div_b=%d fen=%s\n", depth, div_a, div_b, fen)
	print_continuation_div_summary(&result_a)
	print_continuation_div_summary(&result_b)
	if result_a.phase != result_b.phase {
		fmt.printf("phase_divergence div%d=%s div%d=%s\n", div_a, result_a.phase, div_b, result_b.phase)
	}

	first_index_divergence := -1
	first_score_divergence := -1
	limit := result_a.count
	if result_b.count < limit {
		limit = result_b.count
	}

	for i in 0 ..< limit {
		a := &result_a.entries[i]
		b := &result_b.entries[i]
		if first_index_divergence == -1 {
			if !same_move(a.move, b.move) || a.score != b.score {
				first_index_divergence = i
			}
		}
		if first_score_divergence == -1 {
			j := find_continuation_div_entry(&result_b, a.move)
			if j >= 0 && result_b.entries[j].score != a.score {
				first_score_divergence = i
			}
		}
	}

	if first_index_divergence >= 0 {
		a := &result_a.entries[first_index_divergence]
		b := &result_b.entries[first_index_divergence]
		fmt.printf("first_index_divergence idx=%d div%d=", first_index_divergence + 1, div_a)
		board.print_move(a.move)
		fmt.printf(" score=%d div%d=", a.score, div_b)
		board.print_move(b.move)
		fmt.printf(" score=%d\n", b.score)
	} else if result_a.count != result_b.count {
		fmt.printf("first_index_divergence count div%d=%d div%d=%d\n", div_a, result_a.count, div_b, result_b.count)
	} else {
		fmt.println("first_index_divergence none")
	}

	if first_score_divergence >= 0 {
		a := &result_a.entries[first_score_divergence]
		j := find_continuation_div_entry(&result_b, a.move)
		b := &result_b.entries[j]
		fmt.printf("first_score_divergence move=")
		board.print_move(a.move)
		fmt.printf(
			" div%d_idx=%d score=%d div%d_idx=%d score=%d delta=%d\n",
			div_a,
			a.index,
			a.score,
			div_b,
			b.index,
			b.score,
			b.score - a.score,
		)
	} else {
		fmt.println("first_score_divergence none")
	}

	fmt.println("idx divA(move score alpha nodes q tt lmp fut nmp rfp razor probcut lmr/re pvs) | divB(move score alpha nodes q tt lmp fut nmp rfp razor probcut lmr/re pvs) note")
	for i in 0 ..< limit {
		a := &result_a.entries[i]
		b := &result_b.entries[i]
		note := "same"
		if !same_move(a.move, b.move) {
			note = "ORDER"
		} else if a.score != b.score {
			note = "SCORE"
		} else if a.nodes != b.nodes {
			note = "NODES"
		}

		fmt.printf("%2d ", i + 1)
		print_continuation_div_entry("", a)
		fmt.printf(" | ")
		print_continuation_div_entry("", b)
		fmt.printf(" note=%s\n", note)
	}
}

trace_root_aspiration :: proc(fen: string, depth: int, divisor: int) {
	if depth < 1 {
		fmt.println("Root aspiration trace FAILED: depth must be at least 1")
		return
	}
	if divisor <= 0 {
		fmt.println("Root aspiration trace FAILED: divisor must be positive")
		return
	}

	original_div := params.continuation_score_div
	params.continuation_score_div = divisor
	clear_tt()

	root_board := board.parse_fen(fen)
	b := root_board
	refresh_trace_accumulators(&b)

	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
		b = root_board
		refresh_trace_accumulators(&b)
	}

	alpha := -eval.INF
	beta := eval.INF
	if depth >= 4 {
		alpha = warmup_score - params.aspiration_window
		beta = warmup_score + params.aspiration_window
	}

	move_list: moves.MoveList
	board.generate_all_moves(&b, &move_list)
	root_tt_move := warmup_best
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}
	sort_moves(&st, &move_list, &b, root_tt_move, 0, moves.Move{})

	prev_stats_enabled := search_stats_enabled
	prev_options := search_debug_options
	search_debug_options = SearchDebugOptions{}
	search_stats_enabled = true
	reset_search_stats()

	initial := ContinuationDivTraceResult {
		divisor       = divisor,
		warmup_depth  = warmup_depth,
		warmup_score  = warmup_score,
		warmup_best   = warmup_best,
		initial_alpha = alpha,
		initial_beta  = beta,
	}
	run_continuation_div_root_pass(&initial, &st, &b, &move_list, depth, alpha, beta, "initial")

	pv_initial_score := -eval.INF
	pv_initial_seen := false
	if !moves.is_empty_move(root_tt_move) {
		pv_idx := find_continuation_div_entry(&initial, root_tt_move)
		if pv_idx >= 0 {
			pv_initial_seen = true
			pv_initial_score = initial.entries[pv_idx].score
		}
	}
	pv_failed_low := pv_initial_seen && pv_initial_score <= alpha

	research := ContinuationDivTraceResult {
		divisor       = divisor,
		warmup_depth  = warmup_depth,
		warmup_score  = warmup_score,
		warmup_best   = warmup_best,
		initial_alpha = alpha,
		initial_beta  = beta,
	}
	retry := ContinuationDivTraceResult {
		divisor       = divisor,
		warmup_depth  = warmup_depth,
		warmup_score  = warmup_score,
		warmup_best   = warmup_best,
		initial_alpha = alpha,
		initial_beta  = beta,
	}
	research_needed := false
	research_reason := "none"
	retry_needed := false
	retry_reason := "none"
	if initial.best_score <= alpha {
		research_needed = true
		research_reason = "window_fail_low"
		reset_search_stats()
		run_continuation_div_root_pass(&research, &st, &b, &move_list, depth, -eval.INF, beta, "fail_low_research")
	} else if pv_failed_low && initial.best_score < beta {
		research_needed = true
		research_reason = "pv_fail_low_guard"
		reset_search_stats()
		run_continuation_div_root_pass(&research, &st, &b, &move_list, depth, -eval.INF, beta, "fail_low_research")
		if research.best_score >= beta {
			retry_needed = true
			retry_reason = "fail_low_beta_bound"
			reset_search_stats()
			run_continuation_div_root_pass(&retry, &st, &b, &move_list, depth, alpha, eval.INF, "fail_low_beta_retry")
		}
	} else if initial.best_score >= beta {
		research_needed = true
		research_reason = "window_fail_high"
		reset_search_stats()
		run_continuation_div_root_pass(&research, &st, &b, &move_list, depth, alpha, eval.INF, "fail_high_research")
	}

	search_stats_enabled = prev_stats_enabled
	search_debug_options = prev_options
	params.continuation_score_div = original_div

	fmt.printf(
		"Root aspiration trace depth=%d div=%d warmup_depth=%d warmup_score=%d window=[%d,%d] reason=%s fen=%s\n",
		depth,
		divisor,
		warmup_depth,
		warmup_score,
		alpha,
		beta,
		research_reason,
		fen,
	)
	fmt.printf("warmup_best=")
	if !moves.is_empty_move(root_tt_move) {
		board.print_move(root_tt_move)
	} else {
		fmt.printf("(none)")
	}
	fmt.printf(" pv_initial_seen=%v pv_initial_score=%d pv_failed_low=%v\n", pv_initial_seen, pv_initial_score, pv_failed_low)
	print_continuation_div_summary(&initial)
	if research_needed {
		print_continuation_div_summary(&research)
	} else {
		fmt.println("research=none")
	}
	if retry_needed {
		fmt.printf("retry_reason=%s\n", retry_reason)
		print_continuation_div_summary(&retry)
	} else {
		fmt.println("retry=none")
	}

	fmt.println("idx move initial(score alpha nodes q tt lmp fut nmp rfp razor probcut lmr/re pvs) | research(score alpha nodes q tt lmp fut nmp rfp razor probcut lmr/re pvs) delta note")
	for i in 0 ..< initial.count {
		init_entry := &initial.entries[i]
		fmt.printf("%2d ", i + 1)
		board.print_move(init_entry.move)
		fmt.printf(" initial(score=%d alpha=%d nodes=%d q=%d tt=%d lmp=%d fut=%d nmp=%d rfp=%d razor=%d probcut=%d lmr=%d/%d pvs=%d)",
			init_entry.score,
			init_entry.alpha_before,
			init_entry.nodes,
			init_entry.qnodes,
			init_entry.tt_cutoffs,
			init_entry.lmp,
			init_entry.futility,
			init_entry.nmp_cutoffs,
			init_entry.rfp,
			init_entry.razor_cutoffs,
			init_entry.probcut_cutoffs,
			init_entry.lmr,
			init_entry.lmr_research,
			init_entry.pvs_research,
		)

		if research_needed {
			research_idx := find_continuation_div_entry(&research, init_entry.move)
			if research_idx >= 0 {
				research_entry := &research.entries[research_idx]
				delta := research_entry.score - init_entry.score
				note := "same"
				if research_entry.index != init_entry.index {
					note = "ORDER"
				} else if delta != 0 {
					note = "SCORE"
				} else if research_entry.nodes != init_entry.nodes {
					note = "NODES"
				}
				fmt.printf(" | research(score=%d alpha=%d nodes=%d q=%d tt=%d lmp=%d fut=%d nmp=%d rfp=%d razor=%d probcut=%d lmr=%d/%d pvs=%d) delta=%d note=%s\n",
					research_entry.score,
					research_entry.alpha_before,
					research_entry.nodes,
					research_entry.qnodes,
					research_entry.tt_cutoffs,
					research_entry.lmp,
					research_entry.futility,
					research_entry.nmp_cutoffs,
					research_entry.rfp,
					research_entry.razor_cutoffs,
					research_entry.probcut_cutoffs,
					research_entry.lmr,
					research_entry.lmr_research,
					research_entry.pvs_research,
					delta,
					note,
				)
			} else {
				fmt.println(" | research(missing) delta=NA note=MISSING")
			}
		} else {
			fmt.println(" | research(NA) delta=NA note=no_research")
		}
	}
}

trace_root_child_diagnostics :: proc(fen: string, depth: int, target_move_text: string) {
	if depth < 1 {
		fmt.println("Root child trace FAILED: depth must be at least 1")
		return
	}

	b := board.parse_fen(fen)
	refresh_trace_accumulators(&b)
	st: SearchThread
	init_search_thread(&st, 0)
	defer free(st.continuation_history)

	reset_search_control()
	sync.atomic_store(&total_nodes, 0)
	st.nodes = 0

	warmup_best_move: moves.Move
	warmup_score := 0
	warmup_depth := 0
	if depth > 1 {
		search_position(&st, &b, depth - 1, 1, output_bestmove = false)
		warmup_best_move = last_completed_best_move
		warmup_score = last_completed_best_score
		warmup_depth = last_completed_depth
		reset_search_control()
	}

	move_list: moves.MoveList
	board.generate_all_moves(&b, &move_list)
	root_tt_move := warmup_best_move
	if moves.is_empty_move(root_tt_move) {
		root_tt_move = get_tt_move(b.hash)
	}
	sort_moves(&st, &move_list, &b, root_tt_move, 0, moves.Move{})

	current_alpha := -eval.INF
	legal_moves := 0
	target_found := false

	for i in 0 ..< move_list.count {
		move := move_list.moves[i]
		if !board.is_castling_legal_now(&b, move) {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(&b, move, &state)
		king_sq := board.get_king_square(&b, 1 - b.side)
		if board.is_square_attacked(&b, king_sq, b.side) {
			board.unmake_move(&b, &state)
			continue
		}

		nnue.update_accumulators(&state, &b, move)

		if move_matches_uci(move, target_move_text) {
			target_found = true
			alpha_before := current_alpha
			if alpha_before <= -eval.INF / 2 {
				fmt.println("Root child trace FAILED: target is first legal move, no root null-window alpha exists")
				board.unmake_move(&b, &state)
				break
			}

			fmt.printf(
				"Root child trace depth=%d warmup_depth=%d warmup_score=%d target=%s index=%d alpha_before=%d warmup_best=",
				depth,
				warmup_depth,
				warmup_score,
				target_move_text,
				legal_moves + 1,
				alpha_before,
			)
			if !moves.is_empty_move(root_tt_move) {
				board.print_move(root_tt_move)
			} else {
				fmt.printf("(none)")
			}
			fmt.printf(" fen=%s\n", fen)

			tt_snapshot := snapshot_tt()
			print_probe_variant("full", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{}, true)
			print_probe_variant("baseline", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{})
			print_probe_variant("no_tt", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_tt_cutoffs = true})
			print_probe_variant("no_lmr", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_lmr = true})
			print_probe_variant("no_futility", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_futility = true})
			print_probe_variant("no_lmp", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_lmp = true})
			print_probe_variant("no_nmp", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_nmp = true})
			print_probe_variant("no_rfp", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_rfp = true})
			print_probe_variant("no_razor", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_razor = true})
			print_probe_variant("no_probcut", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_probcut = true})
			print_probe_variant("no_iir", &st, &b, tt_snapshot, depth, alpha_before, SearchDebugOptions{disable_iir = true}, true)
			print_probe_variant(
				"no_early_pruning",
				&st,
				&b,
				tt_snapshot,
				depth,
				alpha_before,
				SearchDebugOptions {
					disable_nmp     = true,
					disable_rfp     = true,
					disable_razor   = true,
					disable_probcut = true,
				},
			)
			print_probe_variant(
				"no_tt_lmr_futility_lmp",
				&st,
				&b,
				tt_snapshot,
				depth,
				alpha_before,
				SearchDebugOptions {
					disable_tt_cutoffs = true,
					disable_lmr        = true,
					disable_futility   = true,
					disable_lmp        = true,
				},
			)
			print_probe_variant(
				"no_all_prune_reduce",
				&st,
				&b,
				tt_snapshot,
				depth,
				alpha_before,
				SearchDebugOptions {
					disable_tt_cutoffs = true,
					disable_lmr        = true,
					disable_futility   = true,
					disable_lmp        = true,
					disable_nmp        = true,
					disable_rfp        = true,
					disable_razor      = true,
					disable_probcut    = true,
					disable_iir        = true,
				},
			)
			restore_tt(tt_snapshot)
			delete(tt_snapshot)
			board.unmake_move(&b, &state)
			break
		}

		child_pv: PV_Line
		full_score := -negamax(
			&st,
			&b,
			-eval.INF,
			eval.INF,
			depth - 1,
			1,
			&child_pv,
		)
		board.unmake_move(&b, &state)

		if full_score > current_alpha {
			current_alpha = full_score
		}
		legal_moves += 1
	}

	if !target_found {
		fmt.printf("Root child trace FAILED: target move %s was not legal in root position\n", target_move_text)
	}
}

// Initialize a SearchThread
init_search_thread :: proc(st: ^SearchThread, id: int) {
	st.thread_id = id
	st.nodes = 0
	st.extend_all_checks = false
	st.root_pawn_only_endgame = false
	clear_killers(st)
	clear_history(st)
	clear_capture_history(st)
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

history_gravity_update :: proc(current: int, bonus: int) -> int {
	abs_bonus := bonus
	if abs_bonus < 0 {
		abs_bonus = -abs_bonus
	}

	updated := current + bonus - current * abs_bonus / params.history_max
	if updated > params.history_max {
		return params.history_max
	}
	if updated < params.history_min {
		return params.history_min
	}
	return updated
}

// Update history with result (positive for cutoffs, negative for fails)
update_history :: proc(st: ^SearchThread, move: moves.Move, depth: int, good: bool) {
	// Bonus based on depth (deeper searches = more important)
	bonus := depth * depth
	if !good {
		bonus = -bonus // Penalize moves that don't cause cutoffs
	}

	current := st.history_table[move.piece][move.target]
	st.history_table[move.piece][move.target] = history_gravity_update(current, bonus)
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

update_capture_history :: proc(st: ^SearchThread, move: moves.Move, depth: int, good: bool) {
	if move.piece < 0 || move.piece >= 12 {return}
	if move.target < 0 || move.target >= 64 {return}

	bonus := depth * depth
	if !good {
		bonus = -bonus
		stat_add(&search_stats.capture_history_maluses)
	} else {
		stat_add(&search_stats.capture_history_updates)
	}

	current := st.capture_history[move.piece][move.target]
	st.capture_history[move.piece][move.target] = history_gravity_update(current, bonus)
}

get_capture_history_score :: proc(st: ^SearchThread, move: moves.Move) -> int {
	if move.piece < 0 || move.piece >= 12 {return 0}
	if move.target < 0 || move.target >= 64 {return 0}
	return st.capture_history[move.piece][move.target]
}

clear_capture_history :: proc(st: ^SearchThread) {
	for i in 0 ..< 12 {
		for j in 0 ..< 64 {
			st.capture_history[i][j] = 0
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
		stat_add(&search_stats.continuation_maluses)
	} else {
		stat_add(&search_stats.continuation_updates)
	}
	if search_stats_enabled {
		abs_bonus := bonus
		if abs_bonus < 0 {
			abs_bonus = -abs_bonus
		}
		if abs_bonus < params.continuation_score_div {
			stat_add(&search_stats.continuation_store_bonus_under_scale)
		} else {
			stat_add(&search_stats.continuation_store_bonus_visible)
		}
	}

	// Update with clamping
	old_val := st.continuation_history[prev_type][prev_move.target][curr_type][curr_move.target]
	new_val := old_val + bonus

	// Clamp to prevent overflow
	if new_val > params.history_max {new_val = params.history_max}
	if new_val < params.history_min {new_val = params.history_min}
	if search_stats_enabled {
		abs_new_val := new_val
		if abs_new_val < 0 {
			abs_new_val = -abs_new_val
		}
		if abs_new_val < params.continuation_score_div {
			stat_add(&search_stats.continuation_store_result_under_scale)
		} else {
			stat_add(&search_stats.continuation_store_result_visible)
		}
	}

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
	stat_add(&search_stats.nodes)
	if st.nodes % 1024 == 0 {
		sync.atomic_add(&total_nodes, 1024)
	}
}

// Get total nodes searched across all threads
get_total_nodes :: proc() -> u64 {
	return sync.atomic_load(&total_nodes)
}

has_non_pawn_material :: proc(b: ^board.Board, side: int) -> bool {
	offset := side * 6
	return (b.bitboards[offset + constants.KNIGHT] |
		b.bitboards[offset + constants.BISHOP] |
		b.bitboards[offset + constants.ROOK] |
		b.bitboards[offset + constants.QUEEN]) != 0
}

is_pawn_only_endgame :: proc(b: ^board.Board) -> bool {
	pawns := b.bitboards[constants.PAWN] | b.bitboards[constants.PAWN + 6]
	return !has_non_pawn_material(b, constants.WHITE) &&
	       !has_non_pawn_material(b, constants.BLACK) &&
	       pawns != 0
}

move_gives_check_after_make :: proc(b: ^board.Board) -> bool {
	attacker := 1 - b.side
	king_sq := board.get_king_square(b, b.side)
	return board.is_square_attacked(b, king_sq, attacker)
}

is_quiet_search_move :: proc(move: moves.Move) -> bool {
	return !move.capture && move.promoted == -1
}

is_mate_window :: proc(alpha, beta: int) -> bool {
	return abs(alpha) >= eval.MATE - MAX_PLY || abs(beta) >= eval.MATE - MAX_PLY
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
	pv_line.count = 0
	pv_line.tb_terminal = false

	// Syzygy WDL probes are exact; let them outrank cached TT bounds and
	// apply on PV nodes as well as cut nodes once tablebases are enabled.
	if depth >= 1 && moves.is_empty_move(excluded_move) && tb.syzygy_enabled {
		stat_add(&search_stats.tb_probes)
		tb_score, tb_hit := tb.probe_wdl(b)
		if tb_hit {
			stat_add(&search_stats.tb_hits)
			pv_line.tb_terminal = true
			return tb_score
		}
	}

	// TT Probe
	if moves.is_empty_move(excluded_move) && !search_debug_options.disable_tt_cutoffs {
		tt_score, tt_hit := probe_tt(b.hash, alpha, beta, depth, ply)
		if tt_hit {
			stat_add(&search_stats.tt_cutoffs)
			return tt_score
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
			// Signal all threads to stop immediately
			sync.atomic_store(&search_control.should_stop, i32(1))
			return alpha // Exit early with fail-low
		}
	}

	if ply >= MAX_PLY {
		stat_add(&search_stats.evals)
		return eval.evaluate(b)
	}

	// Check if in check (used by multiple features)
	king_sq := board.get_king_square(b, b.side)
	in_check := board.is_square_attacked(b, king_sq, 1 - b.side)
	pawn_only_endgame := st.root_pawn_only_endgame && is_pawn_only_endgame(b)

	// Check Extension - normally only extend checked frontier nodes.  Very
	// constrained root check evasions can opt into extending all checked nodes.
	effective_depth := depth
	if in_check &&
	   ply < params.check_ext_max_ply &&
	   (depth == 0 || st.extend_all_checks) {
		effective_depth = depth + 1
	}
	if effective_depth == 0 {
		return quiescence(st, b, alpha, beta, ply)
	}

	// Compute static evaluation once and cache it for improving heuristic
	stat_add(&search_stats.evals)
	static_eval := eval.evaluate(b)
	st.static_eval_stack[ply] = static_eval

	improving := false
	if ply >= 2 {
		improving = static_eval > st.static_eval_stack[ply - 2]
	}

	// Razoring - drop into quiescence if position is hopeless
	if !search_debug_options.disable_razor &&
	   !pawn_only_endgame &&
	   !is_pv && !in_check && !is_mate_window(alpha, beta) &&
	   depth <= params.razor_max_depth && moves.is_empty_move(excluded_move) {
		razor_margin := params.razor_margin * depth
		if static_eval + razor_margin < alpha {
			stat_add(&search_stats.razor_tries)
			// Position is so bad even with margin, just do quiescence
			qscore := quiescence(st, b, alpha, beta, ply)
			if qscore < alpha {
				stat_add(&search_stats.razor_cutoffs)
				return qscore
			}
		}
	}

	// Null Move Pruning
	// Apply null move if:
	// 1. Not in PV node (use is_pv flag)
	// 2. Not in check
	// 3. Deep enough
	can_null_move := !search_debug_options.disable_nmp &&
		!is_pv &&
		!in_check &&
		depth >= params.nmp_min_depth &&
		has_non_pawn_material(b, b.side) &&
		moves.is_empty_move(excluded_move) &&
		!is_mate_window(alpha, beta) &&
		static_eval >= beta

	if can_null_move {
		stat_add(&search_stats.nmp_tries)
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
		null_depth := effective_depth - 1 - nmp_reduction
		if null_depth < 1 {
			null_depth = 1
		}

		// Search null move at reduced depth
		null_pv: PV_Line
		null_score := -negamax(
			st,
			&null_board,
			-beta,
			-beta + 1,
			null_depth,
			ply + 1,
			&null_pv,
			{}, // no excluded move
			false, // not PV
		)

		// If null move fails high, prune
		if null_score >= beta {
			stat_add(&search_stats.nmp_cutoffs)
			return beta
		}
	}

	// Reverse Futility Pruning (RFP) / Static Null Move Pruning
	// If position is so good that even with a margin, we're above beta, prune
	// Skip ply 1: root children are PV-significant even when a root-PVS probe
	// searches them with a null window.
	if !search_debug_options.disable_rfp &&
	   !pawn_only_endgame &&
	   ply > 1 &&
	   !is_pv && !in_check && !is_mate_window(alpha, beta) &&
	   effective_depth <= params.rfp_depth && moves.is_empty_move(excluded_move) {
		// Margin based on depth
		rfp_margin := params.rfp_margin * effective_depth

		if static_eval - rfp_margin >= beta {
			stat_add(&search_stats.rfp_cutoffs)
			return static_eval - rfp_margin
		}
	}

	// TT Move (for probcut and move ordering)
	// Fetch early so probcut can use it for sorting tactical moves.
	tt_move := get_tt_move(b.hash)

	// Probcut
	// If the position is good enough that even a reduced-depth tactical search
	// would fail high, we can prune safely.
	if !search_debug_options.disable_probcut &&
	   !pawn_only_endgame &&
	   !is_pv && !in_check && !is_mate_window(alpha, beta) &&
	   effective_depth >= params.probcut_depth && moves.is_empty_move(excluded_move) {
		probcut_beta := beta + params.probcut_margin
		if probcut_beta >= eval.MATE - MAX_PLY {
			probcut_beta = eval.MATE - MAX_PLY - 1
		}
		if static_eval >= probcut_beta {
			stat_add(&search_stats.probcut_tries)
			// Try a few tactical moves at reduced depth
			tactical_list: moves.MoveList
			board.generate_all_moves(b, &tactical_list)
			stat_add(&search_stats.movegen_calls)
			stat_add(&search_stats.moves_generated, u64(tactical_list.count))
			tactical_picker: MovePicker
			init_move_picker(&tactical_picker, st, &tactical_list, b, tt_move, ply, prev_move)

			tactical_move: moves.Move
			for move_picker_next(&tactical_picker, &tactical_move) {
				if !tactical_move.capture && tactical_move.promoted == -1 {
					continue
				}

				if !board.is_castling_legal_now(b, tactical_move) {
					continue
				}

				t_state: board.StateInfo
				board.make_move_fast(b, tactical_move, &t_state)

				king_sq := board.get_king_square(b, 1 - b.side)
				if board.is_square_attacked(b, king_sq, b.side) {
					board.unmake_move(b, &t_state)
					stat_add(&search_stats.legal_rejects)
					continue
				}

				nnue.update_accumulators(&t_state, b, tactical_move)
				probcut_depth := effective_depth - params.probcut_reduce
				if probcut_depth < 1 {
					probcut_depth = 1
				}
				probcut_score := -negamax(
					st,
					b,
					-probcut_beta,
					-probcut_beta + 1,
					probcut_depth,
					ply + 1,
					&PV_Line{},
					{},
					false,
					tactical_move,
				)
				board.unmake_move(b, &t_state)

				if probcut_score >= probcut_beta {
					stat_add(&search_stats.probcut_cutoffs)
					return probcut_beta
				}
			}
		}
	}

	// Move Generation
	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated

	board.generate_all_moves(b, &move_list)
	stat_add(&search_stats.movegen_calls)
	stat_add(&search_stats.moves_generated, u64(move_list.count))

	// Internal Iterative Reduction (IIR)
	// If we have no hash move and this is a PV node, reduce depth.
	// We do not know what is good here, so search shallower first.
	if !search_debug_options.disable_iir &&
	   !pawn_only_endgame &&
	   moves.is_empty_move(tt_move) && is_pv && effective_depth >= params.iir_min_depth {
		effective_depth -= 1
	}

	// Move Ordering
	move_picker: MovePicker
	init_move_picker(&move_picker, st, &move_list, b, tt_move, ply, prev_move, false, is_pv)
	if !moves.is_empty_move(tt_move) && move_list.count > 0 {
		move_picker_prepare_current(&move_picker)
		if same_move(move_list.moves[0], tt_move) {
			stat_add(&search_stats.tt_move_first)
		}
	}

	// Singular Extensions
	// Test if TT move is "singularly" better than all alternatives
	extension := 0

	if depth >= params.se_depth &&
	   !in_check &&
	   ply > 0 &&
	   !moves.is_empty_move(tt_move) &&
	   moves.is_empty_move(excluded_move) {	// Don't do SE during SE search

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
	quiet_moves_searched: [64]moves.Move
	quiet_moves_count := 0
	capture_moves_searched: [64]moves.Move
	capture_moves_count := 0

	// Futility Pruning - pre-compute for move loop
	do_futility := false
	futility_value := 0
	if !search_debug_options.disable_futility &&
	   !pawn_only_endgame &&
	   !is_pv && !in_check && !is_mate_window(alpha, beta) &&
	   depth <= params.futility_max_depth && moves.is_empty_move(excluded_move) {
		futility_margin := params.futility_margin * depth
		futility_value = static_eval + futility_margin
		if futility_value < alpha {
			do_futility = true
		}
	}

	// Late Move Pruning (LMP)
	// Skip quiet moves beyond a certain threshold.
	// The idea: if we've searched the best moves and none raised alpha,
	// the remaining quiet moves are unlikely to help.
	lmp_threshold := 9999 // Default: effectively disabled
	if !search_debug_options.disable_lmp &&
	   !pawn_only_endgame &&
	   !is_pv && !in_check && !is_mate_window(alpha, beta) &&
	   depth <= params.lmp_max_depth && moves.is_empty_move(excluded_move) {
		// Threshold grows with depth: deeper = search more moves
		lmp_threshold = params.lmp_base + depth * depth / params.lmp_div
	}

	move: moves.Move
	for move_picker_next(&move_picker, &move) {
		// Check for stop signal between moves
		if should_stop_search() {
			break
		}

		// Skip excluded move (for singular extensions)
		if !moves.is_empty_move(excluded_move) &&
		   move.source == excluded_move.source &&
		   move.target == excluded_move.target &&
		   move.promoted == excluded_move.promoted {
			continue
		}

		if !board.is_castling_legal_now(b, move) {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move, &state)

		// Check legality: king of side that moved must not be in check
		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			if same_move(move, tt_move) {
				stat_add(&search_stats.tt_move_legal_rejects)
			}
			stat_add(&search_stats.legal_rejects)
			continue
		}
		if legal_moves == 0 && same_move(move, tt_move) {
			stat_add(&search_stats.tt_move_first_legal)
		}

		// Update NNUE Accumulators (state holds the old board for reference)
		nnue.update_accumulators(&state, b, move)
		gives_check := move_gives_check_after_make(b)
		quiet_move := is_quiet_search_move(move)
		history_score := 0
		if quiet_move {
			history_score = get_history_score(st, move)
		}

		// Late Move Pruning (LMP)
		// Skip quiet moves that are late in the move list.
		// Only prune if we've already searched enough moves without finding a good one.
		if !is_pv && !in_check && legal_moves >= lmp_threshold && quiet_moves_count > 0 &&
		   !gives_check && quiet_move {
			board.unmake_move(b, &state)
			stat_add(&search_stats.lmp_prunes)
			continue
		}

		// Futility Pruning - skip quiet moves that can't raise alpha
		if do_futility && legal_moves > 0 && !gives_check &&
		   quiet_move {
			board.unmake_move(b, &state)
			stat_add(&search_stats.futility_prunes)
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
				move, // prev_move for counter-moves
			)
		} else {
			// Subsequent moves: PVS with LMR

			// Late Move Reductions (LMR)
			// Use precomputed table + standard adjustments.
			reduction := 0

			if !search_debug_options.disable_lmr &&
			   !pawn_only_endgame &&
			   combined_depth >= params.lmr_min_depth &&
			   !gives_check &&
			   quiet_move {
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
				if history_score > params.lmr_history_good_thresh {
					reduction += params.lmr_history_good_adj
				} else if history_score < params.lmr_history_bad_thresh {
					reduction += params.lmr_history_bad_adj
				}

				// Clamp: never reduce below 0, never into quiescence
				if reduction < 0 { reduction = 0 }
				if reduction > combined_depth - 2 { reduction = combined_depth - 2 }
			}
			if reduction > 0 {
				stat_add(&search_stats.lmr_searches)
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
				move, // prev_move for counter-moves
			)

			// Re-search if reduced search raised alpha
			if score > current_alpha && reduction > 0 {
				stat_add(&search_stats.lmr_researches)
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
					move, // prev_move for counter-moves
				)
			}

			// Re-search if within bounds (PVS)
			if score > current_alpha && score < beta {
				stat_add(&search_stats.pvs_researches)
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
					move, // prev_move for counter-moves
				)
			}
		}

		board.unmake_move(b, &state)
		legal_moves += 1

		if score > best_score {
			best_score = score
			best_move = move
			// Update PV
			pv_line.moves[0] = move
			for pv_i in 0 ..< child_pv.count {
				pv_line.moves[pv_i + 1] = child_pv.moves[pv_i]
			}
			pv_line.count = child_pv.count + 1
			pv_line.tb_terminal = child_pv.tb_terminal
		}

		if score > current_alpha {
			current_alpha = score
		}

		if current_alpha >= beta {
			stat_add(&search_stats.beta_cutoffs)
			if move.capture || move.promoted != -1 {
				stat_add(&search_stats.capture_beta_cutoffs)
				update_capture_history(st, move, effective_depth, true)
				for j in 0 ..< capture_moves_count {
					update_capture_history(st, capture_moves_searched[j], effective_depth, false)
				}
			}
			// Beta Cutoff - store killer, history, and counter move for quiet moves
			if !move.capture && move.promoted == -1 {
				stat_add(&search_stats.quiet_beta_cutoffs)
				store_killer(st, move, ply)
				update_history(st, move, effective_depth, true)
				for j in 0 ..< quiet_moves_count {
					update_history(st, quiet_moves_searched[j], effective_depth, false)
				}

				// Store as counter move if we have a previous move
				if !moves.is_empty_move(prev_move) {
					store_counter_move(st, prev_move, move)
					store_continuation(st, prev_move, move, effective_depth, true)
					for j in 0 ..< quiet_moves_count {
						store_continuation(st, prev_move, quiet_moves_searched[j], effective_depth, false)
					}
				}
			}
			break
		}

		if !move.capture && move.promoted == -1 &&
		   quiet_moves_count < len(quiet_moves_searched) {
			quiet_moves_searched[quiet_moves_count] = move
			quiet_moves_count += 1
		} else if (move.capture || move.promoted != -1) &&
		          capture_moves_count < len(capture_moves_searched) {
			capture_moves_searched[capture_moves_count] = move
			capture_moves_count += 1
		}
	}

	// Checkmate / Stalemate Detection
	if legal_moves == 0 {
		// If in check -> Checkmate
		// We need `is_in_check`.
		// Let's use `is_square_attacked` on King.
		king_sq := board.get_king_square(b, b.side)
		if board.is_square_attacked(b, king_sq, 1 - b.side) {
			return -eval.MATE + ply // Prefer shorter mates
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

attackers_to_square :: proc(b: ^board.Board, square: int, occ: u64, side: int) -> u64 {
	target := u64(1) << u64(square)
	offset := side * 6

	attackers: u64 = 0
	if side == constants.WHITE {
		attackers |= ((target >> 9) & ~constants.FILE_H) & b.bitboards[constants.PAWN]
		attackers |= ((target >> 7) & ~constants.FILE_A) & b.bitboards[constants.PAWN]
	} else {
		attackers |= ((target << 9) & ~constants.FILE_A) & b.bitboards[constants.PAWN + 6]
		attackers |= ((target << 7) & ~constants.FILE_H) & b.bitboards[constants.PAWN + 6]
	}

	attackers |= moves.get_knight_attacks_bitboard(square) & b.bitboards[offset + constants.KNIGHT]
	attackers |= moves.get_king_attacks_bitboard(square) & b.bitboards[offset + constants.KING]
	attackers |= moves.get_bishop_attacks(square, occ) &
		(b.bitboards[offset + constants.BISHOP] | b.bitboards[offset + constants.QUEEN])
	attackers |= moves.get_rook_attacks(square, occ) &
		(b.bitboards[offset + constants.ROOK] | b.bitboards[offset + constants.QUEEN])

	return attackers & occ
}

least_valuable_attacker :: proc(b: ^board.Board, attackers: u64, side: int) -> (piece_type: int, square: int, found: bool) {
	offset := side * 6
	for pt in constants.PAWN ..= constants.KING {
		bb := attackers & b.bitboards[offset + pt]
		if bb != 0 {
			return pt, utils.get_lsb_index(bb), true
		}
	}
	return 0, 0, false
}

// Static Exchange Evaluation. Returns the material result of the capture
// after both sides make their best recaptures on the target square.
see_capture :: proc(b: ^board.Board, move: moves.Move) -> int {
	stat_add(&search_stats.see_calls)
	if !move.capture {
		return 0
	}

	victim_value := 0
	if move.en_passant {
		victim_value = constants.PIECE_VALUES[constants.PAWN]
	} else {
		victim_idx := int(b.mailbox[move.target])
		if victim_idx == -1 {
			return 0
		}
		victim_value = constants.PIECE_VALUES[victim_idx % 6]
	}

	moved_piece := move.piece
	if move.promoted != -1 {
		moved_piece = move.promoted
	}

	gain: [32]int
	depth := 0
	gain[0] = victim_value

	occ := b.occupancies[constants.BOTH]
	occ &~= u64(1) << u64(move.source)
	if move.en_passant {
		ep_sq := b.side == constants.WHITE ? move.target - 8 : move.target + 8
		occ &~= u64(1) << u64(ep_sq)
		occ |= u64(1) << u64(move.target)
	}

	side := 1 - b.side
	captured_value := constants.PIECE_VALUES[moved_piece]

	for depth + 1 < len(gain) {
		attackers := attackers_to_square(b, move.target, occ, side)
		attacker_piece, attacker_sq, found := least_valuable_attacker(b, attackers, side)
		if !found {
			break
		}

		depth += 1
		gain[depth] = captured_value - gain[depth - 1]

		occ &~= u64(1) << u64(attacker_sq)
		captured_value = constants.PIECE_VALUES[attacker_piece]
		side = 1 - side
	}

	for depth > 0 {
		depth -= 1
		if -gain[depth + 1] < gain[depth] {
			gain[depth] = -gain[depth + 1]
		}
	}

	return gain[0]
}

// Quiescence Search
quiescence :: proc(st: ^SearchThread, b: ^board.Board, alpha: int, beta: int, ply: int) -> int {
	count_nodes(st)
	stat_add(&search_stats.qnodes)

	// Time check: stop if hard limit exceeded
	if use_time_management && st.nodes % 1024 == 0 {
		if should_stop(search_limits) {
			sync.atomic_store(&search_control.should_stop, i32(1))
			return alpha
		}
	}

	// Also check for external stop signal
	if st.nodes % 1024 == 0 {
		if should_stop_search() {
			return alpha
		}
	}

	if tb.syzygy_enabled {
		stat_add(&search_stats.tb_probes)
		tb_score, tb_hit := tb.probe_wdl(b)
		if tb_hit {
			stat_add(&search_stats.tb_hits)
			return tb_score
		}
	}

	if ply >= MAX_PLY {
		stat_add(&search_stats.evals)
		return eval.evaluate(b)
	}

	stat_add(&search_stats.evals)
	evaluation := eval.evaluate(b)

	king_sq := board.get_king_square(b, b.side)
	in_check := board.is_square_attacked(b, king_sq, 1 - b.side)

	current_alpha := alpha
	if !in_check {
		if evaluation >= beta {
			return beta
		}

		if evaluation > current_alpha {
			current_alpha = evaluation
		}

		// Delta Pruning
		// If even capturing the most valuable piece won't raise alpha,
		// stop searching captures.  Delta is the maximum material swing
		// from a single capture (typically queen value + small margin).
		if evaluation + params.delta_pruning_margin < alpha {
			stat_add(&search_stats.q_delta_prunes)
			return evaluation
		}
	}

	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated
	q_see_scores: [256]int
	if in_check {
		board.generate_all_moves(b, &move_list)
		stat_add(&search_stats.movegen_calls)
		stat_add(&search_stats.moves_generated, u64(move_list.count))
		sort_moves(st, &move_list, b, see_scores = &q_see_scores)
	} else {
		generated := order_qcaptures_from_capture_generator(st, b, &move_list, &q_see_scores, true)
		stat_add(&search_stats.movegen_calls)
		stat_add(&search_stats.moves_generated, u64(generated))
	}

	legal_moves := 0

	for i in 0 ..< move_list.count {
		// In quiescence, search captures and promotions unless we are in check.
		// When in check, we must search all legal moves (including non-captures)
		// because the king must escape check.
		if !in_check && !move_list.moves[i].capture && move_list.moves[i].promoted == -1 {
			continue
		}

		// SEE Pruning - skip obviously losing captures
		// Only apply to captures when not in check
		if move_list.moves[i].capture && !in_check {
			see_score := q_see_scores[i]
			if see_score == SEE_SCORE_UNKNOWN {
				see_score = see_capture(b, move_list.moves[i])
			} else {
				stat_add(&search_stats.see_cache_hits)
			}
			if see_score < params.see_prune_threshold {
				stat_add(&search_stats.q_see_prunes)
				continue // Skip this losing capture
			}
		}

		if !board.is_castling_legal_now(b, move_list.moves[i]) {
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move_list.moves[i], &state)

		// Check legality
		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			stat_add(&search_stats.legal_rejects)
			continue
		}
		legal_moves += 1

		nnue.update_accumulators(&state, b, move_list.moves[i])
		score := -quiescence(st, b, -beta, -current_alpha, ply + 1)

		board.unmake_move(b, &state)

		if score >= beta {
			return beta
		}
		if score > current_alpha {
			current_alpha = score
		}
	}

	// Checkmate / stalemate detection in quiescence
	if legal_moves == 0 {
		king_sq := board.get_king_square(b, b.side)
		if board.is_square_attacked(b, king_sq, 1 - b.side) {
			return -eval.MATE + ply // Checkmate
		} else {
			return current_alpha // Stalemate or no captures - return best found
		}
	}

	return current_alpha
}

run_root_search_pass :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	depth: int,
	alpha: int,
	beta: int,
	root_tt_move: moves.Move,
	pv_index: int,
	root_pv_first_legal_counted: ^bool,
	debug_trace: bool = false,
	debug_phase: string = "",
) -> RootSearchPassResult {
	result := RootSearchPassResult {
		best_score    = -eval.INF,
		completed     = true,
		root_tt_score = -eval.INF,
	}
	current_alpha := alpha

	if debug_trace {
		fmt.printf("info string rootdebug pass phase=%s depth=%d alpha=%d beta=%d root_seed=", debug_phase, depth, alpha, beta)
		root_debug_print_move(root_tt_move)
		fmt.println()
		os.flush(os.stdout)
	}

	for i in 0 ..< move_list.count {
		if should_stop_search() {
			result.completed = false
			break
		}

		move := move_list.moves[i]
		if !board.is_castling_legal_now(b, move) {
			if debug_trace {
				fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
				root_debug_print_move(move)
				fmt.println(" reason=castle_illegal")
			}
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move, &state)

		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			stat_add(&search_stats.legal_rejects)
			if debug_trace {
				fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
				root_debug_print_move(move)
				fmt.println(" reason=self_check")
			}
			continue
		}
		if !root_pv_first_legal_counted^ && i == 0 && same_move(move, root_tt_move) {
			stat_add(&search_stats.root_pv_first_legal)
			root_pv_first_legal_counted^ = true
		}

		nnue.update_accumulators(&state, b, move)

		child_pv: PV_Line
		alpha_before := current_alpha
		child_alpha := -beta
		child_beta := -current_alpha
		child_depth := depth - 1
		child_tt_info: TTDebugInfo
		if debug_trace {
			child_tt_info = probe_tt_debug(b.hash, child_alpha, child_beta, child_depth, 1)
		}
		nodes_before := st.nodes
		score := -negamax(
			st,
			b,
			child_alpha,
			child_beta,
			child_depth,
			1,
			&child_pv,
		)
		nodes_delta := st.nodes - nodes_before

		board.unmake_move(b, &state)
		if result.count < len(result.entries) {
			result.entries[result.count] = RootSearchPassEntry {
				move         = move,
				order_index  = i + 1,
				score        = score,
				alpha_before = alpha_before,
				nodes        = nodes_delta,
			}
			result.count += 1
		}
		if pv_index == 0 && !moves.is_empty_move(root_tt_move) && same_move(move, root_tt_move) {
			result.root_tt_seen = true
			result.root_tt_score = score
		}

		new_best := score > result.best_score
		if score > result.best_score {
			result.best_score = score
			result.best_move = move
			result.found_move = true

			result.best_pv.moves[0] = move
			for i in 0 ..< child_pv.count {
				result.best_pv.moves[i + 1] = child_pv.moves[i]
			}
			result.best_pv.count = child_pv.count + 1
			result.best_pv.tb_terminal = child_pv.tb_terminal
		}

		if score > current_alpha {
			current_alpha = score
		}

		if debug_trace {
			fmt.printf(
				"info string rootdebug child phase=%s idx=%d move=",
				debug_phase,
				i + 1,
			)
			root_debug_print_move(move)
			fmt.printf(
				" score=%d alpha_before=%d alpha_after=%d beta=%d nodes=%d new_best=%v root_seed=%v child_window=[%d,%d] child_tt=",
				score,
				alpha_before,
				current_alpha,
				beta,
				nodes_delta,
				new_best,
				same_move(move, root_tt_move),
				child_alpha,
				child_beta,
			)
			if child_tt_info.hit {
				cutoff := "none"
				if child_tt_info.exact_cutoff {
					cutoff = "exact"
				} else if child_tt_info.alpha_cutoff {
					cutoff = "alpha"
				} else if child_tt_info.beta_cutoff {
					cutoff = "beta"
				}
				fmt.printf(
					"hit(slot=%d flag=%s depth=%d/%d score=%d raw=%d age=%d depth_ok=%v cutoff=%s) pv=",
					child_tt_info.slot,
					tt_flag_name(child_tt_info.flag),
					child_tt_info.depth,
					child_depth,
					child_tt_info.score,
					child_tt_info.raw_score,
					child_tt_info.age,
					child_tt_info.depth_ok,
					cutoff,
				)
			} else {
				fmt.printf("miss pv=")
			}
			root_debug_print_pv(move, &child_pv)
			fmt.println()
			os.flush(os.stdout)
		}

	}

	if debug_trace {
		fmt.printf("info string rootdebug pass_result phase=%s completed=%v found=%v best=", debug_phase, result.completed, result.found_move)
		root_debug_print_move(result.best_move)
		fmt.printf(" best_score=%d root_seed_seen=%v root_seed_score=%d\n", result.best_score, result.root_tt_seen, result.root_tt_score)
		os.flush(os.stdout)
	}

	return result
}

run_root_full_window_verification_pass :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	depth: int,
	root_tt_move: moves.Move,
	pv_index: int,
	root_pv_first_legal_counted: ^bool,
	debug_trace: bool = false,
	debug_phase: string = "",
	verify_all: bool = false,
	extra_verify_move_1: moves.Move = moves.Move{},
	extra_verify_move_2: moves.Move = moves.Move{},
	candidate_set: ^RootVerifyCandidateSet = nil,
) -> RootSearchPassResult {
	result := RootSearchPassResult {
		best_score    = -eval.INF,
		completed     = true,
		root_tt_score = -eval.INF,
	}

	if debug_trace {
		fmt.printf("info string rootdebug pass phase=%s depth=%d alpha=%d beta=%d root_seed=", debug_phase, depth, -eval.INF, eval.INF)
		root_debug_print_move(root_tt_move)
		fmt.println()
		os.flush(os.stdout)
	}

	for i in 0 ..< move_list.count {
		if should_stop_search() {
			result.completed = false
			break
		}

		move := move_list.moves[i]
		// Verify the stale TT move plus forcing/high-signal alternatives only.
		if !verify_all {
			if candidate_set != nil && i < candidate_set.count {
				if !candidate_set.include[i] {
					if debug_trace {
						fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
						root_debug_print_move(move)
						fmt.printf(" reason=%s\n", candidate_set.reason[i])
					}
					continue
				}
			} else if !same_move(move, root_tt_move) &&
			          !same_move(move, extra_verify_move_1) &&
			          !same_move(move, extra_verify_move_2) {
				include, reason, _ := root_verify_candidate_decision(
					st,
					b,
					move,
					root_tt_move,
					verify_all,
					extra_verify_move_1,
					extra_verify_move_2,
				)
				if !include {
					if debug_trace {
						fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
						root_debug_print_move(move)
						fmt.printf(" reason=%s\n", reason)
					}
					continue
				}
			}
		}

		if !board.is_castling_legal_now(b, move) {
			if debug_trace {
				fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
				root_debug_print_move(move)
				fmt.println(" reason=castle_illegal")
			}
			continue
		}

		state: board.StateInfo
		board.make_move_fast(b, move, &state)

		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			stat_add(&search_stats.legal_rejects)
			if debug_trace {
				fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
				root_debug_print_move(move)
				fmt.println(" reason=self_check")
			}
			continue
		}
		if !root_pv_first_legal_counted^ && i == 0 && same_move(move, root_tt_move) {
			stat_add(&search_stats.root_pv_first_legal)
			root_pv_first_legal_counted^ = true
		}

		nnue.update_accumulators(&state, b, move)

		child_pv: PV_Line
		nodes_before := st.nodes
		score := -negamax(
			st,
			b,
			-eval.INF,
			eval.INF,
			depth - 1,
			1,
			&child_pv,
		)
		nodes_delta := st.nodes - nodes_before

		board.unmake_move(b, &state)
		if pv_index == 0 && !moves.is_empty_move(root_tt_move) && same_move(move, root_tt_move) {
			result.root_tt_seen = true
			result.root_tt_score = score
		}

		new_best := score > result.best_score
		if score > result.best_score {
			result.best_score = score
			result.best_move = move
			result.found_move = true

			result.best_pv.moves[0] = move
			for i in 0 ..< child_pv.count {
				result.best_pv.moves[i + 1] = child_pv.moves[i]
			}
			result.best_pv.count = child_pv.count + 1
			result.best_pv.tb_terminal = child_pv.tb_terminal
		}

		if debug_trace {
			fmt.printf(
				"info string rootdebug child phase=%s idx=%d move=",
				debug_phase,
				i + 1,
			)
			root_debug_print_move(move)
			fmt.printf(
				" score=%d alpha_before=%d alpha_after=%d beta=%d nodes=%d new_best=%v root_seed=%v pv=",
				score,
				-eval.INF,
				eval.INF,
				eval.INF,
				nodes_delta,
				new_best,
				same_move(move, root_tt_move),
			)
			root_debug_print_pv(move, &child_pv)
			fmt.println()
			os.flush(os.stdout)
		}
	}

	if debug_trace {
		fmt.printf("info string rootdebug pass_result phase=%s completed=%v found=%v best=", debug_phase, result.completed, result.found_move)
		root_debug_print_move(result.best_move)
		fmt.printf(" best_score=%d root_seed_seen=%v root_seed_score=%d\n", result.best_score, result.root_tt_seen, result.root_tt_score)
		os.flush(os.stdout)
	}

	return result
}

run_root_snapshot_verification_pass :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	move_list: ^moves.MoveList,
	depth: int,
	root_tt_move: moves.Move,
	pv_index: int,
	root_pv_first_legal_counted: ^bool,
	tt_snapshot: []TTBucket,
	candidate_set: ^RootVerifyCandidateSet,
	debug_trace: bool = false,
	debug_phase: string = "",
	baseline_move: moves.Move = moves.Move{},
	baseline_score: int = -eval.INF,
	baseline_pv: PV_Line = PV_Line{},
) -> RootSearchPassResult {
	result := RootSearchPassResult {
		best_score    = baseline_score,
		best_move     = baseline_move,
		best_pv       = baseline_pv,
		found_move    = !moves.is_empty_move(baseline_move),
		completed     = true,
		root_tt_score = -eval.INF,
	}

	if debug_trace {
		fmt.printf("info string rootdebug pass phase=%s depth=%d alpha=%d beta=%d root_seed=", debug_phase, depth, -eval.INF, eval.INF)
		root_debug_print_move(root_tt_move)
		fmt.println(" snapshot=true")
		os.flush(os.stdout)
	}

	searched: [256]bool
	stop_verification := false
	for verify_priority := 0; verify_priority <= ROOT_VERIFY_PRIORITY_QUIET; verify_priority += 1 {
		for i in 0 ..< move_list.count {
			if searched[i] {
				continue
			}
			if should_stop_search() {
				result.completed = false
				stop_verification = true
				break
			}

			move := move_list.moves[i]
			reason := "candidate"
			candidate_priority := ROOT_VERIFY_PRIORITY_CORE
			if candidate_set != nil && i < candidate_set.count {
				reason = candidate_set.reason[i]
				if !candidate_set.include[i] {
					searched[i] = true
					if debug_trace {
						fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
						root_debug_print_move(move)
						fmt.printf(" reason=%s\n", reason)
					}
					continue
				}
				candidate_priority = candidate_set.priority[i]
			}
			if candidate_priority != verify_priority {
				continue
			}
			searched[i] = true

			if !board.is_castling_legal_now(b, move) {
				if debug_trace {
					fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
					root_debug_print_move(move)
					fmt.println(" reason=castle_illegal")
				}
				continue
			}

			state: board.StateInfo
			board.make_move_fast(b, move, &state)
			king_sq := board.get_king_square(b, 1 - b.side)
			illegal := board.is_square_attacked(b, king_sq, b.side)
			board.unmake_move(b, &state)
			if illegal {
				stat_add(&search_stats.legal_rejects)
				if debug_trace {
					fmt.printf("info string rootdebug skip phase=%s idx=%d move=", debug_phase, i + 1)
					root_debug_print_move(move)
					fmt.println(" reason=self_check")
				}
				continue
			}

			if !root_pv_first_legal_counted^ && i == 0 && same_move(move, root_tt_move) {
				stat_add(&search_stats.root_pv_first_legal)
				root_pv_first_legal_counted^ = true
			}

			nodes_before := st.nodes
			scored := trace_score_root_child_from_snapshot(
				st,
				b,
				move,
				tt_snapshot,
				depth,
				-eval.INF,
				eval.INF,
				true,
			)
			st.nodes += scored.nodes
			nodes_delta := st.nodes - nodes_before
			score := scored.score

			if should_stop_search() {
				result.completed = false
				stop_verification = true
				break
			}

			if result.count < len(result.entries) {
				result.entries[result.count] = RootSearchPassEntry {
					move         = move,
					order_index  = i + 1,
					score        = score,
					alpha_before = -eval.INF,
					nodes        = nodes_delta,
				}
				result.count += 1
			}

			if pv_index == 0 && !moves.is_empty_move(root_tt_move) && same_move(move, root_tt_move) {
				result.root_tt_seen = true
				result.root_tt_score = score
			}

			new_best := score > result.best_score
			if score > result.best_score {
				result.best_score = score
				result.best_move = move
				result.found_move = true

				result.best_pv.moves[0] = move
				for pv_i in 0 ..< scored.pv.count {
					result.best_pv.moves[pv_i + 1] = scored.pv.moves[pv_i]
				}
				result.best_pv.count = scored.pv.count + 1
				result.best_pv.tb_terminal = scored.pv.tb_terminal
			}

			if debug_trace {
				fmt.printf("info string rootdebug child phase=%s idx=%d move=", debug_phase, i + 1)
				root_debug_print_move(move)
				fmt.printf(
					" score=%d alpha_before=%d alpha_after=%d beta=%d nodes=%d new_best=%v root_seed=%v reason=%s pv=",
					score,
					-eval.INF,
					eval.INF,
					eval.INF,
					nodes_delta,
					new_best,
					same_move(move, root_tt_move),
					reason,
				)
				root_debug_print_pv(move, &scored.pv)
				fmt.println()
				os.flush(os.stdout)
			}
		}
		if stop_verification {
			break
		}
	}

	restore_tt(tt_snapshot)

	if debug_trace {
		fmt.printf("info string rootdebug pass_result phase=%s completed=%v found=%v best=", debug_phase, result.completed, result.found_move)
		root_debug_print_move(result.best_move)
		fmt.printf(" best_score=%d root_seed_seen=%v root_seed_score=%d snapshot=true\n", result.best_score, result.root_tt_seen, result.root_tt_score)
		os.flush(os.stdout)
	}

	return result
}

// Root Search
search_position :: proc(
	st: ^SearchThread,
	b: ^board.Board,
	depth: int,
	multi_pv_count: int = 1,
	output_bestmove: bool = true,
	reset_shared_state: bool = true,
) {
	// fmt.println("DEBUG: Entering search_position")
	st.nodes = 0
	if reset_shared_state {
		reset_shared_search_state(st.thread_id == 0)
	}
	clear_killers(st) // Clear killer moves for new search
	clear_history(st) // Clear history table for new search
	clear_capture_history(st)
	clear_counter_moves(st) // Clear counter moves for new search
	init_continuation_history(st) // Initialize continuation history
	st.root_pawn_only_endgame = is_pawn_only_endgame(b)
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

	// Dynamic time-management state
	prev_best_move: moves.Move
	previous_completed_score := 0
	have_completed_score := false
	best_move_changes := 0
	largest_score_drop := 0
	aspiration_failures := 0
	aspiration_fail_low_count := 0
	aspiration_fail_high_count := 0
	previous_completed_pv_len := 0
	previous_depth_ms := 0
	last_depth_ms := 0

	// MultiPV storage - track best N moves
	multi_pv_results: [dynamic]MultiPV_Result
	defer delete(multi_pv_results)

	// Iterative Deepening
	prev_completed_best_move: moves.Move  // Save last fully completed depth's best move
	depth_completed := true
	for current_depth in 1 ..= depth {
		depth_start := time.now()

		// Save best move before attempting this depth (for recovery if aborted)
		prev_completed_best_move = best_move
		depth_completed = true

		// Clear MultiPV results for this depth
		clear(&multi_pv_results)

		// Generate all root moves once
		all_moves: moves.MoveList
		// deferred delete removed: MoveList is stack-allocated
		board.generate_all_moves(b, &all_moves)
		stat_add(&search_stats.movegen_calls)
		stat_add(&search_stats.moves_generated, u64(all_moves.count))

		// Track which moves have been searched for MultiPV
		excluded_moves: [dynamic]moves.Move
		defer delete(excluded_moves)

		// Search each PV line
		pv_lines_to_search := multi_pv_count
		if pv_lines_to_search > all_moves.count {
			pv_lines_to_search = all_moves.count
		}

		root_king_sq := board.get_king_square(b, b.side)
		root_in_check := board.is_square_attacked(b, root_king_sq, 1 - b.side)
		// Very short movetime check evasions can inherit a shallow PV seed
		// that survives tied fail-low research; let current ordering lead.
		tight_check_evasion_search :=
			root_in_check &&
			use_time_management &&
			search_limits.is_movetime &&
			search_limits.hard_time <= TIGHT_CHECK_EVASION_SEED_LIMIT_MS
		root_legal_moves := all_moves.count
		if tight_check_evasion_search {
			root_legal_moves = count_legal_root_moves(b, &all_moves)
		}
		st.extend_all_checks = tight_check_evasion_search && root_legal_moves <= 2

		for pv_index in 0 ..< pv_lines_to_search {
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

			fixed_depth_root_verify := current_depth == depth && current_depth >= 9 && pv_index == 0
			fixed_depth_fail_high_verify := current_depth == depth && current_depth >= 6 && pv_index == 0
			timed_root_verify_prepared := false
			timed_mixed_root_verify_prepared := false
			timed_root_capture_verify_prepared := false
			if current_depth >= 9 && pv_index == 0 && use_time_management {
				timed_root_verify_prepared = should_prepare_timed_root_verify(
					search_limits,
					last_depth_ms,
					previous_depth_ms,
					best_move_changes,
					largest_score_drop,
					aspiration_failures,
				)
				if !timed_root_verify_prepared &&
				   current_depth >= 12 &&
				   previous_completed_pv_len >= current_depth - 1 &&
				   aspiration_fail_low_count >= 4 &&
				   aspiration_fail_high_count >= 3 {
					timed_mixed_root_verify_prepared = true
					timed_root_verify_prepared = true
				}
			}

			root_tt_move := moves.Move{}
			if pv_index == 0 && !tight_check_evasion_search {
				root_tt_move = best_move
				if moves.is_empty_move(root_tt_move) {
					root_tt_move = prev_completed_best_move
				}
			}
			actual_root_tt_move := moves.Move{}
			debug_root_pass := root_debug_trace_enabled && pv_index == 0 && (current_depth == depth || use_time_management)

			// Sort root moves, preserving the previous completed PV move first.
			sort_moves(st, &move_list, b, root_tt_move, 0, moves.Move{})
			if !moves.is_empty_move(root_tt_move) && move_list.count > 0 && same_move(move_list.moves[0], root_tt_move) {
				stat_add(&search_stats.root_pv_first)
			}

			// Late clock searches can carry a capture root seed through a
			// fail-low without being close enough to prepare the normal
			// verifier.  Snapshot this narrow class before the root pass so
			// a cheap quiet check can recover obvious full-window misses.
			if current_depth >= 15 &&
			   pv_index == 0 &&
			   use_time_management &&
			   !timed_root_verify_prepared &&
			   previous_completed_pv_len >= current_depth - 1 &&
			   aspiration_fail_high_count >= 5 {
				for root_seed_idx in 0 ..< move_list.count {
					if same_move(move_list.moves[root_seed_idx], root_tt_move) &&
					   move_list.moves[root_seed_idx].capture {
						timed_root_capture_verify_prepared = true
						timed_root_verify_prepared = true
						break
					}
				}
			}

			prepare_clean_root_verify := fixed_depth_root_verify || fixed_depth_fail_high_verify || timed_root_verify_prepared
			if debug_root_pass || prepare_clean_root_verify {
				actual_root_tt_move = get_tt_move(b.hash)
			}

			verify_from_clean_root := false
			verify_tt_snapshot: []TTBucket
			verify_st: SearchThread
			if prepare_clean_root_verify {
				verify_from_clean_root = true
				verify_tt_snapshot = snapshot_tt()
				verify_st = clone_search_thread(st)
				verify_st.nodes = 0
			}

			if debug_root_pass {
				fmt.printf(
					"info string rootdebug root depth=%d pv=%d alpha=%d beta=%d prev_score=%d verify_clean=%v root_seed=",
					current_depth,
					pv_index + 1,
					alpha,
					beta,
					prev_score,
					verify_from_clean_root,
				)
				root_debug_print_move(root_tt_move)
				fmt.printf(" tt_move=")
				root_debug_print_move(actual_root_tt_move)
				fmt.printf(" best_before=")
				root_debug_print_move(best_move)
				fmt.printf(" prev_completed=")
				root_debug_print_move(prev_completed_best_move)
				fmt.println()
				for order_idx in 0 ..< move_list.count {
					order_move := move_list.moves[order_idx]
					if !trace_root_legal_move(b, order_move) {
						continue
					}
					fmt.printf("info string rootdebug order depth=%d idx=%d move=", current_depth, order_idx + 1)
					root_debug_print_move(order_move)
					fmt.printf(" root_seed=%v tt_move=%v capture=%v promoted=%d\n",
						same_move(order_move, root_tt_move),
						same_move(order_move, actual_root_tt_move),
						order_move.capture,
						order_move.promoted,
					)
				}
				os.flush(os.stdout)
			}

			best_score := -eval.INF
			current_best_move: moves.Move
			found_move := false

			root_pv_first_legal_counted := false
			initial_pass := run_root_search_pass(
				st,
				b,
				&move_list,
				current_depth,
				alpha,
				beta,
				root_tt_move,
				pv_index,
				&root_pv_first_legal_counted,
				debug_root_pass,
				"initial",
			)
			best_score = initial_pass.best_score
			current_best_move = initial_pass.best_move
			best_pv = initial_pass.best_pv
			found_move = initial_pass.found_move
			if !initial_pass.completed {
				depth_completed = false
			}

			// Re-search if outside aspiration window (first PV only)
			if depth_completed && current_depth >= 5 && pv_index == 0 {
				window_alpha := alpha
				window_beta := beta
				initial_best_score := best_score
				initial_best_move := current_best_move
				initial_pv := best_pv
				initial_found_move := found_move

				root_tt_failed_low := initial_pass.root_tt_seen && initial_pass.root_tt_score <= window_alpha && best_score < window_beta
				guard_forced_fail_low := root_tt_failed_low && best_score > window_alpha
				if debug_root_pass {
					fmt.printf("info string rootdebug aspiration initial_best=")
					root_debug_print_move(current_best_move)
					fmt.printf(
						" initial_score=%d window_alpha=%d window_beta=%d root_seed_seen=%v root_seed_score=%d root_seed_failed_low=%v guard_forced_fail_low=%v\n",
						best_score,
						window_alpha,
						window_beta,
						initial_pass.root_tt_seen,
						initial_pass.root_tt_score,
						root_tt_failed_low,
						guard_forced_fail_low,
					)
				}
				if best_score <= alpha || root_tt_failed_low {
					aspiration_failures += 1
					aspiration_fail_low_count += 1
					stat_add(&search_stats.aspiration_fail_low)
					alpha = -eval.INF
					if debug_root_pass {
						fmt.printf("info string rootdebug aspiration action=fail_low_research alpha=%d beta=%d\n", alpha, beta)
					}
					research_pass := run_root_search_pass(
						st,
						b,
						&move_list,
						current_depth,
						alpha,
						beta,
						root_tt_move,
						pv_index,
						&root_pv_first_legal_counted,
						debug_root_pass,
						"fail_low_research",
					)
					if research_pass.completed {
						best_score = research_pass.best_score
						current_best_move = research_pass.best_move
						best_pv = research_pass.best_pv
						found_move = research_pass.found_move
					} else {
						depth_completed = false
					}

					run_clean_root_verify := fixed_depth_root_verify
					if depth_completed && !run_clean_root_verify && timed_root_verify_prepared {
						depth_elapsed_now := int(time.duration_milliseconds(time.since(depth_start)))
						verify_best_move_changes := best_move_changes
						if !moves.is_empty_move(prev_best_move) &&
						   !moves.is_empty_move(current_best_move) &&
						   !same_move(current_best_move, prev_best_move) {
							verify_best_move_changes += 1
						}

						verify_score_drop := largest_score_drop
						if have_completed_score {
							current_score_for_budget := best_score + params.contempt
							score_drop := previous_completed_score - current_score_for_budget
							if score_drop > verify_score_drop {
								verify_score_drop = score_drop
							}
						}

						run_clean_root_verify = !should_start_next_depth(
							search_limits,
							depth_elapsed_now,
							last_depth_ms,
							verify_best_move_changes,
							verify_score_drop,
							aspiration_failures,
						)
						if timed_root_capture_verify_prepared {
							run_clean_root_verify = true
						}
					}

					if depth_completed && verify_from_clean_root && run_clean_root_verify {
						stat_add(&search_stats.aspiration_verifies)
						if debug_root_pass {
							fmt.printf("info string rootdebug verify action=clean_root start current_best=")
							root_debug_print_move(current_best_move)
							fmt.printf(" current_score=%d\n", best_score)
						}

						verify_pass: RootSearchPassResult
						timed_limited_root_verify := timed_root_verify_prepared && !fixed_depth_root_verify
						if timed_limited_root_verify {
							extend_timed_root_verify_budget(&search_limits)
						}
						if current_depth >= ROOT_VERIFY_SUSPECT_MIN_DEPTH {
							base_verify_candidates: RootVerifyCandidateSet
							verify_candidates: RootVerifyCandidateSet
							prepare_root_verify_candidate_set(
								&base_verify_candidates,
								&verify_st,
								b,
								&move_list,
								root_tt_move,
								false,
								current_best_move,
								actual_root_tt_move,
							)
							suspect_quiets: RootVerifySuspectResult
							if !timed_root_capture_verify_prepared {
								suspect_quiets = collect_root_verify_suspect_quiets(
									&verify_st,
									b,
									&move_list,
									current_depth,
									&research_pass,
									verify_tt_snapshot,
									&base_verify_candidates,
									timed_limited_root_verify,
								)
							}
							st.nodes += suspect_quiets.nodes
							if debug_root_pass && suspect_quiets.count > 0 {
								fmt.printf("info string rootdebug verify suspect_quiets count=%d nodes=%d moves=", suspect_quiets.count, suspect_quiets.nodes)
								for suspect_idx in 0 ..< suspect_quiets.count {
									root_debug_print_move(suspect_quiets.moves[suspect_idx])
									if suspect_idx + 1 < suspect_quiets.count {
										fmt.printf(",")
									}
								}
								fmt.println()
							}
							if should_stop_search() {
								depth_completed = false
							}
							prepare_root_verify_candidate_set(
								&verify_candidates,
								&verify_st,
								b,
								&move_list,
								root_tt_move,
								false,
								current_best_move,
								actual_root_tt_move,
								suspect_quiets.moves[0],
								suspect_quiets.moves[1],
								suspect_quiets.moves[2],
								suspect_quiets.moves[3],
							)
							if timed_limited_root_verify {
								if timed_root_capture_verify_prepared {
									// This trigger is budgeted for quiet recovery only:
									// compare the carried baseline against a tiny
									// high-history quiet set and skip general suspects.
									for verify_idx in 0 ..< verify_candidates.count {
										verify_candidates.include[verify_idx] = false
										verify_candidates.reason[verify_idx] = "timed_capture_verify_budget"
										verify_candidates.priority[verify_idx] = ROOT_VERIFY_PRIORITY_SKIP
									}
									restore_timed_positive_history_quiets(
										&verify_candidates,
										&verify_st,
										&move_list,
										ROOT_VERIFY_TIMED_POSITIVE_QUIET_LIMIT,
									)
								} else {
									limit_timed_root_verify_candidate_set(&verify_candidates, timed_mixed_root_verify_prepared)
								}
							}
							if depth_completed {
								if timed_limited_root_verify && !timed_mixed_root_verify_prepared {
									verify_pass = run_root_snapshot_verification_pass(
										&verify_st,
										b,
										&move_list,
										current_depth,
										root_tt_move,
										pv_index,
										&root_pv_first_legal_counted,
										verify_tt_snapshot,
										&verify_candidates,
										debug_root_pass,
										"clean_root_verify",
										current_best_move,
										best_score,
										best_pv,
									)
								} else {
									verify_pass = run_root_snapshot_verification_pass(
										&verify_st,
										b,
										&move_list,
										current_depth,
										root_tt_move,
										pv_index,
										&root_pv_first_legal_counted,
										verify_tt_snapshot,
										&verify_candidates,
										debug_root_pass,
										"clean_root_verify",
									)
								}
							}
						} else {
							restore_tt(verify_tt_snapshot)
							verify_pass = run_root_full_window_verification_pass(
								&verify_st,
								b,
								&move_list,
								current_depth,
								root_tt_move,
								pv_index,
								&root_pv_first_legal_counted,
								debug_root_pass,
								"clean_root_verify",
								false,
								current_best_move,
								actual_root_tt_move,
							)
						}
						st.nodes += verify_st.nodes
						if verify_pass.completed && verify_pass.found_move {
							best_score = verify_pass.best_score
							current_best_move = verify_pass.best_move
							best_pv = verify_pass.best_pv
							found_move = verify_pass.found_move
						} else if fixed_depth_root_verify || timed_root_verify_prepared {
							depth_completed = false
						}
					}

					if depth_completed && guard_forced_fail_low && best_score >= beta {
						aspiration_failures += 1
						aspiration_fail_high_count += 1
						stat_add(&search_stats.aspiration_fail_high)
						stat_add(&search_stats.aspiration_retries)
						alpha = window_alpha
						beta = eval.INF
						if debug_root_pass {
							fmt.printf("info string rootdebug aspiration action=fail_low_beta_retry alpha=%d beta=%d\n", alpha, beta)
						}
						retry_pass := run_root_search_pass(
							st,
							b,
							&move_list,
							current_depth,
							alpha,
							beta,
							root_tt_move,
							pv_index,
							&root_pv_first_legal_counted,
							debug_root_pass,
							"fail_low_beta_retry",
						)
						if retry_pass.completed {
							best_score = retry_pass.best_score
							current_best_move = retry_pass.best_move
							best_pv = retry_pass.best_pv
							found_move = retry_pass.found_move
						} else {
							depth_completed = false
						}
					}
				} else if best_score >= beta {
					aspiration_failures += 1
					aspiration_fail_high_count += 1
					stat_add(&search_stats.aspiration_fail_high)
					beta = eval.INF
					if debug_root_pass {
						fmt.printf("info string rootdebug aspiration action=fail_high_research alpha=%d beta=%d\n", alpha, beta)
					}
					research_pass := run_root_search_pass(
						st,
						b,
						&move_list,
						current_depth,
						alpha,
						beta,
						root_tt_move,
						pv_index,
						&root_pv_first_legal_counted,
						debug_root_pass,
						"fail_high_research",
					)
					if research_pass.completed {
						best_score = research_pass.best_score
						current_best_move = research_pass.best_move
						best_pv = research_pass.best_pv
						found_move = research_pass.found_move
					} else {
						depth_completed = false
					}

					fail_high_root_seed_clamped :=
						fixed_depth_fail_high_verify &&
						verify_from_clean_root &&
						depth_completed &&
						!moves.is_empty_move(root_tt_move) &&
						(root_tt_move.capture || root_tt_move.promoted != -1) &&
						same_move(current_best_move, root_tt_move) &&
						best_score <= window_alpha
					if fail_high_root_seed_clamped {
						stat_add(&search_stats.aspiration_verifies)
						if debug_root_pass {
							fmt.printf("info string rootdebug verify action=fail_high_clean_root start current_best=")
							root_debug_print_move(current_best_move)
							fmt.printf(" current_score=%d window_alpha=%d\n", best_score, window_alpha)
						}

						verify_pass: RootSearchPassResult
						if current_depth >= ROOT_VERIFY_SUSPECT_MIN_DEPTH {
							verify_candidates: RootVerifyCandidateSet
							prepare_root_verify_candidate_set(
								&verify_candidates,
								&verify_st,
								b,
								&move_list,
								root_tt_move,
								false,
								current_best_move,
								actual_root_tt_move,
							)
							verify_pass = run_root_snapshot_verification_pass(
								&verify_st,
								b,
								&move_list,
								current_depth,
								root_tt_move,
								pv_index,
								&root_pv_first_legal_counted,
								verify_tt_snapshot,
								&verify_candidates,
								debug_root_pass,
								"fail_high_clean_root",
							)
						} else {
							restore_tt(verify_tt_snapshot)
							verify_pass = run_root_full_window_verification_pass(
								&verify_st,
								b,
								&move_list,
								current_depth,
								root_tt_move,
								pv_index,
								&root_pv_first_legal_counted,
								debug_root_pass,
								"fail_high_clean_root",
								false,
								current_best_move,
								actual_root_tt_move,
							)
						}
						st.nodes += verify_st.nodes
						if verify_pass.completed && verify_pass.found_move {
							best_score = verify_pass.best_score
							current_best_move = verify_pass.best_move
							best_pv = verify_pass.best_pv
							found_move = verify_pass.found_move
						} else {
							depth_completed = false
						}
					}
				}

				// If search was stopped during re-search, restore initial results
				if !depth_completed || should_stop_search() {
					best_score = initial_best_score
					current_best_move = initial_best_move
					best_pv = initial_pv
					found_move = initial_found_move
				}
			}

			if found_move {
				// Apply contempt from the engine's perspective at the root
				// (score is always from the side-to-move's perspective at root)
				contempt_score := best_score + params.contempt

				// Store this PV result
				result: MultiPV_Result
				result.move = current_best_move
				result.score = contempt_score
				result.pv = best_pv
				append(&multi_pv_results, result)

				// Add to excluded list for next PV
				append(&excluded_moves, current_best_move)

				// Update prev_score from first PV
				if pv_index == 0 {
					prev_score = contempt_score
					best_move = current_best_move
				}

				if debug_root_pass {
					fmt.printf("info string rootdebug final depth=%d best=", current_depth)
					root_debug_print_move(current_best_move)
					fmt.printf(" raw_score=%d contempt_score=%d pv=", best_score, contempt_score)
					for pv_i in 0 ..< best_pv.count {
						board.print_move(best_pv.moves[pv_i])
						if pv_i < best_pv.count - 1 {
							fmt.printf(" ")
						}
					}
					fmt.println()
					os.flush(os.stdout)
				}
			}

			if verify_from_clean_root {
				if verify_st.continuation_history != nil {
					free(verify_st.continuation_history)
				}
				delete(verify_tt_snapshot)
			}
		}

		// Flush local nodes to global counter for accurate reporting
		sync.atomic_add(&total_nodes, st.nodes % 1024)
		st.nodes = 0

		// Print all PV lines for this depth
		os.flush(os.stdout)
		duration := time.since(start_time)
		ms := time.duration_milliseconds(duration)
		depth_elapsed := int(time.duration_milliseconds(time.since(depth_start)))
		previous_depth_ms = last_depth_ms
		last_depth_ms = depth_elapsed
		last_completed_pv_len := 0
		last_completed_pv_tb_terminal := false
		os.flush(os.stdout)

		nps := u64(0)
		ms_int := int(ms) // Convert to int for output
		if ms_int > 0 {
			nps = get_total_nodes() * 1000 / u64(ms_int)
		}

		// Only output info lines and update best_move if depth completed (not aborted by timeout)
		if !depth_completed {
			// Depth aborted: restore best_move from previous completed depth, stop search
			best_move = prev_completed_best_move
			break
		}

		if len(multi_pv_results) > 0 {
			current_score := multi_pv_results[0].score
			last_completed_pv_len = multi_pv_results[0].pv.count
			last_completed_pv_tb_terminal = multi_pv_results[0].pv.tb_terminal
			if have_completed_score {
				score_drop := previous_completed_score - current_score
				if score_drop > largest_score_drop {
					largest_score_drop = score_drop
				}
			}
			previous_completed_score = current_score
			have_completed_score = true
			if st.thread_id == 0 {
				last_completed_best_move = best_move
				last_completed_best_score = current_score
				last_completed_depth = current_depth
			}
		}

		if output_bestmove {
			// Output each PV line
			for pv_idx in 0 ..< len(multi_pv_results) {
				result := &multi_pv_results[pv_idx]
				uci_score := eval.score_to_uci_cp(result.score, b)

				if multi_pv_count > 1 {
					// MultiPV format
					fmt.printf(
						"info depth %d multipv %d score cp %d nodes %d time %d nps %d pv ",
						current_depth,
						pv_idx + 1,
						uci_score,
						get_total_nodes(),
						ms_int,
						nps,
					)
				} else {
					// Standard format
					fmt.printf(
						"info depth %d score cp %d nodes %d time %d nps %d pv ",
						current_depth,
						uci_score,
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

		previous_completed_pv_len = last_completed_pv_len

		// Check for stop signal (from ponder stop or user interrupt)
		if should_stop_search() {
			break // Exit immediately if stop requested
		}

		// If ponderhit was triggered during pondering, enable time management
		if sync.atomic_load(&search_control.ponderhit_triggered) != 0 {
			use_time_management = true
			sync.atomic_store(&search_control.ponder_mode, i32(0))
		}

		if use_time_management && !search_limits.is_movetime && !moves.is_empty_move(best_move) {
			if !moves.is_empty_move(prev_best_move) &&
			   (best_move.source != prev_best_move.source ||
			    best_move.target != prev_best_move.target ||
			    best_move.promoted != prev_best_move.promoted) {
				best_move_changes += 1
			}
			prev_best_move = best_move

			// A depth can become unstable after it completes, even if it was
			// not close enough to the budget to prepare root verification at
			// depth start. Only extend at this boundary when the completed PV
			// is suspiciously short; normal-length PVs were stable in collapse
			// tests and should not spend extra blitz time just because the
			// projected next depth is expensive.
			if last_completed_pv_len <= 2 && !last_completed_pv_tb_terminal &&
			   should_prepare_timed_root_verify(
				search_limits,
				last_depth_ms,
				previous_depth_ms,
				best_move_changes,
				largest_score_drop,
				aspiration_failures,
			) {
				extend_timed_root_verify_budget(&search_limits)
			}
		}

		// Check if we should stop iterative deepening
		// Skip time check if still in ponder mode (infinite search)
		is_pondering := sync.atomic_load(&search_control.ponder_mode)
		if is_pondering == 0 && use_time_management {
			if !should_start_next_depth(
				search_limits,
				last_depth_ms,
				previous_depth_ms,
				best_move_changes,
				largest_score_drop,
				aspiration_failures,
			) {
				break // Stop deepening, but the current depth was already completed
			}
		}
	}

	// Add remaining local nodes to global counter
	sync.atomic_add(&total_nodes, st.nodes % 1024)

	// Only output bestmove if requested (main thread only)
	if output_bestmove {
		if moves.is_empty_move(best_move) {
			fmt.printf("info string WARNING: best_move is zero, side=%d, regenerating fallback\n", b.side)
			// Fallback: regenerate legal moves and pick the first one
			fallback_list: moves.MoveList
			board.generate_all_moves(b, &fallback_list)
			for i in 0 ..< fallback_list.count {
				if !board.is_castling_legal_now(b, fallback_list.moves[i]) {
					continue
				}
				state: board.StateInfo
				board.make_move_fast(b, fallback_list.moves[i], &state)
				king_sq := board.get_king_square(b, 1 - b.side)
				if !board.is_square_attacked(b, king_sq, b.side) {
					best_move = fallback_list.moves[i]
					board.unmake_move(b, &state)
					break
				}
				board.unmake_move(b, &state)
			}
			if moves.is_empty_move(best_move) {
				fmt.printf("info string CRITICAL: no legal moves found!\n")
			}
		}
		print_search_stats()
		fmt.printf("bestmove ")
		board.print_move(best_move)
		fmt.printf("\n")
		os.flush(os.stdout)
	}
}
