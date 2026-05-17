#!/usr/bin/env python3
"""
debug_divergence.py — Find the exact move where Mantis's board diverges.

Usage:
    python3 debug_divergence.py          # Play random games until divergence
    python3 debug_divergence.py MOVES    # Replay a specific move sequence
"""

import subprocess
import time
import chess
import sys
from typing import Optional

ENGINE = "./mantis"
MOVETIME_MS = 200
MAX_MOVES = 200


class Engine:
    def __init__(self, path: str):
        self.proc = subprocess.Popen(
            path,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._send("uci")
        self._wait_for("uciok")
        self._send("isready")
        self._wait_for("readyok")

    def _send(self, cmd: str):
        assert self.proc.stdin is not None
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def _readline(self, timeout: float = 0.5) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if line:
                return line.strip()
            time.sleep(0.01)
        return ""

    def _wait_for(self, keyword: str, timeout: float = 5.0):
        start = time.time()
        while time.time() - start < timeout:
            line = self._readline(timeout=0.1)
            if keyword in line:
                return
        raise TimeoutError(f"Did not see '{keyword}'")

    def set_position(self, moves: list[str]):
        cmd = "position startpos"
        if moves:
            cmd += " moves " + " ".join(moves)
        self._send(cmd)

    def get_engine_fen(self) -> str:
        """Send 'd' and parse the FEN line."""
        self._send("d")
        fen = None
        start = time.time()
        while time.time() - start < 2.0:
            line = self._readline(timeout=0.1)
            if line.startswith("FEN:"):
                fen = line[4:].strip()
                break
        if fen is None:
            raise RuntimeError("Engine did not respond with FEN")
        return fen

    def get_bestmove(self) -> Optional[str]:
        self._send(f"go movetime {MOVETIME_MS}")
        bestmove = None
        start = time.time()
        while time.time() - start < (MOVETIME_MS / 1000.0 + 10.0):
            line = self._readline(timeout=0.5)
            if line.startswith("bestmove"):
                parts = line.split()
                if len(parts) >= 2:
                    bestmove = parts[1]
                    if bestmove == "(none)":
                        bestmove = None
                break
        return bestmove

    def quit(self):
        self._send("quit")
        try:
            self.proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def boards_equal(engine_fen: str, py_board: chess.Board) -> bool:
    """Compare engine FEN against python-chess board semantically.
    Ignores halfmove/fullmove counters.
    """
    try:
        engine_board = chess.Board(engine_fen)
    except ValueError:
        return False

    # Compare piece placement, side, castling, and EP square
    return (
        engine_board.piece_map() == py_board.piece_map() and
        engine_board.turn == py_board.turn and
        engine_board.castling_rights == py_board.castling_rights and
        engine_board.ep_square == py_board.ep_square
    )


def replay_sequence(moves_str: str) -> int:
    """Replay a specific move sequence and check for divergence at each ply."""
    engine = Engine(ENGINE)
    board = chess.Board()
    moves = moves_str.split()

    try:
        for ply, move_uci in enumerate(moves):
            engine.set_position(moves[:ply])
            engine_fen = engine.get_engine_fen()

            if not boards_equal(engine_fen, board):
                print("=" * 60)
                print(f"DIVERGENCE AT PLY {ply}")
                print(f"Last move applied: {moves[ply-1] if ply > 0 else '(none)'}")
                print(f"Move history so far: {' '.join(moves[:ply])}")
                print(f"Engine FEN: {engine_fen}")
                print(f"Python FEN: {board.fen()}")
                print("=" * 60)
                return 1

            print(f"Ply {ply}: {' '.join(moves[:ply]) or '(startpos)'} -> OK")

            move = chess.Move.from_uci(move_uci)
            if move not in board.legal_moves:
                print(f"ILLEGAL MOVE at ply {ply+1}: {move_uci}")
                print(f"Position: {board.fen()}")
                return 1
            board.push(move)

        # Final check after all moves
        engine.set_position(moves)
        engine_fen = engine.get_engine_fen()
        if not boards_equal(engine_fen, board):
            print("=" * 60)
            print(f"DIVERGENCE AFTER ALL {len(moves)} MOVES")
            print(f"Engine FEN: {engine_fen}")
            print(f"Python FEN: {board.fen()}")
            print("=" * 60)
            return 1

        print(f"\nAll {len(moves)} moves replayed successfully. No divergence.")
        return 0

    finally:
        engine.quit()


def play_one_game(game_idx: int) -> int:
    """Play one game, return 0 if OK, 1 on divergence or illegal move."""
    engine = Engine(ENGINE)
    board = chess.Board()
    moves: list[str] = []

    try:
        for ply in range(MAX_MOVES):
            if board.is_game_over():
                print(f"Game {game_idx}: Over — {board.result()} after {ply} plies")
                return 0

            engine.set_position(moves)
            engine_fen = engine.get_engine_fen()

            if not boards_equal(engine_fen, board):
                print("=" * 60)
                print(f"BOARD DIVERGENCE DETECTED in game {game_idx}!")
                print(f"Ply: {ply + 1}")
                print(f"Side to move: {'White' if board.turn == chess.WHITE else 'Black'}")
                print(f"Move history: {' '.join(moves)}")
                print()
                print(f"Engine FEN: {engine_fen}")
                print(f"Python FEN: {board.fen()}")
                print("=" * 60)
                return 1

            bestmove = engine.get_bestmove()
            if bestmove is None:
                print(f"Game {game_idx}: No bestmove at ply {ply}")
                return 0

            move = chess.Move.from_uci(bestmove)
            if move not in board.legal_moves:
                print("=" * 60)
                print(f"ILLEGAL MOVE in game {game_idx}: {bestmove}")
                print(f"Position: {board.fen()}")
                print(f"Move history: {' '.join(moves)}")
                print("=" * 60)
                return 1

            board.push(move)
            moves.append(bestmove)

        print(f"Game {game_idx}: Reached max moves ({MAX_MOVES})")
        return 0

    finally:
        engine.quit()


def main():
    if len(sys.argv) > 1:
        # Replay specific move sequence from command line
        return replay_sequence(sys.argv[1])

    game_idx = 0
    for game_idx in range(1, 21):
        print(f"\n--- Starting game {game_idx} ---")
        result = play_one_game(game_idx)
        if result != 0:
            return result

    print(f"\nAll {game_idx} games completed. No divergence or illegal moves detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
