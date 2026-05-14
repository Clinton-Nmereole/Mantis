#!/usr/bin/env python3
"""
tune.py — Automated Coordinate-Descent Tuner for Mantis

This script automates the parameter tuning workflow:

    1. Read current defaults from search/tuning.odin
    2. Modify a parameter (or all parameters via coordinate descent)
    3. Recompile the engine
    4. Run self-play games via selfplay.py
    5. Measure win rate vs a baseline engine
    6. Keep improvements, revert failures

The script edits search/tuning.odin in-place, runs the build script,
and invokes selfplay.py.  It keeps a backup of the original file and
restores it on exit (or if you Ctrl+C).

Usage:
    # Single parameter sweep (test NMP reduction from 1 to 4)
    python3 tune.py --param nmp_reduction_base --range 1,2,3,4 --games 10

    # Coordinate descent on all 35 parameters
    python3 tune.py --coordinate-descent --games 20 --steps 3

    # Baseline tournament (no tuning, just measure current strength)
    python3 tune.py --baseline --games 35

    # Fast tuning with short time control
    python3 tune.py --coordinate-descent --games 10 --movetime 50 --concurrency 4

Output:
    Prints a running log of each evaluation and a final summary with
    the best parameter set found.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import json
from typing import Optional, List, Dict, Tuple

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

TUNING_FILE = "search/tuning.odin"
BACKUP_FILE = "search/tuning.odin.bak"
BUILD_SCRIPT = "./build_safe.sh"
SELFPLAY_SCRIPT = "./selfplay.py"
BASELINE_ENGINE = "./mantis_baseline"

# Parameter names and their types (for generating edits)
PARAMETERS = [
    "aspiration_window",
    "nmp_min_depth",
    "nmp_reduction_base",
    "nmp_reduction_div",
    "rfp_depth",
    "rfp_margin",
    "probcut_depth",
    "probcut_margin",
    "probcut_reduce",
    "iir_min_depth",
    "se_depth",
    "se_margin",
    "se_reduced_div",
    "futility_margin",
    "futility_max_depth",
    "lmp_base",
    "lmp_div",
    "lmp_max_depth",
    "lmr_min_depth",
    "lmr_improving_adj",
    "lmr_history_good_adj",
    "lmr_history_bad_adj",
    "lmr_history_good_thresh",
    "lmr_history_bad_thresh",
    "razor_margin",
    "razor_max_depth",
    "delta_pruning_margin",
    "history_decay_numer",
    "history_decay_denom",
    "hash_move_score",
    "counter_move_score",
    "capture_base_score",
    "killer1_score",
    "killer2_score",
    "contempt",
]

# ---------------------------------------------------------------------------
# FILE I/O
# ---------------------------------------------------------------------------

def read_tuning_file() -> str:
    """Read the current contents of search/tuning.odin."""
    with open(TUNING_FILE, "r") as f:
        return f.read()


def write_tuning_file(content: str):
    """Write content to search/tuning.odin."""
    with open(TUNING_FILE, "w") as f:
        f.write(content)


def backup_tuning_file():
    """Create a backup of the original tuning file."""
    shutil.copy2(TUNING_FILE, BACKUP_FILE)


def restore_tuning_file():
    """Restore the original tuning file from backup."""
    if os.path.exists(BACKUP_FILE):
        shutil.copy2(BACKUP_FILE, TUNING_FILE)
        print("[RESTORED] Original tuning file restored.")


def get_current_defaults(content: str) -> Dict[str, int]:
    """
    Parse the current default values from the init_search_params function.
    Returns a dict mapping parameter name to its default integer value.
    """
    defaults = {}
    # Find the init_search_params block
    match = re.search(r"init_search_params :: proc\(\) \{.*?params = SearchParams\{(.*?)\}", content, re.DOTALL)
    if not match:
        print("ERROR: Could not find SearchParams initialization block.")
        return defaults

    block = match.group(1)
    for param in PARAMETERS:
        # Match lines like: aspiration_window      = 25,
        m = re.search(rf"\b{param}\s*=\s*(-?\d+)", block)
        if m:
            defaults[param] = int(m.group(1))

    return defaults


# ---------------------------------------------------------------------------
# PARAMETER MODIFICATION
# ---------------------------------------------------------------------------

def set_param(content: str, param: str, value: int) -> str:
    """
    Replace the default value of a single parameter in the tuning file.
    Returns the modified content.
    """
    pattern = rf"(\b{param}\s*=\s*)(-?\d+)"
    replacement = r"\g<1>" + str(value)
    new_content, count = re.subn(pattern, replacement, content, count=1)
    if count == 0:
        print(f"WARNING: Could not find parameter '{param}' in tuning file.")
    return new_content


def apply_params(content: str, params: Dict[str, int]) -> str:
    """Apply multiple parameter changes at once."""
    for param, value in params.items():
        content = set_param(content, param, value)
    return content


# ---------------------------------------------------------------------------
# BUILD & EVALUATE
# ---------------------------------------------------------------------------

def build_engine() -> bool:
    """Run the build script and return True on success."""
    print("[BUILD] Compiling engine...")
    start = time.time()
    result = subprocess.run(
        [BUILD_SCRIPT],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    elapsed = time.time() - start
    if result.returncode != 0:
        print(f"[BUILD FAILED] in {elapsed:.1f}s")
        print(result.stdout)
        print(result.stderr)
        return False
    print(f"[BUILD OK] in {elapsed:.1f}s")
    return True


def evaluate_params(games: int, tc_args: List[str], concurrency: int,
                    baseline: str = BASELINE_ENGINE) -> Optional[float]:
    """
    Run a self-play tournament and return the win percentage.
    Returns None if the tournament fails.
    """
    test_engine = "./mantis"
    if not os.path.exists(test_engine):
        print(f"[ERROR] Engine binary not found: {test_engine}")
        return None

    if not os.path.exists(baseline):
        # Use the current engine as its own baseline if no baseline exists
        print(f"[INFO] No baseline engine at {baseline}, using self-play.")
        baseline = test_engine

    cmd = [
        sys.executable, SELFPLAY_SCRIPT,
        "--engine-a", test_engine,
        "--engine-b", baseline,
        "--games", str(games),
        "--concurrency", str(concurrency),
    ] + tc_args

    print(f"[EVAL] Running: {' '.join(cmd)}")
    start = time.time()
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    elapsed = time.time() - start

    if result.returncode != 0:
        print(f"[EVAL FAILED] in {elapsed:.1f}s")
        print(result.stderr)
        return None

    # Parse win percentage from output
    output = result.stdout
    m = re.search(r"Win %:\s+([\d.]+)%", output)
    if m:
        win_pct = float(m.group(1))
        print(f"[EVAL OK] Win %: {win_pct:.2f}  (took {elapsed:.1f}s)")
        return win_pct
    else:
        print(f"[EVAL PARSE ERROR] Could not find win percentage in output.")
        print(output[-500:])  # Print last 500 chars for debugging
        return None


# ---------------------------------------------------------------------------
# COORDINATE DESCENT
# ---------------------------------------------------------------------------

def coordinate_descent(
    initial_params: Dict[str, int],
    games: int,
    tc_args: List[str],
    concurrency: int,
    steps: int,
    baseline: str,
    rel_steps: Optional[Dict[str, float]] = None,
) -> Tuple[Dict[str, int], float]:
    """
    Run coordinate descent: tweak one parameter at a time, keep improvements.

    Returns:
        (best_params_dict, best_win_pct)
    """
    if rel_steps is None:
        rel_steps = {
            "aspiration_window": 0.20,
            "nmp_min_depth": 0.33,
            "nmp_reduction_base": 0.25,
            "nmp_reduction_div": 0.25,
            "rfp_depth": 0.15,
            "rfp_margin": 0.20,
            "probcut_depth": 0.15,
            "probcut_margin": 0.20,
            "probcut_reduce": 0.15,
            "iir_min_depth": 0.15,
            "se_depth": 0.12,
            "se_margin": 0.25,
            "se_reduced_div": 0.25,
            "futility_margin": 0.20,
            "futility_max_depth": 0.25,
            "lmp_base": 0.25,
            "lmp_div": 0.25,
            "lmp_max_depth": 0.15,
            "lmr_min_depth": 0.15,
            "lmr_improving_adj": 0.50,
            "lmr_history_good_adj": 0.50,
            "lmr_history_bad_adj": 0.50,
            "lmr_history_good_thresh": 0.20,
            "lmr_history_bad_thresh": 0.20,
            "razor_margin": 0.20,
            "razor_max_depth": 0.25,
            "delta_pruning_margin": 0.15,
            "history_decay_numer": 0.10,
            "history_decay_denom": 0.10,
            "hash_move_score": 0.15,
            "counter_move_score": 0.15,
            "capture_base_score": 0.15,
            "killer1_score": 0.15,
            "killer2_score": 0.15,
            "contempt": 0.25,
        }

    best_params = dict(initial_params)
    baseline_content = read_tuning_file()

    # Evaluate baseline
    print("=" * 60)
    print("BASELINE EVALUATION")
    print("=" * 60)
    best_score = evaluate_params(games, tc_args, concurrency, baseline)
    if best_score is None:
        print("[FATAL] Baseline evaluation failed.")
        return best_params, 0.0
    print(f"Baseline win %: {best_score:.2f}")
    print()

    for step in range(steps):
        print("=" * 60)
        print(f"COORDINATE DESCENT — STEP {step + 1}/{steps}")
        print("=" * 60)
        improved = False

        for param in PARAMETERS:
            if param not in best_params:
                continue

            base_value = best_params[param]
            rel = rel_steps.get(param, 0.20)
            delta = max(1, int(abs(base_value) * rel))

            # Only test positive direction for positive params, both for signed
            directions = []
            if base_value > 0:
                directions = [+delta, -delta]
            else:
                directions = [+delta, -delta]

            best_dir = None
            best_dir_score = best_score

            for direction in directions:
                test_value = base_value + direction
                if test_value < 0 and param not in ["lmr_improving_adj", "lmr_history_good_adj",
                                                      "lmr_history_bad_adj", "lmr_history_bad_thresh",
                                                      "contempt"]:
                    # Most params shouldn't go negative
                    continue

                print(f"  Testing {param} = {test_value} (was {base_value})...")

                # Modify, build, evaluate
                test_content = set_param(baseline_content, param, test_value)
                write_tuning_file(test_content)

                if not build_engine():
                    continue

                score = evaluate_params(games, tc_args, concurrency, baseline)
                if score is None:
                    continue

                if score > best_dir_score:
                    best_dir_score = score
                    best_dir = test_value
                    print(f"    -> BETTER: {score:.2f}% vs {best_score:.2f}%")
                else:
                    print(f"    -> worse: {score:.2f}% vs {best_score:.2f}%")

            if best_dir is not None:
                best_params[param] = best_dir
                best_score = best_dir_score
                baseline_content = set_param(baseline_content, param, best_dir)
                improved = True
                print(f"  [KEEP] {param} = {best_dir}  (score: {best_score:.2f}%)")
            else:
                print(f"  [SKIP] {param} unchanged at {base_value}")

        if not improved:
            print("No improvement this step — converged.")
            break

    # Apply final best params
    write_tuning_file(baseline_content)
    build_engine()

    return best_params, best_score


# ---------------------------------------------------------------------------
# SINGLE PARAMETER SWEEP
# ---------------------------------------------------------------------------

def sweep_param(param: str, values: List[int], games: int,
                tc_args: List[str], concurrency: int,
                baseline: str) -> Tuple[Optional[int], float]:
    """
    Sweep a single parameter over a list of values.
    Returns (best_value, best_win_pct).
    """
    content = read_tuning_file()
    best_value = None
    best_score = -1.0

    print("=" * 60)
    print(f"PARAMETER SWEEP: {param}")
    print("=" * 60)

    for value in values:
        print(f"  Testing {param} = {value}...")
        test_content = set_param(content, param, value)
        write_tuning_file(test_content)

        if not build_engine():
            continue

        score = evaluate_params(games, tc_args, concurrency, baseline)
        if score is None:
            continue

        print(f"    -> Win %: {score:.2f}")
        if score > best_score:
            best_score = score
            best_value = value

    # Restore best
    if best_value is not None:
        final_content = set_param(content, param, best_value)
        write_tuning_file(final_content)
        build_engine()
        print(f"\nBEST: {param} = {best_value}  (win %: {best_score:.2f})")
    else:
        print("\nNo valid result found.")
        write_tuning_file(content)  # Restore original

    return best_value, best_score


# ---------------------------------------------------------------------------
# BASELINE TOURNAMENT
# ---------------------------------------------------------------------------

def run_baseline(games: int, tc_args: List[str], concurrency: int) -> Optional[Dict]:
    """Run a baseline self-play tournament and print results."""
    print("=" * 60)
    print("BASELINE TOURNAMENT")
    print("=" * 60)
    print(f"Games: {games}")
    print(f"Time control: {tc_args}")
    print(f"Concurrency: {concurrency}")
    print()

    # Save current engine as baseline for comparison
    if os.path.exists("./mantis"):
        shutil.copy2("./mantis", BASELINE_ENGINE)
        print(f"[INFO] Saved current engine as {BASELINE_ENGINE}")

    score = evaluate_params(games, tc_args, concurrency, BASELINE_ENGINE)
    if score is not None:
        print(f"\nBaseline result: {score:.2f}% win rate (50% = equal)")
    return None


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Automated parameter tuner for Mantis chess engine",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Baseline tournament
  python3 tune.py --baseline --games 35 --movetime 100

  # Single parameter sweep
  python3 tune.py --param nmp_reduction_base --range 1,2,3,4 --games 10 --movetime 50

  # Coordinate descent
  python3 tune.py --coordinate-descent --games 20 --steps 3 --movetime 100 --concurrency 4
        """,
    )

    parser.add_argument("--baseline", action="store_true",
                        help="Run a baseline tournament (no tuning)")
    parser.add_argument("--param", default=None,
                        help="Parameter name to sweep")
    parser.add_argument("--range", default=None,
                        help="Comma-separated values to test (e.g., 1,2,3,4)")
    parser.add_argument("--coordinate-descent", action="store_true",
                        help="Run full coordinate descent on all parameters")
    parser.add_argument("--games", type=int, default=20,
                        help="Games per evaluation (default: 20)")
    parser.add_argument("--steps", type=int, default=3,
                        help="Coordinate descent steps (default: 3)")
    parser.add_argument("--concurrency", type=int, default=1,
                        help="Parallel games (default: 1)")
    parser.add_argument("--movetime", type=int, default=None,
                        help="Fixed time per move in ms")
    parser.add_argument("--wtime", type=int, default=None,
                        help="White time in ms")
    parser.add_argument("--btime", type=int, default=None,
                        help="Black time in ms")
    parser.add_argument("--winc", type=int, default=0,
                        help="White increment in ms")
    parser.add_argument("--binc", type=int, default=0,
                        help="Black increment in ms")
    parser.add_argument("--depth", type=int, default=None,
                        help="Fixed depth")
    parser.add_argument("--baseline-engine", default=BASELINE_ENGINE,
                        help=f"Path to baseline engine (default: {BASELINE_ENGINE})")

    args = parser.parse_args()

    # Build time control args for selfplay.py
    tc_args = []
    if args.movetime:
        tc_args += ["--movetime", str(args.movetime)]
    if args.wtime:
        tc_args += ["--wtime", str(args.wtime)]
    if args.btime:
        tc_args += ["--btime", str(args.btime)]
    if args.winc:
        tc_args += ["--winc", str(args.winc)]
    if args.binc:
        tc_args += ["--binc", str(args.binc)]
    if args.depth:
        tc_args += ["--depth", str(args.depth)]
    if not tc_args:
        tc_args = ["--movetime", "100"]  # Default

    # Backup original tuning file
    backup_tuning_file()

    try:
        if args.baseline:
            run_baseline(args.games, tc_args, args.concurrency)

        elif args.param and args.range:
            values = [int(v.strip()) for v in args.range.split(",")]
            sweep_param(args.param, values, args.games, tc_args,
                        args.concurrency, args.baseline_engine)

        elif args.coordinate_descent:
            content = read_tuning_file()
            initial = get_current_defaults(content)
            best_params, best_score = coordinate_descent(
                initial, args.games, tc_args, args.concurrency,
                args.steps, args.baseline_engine,
            )
            print()
            print("=" * 60)
            print("COORDINATE DESCENT COMPLETE")
            print("=" * 60)
            print(f"Best win %: {best_score:.2f}")
            print()
            print("Best parameters:")
            for param in PARAMETERS:
                if param in best_params:
                    print(f"  {param:30s} = {best_params[param]}")
            print()
            # Save to JSON
            with open("best_params.json", "w") as f:
                json.dump(best_params, f, indent=2)
            print("Saved to best_params.json")

        else:
            parser.print_help()

    except KeyboardInterrupt:
        print("\n[INTERRUPT] Restoring original tuning file...")
        restore_tuning_file()
        sys.exit(1)
    finally:
        # Optionally restore original (comment out to keep best params)
        # restore_tuning_file()
        pass


if __name__ == "__main__":
    main()
