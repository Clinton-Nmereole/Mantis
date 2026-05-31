#!/usr/bin/env python3
"""Find and re-search Mantis eval drops from PGN practice games."""

from __future__ import annotations

import argparse
import csv
import io
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import chess
import chess.pgn

import stats_benchmark


EVAL_RE = re.compile(r"\[%eval\s+([^\]]+)\]")
MATE_SCORE = 100_000


@dataclass
class BlunderCandidate:
    index: int
    game_index: int
    round_name: str
    result: str
    mantis_color: str
    mover: str
    ply: int
    fullmove: int
    san: str
    uci: str
    fen: str
    eval_before_cp: int
    eval_after_cp: int
    eval_before_mantis_cp: int
    eval_after_mantis_cp: int
    delta_cp: int
    comment: str
    engine_rows: list[dict[str, Any]] = field(default_factory=list)


def parse_eval_cp(comment: str) -> int | None:
    match = EVAL_RE.search(comment or "")
    if not match:
        return None
    raw = match.group(1).strip()
    raw = raw.replace("\n", " ").split()[0]
    if raw.startswith("#"):
        sign = -1 if "-" in raw else 1
        digits = "".join(ch for ch in raw if ch.isdigit())
        ply_distance = int(digits) if digits else 0
        return sign * (MATE_SCORE - min(ply_distance, 999))
    try:
        return int(round(float(raw) * 100))
    except ValueError:
        return None


def cp_label(value: int | None) -> str:
    if value is None:
        return "?"
    if abs(value) >= 90_000:
        sign = "+" if value > 0 else "-"
        return f"{sign}mate"
    return f"{value / 100.0:+.2f}"


def side_name(game: chess.pgn.Game, color: chess.Color) -> str:
    return game.headers.get("White" if color == chess.WHITE else "Black", "")


def mantis_color_for_game(game: chess.pgn.Game, needle: str) -> chess.Color | None:
    needle = needle.lower()
    white = game.headers.get("White", "").lower()
    black = game.headers.get("Black", "").lower()
    if needle in white:
        return chess.WHITE
    if needle in black:
        return chess.BLACK
    return None


def extract_candidates(
    pgn_path: Path,
    mantis_name: str,
    threshold_cp: int,
    max_before_abs_cp: int | None,
) -> tuple[list[BlunderCandidate], dict[str, int]]:
    candidates: list[BlunderCandidate] = []
    stats = {
        "games": 0,
        "mantis_games": 0,
        "mantis_moves": 0,
        "moves_with_eval_drop": 0,
        "moves_missing_eval": 0,
    }

    with pgn_path.open("r", encoding="utf-8", errors="replace") as handle:
        while True:
            game = chess.pgn.read_game(handle)
            if game is None:
                break
            stats["games"] += 1
            mantis_color = mantis_color_for_game(game, mantis_name)
            if mantis_color is None:
                continue
            stats["mantis_games"] += 1

            board = game.board()
            last_eval_cp: int | None = None
            last_eval_ply = -1

            for ply, node in enumerate(game.mainline(), start=1):
                move = node.move
                mover_color = board.turn
                before_fen = board.fen()
                san = board.san(move)
                fullmove = board.fullmove_number
                after_eval_cp = parse_eval_cp(node.comment)

                if mover_color == mantis_color:
                    stats["mantis_moves"] += 1
                    if after_eval_cp is None or last_eval_cp is None or last_eval_ply != ply - 1:
                        stats["moves_missing_eval"] += 1
                    else:
                        # PGN evals from Scid/Viridithas are white-perspective.
                        side_sign = 1 if mantis_color == chess.WHITE else -1
                        before_mantis_cp = last_eval_cp * side_sign
                        after_mantis_cp = after_eval_cp * side_sign
                        delta_cp = after_mantis_cp - before_mantis_cp
                        if delta_cp < 0:
                            stats["moves_with_eval_drop"] += 1
                        if (
                            delta_cp <= -threshold_cp
                            and (
                                max_before_abs_cp is None
                                or abs(last_eval_cp) <= max_before_abs_cp
                            )
                        ):
                            candidates.append(
                                BlunderCandidate(
                                    index=len(candidates) + 1,
                                    game_index=stats["games"],
                                    round_name=game.headers.get("Round", "?"),
                                    result=game.headers.get("Result", "?"),
                                    mantis_color="white" if mantis_color == chess.WHITE else "black",
                                    mover=side_name(game, mover_color),
                                    ply=ply,
                                    fullmove=fullmove,
                                    san=san,
                                    uci=move.uci(),
                                    fen=before_fen,
                                    eval_before_cp=last_eval_cp,
                                    eval_after_cp=after_eval_cp,
                                    eval_before_mantis_cp=before_mantis_cp,
                                    eval_after_mantis_cp=after_mantis_cp,
                                    delta_cp=delta_cp,
                                    comment=node.comment.strip(),
                                )
                            )

                board.push(move)
                if after_eval_cp is not None:
                    last_eval_cp = after_eval_cp
                    last_eval_ply = ply

    candidates.sort(key=lambda item: item.delta_cp)
    for index, item in enumerate(candidates, start=1):
        item.index = index
    return candidates, stats


def select_candidates(
    candidates: list[BlunderCandidate],
    mode: str,
    collapse_before_cp: int,
    collapse_after_cp: int,
) -> list[BlunderCandidate]:
    if mode == "worst":
        selected = sorted(candidates, key=lambda item: item.delta_cp)
    elif mode == "first-collapse":
        selected = []
        seen_games: set[int] = set()
        for candidate in sorted(candidates, key=lambda item: (item.game_index, item.ply)):
            if candidate.game_index in seen_games:
                continue
            if (
                candidate.eval_before_mantis_cp >= -collapse_before_cp
                and candidate.eval_after_mantis_cp <= -collapse_after_cp
            ):
                selected.append(candidate)
                seen_games.add(candidate.game_index)
    else:
        raise ValueError(f"unknown selection mode: {mode}")

    for index, item in enumerate(selected, start=1):
        item.index = index
    return selected


def run_engine_depths(
    candidates: list[BlunderCandidate],
    binary: str,
    depths: list[int],
    timeout: float,
    limit: int,
) -> None:
    selected = candidates[:limit]
    total = len(selected) * len(depths)
    done = 0
    for candidate in selected:
        for depth in depths:
            done += 1
            print(
                f"[{done:>3}/{total}] round={candidate.round_name} "
                f"ply={candidate.ply} move={candidate.uci} depth={depth}",
                flush=True,
            )
            try:
                stats, _output, wall_ms = stats_benchmark.run_position(
                    binary=binary,
                    fen=candidate.fen,
                    depth=depth,
                    timeout=timeout,
                    clear_hash=True,
                    staged_picker=False,
                )
            except subprocess.TimeoutExpired:
                candidate.engine_rows.append(
                    {
                        "depth": depth,
                        "bestmove": "timeout",
                        "score_cp": "",
                        "nodes": "",
                        "time_ms": "",
                        "wall_ms": int(timeout * 1000),
                    }
                )
                continue

            row = {
                "depth": depth,
                "bestmove": stats.get("bestmove", "?"),
                "score_cp": stats.get("score_cp", ""),
                "nodes": stats.get("nodes", ""),
                "time_ms": stats.get("time_ms", ""),
                "wall_ms": int(round(wall_ms)),
                "asp_low": stats.get("asp_low", 0),
                "asp_high": stats.get("asp_high", 0),
                "asp_retry": stats.get("asp_retry", 0),
                "asp_verify": stats.get("asp_verify", 0),
                "lmr_research": stats.get("search_lmr_research", stats.get("lmr_research", 0)),
                "pvs_research": stats.get("search_pvs_research", stats.get("pvs_research", 0)),
            }
            candidate.engine_rows.append(row)


def classify(candidate: BlunderCandidate) -> str:
    rows = [row for row in candidate.engine_rows if row.get("bestmove") not in {"", "timeout", "?"}]
    if not rows:
        return "needs search"
    last = str(rows[-1].get("bestmove"))
    if all(str(row.get("bestmove")) == candidate.uci for row in rows):
        return "still preferred at fixed depth"
    if last == candidate.uci:
        return "returns to PGN move by max depth"
    if any(str(row.get("bestmove")) == candidate.uci for row in rows):
        return "horizon flip"
    return "fixed-depth avoids PGN move"


def write_csv(candidates: list[BlunderCandidate], path: Path) -> None:
    fields = [
        "index",
        "round",
        "ply",
        "side",
        "played",
        "san",
        "delta_cp",
        "eval_before",
        "eval_after",
        "eval_before_mantis",
        "eval_after_mantis",
        "classification",
        "depth",
        "bestmove",
        "score_cp",
        "nodes",
        "time_ms",
        "fen",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for candidate in candidates:
            if candidate.engine_rows:
                for row in candidate.engine_rows:
                    writer.writerow(
                        {
                            "index": candidate.index,
                            "round": candidate.round_name,
                            "ply": candidate.ply,
                            "side": candidate.mantis_color,
                            "played": candidate.uci,
                            "san": candidate.san,
                            "delta_cp": candidate.delta_cp,
                            "eval_before": candidate.eval_before_cp,
                            "eval_after": candidate.eval_after_cp,
                            "eval_before_mantis": candidate.eval_before_mantis_cp,
                            "eval_after_mantis": candidate.eval_after_mantis_cp,
                            "classification": classify(candidate),
                            "depth": row.get("depth", ""),
                            "bestmove": row.get("bestmove", ""),
                            "score_cp": row.get("score_cp", ""),
                            "nodes": row.get("nodes", ""),
                            "time_ms": row.get("time_ms", ""),
                            "fen": candidate.fen,
                        }
                    )
            else:
                writer.writerow(
                    {
                        "index": candidate.index,
                        "round": candidate.round_name,
                        "ply": candidate.ply,
                        "side": candidate.mantis_color,
                        "played": candidate.uci,
                        "san": candidate.san,
                        "delta_cp": candidate.delta_cp,
                        "eval_before": candidate.eval_before_cp,
                        "eval_after": candidate.eval_after_cp,
                        "eval_before_mantis": candidate.eval_before_mantis_cp,
                        "eval_after_mantis": candidate.eval_after_mantis_cp,
                        "classification": classify(candidate),
                        "fen": candidate.fen,
                    }
                )


def render_markdown(
    candidates: list[BlunderCandidate],
    stats: dict[str, int],
    pgn_path: Path,
    binary: str | None,
    depths: list[int],
    threshold_cp: int,
    max_before_abs_cp: int | None,
    mode: str,
    pool_count: int,
    collapse_before_cp: int,
    collapse_after_cp: int,
    limit: int,
) -> str:
    selected = candidates[:limit]
    out = io.StringIO()
    out.write("# Mantis Blunder Trace\n\n")
    out.write(f"PGN: `{pgn_path}`\n\n")
    out.write(f"Selection mode: `{mode}`\n\n")
    out.write(f"Threshold: `{threshold_cp}` cp drop from Mantis' perspective\n\n")
    if max_before_abs_cp is not None:
        out.write(f"Previous-eval filter: `abs(eval_before) <= {max_before_abs_cp}` cp\n\n")
    if mode == "first-collapse":
        out.write(
            "First-collapse filter: "
            f"`before >= -{collapse_before_cp}` and `after <= -{collapse_after_cp}` "
            "from Mantis' perspective\n\n"
        )
    if binary:
        out.write(f"Binary: `{binary}`\n\n")
        out.write(f"Depths: `{', '.join(str(depth) for depth in depths)}`\n\n")
    out.write("## Summary\n\n")
    out.write(f"- Games parsed: {stats['games']}\n")
    out.write(f"- Games with Mantis: {stats['mantis_games']}\n")
    out.write(f"- Mantis moves with adjacent evals: {stats['mantis_moves'] - stats['moves_missing_eval']}\n")
    out.write(f"- Mantis eval drops: {stats['moves_with_eval_drop']}\n")
    out.write(f"- Candidates at threshold: {pool_count}\n")
    out.write(f"- Candidates searched in this report: {len(selected)}\n\n")

    section_title = "First Collapses" if mode == "first-collapse" else "Worst Drops"
    out.write(f"## {section_title}\n\n")
    out.write("| # | Round | Ply | Side | Move | Mantis Before | Mantis After | Drop | Classification |\n")
    out.write("| ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | --- |\n")
    for candidate in selected:
        out.write(
            f"| {candidate.index} | {candidate.round_name} | {candidate.ply} | "
            f"{candidate.mantis_color} | `{candidate.uci}` `{candidate.san}` | "
            f"{cp_label(candidate.eval_before_mantis_cp)} | {cp_label(candidate.eval_after_mantis_cp)} | "
            f"{candidate.delta_cp:+d} | {classify(candidate)} |\n"
        )
    out.write("\n")

    for candidate in selected:
        out.write(f"## Candidate {candidate.index}: Round {candidate.round_name}, Ply {candidate.ply}\n\n")
        out.write(f"Played: `{candidate.uci}` (`{candidate.san}`), Mantis as {candidate.mantis_color}\n\n")
        out.write(
            f"Mantis eval: {cp_label(candidate.eval_before_mantis_cp)} -> "
            f"{cp_label(candidate.eval_after_mantis_cp)} ({candidate.delta_cp:+d} cp)\n\n"
        )
        out.write(
            f"White-perspective PGN eval: {cp_label(candidate.eval_before_cp)} -> "
            f"{cp_label(candidate.eval_after_cp)}\n\n"
        )
        out.write(f"FEN: `{candidate.fen}`\n\n")
        if candidate.engine_rows:
            out.write("| Depth | Bestmove | Score | Nodes | Time ms | Asp low/high/retry/verify |\n")
            out.write("| ---: | --- | ---: | ---: | ---: | --- |\n")
            for row in candidate.engine_rows:
                score = row.get("score_cp", "")
                score_label = cp_label(int(score)) if isinstance(score, int) else "?"
                out.write(
                    f"| {row.get('depth', '')} | `{row.get('bestmove', '')}` | "
                    f"{score_label} | {row.get('nodes', '')} | {row.get('time_ms', '')} | "
                    f"{row.get('asp_low', 0)}/{row.get('asp_high', 0)}/"
                    f"{row.get('asp_retry', 0)}/{row.get('asp_verify', 0)} |\n"
                )
            out.write("\n")
    return out.getvalue()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pgn", default="games/Games.pgn", help="PGN file to analyze")
    parser.add_argument("--mantis-name", default="Mantis", help="Substring identifying Mantis in PGN player names")
    parser.add_argument(
        "--mode",
        choices=["worst", "first-collapse"],
        default="worst",
        help="Select worst drops globally or the first collapse in each game",
    )
    parser.add_argument("--threshold-cp", type=int, default=150, help="Minimum Mantis-perspective eval drop")
    parser.add_argument(
        "--max-before-abs-cp",
        type=int,
        default=3000,
        help="Ignore drops where the previous eval was already beyond this absolute cp value; use 0 to disable",
    )
    parser.add_argument(
        "--collapse-before-cp",
        type=int,
        default=400,
        help="For first-collapse mode, require the prior Mantis eval to be at least this playable threshold",
    )
    parser.add_argument(
        "--collapse-after-cp",
        type=int,
        default=600,
        help="For first-collapse mode, require the post-move Mantis eval to be this bad or worse",
    )
    parser.add_argument("--limit", type=int, default=16, help="Number of worst candidates to search/report")
    parser.add_argument("--binary", help="Optional Mantis binary for fixed-depth re-search")
    parser.add_argument("--depths", type=int, nargs="+", default=[8, 10], help="Depths for fixed-depth re-search")
    parser.add_argument("--timeout", type=float, default=90.0, help="Timeout per engine search")
    parser.add_argument("--report", default="games/blunder_trace_report.md", help="Markdown report path")
    parser.add_argument("--csv", default="games/blunder_trace_report.csv", help="CSV report path")
    args = parser.parse_args()

    pgn_path = Path(args.pgn)
    if not pgn_path.exists():
        raise SystemExit(f"PGN not found: {pgn_path}")

    candidates, stats = extract_candidates(
        pgn_path=pgn_path,
        mantis_name=args.mantis_name,
        threshold_cp=args.threshold_cp,
        max_before_abs_cp=None if args.max_before_abs_cp == 0 else args.max_before_abs_cp,
    )
    pool_count = len(candidates)
    candidates = select_candidates(
        candidates=candidates,
        mode=args.mode,
        collapse_before_cp=args.collapse_before_cp,
        collapse_after_cp=args.collapse_after_cp,
    )

    if args.binary:
        run_engine_depths(
            candidates=candidates,
            binary=args.binary,
            depths=args.depths,
            timeout=args.timeout,
            limit=args.limit,
        )

    report = render_markdown(
        candidates=candidates,
        stats=stats,
        pgn_path=pgn_path,
        binary=args.binary,
        depths=args.depths,
        threshold_cp=args.threshold_cp,
        max_before_abs_cp=None if args.max_before_abs_cp == 0 else args.max_before_abs_cp,
        mode=args.mode,
        pool_count=pool_count,
        collapse_before_cp=args.collapse_before_cp,
        collapse_after_cp=args.collapse_after_cp,
        limit=args.limit,
    )
    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report, encoding="utf-8")
    csv_path = Path(args.csv)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    write_csv(candidates[: args.limit], csv_path)

    print(report)
    print(f"Wrote {report_path}")
    print(f"Wrote {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
