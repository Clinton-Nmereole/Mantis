#!/usr/bin/env python3
"""Perft correctness checks for Mantis.

Compares Mantis CLI perft output against python-chess on a small fixed suite
and a deterministic set of random legal positions.
"""

from __future__ import annotations

import argparse
import random
import re
import subprocess
import sys

import chess


KNOWN_FENS = [
    chess.STARTING_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/2pPN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
]


def py_perft(board: chess.Board, depth: int) -> int:
    if depth == 0:
        return 1

    nodes = 0
    for move in board.legal_moves:
        board.push(move)
        nodes += py_perft(board, depth - 1)
        board.pop()
    return nodes


def mantis_perft(binary: str, fen: str, depth: int) -> int:
    output = subprocess.check_output(
        [binary, "perft", str(depth), "fen", fen],
        text=True,
        stderr=subprocess.STDOUT,
    )
    match = re.search(r"Nodes: (\d+)", output)
    if not match:
        raise RuntimeError(f"Could not find Nodes line in Mantis output:\n{output}")
    return int(match.group(1))


def random_fens(count: int, seed: int) -> list[str]:
    rng = random.Random(seed)
    fens: list[str] = []

    for _ in range(count):
        board = chess.Board()
        for _ply in range(rng.randint(0, 50)):
            moves = list(board.legal_moves)
            if not moves or board.is_game_over(claim_draw=False):
                break
            board.push(rng.choice(moves))
        fens.append(board.fen())

    return fens


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="./mantis", help="Path to the Mantis binary")
    parser.add_argument("--random", type=int, default=24, help="Number of random positions")
    parser.add_argument("--seed", type=int, default=7, help="Random position seed")
    args = parser.parse_args()

    fens = [*KNOWN_FENS, *random_fens(args.random, args.seed)]

    for index, fen in enumerate(fens, 1):
        board = chess.Board(fen)
        depth = 3 if board.legal_moves.count() <= 35 else 2
        expected = py_perft(board, depth)
        actual = mantis_perft(args.binary, fen, depth)
        status = "ok" if expected == actual else "FAIL"
        print(f"{index:02d} depth={depth} {status} expected={expected} actual={actual} fen={fen}")
        if expected != actual:
            return 1

    print("All perft comparisons passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
