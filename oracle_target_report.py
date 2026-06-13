#!/usr/bin/env python3
"""Summarize known oracle losses from compare or blunder-trace CSVs."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Any

import blunder_trace
import compare_candidates


def load_compare_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def has_oracle_columns(rows: list[dict[str, str]]) -> bool:
    if not rows:
        return True
    required = {"base_oracle_loss_cp", "cand_oracle_loss_cp"}
    return required.issubset(rows[0])


def is_blunder_trace_csv(rows: list[dict[str, str]]) -> bool:
    if not rows:
        return False
    required = {"oracle_bestmove", "oracle_engine_loss_cp", "bestmove", "fen"}
    return required.issubset(rows[0])


def query_oracle_rows(binary: str, fen: str, depth: int, multipv: int, timeout: float) -> list[dict[str, Any]]:
    engine = blunder_trace.UCIEngine(binary, timeout)
    try:
        engine.set_option("MultiPV", multipv)
        _stats, _wall_ms, output = engine.search_go_output_fen(
            fen,
            f"go depth {depth}",
            timeout,
        )
        return blunder_trace.parse_multipv(output)
    finally:
        engine.close()


def blunder_rows_to_compare_rows(
    rows: list[dict[str, str]],
    *,
    oracle_binary: str | None,
    oracle_depth: int,
    oracle_multipv: int,
    oracle_timeout: float,
) -> list[dict[str, Any]]:
    oracle_cache: dict[str, list[dict[str, Any]]] = {}
    compare_rows: list[dict[str, Any]] = []

    for row in rows:
        fen = row.get("fen", "")
        if not fen:
            continue

        oracle_rows: list[dict[str, Any]] = []
        if oracle_binary:
            if fen not in oracle_cache:
                oracle_cache[fen] = query_oracle_rows(
                    oracle_binary,
                    fen,
                    oracle_depth,
                    oracle_multipv,
                    oracle_timeout,
                )
            oracle_rows = oracle_cache[fen]

        if oracle_rows:
            best = oracle_rows[0]
            bestmove = str(best.get("root", ""))
            best_score = best.get("score_cp", "")
            entries = compare_candidates.oracle_entries_from_multipv(oracle_rows)
            engine = entries.get(row.get("bestmove", ""), {})
            engine_rank = engine.get("rank", "")
            engine_score = engine.get("score_cp", "")
            engine_loss = engine.get("loss_cp", "")
        else:
            bestmove = row.get("oracle_bestmove", "")
            best_score = row.get("oracle_best_score_cp", "")
            engine_rank = row.get("oracle_engine_rank", "")
            engine_score = row.get("oracle_engine_score_cp", "")
            engine_loss = row.get("oracle_engine_loss_cp", "")

        compare_rows.append(
            {
                "mode": row.get("search_mode", ""),
                "limit": row.get("search_limit", ""),
                "index": row.get("index", ""),
                "fen": fen,
                "base_best": bestmove,
                "cand_best": row.get("bestmove", ""),
                "bestmove_changed": int(bestmove != "" and bestmove != row.get("bestmove", "")),
                "base_oracle_rank": 1 if bestmove else "",
                "cand_oracle_rank": engine_rank,
                "base_oracle_loss_cp": 0 if bestmove else "",
                "cand_oracle_loss_cp": engine_loss,
                "oracle_loss_delta_cp": engine_loss if engine_loss != "" else "",
                "oracle_best_score_cp": best_score,
                "cand_oracle_score_cp": engine_score,
            }
        )

    return compare_rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compare_csv", type=Path, help="CSV produced by compare_candidates.py or blunder_trace.py")
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
    parser.add_argument("--oracle-binary", help="Optional UCI engine used to refresh blunder-trace oracle annotations")
    parser.add_argument("--oracle-depth", type=int, default=18, help="Depth for --oracle-binary searches")
    parser.add_argument("--oracle-multipv", type=int, default=12, help="MultiPV count for --oracle-binary searches")
    parser.add_argument("--oracle-timeout", type=float, default=120.0, help="Timeout per --oracle-binary search")
    parser.add_argument("--search-mode", help="Only summarize rows whose search_mode/mode matches this value")
    parser.add_argument("--search-limit", help="Only summarize rows whose search_limit/limit matches this value")
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be non-negative")
    if args.oracle_depth <= 0:
        parser.error("--oracle-depth must be positive")
    if args.oracle_multipv <= 0:
        parser.error("--oracle-multipv must be positive")
    if args.oracle_timeout <= 0:
        parser.error("--oracle-timeout must be positive")

    rows = load_compare_rows(args.compare_csv)
    if args.search_mode:
        rows = [
            row for row in rows
            if row.get("search_mode", row.get("mode", "")) == args.search_mode
        ]
    if args.search_limit:
        rows = [
            row for row in rows
            if row.get("search_limit", row.get("limit", "")) == args.search_limit
        ]
    if is_blunder_trace_csv(rows) and not has_oracle_columns(rows):
        rows = blunder_rows_to_compare_rows(
            rows,
            oracle_binary=args.oracle_binary,
            oracle_depth=args.oracle_depth,
            oracle_multipv=args.oracle_multipv,
            oracle_timeout=args.oracle_timeout,
        )
    elif args.oracle_csv:
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
