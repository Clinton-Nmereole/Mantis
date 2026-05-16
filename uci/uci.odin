package uci

import "../board"
import "../constants"
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
import "core:thread"

// Debug log file for tracking UCI commands and responses
DEBUG_LOG :: "mantis_uci_debug.log"

debug_log :: proc(msg: string) {
	fd, err := os.open(DEBUG_LOG, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err == os.ERROR_NONE {
		os.write_string(fd, msg)
		os.write_string(fd, "\n")
		os.close(fd)
	}
}

// UCI Configuration
move_overhead: int = 10 // Default 10ms for network/GUI lag compensation
multi_pv: int = 1 // Number of principal variations to display (1-500)
ponder_enabled: bool = false // Whether pondering is allowed
thread_count: int = 1 // Number of search threads (1-512)

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

	// Load Default NNUE (silently)
	default_nnue := "nn-c0ae49f08b40.nnue"
	nnue.init_nnue(default_nnue)

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
			fmt.println("option name Move Overhead type spin default 10 min 0 max 5000")
			fmt.println("option name MultiPV type spin default 1 min 1 max 500")
			fmt.println("option name Ponder type check default false")
			fmt.println("option name SyzygyPath type string default <empty>")
			fmt.println("option name SyzygyProbeLimit type spin default 6 min 0 max 7")
			fmt.println("option name Threads type spin default 1 min 1 max 512")
			fmt.println("option name Contempt type spin default 24 min -100 max 100")
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
		b^ = board.parse_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
		move_start_index = 2
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
					debug_log(fmt.tprintf("[PARSE FAIL] move='%s' not found", move_str))
				}
			}
		}
	}
	debug_log(fmt.tprintf("[POSITION] side=%d", b.side))
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
			if nnue.init_nnue(path) {
				fmt.println("Network loaded successfully.")
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
		} else if name == "Threads" {
			val, ok := strconv.parse_int(parts[4])
			if ok && val >= 1 && val <= 512 {
				thread_count = val
				// Reinitialize thread pool with new count
				search.init_thread_pool(val)
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
