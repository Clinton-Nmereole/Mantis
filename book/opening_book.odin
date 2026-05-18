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
