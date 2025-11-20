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
calculate_time :: proc(tc: TimeControl, side: int) -> SearchLimits {
	my_time := side == 0 ? tc.wtime : tc.btime
	my_inc := side == 0 ? tc.winc : tc.binc

	// Simple formula:
	// If movestogo is known: time_per_move = (my_time / movestogo) + increment
	// If sudden death: time_per_move = (my_time / 40) + increment

	moves_remaining := tc.movestogo > 0 ? tc.movestogo : 40

	// Calculate optimal time (what we aim to use)
	optimal := (my_time / moves_remaining) + my_inc

	// Calculate hard limit (never exceed this)
	// Don't use more than 3x optimal or half remaining time
	max_3x := optimal * 3
	max_half := my_time / 2
	max := max_3x < max_half ? max_3x : max_half

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
