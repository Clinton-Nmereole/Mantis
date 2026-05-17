#!/usr/bin/env python3
"""
selfplay_chess.py — Self-Play Harness for Mantis (python-chess backend)

This is a drop-in replacement for selfplay.py that uses python-chess
instead of the built-in MinimalBoard. Everything else (engine UCI
communication, tournament logic, SPRT, CLI) is imported from selfplay.py.

Usage: exactly the same as selfplay.py:
    python3 selfplay_chess.py --games 20 --movetime 200 --concurrency 1
"""

import chess
from typing import Optional, List

# Import the entire selfplay harness
from selfplay import (
    Engine, play_game, run_tournament, SPRT,
    GameResult, tune_coordinate_descent,
    main as _original_main,
)

# ---------------------------------------------------------------------------
# PYTHON-CHESS BOARD WRAPPER (drop-in replacement for MinimalBoard)
# ---------------------------------------------------------------------------

class MinimalBoard:
    """
    Wrapper around python-chess.Board that mimics the interface of
    the original MinimalBoard used by selfplay.py.
    """

    def __init__(self, fen: str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"):
        if fen == "startpos":
            self.board = chess.Board()
        else:
            self.board = chess.Board(fen)

    # --- Properties expected by play_game() ---

    @property
    def side_to_move(self) -> int:
        """0 = White, 1 = Black."""
        return 0 if self.board.turn == chess.WHITE else 1

    # --- Core methods ---

    def apply_uci_move(self, move_str: str) -> bool:
        """Apply a UCI move if legal. Returns True on success."""
        try:
            move = chess.Move.from_uci(move_str)
            if move in self.board.legal_moves:
                self.board.push(move)
                return True
            return False
        except Exception:
            return False

    def fen(self) -> str:
        """Return the FEN string of the current position."""
        return self.board.fen()

    def generate_legal_moves(self) -> List[str]:
        """Return all legal moves in UCI notation."""
        return [move.uci() for move in self.board.legal_moves]

    def get_result(self) -> Optional[str]:
        """
        Determine the game result, or None if ongoing.
        Returns: '1-0', '0-1', '1/2-1/2', or None
        """
        # Terminal conditions — check in order of priority

        if self.board.is_checkmate():
            return '0-1' if self.board.turn == chess.WHITE else '1-0'

        if self.board.is_stalemate():
            return '1/2-1/2'

        # 50-move rule (100 half-moves)
        if self.board.is_fifty_moves():
            return '1/2-1/2'

        # Threefold repetition
        if self.board.is_repetition(3):
            return '1/2-1/2'

        # Insufficient material
        if self.board.is_insufficient_material():
            return '1/2-1/2'

        # Fivefold repetition / 75-move rule (automatic draw)
        if self.board.is_fivefold_repetition() or self.board.is_seventyfive_moves():
            return '1/2-1/2'

        return None


# ---------------------------------------------------------------------------
# CLI ENTRY POINT
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    _original_main()
