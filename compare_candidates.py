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


def parse_optional_int(value: Any) -> int | None:
    if value in {None, ""}:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def add_oracle_move(
    moves: dict[str, dict[str, int]],
    move: str | None,
    rank: Any,
    score_cp: Any,
    loss_cp: Any,
) -> None:
    if not move:
        return
    rank_value = parse_optional_int(rank)
    loss_value = parse_optional_int(loss_cp)
    score_value = parse_optional_int(score_cp)
    if rank_value is None and loss_value is None and score_value is None:
        return
    entry: dict[str, int] = {}
    if rank_value is not None:
        entry["rank"] = rank_value
    if score_value is not None:
        entry["score_cp"] = score_value
    if loss_value is not None:
        entry["loss_cp"] = loss_value
    moves[move] = entry


def load_oracle_moves(path: Path | None) -> dict[str, dict[str, dict[str, int]]]:
    if path is None:
        return {}

    oracle: dict[str, dict[str, dict[str, int]]] = {}
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            fen = row.get("fen", "")
            if not fen:
                continue
            moves = oracle.setdefault(fen, {})
            add_oracle_move(
                moves,
                row.get("oracle_bestmove"),
                1,
                row.get("oracle_best_score_cp"),
                0,
            )
            add_oracle_move(
                moves,
                row.get("played"),
                row.get("oracle_played_rank"),
                row.get("oracle_played_score_cp"),
                row.get("oracle_played_loss_cp"),
            )
            add_oracle_move(
                moves,
                row.get("bestmove"),
                row.get("oracle_engine_rank"),
                row.get("oracle_engine_score_cp"),
                row.get("oracle_engine_loss_cp"),
            )
    return oracle


def annotate_oracle(row: dict[str, Any], oracle_moves: dict[str, dict[str, dict[str, int]]]) -> None:
    moves = oracle_moves.get(str(row["fen"]), {})
    base = moves.get(str(row["base_best"]), {})
    cand = moves.get(str(row["cand_best"]), {})
    row["base_oracle_rank"] = base.get("rank", "")
    row["cand_oracle_rank"] = cand.get("rank", "")
    row["base_oracle_loss_cp"] = base.get("loss_cp", "")
    row["cand_oracle_loss_cp"] = cand.get("loss_cp", "")
    row["oracle_loss_delta_cp"] = ""
    if "loss_cp" in base and "loss_cp" in cand:
        row["oracle_loss_delta_cp"] = cand["loss_cp"] - base["loss_cp"]


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
    own_book: bool,
    options: list[tuple[str, str]],
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
        own_book=own_book,
        movetime_ms=movetime_ms,
        clock_ms=clock_ms,
        options=options,
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
        args.baseline_own_book,
        args.baseline_options,
    )
    cand = run_one(
        args.candidate,
        fen,
        mode,
        limit_value,
        args.timeout,
        args.keep_hash,
        args.candidate_staged_picker,
        args.candidate_own_book,
        args.candidate_options,
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
    max_score_swing = max((abs(int(row["score_delta_cp"])) for row in rows), default=0)
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
    print(f"max_score_delta:  {max_score_swing} cp", flush=True)

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


def oracle_loss(row: dict[str, Any], key: str) -> int | None:
    return parse_optional_int(row.get(key))


def grouped_by_limit(rows: list[dict[str, Any]]) -> list[tuple[tuple[str, str], list[dict[str, Any]]]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = {}
    order: list[tuple[str, str]] = []
    for row in rows:
        key = (str(row.get("mode", "")), str(row.get("limit", "")))
        if key not in groups:
            order.append(key)
            groups[key] = []
        groups[key].append(row)
    return [(key, groups[key]) for key in order]


def oracle_row_text(row: dict[str, Any], *, loss_key: str = "cand_oracle_loss_cp") -> str:
    index = int_stat(row, "index")
    rank = row.get("cand_oracle_rank", "")
    loss = row.get(loss_key, "")
    return (
        f"  {index:2d}: loss={loss} rank={rank} "
        f"{row.get('base_best', '?')}->{row.get('cand_best', '?')} "
        f"fen={row.get('fen', '')}"
    )


def print_oracle_summary(rows: list[dict[str, Any]], row_limit: int = 5) -> None:
    print("\n=== Oracle Summary ===", flush=True)
    if not rows:
        print("positions:        0", flush=True)
        return

    for (mode, limit_value), limit_rows in grouped_by_limit(rows):
        label = f"{mode} {limit_value}".strip()
        known_rows = [
            row for row in limit_rows
            if oracle_loss(row, "base_oracle_loss_cp") is not None
            and oracle_loss(row, "cand_oracle_loss_cp") is not None
        ]
        unknown_changed = [
            row for row in limit_rows
            if int_stat(row, "bestmove_changed") != 0 and row not in known_rows
        ]

        print(f"\n--- {label} ---", flush=True)
        print(f"positions:        {len(limit_rows)}", flush=True)
        print(f"known_oracle:     {len(known_rows)}", flush=True)
        if not known_rows:
            if unknown_changed:
                print(f"unknown_changed:  {len(unknown_changed)}", flush=True)
            continue

        improved = [
            row for row in known_rows
            if oracle_loss(row, "cand_oracle_loss_cp") < oracle_loss(row, "base_oracle_loss_cp")
        ]
        regressed = [
            row for row in known_rows
            if oracle_loss(row, "cand_oracle_loss_cp") > oracle_loss(row, "base_oracle_loss_cp")
        ]
        unchanged = len(known_rows) - len(improved) - len(regressed)
        remaining = [
            row for row in known_rows
            if oracle_loss(row, "cand_oracle_loss_cp") > 0
        ]
        fixed = [
            row for row in known_rows
            if oracle_loss(row, "base_oracle_loss_cp") > 0
            and oracle_loss(row, "cand_oracle_loss_cp") == 0
        ]
        base_total = sum(oracle_loss(row, "base_oracle_loss_cp") or 0 for row in known_rows)
        cand_total = sum(oracle_loss(row, "cand_oracle_loss_cp") or 0 for row in known_rows)

        print(f"improved:         {len(improved)}", flush=True)
        print(f"fixed:            {len(fixed)}", flush=True)
        print(f"regressed:        {len(regressed)}", flush=True)
        print(f"unchanged:        {unchanged}", flush=True)
        print(f"remaining_loss:   {len(remaining)}", flush=True)
        print(f"loss_cp_total:    {base_total} -> {cand_total} ({cand_total - base_total:+d})", flush=True)
        if unknown_changed:
            print(f"unknown_changed:  {len(unknown_changed)}", flush=True)

        if row_limit <= 0:
            continue

        if improved:
            print("top_improvements:", flush=True)
            for row in sorted(
                improved,
                key=lambda item: (
                    (oracle_loss(item, "base_oracle_loss_cp") or 0)
                    - (oracle_loss(item, "cand_oracle_loss_cp") or 0)
                ),
                reverse=True,
            )[:row_limit]:
                base_loss = oracle_loss(row, "base_oracle_loss_cp") or 0
                cand_loss = oracle_loss(row, "cand_oracle_loss_cp") or 0
                print(f"{oracle_row_text(row)} delta={cand_loss - base_loss:+d}", flush=True)

        if regressed:
            print("top_regressions:", flush=True)
            for row in sorted(
                regressed,
                key=lambda item: (
                    (oracle_loss(item, "cand_oracle_loss_cp") or 0)
                    - (oracle_loss(item, "base_oracle_loss_cp") or 0)
                ),
                reverse=True,
            )[:row_limit]:
                base_loss = oracle_loss(row, "base_oracle_loss_cp") or 0
                cand_loss = oracle_loss(row, "cand_oracle_loss_cp") or 0
                print(f"{oracle_row_text(row)} delta={cand_loss - base_loss:+d}", flush=True)

        if remaining:
            print("remaining_targets:", flush=True)
            for row in sorted(
                remaining,
                key=lambda item: oracle_loss(item, "cand_oracle_loss_cp") or 0,
                reverse=True,
            )[:row_limit]:
                print(oracle_row_text(row), flush=True)

        if unknown_changed:
            print("unknown_changed_moves:", flush=True)
            for row in unknown_changed[:row_limit]:
                print(
                    f"  {int_stat(row, 'index'):2d}: "
                    f"{row.get('base_best', '?')}->{row.get('cand_best', '?')} "
                    f"fen={row.get('fen', '')}",
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
    parser.add_argument("--oracle-csv", type=Path, help="Optional blunder_trace oracle CSV for move rank/loss annotations")
    parser.add_argument("--keep-hash", action="store_true", help="Do not send ucinewgame between positions")
    parser.add_argument("--baseline-own-book", action="store_true", help="Allow OwnBook moves for the baseline binary")
    parser.add_argument("--candidate-own-book", action="store_true", help="Allow OwnBook moves for the candidate binary")
    parser.add_argument("--baseline-staged-picker", action="store_true", help="Enable StagedMovePicker on baseline")
    parser.add_argument("--candidate-staged-picker", action="store_true", help="Enable StagedMovePicker on candidate")
    parser.add_argument("--option", action="append", default=[], help="UCI option Name=Value applied to both binaries; repeatable")
    parser.add_argument("--baseline-option", action="append", default=[], help="UCI option Name=Value applied only to baseline; repeatable")
    parser.add_argument("--candidate-option", action="append", default=[], help="UCI option Name=Value applied only to candidate; repeatable")
    parser.add_argument("--fail-on-bestmove-change", action="store_true", help="Exit nonzero if any bestmove changes")
    parser.add_argument(
        "--fail-on-score-delta",
        type=int,
        help="Exit nonzero if any absolute score delta exceeds this many centipawns",
    )
    parser.add_argument(
        "--fail-on-depth-loss",
        type=int,
        nargs="?",
        const=1,
        help="Exit nonzero if candidate depth is lower by at least this many plies; default threshold is 1",
    )
    parser.add_argument(
        "--fail-on-oracle-loss-regression",
        type=int,
        help="Exit nonzero if known candidate oracle loss exceeds known baseline loss by more than this many centipawns",
    )
    parser.add_argument(
        "--oracle-summary-limit",
        type=int,
        default=5,
        help="Rows per oracle summary section when --oracle-csv is used; 0 suppresses row details",
    )
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
    if args.fail_on_score_delta is not None and args.fail_on_score_delta < 0:
        parser.error("--fail-on-score-delta must be non-negative")
    if args.fail_on_depth_loss is not None and args.fail_on_depth_loss <= 0:
        parser.error("--fail-on-depth-loss must be positive")
    if args.fail_on_oracle_loss_regression is not None and args.fail_on_oracle_loss_regression < 0:
        parser.error("--fail-on-oracle-loss-regression must be non-negative")
    if args.oracle_summary_limit < 0:
        parser.error("--oracle-summary-limit must be non-negative")
    try:
        common_options = stats_benchmark.parse_engine_options(args.option)
        args.baseline_options = common_options + stats_benchmark.parse_engine_options(args.baseline_option)
        args.candidate_options = common_options + stats_benchmark.parse_engine_options(args.candidate_option)
    except ValueError as exc:
        parser.error(str(exc))

    try:
        fens = load_fens(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    oracle_moves = load_oracle_moves(args.oracle_csv)
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

            annotate_oracle(row, oracle_moves)
            limit_rows.append(row)
            all_rows.append(row)
            marker = "!" if int(row["bestmove_changed"]) else " "
            depth_note = ""
            if mode in {"movetime", "clock"}:
                depth_note = f" depth={int(row['base_depth'])}->{int(row['cand_depth'])}"
            oracle_note = ""
            if args.oracle_csv:
                base_loss = row["base_oracle_loss_cp"]
                cand_loss = row["cand_oracle_loss_cp"]
                if base_loss != "" or cand_loss != "":
                    oracle_note = f" oracle_loss={base_loss}->{cand_loss}"
            print(
                f"{marker} {limit_label(mode, limit_value)} {index:2d}/{len(fens):2d} "
                f"{row['base_best']}->{row['cand_best']} "
                f"score={int(row['score_delta_cp']):+5d} "
                f"nodes={int(row['node_delta']):+8d} "
                f"time={int(row['time_delta_ms']):+6d}ms"
                f"{depth_note}"
                f"{oracle_note}",
                flush=True,
            )

        print_limit_summary(mode, limit_value, limit_rows)
        total_changes += sum(int(row["bestmove_changed"]) for row in limit_rows)

    if args.csv:
        write_csv(args.csv, all_rows)
        print(f"\nWrote CSV: {args.csv}", flush=True)

    if args.oracle_csv:
        print_oracle_summary(all_rows, args.oracle_summary_limit)

    if args.fail_on_score_delta is not None:
        score_violations = [
            row for row in all_rows
            if abs(int(row["score_delta_cp"])) > args.fail_on_score_delta
        ]
        if score_violations:
            print(
                f"\nFAIL: {len(score_violations)} score deltas exceeded "
                f"{args.fail_on_score_delta} cp",
                flush=True,
            )
            for row in score_violations:
                print(
                    f"  {row['mode']}={row['limit']} index={int(row['index'])}: "
                    f"score_delta={int(row['score_delta_cp']):+d} "
                    f"{row['base_best']}->{row['cand_best']} fen={row['fen']}",
                    flush=True,
            )
            return 1

    if args.fail_on_depth_loss is not None:
        depth_violations = [
            row for row in all_rows
            if int(row["base_depth"]) - int(row["cand_depth"]) >= args.fail_on_depth_loss
        ]
        if depth_violations:
            print(
                f"\nFAIL: {len(depth_violations)} candidate searches lost at least "
                f"{args.fail_on_depth_loss} ply",
                flush=True,
            )
            for row in depth_violations:
                print(
                    f"  {row['mode']}={row['limit']} index={int(row['index'])}: "
                    f"depth={int(row['base_depth'])}->{int(row['cand_depth'])} "
                    f"{row['base_best']}->{row['cand_best']} fen={row['fen']}",
                    flush=True,
            )
            return 1

    if args.fail_on_oracle_loss_regression is not None:
        oracle_violations = [
            row for row in all_rows
            if row["oracle_loss_delta_cp"] != "" and int(row["oracle_loss_delta_cp"]) > args.fail_on_oracle_loss_regression
        ]
        if oracle_violations:
            print(
                f"\nFAIL: {len(oracle_violations)} known oracle losses worsened by more than "
                f"{args.fail_on_oracle_loss_regression} cp",
                flush=True,
            )
            for row in oracle_violations:
                print(
                    f"  {row['mode']}={row['limit']} index={int(row['index'])}: "
                    f"oracle_loss={row['base_oracle_loss_cp']}->{row['cand_oracle_loss_cp']} "
                    f"{row['base_best']}->{row['cand_best']} fen={row['fen']}",
                    flush=True,
                )
            return 1

    if args.fail_on_bestmove_change and total_changes:
        print(f"\nFAIL: {total_changes} bestmove changes detected", flush=True)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
