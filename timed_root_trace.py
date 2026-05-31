#!/usr/bin/env python3
"""Trace warmed root choices for one or more PGN positions."""

from __future__ import annotations

import argparse
import csv
import io
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import chess
import chess.pgn

import blunder_trace


DEPTH_RE = re.compile(r"\bdepth (?P<depth>\d+)\b")
MULTIPV_RE = re.compile(r"\bmultipv (?P<multipv>\d+)\b")
SCORE_RE = re.compile(r"\bscore (?P<kind>cp|mate) (?P<score>-?\d+)\b")
NODES_RE = re.compile(r"\bnodes (?P<nodes>\d+)\b")
TIME_RE = re.compile(r"\btime (?P<time>\d+)\b")


@dataclass(frozen=True)
class SearchSpec:
    kind: str
    value: int

    @property
    def label(self) -> str:
        if self.kind == "depth":
            return f"d{self.value}"
        if self.kind == "movetime":
            return f"{self.value}ms"
        raise ValueError(f"unknown search kind: {self.kind}")

    @property
    def go_command(self) -> str:
        if self.kind == "depth":
            return f"go depth {self.value}"
        if self.kind == "movetime":
            return f"go movetime {self.value}"
        raise ValueError(f"unknown search kind: {self.kind}")


@dataclass
class TraceTarget:
    candidate: blunder_trace.BlunderCandidate
    moves_before: list[str]
    warm_positions: list[list[str]]


@dataclass
class TargetTrace:
    target: TraceTarget
    normal_rows: list[dict[str, Any]]
    multipv_summaries: list[dict[str, Any]]
    multipv_rows: dict[str, list[dict[str, Any]]]


def parse_target_arg(text: str) -> tuple[str, int]:
    if ":" not in text:
        raise argparse.ArgumentTypeError("target must be ROUND:PLY, for example 2:36")
    round_name, ply_text = text.rsplit(":", 1)
    if not round_name:
        raise argparse.ArgumentTypeError("target round cannot be empty")
    try:
        ply = int(ply_text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("target ply must be an integer") from exc
    if ply <= 0:
        raise argparse.ArgumentTypeError("target ply must be positive")
    return round_name, ply


def target_id(target: TraceTarget) -> str:
    round_text = re.sub(r"[^A-Za-z0-9_.-]+", "_", target.candidate.round_name)
    return f"round{round_text}_ply{target.candidate.ply}"


def default_report_paths(
    targets: list[tuple[str, int]],
    depths: list[int],
    movetimes_ms: list[int],
) -> tuple[Path, Path]:
    if depths and not movetimes_ms:
        prefix = "stateful_depth_root_trace"
    elif movetimes_ms and not depths:
        prefix = "timed_root_trace"
    else:
        prefix = "stateful_root_trace"

    if len(targets) == 1:
        round_name, ply = targets[0]
        round_text = re.sub(r"[^A-Za-z0-9_.-]+", "_", round_name)
        stem = f"{prefix}_round{round_text}_ply{ply}"
    else:
        stem = f"{prefix}_targets"
    return Path("games") / f"{stem}.md", Path("games") / f"{stem}.csv"


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
        while True:
            game = chess.pgn.read_game(handle)
            if game is None:
                break
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


def score_to_cp(kind: str, value: int) -> int:
    if kind == "cp":
        return value
    sign = 1 if value > 0 else -1
    return sign * (blunder_trace.MATE_SCORE - min(abs(value), 999))


def score_label(value: Any) -> str:
    if isinstance(value, int):
        return blunder_trace.cp_label(value)
    try:
        return blunder_trace.cp_label(int(value))
    except (TypeError, ValueError):
        return "?"


def parse_multipv(output: str) -> list[dict[str, Any]]:
    rows_by_key: dict[tuple[int, int], dict[str, Any]] = {}
    max_depth = -1
    for line in output.splitlines():
        if not line.startswith("info depth ") or " multipv " not in line or " pv " not in line:
            continue
        depth_match = DEPTH_RE.search(line)
        multipv_match = MULTIPV_RE.search(line)
        score_match = SCORE_RE.search(line)
        nodes_match = NODES_RE.search(line)
        time_match = TIME_RE.search(line)
        if (
            depth_match is None
            or multipv_match is None
            or score_match is None
            or nodes_match is None
            or time_match is None
        ):
            continue

        depth = int(depth_match.group("depth"))
        multipv = int(multipv_match.group("multipv"))
        score_kind = score_match.group("kind")
        score_raw = int(score_match.group("score"))
        pv_text = line.split(" pv ", 1)[1].strip()
        max_depth = max(max_depth, depth)
        rows_by_key[(depth, multipv)] = {
            "depth": depth,
            "multipv": multipv,
            "score_kind": score_kind,
            "score_raw": score_raw,
            "score_cp": score_to_cp(score_kind, score_raw),
            "nodes": int(nodes_match.group("nodes")),
            "time_ms": int(time_match.group("time")),
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
    spec: SearchSpec,
    warm_depth: int,
    timeout: float,
    root_debug: bool,
) -> dict[str, Any]:
    engine = blunder_trace.UCIEngine(binary, timeout)
    try:
        warmed = warm_engine(engine, target.warm_positions, warm_depth, timeout)
        if root_debug:
            engine.set_option("RootDebugTrace", True)
        stats, wall_ms, _output = engine.search_go_output(
            target.moves_before,
            spec.go_command,
            timeout,
        )
        return {
            "trace_mode": "normal",
            "search_kind": spec.kind,
            "search_value": spec.value,
            "search_label": spec.label,
            "warm_positions": warmed,
            "bestmove": stats.get("bestmove", "?"),
            "score_cp": stats.get("score_cp", ""),
            "depth": stats.get("depth", ""),
            "nodes": stats.get("nodes", ""),
            "time_ms": stats.get("time_ms", ""),
            "wall_ms": int(round(wall_ms)),
            "root_debug_lines": [
                line
                for line in _output.splitlines()
                if line.startswith("info string rootdebug ")
            ],
        }
    finally:
        engine.close()


def run_multipv_trace(
    binary: str,
    target: TraceTarget,
    spec: SearchSpec,
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
            spec.go_command,
            timeout,
        )
        summary = {
            "trace_mode": f"multipv{multipv}",
            "search_kind": spec.kind,
            "search_value": spec.value,
            "search_label": spec.label,
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
    traces: list[TargetTrace],
    binary: str,
    warm_depth: int,
    multipv: int,
    report_path: Path,
    csv_path: Path,
) -> None:
    out = io.StringIO()
    out.write("# Stateful Root Trace\n\n")
    out.write(f"Binary: `{binary}`\n\n")
    out.write(f"Warm depth: `{warm_depth}`\n\n")
    out.write(f"MultiPV: `{multipv}`\n\n")

    for trace in traces:
        target = trace.target
        candidate = target.candidate
        out.write(f"## Round {candidate.round_name}, Ply {candidate.ply}\n\n")
        out.write(f"Played: `{candidate.uci}` (`{candidate.san}`)\n\n")
        out.write(
            f"Mantis eval: {blunder_trace.cp_label(candidate.eval_before_mantis_cp)} -> "
            f"{blunder_trace.cp_label(candidate.eval_after_mantis_cp)} "
            f"({candidate.delta_cp:+d} cp)\n\n"
        )
        out.write(f"FEN: `{candidate.fen}`\n\n")

        out.write("### Normal Search\n\n")
        out.write("| Limit | Bestmove | Score | Depth | Nodes | Engine ms | Wall ms | Warm positions |\n")
        out.write("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
        for row in trace.normal_rows:
            out.write(
                f"| {row['search_label']} | `{row['bestmove']}` | {score_label(row.get('score_cp'))} | "
                f"{row['depth']} | {row['nodes']} | {row['time_ms']} | {row['wall_ms']} | "
                f"{row['warm_positions']} |\n"
            )
        out.write("\n")

        debug_rows = [
            row
            for row in trace.normal_rows
            if row.get("root_debug_lines")
        ]
        if debug_rows:
            out.write("### Normal Root Debug\n\n")
            for row in debug_rows:
                out.write(f"#### {row['search_label']}\n\n")
                out.write("```text\n")
                for line in row["root_debug_lines"]:
                    out.write(f"{line}\n")
                out.write("```\n\n")

        out.write("### MultiPV Trace\n\n")
        for summary in trace.multipv_summaries:
            spec_label = str(summary["search_label"])
            out.write(f"#### {spec_label}\n\n")
            out.write(
                f"Bestmove: `{summary['bestmove']}`, depth `{summary['depth']}`, "
                f"warm positions `{summary['warm_positions']}`\n\n"
            )
            out.write("| Rank | Root | Score | Depth | Nodes | Time ms | PV |\n")
            out.write("| ---: | --- | ---: | ---: | ---: | ---: | --- |\n")
            for row in trace.multipv_rows.get(spec_label, []):
                out.write(
                    f"| {row['multipv']} | `{row['root']}` | "
                    f"{score_label(row.get('score_cp'))} | "
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
                "target",
                "round",
                "ply",
                "played",
                "san",
                "fen",
                "search_kind",
                "search_value",
                "search_label",
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
        for trace in traces:
            target = trace.target
            candidate = target.candidate
            ident = target_id(target)
            for row in trace.normal_rows:
                writer.writerow(
                    {
                        "target": ident,
                        "round": candidate.round_name,
                        "ply": candidate.ply,
                        "played": candidate.uci,
                        "san": candidate.san,
                        "fen": candidate.fen,
                        "search_kind": row["search_kind"],
                        "search_value": row["search_value"],
                        "search_label": row["search_label"],
                        "trace_mode": "normal",
                        "rank": 1,
                        "root": row["bestmove"],
                        "bestmove": row["bestmove"],
                        "score_cp": row["score_cp"],
                        "depth": row["depth"],
                        "nodes": row["nodes"],
                        "time_ms": row["time_ms"],
                        "pv": " | ".join(row.get("root_debug_lines", [])),
                    }
                )
            for summary in trace.multipv_summaries:
                spec_label = str(summary["search_label"])
                for row in trace.multipv_rows.get(spec_label, []):
                    writer.writerow(
                        {
                            "target": ident,
                            "round": candidate.round_name,
                            "ply": candidate.ply,
                            "played": candidate.uci,
                            "san": candidate.san,
                            "fen": candidate.fen,
                            "search_kind": summary["search_kind"],
                            "search_value": summary["search_value"],
                            "search_label": spec_label,
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
    parser.add_argument("--target", action="append", type=parse_target_arg, help="Target ROUND:PLY; may be repeated")
    parser.add_argument("--round", default="2", dest="round_name", help="Single-target round fallback")
    parser.add_argument("--ply", type=int, default=36, help="Single-target ply fallback")
    parser.add_argument("--depths", type=int, nargs="*", default=None)
    parser.add_argument("--movetimes-ms", type=int, nargs="*", default=None)
    parser.add_argument("--warm-depth", type=int, default=8)
    parser.add_argument("--multipv", type=int, default=8)
    parser.add_argument("--root-debug", action="store_true", help="Enable RootDebugTrace during normal searches")
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--report")
    parser.add_argument("--csv")
    args = parser.parse_args()

    target_specs = args.target if args.target else [(args.round_name, args.ply)]
    depths = args.depths or []
    if args.movetimes_ms is None:
        movetimes_ms = [] if depths else [250, 750, 1500, 3000]
    else:
        movetimes_ms = args.movetimes_ms
    if not depths and not movetimes_ms:
        parser.error("provide at least one depth or movetime search limit")

    specs = [SearchSpec("depth", depth) for depth in depths]
    specs.extend(SearchSpec("movetime", movetime_ms) for movetime_ms in movetimes_ms)
    default_report, default_csv = default_report_paths(target_specs, depths, movetimes_ms)
    report_path = Path(args.report) if args.report else default_report
    csv_path = Path(args.csv) if args.csv else default_csv

    traces: list[TargetTrace] = []
    for round_name, ply in target_specs:
        target = find_target(
            pgn_path=Path(args.pgn),
            mantis_name=args.mantis_name,
            round_name=round_name,
            ply=ply,
        )
        normal_rows: list[dict[str, Any]] = []
        multipv_summaries: list[dict[str, Any]] = []
        multipv_rows: dict[str, list[dict[str, Any]]] = {}

        for spec in specs:
            print(f"normal target={target_id(target)} search={spec.label}", flush=True)
            normal_rows.append(
                run_normal_trace(
                    binary=args.binary,
                    target=target,
                    spec=spec,
                    warm_depth=args.warm_depth,
                    timeout=args.timeout,
                    root_debug=args.root_debug,
                )
            )
            print(f"multipv={args.multipv} target={target_id(target)} search={spec.label}", flush=True)
            summary, rows = run_multipv_trace(
                binary=args.binary,
                target=target,
                spec=spec,
                warm_depth=args.warm_depth,
                multipv=args.multipv,
                timeout=args.timeout,
            )
            multipv_summaries.append(summary)
            multipv_rows[spec.label] = rows

        traces.append(
            TargetTrace(
                target=target,
                normal_rows=normal_rows,
                multipv_summaries=multipv_summaries,
                multipv_rows=multipv_rows,
            )
        )

    write_reports(
        traces=traces,
        binary=args.binary,
        warm_depth=args.warm_depth,
        multipv=args.multipv,
        report_path=report_path,
        csv_path=csv_path,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
