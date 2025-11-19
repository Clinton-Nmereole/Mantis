package main

import "board"
import "constants"
import "core:fmt"
import "core:math/bits"
import "moves"
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
	// Initialize Magic Bitboards
	fmt.println("Initializing Magic Bitboards...")
	moves.init_sliders()

	// Initialize Zobrist Keys
	zobrist.init_zobrist()

	// Initialize Board
	board.init_board()
	fmt.println("Initialization Complete.")

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
