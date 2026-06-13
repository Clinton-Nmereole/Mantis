#!/usr/bin/env python3
"""Rank timed-search moves by Stockfish oracle loss."""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path
from typing import Any

import blunder_trace
import stats_benchmark


def load_fens(path: Path | None, limit: int) -> list[str]:
    if path is None:
        fens = stats_benchmark.load_bench_fens(Path("uci/uci.odin"))
    else:
        fens = [
            line.strip()
            for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    if limit > 0:
        fens = fens[:limit]
    stats_benchmark.validate_fens(fens)
    return fens


def oracle_entry(rows: list[dict[str, Any]], move: str) -> dict[str, Any] | None:
    for row in rows:
        if row.get("root") == move:
            return row
    return None


def forced_oracle_score(
    engine: blunder_trace.UCIEngine,
    fen: str,
    move: str,
    depth: int,
    timeout: float,
) -> tuple[int | None, dict[str, int | str], str]:
    engine.set_option("MultiPV", 1)
    stats, _wall_ms, output = engine.search_go_output_fen(
        fen,
        f"go depth {depth} searchmoves {move}",
        timeout,
    )
    score = stats.get("score_cp")
    return int(score) if isinstance(score, int) else None, stats, output


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    keys: list[str] = []
    for row in rows:
        for key in row:
            if key not in keys:
                keys.append(key)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)


def print_top(rows: list[dict[str, Any]], limit: int) -> None:
    known = [
        row for row in rows
        if isinstance(row.get("oracle_loss_cp"), int)
    ]
    known.sort(key=lambda row: int(row["oracle_loss_cp"]), reverse=True)

    print("\n=== Top Oracle Losses ===", flush=True)
    if not known:
        print("No known oracle losses.", flush=True)
        return
    for row in known[:limit]:
        forced = " forced" if row.get("oracle_forced_score") else ""
        print(
            f"{int(row['index']):3d}: loss={int(row['oracle_loss_cp']):4d} "
            f"rank={row.get('oracle_rank', '')}{forced} "
            f"{row.get('bestmove', '')}->{row.get('oracle_bestmove', '')} "
            f"depth={row.get('engine_depth', '')} "
            f"fen={row.get('fen', '')}",
            flush=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="./mantis", help="Engine to scan")
    parser.add_argument("--oracle-binary", required=True, help="Stockfish-compatible UCI oracle")
    parser.add_argument("--fen-file", type=Path, help="Optional FEN list")
    parser.add_argument("--limit", type=int, default=0, help="Only scan first N FENs")
    parser.add_argument("--wtime", type=int, default=1000)
    parser.add_argument("--btime", type=int, default=1000)
    parser.add_argument("--winc", type=int, default=10)
    parser.add_argument("--binc", type=int, default=10)
    parser.add_argument("--movestogo", type=int, default=0)
    parser.add_argument("--movetime", type=int, help="Use go movetime N instead of clock controls")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--oracle-depth", type=int, default=12)
    parser.add_argument("--oracle-multipv", type=int, default=12)
    parser.add_argument("--oracle-timeout", type=float, default=90.0)
    parser.add_argument("--csv", type=Path, help="Optional CSV output path")
    parser.add_argument("--top", type=int, default=12, help="Number of top losses to print")
    parser.add_argument("--keep-hash", action="store_true")
    parser.add_argument("--own-book", action="store_true")
    parser.add_argument("--staged-picker", action="store_true")
    parser.add_argument("--option", action="append", default=[], help="Engine option Name=Value; repeatable")
    parser.add_argument(
        "--oracle-option",
        action="append",
        default=[],
        help="Oracle UCI option Name=Value; repeatable",
    )
    args = parser.parse_args()

    if args.limit < 0:
        parser.error("--limit must be non-negative")
    if args.oracle_depth <= 0:
        parser.error("--oracle-depth must be positive")
    if args.oracle_multipv <= 0:
        parser.error("--oracle-multipv must be positive")
    if args.top < 0:
        parser.error("--top must be non-negative")
    if args.movetime is not None:
        if args.movetime <= 0:
            parser.error("--movetime must be positive")
    else:
        if min(args.wtime, args.btime) <= 0:
            parser.error("--wtime and --btime must be positive")
        if min(args.winc, args.binc, args.movestogo) < 0:
            parser.error("--winc, --binc, and --movestogo must be non-negative")

    try:
        options = stats_benchmark.parse_engine_options(args.option)
        oracle_options = stats_benchmark.parse_engine_options(args.oracle_option)
        fens = load_fens(args.fen_file, args.limit)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    clock = None
    search_mode = "movetime" if args.movetime is not None else "clock"
    search_limit: int | str
    if args.movetime is not None:
        search_limit = args.movetime
    else:
        clock = {
            "wtime": args.wtime,
            "btime": args.btime,
            "winc": args.winc,
            "binc": args.binc,
            "movestogo": args.movestogo,
        }
        search_limit = stats_benchmark.clock_label(clock)

    rows: list[dict[str, Any]] = []
    oracle = blunder_trace.UCIEngine(args.oracle_binary, args.oracle_timeout)
    try:
        for name, value in oracle_options:
            oracle.set_option(name, value)

        for index, fen in enumerate(fens, start=1):
            try:
                stats, _output, wall_ms = stats_benchmark.run_position(
                    args.binary,
                    fen,
                    depth=None,
                    timeout=args.timeout,
                    clear_hash=not args.keep_hash,
                    staged_picker=args.staged_picker,
                    own_book=args.own_book,
                    movetime_ms=args.movetime,
                    clock_ms=clock,
                    options=options,
                )
            except subprocess.CalledProcessError as exc:
                print(f"FAIL engine {index}: exited with {exc.returncode}\n{exc.output}", file=sys.stderr)
                return 1
            except subprocess.TimeoutExpired as exc:
                print(f"FAIL engine {index}: timed out after {args.timeout}s\n{exc.output}", file=sys.stderr)
                return 1

            bestmove = str(stats.get("bestmove", ""))
            oracle.new_game()
            oracle.set_option("MultiPV", args.oracle_multipv)
            try:
                _oracle_stats, _oracle_wall, oracle_output = oracle.search_go_output_fen(
                    fen,
                    f"go depth {args.oracle_depth}",
                    args.oracle_timeout,
                )
            except subprocess.TimeoutExpired as exc:
                print(f"FAIL oracle {index}: timed out after {args.oracle_timeout}s\n{exc.output}", file=sys.stderr)
                return 1

            oracle_rows = blunder_trace.parse_multipv(oracle_output)
            if not oracle_rows:
                print(f"FAIL oracle {index}: no MultiPV rows", file=sys.stderr)
                return 1

            oracle_best = oracle_rows[0]
            found = oracle_entry(oracle_rows, bestmove)
            forced = False
            forced_nodes = ""
            forced_time_ms = ""
            if found is None:
                forced = True
                oracle.new_game()
                try:
                    score_cp, forced_stats, _forced_output = forced_oracle_score(
                        oracle,
                        fen,
                        bestmove,
                        args.oracle_depth,
                        args.oracle_timeout,
                    )
                except subprocess.TimeoutExpired as exc:
                    print(
                        f"WARN oracle forced {index}: timed out after "
                        f"{args.oracle_timeout}s\n{exc.output}",
                        file=sys.stderr,
                        flush=True,
                    )
                    score_cp = None
                    forced_stats = {}
                forced_nodes = forced_stats.get("nodes", "")
                forced_time_ms = forced_stats.get("time_ms", "")
                found = {
                    "rank": "",
                    "score_cp": score_cp if score_cp is not None else "",
                    "depth": forced_stats.get("depth", ""),
                    "nodes": forced_nodes,
                    "time_ms": forced_time_ms,
                }

            move_score = found.get("score_cp", "")
            loss = ""
            if isinstance(oracle_best.get("score_cp"), int) and isinstance(move_score, int):
                loss = int(oracle_best["score_cp"]) - int(move_score)

            row = {
                "index": index,
                "fen": fen,
                "search_mode": search_mode,
                "search_limit": search_limit,
                "bestmove": bestmove,
                "engine_depth": stats.get("depth", ""),
                "engine_score_cp": stats.get("score_cp", ""),
                "engine_nodes": stats.get("nodes", ""),
                "engine_time_ms": stats.get("time_ms", ""),
                "engine_wall_ms": int(wall_ms),
                "oracle_bestmove": oracle_best.get("root", ""),
                "oracle_best_score_cp": oracle_best.get("score_cp", ""),
                "oracle_rank": found.get("rank", ""),
                "oracle_move_score_cp": move_score,
                "oracle_loss_cp": loss,
                "oracle_forced_score": int(forced),
                "oracle_depth": args.oracle_depth,
                "oracle_multipv": args.oracle_multipv,
                "oracle_forced_nodes": forced_nodes,
                "oracle_forced_time_ms": forced_time_ms,
            }
            rows.append(row)
            loss_text = str(loss) if loss != "" else "?"
            rank_text = str(row["oracle_rank"]) if row["oracle_rank"] != "" else "out"
            forced_text = " forced" if forced else ""
            print(
                f"{index:3d}/{len(fens):3d} loss={loss_text:>4} "
                f"rank={rank_text:>3}{forced_text} "
                f"{bestmove}->{row['oracle_bestmove']} "
                f"depth={row['engine_depth']} fen={fen}",
                flush=True,
            )
    finally:
        oracle.close()

    if args.csv:
        write_csv(args.csv, rows)
        print(f"\nWrote CSV: {args.csv}", flush=True)

    if args.top:
        print_top(rows, args.top)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
