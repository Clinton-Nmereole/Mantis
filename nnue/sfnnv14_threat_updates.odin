package nnue

// ============================================================================
// Viridithas-Style Delta-Based Threat Incremental Updates
// ============================================================================
//
// This module implements delta-based incremental threat accumulator updates.
// Instead of refreshing the entire threat accumulator, we compute the exact
// set of threats that changed and apply only those differences.
//
// Approach: For a piece move, compute:
//   1. Threats that existed BEFORE but not AFTER → SUBTRACT
//   2. Threats that exist AFTER but not BEFORE → ADD
//
// This is ~1000x faster than full refresh (50 changes vs 30K features).

import "../board"
import "../constants"
import "../moves"
import "../utils"
import "core:math/bits"

// ============================================================================
// Threat Update Buffer
// ============================================================================

// Maximum active threats per position (empirically ~50-100)
MAX_THREAT_UPDATES :: 128

// Note: ThreatFeatureUpdate, SFNNv14_ThreatUpdateBuffer are defined in
// sfnnv14_features.odin (same package). We use those types here.

// Clear the update buffer
threat_buffer_clear :: proc(buffer: ^SFNNv14_ThreatUpdateBuffer) {
	buffer.add_count = 0
	buffer.sub_count = 0
}

// Append an ADD to the buffer
threat_buffer_add :: proc(buffer: ^SFNNv14_ThreatUpdateBuffer, attacker, from, victim, to: int) {
	if attacker % 6 == constants.KING {return}
	if victim % 6 == constants.KING {return}
	if buffer.add_count < MAX_THREAT_UPDATES {
		buffer.add[buffer.add_count] = ThreatFeatureUpdate{u8(attacker), u8(from), u8(victim), u8(to)}
		buffer.add_count += 1
	}
}

// Append a SUB to the buffer
threat_buffer_sub :: proc(buffer: ^SFNNv14_ThreatUpdateBuffer, attacker, from, victim, to: int) {
	if attacker % 6 == constants.KING {return}
	if victim % 6 == constants.KING {return}
	if buffer.sub_count < MAX_THREAT_UPDATES {
		buffer.sub[buffer.sub_count] = ThreatFeatureUpdate{u8(attacker), u8(from), u8(victim), u8(to)}
		buffer.sub_count += 1
	}
}

// ============================================================================
// Geometry Helpers
// ============================================================================

// Direction offsets for ray walking: N, NE, E, SE, S, SW, W, NW
DIR_FILE_DELTA := [8]int{0, 1, 1, 1, 0, -1, -1, -1}
DIR_RANK_DELTA := [8]int{1, 1, 0, -1, -1, -1, 0, 1}

// Find the first piece in a given direction from sq.
// Returns (piece, square) or (-1, -1) if no piece found.
get_first_piece_in_direction :: proc(b: ^board.Board, sq: int, dir: int) -> (piece: int, square: int) {
	file := sq % 8
	rank := sq / 8
	df := DIR_FILE_DELTA[dir]
	dr := DIR_RANK_DELTA[dir]

	f := file + df
	r := rank + dr

	for f >= 0 && f < 8 && r >= 0 && r < 8 {
		s := r * 8 + f
		p := int(b.mailbox[s])
		if p != -1 {
			return p, s
		}
		f += df
		r += dr
	}

	return -1, -1
}

// Check if a piece type is a slider (bishop, rook, or queen)
is_slider :: proc(piece_type: int) -> bool {
	return piece_type == constants.BISHOP || piece_type == constants.ROOK || piece_type == constants.QUEEN
}

// Check if a slider can attack along a given direction type.
// is_diagonal: true for NE, SE, SW, NW; false for N, E, S, W.
can_slider_attack_direction :: proc(piece_type: int, is_diagonal: bool) -> bool {
	switch piece_type {
	case constants.BISHOP:
		return is_diagonal
	case constants.ROOK:
		return !is_diagonal
	case constants.QUEEN:
		return true
	}
	return false
}

// Compute attack bitboard for a Mantis piece (0-11) on a square.
piece_attacks_bb :: proc(piece: int, sq: int, occupied: u64) -> u64 {
	pt := piece % 6
	switch pt {
	case constants.PAWN:
		color := piece / 6
		if color == constants.WHITE {
			return ((u64(1) << u64(sq) & ~constants.FILE_H) << 9) |
			       ((u64(1) << u64(sq) & ~constants.FILE_A) << 7)
		} else {
			return ((u64(1) << u64(sq) & ~constants.FILE_A) >> 9) |
			       ((u64(1) << u64(sq) & ~constants.FILE_H) >> 7)
		}
	case constants.KNIGHT:
		return moves.get_knight_attacks_bitboard(sq)
	case constants.BISHOP:
		return moves.get_bishop_attacks(sq, occupied)
	case constants.ROOK:
		return moves.get_rook_attacks(sq, occupied)
	case constants.QUEEN:
		return moves.get_queen_attacks(sq, occupied)
	case constants.KING:
		// Kings excluded from threats
		return 0
	}
	return 0
}

// ============================================================================
// Core Threat Delta Functions
// ============================================================================

// Compute all outgoing threats made BY 'piece' at 'sq' on board 'b'.
// These are threats where the piece at sq is the attacker.
// For perspective 'persp', used for orientation.
compute_outgoing_threats :: proc(
	b: ^board.Board,
	persp: int,
	piece: int,
	sq: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
	is_add: bool,
) {
	ksq := board.get_king_square(b, persp)
	occupied := b.occupancies[constants.BOTH]
	pt := piece % 6

	if pt == constants.KING {return}

	// Pawn has special attack patterns including pushes
	if pt == constants.PAWN {
		color := piece / 6
		c_pawns := b.bitboards[piece]
		all_pawns := b.bitboards[constants.PAWN] | b.bitboards[constants.PAWN + 6]

		// Compute pushers: pawns blocked by any pawn in front
		pushers: u64 = 0
		if color == constants.WHITE {
			pushers = ((all_pawns & ~constants.RANK_8) << 8) & c_pawns
		} else {
			pushers = ((all_pawns & ~constants.RANK_1) >> 8) & c_pawns
		}

		if color == constants.WHITE {
			// NE attacks
			attacks := (c_pawns & ~constants.FILE_H) << 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 9
				if from == sq {
					attacked := int(b.mailbox[to])
					if attacked != -1 {
						if is_add {
							threat_buffer_add(buffer, piece, from, attacked, to)
						} else {
							threat_buffer_sub(buffer, piece, from, attacked, to)
						}
					}
				}
			}
			// NW attacks
			attacks = (c_pawns & ~constants.FILE_A) << 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 7
				if from == sq {
					attacked := int(b.mailbox[to])
					if attacked != -1 {
						if is_add {
							threat_buffer_add(buffer, piece, from, attacked, to)
						} else {
							threat_buffer_sub(buffer, piece, from, attacked, to)
						}
					}
				}
			}
			// Pushes
			attacks = pushers << 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 8
				if from == sq {
					attacked := int(b.mailbox[to])
					if attacked != -1 {
						if is_add {
							threat_buffer_add(buffer, piece, from, attacked, to)
						} else {
							threat_buffer_sub(buffer, piece, from, attacked, to)
						}
					}
				}
			}
		} else {
			// Black pawn SW attacks
			attacks := (c_pawns & ~constants.FILE_A) >> 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 9
				if from == sq {
					attacked := int(b.mailbox[to])
					if attacked != -1 {
						if is_add {
							threat_buffer_add(buffer, piece, from, attacked, to)
						} else {
							threat_buffer_sub(buffer, piece, from, attacked, to)
						}
					}
				}
			}
			// Black pawn SE attacks
			attacks = (c_pawns & ~constants.FILE_H) >> 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 7
				if from == sq {
					attacked := int(b.mailbox[to])
					if attacked != -1 {
						if is_add {
							threat_buffer_add(buffer, piece, from, attacked, to)
						} else {
							threat_buffer_sub(buffer, piece, from, attacked, to)
						}
					}
				}
			}
			// Black pawn pushes
			attacks = pushers >> 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 8
				if from == sq {
					attacked := int(b.mailbox[to])
					if attacked != -1 {
						if is_add {
							threat_buffer_add(buffer, piece, from, attacked, to)
						} else {
							threat_buffer_sub(buffer, piece, from, attacked, to)
						}
					}
				}
			}
		}
		return
	}

	// Non-pawn pieces
	attacks := piece_attacks_bb(piece, sq, occupied)
	attacks &= occupied
	for attacks != 0 {
		to := utils.pop_lsb(&attacks)
		attacked := int(b.mailbox[to])
		if attacked != -1 {
			if is_add {
				threat_buffer_add(buffer, piece, sq, attacked, to)
			} else {
				threat_buffer_sub(buffer, piece, sq, attacked, to)
			}
		}
	}
}

// Compute all incoming threats TO 'piece' at 'sq' on board 'b'.
// These are threats where other pieces attack the piece at sq.
compute_incoming_threats :: proc(
	b: ^board.Board,
	persp: int,
	piece: int,
	sq: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
	is_add: bool,
) {
	if piece % 6 == constants.KING {return}
	occupied := b.occupancies[constants.BOTH]

	// Check all piece types that might attack sq
	for pt in constants.KNIGHT ..< constants.KING {
		for color in 0 ..= 1 {
			attacker_piece := color * 6 + pt
			attackers := b.bitboards[attacker_piece]
			if attackers == 0 {continue}

			attacks: u64 = 0
			switch pt {
			case constants.KNIGHT:
				attacks = moves.get_knight_attacks_bitboard(sq) & attackers
			case constants.BISHOP:
				attacks = moves.get_bishop_attacks(sq, occupied) & attackers
			case constants.ROOK:
				attacks = moves.get_rook_attacks(sq, occupied) & attackers
			case constants.QUEEN:
				attacks = moves.get_queen_attacks(sq, occupied) & attackers
			}

			for attacks != 0 {
				from := utils.pop_lsb(&attacks)
				if is_add {
					threat_buffer_add(buffer, attacker_piece, from, piece, sq)
				} else {
					threat_buffer_sub(buffer, attacker_piece, from, piece, sq)
				}
			}
		}
	}

	// Pawns attack diagonally
	for color in 0 ..= 1 {
		attacker_piece := color * 6 + constants.PAWN
		pawns := b.bitboards[attacker_piece]
		if pawns == 0 {continue}

		from_sq: int
		if color == constants.WHITE {
			// White pawns attack from below: sq - 9 (right) and sq - 7 (left)
			from_sq = sq - 9
			if from_sq >= 0 && from_sq < 64 && (from_sq % 8) < 7 && (u64(1) << u64(from_sq)) & pawns != 0 {
				if is_add {
					threat_buffer_add(buffer, attacker_piece, from_sq, piece, sq)
				} else {
					threat_buffer_sub(buffer, attacker_piece, from_sq, piece, sq)
				}
			}
			from_sq = sq - 7
			if from_sq >= 0 && from_sq < 64 && (from_sq % 8) > 0 && (u64(1) << u64(from_sq)) & pawns != 0 {
				if is_add {
					threat_buffer_add(buffer, attacker_piece, from_sq, piece, sq)
				} else {
					threat_buffer_sub(buffer, attacker_piece, from_sq, piece, sq)
				}
			}
		} else {
			// Black pawns attack from above: sq + 9 (left) and sq + 7 (right)
			from_sq = sq + 9
			if from_sq >= 0 && from_sq < 64 && (from_sq % 8) > 0 && (u64(1) << u64(from_sq)) & pawns != 0 {
				if is_add {
					threat_buffer_add(buffer, attacker_piece, from_sq, piece, sq)
				} else {
					threat_buffer_sub(buffer, attacker_piece, from_sq, piece, sq)
				}
			}
			from_sq = sq + 7
			if from_sq >= 0 && from_sq < 64 && (from_sq % 8) < 7 && (u64(1) << u64(from_sq)) & pawns != 0 {
				if is_add {
					threat_buffer_add(buffer, attacker_piece, from_sq, piece, sq)
				} else {
					threat_buffer_sub(buffer, attacker_piece, from_sq, piece, sq)
				}
			}
		}
	}
}

// Compute discovered threats when a piece leaves 'sq'.
// A discovered threat exists when a slider on one side of sq now has
// line of sight to a victim on the other side.
compute_discovered_threats :: proc(
	b: ^board.Board,
	persp: int,
	sq: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
) {
	for dir in 0 ..< 4 { // Only need 4 directions (and their opposites)
		opposite := dir + 4
		is_diag := (dir % 2) == 1

		p1, s1 := get_first_piece_in_direction(b, sq, dir)
		p2, s2 := get_first_piece_in_direction(b, sq, opposite)

		if p1 != -1 && p2 != -1 {
			pt1 := p1 % 6
			pt2 := p2 % 6

			// Check if p1 is a slider and p2 is a non-king victim
			if is_slider(pt1) && pt2 != constants.KING && can_slider_attack_direction(pt1, is_diag) {
				threat_buffer_add(buffer, p1, s1, p2, s2)
			}
			// Check if p2 is a slider and p1 is a non-king victim
			if is_slider(pt2) && pt1 != constants.KING && can_slider_attack_direction(pt2, is_diag) {
				threat_buffer_add(buffer, p2, s2, p1, s1)
			}
		}
	}
}

// Compute blocked threats when a piece arrives at 'sq'.
// These are threats that existed BEFORE the piece arrived but are now blocked.
// We check on the board WITH the piece in place - the blocked threats are
// threats that would exist if the piece were not there.
compute_blocked_threats :: proc(
	b: ^board.Board,
	persp: int,
	sq: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
) {
	// Temporarily remove the piece at sq to see what threats were there
	piece_at_sq := int(b.mailbox[sq])
	if piece_at_sq == -1 {return}

	b.mailbox[sq] = -1
	b.bitboards[piece_at_sq] &~= (u64(1) << u64(sq))
	old_occupied := b.occupancies[constants.BOTH]
	b.occupancies[constants.BOTH] = b.occupancies[constants.WHITE] | b.occupancies[constants.BLACK]

	for dir in 0 ..< 4 {
		opposite := dir + 4
		is_diag := (dir % 2) == 1

		p1, s1 := get_first_piece_in_direction(b, sq, dir)
		p2, s2 := get_first_piece_in_direction(b, sq, opposite)

		if p1 != -1 && p2 != -1 {
			pt1 := p1 % 6
			pt2 := p2 % 6

			if is_slider(pt1) && pt2 != constants.KING && can_slider_attack_direction(pt1, is_diag) {
				threat_buffer_sub(buffer, p1, s1, p2, s2)
			}
			if is_slider(pt2) && pt1 != constants.KING && can_slider_attack_direction(pt2, is_diag) {
				threat_buffer_sub(buffer, p2, s2, p1, s1)
			}
		}
	}

	// Restore board
	b.mailbox[sq] = i8(piece_at_sq)
	b.bitboards[piece_at_sq] |= (u64(1) << u64(sq))
	b.occupancies[constants.BOTH] = old_occupied
}

// ============================================================================
// Viridithas-Style on_change / on_move / on_mutate
// ============================================================================

// on_change_add: piece added to sq.
// Add outgoing threats from piece at sq.
// Add incoming threats to piece at sq.
// Sub blocked threats through sq.
on_change_add :: proc(b: ^board.Board, persp: int, piece: int, sq: int, buffer: ^SFNNv14_ThreatUpdateBuffer) {
	compute_outgoing_threats(b, persp, piece, sq, buffer, true)
	compute_incoming_threats(b, persp, piece, sq, buffer, true)
	compute_blocked_threats(b, persp, sq, buffer)
}

// on_change_sub: piece removed from sq.
// Sub outgoing threats from piece at sq.
// Sub incoming threats to piece at sq.
// Add discovered threats through sq.
on_change_sub :: proc(b: ^board.Board, persp: int, piece: int, sq: int, buffer: ^SFNNv14_ThreatUpdateBuffer) {
	compute_outgoing_threats(b, persp, piece, sq, buffer, false)
	compute_incoming_threats(b, persp, piece, sq, buffer, false)
	compute_discovered_threats(b, persp, sq, buffer)
}

// on_move: piece moves from src to dst.
// Combines on_change_sub at src and on_change_add at dst.
on_move :: proc(
	b: ^board.Board,
	persp: int,
	old_piece: int,
	src: int,
	new_piece: int,
	dst: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
) {
	on_change_sub(b, persp, old_piece, src, buffer)
	on_change_add(b, persp, new_piece, dst, buffer)
}

// on_mutate: piece promotion (type changes, square stays).
// Sub old piece's threats, add new piece's threats.
// No discovered/blocked since square doesn't change.
on_mutate :: proc(
	b: ^board.Board,
	persp: int,
	old_piece: int,
	new_piece: int,
	sq: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
) {
	compute_outgoing_threats(b, persp, old_piece, sq, buffer, false)
	compute_incoming_threats(b, persp, old_piece, sq, buffer, false)
	compute_outgoing_threats(b, persp, new_piece, sq, buffer, true)
	compute_incoming_threats(b, persp, new_piece, sq, buffer, true)
}

// ============================================================================
// Apply Buffer to Accumulator
// ============================================================================

// Apply a threat update buffer to the accumulator for a given perspective.
// This performs the actual add/subtract of weight rows.
// Requires the king square for proper threat feature orientation.
apply_threat_buffer_to_accumulator :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	perspective: int,
	buffer: ^SFNNv14_ThreatUpdateBuffer,
	ksq: int,
) {
	if len(sfnnv14_transformer.threat_weights) == 0 {return}

	// Apply SUBs
	for i in 0 ..< buffer.sub_count {
		update := buffer.sub[i]
		idx := get_threat_feature_index(perspective, int(update.attacker), int(update.from), int(update.to), int(update.victim), ksq)
		if idx < 0 || idx >= SFNNV14_THREAT_DIMENSIONS {continue}

		weight_offset := idx * SFNNV14_L1
		for j in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][j] -= i16(sfnnv14_transformer.threat_weights[weight_offset + j])
		}
		psqt_offset := idx * SFNNV14_PSQT_BUCKETS
		for j in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][j] -= sfnnv14_transformer.threat_psqt_weights[psqt_offset + j]
		}
	}

	// Apply ADDs
	for i in 0 ..< buffer.add_count {
		update := buffer.add[i]
		idx := get_threat_feature_index(perspective, int(update.attacker), int(update.from), int(update.to), int(update.victim), ksq)
		if idx < 0 || idx >= SFNNV14_THREAT_DIMENSIONS {continue}

		weight_offset := idx * SFNNV14_L1
		for j in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][j] += i16(sfnnv14_transformer.threat_weights[weight_offset + j])
		}
		psqt_offset := idx * SFNNV14_PSQT_BUCKETS
		for j in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][j] += sfnnv14_transformer.threat_psqt_weights[psqt_offset + j]
		}
	}
}

// ============================================================================
// High-Level: Incremental Update for a Move
// ============================================================================

// Update threat accumulators incrementally for a piece move.
// This replaces the "mark dirty" approach with exact delta application.
update_threat_accumulators_incremental :: proc(
	old_board: ^board.Board,
	new_board: ^board.Board,
	move: moves.Move,
) {
	if sfnnv14_transformer.threat_weights == nil {return}

	side := old_board.side
	piece_type := move.piece

	// Determine the actual piece being moved
	moved_piece := piece_type
	if side == constants.BLACK {
		moved_piece += 6
	}

	// For captures, determine the captured piece
	captured_piece := -1
	if move.capture {
		captured_piece = int(old_board.mailbox[move.target])
	}

	// For promotions, determine the final piece
	final_piece := moved_piece
	if move.promoted != -1 {
		final_piece = move.promoted
		if side == constants.BLACK {
			final_piece += 6
		}
	}

	buffer: SFNNv14_ThreatUpdateBuffer

	for perspective in 0 ..= 1 {
		threat_buffer_clear(&buffer)

		// Handle different move types
		if piece_type == constants.KING {
			// King move: full refresh required (king bucket changes)
			refresh_threat_accumulator(new_board, perspective)
			continue
		}

		if move.promoted != -1 {
			// Promotion: piece type changes at target square
			// Remove pawn threats from source
			fast_on_change_sub(old_board, perspective, moved_piece, move.source, &buffer)
			// Remove captured piece threats at target (if capture)
			if captured_piece != -1 {
				fast_on_change_sub(new_board, perspective, captured_piece, move.target, &buffer)
			}
			// Add promoted piece threats at target
			fast_on_change_add(new_board, perspective, final_piece, move.target, &buffer)
		} else if move.capture && captured_piece != -1 {
			// Normal capture: move piece, capture at target
			fast_on_move(old_board, perspective, moved_piece, move.source, final_piece, move.target, &buffer)
			// Also remove captured piece's threats
			fast_on_change_sub(new_board, perspective, captured_piece, move.target, &buffer)
		} else {
			// Quiet move
			fast_on_move(old_board, perspective, moved_piece, move.source, final_piece, move.target, &buffer)
		}

		// Handle en passant capture (captured pawn is not on target square)
		if move.en_passant {
			ep_captured_sq := move.target + (side == constants.WHITE ? -8 : 8)
			ep_captured_piece := side == constants.WHITE ? constants.PAWN + 6 : constants.PAWN
			fast_on_change_sub(new_board, perspective, ep_captured_piece, ep_captured_sq, &buffer)
		}

		// Apply the computed delta to the accumulator
		ksq := board.get_king_square(old_board, perspective)
		apply_threat_buffer_to_accumulator(&new_board.sfnnv14_accumulators.threat, perspective, &buffer, ksq)
		new_board.sfnnv14_accumulators.threat.computed[perspective] = true
	}
}
