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
	capture_history:      [12][64]int,
	counter_moves:        [12][64]moves.Move,
	continuation_history: ^[6][64][6][64]int,
	static_eval_stack:    [MAX_PLY]int,
}

// Global atomic node counter for UCI reporting
total_nodes: u64 = 0

last_completed_best_move: moves.Move
last_completed_best_score: int
last_completed_depth: int

SearchDebugOptions :: struct {
	disable_tt_cutoffs: bool,
	disable_lmr:        bool,
	disable_futility:   bool,
	disable_lmp:        bool,
	disable_nmp:        bool,
	disable_rfp:        bool,
	disable_razor:      bool,
	disable_probcut:    bool,
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
}

search_stats_enabled: bool = false
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
		"info string stats search beta_cutoffs=%d quiet_beta=%d capture_beta=%d capture_hist_updates=%d capture_hist_maluses=%d cont_updates=%d cont_maluses=%d lmr=%d lmr_research=%d pvs_research=%d asp_low=%d asp_high=%d\n",
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
) -> int {
	board.generate_capture_moves(b, move_list)

	scores: [256]int
	has_duplicate_scores := false
	for i in 0 ..< move_list.count {
		see_score := see_capture(b, move_list.moves[i])
		q_see_scores[i] = see_score
		scores[i] = score_move(st, move_list.moves[i], b, moves.Move{}, 0, moves.Move{}, see_score)

		for j in 0 ..< i {
			if scores[j] == scores[i] {
				has_duplicate_scores = true
			}
		}
	}

	if has_duplicate_scores {
		// The full exchange sort is not stable: high-scoring quiets can
		// indirectly reorder equal-scored captures, so ties need fallback.
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

trace_root_legal_move :: proc(b: ^board.Board, move: moves.Move) -> bool {
	if !board.is_castling_legal_now(b, move) {
		return false
	}

	state: board.StateInfo
	board.make_move_fast(b, move, &state)
	king_sq := board.get_king_square(b, 1 - b.side)
	illegal := board.is_square_attacked(b, king_sq, b.side)
	board.unmake_move(b, &state)

	return !illegal
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

	// TT Probe
	if moves.is_empty_move(excluded_move) && !search_debug_options.disable_tt_cutoffs {
		tt_score, tt_hit := probe_tt(b.hash, alpha, beta, depth, ply)
		if tt_hit {
			stat_add(&search_stats.tt_cutoffs)
			return tt_score
		}
	}

	// Syzygy WDL Probe (during search, for exact endgame scores)
	if !is_pv && depth >= 1 {
		stat_add(&search_stats.tb_probes)
		tb_score, tb_hit := tb.probe_wdl(b)
		if tb_hit {
			stat_add(&search_stats.tb_hits)
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
			// Signal all threads to stop immediately
			sync.atomic_store(&search_control.should_stop, i32(1))
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
			return quiescence(st, b, alpha, beta, ply)
		}
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
	// If we have no hash move and this is a PV node, reduce depth
	// We don't know what's good here, so search shallower first
	if moves.is_empty_move(tt_move) && is_pv && effective_depth >= params.iir_min_depth {
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
		generated := order_qcaptures_from_capture_generator(st, b, &move_list, &q_see_scores)
		stat_add(&search_stats.movegen_calls)
		stat_add(&search_stats.moves_generated, u64(generated))
	}

	legal_moves := 0

	for i in 0 ..< move_list.count {
		// In quiescence, only search captures unless we are in check.
		// When in check, we must search all legal moves (including non-captures)
		// because the king must escape check.
		if !in_check && !move_list.moves[i].capture {
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
	if st.thread_id == 0 {
		last_completed_best_move = moves.Move{}
		last_completed_best_score = 0
		last_completed_depth = 0
	}
	sync.atomic_store(&total_nodes, 0)
	reset_search_stats()
	clear_killers(st) // Clear killer moves for new search
	clear_history(st) // Clear history table for new search
	clear_capture_history(st)
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

	// Dynamic time-management state
	prev_best_move: moves.Move
	previous_completed_score := 0
	have_completed_score := false
	best_move_changes := 0
	largest_score_drop := 0
	aspiration_failures := 0
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

			root_tt_move := moves.Move{}
			if pv_index == 0 {
				root_tt_move = best_move
				if moves.is_empty_move(root_tt_move) {
					root_tt_move = prev_completed_best_move
				}
			}

			// Sort root moves, preserving the previous completed PV move first.
			sort_moves(st, &move_list, b, root_tt_move, 0, moves.Move{})
			if !moves.is_empty_move(root_tt_move) && move_list.count > 0 && same_move(move_list.moves[0], root_tt_move) {
				stat_add(&search_stats.root_pv_first)
			}

			best_score := -eval.INF
			current_best_move: moves.Move
			found_move := false

			current_alpha := alpha
			root_pv_first_legal_counted := false

			for i in 0 ..< move_list.count {
				// Abort root move loop if search was stopped (time limit or external stop)
				if should_stop_search() {
					depth_completed = false
					break
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
				if !root_pv_first_legal_counted && i == 0 && same_move(move_list.moves[i], root_tt_move) {
					stat_add(&search_stats.root_pv_first_legal)
					root_pv_first_legal_counted = true
				}

				nnue.update_accumulators(&state, b, move_list.moves[i])

				child_pv: PV_Line
				score := -negamax(
					st,
					b,
					-beta,
					-current_alpha,
					current_depth - 1,
					1,
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
				initial_best_score := best_score
				initial_best_move := current_best_move
				initial_pv := best_pv

				if best_score <= alpha {
					aspiration_failures += 1
					stat_add(&search_stats.aspiration_fail_low)
					// Failed low - re-search with lower bound
					alpha = -eval.INF
					best_score = -eval.INF
					current_alpha = alpha

					for i in 0 ..< move_list.count {
						if should_stop_search() {
							depth_completed = false
							break
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
						if !root_pv_first_legal_counted && i == 0 && same_move(move_list.moves[i], root_tt_move) {
							stat_add(&search_stats.root_pv_first_legal)
							root_pv_first_legal_counted = true
						}

						nnue.update_accumulators(&state, b, move_list.moves[i])
						child_pv: PV_Line
						score := -negamax(
							st,
							b,
							-beta,
							-current_alpha,
							current_depth - 1,
							1,
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
					aspiration_failures += 1
					stat_add(&search_stats.aspiration_fail_high)
					// Failed high - re-search with upper bound
					beta = eval.INF
					best_score = -eval.INF
					current_alpha = alpha

					for i in 0 ..< move_list.count {
						if should_stop_search() {
							depth_completed = false
							break
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
						if !root_pv_first_legal_counted && i == 0 && same_move(move_list.moves[i], root_tt_move) {
							stat_add(&search_stats.root_pv_first_legal)
							root_pv_first_legal_counted = true
						}

						nnue.update_accumulators(&state, b, move_list.moves[i])
						child_pv: PV_Line
						score := -negamax(
							st,
							b,
							-beta,
							-current_alpha,
							current_depth - 1,
							1,
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

				// If search was stopped during re-search, restore initial results
				if should_stop_search() {
					best_score = initial_best_score
					current_best_move = initial_best_move
					best_pv = initial_pv
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

		if use_time_management && !search_limits.is_movetime && !moves.is_empty_move(best_move) {
			if !moves.is_empty_move(prev_best_move) &&
			   (best_move.source != prev_best_move.source ||
			    best_move.target != prev_best_move.target ||
			    best_move.promoted != prev_best_move.promoted) {
				best_move_changes += 1
			}
			prev_best_move = best_move
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
