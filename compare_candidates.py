#!/usr/bin/env python3
"""Compare two Mantis binaries across benchmark FENs and search budgets."""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path
from typing import Any

import stats_benchmark


def int_stat(row: dict[str, Any], key: str) -> int:
    value = row.get(key, 0)
    if isinstance(value, int):
        return value
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def score_delta(base: dict[str, Any], cand: dict[str, Any]) -> int:
    return int_stat(cand, "score_cp") - int_stat(base, "score_cp")


def node_delta(base: dict[str, Any], cand: dict[str, Any]) -> int:
    return int_stat(cand, "nodes") - int_stat(base, "nodes")


def time_delta(base: dict[str, Any], cand: dict[str, Any]) -> int:
    return int_stat(cand, "time_ms") - int_stat(base, "time_ms")


def pct_delta(delta: int, base: int) -> float:
    if base == 0:
        return 0.0
    return 100.0 * delta / base


def limit_label(mode: str, limit_value: Any) -> str:
    if mode == "depth":
        return f"Depth {limit_value}"
    if mode == "movetime":
        return f"Movetime {limit_value}ms"
    if mode == "clock":
        return f"Clock {stats_benchmark.clock_label(limit_value)}"
    return f"{mode}={limit_value}"


def load_fens(args: argparse.Namespace) -> list[str]:
    if args.fen_file:
        fens = [
            line.strip()
            for line in args.fen_file.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    else:
        fens = stats_benchmark.load_bench_fens(Path("uci/uci.odin"))

    if args.limit > 0:
        fens = fens[: args.limit]
    stats_benchmark.validate_fens(fens)
    return fens


def run_one(
    binary: str,
    fen: str,
    mode: str,
    limit_value: Any,
    timeout: float,
    keep_hash: bool,
    staged_picker: bool,
) -> dict[str, Any]:
    depth = limit_value if mode == "depth" else None
    movetime_ms = limit_value if mode == "movetime" else None
    clock_ms = limit_value if mode == "clock" else None
    stats, _output, wall_ms = stats_benchmark.run_position(
        binary,
        fen,
        depth,
        timeout,
        clear_hash=not keep_hash,
        staged_picker=staged_picker,
        movetime_ms=movetime_ms,
        clock_ms=clock_ms,
    )
    stats["wall_ms"] = int(wall_ms)
    return stats


def compare_position(
    args: argparse.Namespace,
    fen: str,
    index: int,
    mode: str,
    limit_value: Any,
) -> dict[str, Any]:
    base = run_one(
        args.baseline,
        fen,
        mode,
        limit_value,
        args.timeout,
        args.keep_hash,
        args.baseline_staged_picker,
    )
    cand = run_one(
        args.candidate,
        fen,
        mode,
        limit_value,
        args.timeout,
        args.keep_hash,
        args.candidate_staged_picker,
    )

    base_best = str(base.get("bestmove", "?"))
    cand_best = str(cand.get("bestmove", "?"))
    nodes_base = int_stat(base, "nodes")
    nodes_delta = node_delta(base, cand)
    time_base = int_stat(base, "time_ms")
    elapsed_delta = time_delta(base, cand)

    return {
        "mode": mode,
        "limit": stats_benchmark.clock_label(limit_value) if mode == "clock" else limit_value,
        "depth": limit_value if mode == "depth" else "",
        "movetime_ms": limit_value if mode == "movetime" else "",
        "clock": stats_benchmark.clock_label(limit_value) if mode == "clock" else "",
        "index": index,
        "fen": fen,
        "base_best": base_best,
        "cand_best": cand_best,
        "bestmove_changed": int(base_best != cand_best),
        "base_depth": int_stat(base, "depth"),
        "cand_depth": int_stat(cand, "depth"),
        "base_score_cp": int_stat(base, "score_cp"),
        "cand_score_cp": int_stat(cand, "score_cp"),
        "score_delta_cp": score_delta(base, cand),
        "base_nodes": nodes_base,
        "cand_nodes": int_stat(cand, "nodes"),
        "node_delta": nodes_delta,
        "node_delta_pct": f"{pct_delta(nodes_delta, nodes_base):.2f}",
        "base_time_ms": time_base,
        "cand_time_ms": int_stat(cand, "time_ms"),
        "time_delta_ms": elapsed_delta,
        "time_delta_pct": f"{pct_delta(elapsed_delta, time_base):.2f}",
        "base_qnode_pct": int_stat(base, "qnode_pct"),
        "cand_qnode_pct": int_stat(cand, "qnode_pct"),
        "base_lmp": int_stat(base, "lmp"),
        "cand_lmp": int_stat(cand, "lmp"),
        "base_futility": int_stat(base, "futility"),
        "cand_futility": int_stat(cand, "futility"),
        "base_pvs_research": int_stat(base, "pvs_research"),
        "cand_pvs_research": int_stat(cand, "pvs_research"),
    }


def print_limit_summary(mode: str, limit_value: Any, rows: list[dict[str, Any]]) -> None:
    changed = [row for row in rows if int(row["bestmove_changed"]) != 0]
    base_nodes = sum(int(row["base_nodes"]) for row in rows)
    cand_nodes = sum(int(row["cand_nodes"]) for row in rows)
    base_time = sum(int(row["base_time_ms"]) for row in rows)
    cand_time = sum(int(row["cand_time_ms"]) for row in rows)
    score_swing = sum(abs(int(row["score_delta_cp"])) for row in rows)
    base_depth = sum(int(row["base_depth"]) for row in rows)
    cand_depth = sum(int(row["cand_depth"]) for row in rows)
    label = limit_label(mode, limit_value)

    print(f"\n=== {label} Summary ===", flush=True)
    print(f"positions:        {len(rows)}", flush=True)
    print(f"bestmove_changes: {len(changed)}", flush=True)
    if mode in {"movetime", "clock"} and rows:
        print(f"avg_depth:        {base_depth / len(rows):.2f} -> {cand_depth / len(rows):.2f}", flush=True)
    print(f"nodes:            {base_nodes} -> {cand_nodes} ({pct_delta(cand_nodes - base_nodes, base_nodes):+.2f}%)", flush=True)
    print(f"time_ms:          {base_time} -> {cand_time} ({pct_delta(cand_time - base_time, base_time):+.2f}%)", flush=True)
    print(f"abs_score_delta:  {score_swing} cp", flush=True)

    if changed:
        print("changed:", flush=True)
        for row in changed:
            print(
                f"  {int(row['index']):2d}: {row['base_best']} -> {row['cand_best']} "
                f"score_delta={int(row['score_delta_cp']):+d} "
                f"node_delta={int(row['node_delta']):+d} "
                f"fen={row['fen']}",
                flush=True,
            )


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Reference Mantis binary")
    parser.add_argument("--candidate", required=True, help="Candidate Mantis binary")
    parser.add_argument("--depths", type=int, nargs="+", help="Fixed depths to compare")
    parser.add_argument("--movetimes", type=int, nargs="+", help="UCI movetime budgets, in milliseconds, to compare")
    parser.add_argument(
        "--clock",
        type=int,
        nargs=4,
        metavar=("WTIME", "BTIME", "WINC", "BINC"),
        help="Add one UCI clock budget to compare, in milliseconds",
    )
    parser.add_argument("--movestogo", type=int, default=0, help="Optional UCI movestogo value for --clock")
    parser.add_argument("--limit", type=int, default=0, help="Only run the first N benchmark FENs")
    parser.add_argument("--timeout", type=float, default=90.0, help="Timeout per engine/position in seconds")
    parser.add_argument("--fen-file", type=Path, help="Optional file with one FEN per line")
    parser.add_argument("--csv", type=Path, help="Optional CSV output path")
    parser.add_argument("--keep-hash", action="store_true", help="Do not send ucinewgame between positions")
    parser.add_argument("--baseline-staged-picker", action="store_true", help="Enable StagedMovePicker on baseline")
    parser.add_argument("--candidate-staged-picker", action="store_true", help="Enable StagedMovePicker on candidate")
    parser.add_argument("--fail-on-bestmove-change", action="store_true", help="Exit nonzero if any bestmove changes")
    args = parser.parse_args()
    if args.depths and any(depth <= 0 for depth in args.depths):
        parser.error("--depths values must be positive")
    if args.movetimes and any(movetime <= 0 for movetime in args.movetimes):
        parser.error("--movetimes values must be positive")
    if args.clock:
        wtime, btime, winc, binc = args.clock
        if wtime <= 0 or btime <= 0:
            parser.error("--clock WTIME and BTIME must be positive")
        if winc < 0 or binc < 0:
            parser.error("--clock WINC and BINC must be non-negative")
    if args.movestogo < 0:
        parser.error("--movestogo must be non-negative")

    try:
        fens = load_fens(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    all_rows: list[dict[str, Any]] = []
    total_changes = 0
    limits: list[tuple[str, Any]] = []
    if args.depths:
        limits.extend(("depth", depth) for depth in args.depths)
    if args.movetimes:
        limits.extend(("movetime", movetime) for movetime in args.movetimes)
    if args.clock:
        wtime, btime, winc, binc = args.clock
        limits.append((
            "clock",
            {
                "wtime": wtime,
                "btime": btime,
                "winc": winc,
                "binc": binc,
                "movestogo": args.movestogo,
            },
        ))
    if not limits:
        limits.extend(("depth", depth) for depth in [6, 7, 8])

    for mode, limit_value in limits:
        limit_rows: list[dict[str, Any]] = []
        for index, fen in enumerate(fens, start=1):
            try:
                row = compare_position(args, fen, index, mode, limit_value)
            except subprocess.CalledProcessError as exc:
                print(f"FAIL {mode}={limit_value} index={index}: engine exited with {exc.returncode}\n{exc.output}", file=sys.stderr)
                return 1
            except subprocess.TimeoutExpired as exc:
                print(f"FAIL {mode}={limit_value} index={index}: timed out after {args.timeout}s\n{exc.output}", file=sys.stderr)
                return 1

            limit_rows.append(row)
            all_rows.append(row)
            marker = "!" if int(row["bestmove_changed"]) else " "
            depth_note = ""
            if mode in {"movetime", "clock"}:
                depth_note = f" depth={int(row['base_depth'])}->{int(row['cand_depth'])}"
            print(
                f"{marker} {limit_label(mode, limit_value)} {index:2d}/{len(fens):2d} "
                f"{row['base_best']}->{row['cand_best']} "
                f"score={int(row['score_delta_cp']):+5d} "
                f"nodes={int(row['node_delta']):+8d} "
                f"time={int(row['time_delta_ms']):+6d}ms"
                f"{depth_note}",
                flush=True,
            )

        print_limit_summary(mode, limit_value, limit_rows)
        total_changes += sum(int(row["bestmove_changed"]) for row in limit_rows)

    if args.csv:
        write_csv(args.csv, all_rows)
        print(f"\nWrote CSV: {args.csv}", flush=True)

    if args.fail_on_bestmove_change and total_changes:
        print(f"\nFAIL: {total_changes} bestmove changes detected", flush=True)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
