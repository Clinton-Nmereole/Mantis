package uci

import "../board"
import "../book"
import "../constants"
import "../eval"
import "../moves"
import "../nnue"
import "../search"
import "../tb"
import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

// Get the directory containing the current executable.
// On Linux, reads /proc/self/exe symlink via raw syscall.
get_executable_dir :: proc() -> string {
	buf: [4096]u8
	ret, errno := linux.readlink("/proc/self/exe", buf[:])
	if errno != .NONE || ret <= 0 {
		return ""
	}
	exe_path := string(buf[:ret])
	last_slash := strings.last_index(exe_path, "/")
	if last_slash >= 0 {
		return strings.clone(exe_path[:last_slash])
	}
	return ""
}

// UCI Configuration
move_overhead: int = 10 // Default 10ms for network/GUI lag compensation
multi_pv: int = 1 // Number of principal variations to display (1-500)
ponder_enabled: bool = false // Whether pondering is allowed
thread_count: int = 1 // Number of search threads (1-512)
own_book: bool = false // Whether to use internal opening book
book_file: string = "2moves_v1.epd" // Path to opening book EPD file

// Ponder State - manages background pondering
Ponder_State :: struct {
	thread_handle: ^thread.Thread,
	is_active:     i32, // Using i32 for atomic operations
	board:         board.Board,
	time_control:  search.TimeControl,
	depth:         int,
}

ponder_state: Ponder_State

// UCI Main Loop
uci_loop :: proc() {
	reader: bufio.Reader
	buffer: [4096]byte
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	defer bufio.reader_destroy(&reader)

	game_board := board.parse_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

	// Initialize TT
	search.init_tt(64) // Default 64MB

	// Initialize thread pool
	search.init_thread_pool(thread_count)

	// Initialize LMR reduction table
	search.init_lmr_table()

	// Initialize tunable search parameters
	search.init_search_params()

	// Load Default NNUE — try SFNNv14 first, then fall back to legacy.
	// Try executable directory first (so cutechess / GUI launches work),
	// then fall back to current working directory.
	exe_dir := get_executable_dir()
	default_nnue := "nn-7bf13f9655c8.nnue"

	sfnnv14_loaded := false
	if exe_dir != "" {
		path := strings.concatenate([]string{exe_dir, "/", default_nnue})
		sfnnv14_loaded = nnue.init_sfnnv14(path)
		delete(path)
	}
	if !sfnnv14_loaded {
		sfnnv14_loaded = nnue.init_sfnnv14(default_nnue)
	}

	if sfnnv14_loaded {
		nnue.sfnnv14_active = true
		nnue.init_sfnnv14_features()
	} else {
		legacy_nnue := "nn-c0ae49f08b40.nnue"
		legacy_loaded := false
		if exe_dir != "" {
			path := strings.concatenate([]string{exe_dir, "/", legacy_nnue})
			legacy_loaded = nnue.init_nnue(path)
			delete(path)
		}
		if !legacy_loaded {
			legacy_loaded = nnue.init_nnue(legacy_nnue)
		}
		if !legacy_loaded {
			fmt.println("WARNING: No NNUE network loaded. Using HCE fallback.")
		}
	}

	for {
		line, err := bufio.reader_read_string(&reader, '\n')
		if err != nil {
			break
		}
		defer delete(line)

		command := strings.trim_space(line)
		if len(command) == 0 {continue}

		if command == "quit" {
			// Clean up ponder thread if active
			if sync.atomic_load(&ponder_state.is_active) != 0 {
				search.stop_search()
				thread.join(ponder_state.thread_handle)
				thread.destroy(ponder_state.thread_handle)
				sync.atomic_store(&ponder_state.is_active, i32(0))
			}
			break
		} else if command == "uci" {
			fmt.println("id name Mantis")
			fmt.println("id author")
			fmt.println("option name Hash type spin default 64 min 1 max 1024")
			fmt.println("option name EvalFile type string default nn-c0ae49f08b40.nnue")
			fmt.println("option name OwnBook type check default false")
			fmt.println("option name BookFile type string default 2moves_v1.epd")
			fmt.println("option name Move Overhead type spin default 10 min 0 max 5000")
			fmt.println("option name MultiPV type spin default 1 min 1 max 500")
			fmt.println("option name Ponder type check default false")
			fmt.println("option name SyzygyPath type string default <empty>")
			fmt.println("option name SyzygyProbeLimit type spin default 6 min 0 max 7")
			fmt.println("option name Threads type spin default 1 min 1 max 512")
			fmt.println("option name Contempt type spin default 24 min -100 max 100")
			fmt.println("option name SearchStats type check default false")
			fmt.println("option name RootDebugTrace type check default false")
			fmt.println("option name StagedMovePicker type check default false")
			fmt.println("uciok")
			os.flush(os.stdout)
		} else if command == "isready" {
			fmt.println("readyok")
			os.flush(os.stdout)
		} else if command == "ucinewgame" {
			search.clear_tt()
			game_board = board.init_board()
		} else if strings.has_prefix(command, "position") {
			parse_position(command, &game_board)
		} else if strings.has_prefix(command, "go") {
			parse_go(command, &game_board)
		} else if strings.has_prefix(command, "setoption") {
			parse_setoption(command)
		} else if command == "ponderhit" {
			// Opponent made the predicted move - convert ponder to normal search
			if sync.atomic_load(&ponder_state.is_active) != 0 {
				// Trigger ponderhit flag to apply time management
				sync.atomic_store(&search.search_control.ponderhit_triggered, i32(1))

				// Apply time control limits
				tc := ponder_state.time_control
				if tc.wtime > 0 || tc.btime > 0 {
					limits := search.calculate_time(tc, ponder_state.board.side, move_overhead)
					search.search_limits = limits
					search.use_time_management = true
				}

				// Wait for ponder thread to complete
				thread.join(ponder_state.thread_handle)
				thread.destroy(ponder_state.thread_handle)
				sync.atomic_store(&ponder_state.is_active, i32(0))
				search.use_time_management = false
			}
		} else if command == "d" {
			board.print_board(game_board)
			fmt.printf("FEN: %s\n", board.get_fen(game_board))
			os.flush(os.stdout)
		} else if command == "eval" {
			score := eval.evaluate(&game_board)
			fmt.printf("Static evaluation: %d (side to move perspective)\n", score)
			if nnue.sfnnv14_active {
				bucket, psqt, positional, total, nnz, sum, hash, psq_stm_count, psq_stm_hash, psq_nstm_count, psq_nstm_hash, threat_stm_count, threat_stm_sum, threat_stm_hash, threat_nstm_count, threat_nstm_sum, threat_nstm_hash := nnue.trace_sfnnv14(&game_board)
				fmt.printf(
					"SFNNv14 trace: bucket=%d psqt=%d positional=%d total=%d transformed_nnz=%d transformed_sum=%d transformed_hash=%x psq_stm_count=%d psq_stm_hash=%x psq_nstm_count=%d psq_nstm_hash=%x threat_stm_count=%d threat_stm_sum=%d threat_stm_hash=%x threat_nstm_count=%d threat_nstm_sum=%d threat_nstm_hash=%x (side to move)\n",
					bucket,
					psqt,
					positional,
					total,
					nnz,
					sum,
					hash,
					psq_stm_count,
					psq_stm_hash,
					psq_nstm_count,
					psq_nstm_hash,
					threat_stm_count,
					threat_stm_sum,
					threat_stm_hash,
					threat_nstm_count,
					threat_nstm_sum,
					threat_nstm_hash,
				)
			}
			ml: moves.MoveList
			board.generate_all_moves(&game_board, &ml)
			fmt.printf("Move count: %d\n", ml.count)
			for i in 0 ..< ml.count {
				fmt.printf("  %d: ", i)
				board.print_move(ml.moves[i])
				fmt.println()
			}
			os.flush(os.stdout)
		} else if command == "bench" || strings.has_prefix(command, "bench ") {
			run_benchmark(command)
		} else if command == "stop" {
			// Stop current search (including pondering)
			if sync.atomic_load(&ponder_state.is_active) != 0 {
				// Signal search to stop immediately
				search.stop_search()

				// Wait for ponder thread to finish
				thread.join(ponder_state.thread_handle)
				thread.destroy(ponder_state.thread_handle)
				sync.atomic_store(&ponder_state.is_active, i32(0))
			}
		}
	}
}

// Parse 'position' command
// position startpos [moves e2e4 e7e5 ...]
// position fen <fen_string> [moves ...]
parse_position :: proc(command: string, b: ^board.Board) {
	// Split command
	parts := strings.split(command, " ")
	defer delete(parts)

	move_start_index := 0

	if len(parts) < 2 {return}

	if parts[1] == "startpos" {
		// If opening book is enabled, pick a random book position
		if own_book && book.has_book() && len(parts) == 2 {
			// Only use book for pure "position startpos" (no moves specified)
			fen := book.get_random_book_position()
			if fen != "" {
				b^ = board.parse_fen(fen)
				move_start_index = len(parts) // No moves to parse
			} else {
				b^ = board.parse_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
				move_start_index = 2
			}
		} else {
			b^ = board.parse_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
			move_start_index = 2
		}
	} else if parts[1] == "fen" {
		// Reconstruct FEN string (it might contain spaces)
		// "position fen r... ... ... ... moves ..."
		// We need to find where "moves" starts, or take the rest of the string
		fen_parts := make([dynamic]string)
		defer delete(fen_parts)

		move_start_index = -1

		for i in 2 ..< len(parts) {
			if parts[i] == "moves" {
				move_start_index = i
				break
			}
			append(&fen_parts, parts[i])
		}

		fen_str := strings.join(fen_parts[:], " ")
		defer delete(fen_str)
		b^ = board.parse_fen(fen_str)
	} else {
		return
	}

	// Parse Moves
	if move_start_index != -1 && move_start_index < len(parts) {
		if parts[move_start_index] == "moves" {
			for i in (move_start_index + 1) ..< len(parts) {
				move_str := parts[i]
				move := parse_move(b, move_str)
				if move.source != 0 || move.target != 0 { 	// Valid move?
					state: board.StateInfo
					board.make_move(b, move, &state)
				} else {
					// Invalid move, skip
				}
			}
		}
	}
	// Refresh NNUE accumulators after setting up position.
	if nnue.sfnnv14_active {
		nnue.refresh_sfnnv14_accumulators(b)
	} else if nnue.is_initialized {
		b.accumulators[constants.WHITE] = nnue.compute_accumulator(b, constants.WHITE)
		b.accumulators[constants.BLACK] = nnue.compute_accumulator(b, constants.BLACK)
	}
}

// Parse 'go' command
// go depth 6 wtime 10000 btime 10000 ...
parse_go :: proc(command: string, b: ^board.Board) {
	parts := strings.split(command, " ")
	defer delete(parts)

	depth := -1
	tc: search.TimeControl
	is_pondering := false // Track if this is a ponder search

	// Parse all parameters
	for i in 1 ..< len(parts) {
		if parts[i] == "ponder" {
			is_pondering = true
		} else if parts[i] == "depth" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {depth = val}
			}
		} else if parts[i] == "wtime" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {tc.wtime = val}
			}
		} else if parts[i] == "btime" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {tc.btime = val}
			}
		} else if parts[i] == "winc" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {tc.winc = val}
			}
		} else if parts[i] == "binc" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {tc.binc = val}
			}
		} else if parts[i] == "movestogo" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {tc.movestogo = val}
			}
		} else if parts[i] == "movetime" {
			if i + 1 < len(parts) {
				val, ok := strconv.parse_int(parts[i + 1])
				if ok {tc.movetime = val}
			}
		} else if parts[i] == "infinite" {
			tc.infinite = true
		}
	}

	if depth == -1 {
		depth = 64 // Default to max depth with time control
	}

	// Handle pondering
	if is_pondering {
		// Store board state and parameters for ponder search
		ponder_state.board = b^
		ponder_state.time_control = tc
		ponder_state.depth = depth
		sync.atomic_store(&ponder_state.is_active, i32(1))

		// Spawn background ponder thread
		ponder_state.thread_handle = thread.create(ponder_search_thread)
		ponder_state.thread_handle.data = &ponder_state
		thread.start(ponder_state.thread_handle)

		// Return immediately - search continues in background
		return
	}

	// Regular search (non-ponder)
	search.reset_search_control()

	// If time control, movetime, or infinite specified, use time management
	if tc.wtime > 0 || tc.btime > 0 || tc.movetime > 0 || tc.infinite {
		limits := search.calculate_time(tc, b.side, move_overhead)
		search.search_limits = limits
		search.use_time_management = true
		// Keep TT inside the current clock search, but do not let prior
		// game positions steer a new managed-clock move.
		if !limits.is_movetime && !limits.is_infinite {
			search.clear_tt()
		}

		// Use parallel search if threading enabled
		if thread_count > 1 {
			search.parallel_search(b, depth, multi_pv)
		} else {
			st: search.SearchThread
			search.init_search_thread(&st, 0)
			defer free(st.continuation_history)
			search.search_position(&st, b, depth, multi_pv)
		}

		search.use_time_management = false
	} else {
		// Use parallel search if threading enabled
		if thread_count > 1 {
			search.parallel_search(b, depth, multi_pv)
		} else {
			st: search.SearchThread
			search.init_search_thread(&st, 0)
			defer free(st.continuation_history)
			search.search_position(&st, b, depth, multi_pv)
		}
	}
}


// ============================================================================
// Benchmark
// ============================================================================

// Standard benchmark positions covering openings, middlegames, endgames, and tactics.
// These 44 positions exercise all major code paths in the engine.
BENCH_FENS := []string {
	// Openings
	"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
	"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
	"rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
	"r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
	"rnbqkbnr/pppp1ppp/8/4p3/2P5/8/PP1PPPPP/RNBQKBNR w KQkq - 0 2",
	"rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
	"r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3",
	"rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1",
	"rnbq1rk1/ppppqppp/5n2/4p1B1/1b1PP3/5N2/PPP2PPP/RN1QKB1R w KQ - 4 6",
	"rnbqkb1r/pppp1ppp/7n/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 3 3",
	"r1bqk2r/ppp2ppp/2n2n2/3pp3/1b1PP3/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 5 6",
	"r1bq1rk1/ppp2ppp/2np1n2/4p3/2PPP3/2N2N2/PP3PPP/R1BQKB1R w KQ - 2 6",

	// Middlegames
	"r3kb1r/pppb1ppp/2np4/4p3/1PP1P3/5N2/PB3PPP/RN1QKB1R w KQkq - 2 9",
	"r1bq1rk1/pppnn1bp/3p2p1/3Ppp2/2P1P3/2N2NP1/PP1B1PBP/R2Q1RK1 b - - 0 11",
	"rn1qkb1r/pb1p1ppp/1p2pn2/2p5/2PP4/2N2NP1/PP2PPBP/R1BQK2R b KQkq - 0 7",
	"r4rk1/ppp1qppp/2n1p3/3p4/1b1P4/2N1PN2/PP2BPPP/R2Q1RK1 w - - 2 9",
	"2rq1rk1/pp1bppbp/2np1np1/4P3/3N1P2/2N1B3/PPP1B1PP/R2Q1RK1 w - - 3 12",
	"r1bq1rk1/pp2bppp/2n1pn2/2pp4/2PP4/2N1PN2/PPQ1BPPP/R1B2RK1 b - - 3 8",
	"r1bq1rk1/1pp2ppp/p1np1n2/4p3/2PPP3/2N2N2/PP2BPPP/R1BQ1RK1 w - - 3 9",
	"r1b1kb1r/pp1p1ppp/1qn1p3/2pn4/3P4/2N2N2/PPP1BPPP/R1BQ1RK1 w kq - 4 7",
	"r1bqk2r/pp1pppbp/2n2np1/8/2PNP3/2N5/PP2BPPP/R1BQK2R w KQkq - 0 7",
	"2rqrnk1/pp2bp1p/2p1p1pB/3p4/3P4/2P1PN2/P4PPP/R2Q1RK1 w - - 5 16",

	// Tactical / complex
	"r1b1k2r/ppppqppp/2n5/8/1PP2B2/3PBn2/P1Q2PPP/RN3RK1 w kq - 1 13",
	"r2qkb1r/1ppb1ppp/p1np4/4p3/B3P3/2PP1N2/PP3PPP/RNBQ1RK1 w kq - 1 9",
	"r1bq1rk1/p4ppp/1pnp4/4p3/2P5/1PP1PN2/PB3PPP/R2QKB1R w KQ - 1 12",
	"1r1q1rk1/1p2bppp/pB1ppn2/8/2PQ4/2N2NP1/PP2PPBP/R4RK1 b - - 0 14",
	"r1bq1rk1/pp3ppp/2n1pn2/2pp4/2PP4/2PBPN2/P4PPP/R1BQ1RK1 b - - 1 9",
	"rn2k2r/p4ppp/1q2p3/2bp2B1/1p6/4P3/PP1N1PPP/R2QK2R w KQkq - 0 14",
	"r3k2r/p1q2ppp/2p1pn2/1pb1N3/2B5/2N5/PPP1QPPP/R4RK1 w kq - 1 15",
	"r3r1k1/pp3ppp/2p1bn2/2PpNbb1/3P4/2N1B3/PP2BPPP/R2Q1RK1 w - - 3 15",

	// Endgames
	"8/k7/3p4/p2P1p2/P2P1P2/8/8/K7 w - - 0 1",
	"8/8/8/8/5kp1/P7/8/1K1N4 w - - 0 1",
	"8/2P5/8/4k3/3N4/4K3/8/8 w - - 0 1",
	"6k1/5p2/6p1/8/7p/7P/6PK/8 w - - 0 1",
	"8/8/8/8/1k6/p3R3/1K6/8 w - - 0 1",
	"r1b5/ppp2kpp/8/4p3/2B1n3/2N5/PPP2PPP/R1B1K2R b KQ - 4 13",
	"8/8/8/8/4k3/8/4K3/8 w - - 0 1",
	"8/8/1Pk5/8/2K5/8/8/8 w - - 0 1",
	"8/5pk1/r6p/8/2Q5/3q4/P4PPP/6K1 w - - 0 1",
	"r4rk1/1pp2ppp/2p2n2/p2b4/8/3P2P1/P1P2P1P/R1B1R1K1 w - - 0 22",

	// Mate in X / tricky
	"3rr1k1/pp3ppp/2p5/4q3/P2Q4/2P5/1P3PPP/R2R2K1 w - - 1 22",
	"r1b2rk1/pp3ppp/2n1p3/3p4/2P5/2N1PN2/q4PPP/1R1QKB1R w K - 1 13",
	"7r/p3q1kp/2p1Ppp1/1p1p4/3Q1P2/2P3R1/Pr4PP/4R1K1 b - - 0 26",
	"rnbq2k1/ppp2pp1/4p2p/3n4/1P1P4/P1N2N2/4PPPP/R2QKB1R w KQ - 0 11",
}

run_benchmark :: proc(command: string) {
	parts := strings.split(command, " ")
	defer delete(parts)

	depth := 13
	if len(parts) > 1 {
		val, ok := strconv.parse_int(parts[1])
		if ok && val > 0 && val <= 64 {
			depth = val
		}
	}

	fmt.printf("\n=== Mantis Benchmark ===\n")
	fmt.printf("Positions: %d, Depth: %d\n", len(BENCH_FENS), depth)
	os.flush(os.stdout)

	total_nodes: u64 = 0
	total_time_ms: u64 = 0

	for i in 0 ..< len(BENCH_FENS) {
		search.clear_tt()
		b := board.parse_fen(BENCH_FENS[i])
		nnue.refresh_sfnnv14_accumulators(&b)

		search.reset_search_control()
		sync.atomic_store(&search.total_nodes, 0)

		st: search.SearchThread
		search.init_search_thread(&st, 0)
		defer free(st.continuation_history)

		start := time.now()
		search.search_position(&st, &b, depth, 1, false)
		elapsed := int(time.duration_milliseconds(time.since(start)))

		nodes := search.get_total_nodes()
		total_nodes += u64(nodes)
		total_time_ms += u64(elapsed)

		nps: u64 = 0
		if elapsed > 0 {
			nps = u64(nodes) * 1000 / u64(elapsed)
		}
		fmt.printf("[%2d/%2d] %7d nodes %6d ms %7d nps\n",
			i + 1, len(BENCH_FENS), nodes, elapsed, nps)
		os.flush(os.stdout)
	}

	total_nps: u64 = 0
	if total_time_ms > 0 {
		total_nps = total_nodes * 1000 / total_time_ms
	}
	fmt.println("================================")
	fmt.printf("Total: %d nodes %d ms\n", total_nodes, total_time_ms)
	fmt.printf("NPS:   %d\n", total_nps)
	fmt.println("================================")
	os.flush(os.stdout)
}

// Parse 'setoption' command
// setoption name EvalFile value <path>
parse_setoption :: proc(command: string) {
	parts := strings.split(command, " ")
	defer delete(parts)

	// setoption name <Name> value <Value>
	// 0         1    2      3     4...

	if len(parts) >= 5 && parts[1] == "name" && parts[3] == "value" {
		name := parts[2]

		if name == "EvalFile" {
			// Reconstruct path
			path_parts := parts[4:]
			path := strings.join(path_parts, " ")
			defer delete(path)

			fmt.printf("Loading network from: %s\n", path)

			// Try SFNNv14 first, then fall back to legacy NNUE
			if nnue.init_sfnnv14(path) {
				fmt.println("SFNNv14 network loaded successfully.")
				nnue.sfnnv14_active = true
				nnue.init_sfnnv14_features()
			} else if nnue.init_nnue(path) {
				fmt.println("Legacy NNUE network loaded successfully.")
				nnue.sfnnv14_active = false
			} else {
				fmt.println("Failed to load network.")
			}
		} else if name == "Hash" {
			val, ok := strconv.parse_int(parts[4])
			if ok {
				search.init_tt(val)
			}
		} else if name == "Move" &&
		   len(parts) >= 6 &&
		   parts[3] == "Overhead" &&
		   parts[4] == "value" {
			// Handle "Move Overhead" (two-word option name)
			val, ok := strconv.parse_int(parts[5])
			if ok {
				move_overhead = val
			}
		} else if name == "MultiPV" {
			val, ok := strconv.parse_int(parts[4])
			if ok && val >= 1 && val <= 500 {
				multi_pv = val
			}
		} else if name == "Ponder" {
			// Parse boolean value (true/false)
			if parts[4] == "true" {
				ponder_enabled = true
			} else if parts[4] == "false" {
				ponder_enabled = false
			}
		} else if name == "OwnBook" {
			if parts[4] == "true" {
				own_book = true
				// Load book if not already loaded
				if !book.has_book() {
					book.seed_book_random()
					book.init_opening_book(book_file)
				}
			} else if parts[4] == "false" {
				own_book = false
			}
		} else if name == "BookFile" {
			// Reconstruct path (may contain spaces)
			path_parts := parts[4:]
			path := strings.join(path_parts, " ")
			book_file = path
			if own_book {
				book.seed_book_random()
				book.init_opening_book(book_file)
			}
		} else if name == "Threads" {
			val, ok := strconv.parse_int(parts[4])
			if ok && val >= 1 && val <= 512 {
				thread_count = val
				// Reinitialize thread pool with new count
				search.init_thread_pool(val)
			}
		} else if name == "SearchStats" {
			if parts[4] == "true" {
				search.search_stats_enabled = true
			} else if parts[4] == "false" {
				search.search_stats_enabled = false
			}
		} else if name == "RootDebugTrace" {
			if parts[4] == "true" {
				search.root_debug_trace_enabled = true
			} else if parts[4] == "false" {
				search.root_debug_trace_enabled = false
			}
		} else if name == "StagedMovePicker" {
			if parts[4] == "true" {
				search.use_staged_move_picker = true
			} else if parts[4] == "false" {
				search.use_staged_move_picker = false
			}
		} else if name == "Contempt" {
			val, ok := strconv.parse_int(parts[4])
			if ok && val >= -100 && val <= 100 {
				search.params.contempt = val
			}
		} else if name == "SyzygyPath" {
			// Reconstruct path (may contain spaces)
			path_parts := parts[4:]
			path := strings.join(path_parts, " ")
			defer delete(path)

			if tb.init_syzygy(path) {
				fmt.printf("Syzygy: loaded %d-man tablebases from %s\n", tb.TB_LARGEST, path)
			} else {
				fmt.println("Syzygy: failed to load tablebases")
			}
		} else if name == "SyzygyProbeLimit" {
			val, ok := strconv.parse_int(parts[4])
			if ok && val >= 0 && val <= 7 {
				tb.syzygy_probe_limit = val
			}
		}
	}
}

// Parse Move String (e2e4) to Move Struct
parse_move :: proc(b: ^board.Board, move_str: string) -> moves.Move {
	if len(move_str) < 4 {return moves.Move{}}

	// Source
	sf := int(move_str[0] - 'a')
	sr := int(move_str[1] - '1')
	source := sr * 8 + sf

	// Target
	tf := int(move_str[2] - 'a')
	tr := int(move_str[3] - '1')
	target := tr * 8 + tf

	// Promotion
	promoted := -1
	if len(move_str) > 4 {
		switch move_str[4] {
		case 'n':
			promoted = constants.KNIGHT
		case 'b':
			promoted = constants.BISHOP
		case 'r':
			promoted = constants.ROOK
		case 'q':
			promoted = constants.QUEEN
		}
	}

	// We need to find the move in the move list to get full details (capture, flags)
	move_list: moves.MoveList
	// deferred delete removed: MoveList is stack-allocated
	board.generate_all_moves(b, &move_list)

	for i in 0 ..< move_list.count {
		if move_list.moves[i].source == source && move_list.moves[i].target == target {
			if promoted != -1 {
				if move_list.moves[i].promoted == promoted {return move_list.moves[i]}
			} else {
				return move_list.moves[i]
			}
		}
	}

	return moves.Move{}
}

// Ponder Search Thread - runs in background
ponder_search_thread :: proc(t: ^thread.Thread) {
	state := cast(^Ponder_State)t.data

	// Reset and configure search control for pondering
	search.reset_search_control()
	sync.atomic_store(&search.search_control.ponder_mode, i32(1))

	// Run search with ponder mode (infinite until ponderhit or stop)
	st: search.SearchThread
	search.init_search_thread(&st, 0)
	defer free(st.continuation_history)
	search.search_position(&st, &state.board, state.depth, multi_pv)

	// Mark ponder as inactive when done
	sync.atomic_store(&ponder_state.is_active, i32(0))
}
