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


def parse_stats(output: str) -> dict[str, int | str]:
    stats: dict[str, int | str] = {}
    for line in output.splitlines():
        if line.startswith("info depth "):
            depth_match = re.search(r"info depth ([0-9]+)", line)
            score_match = re.search(r"score cp (-?[0-9]+)", line)
            nodes_match = re.search(r"nodes ([0-9]+)", line)
            time_match = re.search(r"time ([0-9]+)", line)
            nps_match = re.search(r"nps ([0-9]+)", line)
            if depth_match:
                stats["depth"] = int(depth_match.group(1))
            if score_match:
                stats["score_cp"] = int(score_match.group(1))
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
                if key not in stats:
                    stats[key] = int(value)

        if line.startswith("bestmove "):
            parts = line.split()
            if len(parts) >= 2:
                stats["bestmove"] = parts[1]

    if "bestmove" not in stats:
        raise RuntimeError(f"Engine did not return bestmove. Output:\n{output}")
    return stats


def run_position(binary: str, fen: str, depth: int, timeout: float, clear_hash: bool) -> tuple[dict[str, int | str], str, float]:
    commands = [
        "uci",
        "setoption name SearchStats value true",
        "isready",
    ]
    if clear_hash:
        commands.append("ucinewgame")
    commands.extend([
        f"position fen {fen}",
        f"go depth {depth}",
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
    total_beta_cutoffs = sum(int(row.get("search_beta_cutoffs", 0)) for row in rows)
    total_quiet_beta = sum(int(row.get("search_quiet_beta", 0)) for row in rows)
    total_capture_beta = sum(int(row.get("search_capture_beta", 0)) for row in rows)
    total_capture_hist_updates = sum(int(row.get("search_capture_hist_updates", 0)) for row in rows)
    total_capture_hist_maluses = sum(int(row.get("search_capture_hist_maluses", 0)) for row in rows)
    total_cont_updates = sum(int(row.get("search_cont_updates", 0)) for row in rows)
    total_cont_maluses = sum(int(row.get("search_cont_maluses", 0)) for row in rows)
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
    print(f"quiet_beta_pct:      {pct(total_quiet_beta, total_beta_cutoffs):.1f}")
    print(f"capture_beta_pct:    {pct(total_capture_beta, total_beta_cutoffs):.1f}")
    print(f"capture_hist_updates:{total_capture_hist_updates}")
    print(f"capture_hist_maluses:{total_capture_hist_maluses}")
    print(f"cont_updates:        {total_cont_updates}")
    print(f"cont_maluses:        {total_cont_maluses}")
    print(f"nmp_cut_pct:         {pct(total_nmp_cutoffs, total_nmp_tries):.1f}")
    print(f"probcut_cut_pct:     {pct(total_probcut_cutoffs, total_probcut_tries):.1f}")
    print(f"see_calls:           {sum(int(row.get('see', 0)) for row in rows)}")
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
    parser.add_argument("--limit", type=int, default=0, help="Only run the first N benchmark FENs")
    parser.add_argument("--timeout", type=float, default=60.0, help="Timeout per position in seconds")
    parser.add_argument("--fen-file", type=Path, help="Optional file with one FEN per line")
    parser.add_argument("--csv", type=Path, help="Optional CSV output path")
    parser.add_argument("--keep-hash", action="store_true", help="Do not send ucinewgame between positions")
    args = parser.parse_args()

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

    rows: list[dict[str, int | str]] = []
    for index, fen in enumerate(fens, start=1):
        try:
            stats, _output, wall_ms = run_position(
                args.binary,
                fen,
                args.depth,
                args.timeout,
                clear_hash=not args.keep_hash,
            )
        except subprocess.CalledProcessError as exc:
            print(f"FAIL {index}: engine exited with {exc.returncode}\n{exc.output}", file=sys.stderr)
            return 1
        except subprocess.TimeoutExpired as exc:
            print(f"FAIL {index}: timed out after {args.timeout}s\n{exc.output}", file=sys.stderr)
            return 1

        stats["index"] = index
        stats["fen"] = fen
        stats["wall_ms"] = int(wall_ms)
        rows.append(stats)

        print(
            f"{index:2d}/{len(fens):2d} "
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
