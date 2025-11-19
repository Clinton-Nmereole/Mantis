package main

import "board"
import "constants"
import "core:fmt"
import "core:math/bits"
import "moves"
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
	fmt.println("Initializing Magic Bitboards...")
	moves.init_sliders()

	// Initialize Zobrist Keys
	zobrist.init_zobrist()

	// Initialize Board
	board.init_board()
	fmt.println("Initialization Complete.")

	// Test FEN Parsing
	fmt.println("\n--- FEN Parsing Test ---")
	// Standard Start Position
	start_fen := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
	game_board := board.parse_fen(start_fen)
	board.print_board(game_board)

	// Test Tricky Position (KiwiPete)
	fmt.println("\n--- KiwiPete Position ---")
	kiwipete_fen := "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"

	// Test Perft
	fmt.println("\n--- Perft Test ---")

	// Position 1 (Start Pos)
	// Depth 1: 20
	// Depth 2: 400
	// Depth 3: 8902
	// Depth 4: 197281
	board.perft_test(start_fen, 3)

	// Position 2 (KiwiPete)
	// Depth 1: 48
	// Depth 2: 2039
	// Depth 3: 97862
	board.perft_test(kiwipete_fen, 3)
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
