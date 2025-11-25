package search

import "core:time"

TimeControl :: struct {
	wtime:     int, // White time remaining (ms)
	btime:     int, // Black time remaining (ms)
	winc:      int, // White increment (ms)
	binc:      int, // Black increment (ms)
	movestogo: int, // Moves to next time control (0 = sudden death)
}

SearchLimits :: struct {
	max_time:     int, // Hard limit (ms)
	optimal_time: int, // Target time (ms)
	start_time:   time.Time,
}

// Global search limits
search_limits: SearchLimits
use_time_management := false

// Calculate time allocation for this move
calculate_time :: proc(tc: TimeControl, side: int, overhead: int = 10) -> SearchLimits {
	my_time := side == 0 ? tc.wtime : tc.btime
	my_inc := side == 0 ? tc.winc : tc.binc

	// Conservative time management formula
	// Key principle: Always leave a time cushion to avoid flagging

	// Account for overhead first
	available_time := my_time - overhead
	if available_time < 1 {
		available_time = 1
	}

	// Determine moves to horizon based on time control
	moves_to_horizon := 50 // Default: assume 50 more moves

	if tc.movestogo > 0 {
		// Tournament time control with moves/time
		moves_to_horizon = tc.movestogo
	} else {
		// Sudden death - estimate remaining moves based on time
		if my_time >= 180000 { 	// >= 3 minutes
			moves_to_horizon = 50
		} else if my_time >= 60000 { 	// >= 1 minute
			moves_to_horizon = 40
		} else if my_time >= 30000 { 	// >= 30 seconds
			moves_to_horizon = 30
		} else if my_time >= 10000 { 	// >= 10 seconds
			moves_to_horizon = 20
		} else {
			moves_to_horizon = 15
		}
	}

	// Calculate base time allocation (conservative)
	// Use only a fraction of time/moves to maintain cushion
	base_time := available_time / moves_to_horizon

	// Only use a fraction of increment to build time bank
	// In blitz/rapid with increment, save some increment for later
	inc_fraction := my_inc
	if my_inc > 0 && my_time < 60000 { 	// In time pressure with increment
		inc_fraction = (my_inc * 2) / 3 // Use only 2/3 of increment
	}

	// Optimal time = conservative base + fraction of increment
	optimal := base_time + inc_fraction

	// Ensure minimum thinking time
	if optimal < 50 && my_time > 1000 {
		optimal = 50 // At least 50ms unless in severe time trouble
	}

	// Hard limit (absolute maximum)
	// Use at most 1/10 of remaining time or 5x optimal, whichever is smaller
	max_tenth := available_time / 10
	max_5x := optimal * 5
	max := max_tenth < max_5x ? max_tenth : max_5x

	// In extreme time pressure, be even more conservative
	if my_time < 5000 { 	// Less than 5 seconds
		max = optimal * 2 // Only allow 2x optimal in time scramble
	}

	// Safety: never exceed 1/3 of total time
	max_third := available_time / 3
	if max > max_third {
		max = max_third
	}

	return SearchLimits{max_time = max, optimal_time = optimal, start_time = time.now()}
}

// Check if we should stop searching (hard limit)
should_stop :: proc(limits: SearchLimits) -> bool {
	elapsed := time.duration_milliseconds(time.since(limits.start_time))
	return int(elapsed) >= limits.max_time
}

// Check if we've exceeded optimal time
exceeded_optimal :: proc(limits: SearchLimits) -> bool {
	elapsed := time.duration_milliseconds(time.since(limits.start_time))
	return int(elapsed) >= limits.optimal_time
}
