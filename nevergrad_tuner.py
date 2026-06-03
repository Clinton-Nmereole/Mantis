#!/usr/bin/env python3
"""
nevergrad_tuner.py — Parameter Tuner for Mantis

Uses Facebook's Nevergrad library, or a dependency-free random-search
fallback, for derivative-free optimization of chess engine parameters.

Requirements:
    # Random-search fallback needs no extra packages.
    python3 nevergrad_tuner.py --optimizer random --budget 50

    # Nevergrad mode:
    source venv/bin/activate
    python3 nevergrad_tuner.py --optimizer nevergrad --budget 50

Workflow:
    1. Define parameter ranges for UCI tuning options
    2. For each evaluation:
       a. Run selfplay.py with candidate options on engine A
       b. Compare against the same binary, or a supplied baseline, at defaults
       c. Return win_pct as objective
    3. The selected optimizer explores the candidate space
    4. Save best parameters to best_params_uci.json

Recommended usage:
    # Quick exploration with no rebuilds
    python3 nevergrad_tuner.py --engine ./mantis_uci_tune_options \
        --optimizer random --budget 30 --games 10 --movetime 100

    # Serious tuning overnight with Nevergrad installed
    python3 nevergrad_tuner.py --engine ./mantis \
        --optimizer nevergrad --budget 80 --games 15 --movetime 200

    # Verify the best result afterward
    python3 selfplay.py --verify --engine-a ./mantis --engine-b ./mantis \
        --option-a RfpMargin=35 --option-a FutilityMargin=80
"""

import argparse
import json
import os
import random
import re
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
DEFAULT_ENGINE = "./mantis"
BASELINE_ENGINE = "./mantis_baseline"
RESULT_FILE = "tuning_progress_uci.json"
BEST_PARAMS_FILE = "best_params_uci.json"

# Parameters to tune: name -> (min, max)
# Focus on the 8 highest-leverage search parameters
PARAM_RANGES: Dict[str, Tuple[int, int]] = {
    "nmp_reduction_base": (0, 4),
    "nmp_reduction_div":  (3, 10),
    "rfp_margin":         (10, 150),
    "rfp_depth":          (5, 10),
    "lmr_min_depth":      (2, 5),
    "futility_margin":    (30, 400),
    "lmp_base":           (1, 4),
    "lmp_div":            (1, 4),
}

PARAM_UCI_OPTIONS: Dict[str, str] = {
    "nmp_reduction_base": "NmpReductionBase",
    "nmp_reduction_div":  "NmpReductionDiv",
    "rfp_margin":         "RfpMargin",
    "rfp_depth":          "RfpDepth",
    "lmr_min_depth":      "LmrMinDepth",
    "futility_margin":    "FutilityMargin",
    "lmp_base":           "LmpBase",
    "lmp_div":            "LmpDiv",
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


def params_to_uci_option_args(params: Dict[str, int]) -> List[str]:
    """Convert snake_case tuning params into selfplay.py --option-a args."""
    args: List[str] = []
    for param, value in params.items():
        option_name = PARAM_UCI_OPTIONS[param]
        args += ["--option-a", f"{option_name}={value}"]
    return args


def random_candidate(rng: random.Random) -> Dict[str, int]:
    return {
        name: rng.randint(lo, hi)
        for name, (lo, hi) in PARAM_RANGES.items()
    }


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
                    engine: str = DEFAULT_ENGINE,
                    baseline: str = DEFAULT_ENGINE,
                    games: int = 10,
                    movetime: Optional[int] = 100,
                    depth: Optional[int] = None,
                    max_moves: Optional[int] = None,
                    concurrency: int = 4,
                    openings: Optional[str] = "openings.epd",
                    use_uci_options: bool = True) -> Optional[float]:
    """
    Run a quick tournament and return win percentage.
    Returns None on failure.
    """
    if not os.path.exists(engine):
        print(f"[ERROR] Engine not found: {engine}")
        return None

    if not os.path.exists(baseline):
        print(f"[ERROR] Baseline not found: {baseline}")
        return None

    cmd = [
        sys.executable, SELFPLAY_SCRIPT,
        "--engine-a", engine,
        "--engine-b", baseline,
        "--games", str(games),
        "--concurrency", str(concurrency),
    ]
    if depth is not None:
        cmd += ["--depth", str(depth)]
    else:
        cmd += ["--movetime", str(movetime or 100)]
    if max_moves is not None:
        cmd += ["--max-moves", str(max_moves)]
    if openings and os.path.exists(openings):
        cmd += ["--openings", openings]
    if use_uci_options:
        cmd += params_to_uci_option_args(params)

    print(f"[EVAL] {' '.join(cmd)}")
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


def load_history(resume_file: Optional[str]) -> List[dict]:
    if resume_file and os.path.exists(resume_file):
        with open(resume_file) as f:
            history = json.load(f)
        print(f"[RESUME] Loaded {len(history)} previous evaluations")
        return history
    return []


def best_from_history(history: List[dict]) -> Tuple[Dict[str, int], float]:
    best_score = -1.0
    best_params: Dict[str, int] = {}
    for entry in history:
        score = float(entry.get("score", 0.0))
        if score > best_score:
            best_score = score
            best_params = dict(entry.get("params", {}))
    return best_params, best_score


def save_history(resume_file: Optional[str], history: List[dict]):
    if resume_file:
        with open(resume_file, "w") as f:
            json.dump(history, f, indent=2)


def evaluate_candidate(candidate_params: Dict[str, int],
                       engine: str,
                       baseline: str,
                       games_per_eval: int,
                       movetime: Optional[int],
                       depth: Optional[int],
                       max_moves: Optional[int],
                       concurrency: int,
                       openings: Optional[str],
                       use_uci_options: bool,
                       original_content: Optional[str]) -> float:
    if not use_uci_options:
        if original_content is None:
            raise ValueError("source-edit tuning requires original tuning content")
        test_content = apply_params(original_content, candidate_params)
        write_tuning_file(test_content)
        print("  Building...")
        if not build_engine():
            print("  [BUILD FAILED] Assigning 0% win rate")
            return 0.0
        engine = DEFAULT_ENGINE

    score = evaluate_params(
        candidate_params,
        engine=engine,
        baseline=baseline,
        games=games_per_eval,
        movetime=movetime,
        depth=depth,
        max_moves=max_moves,
        concurrency=concurrency,
        openings=openings,
        use_uci_options=use_uci_options,
    )
    return 0.0 if score is None else score


# ---------------------------------------------------------------------------
# OPTIMIZATION
# ---------------------------------------------------------------------------

def run_nevergrad(budget: int,
                  engine: str,
                  baseline: str,
                  original_content: Optional[str] = None,
                  games_per_eval: int = 10,
                  movetime: Optional[int] = 100,
                  depth: Optional[int] = None,
                  max_moves: Optional[int] = None,
                  concurrency: int = 4,
                  openings: Optional[str] = "openings.epd",
                  resume_file: Optional[str] = None,
                  use_uci_options: bool = True) -> Tuple[Dict[str, int], float]:
    """Run Nevergrad optimization loop."""
    import nevergrad as ng

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
    history = load_history(resume_file)
    for entry in history:
        # Re-inject into optimizer.
        vals = [float(entry["params"][k]) for k in PARAM_RANGES.keys()]
        candidate = instrum.spawn_child().set_standardized_data(vals)
        optimizer.tell(candidate, -entry["score"])  # negate for maximization

    best_params, best_score = best_from_history(history)

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

        score = evaluate_candidate(
            candidate_params,
            engine=engine,
            baseline=baseline,
            games_per_eval=games_per_eval,
            movetime=movetime,
            depth=depth,
            max_moves=max_moves,
            concurrency=concurrency,
            openings=openings,
            use_uci_options=use_uci_options,
            original_content=original_content,
        )

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
            "optimizer": "nevergrad",
        })
        save_history(resume_file, history)

    if not use_uci_options and best_params:
        final_content = apply_params(original_content, best_params)
        write_tuning_file(final_content)
        build_engine()

    return best_params, best_score


def run_random_search(budget: int,
                      engine: str,
                      baseline: str,
                      original_content: Optional[str] = None,
                      games_per_eval: int = 10,
                      movetime: Optional[int] = 100,
                      depth: Optional[int] = None,
                      max_moves: Optional[int] = None,
                      concurrency: int = 4,
                      openings: Optional[str] = "openings.epd",
                      resume_file: Optional[str] = None,
                      use_uci_options: bool = True,
                      seed: int = 1) -> Tuple[Dict[str, int], float]:
    """Run dependency-free random search over the same parameter ranges."""
    rng = random.Random(seed)
    history = load_history(resume_file)
    best_params, best_score = best_from_history(history)

    for _ in range(len(history)):
        random_candidate(rng)

    for iteration in range(len(history), budget):
        print(f"\n{'='*60}")
        print(f"ITERATION {iteration + 1} / {budget}")
        print(f"{'='*60}")

        candidate_params = random_candidate(rng)
        print(f"  Params: {candidate_params}")

        score = evaluate_candidate(
            candidate_params,
            engine=engine,
            baseline=baseline,
            games_per_eval=games_per_eval,
            movetime=movetime,
            depth=depth,
            max_moves=max_moves,
            concurrency=concurrency,
            openings=openings,
            use_uci_options=use_uci_options,
            original_content=original_content,
        )

        if score > best_score:
            best_score = score
            best_params = dict(candidate_params)
            print(f"  *** NEW BEST: {score:.2f}% ***")

        history.append({
            "iteration": iteration + 1,
            "params": candidate_params,
            "score": score,
            "best_score": best_score,
            "best_params": dict(best_params),
            "optimizer": "random",
        })
        save_history(resume_file, history)

    if not use_uci_options and best_params:
        final_content = apply_params(original_content, best_params)
        write_tuning_file(final_content)
        build_engine()

    return best_params, best_score


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Mantis parameter tuner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Quick no-rebuild exploration against default params
  python3 nevergrad_tuner.py --engine ./mantis_uci_tune_options \\
      --optimizer random --budget 30 --games 10 --movetime 100

  # Overnight Nevergrad tuning, if nevergrad is installed
  python3 nevergrad_tuner.py --engine ./mantis \\
      --optimizer nevergrad --budget 80 --games 15 --movetime 200

  # Resume interrupted run
  python3 nevergrad_tuner.py --engine ./mantis --budget 50 --resume tuning_progress_uci.json
        """,
    )

    parser.add_argument("--optimizer", choices=["auto", "nevergrad", "random"], default="auto",
                        help="Optimizer to use; auto falls back to random if nevergrad is missing")
    parser.add_argument("--engine", default=DEFAULT_ENGINE,
                        help=f"Candidate engine binary (default: {DEFAULT_ENGINE})")
    parser.add_argument("--budget", type=int, default=30,
                        help="Number of evaluations (default: 30)")
    parser.add_argument("--games", type=int, default=10,
                        help="Games per evaluation (default: 10)")
    parser.add_argument("--movetime", type=int, default=100,
                        help="Fixed time per move in ms (default: 100)")
    parser.add_argument("--depth", type=int, default=None,
                        help="Use fixed-depth searches instead of movetime")
    parser.add_argument("--max-moves", type=int, default=None,
                        help="Forwarded to selfplay.py for quick smoke runs")
    parser.add_argument("--concurrency", type=int, default=4,
                        help="Parallel games (default: 4)")
    parser.add_argument("--baseline", default=None,
                        help="Baseline engine; default is candidate engine in UCI mode")
    parser.add_argument("--openings", default="openings.epd",
                        help="Opening FEN/move file for selfplay.py (default: openings.epd)")
    parser.add_argument("--no-openings", action="store_true",
                        help="Do not pass an openings file to selfplay.py")
    parser.add_argument("--source-edit", action="store_true",
                        help="Legacy mode: edit search/tuning.odin and rebuild each candidate")
    parser.add_argument("--seed", type=int, default=1,
                        help="Random-search seed (default: 1)")
    parser.add_argument("--resume", default=None,
                        help="Resume from progress JSON file")
    parser.add_argument("--output", default=BEST_PARAMS_FILE,
                        help=f"Output file for best params (default: {BEST_PARAMS_FILE})")
    parser.add_argument("--verify", action="store_true",
                        help="Run verification match after tuning")

    args = parser.parse_args()

    if args.budget < 1:
        parser.error("--budget must be at least 1")
    if args.games < 1:
        parser.error("--games must be at least 1")
    if args.concurrency < 1:
        parser.error("--concurrency must be at least 1")
    if args.depth is not None and args.depth < 1:
        parser.error("--depth must be at least 1")
    if args.movetime < 1:
        parser.error("--movetime must be at least 1")
    if args.max_moves is not None and args.max_moves < 1:
        parser.error("--max-moves must be at least 1")

    use_uci_options = not args.source_edit
    baseline = args.baseline or (BASELINE_ENGINE if args.source_edit else args.engine)
    engine = DEFAULT_ENGINE if args.source_edit else args.engine
    openings = None if args.no_openings else args.openings
    movetime = None if args.depth is not None else args.movetime

    if args.source_edit and not os.path.exists(TUNING_FILE):
        print(f"ERROR: Tuning file not found: {TUNING_FILE}")
        sys.exit(1)
    if use_uci_options and not os.path.exists(engine):
        print(f"ERROR: Engine not found: {engine}")
        sys.exit(1)
    if not os.path.exists(baseline):
        print(f"ERROR: Baseline engine not found: {baseline}")
        sys.exit(1)

    original_content = read_tuning_file() if args.source_edit else None

    optimizer_name = args.optimizer
    if optimizer_name == "auto":
        try:
            import nevergrad  # noqa: F401
            optimizer_name = "nevergrad"
        except ImportError:
            optimizer_name = "random"
            print("[INFO] nevergrad not installed; using dependency-free random search.")

    print("=" * 60)
    print("MANTIS PARAMETER TUNER")
    print("=" * 60)
    print(f"Optimizer: {optimizer_name}")
    print(f"Mode: {'UCI options' if use_uci_options else 'source edit + rebuild'}")
    print(f"Engine: {engine}")
    print(f"Baseline: {baseline}")
    print(f"Budget: {args.budget} evaluations")
    if args.depth is not None:
        print(f"Games per eval: {args.games} at depth {args.depth}")
    else:
        print(f"Games per eval: {args.games} at {args.movetime}ms")
    print(f"Concurrency: {args.concurrency}")
    if openings:
        print(f"Openings: {openings}")
    print(f"Parameters: {list(PARAM_RANGES.keys())}")
    print()

    try:
        if optimizer_name == "nevergrad":
            best_params, best_score = run_nevergrad(
                budget=args.budget,
                engine=engine,
                baseline=baseline,
                original_content=original_content,
                games_per_eval=args.games,
                movetime=movetime,
                depth=args.depth,
                max_moves=args.max_moves,
                concurrency=args.concurrency,
                openings=openings,
                resume_file=args.resume or RESULT_FILE,
                use_uci_options=use_uci_options,
            )
        else:
            best_params, best_score = run_random_search(
                budget=args.budget,
                engine=engine,
                baseline=baseline,
                original_content=original_content,
                games_per_eval=args.games,
                movetime=movetime,
                depth=args.depth,
                max_moves=args.max_moves,
                concurrency=args.concurrency,
                openings=openings,
                resume_file=args.resume or RESULT_FILE,
                use_uci_options=use_uci_options,
                seed=args.seed,
            )
    except KeyboardInterrupt:
        if args.source_edit and original_content is not None:
            print("\n[INTERRUPT] Restoring original tuning file...")
            write_tuning_file(original_content)
        sys.exit(1)
    except ImportError:
        print("ERROR: nevergrad not installed. Use --optimizer auto/random, or install nevergrad.")
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
            "--engine-a", engine,
            "--engine-b", baseline,
            "--verify",
            "--concurrency", str(args.concurrency),
        ]
        if openings:
            verify_cmd += ["--openings", openings]
        if use_uci_options:
            verify_cmd += params_to_uci_option_args(best_params)
        subprocess.run(verify_cmd)


if __name__ == "__main__":
    main()
