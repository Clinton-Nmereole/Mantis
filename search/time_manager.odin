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
	start_time:   time.Time,
	is_movetime:  bool, // True for go movetime N (no dynamic scaling)
	is_infinite:  bool,
}

// Global search limits
search_limits: SearchLimits
use_time_management := false

// Calculate time allocation for this move.
// Heavily influenced by how modern engines (Stockfish, Ethereal, etc.)
// allocate time for blitz/rapid/classical.
calculate_time :: proc(tc: TimeControl, side: int, overhead: int = 10) -> SearchLimits {
	// movetime overrides everything
	if tc.movetime > 0 {
		mt := tc.movetime - overhead
		if mt < 1 { mt = 1 }
		return SearchLimits{
			soft_time    = mt,
			hard_time    = mt,
			max_time     = mt,
			optimal_time = mt,
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
		start_time   = time.now(),
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

	if score_drop >= 150 {
		budget += limits.soft_time
	} else if score_drop >= 75 {
		budget += limits.soft_time / 2
	} else if score_drop >= 35 {
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
