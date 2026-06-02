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
    {
        "name": "Viridithas 2026-05-29: avoid passive bishop retreat",
        "fen": "2bq1rk1/p4ppp/2p2n2/b2p4/1r5B/2NB4/PPP2PPP/R1Q1R1K1 w - - 6 14",
        "depth": 6,
        "banned": {"h4g3"},
    },
    {
        "name": "Viridithas 2026-05-29: avoid knight retreat into pressure",
        "fen": "3q1rk1/pb3ppp/1r6/b1pp3n/8/P1NB2BP/1PP2PP1/R1QR2K1 w - - 1 18",
        "depth": 5,
        "banned": {"c3e2"},
    },
    {
        "name": "Viridithas 2026-05-29: avoid bishop pin tactic",
        "fen": "5rk1/pb2qppp/4r3/b2p3n/2B5/P5BP/1PP1NPP1/R1QR3K w - - 3 21",
        "depth": 4,
        "banned": {"c4b5"},
    },
    {
        "name": "Viridithas 2026-06-01: keep queen defense",
        "fen": "1r3rk1/1p1b3q/3NpP1p/p2pn1p1/8/6P1/PP1QBR1P/2R3K1 b - - 0 25",
        "clock": (180000, 180000, 2000, 2000),
        "expected": {"h7g6"},
        "timeout": 60,
    },
]


def bestmove(binary: str, test: dict) -> tuple[str, str]:
    fen = test["fen"]
    if "clock" in test:
        wtime, btime, winc, binc = test["clock"]
        go = f"go wtime {wtime} btime {btime} winc {winc} binc {binc}"
    else:
        go = f"go depth {test['depth']}"

    command = f"uci\nisready\nposition fen {fen}\n{go}\nquit\n"
    output = subprocess.check_output(
        [binary],
        input=command,
        text=True,
        stderr=subprocess.STDOUT,
        timeout=test.get("timeout", 30),
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
        move, output = bestmove(args.binary, test)
        if "expected" in test and move not in test["expected"]:
            expected = ", ".join(sorted(test["expected"]))
            print(f"FAIL {test['name']}: bestmove={move}, expected one of {{{expected}}}")
            print(output)
            return 1
        if move in test.get("banned", set()):
            print(f"FAIL {test['name']}: bestmove={move}")
            print(output)
            return 1
        print(f"ok {test['name']}: bestmove={move}")

    print("All tactical regressions passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
