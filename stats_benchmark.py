#!/usr/bin/env python3
"""Repeatable SearchStats benchmark harness for Mantis."""

from __future__ import annotations

import argparse
import csv
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path


STAT_RE = re.compile(r"([a-zA-Z_]+)=([0-9]+)")
RATIO_RE = re.compile(r"([a-zA-Z_]+)=([0-9]+)/([0-9]+)")
FEN_RE = re.compile(r'"([^"]+)"')
MATE_SCORE = 100_000
WHITE = "w"
BLACK = "b"
WHITE_PIECES = set("PNBRQK")
BLACK_PIECES = set("pnbrqk")
FEN_PIECES = WHITE_PIECES | BLACK_PIECES


def load_bench_fens(source: Path) -> list[str]:
    text = source.read_text()
    start = text.find("BENCH_FENS")
    if start < 0:
        raise RuntimeError(f"Could not find BENCH_FENS in {source}")
    block_start = text.find("{", start)
    block_end = text.find("}", block_start)
    if block_start < 0 or block_end < 0:
        raise RuntimeError(f"Could not parse BENCH_FENS block in {source}")

    fens: list[str] = []
    for line in text[block_start:block_end].splitlines():
        line = line.strip()
        if not line.startswith('"'):
            continue
        match = FEN_RE.search(line)
        if match:
            fens.append(match.group(1))
    if not fens:
        raise RuntimeError(f"No FENs found in BENCH_FENS block in {source}")
    return fens


def square(file: int, rank: int) -> int:
    return rank * 8 + file


def parse_fen_board(fen: str) -> tuple[list[str | None], str, list[str]]:
    parts = fen.split()
    errors: list[str] = []
    board: list[str | None] = [None] * 64

    if len(parts) != 6:
        errors.append(f"expected 6 FEN fields, got {len(parts)}")
        return board, WHITE, errors

    placement, side_to_move, castling, en_passant, halfmove, fullmove = parts

    if side_to_move not in {WHITE, BLACK}:
        errors.append(f"invalid side to move: {side_to_move}")

    ranks = placement.split("/")
    if len(ranks) != 8:
        errors.append(f"piece placement has {len(ranks)} ranks")
        return board, side_to_move, errors

    for fen_rank, rank_text in enumerate(ranks):
        rank = 7 - fen_rank
        file = 0
        for char in rank_text:
            if char.isdigit():
                if char == "0":
                    errors.append("rank contains zero-width digit")
                    continue
                file += int(char)
                continue
            if char not in FEN_PIECES:
                errors.append(f"invalid piece character: {char}")
                continue
            if file >= 8:
                errors.append(f"rank {8 - fen_rank} has too many squares")
                continue
            board[square(file, rank)] = char
            file += 1
        if file != 8:
            errors.append(f"rank {8 - fen_rank} has {file} squares")

    if castling != "-" and any(char not in "KQkq" for char in castling):
        errors.append(f"invalid castling rights: {castling}")
    if en_passant != "-":
        if len(en_passant) != 2 or en_passant[0] not in "abcdefgh" or en_passant[1] not in "36":
            errors.append(f"invalid en passant square: {en_passant}")
    if not halfmove.isdigit():
        errors.append(f"invalid halfmove clock: {halfmove}")
    if not fullmove.isdigit() or int(fullmove) < 1:
        errors.append(f"invalid fullmove number: {fullmove}")

    return board, side_to_move, errors


def piece_side(piece: str | None) -> str | None:
    if piece is None:
        return None
    return WHITE if piece in WHITE_PIECES else BLACK


def find_piece(board: list[str | None], piece: str) -> list[int]:
    return [index for index, value in enumerate(board) if value == piece]


def side_piece(piece: str, side: str, white_piece: str) -> bool:
    return piece == white_piece if side == WHITE else piece == white_piece.lower()


def attacks_square(board: list[str | None], side: str, target: int) -> bool:
    target_file = target % 8
    target_rank = target // 8

    pawn_rank = target_rank - 1 if side == WHITE else target_rank + 1
    for pawn_file in (target_file - 1, target_file + 1):
        if 0 <= pawn_file < 8 and 0 <= pawn_rank < 8:
            piece = board[square(pawn_file, pawn_rank)]
            if piece is not None and side_piece(piece, side, "P"):
                return True

    for df, dr in ((1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)):
        file = target_file + df
        rank = target_rank + dr
        if 0 <= file < 8 and 0 <= rank < 8:
            piece = board[square(file, rank)]
            if piece is not None and side_piece(piece, side, "N"):
                return True

    for df in (-1, 0, 1):
        for dr in (-1, 0, 1):
            if df == 0 and dr == 0:
                continue
            file = target_file + df
            rank = target_rank + dr
            if 0 <= file < 8 and 0 <= rank < 8:
                piece = board[square(file, rank)]
                if piece is not None and side_piece(piece, side, "K"):
                    return True

    directions = (
        (1, 0, "RQ"),
        (-1, 0, "RQ"),
        (0, 1, "RQ"),
        (0, -1, "RQ"),
        (1, 1, "BQ"),
        (1, -1, "BQ"),
        (-1, 1, "BQ"),
        (-1, -1, "BQ"),
    )
    for df, dr, attackers in directions:
        file = target_file + df
        rank = target_rank + dr
        while 0 <= file < 8 and 0 <= rank < 8:
            piece = board[square(file, rank)]
            if piece is not None:
                if piece_side(piece) == side and piece.upper() in attackers:
                    return True
                break
            file += df
            rank += dr

    return False


def validate_fen(fen: str) -> list[str]:
    board, side_to_move, errors = parse_fen_board(fen)
    if errors:
        return errors

    white_piece_count = sum(1 for piece in board if piece in WHITE_PIECES)
    black_piece_count = sum(1 for piece in board if piece in BLACK_PIECES)
    total_piece_count = white_piece_count + black_piece_count
    if total_piece_count > 32:
        errors.append(f"too many pieces: {total_piece_count}")
    if white_piece_count > 16:
        errors.append(f"too many white pieces: {white_piece_count}")
    if black_piece_count > 16:
        errors.append(f"too many black pieces: {black_piece_count}")

    white_kings = find_piece(board, "K")
    black_kings = find_piece(board, "k")
    if len(white_kings) != 1:
        errors.append(f"expected 1 white king, got {len(white_kings)}")
    if len(black_kings) != 1:
        errors.append(f"expected 1 black king, got {len(black_kings)}")
    if errors:
        return errors

    for index, piece in enumerate(board):
        rank = index // 8
        if piece in {"P", "p"} and rank in {0, 7}:
            errors.append("pawn on first or eighth rank")
            break

    opponent_king = black_kings[0] if side_to_move == WHITE else white_kings[0]
    if attacks_square(board, side_to_move, opponent_king):
        errors.append("side to move attacks the opponent king")

    return errors


def validate_fens(fens: list[str]) -> None:
    invalid: list[str] = []
    for index, fen in enumerate(fens, start=1):
        errors = validate_fen(fen)
        if errors:
            invalid.append(f"{index}: {'; '.join(errors)} | {fen}")
    if invalid:
        detail = "\n".join(invalid)
        raise ValueError(f"Invalid benchmark FENs:\n{detail}")


def clock_label(clock: dict[str, int]) -> str:
    label = (
        f"wtime={clock['wtime']} btime={clock['btime']} "
        f"winc={clock['winc']} binc={clock['binc']}"
    )
    if clock.get("movestogo", 0) > 0:
        label += f" movestogo={clock['movestogo']}"
    return label


def clock_go_command(clock: dict[str, int]) -> str:
    command = (
        f"go wtime {clock['wtime']} btime {clock['btime']} "
        f"winc {clock['winc']} binc {clock['binc']}"
    )
    if clock.get("movestogo", 0) > 0:
        command += f" movestogo {clock['movestogo']}"
    return command


def parse_engine_options(raw_options: list[str] | None) -> list[tuple[str, str]]:
    """Parse repeated Name=Value CLI options into UCI setoption pairs."""
    options: list[tuple[str, str]] = []
    for raw in raw_options or []:
        if "=" not in raw:
            raise ValueError(f"engine option must be Name=Value: {raw}")
        name, value = raw.split("=", 1)
        name = name.strip()
        value = value.strip()
        if not name or not value:
            raise ValueError(f"engine option must be Name=Value: {raw}")
        options.append((name, value))
    return options


def setoption_command(option: tuple[str, str]) -> str:
    name, value = option
    return f"setoption name {name} value {value}"


def score_to_cp(kind: str, score: int) -> int:
    if kind == "mate":
        sign = 1 if score > 0 else -1
        return sign * (MATE_SCORE - min(abs(score), 999))
    return score


def parse_stats(output: str) -> dict[str, int | str]:
    stats: dict[str, int | str] = {}
    for line in output.splitlines():
        if line.startswith("info depth "):
            depth_match = re.search(r"info depth ([0-9]+)", line)
            score_match = re.search(r"score (cp|mate) (-?[0-9]+)", line)
            nodes_match = re.search(r"nodes ([0-9]+)", line)
            time_match = re.search(r"time ([0-9]+)", line)
            nps_match = re.search(r"nps ([0-9]+)", line)
            if depth_match:
                stats["depth"] = int(depth_match.group(1))
            if score_match:
                score_kind = score_match.group(1)
                score_raw = int(score_match.group(2))
                stats["score_kind"] = score_kind
                stats["score_raw"] = score_raw
                stats["score_cp"] = score_to_cp(score_kind, score_raw)
            if nodes_match:
                stats["nodes"] = int(nodes_match.group(1))
            if time_match:
                stats["time_ms"] = int(time_match.group(1))
            if nps_match:
                stats["nps"] = int(nps_match.group(1))

        if line.startswith("info string stats "):
            for key, cutoffs, tries in RATIO_RE.findall(line):
                stats[key] = int(cutoffs)
                stats[f"{key}_cutoffs"] = int(cutoffs)
                stats[f"{key}_tries"] = int(tries)
            for key, value in STAT_RE.findall(line):
                if line.startswith("info string stats ttmove ") and key in {"probes", "hits", "invalid", "ordered"}:
                    stats[f"ttmove_{key}"] = int(value)
                    continue
                if line.startswith("info string stats moveorder ") and key in {
                    "tt_first",
                    "tt_first_legal",
                    "tt_legal_rejects",
                    "root_pv_ordered",
                    "root_pv_first",
                    "root_pv_first_legal",
                }:
                    stats[f"moveorder_{key}"] = int(value)
                    continue
                if line.startswith("info string stats search ") and key in {
                    "beta_cutoffs",
                    "quiet_beta",
                    "capture_beta",
                    "capture_hist_updates",
                    "capture_hist_maluses",
                    "cont_updates",
                    "cont_maluses",
                }:
                    stats[f"search_{key}"] = int(value)
                    continue
                if line.startswith("info string stats see ") and key in {"cache_hits", "qsee_prunes"}:
                    stats[f"see_{key}"] = int(value)
                    continue
                if key not in stats:
                    stats[key] = int(value)

        if line.startswith("bestmove "):
            parts = line.split()
            if len(parts) >= 2:
                stats["bestmove"] = parts[1]

    if "bestmove" not in stats:
        raise RuntimeError(f"Engine did not return bestmove. Output:\n{output}")
    return stats


def run_position(
    binary: str,
    fen: str,
    depth: int | None,
    timeout: float,
    clear_hash: bool,
    staged_picker: bool,
    own_book: bool = False,
    movetime_ms: int | None = None,
    clock_ms: dict[str, int] | None = None,
    options: list[tuple[str, str]] | None = None,
) -> tuple[dict[str, int | str], str, float]:
    modes = sum(
        1
        for enabled in (
            depth is not None,
            movetime_ms is not None,
            clock_ms is not None,
        )
        if enabled
    )
    if modes != 1:
        raise ValueError("provide exactly one of depth, movetime_ms, or clock_ms")

    if clock_ms is not None:
        go_command = clock_go_command(clock_ms)
    elif movetime_ms is not None:
        go_command = f"go movetime {movetime_ms}"
    else:
        go_command = f"go depth {depth}"
    commands = [
        "uci",
        f"setoption name OwnBook value {'true' if own_book else 'false'}",
    ]
    commands.extend(setoption_command(option) for option in options or [])
    commands.append("setoption name SearchStats value true")
    if staged_picker:
        commands.append("setoption name StagedMovePicker value true")
    commands.append("isready")
    if clear_hash:
        commands.append("ucinewgame")
    commands.extend([
        f"position fen {fen}",
        go_command,
        "quit",
    ])
    command = "\n".join(commands) + "\n"

    start = time.perf_counter()
    output = subprocess.check_output(
        [binary],
        input=command,
        text=True,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    wall_ms = (time.perf_counter() - start) * 1000.0
    stats = parse_stats(output)
    return stats, output, wall_ms


def pct(num: int, denom: int) -> float:
    if denom == 0:
        return 0.0
    return 100.0 * num / denom


def print_summary(rows: list[dict[str, int | str]]) -> None:
    total_nodes = sum(int(row.get("nodes", 0)) for row in rows)
    total_time = sum(int(row.get("time_ms", 0)) for row in rows)
    total_qnodes = sum(int(row.get("qnodes", 0)) for row in rows)
    total_tt_probes = sum(int(row.get("probes", 0)) for row in rows)
    total_tt_hits = sum(int(row.get("hits", 0)) for row in rows)
    total_tt_cutoffs = sum(int(row.get("cutoffs", 0)) for row in rows)
    total_lmr = sum(int(row.get("lmr", 0)) for row in rows)
    total_lmr_research = sum(int(row.get("lmr_research", 0)) for row in rows)
    total_pvs_research = sum(int(row.get("pvs_research", 0)) for row in rows)
    total_asp_low = sum(int(row.get("asp_low", 0)) for row in rows)
    total_asp_high = sum(int(row.get("asp_high", 0)) for row in rows)
    total_asp_retry = sum(int(row.get("asp_retry", 0)) for row in rows)
    total_asp_verify = sum(int(row.get("asp_verify", 0)) for row in rows)
    total_beta_cutoffs = sum(int(row.get("search_beta_cutoffs", 0)) for row in rows)
    total_quiet_beta = sum(int(row.get("search_quiet_beta", 0)) for row in rows)
    total_capture_beta = sum(int(row.get("search_capture_beta", 0)) for row in rows)
    total_capture_hist_updates = sum(int(row.get("search_capture_hist_updates", 0)) for row in rows)
    total_capture_hist_maluses = sum(int(row.get("search_capture_hist_maluses", 0)) for row in rows)
    total_cont_updates = sum(int(row.get("search_cont_updates", 0)) for row in rows)
    total_cont_maluses = sum(int(row.get("search_cont_maluses", 0)) for row in rows)
    total_cont_score_probes = sum(int(row.get("cont_score_probes", 0)) for row in rows)
    total_cont_raw_nonzero = sum(int(row.get("cont_raw_nonzero", 0)) for row in rows)
    total_cont_raw_positive = sum(int(row.get("cont_raw_positive", 0)) for row in rows)
    total_cont_raw_negative = sum(int(row.get("cont_raw_negative", 0)) for row in rows)
    total_cont_raw_abs_sum = sum(int(row.get("cont_raw_abs_sum", 0)) for row in rows)
    total_cont_raw_under_scale = sum(int(row.get("cont_raw_under_scale", 0)) for row in rows)
    total_cont_score_nonzero = sum(int(row.get("cont_score_nonzero", 0)) for row in rows)
    total_cont_score_positive = sum(int(row.get("cont_score_positive", 0)) for row in rows)
    total_cont_score_negative = sum(int(row.get("cont_score_negative", 0)) for row in rows)
    total_cont_score_abs_sum = sum(int(row.get("cont_score_abs_sum", 0)) for row in rows)
    total_cont_store_bonus_under_scale = sum(int(row.get("cont_store_bonus_under_scale", 0)) for row in rows)
    total_cont_store_bonus_visible = sum(int(row.get("cont_store_bonus_visible", 0)) for row in rows)
    total_cont_store_result_under_scale = sum(int(row.get("cont_store_result_under_scale", 0)) for row in rows)
    total_cont_store_result_visible = sum(int(row.get("cont_store_result_visible", 0)) for row in rows)
    total_nmp_tries = sum(int(row.get("nmp_tries", 0)) for row in rows)
    total_nmp_cutoffs = sum(int(row.get("nmp_cutoffs", 0)) for row in rows)
    total_probcut_tries = sum(int(row.get("probcut_tries", 0)) for row in rows)
    total_probcut_cutoffs = sum(int(row.get("probcut_cutoffs", 0)) for row in rows)
    total_hash_probes = sum(int(row.get("ttmove_probes", 0)) for row in rows)
    total_hash_hits = sum(int(row.get("ttmove_hits", 0)) for row in rows)
    total_hash_ordered = sum(int(row.get("ttmove_ordered", 0)) for row in rows)
    total_depth_misses = sum(int(row.get("depth_misses", 0)) for row in rows)
    total_tt_first = sum(int(row.get("moveorder_tt_first", 0)) for row in rows)
    total_tt_first_legal = sum(int(row.get("moveorder_tt_first_legal", 0)) for row in rows)
    total_root_pv_ordered = sum(int(row.get("moveorder_root_pv_ordered", 0)) for row in rows)
    total_root_pv_first = sum(int(row.get("moveorder_root_pv_first", 0)) for row in rows)
    total_root_pv_first_legal = sum(int(row.get("moveorder_root_pv_first_legal", 0)) for row in rows)

    nps = total_nodes * 1000 // total_time if total_time > 0 else 0
    qnode_pct = pct(total_qnodes, total_nodes)
    tt_hit_pct = pct(total_tt_hits, total_tt_probes)
    tt_cut_pct = pct(total_tt_cutoffs, total_tt_probes)
    lmr_research_pct = pct(total_lmr_research, total_lmr)

    print("\n=== Summary ===")
    print(f"positions:           {len(rows)}")
    print(f"nodes:               {total_nodes}")
    print(f"time_ms:             {total_time}")
    print(f"nps:                 {nps}")
    print(f"qnode_pct:           {qnode_pct:.1f}")
    print(f"tt_hit_pct:          {tt_hit_pct:.1f}")
    print(f"tt_cut_pct:          {tt_cut_pct:.1f}")
    print(f"tt_depth_misses:     {total_depth_misses}")
    if total_hash_probes > 0:
        print(f"hash_move_hit_pct:   {pct(total_hash_hits, total_hash_probes):.1f}")
        print(f"hash_move_ordered:   {total_hash_ordered}")
        print(f"hash_first_pct:      {pct(total_tt_first, total_hash_ordered):.1f}")
        print(f"hash_first_legal_pct:{pct(total_tt_first_legal, total_hash_ordered):.1f}")
    if total_root_pv_ordered > 0:
        print(f"root_pv_first_pct:   {pct(total_root_pv_first, total_root_pv_ordered):.1f}")
    print(f"root_pv_legal_pct:   {pct(total_root_pv_first_legal, total_root_pv_ordered):.1f}")
    print(f"lmr_research_pct:    {lmr_research_pct:.1f}")
    print(f"pvs_researches:      {total_pvs_research}")
    print(f"asp_low:             {total_asp_low}")
    print(f"asp_high:            {total_asp_high}")
    print(f"asp_retry:           {total_asp_retry}")
    print(f"asp_verify:          {total_asp_verify}")
    print(f"quiet_beta_pct:      {pct(total_quiet_beta, total_beta_cutoffs):.1f}")
    print(f"capture_beta_pct:    {pct(total_capture_beta, total_beta_cutoffs):.1f}")
    print(f"capture_hist_updates:{total_capture_hist_updates}")
    print(f"capture_hist_maluses:{total_capture_hist_maluses}")
    print(f"cont_updates:        {total_cont_updates}")
    print(f"cont_maluses:        {total_cont_maluses}")
    print(f"cont_score_probes:   {total_cont_score_probes}")
    print(f"cont_raw_nonzero:    {total_cont_raw_nonzero}")
    print(f"cont_raw_nonzero_pct:{pct(total_cont_raw_nonzero, total_cont_score_probes):.1f}")
    print(f"cont_raw_under_pct:  {pct(total_cont_raw_under_scale, total_cont_raw_nonzero):.1f}")
    print(f"cont_raw_pos_pct:    {pct(total_cont_raw_positive, total_cont_raw_nonzero):.1f}")
    print(f"cont_raw_neg_pct:    {pct(total_cont_raw_negative, total_cont_raw_nonzero):.1f}")
    avg_cont_raw_abs = total_cont_raw_abs_sum / total_cont_raw_nonzero if total_cont_raw_nonzero > 0 else 0.0
    print(f"cont_raw_avg_abs:    {avg_cont_raw_abs:.1f}")
    print(f"cont_scaled_nonzero: {total_cont_score_nonzero}")
    print(f"cont_scaled_nonzero_pct:{pct(total_cont_score_nonzero, total_cont_score_probes):.1f}")
    print(f"cont_score_pos_pct:  {pct(total_cont_score_positive, total_cont_score_nonzero):.1f}")
    print(f"cont_score_neg_pct:  {pct(total_cont_score_negative, total_cont_score_nonzero):.1f}")
    avg_cont_score_abs = total_cont_score_abs_sum / total_cont_score_nonzero if total_cont_score_nonzero > 0 else 0.0
    print(f"cont_score_avg_abs:  {avg_cont_score_abs:.1f}")
    total_cont_store = total_cont_store_bonus_under_scale + total_cont_store_bonus_visible
    print(f"cont_store_bonus_under_pct:{pct(total_cont_store_bonus_under_scale, total_cont_store):.1f}")
    print(f"cont_store_result_under_pct:{pct(total_cont_store_result_under_scale, total_cont_store):.1f}")
    print(f"cont_store_visible:  {total_cont_store_result_visible}")
    print(f"nmp_cut_pct:         {pct(total_nmp_cutoffs, total_nmp_tries):.1f}")
    print(f"probcut_cut_pct:     {pct(total_probcut_cutoffs, total_probcut_tries):.1f}")
    print(f"see_calls:           {sum(int(row.get('see', 0)) for row in rows)}")
    print(f"see_cache_hits:      {sum(int(row.get('see_cache_hits', 0)) for row in rows)}")
    print(f"qsee_prunes:         {sum(int(row.get('qsee', 0)) for row in rows)}")
    print(f"futility_prunes:     {sum(int(row.get('futility', 0)) for row in rows)}")
    print(f"lmp_prunes:          {sum(int(row.get('lmp', 0)) for row in rows)}")
    print(f"legal_rejects:       {sum(int(row.get('legal_rejects', 0)) for row in rows)}")
    print(f"tt_same_key_kept:    {sum(int(row.get('same_key_kept', 0)) for row in rows)}")
    print(f"tt_replacements:     {sum(int(row.get('replacements', 0)) for row in rows)}")
    print(f"tt_stale_replaces:   {sum(int(row.get('stale_replacements', 0)) for row in rows)}")

    slowest = sorted(rows, key=lambda row: int(row.get("time_ms", 0)), reverse=True)[:5]
    print("\n=== Slowest Positions ===")
    for row in slowest:
        print(
            f"{int(row['index']):2d}: {int(row.get('time_ms', 0)):6d} ms "
            f"{int(row.get('nodes', 0)):9d} nodes best={row.get('bestmove', '?')} "
            f"fen={row['fen']}"
        )

    qnode_values = [float(row.get("qnode_pct", 0)) for row in rows]
    tt_hit_values = [pct(int(row.get("hits", 0)), int(row.get("probes", 0))) for row in rows]
    if len(qnode_values) > 1:
        print("\n=== Spread ===")
        print(f"qnode_pct median:    {statistics.median(qnode_values):.1f}")
        print(f"qnode_pct max:       {max(qnode_values):.1f}")
        print(f"tt_hit_pct median:   {statistics.median(tt_hit_values):.1f}")
        print(f"tt_hit_pct max:      {max(tt_hit_values):.1f}")


def write_csv(path: Path, rows: list[dict[str, int | str]]) -> None:
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
    parser.add_argument("--binary", default="./mantis", help="Path to Mantis binary")
    parser.add_argument("--depth", type=int, default=6, help="Fixed search depth")
    parser.add_argument("--movetime", type=int, help="Search each position with UCI go movetime N milliseconds")
    parser.add_argument("--wtime", type=int, help="White clock remaining for UCI clock mode, in milliseconds")
    parser.add_argument("--btime", type=int, help="Black clock remaining for UCI clock mode, in milliseconds")
    parser.add_argument("--winc", type=int, default=0, help="White increment for UCI clock mode, in milliseconds")
    parser.add_argument("--binc", type=int, default=0, help="Black increment for UCI clock mode, in milliseconds")
    parser.add_argument("--movestogo", type=int, default=0, help="Optional UCI movestogo value for clock mode")
    parser.add_argument("--limit", type=int, default=0, help="Only run the first N benchmark FENs")
    parser.add_argument("--timeout", type=float, default=60.0, help="Timeout per position in seconds")
    parser.add_argument("--fen-file", type=Path, help="Optional file with one FEN per line")
    parser.add_argument("--csv", type=Path, help="Optional CSV output path")
    parser.add_argument("--keep-hash", action="store_true", help="Do not send ucinewgame between positions")
    parser.add_argument("--own-book", action="store_true", help="Allow internal OwnBook moves during the benchmark")
    parser.add_argument("--staged-picker", action="store_true", help="Enable the StagedMovePicker UCI option")
    parser.add_argument("--option", action="append", default=[], help="UCI option Name=Value applied before each search; repeatable")
    parser.add_argument("--validate-only", action="store_true", help="Validate selected FENs and exit")
    args = parser.parse_args()
    if args.depth <= 0:
        parser.error("--depth must be positive")
    if args.movetime is not None and args.movetime <= 0:
        parser.error("--movetime must be positive")
    clock_mode = args.wtime is not None or args.btime is not None
    if clock_mode:
        if args.movetime is not None:
            parser.error("--movetime cannot be combined with clock mode")
        if args.wtime is None or args.btime is None:
            parser.error("--wtime and --btime are both required for clock mode")
        if args.wtime <= 0 or args.btime <= 0:
            parser.error("--wtime and --btime must be positive")
    if args.winc < 0 or args.binc < 0:
        parser.error("--winc and --binc must be non-negative")
    if args.movestogo < 0:
        parser.error("--movestogo must be non-negative")
    try:
        engine_options = parse_engine_options(args.option)
    except ValueError as exc:
        parser.error(str(exc))

    if args.fen_file:
        fens = [
            line.strip()
            for line in args.fen_file.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    else:
        fens = load_bench_fens(Path("uci/uci.odin"))

    if args.limit > 0:
        fens = fens[: args.limit]

    try:
        validate_fens(fens)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.validate_only:
        print(f"FEN validation OK: {len(fens)} positions")
        return 0

    clock_ms: dict[str, int] | None = None
    if clock_mode:
        clock_ms = {
            "wtime": args.wtime,
            "btime": args.btime,
            "winc": args.winc,
            "binc": args.binc,
            "movestogo": args.movestogo,
        }

    depth = None if args.movetime is not None or clock_ms is not None else args.depth
    mode = "clock" if clock_ms is not None else ("movetime" if args.movetime is not None else "depth")
    limit_value: int | str
    if clock_ms is not None:
        limit_value = clock_label(clock_ms)
    elif args.movetime is not None:
        limit_value = args.movetime
    else:
        limit_value = args.depth

    rows: list[dict[str, int | str]] = []
    for index, fen in enumerate(fens, start=1):
        try:
            stats, _output, wall_ms = run_position(
                args.binary,
                fen,
                depth,
                args.timeout,
                clear_hash=not args.keep_hash,
                staged_picker=args.staged_picker,
                own_book=args.own_book,
                movetime_ms=args.movetime,
                clock_ms=clock_ms,
                options=engine_options,
            )
        except subprocess.CalledProcessError as exc:
            print(f"FAIL {index}: engine exited with {exc.returncode}\n{exc.output}", file=sys.stderr)
            return 1
        except subprocess.TimeoutExpired as exc:
            print(f"FAIL {index}: timed out after {args.timeout}s\n{exc.output}", file=sys.stderr)
            return 1

        stats["index"] = index
        stats["fen"] = fen
        stats["mode"] = mode
        stats["limit"] = limit_value
        stats["wall_ms"] = int(wall_ms)
        rows.append(stats)

        print(
            f"{index:2d}/{len(fens):2d} "
            f"depth={int(stats.get('depth', 0)):2d} "
            f"nodes={int(stats.get('nodes', 0)):8d} "
            f"time={int(stats.get('time_ms', 0)):5d}ms "
            f"q={float(stats.get('qnode_pct', 0)):4.0f}% "
            f"tt={pct(int(stats.get('hits', 0)), int(stats.get('probes', 0))):4.0f}% "
            f"best={stats.get('bestmove', '?')}"
        )

    print_summary(rows)
    if args.csv:
        write_csv(args.csv, rows)
        print(f"\nWrote CSV: {args.csv}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
