package constants

import "core:fmt"

starting_bitboard: u64 = 0

// Colors
WHITE :: 0
BLACK :: 1
BOTH :: 2

// Piece Types
PAWN :: 0
KNIGHT :: 1
BISHOP :: 2
ROOK :: 3
QUEEN :: 4
KING :: 5

// White Pieces
white_pawn_bitboard: u64 = 0x000000000000FF00
white_knight_bitboard: u64 = 0x0000000000000042
white_bishop_bitboard: u64 = 0x0000000000000024
white_rook_bitboard: u64 = 0x0000000000000081
white_queen_bitboard: u64 = 0x0000000000000008
white_king_bitboard: u64 = 0x0000000000000010

// Black Pieces
// Black Pieces
black_pawn_bitboard: u64 = 0x00FF000000000000
black_knight_bitboard: u64 = 0x4200000000000000
black_bishop_bitboard: u64 = 0x2400000000000000
black_rook_bitboard: u64 = 0x8100000000000000
black_queen_bitboard: u64 = 0x0800000000000000
black_king_bitboard: u64 = 0x1000000000000000

// Board Masks
FILE_A: u64 = 0x0101010101010101
FILE_H: u64 = 0x8080808080808080

RANK_1: u64 = 0x00000000000000FF
RANK_2: u64 = 0x000000000000FF00
RANK_3: u64 = 0x0000000000FF0000
RANK_4: u64 = 0x00000000FF000000
RANK_5: u64 = 0x000000FF00000000
RANK_6: u64 = 0x0000FF0000000000
RANK_7: u64 = 0x00FF000000000000
RANK_8: u64 = 0xFF00000000000000

// Piece Values for MVV-LVA
PIECE_VALUES := [6]int {
	100, // Pawn
	300, // Knight
	300, // Bishop
	500, // Rook
	900, // Queen
	10000, // King
}
