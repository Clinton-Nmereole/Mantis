#!/usr/bin/env python3
"""Summarize known oracle losses from a compare_candidates CSV."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import compare_candidates


def load_compare_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def has_oracle_columns(rows: list[dict[str, str]]) -> bool:
    if not rows:
        return True
    required = {"base_oracle_loss_cp", "cand_oracle_loss_cp"}
    return required.issubset(rows[0])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compare_csv", type=Path, help="CSV produced by compare_candidates.py")
    parser.add_argument(
        "--oracle-csv",
        type=Path,
        help="Optional oracle CSV to annotate compare rows that do not already include oracle columns",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=10,
        help="Rows per improvements/regressions/remaining section; 0 suppresses row details",
    )
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be non-negative")

    rows = load_compare_rows(args.compare_csv)
    if args.oracle_csv:
        oracle_moves = compare_candidates.load_oracle_moves(args.oracle_csv)
        for row in rows:
            compare_candidates.annotate_oracle(row, oracle_moves)
    elif not has_oracle_columns(rows):
        print(
            "compare CSV has no oracle columns; pass --oracle-csv to annotate it",
            file=sys.stderr,
        )
        return 1

    compare_candidates.print_oracle_summary(rows, args.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
