package book

// Opening Book for Mantis Chess Engine
//
// Supports EPD format (Extended Position Description).
// Each line in the EPD file contains a FEN string representing a position
// after a certain number of opening moves.
//
// Usage:
//   init_opening_book("2moves_v1.epd") -> loads book into memory
//   get_random_book_position() -> returns random FEN from book
//   get_builtin_book_move(fen) -> returns a legal opening move for common roots
//   has_book() -> true if book is loaded

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"

// Maximum number of book entries
MAX_BOOK_ENTRIES :: 100_000

OpeningBook :: struct {
	entries:     [MAX_BOOK_ENTRIES]string,
	count:       int,
	is_loaded:   bool,
	filename:    string,
}

book: OpeningBook

BuiltinBookMove :: struct {
	fen:  string,
	move: string,
}

BUILTIN_BOOK_MOVES := [?]BuiltinBookMove {
	{"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "e2e4"},
	{"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", "e7e5"},
	{"rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1", "d7d5"},
	{"rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq c3 0 1", "e7e5"},
	{"rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1", "d7d5"},
	{"rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2", "g1f3"},
	{"rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2", "g1f3"},
	{"rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", "d2d4"},
	{"rnbqkbnr/pp1ppppp/2p5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", "d2d4"},
	{"rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2", "c2c4"},
	{"rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2", "c2c4"},
	{"rnbqkbnr/ppp1pppp/8/3p4/8/5N2/PPPPPPPP/RNBQKB1R w KQkq d6 0 2", "d2d4"},
	{"rnbqkbnr/pppp1ppp/8/4p3/2P5/8/PP1PPPPP/RNBQKBNR w KQkq e6 0 2", "g1f3"},
	{"rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2", "b8c6"},
	{"rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2", "d7d6"},
	{"rnbqkbnr/pppp1ppp/4p3/8/3PP3/8/PPP2PPP/RNBQKBNR b KQkq d3 0 2", "d7d5"},
	{"rnbqkbnr/pp1ppppp/2p5/8/3PP3/8/PPP2PPP/RNBQKBNR b KQkq d3 0 2", "d7d5"},
	{"rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq c3 0 2", "e7e6"},
}

// Initialize the opening book from an EPD file.
// EPD format: each line is "FEN [operations]"
// We extract just the FEN part (first 6 space-separated fields).
init_opening_book :: proc(filename: string) -> bool {
	data, err := os.read_entire_file_from_path(filename, context.allocator)
	if err != os.ERROR_NONE {
		fmt.printf("OpeningBook: Failed to read file: %s\n", filename)
		return false
	}
	defer delete(data)

	content := string(data)
	lines := strings.split(content, "\n")
	defer delete(lines)

	book.count = 0
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 { continue }
		if trimmed[0] == '#' { continue } // Skip comments

		// EPD format: "pieces side castling enpassant halfmove fullmove [ops]"
		// Extract just the FEN part (first 6 fields)
		parts := strings.split(trimmed, " ")
		defer delete(parts)

		if len(parts) < 6 { continue }

		// Build FEN string from first 6 parts
		fen := strings.join(parts[:6], " ")
		if book.count < MAX_BOOK_ENTRIES {
			book.entries[book.count] = fen
			book.count += 1
		}
	}

	if book.count == 0 {
		fmt.println("OpeningBook: No valid entries found")
		return false
	}

	book.is_loaded = true
	book.filename = filename
	fmt.printf("OpeningBook: Loaded %d positions from %s\n", book.count, filename)
	return true
}

// Get a random book position (FEN string).
// Returns empty string if no book is loaded.
get_random_book_position :: proc() -> string {
	if !book.is_loaded || book.count == 0 {
		return ""
	}
	idx := rand.int_max(book.count)
	return book.entries[idx]
}

get_builtin_book_move :: proc(fen: string) -> string {
	for entry in BUILTIN_BOOK_MOVES {
		if fen == entry.fen {
			return entry.move
		}
	}
	return ""
}

// Check if a book is loaded.
has_book :: proc() -> bool {
	return book.is_loaded && book.count > 0
}

// Get the number of book entries.
get_book_count :: proc() -> int {
	return book.count
}

// Seed the random number generator for book selection.
// Call this once during engine initialization.
seed_book_random :: proc(seed: u64 = 0) {
	if seed == 0 {
		now := time.now()
		rand.reset(u64(now._nsec))
	} else {
		rand.reset(seed)
	}
}
