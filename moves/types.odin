package moves

import "../constants"

Move :: struct {
	source:      int,
	target:      int,
	piece:       int,
	promoted:    int, // 0-5 (Piece Type) or -1 if none
	capture:     bool,
	double_push: bool,
	en_passant:  bool,
	castling:    bool,
}

// Helper to create a simple move
create_move :: proc(source, target, piece: int, capture: bool = false) -> Move {
	return Move {
		source      = source,
		target      = target,
		piece       = piece,
		promoted    = -1, // No promotion
		capture     = capture,
		double_push = false,
		en_passant  = false,
		castling    = false,
	}
}

// MoveList: fixed-size stack-allocated move buffer.
// Chess has at most 218 legal moves in any position, so 256 is plenty.
MoveList :: struct {
	moves: [256]Move,
	count: int,
}

// Append a move to the list
append_move :: proc(list: ^MoveList, move: Move) {
	list.moves[list.count] = move
	list.count += 1
}

// Clear the list
 clear_move_list :: proc(list: ^MoveList) {
	list.count = 0
}
