package main

import "../board"
import "../moves"
import "../nnue"
import "core:fmt"
import "core:os"
import "core:time"

// Benchmark NNUE performance to measure SIMD speedup
main :: proc() {
	fmt.println("=== Mantis NNUE Performance Benchmark ===\n")

	// Print working directory for debugging
	cwd := os.get_current_directory()
	fmt.printf("Working directory: %s\n", cwd)

	// Initialize magic bitboards
	fmt.println("Initializing Magic Bitboards...")
	moves.init_sliders()
	fmt.println("Magic Bitboards Initialized.\n")

	// Try to load NNUE network - try different paths
	fmt.println("Loading NNUE network...")
	network_loaded := false

	paths_to_try := []string {
		"nn-c0ae49f08b40.nnue",
		"../nn-c0ae49f08b40.nnue",
		"../../nn-c0ae49f08b40.nnue",
	}

	for path in paths_to_try {
		fmt.printf("Trying: %s ... ", path)
		if nnue.init_nnue(path) {
			fmt.println("SUCCESS!")
			network_loaded = true
			break
		} else {
			fmt.println("failed")
		}
	}

	if !network_loaded {
		fmt.println("\nFailed to load network from any path!")
		fmt.println("Please ensure nn-c0ae49f08b40.nnue is in the Mantis root directory")
		return
	}

	fmt.println("Network loaded successfully.\n")

	// Run benchmarks
	benchmark_evaluation()

	fmt.println("\n=== Benchmark Complete ===")
}

//Benchmark: Full Evaluation (simplified for now)
benchmark_evaluation :: proc() {
	fmt.println("--- Benchmark: Full Evaluation ---")

	positions := [?]string {
		"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
		"r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
		"rnbqkb1r/pp2pppp/3p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 0 5",
	}

	boards: [3]board.Board
	for fen, i in positions {
		boards[i] = board.parse_fen(fen)
	}

	iterations := 100000
	start := time.now()

	for _ in 0 ..< iterations {
		for &b in boards {
			_ = nnue.evaluate(&b)
		}
	}

	elapsed := time.since(start)
	total_evals := iterations * len(positions)
	evals_per_sec := f64(total_evals) / time.duration_seconds(elapsed)

	fmt.printf("Iterations: %d\n", iterations)
	fmt.printf("Positions: %d\n", len(positions))
	fmt.printf("Total evaluations: %d\n", total_evals)
	fmt.printf("Time: %v\n", elapsed)
	fmt.printf("Evaluations/sec: %.0f\n", evals_per_sec)
	fmt.printf(
		"Avg time per eval: %.2f µs\n\n",
		time.duration_microseconds(elapsed) / f64(total_evals),
	)
}
