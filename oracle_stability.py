#!/usr/bin/env python3
"""Check whether oracle targets stay stable across Stockfish depths."""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path
from typing import Any

import blunder_trace
import stats_benchmark


def load_input_rows(path: Path | None, limit: int, indices: set[int]) -> list[dict[str, Any]]:
    if path is None:
        rows = [
            {"index": index, "fen": fen}
            for index, fen in enumerate(stats_benchmark.load_bench_fens(Path("uci/uci.odin")), start=1)
        ]
    else:
        text = path.read_text()
        if path.suffix.lower() == ".csv":
            rows = [dict(row) for row in csv.DictReader(text.splitlines())]
        else:
            rows = [
                {"index": index, "fen": line.strip()}
                for index, line in enumerate(text.splitlines(), start=1)
                if line.strip() and not line.lstrip().startswith("#")
            ]

    if indices:
        filtered: list[dict[str, Any]] = []
        for fallback_index, row in enumerate(rows, start=1):
            try:
                row_index = int(row.get("index", fallback_index))
            except (TypeError, ValueError):
                row_index = fallback_index
            if row_index in indices:
                filtered.append(row)
        rows = filtered
    if limit > 0:
        rows = rows[:limit]
    fens = [str(row.get("fen", "")) for row in rows]
    stats_benchmark.validate_fens(fens)
    return rows


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
) -> tuple[int | None, dict[str, int | str]]:
    engine.set_option("MultiPV", 1)
    stats, _wall_ms, _output = engine.search_go_output_fen(
        fen,
        f"go depth {depth} searchmoves {move}",
        timeout,
    )
    score = stats.get("score_cp")
    return int(score) if isinstance(score, int) else None, stats


def move_loss(
    oracle_rows: list[dict[str, Any]],
    move: str,
    engine: blunder_trace.UCIEngine,
    fen: str,
    depth: int,
    timeout: float,
    force_missing: bool,
) -> tuple[int | str, int | str, int | str, int]:
    if not move:
        return "", "", "", 0

    best_score = oracle_rows[0].get("score_cp")
    if not isinstance(best_score, int):
        return "", "", "", 0

    found = oracle_entry(oracle_rows, move)
    forced = 0
    if found is None and force_missing:
        forced = 1
        score, stats = forced_oracle_score(engine, fen, move, depth, timeout)
        found = {
            "rank": "",
            "score_cp": score if score is not None else "",
            "nodes": stats.get("nodes", ""),
        }
    if found is None:
        return "", "", "", forced

    score = found.get("score_cp", "")
    rank = found.get("rank", "")
    if isinstance(score, int):
        return rank, score, best_score - score, forced
    return rank, score, "", forced


def run_engine_clock(
    binary: str,
    fen: str,
    clock: dict[str, int],
    timeout: float,
    options: list[tuple[str, str]],
) -> dict[str, Any]:
    stats, _output, wall_ms = stats_benchmark.run_position(
        binary,
        fen,
        depth=None,
        timeout=timeout,
        clear_hash=True,
        staged_picker=False,
        own_book=False,
        clock_ms=clock,
        options=options,
    )
    stats["wall_ms"] = int(wall_ms)
    return stats


def configure_oracle(
    binary: str,
    timeout: float,
    options: list[tuple[str, str]],
) -> blunder_trace.UCIEngine:
    engine = blunder_trace.UCIEngine(binary, timeout)
    for name, value in options:
        engine.set_option(name, value)
    return engine


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


def print_summary(rows: list[dict[str, Any]], top: int) -> None:
    print("\n=== Oracle Stability Summary ===", flush=True)
    print(f"positions:       {len(rows)}", flush=True)
    print(f"stable_best:     {sum(int(row['stable_best']) for row in rows)}", flush=True)
    print(f"unstable_best:   {sum(1 - int(row['stable_best']) for row in rows)}", flush=True)

    loss_rows = [
        row for row in rows
        if isinstance(row.get("final_engine_loss_cp"), int)
    ]
    loss_rows.sort(key=lambda row: int(row["final_engine_loss_cp"]), reverse=True)
    if top <= 0:
        return
    print("\nTop final-depth engine losses:", flush=True)
    for row in loss_rows[:top]:
        print(
            f"{int(row['index']):3d}: loss={int(row['final_engine_loss_cp']):4d} "
            f"stable={row['stable_best']} engine={row.get('engine_best', '')} "
            f"final={row.get('final_bestmove', '')} depths={row.get('bestmoves_by_depth', '')} "
            f"fen={row.get('fen', '')}",
            flush=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle-binary", required=True, help="Stockfish-compatible UCI oracle")
    parser.add_argument("--binary", help="Optional engine to search for current bestmove")
    parser.add_argument("--input", type=Path, help="FEN text file or CSV with a fen column")
    parser.add_argument("--indices", type=int, nargs="+", default=[], help="Only include these 1-based row/index values")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--depths", type=int, nargs="+", default=[14, 16, 18, 20])
    parser.add_argument("--multipv", type=int, default=12)
    parser.add_argument("--timeout", type=float, default=120.0, help="Timeout per engine/oracle search")
    parser.add_argument("--wtime", type=int, default=1000)
    parser.add_argument("--btime", type=int, default=1000)
    parser.add_argument("--winc", type=int, default=10)
    parser.add_argument("--binc", type=int, default=10)
    parser.add_argument("--movestogo", type=int, default=0)
    parser.add_argument("--option", action="append", default=[], help="Engine option Name=Value; repeatable")
    parser.add_argument("--oracle-option", action="append", default=[], help="Oracle option Name=Value; repeatable")
    parser.add_argument("--force-missing", action="store_true", help="Force-score engine moves missing from MultiPV")
    parser.add_argument("--csv", type=Path, help="Optional CSV output")
    parser.add_argument("--top", type=int, default=10)
    args = parser.parse_args()

    if args.limit < 0:
        parser.error("--limit must be non-negative")
    if not args.depths or any(depth <= 0 for depth in args.depths):
        parser.error("--depths must be positive")
    if args.multipv <= 0:
        parser.error("--multipv must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    try:
        rows = load_input_rows(args.input, args.limit, set(args.indices))
        engine_options = stats_benchmark.parse_engine_options(args.option)
        oracle_options = stats_benchmark.parse_engine_options(args.oracle_option)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    clock = {
        "wtime": args.wtime,
        "btime": args.btime,
        "winc": args.winc,
        "binc": args.binc,
        "movestogo": args.movestogo,
    }

    results: list[dict[str, Any]] = []
    oracle = configure_oracle(args.oracle_binary, args.timeout, oracle_options)
    try:
        for input_index, input_row in enumerate(rows, start=1):
            fen = str(input_row["fen"])
            engine_best = str(
                input_row.get("bestmove")
                or input_row.get("cand_best")
                or input_row.get("base_best")
                or ""
            )
            engine_depth: int | str = input_row.get("engine_depth", "")
            engine_time_ms: int | str = input_row.get("engine_time_ms", "")
            if args.binary:
                try:
                    engine_stats = run_engine_clock(args.binary, fen, clock, args.timeout, engine_options)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
                    print(f"FAIL engine {input_index}: {exc}", file=sys.stderr)
                    return 1
                engine_best = str(engine_stats.get("bestmove", ""))
                engine_depth = engine_stats.get("depth", "")
                engine_time_ms = engine_stats.get("time_ms", "")

            bestmoves: list[str] = []
            row: dict[str, Any] = {
                "index": input_row.get("index", input_index),
                "fen": fen,
                "engine_best": engine_best,
                "engine_depth": engine_depth,
                "engine_time_ms": engine_time_ms,
            }

            for depth in args.depths:
                oracle.new_game()
                oracle.set_option("MultiPV", args.multipv)
                timed_out = 0
                try:
                    _stats, _wall_ms, output = oracle.search_go_output_fen(
                        fen,
                        f"go depth {depth}",
                        args.timeout,
                    )
                except subprocess.TimeoutExpired as exc:
                    timed_out = 1
                    output = exc.output or ""
                    oracle.close()
                    oracle = configure_oracle(args.oracle_binary, args.timeout, oracle_options)
                oracle_rows = blunder_trace.parse_multipv(output)
                if not oracle_rows:
                    print(
                        f"FAIL oracle depth {depth} index {input_index}: no MultiPV rows",
                        file=sys.stderr,
                    )
                    return 1

                best = str(oracle_rows[0].get("root", ""))
                bestmoves.append(best)
                rank, score, loss, forced = move_loss(
                    oracle_rows,
                    engine_best,
                    oracle,
                    fen,
                    depth,
                    args.timeout,
                    args.force_missing,
                )
                row[f"d{depth}_bestmove"] = best
                row[f"d{depth}_best_score_cp"] = oracle_rows[0].get("score_cp", "")
                row[f"d{depth}_engine_rank"] = rank
                row[f"d{depth}_engine_score_cp"] = score
                row[f"d{depth}_engine_loss_cp"] = loss
                row[f"d{depth}_forced"] = forced
                row[f"d{depth}_timeout"] = timed_out

            final_depth = args.depths[-1]
            row["bestmoves_by_depth"] = ",".join(bestmoves)
            row["stable_best"] = int(len(set(bestmoves)) == 1)
            row["final_bestmove"] = row[f"d{final_depth}_bestmove"]
            row["final_engine_loss_cp"] = row[f"d{final_depth}_engine_loss_cp"]
            results.append(row)

            loss_text = row["final_engine_loss_cp"]
            print(
                f"{input_index:3d}/{len(rows):3d} stable={row['stable_best']} "
                f"loss={loss_text if loss_text != '' else '?'} "
                f"engine={engine_best} final={row['final_bestmove']} "
                f"depths={row['bestmoves_by_depth']}",
                flush=True,
            )
    finally:
        oracle.close()

    if args.csv:
        write_csv(args.csv, results)
        print(f"\nWrote CSV: {args.csv}", flush=True)
    print_summary(results, args.top)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
