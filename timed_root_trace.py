#!/usr/bin/env python3
"""Trace timed/stateful root choices for one PGN position."""

from __future__ import annotations

import argparse
import csv
import io
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import chess
import chess.pgn

import blunder_trace


MULTIPV_RE = re.compile(
    r"info depth (?P<depth>\d+) multipv (?P<multipv>\d+) score cp (?P<score>-?\d+) "
    r"nodes (?P<nodes>\d+) time (?P<time>\d+) nps \d+ pv (?P<pv>.*)"
)


@dataclass
class TraceTarget:
    candidate: blunder_trace.BlunderCandidate
    moves_before: list[str]
    warm_positions: list[list[str]]


def find_target(
    pgn_path: Path,
    mantis_name: str,
    round_name: str,
    ply: int,
) -> TraceTarget:
    candidates, _stats = blunder_trace.extract_candidates(
        pgn_path=pgn_path,
        mantis_name=mantis_name,
        threshold_cp=0,
        max_before_abs_cp=None,
    )
    target = next(
        (
            candidate
            for candidate in candidates
            if candidate.round_name == round_name and candidate.ply == ply
        ),
        None,
    )
    if target is None:
        raise SystemExit(f"target not found in candidate eval drops: round={round_name} ply={ply}")

    with pgn_path.open("r", encoding="utf-8", errors="replace") as handle:
        game_index = 0
        while True:
            game = chess.pgn.read_game(handle)
            if game is None:
                break
            game_index += 1
            if game.headers.get("Round", "?") != round_name:
                continue

            mantis_color = blunder_trace.mantis_color_for_game(game, mantis_name)
            if mantis_color is None:
                continue

            board = game.board()
            moves_before: list[str] = []
            warm_positions: list[list[str]] = []

            for current_ply, node in enumerate(game.mainline(), start=1):
                if current_ply == ply:
                    return TraceTarget(
                        candidate=target,
                        moves_before=moves_before.copy(),
                        warm_positions=warm_positions,
                    )
                if board.turn == mantis_color:
                    warm_positions.append(moves_before.copy())
                move = node.move
                moves_before.append(move.uci())
                board.push(move)

    raise SystemExit(f"round found but ply not reached: round={round_name} ply={ply}")


def parse_multipv(output: str) -> list[dict[str, Any]]:
    rows_by_key: dict[tuple[int, int], dict[str, Any]] = {}
    max_depth = -1
    for line in output.splitlines():
        match = MULTIPV_RE.match(line)
        if not match:
            continue
        depth = int(match.group("depth"))
        multipv = int(match.group("multipv"))
        max_depth = max(max_depth, depth)
        pv_text = match.group("pv").strip()
        rows_by_key[(depth, multipv)] = {
            "depth": depth,
            "multipv": multipv,
            "score_cp": int(match.group("score")),
            "nodes": int(match.group("nodes")),
            "time_ms": int(match.group("time")),
            "pv": pv_text,
            "root": pv_text.split()[0] if pv_text else "",
        }
    if max_depth < 0:
        return []
    return [
        rows_by_key[key]
        for key in sorted(rows_by_key)
        if key[0] == max_depth
    ]


def warm_engine(
    engine: blunder_trace.UCIEngine,
    warm_positions: list[list[str]],
    warm_depth: int,
    timeout: float,
) -> int:
    engine.send("ucinewgame")
    engine.send("isready")
    engine.read_until("readyok", timeout)
    warmed = 0
    for moves_before in warm_positions:
        engine.search_depth(moves_before, warm_depth, timeout)
        warmed += 1
    return warmed


def run_normal_trace(
    binary: str,
    target: TraceTarget,
    movetime_ms: int,
    warm_depth: int,
    timeout: float,
) -> dict[str, Any]:
    engine = blunder_trace.UCIEngine(binary, timeout)
    try:
        warmed = warm_engine(engine, target.warm_positions, warm_depth, timeout)
        stats, wall_ms, _output = engine.search_go_output(
            target.moves_before,
            f"go movetime {movetime_ms}",
            timeout,
        )
        return {
            "trace_mode": "normal",
            "movetime_ms": movetime_ms,
            "warm_positions": warmed,
            "bestmove": stats.get("bestmove", "?"),
            "score_cp": stats.get("score_cp", ""),
            "depth": stats.get("depth", ""),
            "nodes": stats.get("nodes", ""),
            "time_ms": stats.get("time_ms", ""),
            "wall_ms": int(round(wall_ms)),
        }
    finally:
        engine.close()


def run_multipv_trace(
    binary: str,
    target: TraceTarget,
    movetime_ms: int,
    warm_depth: int,
    multipv: int,
    timeout: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    engine = blunder_trace.UCIEngine(binary, timeout)
    try:
        warmed = warm_engine(engine, target.warm_positions, warm_depth, timeout)
        engine.set_option("MultiPV", multipv)
        stats, wall_ms, output = engine.search_go_output(
            target.moves_before,
            f"go movetime {movetime_ms}",
            timeout,
        )
        summary = {
            "trace_mode": f"multipv{multipv}",
            "movetime_ms": movetime_ms,
            "warm_positions": warmed,
            "bestmove": stats.get("bestmove", "?"),
            "score_cp": stats.get("score_cp", ""),
            "depth": stats.get("depth", ""),
            "nodes": stats.get("nodes", ""),
            "time_ms": stats.get("time_ms", ""),
            "wall_ms": int(round(wall_ms)),
        }
        return summary, parse_multipv(output)
    finally:
        engine.close()


def write_reports(
    target: TraceTarget,
    normal_rows: list[dict[str, Any]],
    multipv_summaries: list[dict[str, Any]],
    multipv_rows: dict[int, list[dict[str, Any]]],
    report_path: Path,
    csv_path: Path,
) -> None:
    out = io.StringIO()
    candidate = target.candidate
    out.write("# Timed Root Trace\n\n")
    out.write(f"Round: `{candidate.round_name}`\n\n")
    out.write(f"Ply: `{candidate.ply}`\n\n")
    out.write(f"Played: `{candidate.uci}` (`{candidate.san}`)\n\n")
    out.write(
        f"Mantis eval: {blunder_trace.cp_label(candidate.eval_before_mantis_cp)} -> "
        f"{blunder_trace.cp_label(candidate.eval_after_mantis_cp)} "
        f"({candidate.delta_cp:+d} cp)\n\n"
    )
    out.write(f"FEN: `{candidate.fen}`\n\n")

    out.write("## Normal Movetime\n\n")
    out.write("| Movetime | Bestmove | Score | Depth | Nodes | Engine ms | Wall ms |\n")
    out.write("| ---: | --- | ---: | ---: | ---: | ---: | ---: |\n")
    for row in normal_rows:
        score = row.get("score_cp", "")
        score_label = blunder_trace.cp_label(int(score)) if isinstance(score, int) else "?"
        out.write(
            f"| {row['movetime_ms']} | `{row['bestmove']}` | {score_label} | "
            f"{row['depth']} | {row['nodes']} | {row['time_ms']} | {row['wall_ms']} |\n"
        )
    out.write("\n")

    out.write("## MultiPV Trace\n\n")
    for summary in multipv_summaries:
        movetime_ms = int(summary["movetime_ms"])
        out.write(f"### {movetime_ms} ms\n\n")
        out.write(
            f"Bestmove: `{summary['bestmove']}`, depth `{summary['depth']}`, "
            f"warm positions `{summary['warm_positions']}`\n\n"
        )
        out.write("| Rank | Root | Score | Depth | Nodes | Time ms | PV |\n")
        out.write("| ---: | --- | ---: | ---: | ---: | ---: | --- |\n")
        for row in multipv_rows.get(movetime_ms, []):
            out.write(
                f"| {row['multipv']} | `{row['root']}` | "
                f"{blunder_trace.cp_label(int(row['score_cp']))} | "
                f"{row['depth']} | {row['nodes']} | {row['time_ms']} | `{row['pv']}` |\n"
            )
        out.write("\n")

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(out.getvalue(), encoding="utf-8")

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "movetime_ms",
                "trace_mode",
                "rank",
                "root",
                "bestmove",
                "score_cp",
                "depth",
                "nodes",
                "time_ms",
                "pv",
            ],
        )
        writer.writeheader()
        for row in normal_rows:
            writer.writerow(
                {
                    "movetime_ms": row["movetime_ms"],
                    "trace_mode": "normal",
                    "rank": 1,
                    "root": row["bestmove"],
                    "bestmove": row["bestmove"],
                    "score_cp": row["score_cp"],
                    "depth": row["depth"],
                    "nodes": row["nodes"],
                    "time_ms": row["time_ms"],
                    "pv": "",
                }
            )
        for summary in multipv_summaries:
            movetime_ms = int(summary["movetime_ms"])
            for row in multipv_rows.get(movetime_ms, []):
                writer.writerow(
                    {
                        "movetime_ms": movetime_ms,
                        "trace_mode": summary["trace_mode"],
                        "rank": row["multipv"],
                        "root": row["root"],
                        "bestmove": summary["bestmove"],
                        "score_cp": row["score_cp"],
                        "depth": row["depth"],
                        "nodes": row["nodes"],
                        "time_ms": row["time_ms"],
                        "pv": row["pv"],
                    }
                )

    print(out.getvalue())
    print(f"Wrote {report_path}")
    print(f"Wrote {csv_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pgn", default="games/Games.pgn")
    parser.add_argument("--binary", default="./mantis_root_verify")
    parser.add_argument("--mantis-name", default="Mantis")
    parser.add_argument("--round", default="2", dest="round_name")
    parser.add_argument("--ply", type=int, default=36)
    parser.add_argument("--movetimes-ms", type=int, nargs="+", default=[250, 750, 1500, 3000])
    parser.add_argument("--warm-depth", type=int, default=8)
    parser.add_argument("--multipv", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--report", default="games/timed_root_trace_round2_ply36.md")
    parser.add_argument("--csv", default="games/timed_root_trace_round2_ply36.csv")
    args = parser.parse_args()

    target = find_target(
        pgn_path=Path(args.pgn),
        mantis_name=args.mantis_name,
        round_name=args.round_name,
        ply=args.ply,
    )

    normal_rows: list[dict[str, Any]] = []
    multipv_summaries: list[dict[str, Any]] = []
    multipv_rows: dict[int, list[dict[str, Any]]] = {}

    for movetime_ms in args.movetimes_ms:
        print(f"normal movetime={movetime_ms}ms", flush=True)
        normal_rows.append(
            run_normal_trace(
                binary=args.binary,
                target=target,
                movetime_ms=movetime_ms,
                warm_depth=args.warm_depth,
                timeout=args.timeout,
            )
        )
        print(f"multipv={args.multipv} movetime={movetime_ms}ms", flush=True)
        summary, rows = run_multipv_trace(
            binary=args.binary,
            target=target,
            movetime_ms=movetime_ms,
            warm_depth=args.warm_depth,
            multipv=args.multipv,
            timeout=args.timeout,
        )
        multipv_summaries.append(summary)
        multipv_rows[movetime_ms] = rows

    write_reports(
        target=target,
        normal_rows=normal_rows,
        multipv_summaries=multipv_summaries,
        multipv_rows=multipv_rows,
        report_path=Path(args.report),
        csv_path=Path(args.csv),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
