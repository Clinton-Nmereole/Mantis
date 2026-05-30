#!/usr/bin/env python3
"""Summarize root quiet move ordering from Mantis trace-order output."""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import stats_benchmark


HEADER_RE = re.compile(
    r"Root order trace depth=(?P<depth>\d+) "
    r"warmup_depth=(?P<warmup_depth>\d+) "
    r"warmup_score=(?P<warmup_score>-?\d+) "
    r"warmup_best=(?P<warmup_best>\S+) "
    r"fen=(?P<fen>.+)"
)
ROW_RE = re.compile(
    r"^\s*(?P<rank>\d+)\s+"
    r"(?P<move>\S+)\s+"
    r"tag=(?P<tag>\S+)\s+"
    r"total=(?P<total>-?\d+)\s+"
    r"see=(?P<see>NA|-?\d+)\s+"
    r"hist=(?P<hist>-?\d+)\s+"
    r"caphist=(?P<caphist>-?\d+)\s+"
    r"opening=(?P<opening>-?\d+)\s+"
    r"killer=(?P<killer>-?\d+)\s+"
    r"victim=(?P<victim>-?\d+)\s+"
    r"attacker=(?P<attacker>-?\d+)\s+"
    r"promo=(?P<promo>-?\d+)\s+"
    r"tt=(?P<tt>true|false)\s+"
    r"capture=(?P<capture>true|false)"
)
DEFAULT_WATCH_MOVES = (
    "a2a3",
    "a2a4",
    "b2b3",
    "b2b4",
    "g2g3",
    "g2g4",
    "h2h3",
    "h2h4",
    "a7a6",
    "a7a5",
    "b7b6",
    "b7b5",
    "g7g6",
    "g7g5",
    "h7h6",
    "h7h5",
)


def parse_trace(output: str, index: int) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    header: dict[str, Any] | None = None
    rows: list[dict[str, Any]] = []

    for line in output.splitlines():
        header_match = HEADER_RE.match(line)
        if header_match:
            header = {
                "index": index,
                "depth": int(header_match.group("depth")),
                "warmup_depth": int(header_match.group("warmup_depth")),
                "warmup_score": int(header_match.group("warmup_score")),
                "warmup_best": header_match.group("warmup_best"),
                "fen": header_match.group("fen"),
            }
            continue

        row_match = ROW_RE.match(line)
        if not row_match:
            continue

        row: dict[str, Any] = {
            "index": index,
            "rank": int(row_match.group("rank")),
            "move": row_match.group("move"),
            "tag": row_match.group("tag"),
            "see": row_match.group("see"),
            "tt": row_match.group("tt") == "true",
            "capture": row_match.group("capture") == "true",
        }
        for key in ("total", "hist", "caphist", "opening", "killer", "victim", "attacker", "promo"):
            row[key] = int(row_match.group(key))
        rows.append(row)

    if header is None:
        raise RuntimeError(f"trace-order header missing for position {index}. Output:\n{output}")
    return header, rows


def run_trace(binary: str, fen: str, depth: int, timeout: float, index: int) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    output = subprocess.check_output(
        [binary, "trace-order", str(depth), "fen", fen],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return parse_trace(output, index)


def is_quiet(row: dict[str, Any]) -> bool:
    return not row["capture"] and int(row["promo"]) == 0


def summarize_position(
    header: dict[str, Any],
    rows: list[dict[str, Any]],
    watch_moves: set[str],
) -> list[dict[str, Any]]:
    quiets = [row for row in rows if is_quiet(row)]
    non_tt_quiets = [row for row in quiets if not row["tt"]]
    top_quiet = non_tt_quiets[0] if non_tt_quiets else None

    summary_rows: list[dict[str, Any]] = []
    if top_quiet is not None:
        row = dict(top_quiet)
        row.update(header)
        row["kind"] = "top_non_tt_quiet"
        summary_rows.append(row)

    for row in quiets:
        if row["move"] in watch_moves and not row["tt"]:
            watch = dict(row)
            watch.update(header)
            watch["kind"] = "watch_quiet"
            summary_rows.append(watch)
        if row["opening"] < 0 and row["hist"] > 0 and not row["tt"]:
            penalty = dict(row)
            penalty.update(header)
            penalty["kind"] = "history_vs_wing_penalty"
            summary_rows.append(penalty)
        if row["opening"] > 0 and row["rank"] <= 5 and not row["tt"]:
            boosted = dict(row)
            boosted.update(header)
            boosted["kind"] = "early_opening_boost"
            summary_rows.append(boosted)

    return summary_rows


def load_fens(args: argparse.Namespace) -> list[str]:
    if args.fen_file:
        fens = [
            line.strip()
            for line in args.fen_file.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    else:
        fens = stats_benchmark.load_bench_fens(Path("uci/uci.odin"))
    stats_benchmark.validate_fens(fens)
    if args.limit:
        return fens[: args.limit]
    return fens


def sort_key(row: dict[str, Any]) -> tuple[int, int, int]:
    if row["kind"] == "history_vs_wing_penalty":
        return (abs(int(row["hist"])), -int(row["rank"]), int(row["total"]))
    if row["kind"] == "early_opening_boost":
        return (abs(int(row["opening"])), -int(row["rank"]), int(row["total"]))
    return (-int(row["rank"]), abs(int(row["total"])), abs(int(row["hist"])))


def print_section(title: str, rows: list[dict[str, Any]], limit: int) -> None:
    print(f"\n{title}")
    if not rows:
        print("  none")
        return
    for row in sorted(rows, key=sort_key, reverse=True)[:limit]:
        print(
            f"  #{row['index']:02d} rank={row['rank']:02d} move={row['move']} "
            f"total={row['total']:+d} hist={row['hist']:+d} opening={row['opening']:+d} "
            f"warmup={row['warmup_best']} score={row['warmup_score']:+d}"
        )


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = [
        "kind",
        "index",
        "rank",
        "move",
        "tag",
        "total",
        "hist",
        "opening",
        "killer",
        "tt",
        "capture",
        "warmup_best",
        "warmup_score",
        "fen",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="./mantis_asp_retry", help="Mantis binary to trace")
    parser.add_argument("--depth", type=int, default=7, help="Root trace depth")
    parser.add_argument("--timeout", type=float, default=30.0, help="Timeout per traced position")
    parser.add_argument("--limit", type=int, default=0, help="Only trace the first N benchmark FENs")
    parser.add_argument("--fen-file", type=Path, help="Optional file with one FEN per line")
    parser.add_argument("--watch-move", action="append", default=[], help="Extra quiet move to track")
    parser.add_argument("--top", type=int, default=12, help="Rows per printed section")
    parser.add_argument("--csv", type=Path, help="Optional CSV output path")
    args = parser.parse_args()

    if args.depth < 1:
        parser.error("--depth must be positive")
    if args.limit < 0:
        parser.error("--limit must be non-negative")
    if args.top <= 0:
        parser.error("--top must be positive")

    try:
        fens = load_fens(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    watch_moves = set(DEFAULT_WATCH_MOVES)
    watch_moves.update(args.watch_move)

    all_rows: list[dict[str, Any]] = []
    for index, fen in enumerate(fens, start=1):
        try:
            header, rows = run_trace(args.binary, fen, args.depth, args.timeout, index)
        except subprocess.CalledProcessError as exc:
            print(f"FAIL position {index}: engine exited with {exc.returncode}\n{exc.output}", file=sys.stderr)
            return 1
        except subprocess.TimeoutExpired as exc:
            print(f"FAIL position {index}: timed out after {args.timeout}s\n{exc.output}", file=sys.stderr)
            return 1

        all_rows.extend(summarize_position(header, rows, watch_moves))
        print(f"traced {index:02d}/{len(fens):02d} warmup={header['warmup_best']}", flush=True)

    top_quiets = [row for row in all_rows if row["kind"] == "top_non_tt_quiet"]
    wing_history = [row for row in all_rows if row["kind"] == "history_vs_wing_penalty"]
    opening_boosts = [row for row in all_rows if row["kind"] == "early_opening_boost"]
    watch_rows = [row for row in all_rows if row["kind"] == "watch_quiet"]
    watch_high = [row for row in watch_rows if int(row["rank"]) <= 10 or int(row["total"]) > -500]

    print(
        f"\nRoot quiet trace summary: positions={len(fens)} depth={args.depth} "
        f"top_quiets={len(top_quiets)} watch_rows={len(watch_rows)}"
    )
    print_section("Top non-TT quiets", top_quiets, args.top)
    print_section("Wing-pawn watch rows near the top", watch_high, args.top)
    print_section("Positive history fighting wing-pawn penalties", wing_history, args.top)
    print_section("Early root quiets dominated by opening boost", opening_boosts, args.top)

    if args.csv:
        write_csv(args.csv, all_rows)
        print(f"\nWrote CSV: {args.csv}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
