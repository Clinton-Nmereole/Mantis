package search

import "core:time"

TimeControl :: struct {
	wtime:     int, // White time remaining (ms)
	btime:     int, // Black time remaining (ms)
	winc:      int, // White increment (ms)
	binc:      int, // Black increment (ms)
	movestogo: int, // Moves to next time control (0 = sudden death)
	movetime:  int, // Exact time per move (ms), overrides normal calculation
	infinite:  bool, // Search until "stop" command
}

SearchLimits :: struct {
	soft_time:    int, // Target budget (ms)
	hard_time:    int, // Absolute abort limit (ms)
	max_time:     int, // Backward-compatible alias for hard_time
	optimal_time: int, // Backward-compatible alias for soft_time
	base_hard_time: int, // Initial hard limit before instability extensions
	root_fullmove_number: int, // Root fullmove, filled in by search_position
	clock_time: int, // Side-to-move clock at root, for short-clock extension caps
	start_time:   time.Time,
	is_movetime:  bool, // True for go movetime N (no dynamic scaling)
	is_infinite:  bool,
}

// Global search limits
search_limits: SearchLimits
use_time_management := false

// Search scores are Stockfish-style internal values when SFNNv14 is active.
// These thresholds approximate 35/75/150 UCI cp score drops near normal material.
SCORE_DROP_SMALL :: 140
SCORE_DROP_MEDIUM :: 300
SCORE_DROP_LARGE :: 600

// Calculate time allocation for this move.
// Heavily influenced by how modern engines (Stockfish, Ethereal, etc.)
// allocate time for blitz/rapid/classical.
calculate_time :: proc(tc: TimeControl, side: int, overhead: int = 10) -> SearchLimits {
	// movetime overrides everything
	if tc.movetime > 0 {
		// UCI movetime is an exact per-move budget. Move overhead is for
		// clock-managed searches, where we must reserve time to return a move.
		mt := tc.movetime
		if mt < 1 { mt = 1 }
		return SearchLimits{
			soft_time    = mt,
			hard_time    = mt,
			max_time     = mt,
			optimal_time = mt,
			base_hard_time = mt,
			start_time   = time.now(),
			is_movetime  = true,
		}
	}

	// infinite search
	if tc.infinite {
		return SearchLimits{
			soft_time    = 999_999_999,
			hard_time    = 999_999_999,
			max_time     = 999_999_999,
			optimal_time = 999_999_999,
			base_hard_time = 999_999_999,
			start_time   = time.now(),
			is_infinite  = true,
		}
	}

	my_time := side == 0 ? tc.wtime : tc.btime
	my_inc  := side == 0 ? tc.winc  : tc.binc

	available := my_time - overhead
	if available < 1 { available = 1 }

	mtg := tc.movestogo

	// Tournament time control with moves-to-go
	if mtg > 0 {
		base := available / mtg
		// Use most of the increment every move
		optimal := base + my_inc * 3 / 4
		// Hard limit: time / 3 or 3x optimal, whichever is smaller
		max_limit := available / 3
		if max_limit > optimal * 3 { max_limit = optimal * 3 }
		if max_limit > available / 2 { max_limit = available / 2 }
		return SearchLimits{
			soft_time    = optimal,
			hard_time    = max_limit,
			max_time     = max_limit,
			optimal_time = optimal,
			base_hard_time = max_limit,
			clock_time   = my_time,
			start_time   = time.now(),
		}
	}

	if my_time < 500 && my_inc <= 50 {
		base := available / 80
		inc_bonus := my_inc
		optimal := base + inc_bonus
		if optimal < 1 {
			optimal = 1
		}

		max_limit := optimal * 12 / 10
		if max_limit < optimal {
			max_limit = optimal
		}
		cap := available / 5
		if cap < 1 {
			cap = 1
		}
		if max_limit > cap {
			max_limit = cap
		}

		return SearchLimits{
			soft_time    = optimal,
			hard_time    = max_limit,
			max_time     = max_limit,
			optimal_time = optimal,
			base_hard_time = max_limit,
			clock_time   = my_time,
			start_time   = time.now(),
		}
	}

	// Sudden death / blitz / rapid
	// Estimate moves-to-horizon based on remaining time.
	// Higher values = more conservative time usage (spread thinner).
	moves_to_horizon: int
	switch {
	case my_time >= 300_000: moves_to_horizon = 50 // >= 5 min
	case my_time >= 120_000: moves_to_horizon = 45 // >= 2 min
	case my_time >= 60_000:  moves_to_horizon = 40 // >= 1 min
	case my_time >= 30_000:  moves_to_horizon = 35 // >= 30 s
	case my_time >= 10_000:  moves_to_horizon = 30 // >= 10 s
	case my_time >= 5_000:   moves_to_horizon = 25 // >= 5 s
	case:                    moves_to_horizon = 15 // < 5 s
	}

	base := available / moves_to_horizon

	// Increment bonus: use more in blitz, less in classical
	inc_bonus: int
	if my_inc > 0 {
		if my_time < 60_000 {
			// Blitz / rapid: use 70 % of increment
			inc_bonus = my_inc * 7 / 10
		} else {
			// Classical: use 60 % of increment
			inc_bonus = my_inc * 3 / 5
		}
	}

	optimal := base + inc_bonus

	// Minimum thinking time
	if optimal < 30 && my_time > 500 {
		optimal = 30
	}

	// Hard limit depends on time pressure
	max_limit: int
	if my_time < 5_000 {
		// Time scramble: very conservative
		max_limit = optimal * 15 / 10 // 1.5x
		if max_limit > available / 5 { max_limit = available / 5 }
	} else if my_time < 20_000 {
		// Moderate pressure
		max_limit = optimal * 2 // 2.0x
		if max_limit > available / 5 { max_limit = available / 5 }
	} else {
		// Normal: up to 2x optimal, but never more than 1/5 of clock
		max_limit = optimal * 2
		if max_limit > available / 5 { max_limit = available / 5 }
	}

	return SearchLimits{
		soft_time    = optimal,
		hard_time    = max_limit,
		max_time     = max_limit,
		optimal_time = optimal,
		base_hard_time = max_limit,
		clock_time   = my_time,
		start_time   = time.now(),
	}
}

short_clock_extension_cap :: proc(limits: ^SearchLimits, requested_cap: int) -> int {
	if limits.is_movetime || limits.is_infinite {
		return requested_cap
	}
	if limits.base_hard_time <= 0 || limits.root_fullmove_number <= 0 {
		return requested_cap
	}
	if limits.root_fullmove_number > 2 || limits.base_hard_time > 160 {
		return requested_cap
	}

	cap := limits.base_hard_time * 3 / 2
	min_cap := limits.base_hard_time + 20
	if cap < min_cap {
		cap = min_cap
	}
	if cap > 160 {
		cap = 160
	}
	if requested_cap < cap {
		return requested_cap
	}
	return cap
}

short_clock_opening_extension_cap :: proc(limits: ^SearchLimits, requested_cap: int) -> int {
	if limits.is_movetime || limits.is_infinite {
		return requested_cap
	}
	if limits.clock_time > 800 || limits.base_hard_time <= 0 {
		return requested_cap
	}

	cap := limits.base_hard_time * 3 / 2
	min_cap := limits.base_hard_time + 20
	if cap < min_cap {
		cap = min_cap
	}
	if cap > 160 {
		cap = 160
	}
	if requested_cap < cap {
		return requested_cap
	}
	return cap
}

raise_soft_time :: proc(limits: ^SearchLimits, target: int) {
	adjusted := target
	cap := short_clock_extension_cap(limits, target)
	if adjusted > cap {
		adjusted = cap
	}
	if limits.soft_time < adjusted {
		limits.soft_time = adjusted
		limits.optimal_time = adjusted
	}
}

raise_hard_time :: proc(limits: ^SearchLimits, target: int) {
	adjusted := target
	cap := short_clock_extension_cap(limits, target)
	if adjusted > cap {
		adjusted = cap
	}
	if adjusted > limits.hard_time {
		limits.hard_time = adjusted
		limits.max_time = adjusted
	}
}

// Return elapsed milliseconds since search started
elapsed_ms :: proc(limits: SearchLimits) -> int {
	return int(time.duration_milliseconds(time.since(limits.start_time)))
}

// Check if we should stop searching (hard limit)
should_stop :: proc(limits: SearchLimits) -> bool {
	if limits.is_infinite { return false }
	return elapsed_ms(limits) >= limits.hard_time
}

// Check if we've exceeded the base soft budget.
exceeded_optimal :: proc(limits: SearchLimits) -> bool {
	return elapsed_ms(limits) >= limits.soft_time
}

time_budget_with_instability :: proc(
	limits: SearchLimits,
	best_move_changes: int,
	score_drop: int,
	aspiration_failures: int,
) -> int {
	if limits.is_movetime || limits.is_infinite {
		return limits.hard_time
	}

	budget := limits.soft_time

	// Spend extra time when the search is unstable, but never beyond hard_time.
	budget += limits.soft_time * best_move_changes / 4
	budget += limits.soft_time * aspiration_failures / 3

	if score_drop >= SCORE_DROP_LARGE {
		budget += limits.soft_time
	} else if score_drop >= SCORE_DROP_MEDIUM {
		budget += limits.soft_time / 2
	} else if score_drop >= SCORE_DROP_SMALL {
		budget += limits.soft_time / 4
	}

	if budget > limits.hard_time { budget = limits.hard_time }
	if budget < 1 { budget = 1 }
	return budget
}

project_next_depth_time :: proc(last_depth_ms: int, previous_depth_ms: int) -> int {
	if last_depth_ms <= 0 { return 1 }
	if previous_depth_ms <= 0 {
		return last_depth_ms * 3
	}

	growth := f64(last_depth_ms) / f64(previous_depth_ms)
	if growth < 1.5 { growth = 1.5 }
	if growth > 6.0 { growth = 6.0 }

	projected := int(f64(last_depth_ms) * growth)
	if projected < last_depth_ms + 1 { projected = last_depth_ms + 1 }
	return projected
}

should_start_next_depth :: proc(
	limits: SearchLimits,
	last_depth_ms: int,
	previous_depth_ms: int,
	best_move_changes: int,
	score_drop: int,
	aspiration_failures: int,
) -> bool {
	if limits.is_infinite { return true }
	if limits.is_movetime {
		return limits.hard_time - elapsed_ms(limits) > 5
	}

	budget := time_budget_with_instability(limits, best_move_changes, score_drop, aspiration_failures)
	projected := project_next_depth_time(last_depth_ms, previous_depth_ms)
	return elapsed_ms(limits) + projected < budget
}

should_prepare_timed_root_verify :: proc(
	limits: SearchLimits,
	last_depth_ms: int,
	previous_depth_ms: int,
	best_move_changes: int,
	score_drop: int,
	aspiration_failures: int,
) -> bool {
	if limits.is_infinite || limits.is_movetime {
		return false
	}

	elapsed := elapsed_ms(limits)
	budget := time_budget_with_instability(limits, best_move_changes, score_drop, aspiration_failures)
	projected := project_next_depth_time(last_depth_ms, previous_depth_ms)

	return elapsed + projected * 2 >= budget || elapsed >= limits.soft_time
}

extend_timed_root_verify_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}

	// Only extend when the original hard limit had room to be a normal
	// instability bound. If the hard limit was capped by time pressure,
	// preserve the cap.
	if limits.hard_time < limits.soft_time * 19 / 10 {
		return
	}

	extended := limits.hard_time + limits.soft_time
	cap := limits.soft_time * 3
	cap = short_clock_extension_cap(limits, cap)
	if extended > cap {
		extended = cap
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_pv_instability_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 120)

	extended := limits.soft_time * 3
	if extended > 240 {
		extended = 240
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_next_depth_margin_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}

	extended := limits.soft_time * 2
	if extended > 160 {
		extended = 160
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_opening_center_recovery_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, short_clock_opening_extension_cap(limits, 120))

	extended := limits.soft_time * 2
	if extended > 190 {
		extended = 190
	}
	extended = short_clock_opening_extension_cap(limits, extended)
	raise_hard_time(limits, extended)
}

extend_short_clock_rook_invasion_horizon_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 120)

	extended := limits.soft_time * 3
	if extended > 190 {
		extended = 190
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_tactical_horizon_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 120)

	extended := limits.soft_time * 4
	if extended > 320 {
		extended = 320
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_deep_tactical_horizon_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 160)

	extended := limits.soft_time * 4
	if extended > 640 {
		extended = 640
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_late_rook_endgame_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 400)

	extended := limits.soft_time * 4
	if extended > 1600 {
		extended = 1600
	}
	raise_hard_time(limits, extended)
}

extend_short_clock_two_rook_passed_pawn_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}

	raise_hard_time(limits, 220)
}

extend_short_clock_opening_center_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, short_clock_opening_extension_cap(limits, 220))

	extended := limits.soft_time * 2
	if extended > 360 {
		extended = 360
	}
	extended = short_clock_opening_extension_cap(limits, extended)
	raise_hard_time(limits, extended)
}

extend_short_clock_opening_development_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, short_clock_opening_extension_cap(limits, 520))

	extended := limits.soft_time * 2
	if extended > 640 {
		extended = 640
	}
	extended = short_clock_opening_extension_cap(limits, extended)
	raise_hard_time(limits, extended)
}

extend_low_material_stable_quiet_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 120)

	extended := limits.soft_time * 4
	if extended > 320 {
		extended = 320
	}
	raise_hard_time(limits, extended)
}

extend_low_material_passed_pawn_race_budget :: proc(limits: ^SearchLimits) {
	if limits.is_infinite || limits.is_movetime {
		return
	}
	if limits.soft_time <= 0 {
		return
	}
	raise_soft_time(limits, 120)

	extended := limits.soft_time * 6
	if extended > 440 {
		extended = 440
	}
	raise_hard_time(limits, extended)
}
