package uci

import "../board"
import "../constants"
import "../moves"
import "../nnue"
import "../search"
import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// UCI Main Loop
uci_loop :: proc() {
	reader: bufio.Reader
	buffer: [4096]byte
	bufio.reader_init(&reader, os.stream_from_handle(os.stdin))
	defer bufio.reader_destroy(&reader)

	game_board := board.parse_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

	// Initialize TT
	search.init_tt(64) // Default 64MB

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
			break
		} else if command == "uci" {
			fmt.println("id name Mantis")
			fmt.println("id author")
			fmt.println("option name Hash type spin default 64 min 1 max 1024")
			fmt.println("option name EvalFile type string default nn-c0ae49f08b40.nnue")
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
		} else if command == "stop" {
			// TODO: Signal stop to search thread
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
					board.make_move(b, move, b.side)
				}
			}
		}
	}
}

// Parse 'go' command
// go depth 6 wtime 10000 btime 10000 ...
parse_go :: proc(command: string, b: ^board.Board) {
	parts := strings.split(command, " ")
	defer delete(parts)

	depth := -1
	tc: search.TimeControl

	// Parse all parameters
	for i in 1 ..< len(parts) {
		if parts[i] == "depth" {
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
		}
	}

	if depth == -1 {
		depth = 64 // Default to max depth with time control
	}

	// If time control specified, use time management
	if tc.wtime > 0 || tc.btime > 0 {
		limits := search.calculate_time(tc, b.side)
		search.search_limits = limits
		search.use_time_management = true
		search.search_position(b, depth)
		search.use_time_management = false
	} else {
		search.search_position(b, depth)
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
	move_list := make([dynamic]moves.Move)
	defer delete(move_list)
	board.generate_all_moves(b, &move_list)

	for m in move_list {
		if m.source == source && m.target == target {
			if promoted != -1 {
				if m.promoted == promoted {return m}
			} else {
				return m
			}
		}
	}

	return moves.Move{}
}
