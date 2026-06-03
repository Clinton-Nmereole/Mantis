package tb

import "../board"
import "../constants"
import "../moves"

// Count pieces on board for TB probing decision
piece_count :: proc(b: ^board.Board) -> int {
	count := 0
	for i in 0 ..< 12 {
		count += popcount(b.bitboards[i])
	}
	return count
}

popcount :: proc(bb: u64) -> int {
	c: int = 0
	x := bb
	for x != 0 {
		x &= x - 1
		c += 1
	}
	return c
}

// Convert Mantis Board to Fathom bitboards
board_to_tb :: proc(b: ^board.Board, white, black, kings, queens, rooks, bishops, knights, pawns: ^u64) {
	white^ = 0
	black^ = 0
	kings^ = 0
	queens^ = 0
	rooks^ = 0
	bishops^ = 0
	knights^ = 0
	pawns^ = 0

	for sq in 0 ..< 64 {
		piece := b.mailbox[sq]
		if piece == -1 { continue }

		bb := u64(1) << u64(sq)
		piece_type := piece % 6
		is_white := piece < 6

		if is_white {
			white^ |= bb
		} else {
			black^ |= bb
		}

		switch piece_type {
		case constants.KING:
			kings^ |= bb
		case constants.QUEEN:
			queens^ |= bb
		case constants.ROOK:
			rooks^ |= bb
		case constants.BISHOP:
			bishops^ |= bb
		case constants.KNIGHT:
			knights^ |= bb
		case constants.PAWN:
			pawns^ |= bb
		}
	}
}

// Probe WDL during search — returns (score, hit)
probe_wdl :: proc(b: ^board.Board) -> (int, bool) {
	if !syzygy_enabled { return 0, false }
	if piece_count(b) > effective_probe_limit() { return 0, false }
	if b.castle != 0 { return 0, false } // TBs don't handle castling

	white, black, kings, queens, rooks, bishops, knights, pawns: u64
	board_to_tb(b, &white, &black, &kings, &queens, &rooks, &bishops, &knights, &pawns)

	ep := u32(0)
	if b.en_passant != -1 {
		ep = u32(b.en_passant)
	}

	wdl := tb_probe_wdl_impl(white, black, kings, queens, rooks, bishops, knights, pawns,
		ep, b.side == constants.WHITE)

	if wdl == TB_RESULT_FAILED {
		return 0, false
	}

	return wdl_to_score(wdl), true
}

// Probe root — returns (score, best_move, hit)
probe_root :: proc(b: ^board.Board) -> (int, moves.Move, bool) {
	if !syzygy_enabled { return 0, moves.Move{}, false }
	if piece_count(b) > effective_probe_limit() { return 0, moves.Move{}, false }
	if b.castle != 0 { return 0, moves.Move{}, false }

	white, black, kings, queens, rooks, bishops, knights, pawns: u64
	board_to_tb(b, &white, &black, &kings, &queens, &rooks, &bishops, &knights, &pawns)

	ep := u32(0)
	if b.en_passant != -1 {
		ep = u32(b.en_passant)
	}

	results: [192 + 1]u32
	res := tb_probe_root_impl(white, black, kings, queens, rooks, bishops, knights, pawns,
		u32(b.halfmove_clock), ep, b.side == constants.WHITE, &results[0])

	if res == TB_RESULT_FAILED {
		return 0, moves.Move{}, false
	}

	// Extract best move from result
	from_sq := int(TB_GET_FROM(res))
	to_sq := int(TB_GET_TO(res))
	promote := int(TB_GET_PROMOTES(res))

	// Map promotion to piece type
	promoted_piece := -1
	switch promote {
	case 1: promoted_piece = constants.QUEEN
	case 2: promoted_piece = constants.ROOK
	case 3: promoted_piece = constants.BISHOP
	case 4: promoted_piece = constants.KNIGHT
	}

	// Find the actual move in the board's move list to get full details
	move_list: moves.MoveList
	board.generate_all_moves(b, &move_list)

	for i in 0 ..< move_list.count {
		m := move_list.moves[i]
		if m.source == from_sq && m.target == to_sq {
			if promoted_piece == -1 || m.promoted == promoted_piece {
				return wdl_to_score(TB_GET_WDL(res)), m, true
			}
		}
	}

	return 0, moves.Move{}, false
}
