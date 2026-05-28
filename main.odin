package main

import "board"
import "constants"
import "core:fmt"
import "core:math/bits"
import "core:os"
import "core:strconv"
import "moves"
import "nnue"
import "search"
import "uci"
import "zobrist"

starting_bitboard: u64 = 0


set_bit :: proc(bitboard: ^u64, square: u64) {
	bitboard^ |= 1 << square
}

set_bits :: proc(bitboard: ^u64, squares: ..u64) {
	for square in squares {
		bitboard^ |= 1 << square
	}
}

clear_bit :: proc(bitboard: ^u64, square: u64) {
	bitboard^ &= ~(1 << square)
}

clear_bits :: proc(bitboard: ^u64, squares: ..u64) {
	for square in squares {
		bitboard^ &= ~(1 << square)
	}
}

is_bit_set :: proc(bitboard: ^u64, square: u64) -> bool {
	return (bitboard^ & 1 << square) != 0
}


main :: proc() {
	fmt.println("Starting Mantis...")
	// Initialize Magic Bitboards
	fmt.println("Initializing Magic Bitboards...")
	moves.init_sliders()
	fmt.println("Magic Bitboards Initialized.")

	// Initialize Zobrist Keys
	fmt.println("Initializing Zobrist...")
	zobrist.init_zobrist()
	fmt.println("Zobrist Initialized.")

	// Initialize Board
	fmt.println("Initializing Board...")
	board.init_board()
	fmt.println("Initialization Complete.")

	// Check for CLI perft mode
	args := os.args
	if len(args) >= 3 && args[1] == "validate-threat" {
		depth, ok := strconv.parse_int(args[2])
		if ok && depth >= 1 {
			fen := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
			if len(args) >= 5 && args[3] == "fen" {
				fen = args[4]
			}
			if nnue.init_sfnnv14("nn-7bf13f9655c8.nnue") {
				nnue.sfnnv14_active = true
				nnue.init_sfnnv14_features()
				nnue.validate_threat_incremental_test(fen, depth)
			} else {
				fmt.println("Threat validation FAILED: could not load SFNNv14 network")
			}
			return
		}
	}

	if len(args) >= 3 && args[1] == "validate-qcaptures" {
		depth, ok := strconv.parse_int(args[2])
		if ok && depth >= 0 {
			search.init_search_params()
			fen := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
			if len(args) >= 5 && args[3] == "fen" {
				fen = args[4]
			}
			search.validate_qcapture_parity_test(fen, depth)
			return
		}
	}

	if len(args) >= 3 && args[1] == "perft" {
		depth, ok := strconv.parse_int(args[2])
		if ok && depth >= 1 {
			fen := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
			if len(args) >= 5 && args[3] == "fen" {
				fen = args[4]
			}
			board.perft_test(fen, depth)
			return
		}
	}

	// Check for CLI validation mode
	if len(args) >= 3 && args[1] == "validate" {
		depth, ok := strconv.parse_int(args[2])
		if ok && depth >= 1 {
			fen := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
			if len(args) >= 5 && args[3] == "fen" {
				fen = args[4]
			}
			board.validate_perft_test(fen, depth)
			return
		}
	}

	// Start UCI Loop
	uci.uci_loop()
}

print_move_list :: proc(list: [dynamic]moves.Move) {
	for m in list {
		fmt.printf(
			"Move: %v -> %v (Piece: %v, Capture: %v",
			m.source,
			m.target,
			m.piece,
			m.capture,
		)
		if m.promoted != -1 {
			fmt.printf(", Promoted: %v", m.promoted)
		}
		if m.double_push {
			fmt.printf(", Double Push")
		}
		if m.en_passant {
			fmt.printf(", En Passant")
		}
		fmt.println(")")
	}
}
