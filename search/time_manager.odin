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
	max_time:     int, // Hard abort limit (ms)
	optimal_time: int, // Target time (ms)
	start_time:   time.Time,
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
			max_time     = mt,
			optimal_time = mt,
			start_time   = time.now(),
		}
	}

	// infinite search
	if tc.infinite {
		return SearchLimits{
			max_time     = 999_999_999,
			optimal_time = 999_999_999,
			start_time   = time.now(),
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
	return elapsed_ms(limits) >= limits.max_time
}

// Check if we've exceeded the base optimal time.
// The caller scales optimal_time dynamically, so this is the
// *unscaled* baseline.  Use exceeded_scaled_optimal for the
// dynamically-adjusted target.
exceeded_optimal :: proc(limits: SearchLimits) -> bool {
	return elapsed_ms(limits) >= limits.optimal_time
}

// Check against a scaled optimal time (for dynamic scaling)
exceeded_scaled_optimal :: proc(limits: SearchLimits, factor: f64) -> bool {
	scaled := int(f64(limits.optimal_time) * factor)
	return elapsed_ms(limits) >= scaled
}
