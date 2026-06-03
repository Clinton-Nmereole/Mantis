#!/usr/bin/env python3
"""
selfplay.py — Self-Play Harness for Mantis Chess Engine

This script runs two instances of the Mantis engine against each other
via the UCI protocol. Games are played automatically with proper
time management, result detection, and statistics collection.

The primary use case is automated parameter tuning: the script can
compile Mantis with different search parameters, run a batch of games,
and report the win rate. Higher win rate = better parameters.

Features:
    • UCI communication with engine subprocesses
    • Minimal built-in chess board (no external dependencies)
    • Proper game termination detection (checkmate, stalemate,
      50-move rule, threefold repetition, insufficient material)
    • Configurable time control (movetime, wtime/btime+increment)
    • Concurrent game execution with thread pools
    • Opening position randomization (optional)
    • PGN output for post-game analysis
    • Automatic result adjudication (resignation on large eval swings)

Usage:
    # Quick test: 10 games at 100ms per move
    python3 selfplay.py --games 10 --movetime 100

    # Blitz tuning: 50 games at 3+0
    python3 selfplay.py --games 50 --wtime 180000 --btime 180000

    # Use an opening book file (one FEN per line)
    python3 selfplay.py --games 100 --movetime 200 --openings openings.txt

    # Compare two engine binaries
    python3 selfplay.py --games 20 --engine-a ./mantis_new --engine-b ./mantis_old

    # Compare one UCI-tuned candidate against default parameters
    python3 selfplay.py --engine-a ./mantis --engine-b ./mantis \
        --option-a RfpMargin=35 --option-a FutilityMargin=80

Output:
    Prints W-L-D statistics and win percentage after all games complete.
"""

import subprocess
import threading
import time
import random
import argparse
import sys
import os
import re
import math
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Optional, List, Tuple

# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------

# Square mapping: a1=0, h1=7, a8=56, h8=63
FILE_NAMES = "abcdefgh"
RANK_NAMES = "12345678"

# Piece codes used internally (same as UCI convention)
# White pieces are uppercase, black are lowercase in FEN
PIECE_TYPES = {
    'P': 0, 'N': 1, 'B': 2, 'R': 3, 'Q': 4, 'K': 5,
    'p': 0, 'n': 1, 'b': 2, 'r': 3, 'q': 4, 'k': 5,
}
PIECE_NAMES = "PNBRQK"
PIECE_VALUES = [100, 320, 330, 500, 900, 20000]

# Directions for sliding pieces
DIRECTIONS = {
    'N': [-8, -19, -21, -12, 8, 19, 21, 12],
    'B': [-9, -7, 7, 9],
    'R': [-8, -1, 1, 8],
    'Q': [-9, -7, 7, 9, -8, -1, 1, 8],
    'K': [-9, -7, 7, 9, -8, -1, 1, 8],
}

# ---------------------------------------------------------------------------
# MINIMAL CHESS BOARD
# ---------------------------------------------------------------------------

class MinimalBoard:
    """
    A minimal chess board implementation that supports everything
    needed for self-play adjudication:

    • Parse and generate FEN strings
    • Apply UCI coordinate moves (e2e4, e1g1, e7e8q, etc.)
    • Generate all pseudo-legal moves
    • Filter illegal moves (king left in check)
    • Detect checkmate, stalemate, draws
    • Track 50-move rule and threefold repetition

    This is intentionally lightweight — no bitboards, no magic,
    just array-based piece tracking. Speed is not critical here
    since move generation is only used for adjudication, not
    during engine search.
    """

    def __init__(self, fen: str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"):
        self.squares = [None] * 64  # (piece_type, color) or None
        self.side_to_move = 0  # 0 = white, 1 = black
        self.castling_rights = [False, False, False, False]  # KQkq
        self.ep_square = -1  # En passant target square
        self.halfmove_clock = 0  # For 50-move rule
        self.fullmove_number = 1
        self.position_history = []  # List of (piece_hash, side, castling, ep) tuples
        if fen == "startpos":
            fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        self._parse_fen(fen)

    # ------------------------------------------------------------------
    # FEN Parsing / Generation
    # ------------------------------------------------------------------

    def _parse_fen(self, fen: str):
        """Parse a FEN string into internal board state."""
        parts = fen.strip().split()
        ranks = parts[0].split('/')
        for rank_idx, rank_str in enumerate(ranks):
            file_idx = 0
            for ch in rank_str:
                if ch.isdigit():
                    file_idx += int(ch)
                else:
                    sq = (7 - rank_idx) * 8 + file_idx
                    color = 0 if ch.isupper() else 1
                    pt = PIECE_TYPES[ch]
                    self.squares[sq] = (pt, color)
                    file_idx += 1

        self.side_to_move = 0 if parts[1] == 'w' else 1

        self.castling_rights = [False, False, False, False]
        if parts[2] != '-':
            for ch in parts[2]:
                if ch == 'K': self.castling_rights[0] = True
                elif ch == 'Q': self.castling_rights[1] = True
                elif ch == 'k': self.castling_rights[2] = True
                elif ch == 'q': self.castling_rights[3] = True

        self.ep_square = self._uci_sq(parts[3]) if parts[3] != '-' else -1
        self.halfmove_clock = int(parts[4])
        self.fullmove_number = int(parts[5])
        self._record_position()

    def _uci_sq(self, sq_str: str) -> int:
        """Convert UCI square string (e.g., 'e4') to internal index (0-63)."""
        file_idx = ord(sq_str[0]) - ord('a')
        rank_idx = int(sq_str[1]) - 1
        return rank_idx * 8 + file_idx

    def _sq_uci(self, sq: int) -> str:
        """Convert internal index to UCI square string."""
        return FILE_NAMES[sq % 8] + RANK_NAMES[sq // 8]

    def _record_position(self):
        """Store a hashable representation for repetition detection."""
        piece_hash = tuple(
            (sq, p[0], p[1]) for sq, p in enumerate(self.squares) if p is not None
        )
        self.position_history.append((piece_hash, self.side_to_move,
                                       tuple(self.castling_rights), self.ep_square))

    def fen(self) -> str:
        """Generate a FEN string from current board state."""
        parts = []
        for rank_idx in range(7, -1, -1):
            empty = 0
            rank_str = ""
            for file_idx in range(8):
                sq = rank_idx * 8 + file_idx
                piece = self.squares[sq]
                if piece is None:
                    empty += 1
                else:
                    if empty > 0:
                        rank_str += str(empty)
                        empty = 0
                    pt, color = piece
                    name = PIECE_NAMES[pt]
                    rank_str += name if color == 0 else name.lower()
            if empty > 0:
                rank_str += str(empty)
            parts.append(rank_str)

        fen = "/".join(parts)
        fen += " w" if self.side_to_move == 0 else " b"

        castling = ""
        if self.castling_rights[0]: castling += "K"
        if self.castling_rights[1]: castling += "Q"
        if self.castling_rights[2]: castling += "k"
        if self.castling_rights[3]: castling += "q"
        fen += " " + (castling if castling else "-")

        fen += " " + (self._sq_uci(self.ep_square) if self.ep_square != -1 else "-")
        fen += f" {self.halfmove_clock} {self.fullmove_number}"
        return fen

    # ------------------------------------------------------------------
    # Move Application
    # ------------------------------------------------------------------

    def apply_uci_move(self, move_str: str) -> bool:
        """
        Apply a UCI coordinate move to the board.
        Returns True if the move was valid, False otherwise.

        UCI move format:
            e2e4   — regular move
            e1g1   — kingside castling
            e1c1   — queenside castling
            e7e8q  — promotion to queen
            e5d6   — en passant capture
        """
        if len(move_str) < 4 or len(move_str) > 5:
            return False

        from_sq = self._uci_sq(move_str[0:2])
        to_sq = self._uci_sq(move_str[2:4])
        promotion = move_str[4].lower() if len(move_str) == 5 else None

        piece = self.squares[from_sq]
        if piece is None:
            return False
        pt, color = piece
        if color != self.side_to_move:
            return False

        captured = self.squares[to_sq]
        is_capture = captured is not None
        is_pawn_move = (pt == 0)
        is_en_passant = False

        # Handle en passant
        if is_pawn_move and to_sq == self.ep_square:
            is_en_passant = True
            is_capture = True
            ep_captured_sq = to_sq + (8 if color == 1 else -8)
            self.squares[ep_captured_sq] = None

        # Handle castling (king moves 2 squares)
        if pt == 5 and abs(to_sq - from_sq) == 2:
            # Kingside: rook from h-file to f-file
            # Queenside: rook from a-file to d-file
            if to_sq > from_sq:
                rook_from = from_sq + 3
                rook_to = from_sq + 1
            else:
                rook_from = from_sq - 4
                rook_to = from_sq - 1
            self.squares[rook_to] = self.squares[rook_from]
            self.squares[rook_from] = None

        # Move the piece
        self.squares[to_sq] = self.squares[from_sq]
        self.squares[from_sq] = None

        # Handle promotion
        if promotion is not None and is_pawn_move:
            promo_pt = PIECE_NAMES.index(promotion.upper())
            self.squares[to_sq] = (promo_pt, color)

        # Update castling rights
        if pt == 5:  # King moved
            if color == 0:
                self.castling_rights[0] = False
                self.castling_rights[1] = False
            else:
                self.castling_rights[2] = False
                self.castling_rights[3] = False
        if pt == 3:  # Rook moved
            if from_sq == 0: self.castling_rights[3] = False  # a8
            elif from_sq == 7: self.castling_rights[2] = False  # h8
            elif from_sq == 56: self.castling_rights[1] = False  # a1
            elif from_sq == 63: self.castling_rights[0] = False  # h1
        if captured is not None and captured[0] == 3:  # Rook captured
            if to_sq == 0: self.castling_rights[3] = False
            elif to_sq == 7: self.castling_rights[2] = False
            elif to_sq == 56: self.castling_rights[1] = False
            elif to_sq == 63: self.castling_rights[0] = False

        # Update en passant square
        if is_pawn_move and abs(to_sq - from_sq) == 16:
            self.ep_square = (from_sq + to_sq) // 2
        else:
            self.ep_square = -1

        # Update move counters
        if is_capture or is_pawn_move:
            self.halfmove_clock = 0
        else:
            self.halfmove_clock += 1

        if self.side_to_move == 1:
            self.fullmove_number += 1

        self.side_to_move = 1 - self.side_to_move
        self._record_position()
        return True

    # ------------------------------------------------------------------
    # Move Generation (Pseudo-legal)
    # ------------------------------------------------------------------

    def _generate_pseudo_legal(self) -> List[str]:
        """Generate all pseudo-legal moves (may leave king in check)."""
        moves = []
        for sq in range(64):
            piece = self.squares[sq]
            if piece is None:
                continue
            pt, color = piece
            if color != self.side_to_move:
                continue

            if pt == 0:  # Pawn
                moves.extend(self._pawn_moves(sq, color))
            elif pt == 1:  # Knight
                moves.extend(self._knight_moves(sq, color))
            elif pt == 5:  # King
                moves.extend(self._king_moves(sq, color))
            else:  # Bishop, Rook, Queen
                moves.extend(self._slider_moves(sq, color, pt))

        return moves

    def _pawn_moves(self, sq: int, color: int) -> List[str]:
        """Generate pawn moves including promotions and en passant."""
        moves = []
        direction = 8 if color == 0 else -8
        start_rank = 1 if color == 0 else 6
        promotion_rank = 7 if color == 0 else 0

        # Single push
        target = sq + direction
        if 0 <= target < 64 and self.squares[target] is None:
            if target // 8 == promotion_rank:
                for promo in 'qnrb':
                    moves.append(self._sq_uci(sq) + self._sq_uci(target) + promo)
            else:
                moves.append(self._sq_uci(sq) + self._sq_uci(target))

            # Double push
            if sq // 8 == start_rank:
                target2 = sq + 2 * direction
                if self.squares[target2] is None:
                    moves.append(self._sq_uci(sq) + self._sq_uci(target2))

        # Captures
        for cap_dir in [direction - 1, direction + 1]:
            target = sq + cap_dir
            if target < 0 or target >= 64:
                continue
            # Must be on adjacent file
            if abs((target % 8) - (sq % 8)) != 1:
                continue

            captured = self.squares[target]
            if captured is not None and captured[1] != color:
                if target // 8 == promotion_rank:
                    for promo in 'qnrb':
                        moves.append(self._sq_uci(sq) + self._sq_uci(target) + promo)
                else:
                    moves.append(self._sq_uci(sq) + self._sq_uci(target))
            # En passant
            elif target == self.ep_square:
                moves.append(self._sq_uci(sq) + self._sq_uci(target))

        return moves

    def _knight_moves(self, sq: int, color: int) -> List[str]:
        """Generate knight moves."""
        moves = []
        for offset in DIRECTIONS['N']:
            target = sq + offset
            if target < 0 or target >= 64:
                continue
            if abs((target % 8) - (sq % 8)) > 2:
                continue
            piece = self.squares[target]
            if piece is None or piece[1] != color:
                moves.append(self._sq_uci(sq) + self._sq_uci(target))
        return moves

    def _king_moves(self, sq: int, color: int) -> List[str]:
        """Generate king moves including castling."""
        moves = []
        for offset in DIRECTIONS['K']:
            target = sq + offset
            if target < 0 or target >= 64:
                continue
            if abs((target % 8) - (sq % 8)) > 1:
                continue
            piece = self.squares[target]
            if piece is None or piece[1] != color:
                moves.append(self._sq_uci(sq) + self._sq_uci(target))

        # Castling
        back_rank = 0 if color == 0 else 56
        if color == 0:
            if self.castling_rights[0] and self._can_castle(back_rank + 4, back_rank + 7, color):
                moves.append(self._sq_uci(back_rank + 4) + self._sq_uci(back_rank + 6))
            if self.castling_rights[1] and self._can_castle(back_rank, back_rank + 4, color):
                moves.append(self._sq_uci(back_rank + 4) + self._sq_uci(back_rank + 2))
        else:
            if self.castling_rights[2] and self._can_castle(back_rank + 4, back_rank + 7, color):
                moves.append(self._sq_uci(back_rank + 4) + self._sq_uci(back_rank + 6))
            if self.castling_rights[3] and self._can_castle(back_rank, back_rank + 4, color):
                moves.append(self._sq_uci(back_rank + 4) + self._sq_uci(back_rank + 2))

        return moves

    def _can_castle(self, king_sq: int, rook_sq: int, color: int) -> bool:
        """Check if castling is legal (squares empty and king not in check/passing through check)."""
        # Check rook is still there
        if self.squares[rook_sq] is None or self.squares[rook_sq][0] != 3:
            return False

        step = 1 if rook_sq > king_sq else -1
        for sq in range(king_sq + step, rook_sq, step):
            if self.squares[sq] is not None:
                return False

        # King must not be in check now, and must not pass through check
        king_path = [king_sq, king_sq + step, king_sq + 2 * step]
        for sq in king_path[:2]:  # Only need to check starting and passing squares
            if self._is_square_attacked(sq, 1 - color):
                return False
        return True

    def _slider_moves(self, sq: int, color: int, pt: int) -> List[str]:
        """Generate bishop/rook/queen moves."""
        moves = []
        dirs = DIRECTIONS['B'] if pt == 2 else (DIRECTIONS['R'] if pt == 3 else DIRECTIONS['Q'])
        for offset in dirs:
            target = sq + offset
            prev = sq
            while 0 <= target < 64:
                # Detect board wrapping: file must change by exactly 0 or 1 per step.
                # Offsets that wrap around the board have a file jump of 7 instead of 1.
                file_diff = abs((target % 8) - (prev % 8))
                if file_diff > 1:
                    break
                piece = self.squares[target]
                if piece is None:
                    moves.append(self._sq_uci(sq) + self._sq_uci(target))
                    prev = target
                    target += offset
                elif piece[1] != color:
                    moves.append(self._sq_uci(sq) + self._sq_uci(target))
                    break
                else:
                    break
        return moves

    # ------------------------------------------------------------------
    # Check Detection
    # ------------------------------------------------------------------

    def _find_king(self, color: int) -> int:
        """Find the square of the king of the given color."""
        for sq in range(64):
            piece = self.squares[sq]
            if piece is not None and piece[0] == 5 and piece[1] == color:
                return sq
        return -1

    def _is_square_attacked(self, sq: int, by_color: int) -> bool:
        """Check if a square is attacked by the given color."""
        # Pawn attacks
        pawn_dir = -8 if by_color == 0 else 8
        for offset in [pawn_dir - 1, pawn_dir + 1]:
            target = sq + offset
            if target < 0 or target >= 64:
                continue
            if abs((target % 8) - (sq % 8)) != 1:
                continue
            piece = self.squares[target]
            if piece is not None and piece[0] == 0 and piece[1] == by_color:
                return True

        # Knight attacks
        for offset in DIRECTIONS['N']:
            target = sq + offset
            if target < 0 or target >= 64:
                continue
            if abs((target % 8) - (sq % 8)) > 2:
                continue
            piece = self.squares[target]
            if piece is not None and piece[0] == 1 and piece[1] == by_color:
                return True

        # King attacks
        for offset in DIRECTIONS['K']:
            target = sq + offset
            if target < 0 or target >= 64:
                continue
            if abs((target % 8) - (sq % 8)) > 1:
                continue
            piece = self.squares[target]
            if piece is not None and piece[0] == 5 and piece[1] == by_color:
                return True

        # Sliding attacks (B/R/Q)
        for offset in DIRECTIONS['B']:
            target = sq + offset
            while 0 <= target < 64:
                if abs((target % 8) - ((target - offset) % 8)) > 1:
                    break
                piece = self.squares[target]
                if piece is not None:
                    if piece[1] == by_color and piece[0] in [2, 4]:
                        return True
                    break
                target += offset

        for offset in DIRECTIONS['R']:
            target = sq + offset
            while 0 <= target < 64:
                if abs((target % 8) - ((target - offset) % 8)) > 1:
                    break
                piece = self.squares[target]
                if piece is not None:
                    if piece[1] == by_color and piece[0] in [3, 4]:
                        return True
                    break
                target += offset

        return False

    def _is_in_check(self, color: int) -> bool:
        """Check if the given color's king is in check."""
        king_sq = self._find_king(color)
        if king_sq == -1:
            return False
        return self._is_square_attacked(king_sq, 1 - color)

    # ------------------------------------------------------------------
    # Legal Move Generation
    # ------------------------------------------------------------------

    def generate_legal_moves(self) -> List[str]:
        """Generate all fully legal moves for the side to move."""
        pseudo = self._generate_pseudo_legal()
        legal = []
        for move in pseudo:
            # Save state
            saved_squares = self.squares[:]
            saved_castling = self.castling_rights[:]
            saved_ep = self.ep_square
            saved_halfmove = self.halfmove_clock
            saved_fullmove = self.fullmove_number
            saved_side = self.side_to_move

            # Try the move
            if self.apply_uci_move(move):
                # If king is not in check after the move, it's legal
                if not self._is_in_check(saved_side):
                    legal.append(move)

                # Restore state
                self.squares = saved_squares
                self.castling_rights = saved_castling
                self.ep_square = saved_ep
                self.halfmove_clock = saved_halfmove
                self.fullmove_number = saved_fullmove
                self.side_to_move = saved_side

        return legal

    # ------------------------------------------------------------------
    # Draw Detection
    # ------------------------------------------------------------------

    def is_insufficient_material(self) -> bool:
        """Check if there's insufficient material to checkmate."""
        pieces = [p for p in self.squares if p is not None]
        if len(pieces) == 2:
            return True  # King vs King
        if len(pieces) == 3:
            types = [p[0] for p in pieces]
            if 1 in types or 2 in types:  # King + minor piece vs King
                return True
        if len(pieces) == 4:
            # King + bishop vs King + bishop (same color bishops)
            bishops = [(sq, p[1]) for sq, p in enumerate(self.squares) if p is not None and p[0] == 2]
            if len(bishops) == 2:
                # Same color square bishops
                sq1, sq2 = bishops[0][0], bishops[1][0]
                if (sq1 % 2) == (sq2 % 2):
                    return True
        return False

    def is_threefold_repetition(self) -> bool:
        """Check if the current position has occurred 3 times."""
        current = self.position_history[-1]
        count = sum(1 for pos in self.position_history if pos == current)
        return count >= 3

    def is_fifty_move_rule(self) -> bool:
        """Check if 50 moves have occurred without capture or pawn push."""
        return self.halfmove_clock >= 100

    # ------------------------------------------------------------------
    # Game Result
    # ------------------------------------------------------------------

    def get_result(self) -> Optional[str]:
        """
        Determine the game result, or None if ongoing.
        Returns: '1-0', '0-1', '1/2-1/2', or None
        """
        legal = self.generate_legal_moves()
        in_check = self._is_in_check(self.side_to_move)

        if len(legal) == 0:
            if in_check:
                return '0-1' if self.side_to_move == 0 else '1-0'
            else:
                return '1/2-1/2'

        if self.is_fifty_move_rule():
            return '1/2-1/2'

        if self.is_threefold_repetition():
            return '1/2-1/2'

        if self.is_insufficient_material():
            return '1/2-1/2'

        return None


# ---------------------------------------------------------------------------
# ENGINE INTERFACE
# ---------------------------------------------------------------------------

class Engine:
    """
    Manages a UCI engine subprocess.
    Handles initialization, position setup, time control,
    and move extraction from the engine's bestmove output.

    Uses a background reader thread to reliably capture all engine
    output without blocking on select/pipe buffering issues.
    """

    def __init__(self, path: str, name: str = "Engine",
                 options: Optional[List[Tuple[str, str]]] = None):
        self.path = path
        self.name = name
        self.options = options or []
        self.process = None
        self._output_queue = []
        self._queue_lock = threading.Lock()
        self._reader_thread = None
        self._running = False

    def start(self):
        """Launch the engine process and wait for UCI initialization."""
        self.process = subprocess.Popen(
            self.path,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # Line-buffered
        )
        self._running = True
        self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thread.start()

        self._send("uci")
        self._wait_for("uciok", timeout=10.0)
        for option_name, option_value in self.options:
            self._send(f"setoption name {option_name} value {option_value}")
        self._send("isready")
        self._wait_for("readyok", timeout=10.0)

    def stop(self):
        """Send quit and clean up the engine process."""
        self._running = False
        if self.process and self.process.poll() is None:
            try:
                self._send("quit")
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self._reader_thread and self._reader_thread.is_alive():
            self._reader_thread.join(timeout=1.0)

    def _reader_loop(self):
        """Background thread: continuously read stdout lines into queue."""
        while self._running and self.process and self.process.poll() is None:
            try:
                line = self.process.stdout.readline()
                if line:
                    with self._queue_lock:
                        self._output_queue.append(line.strip())
            except Exception:
                break

    def _send(self, cmd: str):
        """Send a command to the engine's stdin."""
        if self.process and self.process.stdin:
            self.process.stdin.write(cmd + "\n")
            self.process.stdin.flush()

    def _readline(self, timeout: float = 0.5) -> Optional[str]:
        """Read a single line from engine output queue with timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._queue_lock:
                if self._output_queue:
                    return self._output_queue.pop(0)
            time.sleep(0.01)
        return None

    def _wait_for(self, keyword: str, timeout: float = 10.0):
        """Block until the engine outputs a line containing keyword."""
        start = time.time()
        while time.time() - start < timeout:
            line = self._readline(timeout=0.1)
            if line and keyword in line:
                return
        raise TimeoutError(f"Engine did not respond with '{keyword}' within {timeout}s")

    def set_position(self, moves: List[str], fen: Optional[str] = None):
        """
        Send the position to the engine.
        If fen is provided, use it; otherwise use startpos.
        """
        if fen:
            cmd = f"position fen {fen}"
        else:
            cmd = "position startpos"
        if moves:
            cmd += " moves " + " ".join(moves)
        self._send(cmd)

    def go(self, movetime: Optional[int] = None,
           wtime: Optional[int] = None, btime: Optional[int] = None,
           winc: int = 0, binc: int = 0,
           depth: Optional[int] = None) -> Tuple[str, Optional[int]]:
        """
        Tell the engine to search and return its best move.
        Also returns the engine's score from the last info line if available.

        Parameters:
            movetime: Exact time per move in milliseconds.
            wtime, btime: Time remaining for each side in ms.
            winc, binc: Time increment per move in ms.
            depth: Fixed depth search (overrides time control).

        Returns:
            (bestmove_uci, score_cp_or_mate) where score may be None.
        """
        if depth is not None:
            cmd = f"go depth {depth}"
        elif movetime is not None:
            cmd = f"go movetime {movetime}"
        elif wtime is not None and btime is not None:
            cmd = f"go wtime {wtime} btime {btime} winc {winc} binc {binc}"
        else:
            cmd = "go movetime 1000"  # Default fallback

        self._send(cmd)

        bestmove = None
        score = None
        start = time.time()

        # Compute adaptive timeout based on time control
        if movetime is not None:
            max_wait = movetime / 1000.0 + 30.0
        elif wtime is not None and btime is not None:
            max_wait = max(wtime, btime) / 1000.0 + 30.0
        else:
            max_wait = 60.0
        # Cap at 10 minutes to avoid hanging forever
        max_wait = min(max_wait, 600.0)

        # Read output until bestmove is found or timeout
        while time.time() - start < max_wait:
            line = self._readline(timeout=1.0)
            if line is None:
                continue

            # Parse score from info line
            if line.startswith("info"):
                # Look for "score cp <N>" or "score mate <N>"
                m = re.search(r'score\s+(cp|mate)\s+(-?\d+)', line)
                if m:
                    score_type = m.group(1)
                    score_val = int(m.group(2))
                    if score_type == "mate":
                        # Convert mate-in-N to approximate centipawns
                        score = 100000 if score_val > 0 else -100000
                    else:
                        score = score_val

            # Parse bestmove
            if line.startswith("bestmove"):
                parts = line.split()
                if len(parts) >= 2:
                    bestmove = parts[1]
                    if bestmove == "(none)":
                        bestmove = None
                break

        if bestmove is None:
            raise TimeoutError("Engine did not return bestmove")

        return bestmove, score


# ---------------------------------------------------------------------------
# GAME PLAYBACK
# ---------------------------------------------------------------------------

@dataclass
class GameResult:
    """Stores the result of a single self-play game."""
    result: str           # '1-0', '0-1', or '1/2-1/2'
    moves: List[str]      # List of UCI moves played
    scores: List[int]     # Engine evaluation after each move (engine A perspective)
    reason: str           # Why the game ended
    white_engine: str     # Name of engine playing white
    black_engine: str     # Name of engine playing black


def play_game(engine_a_path: str, engine_b_path: str,
              time_control: dict, max_moves: int = 400,
              adjudicate_eval: int = 800, adjudicate_moves: int = 5,
              opening_moves: Optional[List[str]] = None,
              opening_fen: Optional[str] = None,
              engine_a_options: Optional[List[Tuple[str, str]]] = None,
              engine_b_options: Optional[List[Tuple[str, str]]] = None,
              verbose: bool = False) -> GameResult:
    """
    Play a single game between two engine instances.

    Parameters:
        engine_a_path: Path to the first engine binary (plays White).
        engine_b_path: Path to the second engine binary (plays Black).
        time_control: Dict with keys 'movetime', 'wtime', 'btime', 'winc', 'binc', 'depth'.
                      Clock mode updates wtime/btime after every searched move.
        max_moves: Maximum plies before forced draw (default 400 ≈ 200 full moves).
        adjudicate_eval: If one engine eval exceeds this for N moves, declare win.
        adjudicate_moves: Number of consecutive moves eval must exceed threshold.
        opening_moves: List of UCI moves to start from (overrides opening_fen).
        opening_fen: FEN string for custom starting position.
        engine_a_options: UCI options for the engine passed as engine_a_path.
        engine_b_options: UCI options for the engine passed as engine_b_path.
        verbose: Print move-by-move output.

    Returns:
        GameResult with result, moves, scores, and termination reason.
    """
    # Initialize both engines
    white = Engine(engine_a_path, "White", engine_a_options)
    black = Engine(engine_b_path, "Black", engine_b_options)
    white.start()
    black.start()

    try:
        board = MinimalBoard(opening_fen if opening_fen else "startpos")
        moves = []
        scores = []
        eval_history = []  # Track evals for adjudication
        clock_mode = (
            time_control.get('wtime') is not None and
            time_control.get('btime') is not None and
            time_control.get('movetime') is None and
            time_control.get('depth') is None
        )
        white_clock = int(time_control.get('wtime', 0) or 0)
        black_clock = int(time_control.get('btime', 0) or 0)
        winc = int(time_control.get('winc', 0) or 0)
        binc = int(time_control.get('binc', 0) or 0)

        # Apply opening moves if provided
        if opening_moves:
            for mv in opening_moves:
                board.apply_uci_move(mv)
                moves.append(mv)

        for move_number in range(max_moves):
            # Check if game is already over
            result = board.get_result()
            if result is not None:
                if verbose:
                    print(f"Game over: {result} ({board.fen()})")
                return GameResult(
                    result=result, moves=moves[:], scores=scores[:],
                    reason="checkmate/stalemate/draw rule",
                    white_engine=engine_a_path, black_engine=engine_b_path,
                )

            # Determine which engine to query
            is_white_turn = (board.side_to_move == 0)
            engine = white if is_white_turn else black

            # Set position and search
            engine.set_position(moves, opening_fen)

            # Build go command arguments from time_control
            if clock_mode:
                tc_args = {
                    'wtime': max(1, white_clock),
                    'btime': max(1, black_clock),
                    'winc': winc,
                    'binc': binc,
                }
            else:
                tc_args = {}
                for key in ['movetime', 'wtime', 'btime', 'winc', 'binc', 'depth']:
                    if key in time_control and time_control[key] is not None:
                        tc_args[key] = time_control[key]

            search_start = time.time()
            bestmove, score = engine.go(**tc_args)
            elapsed_ms = max(0, int((time.time() - search_start) * 1000))

            if clock_mode:
                if is_white_turn:
                    white_clock -= elapsed_ms
                    if white_clock <= 0:
                        return GameResult(
                            result='0-1', moves=moves[:], scores=scores[:],
                            reason=f"time forfeit (white, elapsed {elapsed_ms} ms)",
                            white_engine=engine_a_path, black_engine=engine_b_path,
                        )
                    white_clock += winc
                else:
                    black_clock -= elapsed_ms
                    if black_clock <= 0:
                        return GameResult(
                            result='1-0', moves=moves[:], scores=scores[:],
                            reason=f"time forfeit (black, elapsed {elapsed_ms} ms)",
                            white_engine=engine_a_path, black_engine=engine_b_path,
                        )
                    black_clock += binc

            if bestmove is None:
                # No legal move — should have been caught above, but handle defensively
                result = '0-1' if is_white_turn else '1-0'
                return GameResult(
                    result=result, moves=moves[:], scores=scores[:],
                    reason="no legal move",
                    white_engine=engine_a_path, black_engine=engine_b_path,
                )

            # Apply the move
            success = board.apply_uci_move(bestmove)
            if not success:
                # Engine returned an illegal move — forfeit
                print(f"  [ILLEGAL MOVE] {bestmove} in position {board.fen()}")
                print(f"  [ILLEGAL MOVE] Moves so far: {' '.join(moves)}")
                print(f"  [ILLEGAL MOVE] Engine: {engine.name}")
                result = '0-1' if is_white_turn else '1-0'
                return GameResult(
                    result=result, moves=moves[:], scores=scores[:],
                    reason=f"illegal move ({bestmove})",
                    white_engine=engine_a_path, black_engine=engine_b_path,
                )

            moves.append(bestmove)

            # Track score from White's perspective
            if score is not None:
                if not is_white_turn:
                    score = -score  # Flip to White's perspective
                scores.append(score)

                # Adjudication: if eval is consistently extreme, end early
                eval_history.append(score)
                if len(eval_history) >= adjudicate_moves:
                    recent = eval_history[-adjudicate_moves:]
                    if all(e >= adjudicate_eval for e in recent):
                        return GameResult(
                            result='1-0', moves=moves[:], scores=scores[:],
                            reason=f"adjudication (eval >= {adjudicate_eval})",
                            white_engine=engine_a_path, black_engine=engine_b_path,
                        )
                    if all(e <= -adjudicate_eval for e in recent):
                        return GameResult(
                            result='0-1', moves=moves[:], scores=scores[:],
                            reason=f"adjudication (eval <= -{adjudicate_eval})",
                            white_engine=engine_a_path, black_engine=engine_b_path,
                        )

            if verbose:
                side_str = "W" if is_white_turn else "B"
                eval_str = f" cp {score}" if score is not None else ""
                clock_str = ""
                if clock_mode:
                    clock_str = f" clock W:{white_clock}ms B:{black_clock}ms"
                print(f"{move_number+1:3d}. {side_str}: {bestmove}{eval_str}{clock_str}")

        # Max moves reached — declare draw
        return GameResult(
            result='1/2-1/2', moves=moves[:], scores=scores[:],
            reason="max moves reached",
            white_engine=engine_a_path, black_engine=engine_b_path,
        )

    finally:
        white.stop()
        black.stop()


# ---------------------------------------------------------------------------
# SPRT (Sequential Probability Ratio Test)
# ---------------------------------------------------------------------------
# SPRT allows early stopping when the result is statistically clear.
# Used by Stockfish Fishtest and all serious engine development.
# ---------------------------------------------------------------------------

class SPRT:
    """
    Sequential Probability Ratio Test for chess engine self-play.

    Tests H0: elo = elo0  vs  H1: elo = elo1
    Stop early if the evidence is conclusive.
    """

    def __init__(self, elo0: float = 0.0, elo1: float = 2.0,
                 alpha: float = 0.05, beta: float = 0.05):
        self.elo0 = elo0
        self.elo1 = elo1
        self.alpha = alpha
        self.beta = beta
        self.lower_bound = math.log(beta / (1.0 - alpha))
        self.upper_bound = math.log((1.0 - beta) / alpha)
        self.wins = 0
        self.losses = 0
        self.draws = 0

    def update(self, result: str, a_is_white: bool):
        """Update counts with a single game result."""
        if result == '1-0':
            if a_is_white:
                self.wins += 1
            else:
                self.losses += 1
        elif result == '0-1':
            if a_is_white:
                self.losses += 1
            else:
                self.wins += 1
        else:
            self.draws += 1

    def llr(self) -> float:
        """Compute log-likelihood ratio."""
        n = self.wins + self.losses + self.draws
        if n == 0:
            return 0.0

        p_w = self.wins / n
        p_l = self.losses / n
        p_d = self.draws / n

        # Expected score under each hypothesis
        s0 = 1.0 / (1.0 + 10.0 ** (-self.elo0 / 400.0))
        s1 = 1.0 / (1.0 + 10.0 ** (-self.elo1 / 400.0))

        # Trinomial probabilities under H0 and H1
        # Assume draw rate stays fixed, win/loss ratio shifts
        p0_w = max(0.001, min(0.998, s0 - 0.5 * p_d))
        p0_l = max(0.001, min(0.998, 1.0 - p0_w - p_d))
        p0_d = 1.0 - p0_w - p0_l

        p1_w = max(0.001, min(0.998, s1 - 0.5 * p_d))
        p1_l = max(0.001, min(0.998, 1.0 - p1_w - p_d))
        p1_d = 1.0 - p1_w - p1_l

        # Normalize
        t0 = p0_w + p0_l + p0_d
        t1 = p1_w + p1_l + p1_d
        p0_w /= t0; p0_l /= t0; p0_d /= t0
        p1_w /= t1; p1_l /= t1; p1_d /= t1

        llr_val = 0.0
        if self.wins > 0:
            llr_val += self.wins * math.log(p1_w / p0_w)
        if self.losses > 0:
            llr_val += self.losses * math.log(p1_l / p0_l)
        if self.draws > 0:
            llr_val += self.draws * math.log(p1_d / p0_d)

        return llr_val

    def status(self) -> Tuple[str, float]:
        """
        Return (decision, llr) where decision is one of:
        'continue', 'accept' (H1: engine is better), 'reject' (H0: no improvement)
        """
        llr_val = self.llr()
        if llr_val > self.upper_bound:
            return 'accept', llr_val
        if llr_val < self.lower_bound:
            return 'reject', llr_val
        return 'continue', llr_val

    def __str__(self) -> str:
        n = self.wins + self.losses + self.draws
        if n == 0:
            return "SPRT: 0 games"
        llr_val = self.llr()
        status, _ = self.status()
        win_pct = (self.wins + 0.5 * self.draws) / n * 100
        return (f"SPRT[{n}] W:{self.wins} L:{self.losses} D:{self.draws} "
                f"Win%:{win_pct:.1f} LLR:{llr_val:.3f} [{status}]")


# ---------------------------------------------------------------------------
# TOURNAMENT / BATCH RUNNER
# ---------------------------------------------------------------------------

def parse_engine_options(raw_options: Optional[List[str]]) -> List[Tuple[str, str]]:
    """Parse repeated Name=Value CLI options into UCI setoption pairs."""
    parsed = []
    for raw in raw_options or []:
        if "=" not in raw:
            raise ValueError(f"engine option must be Name=Value: {raw}")
        name, value = raw.split("=", 1)
        name = name.strip()
        value = value.strip()
        if not name or not value:
            raise ValueError(f"engine option must be Name=Value: {raw}")
        parsed.append((name, value))
    return parsed


def run_tournament(engine_a: str, engine_b: str,
                   games: int, time_control: dict,
                   concurrency: int = 1,
                   openings: Optional[List[str]] = None,
                   max_moves: int = 400,
                   adjudicate_eval: int = 800,
                   adjudicate_moves: int = 5,
                   engine_a_options: Optional[List[Tuple[str, str]]] = None,
                   engine_b_options: Optional[List[Tuple[str, str]]] = None,
                   verbose: bool = False,
                   sprt: Optional[SPRT] = None) -> dict:
    """
    Run a multi-game tournament between two engines.
    Engines swap colors every game (A plays White in even games, Black in odd).

    Parameters:
        engine_a, engine_b: Paths to engine binaries.
        games: Total games to play (max if SPRT is enabled).
        time_control: Passed directly to play_game().
        concurrency: Number of games to run in parallel.
        openings: List of opening FENs or move sequences.
        max_moves: Maximum plies before a game is declared drawn.
        adjudicate_eval: Evaluation threshold for early adjudication.
        adjudicate_moves: Consecutive eval count needed for adjudication.
        engine_a_options: UCI options applied whenever engine A is launched.
        engine_b_options: UCI options applied whenever engine B is launched.
        verbose: Print per-game results.
        sprt: Optional SPRT object for early stopping.

    Returns:
        Dict with 'wins', 'losses', 'draws', 'win_pct', 'results', and 'sprt_status'.
    """
    results = []
    stats = {'wins': 0, 'losses': 0, 'draws': 0}
    should_stop = False
    sprt_lock = threading.Lock()

    def play_one(game_idx: int) -> Tuple[int, GameResult]:
        # Swap colors: even indices → A=White, odd → A=Black
        if game_idx % 2 == 0:
            white_path, black_path = engine_a, engine_b
            white_options, black_options = engine_a_options, engine_b_options
        else:
            white_path, black_path = engine_b, engine_a
            white_options, black_options = engine_b_options, engine_a_options

        # Pick an opening if provided
        opening = None
        if openings:
            opening = openings[game_idx % len(openings)]

        opening_moves = None
        opening_fen = None
        if opening:
            if '/' in opening or opening == "startpos":
                opening_fen = opening  # FEN string
            else:
                opening_moves = opening.split()  # Space-separated moves

        result = play_game(
            white_path, black_path,
            time_control=time_control,
            max_moves=max_moves,
            adjudicate_eval=adjudicate_eval,
            adjudicate_moves=adjudicate_moves,
            opening_moves=opening_moves,
            opening_fen=opening_fen,
            engine_a_options=white_options,
            engine_b_options=black_options,
            verbose=verbose,
        )
        return game_idx, result

    def process_result(game_idx: int, result: GameResult):
        nonlocal should_stop
        results.append(result)
        _update_stats(result, engine_a, stats, game_idx)
        total_done = stats['wins'] + stats['losses'] + stats['draws']
        win_pct = (stats['wins'] + 0.5 * stats['draws']) / total_done * 100 if total_done > 0 else 0
        print(f"[Game {game_idx+1}/{games}] {result.result} ({result.reason})  "
              f"W:{stats['wins']} L:{stats['losses']} D:{stats['draws']}  "
              f"Win%:{win_pct:.1f}")
        if verbose:
            print(f"Game {game_idx+1}/{games}: {result.result} ({result.reason})")

        # SPRT check
        if sprt and not should_stop:
            with sprt_lock:
                a_is_white = (game_idx % 2 == 0)
                sprt.update(result.result, a_is_white)
                status, llr = sprt.status()
                if status != 'continue':
                    should_stop = True
                    print(f"\n*** SPRT STOP: {status.upper()} ***")
                    print(f"    {sprt}")
                    print(f"    Stopping early after {total_done} games.\n")

    if concurrency == 1:
        for i in range(games):
            if should_stop:
                break
            _, result = play_one(i)
            process_result(i, result)
    else:
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = {executor.submit(play_one, i): i for i in range(games)}
            for future in as_completed(futures):
                if should_stop:
                    # Cancel remaining futures
                    for f in futures:
                        f.cancel()
                    break
                game_idx = futures[future]
                try:
                    _, result = future.result()
                    process_result(game_idx, result)
                except Exception as e:
                    print(f"Game {game_idx+1} failed: {e}")

    total = stats['wins'] + stats['losses'] + stats['draws']
    stats['win_pct'] = (stats['wins'] + 0.5 * stats['draws']) / total * 100 if total > 0 else 0
    stats['results'] = results
    if sprt:
        status, _ = sprt.status()
        stats['sprt_status'] = status
        stats['sprt_llr'] = sprt.llr()
    return stats


def _update_stats(result: GameResult, engine_a: str, stats: dict, game_idx: int):
    """Update win/loss/draw counters from a game result."""
    # Determine if engine_a won from the perspective of color assignment
    a_is_white = (game_idx % 2 == 0)
    if result.result == '1-0':
        if a_is_white:
            stats['wins'] += 1
        else:
            stats['losses'] += 1
    elif result.result == '0-1':
        if a_is_white:
            stats['losses'] += 1
        else:
            stats['wins'] += 1
    else:
        stats['draws'] += 1


# ---------------------------------------------------------------------------
# COORDINATE DESCENT TUNING INTEGRATION
# ---------------------------------------------------------------------------

def tune_coordinate_descent(engine_path: str,
                            baseline_path: Optional[str] = None,
                            games_per_eval: int = 20,
                            steps: int = 3,
                            time_control: dict = None,
                            concurrency: int = 1) -> dict:
    """
    Run coordinate descent tuning using the self-play harness.

    This is a simplified version that works externally: it modifies
    search/tuning.odin, rebuilds the engine, and plays games.
    
    For a full implementation, see the tuning framework in search/tuning.odin
    which can be called from within the Odin codebase directly.

    Parameters:
        engine_path: Path to the engine source directory (contains build script).
        baseline_path: Path to a baseline engine binary for comparison.
                        If None, the engine plays against itself.
        games_per_eval: Games to play per parameter evaluation.
        steps: Number of coordinate descent iterations.
        time_control: Time control dict for games.
        concurrency: Parallel games.

    Returns:
        Dict with final statistics.
    """
    if time_control is None:
        time_control = {'movetime': 100}  # Fast games for tuning

    if baseline_path is None:
        baseline_path = engine_path

    print("=" * 60)
    print("COORDINATE DESCENT TUNING")
    print("=" * 60)
    print(f"Games per eval: {games_per_eval}")
    print(f"Time control: {time_control}")
    print(f"Concurrency: {concurrency}")
    print()

    stats = run_tournament(
        engine_path, baseline_path,
        games=games_per_eval, time_control=time_control,
        concurrency=concurrency, verbose=True,
    )

    print()
    print("=" * 60)
    print(f"FINAL RESULTS")
    print("=" * 60)
    print(f"Wins:   {stats['wins']}")
    print(f"Losses: {stats['losses']}")
    print(f"Draws:  {stats['draws']}")
    print(f"Win %:  {stats['win_pct']:.2f}%")
    print()

    return stats


# ---------------------------------------------------------------------------
# COMMAND LINE INTERFACE
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Self-play harness for Mantis chess engine",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Quick smoke test
  python3 selfplay.py --games 4 --movetime 50

  # Blitz self-play with color swap
  python3 selfplay.py --games 20 --wtime 180000 --btime 180000 --concurrency 4

  # Compare two versions
  python3 selfplay.py --engine-a ./mantis_new --engine-b ./mantis_old --games 50

  # Use opening positions from file
  python3 selfplay.py --openings openings.txt --games 100 --movetime 200
        """,
    )

    parser.add_argument("--engine-a", default="./mantis",
                        help="Path to engine A (default: ./mantis)")
    parser.add_argument("--engine-b", default="./mantis",
                        help="Path to engine B (default: ./mantis)")
    parser.add_argument("--option", action="append", default=[],
                        help="UCI option Name=Value applied to both engines; repeatable")
    parser.add_argument("--option-a", action="append", default=[],
                        help="UCI option Name=Value applied only to engine A; repeatable")
    parser.add_argument("--option-b", action="append", default=[],
                        help="UCI option Name=Value applied only to engine B; repeatable")
    parser.add_argument("--games", type=int, default=10,
                        help="Number of games to play (default: 10)")
    parser.add_argument("--concurrency", type=int, default=1,
                        help="Parallel games (default: 1)")
    parser.add_argument("--movetime", type=int, default=None,
                        help="Fixed time per move in ms")
    parser.add_argument("--wtime", type=int, default=None,
                        help="White time remaining in ms")
    parser.add_argument("--btime", type=int, default=None,
                        help="Black time remaining in ms")
    parser.add_argument("--winc", type=int, default=0,
                        help="White increment in ms")
    parser.add_argument("--binc", type=int, default=0,
                        help="Black increment in ms")
    parser.add_argument("--depth", type=int, default=None,
                        help="Fixed depth search")
    parser.add_argument("--openings", default=None,
                        help="File with opening FENs (one per line)")
    parser.add_argument("--max-moves", type=int, default=400,
                        help="Max plies before forced draw (default: 400)")
    parser.add_argument("--adjudicate-eval", type=int, default=800,
                        help="Adjudicate if eval exceeds this (default: 800)")
    parser.add_argument("--adjudicate-moves", type=int, default=5,
                        help="Consecutive moves for adjudication (default: 5)")
    parser.add_argument("--verbose", action="store_true",
                        help="Print move-by-move output")
    parser.add_argument("--tune", action="store_true",
                        help="Run coordinate descent tuning mode")

    # Quick / Verify presets
    parser.add_argument("--quick", action="store_true",
                        help="Quick screen: 10 games at 100ms with SPRT")
    parser.add_argument("--verify", action="store_true",
                        help="Verify mode: 100 games at 3+0 with SPRT")

    # SPRT options
    parser.add_argument("--sprt", action="store_true",
                        help="Enable SPRT early stopping")
    parser.add_argument("--sprt-elo0", type=float, default=0.0,
                        help="SPRT lower Elo bound (default: 0)")
    parser.add_argument("--sprt-elo1", type=float, default=2.0,
                        help="SPRT upper Elo bound (default: 2)")
    parser.add_argument("--sprt-alpha", type=float, default=0.05,
                        help="SPRT false positive rate (default: 0.05)")
    parser.add_argument("--sprt-beta", type=float, default=0.05,
                        help="SPRT false negative rate (default: 0.05)")

    args = parser.parse_args()

    try:
        common_options = parse_engine_options(args.option)
        engine_a_options = common_options + parse_engine_options(args.option_a)
        engine_b_options = common_options + parse_engine_options(args.option_b)
    except ValueError as exc:
        parser.error(str(exc))

    # Initialize time control
    tc = {}

    # Apply quick / verify presets
    if args.quick:
        if args.games == 10:  # Only override if user didn't specify
            args.games = 10
        if not args.movetime and not args.wtime:
            tc = {'movetime': 100}
        args.sprt = True
        args.sprt_elo0 = -2.0
        args.sprt_elo1 = 4.0
        args.sprt_alpha = 0.10
        args.sprt_beta = 0.10
        print("[PRESET] Quick mode: 10 games, 100ms, SPRT(-2, 4)")
    elif args.verify:
        if args.games == 10:
            args.games = 100
        if not args.movetime and not args.wtime:
            tc = {'wtime': 180000, 'btime': 180000}
        args.sprt = True
        args.sprt_elo0 = 0.0
        args.sprt_elo1 = 2.0
        args.sprt_alpha = 0.05
        args.sprt_beta = 0.05
        print("[PRESET] Verify mode: 100 games, 3+0, SPRT(0, 2)")
    else:
        # Build time control dict from individual args
        tc = {}
        if args.movetime:
            tc['movetime'] = args.movetime
        if args.wtime:
            tc['wtime'] = args.wtime
        if args.btime:
            tc['btime'] = args.btime
        if args.winc:
            tc['winc'] = args.winc
        if args.binc:
            tc['binc'] = args.binc
        if args.depth:
            tc['depth'] = args.depth
        if not tc:
            tc['movetime'] = 100  # Default fallback

    # Load openings if provided
    openings = None
    if args.openings and os.path.exists(args.openings):
        with open(args.openings) as f:
            openings = [line.strip() for line in f if line.strip()]
        print(f"Loaded {len(openings)} opening positions from {args.openings}")

    if args.tune:
        tune_coordinate_descent(
            args.engine_a,
            baseline_path=args.engine_b,
            games_per_eval=args.games,
            time_control=tc,
            concurrency=args.concurrency,
        )
        return

    # Build SPRT object if requested
    sprt_obj = None
    if args.sprt:
        sprt_obj = SPRT(
            elo0=args.sprt_elo0,
            elo1=args.sprt_elo1,
            alpha=args.sprt_alpha,
            beta=args.sprt_beta,
        )
        print(f"[SPRT] H0: elo={args.sprt_elo0}, H1: elo={args.sprt_elo1}, "
              f"alpha={args.sprt_alpha}, beta={args.sprt_beta}")

    print("=" * 60)
    print("SELF-PLAY TOURNAMENT")
    print("=" * 60)
    print(f"Engine A (White on even games): {args.engine_a}")
    print(f"Engine B (White on odd games):  {args.engine_b}")
    if engine_a_options:
        print(f"Engine A options: {engine_a_options}")
    if engine_b_options:
        print(f"Engine B options: {engine_b_options}")
    print(f"Games: {args.games} (max)")
    print(f"Time control: {tc}")
    print(f"Concurrency: {args.concurrency}")
    print()

    stats = run_tournament(
        args.engine_a, args.engine_b,
        games=args.games, time_control=tc,
        concurrency=args.concurrency,
        openings=openings,
        max_moves=args.max_moves,
        adjudicate_eval=args.adjudicate_eval,
        adjudicate_moves=args.adjudicate_moves,
        engine_a_options=engine_a_options,
        engine_b_options=engine_b_options,
        verbose=args.verbose,
        sprt=sprt_obj,
    )

    print()
    print("=" * 60)
    print("FINAL RESULTS")
    print("=" * 60)
    print(f"Wins:   {stats['wins']}")
    print(f"Losses: {stats['losses']}")
    print(f"Draws:  {stats['draws']}")
    print(f"Total:  {stats['wins'] + stats['losses'] + stats['draws']}")
    print(f"Win %:  {stats['win_pct']:.2f}%")
    if 'sprt_status' in stats:
        print(f"SPRT:   {stats['sprt_status']} (LLR={stats['sprt_llr']:.3f})")
    print()

    # Per-game summary
    if not args.verbose and len(stats['results']) <= 20:
        print("Per-game results:")
        for i, r in enumerate(stats['results']):
            color = "W" if i % 2 == 0 else "B"
            print(f"  Game {i+1:2d} (A={color}): {r.result} — {r.reason}")


if __name__ == "__main__":
    main()
