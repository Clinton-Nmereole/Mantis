#!/usr/bin/env python3
"""
nevergrad_tuner.py — Nevergrad-based Parameter Tuner for Mantis

Uses Facebook's Nevergrad library for derivative-free optimization
of chess engine parameters. Much more efficient than coordinate
descent because it explores the parameter space intelligently
rather than one dimension at a time.

Requirements:
    source venv/bin/activate
    python3 nevergrad_tuner.py --budget 50

Workflow:
    1. Define parameter ranges (integers only for Odin tuning.odin)
    2. For each evaluation:
       a. Modify search/tuning.odin
       b. Build engine
       c. Run selfplay.py --quick vs baseline
       d. Return win_pct as objective
    3. Nevergrad optimizes over 50+ evaluations
    4. Save best parameters to best_params.json

Recommended usage:
    # Quick exploration (2-4 hours)
    python3 nevergrad_tuner.py --budget 30 --quick

    # Serious tuning overnight (6-10 hours)
    python3 nevergrad_tuner.py --budget 80 --quick

    # Verify the best result afterward
    python3 selfplay.py --verify --engine-a ./mantis --engine-b ./mantis_baseline
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from typing import Dict, List, Tuple, Optional

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

TUNING_FILE = "search/tuning.odin"
BUILD_SCRIPT = "./build_safe.sh"
SELFPLAY_SCRIPT = "./selfplay.py"
BASELINE_ENGINE = "./mantis_baseline"
RESULT_FILE = "tuning_progress.json"
BEST_PARAMS_FILE = "best_params.json"

# Parameters to tune: name -> (min, max)
# Focus on the 8 highest-leverage search parameters
PARAM_RANGES: Dict[str, Tuple[int, int]] = {
    "nmp_reduction_base": (0, 4),
    "nmp_reduction_div":  (3, 10),
    "rfp_margin":         (50, 130),
    "rfp_depth":          (5, 10),
    "lmr_min_depth":      (2, 5),
    "futility_margin":    (150, 400),
    "lmp_base":           (1, 4),
    "lmp_div":            (1, 4),
}

# ---------------------------------------------------------------------------
# FILE I/O
# ---------------------------------------------------------------------------

def read_tuning_file() -> str:
    with open(TUNING_FILE, "r") as f:
        return f.read()


def write_tuning_file(content: str):
    with open(TUNING_FILE, "w") as f:
        f.write(content)


def set_param(content: str, param: str, value: int) -> str:
    """Replace a single parameter value in tuning.odin."""
    pattern = rf"(\b{param}\s*=\s*)(-?\d+)"
    replacement = r"\g<1>" + str(value)
    new_content, count = re.subn(pattern, replacement, content, count=1)
    if count == 0:
        print(f"WARNING: Could not find parameter '{param}'")
    return new_content


def apply_params(content: str, params: Dict[str, int]) -> str:
    for param, value in params.items():
        content = set_param(content, param, value)
    return content


# ---------------------------------------------------------------------------
# BUILD & EVALUATE
# ---------------------------------------------------------------------------

def build_engine() -> bool:
    """Build engine, return True on success."""
    result = subprocess.run(
        [BUILD_SCRIPT],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.returncode == 0


def evaluate_params(params: Dict[str, int],
                    baseline: str = BASELINE_ENGINE,
                    games: int = 10,
                    movetime: int = 100,
                    concurrency: int = 4,
                    openings: Optional[str] = "openings.epd") -> Optional[float]:
    """
    Run a quick tournament and return win percentage.
    Returns None on failure.
    """
    test_engine = "./mantis"
    if not os.path.exists(test_engine):
        print(f"[ERROR] Engine not found: {test_engine}")
        return None

    if not os.path.exists(baseline):
        print(f"[ERROR] Baseline not found: {baseline}")
        return None

    cmd = [
        sys.executable, SELFPLAY_SCRIPT,
        "--engine-a", test_engine,
        "--engine-b", baseline,
        "--games", str(games),
        "--concurrency", str(concurrency),
        "--movetime", str(movetime),
    ]
    if openings and os.path.exists(openings):
        cmd += ["--openings", openings]

    print(f"[EVAL] {' '.join(cmd[-6:])}")
    start = time.time()
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    elapsed = time.time() - start

    if result.returncode != 0:
        print(f"[EVAL FAILED] rc={result.returncode}")
        return None

    # Parse win percentage
    m = re.search(r"Win %:\s+([\d.]+)%", result.stdout)
    if m:
        win_pct = float(m.group(1))
        # Count failures
        illegal_count = result.stdout.count("(illegal move")
        failed_count = result.stdout.count("failed:")
        total_games = games
        problem_rate = (illegal_count + failed_count) / total_games * 100 if total_games > 0 else 0
        print(f"[EVAL OK] Win %: {win_pct:.2f}  Illegal:{illegal_count} Failed:{failed_count}  ({elapsed:.1f}s)")
        if problem_rate > 10:
            print(f"[EVAL WARNING] Problem rate {problem_rate:.1f}% > 10%, rejecting this candidate")
            return 0.0  # Treat as 0% win rate — reject
        return win_pct
    else:
        print("[EVAL PARSE ERROR]")
        return None


# ---------------------------------------------------------------------------
# NEVERGRAD OPTIMIZATION
# ---------------------------------------------------------------------------

def run_nevergrad(budget: int,
                  baseline_content: str,
                  games_per_eval: int = 10,
                  movetime: int = 100,
                  concurrency: int = 4,
                  resume_file: Optional[str] = None) -> Tuple[Dict[str, int], float]:
    """
    Run Nevergrad optimization loop.
    Returns the best parameter dictionary found.
    """
    try:
        import nevergrad as ng
    except ImportError:
        print("ERROR: nevergrad not installed.")
        print("Run: source venv/bin/activate && pip install nevergrad")
        sys.exit(1)

    # Build parameter space (all integers)
    params = {}
    for name, (lo, hi) in PARAM_RANGES.items():
        p = ng.p.Scalar(lower=lo, upper=hi)
        p.set_integer_casting()
        params[name] = p

    instrum = ng.p.Instrumentation(**params)

    # Optimizer: NGOpt automatically picks the best algorithm
    optimizer = ng.optimizers.NGOpt(parametrization=instrum, budget=budget)

    # Load progress if resuming
    history = []
    if resume_file and os.path.exists(resume_file):
        with open(resume_file) as f:
            history = json.load(f)
        print(f"[RESUME] Loaded {len(history)} previous evaluations")
        for entry in history:
            # Re-inject into optimizer
            vals = [float(entry["params"][k]) for k in PARAM_RANGES.keys()]
            candidate = instrum.spawn_child().set_standardized_data(vals)
            optimizer.tell(candidate, -entry["score"])  # negate for maximization

    best_score = -1.0
    best_params = {}
    baseline_params = dict(PARAM_RANGES)  # Just for reference

    # Save original content for restoration
    original_content = baseline_content

    for iteration in range(len(history), budget):
        print(f"\n{'='*60}")
        print(f"ITERATION {iteration + 1} / {budget}")
        print(f"{'='*60}")

        # Ask Nevergrad for next candidate
        candidate = optimizer.ask()
        candidate_params = {}
        for name in PARAM_RANGES:
            val = int(candidate.value[1][name])
            lo, hi = PARAM_RANGES[name]
            val = max(lo, min(hi, val))
            candidate_params[name] = val

        print(f"  Params: {candidate_params}")

        # Modify tuning file
        test_content = apply_params(original_content, candidate_params)
        write_tuning_file(test_content)

        # Build
        print("  Building...")
        if not build_engine():
            print("  [BUILD FAILED] Assigning 0% win rate")
            score = 0.0
        else:
            # Evaluate
            score = evaluate_params(
                candidate_params,
                baseline=BASELINE_ENGINE,
                games=games_per_eval,
                movetime=movetime,
                concurrency=concurrency,
            )
            if score is None:
                score = 0.0

        # Track best
        if score > best_score:
            best_score = score
            best_params = dict(candidate_params)
            print(f"  *** NEW BEST: {score:.2f}% ***")

        # Tell optimizer the result (negate because Nevergrad minimizes)
        optimizer.tell(candidate, -score)

        # Save progress
        history.append({
            "iteration": iteration + 1,
            "params": candidate_params,
            "score": score,
            "best_score": best_score,
            "best_params": dict(best_params),
        })
        if resume_file:
            with open(resume_file, "w") as f:
                json.dump(history, f, indent=2)

    # Restore best params
    if best_params:
        final_content = apply_params(original_content, best_params)
        write_tuning_file(final_content)
        build_engine()

    return best_params, best_score


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Nevergrad parameter tuner for Mantis",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Quick exploration (~2 hours)
  python3 nevergrad_tuner.py --budget 30

  # Overnight serious tuning (~6 hours)
  python3 nevergrad_tuner.py --budget 80 --games 15 --movetime 200

  # Resume interrupted run
  python3 nevergrad_tuner.py --budget 50 --resume tuning_progress.json
        """,
    )

    parser.add_argument("--budget", type=int, default=30,
                        help="Number of evaluations (default: 30)")
    parser.add_argument("--games", type=int, default=10,
                        help="Games per evaluation (default: 10)")
    parser.add_argument("--movetime", type=int, default=100,
                        help="Fixed time per move in ms (default: 100)")
    parser.add_argument("--concurrency", type=int, default=4,
                        help="Parallel games (default: 4)")
    parser.add_argument("--baseline", default=BASELINE_ENGINE,
                        help=f"Baseline engine (default: {BASELINE_ENGINE})")
    parser.add_argument("--resume", default=None,
                        help="Resume from progress JSON file")
    parser.add_argument("--output", default=BEST_PARAMS_FILE,
                        help=f"Output file for best params (default: {BEST_PARAMS_FILE})")
    parser.add_argument("--verify", action="store_true",
                        help="Run verification match after tuning")

    args = parser.parse_args()

    # Sanity checks
    if not os.path.exists(TUNING_FILE):
        print(f"ERROR: Tuning file not found: {TUNING_FILE}")
        sys.exit(1)
    if not os.path.exists(args.baseline):
        print(f"ERROR: Baseline engine not found: {args.baseline}")
        sys.exit(1)

    # Save original tuning content
    original_content = read_tuning_file()

    print("=" * 60)
    print("NEVERGRAD PARAMETER TUNER")
    print("=" * 60)
    print(f"Budget: {args.budget} evaluations")
    print(f"Games per eval: {args.games} at {args.movetime}ms")
    print(f"Concurrency: {args.concurrency}")
    print(f"Parameters: {list(PARAM_RANGES.keys())}")
    print()

    try:
        best_params, best_score = run_nevergrad(
            budget=args.budget,
            baseline_content=original_content,
            games_per_eval=args.games,
            movetime=args.movetime,
            concurrency=args.concurrency,
            resume_file=args.resume or RESULT_FILE,
        )
    except KeyboardInterrupt:
        print("\n[INTERRUPT] Restoring original tuning file...")
        write_tuning_file(original_content)
        sys.exit(1)

    print()
    print("=" * 60)
    print("TUNING COMPLETE")
    print("=" * 60)
    print(f"Best score: {best_score:.2f}%")
    print(f"Best parameters:")
    for k, v in best_params.items():
        print(f"  {k:25s} = {v}")
    print()

    # Save to JSON
    with open(args.output, "w") as f:
        json.dump(best_params, f, indent=2)
    print(f"Saved to {args.output}")

    # Optional verification
    if args.verify:
        print()
        print("=" * 60)
        print("VERIFICATION MATCH")
        print("=" * 60)
        verify_cmd = [
            sys.executable, SELFPLAY_SCRIPT,
            "--engine-a", "./mantis",
            "--engine-b", args.baseline,
            "--verify",
            "--concurrency", str(args.concurrency),
            "--openings", "openings.epd",
        ]
        subprocess.run(verify_cmd)


if __name__ == "__main__":
    main()
