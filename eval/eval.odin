package eval

import "../board"
import "../constants"
import "../nnue"
import "../utils"

// Evaluation Constants
INF :: 50000
MATE :: 49000

// Evaluate the board position
// Returns score in centipawns (from side to move perspective)
evaluate :: proc(b: ^board.Board) -> int {
	// Try NNUE
	if nnue.is_initialized {
		return nnue.evaluate(b)
	}

	// Fallback to Hand-Crafted Evaluation (HCE)
	score := 0

	// Material and Position
	// White Pieces
	bitboard := b.bitboards[constants.PAWN]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		score += PAWN_VALUE + pawn_pst[sq]
	}

	bitboard = b.bitboards[constants.KNIGHT]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		score += KNIGHT_VALUE + knight_pst[sq]
	}

	bitboard = b.bitboards[constants.BISHOP]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		score += BISHOP_VALUE + bishop_pst[sq]
	}

	bitboard = b.bitboards[constants.ROOK]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		score += ROOK_VALUE + rook_pst[sq]
	}

	bitboard = b.bitboards[constants.QUEEN]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		score += QUEEN_VALUE + queen_pst[sq]
	}

	bitboard = b.bitboards[constants.KING]
	if bitboard != 0 {
		sq := utils.get_lsb_index(bitboard)
		score += KING_VALUE + king_pst[sq]
	}

	// Black Pieces
	bitboard = b.bitboards[constants.PAWN + 6]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		// Mirror Square for Black PST
		mirror_sq := sq ~ 56
		score -= PAWN_VALUE + pawn_pst[mirror_sq]
	}

	bitboard = b.bitboards[constants.KNIGHT + 6]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		mirror_sq := sq ~ 56
		score -= KNIGHT_VALUE + knight_pst[mirror_sq]
	}

	bitboard = b.bitboards[constants.BISHOP + 6]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		mirror_sq := sq ~ 56
		score -= BISHOP_VALUE + bishop_pst[mirror_sq]
	}

	bitboard = b.bitboards[constants.ROOK + 6]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		mirror_sq := sq ~ 56
		score -= ROOK_VALUE + rook_pst[mirror_sq]
	}

	bitboard = b.bitboards[constants.QUEEN + 6]
	for bitboard != 0 {
		sq := utils.pop_lsb(&bitboard)
		mirror_sq := sq ~ 56
		score -= QUEEN_VALUE + queen_pst[mirror_sq]
	}

	bitboard = b.bitboards[constants.KING + 6]
	if bitboard != 0 {
		sq := utils.get_lsb_index(bitboard)
		mirror_sq := sq ~ 56
		score -= KING_VALUE + king_pst[mirror_sq]
	}

	// Return score from side-to-move perspective
	if b.side == constants.WHITE {
		return score
	} else {
		return -score
	}
}
