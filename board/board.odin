package board

import "../constants"
import "../moves"
import "../utils"
import "../zobrist"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Board State
Board :: struct {
	// Piece Bitboards
	bitboards:       [12]u64, // [P, N, B, R, Q, K, p, n, b, r, q, k]

	// Occupancy Bitboards
	occupancies:     [3]u64, // [WHITE, BLACK, BOTH]

	// Game State
	side:            int, // 0: White, 1: Black
	en_passant:      int, // Square index (0-63) or -1
	castle:          int, // Bitmask: 0001(WK), 0010(WQ), 0100(BK), 1000(BQ)

	// Zobrist Hash
	hash:            u64,

	// Counters
	halfmove_clock:  int,
	fullmove_number: int,
}

// Castling Rights Bits
WK :: 1 // White King Side
WQ :: 2 // White Queen Side
BK :: 4 // Black King Side
BQ :: 8 // Black Queen Side

// Initialize an empty board
init_board :: proc() -> Board {
	return Board {
		bitboards = [12]u64{},
		occupancies = [3]u64{},
		side = constants.WHITE,
		en_passant = -1,
		castle = 0,
		halfmove_clock = 0,
		fullmove_number = 1,
	}
}

// Helper to map char to piece index
char_to_piece :: proc(c: rune) -> int {
	switch c {
	case 'P':
		return constants.PAWN
	case 'N':
		return constants.KNIGHT
	case 'B':
		return constants.BISHOP
	case 'R':
		return constants.ROOK
	case 'Q':
		return constants.QUEEN
	case 'K':
		return constants.KING
	case 'p':
		return constants.PAWN + 6
	case 'n':
		return constants.KNIGHT + 6
	case 'b':
		return constants.BISHOP + 6
	case 'r':
		return constants.ROOK + 6
	case 'q':
		return constants.QUEEN + 6
	case 'k':
		return constants.KING + 6
	case:
		return -1
	}
}

// Parse FEN String
parse_fen :: proc(fen: string) -> Board {
	board := init_board()

	parts := strings.split(fen, " ")
	defer delete(parts)

	if len(parts) < 1 {return board}

	// 1. Piece Placement
	rank := 7
	file := 0

	for c in parts[0] {
		if c == '/' {
			rank -= 1
			file = 0
		} else if c >= '1' && c <= '8' {
			file += int(c - '0')
		} else {
			piece := char_to_piece(c)
			if piece != -1 {
				// Determine piece color/type index
				// char_to_piece returns 0-5 for White, 6-11 for Black
				// But our bitboards array is 0-11?
				// Let's assume bitboards are indexed:
				// 0-5: White P, N, B, R, Q, K
				// 6-11: Black P, N, B, R, Q, K

				square := rank * 8 + file
				board.bitboards[piece] |= (1 << u64(square))
				file += 1
			}
		}
	}

	// 2. Side to Move
	if len(parts) >= 2 {
		if parts[1] == "w" {board.side = constants.WHITE} else {board.side = constants.BLACK}
	}

	// 3. Castling Rights
	if len(parts) >= 3 {
		for c in parts[2] {
			switch c {
			case 'K':
				board.castle |= WK
			case 'Q':
				board.castle |= WQ
			case 'k':
				board.castle |= BK
			case 'q':
				board.castle |= BQ
			}
		}
	}

	// 4. En Passant
	if len(parts) >= 4 {
		if parts[3] != "-" {
			// Convert "e3" to index
			// 'e' - 'a' = 4
			// '3' - '1' = 2
			// index = 2 * 8 + 4 = 20
			file_char := parts[3][0]
			rank_char := parts[3][1]

			f := int(file_char - 'a')
			r := int(rank_char - '1')
			board.en_passant = r * 8 + f
		}
	}

	// 5. Halfmove Clock
	if len(parts) >= 5 {
		val, ok := strconv.parse_int(parts[4])
		if ok {board.halfmove_clock = val}
	}

	// 6. Fullmove Number
	if len(parts) >= 6 {
		val, ok := strconv.parse_int(parts[5])
		if ok {board.fullmove_number = val}
	}

	// Update Occupancies
	update_occupancies(&board)

	// Initialize Hash
	board.hash = generate_hash(&board)

	return board
}

update_occupancies :: proc(board: ^Board) {
	board.occupancies[constants.WHITE] = 0
	board.occupancies[constants.BLACK] = 0
	board.occupancies[constants.BOTH] = 0

	// White Pieces (0-5)
	for i in 0 ..< 6 {
		board.occupancies[constants.WHITE] |= board.bitboards[i]
	}

	// Black Pieces (6-11)
	for i in 6 ..< 12 {
		board.occupancies[constants.BLACK] |= board.bitboards[i]
	}

	board.occupancies[constants.BOTH] =
		board.occupancies[constants.WHITE] | board.occupancies[constants.BLACK]
}

// Print Board (ASCII)
print_board :: proc(board: Board) {
	fmt.println("\n   +---+---+---+---+---+---+---+---+")
	for r := 7; r >= 0; r -= 1 {
		fmt.printf(" %d |", r + 1)
		for f := 0; f < 8; f += 1 {
			square := r * 8 + f
			piece := -1

			// Find piece at square
			for i in 0 ..< 12 {
				if (board.bitboards[i] & (1 << u64(square))) != 0 {
					piece = i
					break
				}
			}

			symbol := " "
			switch piece {
			case 0:
				symbol = "P"
			case 1:
				symbol = "N"
			case 2:
				symbol = "B"
			case 3:
				symbol = "R"
			case 4:
				symbol = "Q"
			case 5:
				symbol = "K"
			case 6:
				symbol = "p"
			case 7:
				symbol = "n"
			case 8:
				symbol = "b"
			case 9:
				symbol = "r"
			case 10:
				symbol = "q"
			case 11:
				symbol = "k"
			}
			fmt.printf(" %s |", symbol)
		}
		fmt.println("\n   +---+---+---+---+---+---+---+---+")
	}
	fmt.println("     a   b   c   d   e   f   g   h\n")

	fmt.printf("Side: %s\n", board.side == constants.WHITE ? "White" : "Black")
	fmt.printf("En Passant: %d\n", board.en_passant)
	fmt.printf("Castling: %04b\n", board.castle)
}

// Generate Hash from Board
generate_hash :: proc(board: ^Board) -> u64 {
	final_hash: u64 = 0

	// Pieces
	for piece in 0 ..< 12 {
		bitboard := board.bitboards[piece]
		for bitboard != 0 {
			square := utils.get_lsb_index(bitboard)
			utils.pop_lsb(&bitboard)
			final_hash ~= zobrist.piece_keys[piece][square]
		}
	}

	// En Passant
	if board.en_passant != -1 {
		final_hash ~= zobrist.en_passant_keys[board.en_passant]
	}

	// Castling
	final_hash ~= zobrist.castling_keys[board.castle]

	// Side
	if board.side == constants.BLACK {
		final_hash ~= zobrist.side_key
	}

	return final_hash
}
