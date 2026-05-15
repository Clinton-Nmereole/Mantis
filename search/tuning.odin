package search

import "core:fmt"
import "core:math"

// SearchParams holds all tunable search constants.
// Changing these values and recompiling allows automated tuning
// (SPSA, CLOP, manual testing) without editing source code.
SearchParams :: struct {
	// Aspiration Windows
	aspiration_window: int,

	// Null Move Pruning
	nmp_min_depth: int,
	nmp_reduction_base: int,
	nmp_reduction_div: int,

	// Reverse Futility Pruning
	rfp_depth: int,
	rfp_margin: int,

	// Probcut
	probcut_depth: int,
	probcut_margin: int,
	probcut_reduce: int,

	// Internal Iterative Reduction
	iir_min_depth: int,

	// Singular Extensions
	se_depth: int,
	se_margin: int,
	se_reduced_div: int,

	// Futility Pruning (near leaf)
	futility_margin: int,
	futility_max_depth: int,

	// Late Move Pruning
	lmp_base: int,
	lmp_div: int,
	lmp_max_depth: int,

	// Late Move Reductions
	lmr_min_depth: int,
	lmr_improving_adj: int,
	lmr_history_good_adj: int,
	lmr_history_bad_adj: int,
	lmr_history_good_thresh: int,
	lmr_history_bad_thresh: int,

	// Razoring
	razor_margin: int,
	razor_max_depth: int,

	// Quiescence
	delta_pruning_margin: int,
	see_prune_threshold: int,

	// History heuristic
	history_max: int,
	history_min: int,
	history_decay_numer: int,
	history_decay_denom: int,

	// Move ordering scores
	hash_move_score: int,
	counter_move_score: int,
	capture_base_score: int,
	killer1_score: int,
	killer2_score: int,

	// Check extension
	check_ext_max_ply: int,

	// Contempt ( discourages draws by biasing root eval)
	contempt: int,
}

// Global parameter set — initialized to defaults.
// The tuner modifies this struct in-place and recompiles.
params: SearchParams

// Initialize with sensible defaults (current hand-tuned values)
init_search_params :: proc() {
	params = SearchParams{
		aspiration_window      = 30,
		nmp_min_depth          = 3,
		nmp_reduction_base     = 1,
		nmp_reduction_div      = 6,
		rfp_depth              = 7,
		rfp_margin             = 72,
		probcut_depth          = 5,
		probcut_margin         = 100,
		probcut_reduce         = 4,
		iir_min_depth          = 4,
		se_depth               = 8,
		se_margin              = 2,
		se_reduced_div         = 2,
		futility_margin        = 250,
		futility_max_depth     = 3,
		lmp_base               = 2,
		lmp_div                = 2,
		lmp_max_depth          = 8,
		lmr_min_depth          = 3,
		lmr_improving_adj      = -1,
		lmr_history_good_adj   = -1,
		lmr_history_bad_adj    = 1,
		lmr_history_good_thresh= 2000,
		lmr_history_bad_thresh = -2000,
		razor_margin           = 300,
		razor_max_depth        = 3,
		delta_pruning_margin   = 900,
		see_prune_threshold    = -100,
		history_max            = 10000,
		history_min            = -10000,
		history_decay_numer    = 9,
		history_decay_denom    = 10,
		hash_move_score        = 20000,
		counter_move_score     = 15000,
		capture_base_score     = 10000,
		killer1_score          = 9000,
		killer2_score          = 8000,
		check_ext_max_ply      = 40,
		contempt               = 0,
	}
}

// ---------------------------------------------------------------------------
// SPSA Tuner
// ---------------------------------------------------------------------------

SPSA :: struct {
	best_params:  SearchParams,
	best_score:   f64,
	alpha:        f64, // learning-rate decay
	gamma:        f64, // perturbation decay
	a:            f64, // learning-rate scale
	c:            f64, // perturbation scale
	A:            f64, // stability constant
	iterations:   int,
}

// Number of scalar fields in SearchParams
NUM_PARAMS :: 35

// Flatten SearchParams into a float slice for SPSA
params_to_slice :: proc(p: ^SearchParams, out: []f64) {
	out[0]  = f64(p.aspiration_window)
	out[1]  = f64(p.nmp_min_depth)
	out[2]  = f64(p.nmp_reduction_base)
	out[3]  = f64(p.nmp_reduction_div)
	out[4]  = f64(p.rfp_depth)
	out[5]  = f64(p.rfp_margin)
	out[6]  = f64(p.probcut_depth)
	out[7]  = f64(p.probcut_margin)
	out[8]  = f64(p.probcut_reduce)
	out[9]  = f64(p.iir_min_depth)
	out[10] = f64(p.se_depth)
	out[11] = f64(p.se_margin)
	out[12] = f64(p.se_reduced_div)
	out[13] = f64(p.futility_margin)
	out[14] = f64(p.futility_max_depth)
	out[15] = f64(p.lmp_base)
	out[16] = f64(p.lmp_div)
	out[17] = f64(p.lmp_max_depth)
	out[18] = f64(p.lmr_min_depth)
	out[19] = f64(p.lmr_improving_adj)
	out[20] = f64(p.lmr_history_good_adj)
	out[21] = f64(p.lmr_history_bad_adj)
	out[22] = f64(p.lmr_history_good_thresh)
	out[23] = f64(p.lmr_history_bad_thresh)
	out[24] = f64(p.razor_margin)
	out[25] = f64(p.razor_max_depth)
	out[26] = f64(p.delta_pruning_margin)
	out[27] = f64(p.history_decay_numer)
	out[28] = f64(p.history_decay_denom)
	out[29] = f64(p.hash_move_score)
	out[30] = f64(p.counter_move_score)
	out[31] = f64(p.capture_base_score)
	out[32] = f64(p.killer1_score)
	out[33] = f64(p.killer2_score)
	out[34] = f64(p.contempt)
	// see_prune_threshold omitted — tends to be binary (skip/keep)
	// history_max/min omitted — prevent overflow only
	// check_ext_max_ply omitted — structural safety limit
}

// Unflatten float slice back into SearchParams
slice_to_params :: proc(slice: []f64, p: ^SearchParams) {
	p.aspiration_window       = int(slice[0])
	p.nmp_min_depth           = int(slice[1])
	p.nmp_reduction_base      = int(slice[2])
	p.nmp_reduction_div       = int(slice[3])
	p.rfp_depth               = int(slice[4])
	p.rfp_margin              = int(slice[5])
	p.probcut_depth           = int(slice[6])
	p.probcut_margin          = int(slice[7])
	p.probcut_reduce          = int(slice[8])
	p.iir_min_depth           = int(slice[9])
	p.se_depth                = int(slice[10])
	p.se_margin               = int(slice[11])
	p.se_reduced_div          = int(slice[12])
	p.futility_margin         = int(slice[13])
	p.futility_max_depth      = int(slice[14])
	p.lmp_base                = int(slice[15])
	p.lmp_div                 = int(slice[16])
	p.lmp_max_depth           = int(slice[17])
	p.lmr_min_depth           = int(slice[18])
	p.lmr_improving_adj       = int(slice[19])
	p.lmr_history_good_adj    = int(slice[20])
	p.lmr_history_bad_adj     = int(slice[21])
	p.lmr_history_good_thresh = int(slice[22])
	p.lmr_history_bad_thresh  = int(slice[23])
	p.razor_margin            = int(slice[24])
	p.razor_max_depth         = int(slice[25])
	p.delta_pruning_margin    = int(slice[26])
	p.history_decay_numer     = int(slice[27])
	p.history_decay_denom     = int(slice[28])
	p.hash_move_score         = int(slice[29])
	p.counter_move_score      = int(slice[30])
	p.capture_base_score      = int(slice[31])
	p.killer1_score           = int(slice[32])
	p.killer2_score           = int(slice[33])
	p.contempt                = int(slice[34])
}

// ---------------------------------------------------------------------------
// Coordinate-Descent (Simplified Tuner)
// ---------------------------------------------------------------------------
// Full SPSA requires thousands of games.  For a practical first pass we use
// coordinate descent: tweak one parameter at a time, keep the improvement.
// This is much faster and often finds 70-80 % of the Elo gain.
// ---------------------------------------------------------------------------

// eval_params is a user-supplied callback that returns a score for a given
// parameter set.  Higher = better.  Typical implementation plays 50-100
// self-play games and returns the win-rate.
EvalFn :: proc(p: ^SearchParams) -> f64

coordinate_descent :: proc(eval_fn: EvalFn, steps: int = 3, games_per_eval: int = 50) {
	best := params
	best_score := eval_fn(&best)

	fmt.printf("Starting coordinate descent.  Baseline score: %.4f\n", best_score)

	theta: [NUM_PARAMS]f64
	params_to_slice(&best, theta[:])

	// Step sizes relative to current value
	rel_steps := [NUM_PARAMS]f64{
		0.20, // aspiration_window
		0.33, // nmp_min_depth
		0.25, // nmp_reduction_base
		0.25, // nmp_reduction_div
		0.15, // rfp_depth
		0.20, // rfp_margin
		0.15, // probcut_depth
		0.20, // probcut_margin
		0.15, // probcut_reduce
		0.15, // iir_min_depth
		0.12, // se_depth
		0.25, // se_margin
		0.25, // se_reduced_div
		0.20, // futility_margin
		0.25, // futility_max_depth
		0.25, // lmp_base
		0.25, // lmp_div
		0.15, // lmp_max_depth
		0.15, // lmr_min_depth
		0.50, // lmr_improving_adj
		0.50, // lmr_history_good_adj
		0.50, // lmr_history_bad_adj
		0.20, // lmr_history_good_thresh
		0.20, // lmr_history_bad_thresh
		0.20, // razor_margin
		0.25, // razor_max_depth
		0.15, // delta_pruning_margin
		0.10, // history_decay_numer
		0.10, // history_decay_denom
		0.15, // hash_move_score
		0.15, // counter_move_score
		0.15, // capture_base_score
		0.15, // killer1_score
		0.15, // killer2_score
		0.25, // contempt
	}

	for step in 0 ..< steps {
		improved := false
		for i in 0 ..< NUM_PARAMS {
			base := theta[i]
			delta := base * rel_steps[i]
			if delta < 1 { delta = 1 }

			// Try +delta
			theta[i] = base + delta
			plus: SearchParams
			slice_to_params(theta[:], &plus)
			score_plus := eval_fn(&plus)

			// Try -delta
			theta[i] = base - delta
			minus: SearchParams
			slice_to_params(theta[:], &minus)
			score_minus := eval_fn(&minus)

			// Keep the best of the three
			if score_plus > best_score && score_plus >= score_minus {
				best_score = score_plus
				theta[i] = base + delta
				improved = true
				fmt.printf("  param[%d] +%.0f -> %.4f\n", i, delta, best_score)
			} else if score_minus > best_score {
				best_score = score_minus
				theta[i] = base - delta
				improved = true
				fmt.printf("  param[%d] -%.0f -> %.4f\n", i, delta, best_score)
			} else {
				theta[i] = base // revert
			}
		}

		if !improved {
			fmt.println("No improvement this round — converged.")
			break
		}
	}

	slice_to_params(theta[:], &params)
	fmt.println("Coordinate descent complete.  Final params applied.")
}
