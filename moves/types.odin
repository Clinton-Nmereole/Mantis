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
