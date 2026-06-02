#!/usr/bin/env python3
"""Find and re-search Mantis eval drops from PGN practice games."""

from __future__ import annotations

import argparse
import csv
import io
import queue
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import chess
import chess.pgn

import stats_benchmark


EVAL_RE = re.compile(r"\[%eval\s+([^\]]+)\]")
MATE_SCORE = 100_000


class UCIEngine:
    def __init__(self, binary: str, timeout: float) -> None:
        self.binary = binary
        self.timeout = timeout
        self.process = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self.output_queue: queue.Queue[str] = queue.Queue()
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        self.send("uci")
        self.read_until("uciok", timeout)
        self.send("setoption name SearchStats value true")
        self.send("isready")
        self.read_until("readyok", timeout)

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=2.0)
            except Exception:
                self.process.kill()
                self.process.wait(timeout=2.0)

    def _read_stdout(self) -> None:
        if self.process.stdout is None:
            return
        for line in self.process.stdout:
            self.output_queue.put(line)

    def send(self, command: str) -> None:
        if self.process.stdin is None:
            raise RuntimeError("engine stdin is closed")
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def set_option(self, name: str, value: str | int | bool) -> None:
        if isinstance(value, bool):
            value_text = "true" if value else "false"
        else:
            value_text = str(value)
        self.send(f"setoption name {name} value {value_text}")
        self.send("isready")
        self.read_until("readyok", self.timeout)

    def new_game(self) -> None:
        self.send("ucinewgame")
        self.send("isready")
        self.read_until("readyok", self.timeout)

    def read_until(self, marker: str, timeout: float) -> str:
        output: list[str] = []
        deadline = time.monotonic() + timeout
        while True:
            if self.process.poll() is not None:
                raise RuntimeError(
                    f"engine exited before {marker!r}; output:\n{''.join(output)}"
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(self.binary, timeout, output="".join(output))
            try:
                line = self.output_queue.get(timeout=remaining)
            except queue.Empty:
                raise subprocess.TimeoutExpired(self.binary, timeout, output="".join(output))
            output.append(line)
            if marker in line:
                return "".join(output)

    def search_go_output(self, moves_so_far: list[str], go_command: str, timeout: float) -> tuple[dict[str, int | str], float, str]:
        if moves_so_far:
            self.send("position startpos moves " + " ".join(moves_so_far))
        else:
            self.send("position startpos")
        self.send(go_command)
        start = time.perf_counter()
        output = self.read_until("bestmove", timeout)
        wall_ms = (time.perf_counter() - start) * 1000.0
        return stats_benchmark.parse_stats(output), wall_ms, output

    def search_go_output_fen(self, fen: str, go_command: str, timeout: float) -> tuple[dict[str, int | str], float, str]:
        self.send("position fen " + fen)
        self.send(go_command)
        start = time.perf_counter()
        output = self.read_until("bestmove", timeout)
        wall_ms = (time.perf_counter() - start) * 1000.0
        return stats_benchmark.parse_stats(output), wall_ms, output

    def search_go(self, moves_so_far: list[str], go_command: str, timeout: float) -> tuple[dict[str, int | str], float]:
        stats, wall_ms, _output = self.search_go_output(moves_so_far, go_command, timeout)
        return stats, wall_ms

    def search_depth(self, moves_so_far: list[str], depth: int, timeout: float) -> tuple[dict[str, int | str], float]:
        return self.search_go(moves_so_far, f"go depth {depth}", timeout)

    def search_depth_fen(self, fen: str, depth: int, timeout: float) -> tuple[dict[str, int | str], float]:
        stats, wall_ms, _output = self.search_go_output_fen(fen, f"go depth {depth}", timeout)
        return stats, wall_ms

    def search_movetime(self, moves_so_far: list[str], movetime_ms: int, timeout: float) -> tuple[dict[str, int | str], float]:
        return self.search_go(moves_so_far, f"go movetime {movetime_ms}", timeout)

    def search_movetime_fen(self, fen: str, movetime_ms: int, timeout: float) -> tuple[dict[str, int | str], float]:
        stats, wall_ms, _output = self.search_go_output_fen(fen, f"go movetime {movetime_ms}", timeout)
        return stats, wall_ms

    def search_clock(self, moves_so_far: list[str], clock_ms: dict[str, int], timeout: float) -> tuple[dict[str, int | str], float]:
        return self.search_go(moves_so_far, stats_benchmark.clock_go_command(clock_ms), timeout)

    def search_clock_fen(self, fen: str, clock_ms: dict[str, int], timeout: float) -> tuple[dict[str, int | str], float]:
        stats, wall_ms, _output = self.search_go_output_fen(fen, stats_benchmark.clock_go_command(clock_ms), timeout)
        return stats, wall_ms


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
    oracle_rows: list[dict[str, Any]] = field(default_factory=list)


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


DEPTH_RE = re.compile(r"\bdepth (?P<depth>\d+)\b")
MULTIPV_RE = re.compile(r"\bmultipv (?P<multipv>\d+)\b")
SCORE_RE = re.compile(r"\bscore (?P<kind>cp|mate) (?P<score>-?\d+)\b")
NODES_RE = re.compile(r"\bnodes (?P<nodes>\d+)\b")
TIME_RE = re.compile(r"\btime (?P<time>\d+)\b")


def score_to_cp(kind: str, score: int) -> int:
    if kind == "mate":
        return MATE_SCORE if score > 0 else -MATE_SCORE
    return score


def parse_multipv(output: str) -> list[dict[str, Any]]:
    rows_by_rank: dict[int, dict[str, Any]] = {}
    for line in output.splitlines():
        if " multipv " not in line or " pv " not in line:
            continue
        multipv_match = MULTIPV_RE.search(line)
        score_match = SCORE_RE.search(line)
        if not multipv_match or not score_match:
            continue
        rank = int(multipv_match.group("multipv"))
        pv_text = line.split(" pv ", 1)[1].strip()
        pv_moves = pv_text.split()
        if not pv_moves:
            continue
        depth_match = DEPTH_RE.search(line)
        nodes_match = NODES_RE.search(line)
        time_match = TIME_RE.search(line)
        score_kind = score_match.group("kind")
        score_value = int(score_match.group("score"))
        rows_by_rank[rank] = {
            "rank": rank,
            "root": pv_moves[0],
            "score_cp": score_to_cp(score_kind, score_value),
            "score_kind": score_kind,
            "score_raw": score_value,
            "depth": int(depth_match.group("depth")) if depth_match else "",
            "nodes": int(nodes_match.group("nodes")) if nodes_match else "",
            "time_ms": int(time_match.group("time")) if time_match else "",
            "pv": " ".join(pv_moves),
        }
    return [rows_by_rank[rank] for rank in sorted(rows_by_rank)]


def oracle_summary(candidate: BlunderCandidate) -> dict[str, Any]:
    if not candidate.oracle_rows:
        return {}
    best = candidate.oracle_rows[0]
    played = next((row for row in candidate.oracle_rows if row["root"] == candidate.uci), None)
    if played is None:
        return {
            "bestmove": best["root"],
            "best_score_cp": best["score_cp"],
            "played_rank": "",
            "played_score_cp": "",
            "played_loss_cp": "",
        }
    return {
        "bestmove": best["root"],
        "best_score_cp": best["score_cp"],
        "played_rank": played["rank"],
        "played_score_cp": played["score_cp"],
        "played_loss_cp": best["score_cp"] - played["score_cp"],
    }


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
    movetimes_ms: list[int],
    clock_ms: dict[str, int] | None,
    timeout: float,
    limit: int,
) -> None:
    selected = candidates[:limit]
    specs = [("depth", depth, None, None) for depth in depths]
    specs.extend(("movetime", None, movetime_ms, None) for movetime_ms in movetimes_ms)
    if clock_ms is not None:
        specs.append(("clock", None, None, clock_ms))
    total = len(selected) * len(specs)
    done = 0
    for candidate in selected:
        for spec_type, depth, movetime_ms, clock_limit in specs:
            done += 1
            if depth is not None:
                search_label = f"d{depth}"
            elif movetime_ms is not None:
                search_label = f"{movetime_ms}ms"
            else:
                assert clock_limit is not None
                search_label = stats_benchmark.clock_label(clock_limit)
            print(
                f"[{done:>3}/{total}] round={candidate.round_name} "
                f"ply={candidate.ply} move={candidate.uci} search={search_label}",
                flush=True,
            )
            try:
                stats, _output, wall_ms = stats_benchmark.run_position(
                    binary=binary,
                    fen=candidate.fen,
                    depth=depth,
                    movetime_ms=movetime_ms,
                    clock_ms=clock_limit,
                    timeout=timeout,
                    clear_hash=True,
                    staged_picker=False,
                )
            except subprocess.TimeoutExpired:
                candidate.engine_rows.append(
                    {
                        "depth": depth if depth is not None else "",
                        "movetime_ms": movetime_ms if movetime_ms is not None else "",
                        "clock": stats_benchmark.clock_label(clock_limit) if clock_limit is not None else "",
                        "search_limit": search_label,
                        "search_mode": "cold",
                        "bestmove": "timeout",
                        "score_cp": "",
                        "nodes": "",
                        "time_ms": "",
                        "wall_ms": int(timeout * 1000),
                    }
                )
                continue

            row = {
                "depth": depth if depth is not None else stats.get("depth", ""),
                "movetime_ms": movetime_ms if movetime_ms is not None else "",
                "clock": stats_benchmark.clock_label(clock_limit) if clock_limit is not None else "",
                "search_limit": search_label,
                "search_mode": "cold",
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


def run_oracle_searches(
    candidates: list[BlunderCandidate],
    binary: str,
    depth: int,
    multipv: int,
    timeout: float,
    limit: int,
) -> None:
    selected = candidates[:limit]
    total = len(selected)
    for index, candidate in enumerate(selected, start=1):
        print(
            f"[oracle {index:>3}/{total}] round={candidate.round_name} "
            f"ply={candidate.ply} move={candidate.uci} depth={depth} multipv={multipv}",
            flush=True,
        )
        engine = UCIEngine(binary, timeout)
        try:
            engine.set_option("MultiPV", multipv)
            _stats, wall_ms, output = engine.search_go_output_fen(
                candidate.fen,
                f"go depth {depth}",
                timeout,
            )
        except subprocess.TimeoutExpired:
            candidate.oracle_rows.append(
                {
                    "rank": "",
                    "root": "timeout",
                    "score_cp": "",
                    "depth": depth,
                    "nodes": "",
                    "time_ms": int(timeout * 1000),
                    "wall_ms": int(timeout * 1000),
                    "pv": "",
                }
            )
        else:
            rows = parse_multipv(output)
            for row in rows:
                row["wall_ms"] = int(round(wall_ms))
            candidate.oracle_rows.extend(rows)
        finally:
            engine.close()


def run_stateful_replay(
    candidates: list[BlunderCandidate],
    pgn_path: Path,
    mantis_name: str,
    binary: str,
    depths: list[int],
    movetimes_ms: list[int],
    clock_ms: dict[str, int] | None,
    warm_depth: int,
    clear_hash_before_target: bool,
    target_from_fen: bool,
    timeout: float,
    limit: int,
) -> None:
    selected = candidates[:limit]
    targets: dict[tuple[int, int], BlunderCandidate] = {
        (candidate.game_index, candidate.ply): candidate for candidate in selected
    }
    target_games = {candidate.game_index for candidate in selected}
    last_target_ply = {
        game_index: max(candidate.ply for candidate in selected if candidate.game_index == game_index)
        for game_index in target_games
    }
    if not targets:
        return
    specs = [("depth", depth, None, None) for depth in depths]
    specs.extend(("movetime", None, movetime_ms, None) for movetime_ms in movetimes_ms)
    if clock_ms is not None:
        specs.append(("clock", None, None, clock_ms))
    contexts: dict[tuple[int, int], tuple[list[str], list[list[str]]]] = {}

    with pgn_path.open("r", encoding="utf-8", errors="replace") as handle:
        game_index = 0
        while True:
            game = chess.pgn.read_game(handle)
            if game is None:
                break
            game_index += 1
            if game_index not in target_games:
                continue

            mantis_color = mantis_color_for_game(game, mantis_name)
            if mantis_color is None:
                continue

            board = game.board()
            moves_so_far: list[str] = []
            warm_positions: list[list[str]] = []

            for ply, node in enumerate(game.mainline(), start=1):
                if ply > last_target_ply[game_index]:
                    break

                move = node.move
                mover_color = board.turn
                target = targets.get((game_index, ply))

                if mover_color == mantis_color and target is not None:
                    contexts[(game_index, ply)] = (moves_so_far.copy(), [position.copy() for position in warm_positions])
                if mover_color == mantis_color:
                    warm_positions.append(moves_so_far.copy())

                moves_so_far.append(move.uci())
                board.push(move)

    total = len(selected) * len(specs)
    done = 0
    for candidate in selected:
        context = contexts.get((candidate.game_index, candidate.ply))
        if context is None:
            continue
        moves_so_far, warm_positions = context
        for _spec_type, depth, movetime_ms, clock_limit in specs:
            done += 1
            if depth is not None:
                search_label = f"d{depth}"
            elif movetime_ms is not None:
                search_label = f"{movetime_ms}ms"
            else:
                assert clock_limit is not None
                search_label = stats_benchmark.clock_label(clock_limit)
            print(
                f"[stateful {done:>3}/{total}] round={candidate.round_name} "
                f"ply={candidate.ply} move={candidate.uci} search={search_label} "
                f"warm_positions={len(warm_positions)}",
                flush=True,
            )
            engine = UCIEngine(binary, timeout)
            try:
                engine.new_game()
                warmed = 0
                try:
                    for warm_moves in warm_positions:
                        engine.search_depth(warm_moves, warm_depth, timeout)
                        warmed += 1
                    if clear_hash_before_target:
                        engine.new_game()
                    if depth is not None:
                        if target_from_fen:
                            stats, wall_ms = engine.search_depth_fen(candidate.fen, depth, timeout)
                        else:
                            stats, wall_ms = engine.search_depth(moves_so_far, depth, timeout)
                    else:
                        if movetime_ms is not None:
                            if target_from_fen:
                                stats, wall_ms = engine.search_movetime_fen(candidate.fen, movetime_ms, timeout)
                            else:
                                stats, wall_ms = engine.search_movetime(moves_so_far, movetime_ms, timeout)
                        else:
                            assert clock_limit is not None
                            if target_from_fen:
                                stats, wall_ms = engine.search_clock_fen(candidate.fen, clock_limit, timeout)
                            else:
                                stats, wall_ms = engine.search_clock(moves_so_far, clock_limit, timeout)
                    mode_suffix = f"{'-clearhash' if clear_hash_before_target else ''}{'-fen' if target_from_fen else ''}"
                    row = {
                        "depth": depth if depth is not None else stats.get("depth", ""),
                        "movetime_ms": movetime_ms if movetime_ms is not None else "",
                        "clock": stats_benchmark.clock_label(clock_limit) if clock_limit is not None else "",
                        "search_limit": search_label,
                        "search_mode": f"stateful-warm{warm_depth}{mode_suffix}",
                        "bestmove": stats.get("bestmove", "?"),
                        "score_cp": stats.get("score_cp", ""),
                        "nodes": stats.get("nodes", ""),
                        "time_ms": stats.get("time_ms", ""),
                        "wall_ms": int(round(wall_ms)),
                        "asp_low": stats.get("asp_low", 0),
                        "asp_high": stats.get("asp_high", 0),
                        "asp_retry": stats.get("asp_retry", 0),
                        "asp_verify": stats.get("asp_verify", 0),
                        "warm_positions": warmed,
                    }
                except subprocess.TimeoutExpired:
                    mode_suffix = f"{'-clearhash' if clear_hash_before_target else ''}{'-fen' if target_from_fen else ''}"
                    row = {
                        "depth": depth if depth is not None else "",
                        "movetime_ms": movetime_ms if movetime_ms is not None else "",
                        "clock": stats_benchmark.clock_label(clock_limit) if clock_limit is not None else "",
                        "search_limit": search_label,
                        "search_mode": f"stateful-warm{warm_depth}{mode_suffix}",
                        "bestmove": "timeout",
                        "score_cp": "",
                        "nodes": "",
                        "time_ms": "",
                        "wall_ms": int(timeout * 1000),
                        "warm_positions": warmed,
                    }
                candidate.engine_rows.append(row)
            finally:
                engine.close()


def classify(candidate: BlunderCandidate) -> str:
    rows = [
        row
        for row in candidate.engine_rows
        if row.get("search_mode", "cold") == "cold" and row.get("bestmove") not in {"", "timeout", "?"}
    ]
    if not rows:
        rows = [
            row
            for row in candidate.engine_rows
            if row.get("bestmove") not in {"", "timeout", "?"}
        ]
    if not rows:
        return "needs search"
    last = str(rows[-1].get("bestmove"))
    if all(str(row.get("bestmove")) == candidate.uci for row in rows):
        return "still preferred by searched limits"
    if last == candidate.uci:
        return "returns to PGN move by final limit"
    if any(str(row.get("bestmove")) == candidate.uci for row in rows):
        return "horizon flip"
    return "searched limits avoid PGN move"


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
        "oracle_bestmove",
        "oracle_best_score_cp",
        "oracle_played_rank",
        "oracle_played_score_cp",
        "oracle_played_loss_cp",
        "search_mode",
        "search_limit",
        "depth",
        "movetime_ms",
        "clock",
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
            oracle = oracle_summary(candidate)
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
                            "oracle_bestmove": oracle.get("bestmove", ""),
                            "oracle_best_score_cp": oracle.get("best_score_cp", ""),
                            "oracle_played_rank": oracle.get("played_rank", ""),
                            "oracle_played_score_cp": oracle.get("played_score_cp", ""),
                            "oracle_played_loss_cp": oracle.get("played_loss_cp", ""),
                            "search_mode": row.get("search_mode", "cold"),
                            "search_limit": row.get("search_limit", row.get("depth", "")),
                            "depth": row.get("depth", ""),
                            "movetime_ms": row.get("movetime_ms", ""),
                            "clock": row.get("clock", ""),
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
                        "oracle_bestmove": oracle.get("bestmove", ""),
                        "oracle_best_score_cp": oracle.get("best_score_cp", ""),
                        "oracle_played_rank": oracle.get("played_rank", ""),
                        "oracle_played_score_cp": oracle.get("played_score_cp", ""),
                        "oracle_played_loss_cp": oracle.get("played_loss_cp", ""),
                        "fen": candidate.fen,
                    }
                )


def render_markdown(
    candidates: list[BlunderCandidate],
    stats: dict[str, int],
    pgn_path: Path,
    binary: str | None,
    depths: list[int],
    movetimes_ms: list[int],
    clock_ms: dict[str, int] | None,
    oracle_binary: str | None,
    oracle_depth: int,
    oracle_multipv: int,
    threshold_cp: int,
    max_before_abs_cp: int | None,
    mode: str,
    pool_count: int,
    collapse_before_cp: int,
    collapse_after_cp: int,
    stateful_replay: bool,
    warm_depth: int,
    clear_hash_before_target: bool,
    target_from_fen: bool,
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
        depth_label = ", ".join(str(depth) for depth in depths) if depths else "none"
        movetime_label = ", ".join(f"{value}ms" for value in movetimes_ms) if movetimes_ms else "none"
        clock_label = stats_benchmark.clock_label(clock_ms) if clock_ms is not None else "none"
        out.write(f"Depths: `{depth_label}`\n\n")
        out.write(f"Movetimes: `{movetime_label}`\n\n")
        out.write(f"Clock: `{clock_label}`\n\n")
    if stateful_replay:
        out.write(f"Stateful replay: `enabled`, warm depth `{warm_depth}`\n\n")
        if clear_hash_before_target:
            out.write("Stateful target hash: `cleared after warmup`\n\n")
        if target_from_fen:
            out.write("Stateful target position: `FEN`\n\n")
    if oracle_binary:
        out.write(
            f"Oracle: `{oracle_binary}`, depth `{oracle_depth}`, MultiPV `{oracle_multipv}`\n\n"
        )
    out.write("## Summary\n\n")
    out.write(f"- Games parsed: {stats['games']}\n")
    out.write(f"- Games with Mantis: {stats['mantis_games']}\n")
    out.write(f"- Mantis moves with adjacent evals: {stats['mantis_moves'] - stats['moves_missing_eval']}\n")
    out.write(f"- Mantis eval drops: {stats['moves_with_eval_drop']}\n")
    out.write(f"- Candidates at threshold: {pool_count}\n")
    out.write(f"- Candidates searched in this report: {len(selected)}\n\n")

    section_title = "First Collapses" if mode == "first-collapse" else "Worst Drops"
    out.write(f"## {section_title}\n\n")
    has_oracle = any(candidate.oracle_rows for candidate in selected)
    if has_oracle:
        out.write("| # | Round | Ply | Side | Move | Mantis Before | Mantis After | Drop | Classification | Oracle Best | Played Rank | Loss |\n")
        out.write("| ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | --- | --- | ---: | ---: |\n")
    else:
        out.write("| # | Round | Ply | Side | Move | Mantis Before | Mantis After | Drop | Classification |\n")
        out.write("| ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | --- |\n")
    for candidate in selected:
        base = (
            f"| {candidate.index} | {candidate.round_name} | {candidate.ply} | "
            f"{candidate.mantis_color} | `{candidate.uci}` `{candidate.san}` | "
            f"{cp_label(candidate.eval_before_mantis_cp)} | {cp_label(candidate.eval_after_mantis_cp)} | "
            f"{candidate.delta_cp:+d} | {classify(candidate)}"
        )
        if has_oracle:
            oracle = oracle_summary(candidate)
            loss = oracle.get("played_loss_cp", "")
            loss_label = cp_label(loss) if isinstance(loss, int) else ""
            out.write(
                f"{base} | `{oracle.get('bestmove', '')}` | "
                f"{oracle.get('played_rank', '')} | {loss_label} |\n"
            )
        else:
            out.write(f"{base} |\n")
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
        if candidate.oracle_rows:
            out.write("### Oracle MultiPV\n\n")
            out.write("| Rank | Root | Score | Depth | Nodes | Time ms | PV |\n")
            out.write("| ---: | --- | ---: | ---: | ---: | ---: | --- |\n")
            for row in candidate.oracle_rows:
                score = row.get("score_cp", "")
                score_label = cp_label(score) if isinstance(score, int) else "?"
                out.write(
                    f"| {row.get('rank', '')} | `{row.get('root', '')}` | {score_label} | "
                    f"{row.get('depth', '')} | {row.get('nodes', '')} | {row.get('time_ms', '')} | "
                    f"`{row.get('pv', '')}` |\n"
                )
            out.write("\n")
        if candidate.engine_rows:
            out.write("| Mode | Limit | Bestmove | Score | Nodes | Time ms | Asp low/high/retry/verify |\n")
            out.write("| --- | --- | --- | ---: | ---: | ---: | --- |\n")
            for row in candidate.engine_rows:
                score = row.get("score_cp", "")
                score_label = cp_label(int(score)) if isinstance(score, int) else "?"
                out.write(
                    f"| {row.get('search_mode', 'cold')} | {row.get('search_limit', row.get('depth', ''))} | "
                    f"`{row.get('bestmove', '')}` | "
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
    parser.add_argument(
        "--candidate-indexes",
        type=int,
        nargs="+",
        help="Only report selected candidate indexes after mode selection; preserves original candidate numbers",
    )
    parser.add_argument("--binary", help="Optional Mantis binary for fixed-depth re-search")
    parser.add_argument("--depths", type=int, nargs="+", default=[8, 10], help="Depths for fixed-depth re-search")
    parser.add_argument("--no-depths", action="store_true", help="Do not run fixed-depth target searches")
    parser.add_argument("--movetimes-ms", type=int, nargs="*", default=[], help="Movetime budgets for timed target searches")
    parser.add_argument(
        "--clock",
        type=int,
        nargs=4,
        metavar=("WTIME", "BTIME", "WINC", "BINC"),
        help="UCI clock budget for target searches, in milliseconds",
    )
    parser.add_argument("--movestogo", type=int, default=0, help="Optional UCI movestogo for --clock")
    parser.add_argument("--stateful-replay", action="store_true", help="Replay prior Mantis searches in one engine process before target positions")
    parser.add_argument("--warm-depth", type=int, default=8, help="Depth used to warm stateful replay before target positions")
    parser.add_argument(
        "--clear-hash-before-target",
        action="store_true",
        help="In stateful replay, clear TT after warming prior searches and before the target search",
    )
    parser.add_argument(
        "--stateful-target-fen",
        action="store_true",
        help="In stateful replay, set the target position from its FEN instead of replaying startpos moves",
    )
    parser.add_argument("--skip-cold", action="store_true", help="Only run stateful replay searches, not cold per-position searches")
    parser.add_argument("--oracle-binary", help="Optional external UCI engine used to validate candidate root moves")
    parser.add_argument("--oracle-depth", type=int, default=18, help="Depth for --oracle-binary searches")
    parser.add_argument("--oracle-multipv", type=int, default=6, help="MultiPV count for --oracle-binary searches")
    parser.add_argument("--oracle-timeout", type=float, default=120.0, help="Timeout per oracle search")
    parser.add_argument("--timeout", type=float, default=90.0, help="Timeout per engine search")
    parser.add_argument("--report", default="games/blunder_trace_report.md", help="Markdown report path")
    parser.add_argument("--csv", default="games/blunder_trace_report.csv", help="CSV report path")
    args = parser.parse_args()
    if args.clock:
        wtime, btime, winc, binc = args.clock
        if wtime <= 0 or btime <= 0:
            parser.error("--clock WTIME and BTIME must be positive")
        if winc < 0 or binc < 0:
            parser.error("--clock WINC and BINC must be non-negative")
    if args.movestogo < 0:
        parser.error("--movestogo must be non-negative")
    if args.oracle_depth <= 0:
        parser.error("--oracle-depth must be positive")
    if args.oracle_multipv <= 0:
        parser.error("--oracle-multipv must be positive")

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
    if args.candidate_indexes:
        wanted = set(args.candidate_indexes)
        candidates = [candidate for candidate in candidates if candidate.index in wanted]
    depths = [] if args.no_depths else args.depths
    movetimes_ms = args.movetimes_ms
    clock_ms: dict[str, int] | None = None
    if args.clock:
        wtime, btime, winc, binc = args.clock
        clock_ms = {
            "wtime": wtime,
            "btime": btime,
            "winc": winc,
            "binc": binc,
            "movestogo": args.movestogo,
        }
    if args.binary and not depths and not movetimes_ms and clock_ms is None:
        raise SystemExit("provide at least one depth, movetime, or clock budget when --binary is used")

    if args.binary and not args.skip_cold:
        run_engine_depths(
            candidates=candidates,
            binary=args.binary,
            depths=depths,
            movetimes_ms=movetimes_ms,
            clock_ms=clock_ms,
            timeout=args.timeout,
            limit=args.limit,
        )
    if args.binary and args.stateful_replay:
        run_stateful_replay(
            candidates=candidates,
            pgn_path=pgn_path,
            mantis_name=args.mantis_name,
            binary=args.binary,
            depths=depths,
            movetimes_ms=movetimes_ms,
            clock_ms=clock_ms,
            warm_depth=args.warm_depth,
            clear_hash_before_target=args.clear_hash_before_target,
            target_from_fen=args.stateful_target_fen,
            timeout=args.timeout,
            limit=args.limit,
        )
    if args.oracle_binary:
        run_oracle_searches(
            candidates=candidates,
            binary=args.oracle_binary,
            depth=args.oracle_depth,
            multipv=args.oracle_multipv,
            timeout=args.oracle_timeout,
            limit=args.limit,
        )

    report = render_markdown(
        candidates=candidates,
        stats=stats,
        pgn_path=pgn_path,
        binary=args.binary,
        depths=depths,
        movetimes_ms=movetimes_ms,
        clock_ms=clock_ms,
        oracle_binary=args.oracle_binary,
        oracle_depth=args.oracle_depth,
        oracle_multipv=args.oracle_multipv,
        threshold_cp=args.threshold_cp,
        max_before_abs_cp=None if args.max_before_abs_cp == 0 else args.max_before_abs_cp,
        mode=args.mode,
        pool_count=pool_count,
        collapse_before_cp=args.collapse_before_cp,
        collapse_after_cp=args.collapse_after_cp,
        stateful_replay=args.stateful_replay,
        warm_depth=args.warm_depth,
        clear_hash_before_target=args.clear_hash_before_target,
        target_from_fen=args.stateful_target_fen,
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
