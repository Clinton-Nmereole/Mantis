#!/usr/bin/env python3
"""Small fixed tactical/search regression suite for Mantis."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys


TESTS = [
    {
        "name": "Viridithas game: avoid poisoned knight grab",
        "fen": "r1b1r1k1/ppp2ppp/5n2/1N1qb3/8/3B4/PPP2PPP/R1BQ1RK1 w - - 0 12",
        "depth": 4,
        "banned": {"b5a7"},
    },
]


def bestmove(binary: str, fen: str, depth: int) -> tuple[str, str]:
    command = f"uci\nisready\nposition fen {fen}\ngo depth {depth}\nquit\n"
    output = subprocess.check_output(
        [binary],
        input=command,
        text=True,
        stderr=subprocess.STDOUT,
        timeout=30,
    )
    match = re.search(r"bestmove\s+(\S+)", output)
    if not match:
        raise RuntimeError(f"Could not find bestmove in engine output:\n{output}")
    return match.group(1), output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="./mantis", help="Path to the Mantis binary")
    args = parser.parse_args()

    for test in TESTS:
        move, output = bestmove(args.binary, test["fen"], test["depth"])
        if move in test["banned"]:
            print(f"FAIL {test['name']}: bestmove={move}")
            print(output)
            return 1
        print(f"ok {test['name']}: bestmove={move}")

    print("All tactical regressions passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
