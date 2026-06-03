#!/usr/bin/env python3
"""
nevergrad_tuner.py — Parameter Tuner for Mantis

Uses Facebook's Nevergrad library, dependency-free random search, or paired
SPSA for derivative-free optimization of chess engine parameters.

Requirements:
    # Random-search fallback needs no extra packages.
    python3 nevergrad_tuner.py --optimizer random --budget 50

    # Nevergrad mode:
    source venv/bin/activate
    python3 nevergrad_tuner.py --optimizer nevergrad --budget 50

    # Dependency-free paired SPSA mode:
    python3 nevergrad_tuner.py --optimizer spsa --budget 50

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

    # Paired SPSA tuning through UCI options
    python3 nevergrad_tuner.py --engine ./mantis \
        --optimizer spsa --budget 80 --games 20 --movetime 200

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
SPSA_RESULT_FILE = "tuning_progress_spsa.json"
BEST_PARAMS_FILE = "best_params_uci.json"
DEFAULT_OPENINGS = "2moves_v1.epd"

# Parameters to tune: source field name -> (min, max)
# These ranges mirror the bounded UCI tuning options.
PARAM_RANGES: Dict[str, Tuple[int, int]] = {
    "aspiration_window":   (5, 200),
    "nmp_min_depth":       (2, 6),
    "nmp_reduction_base": (0, 4),
    "nmp_reduction_div":  (3, 10),
    "rfp_margin":         (10, 150),
    "rfp_depth":          (5, 10),
    "probcut_depth":      (3, 8),
    "probcut_margin":     (0, 300),
    "probcut_reduce":     (1, 6),
    "iir_min_depth":      (3, 8),
    "se_depth":           (5, 12),
    "se_margin":          (0, 8),
    "se_reduced_div":     (1, 4),
    "lmr_min_depth":      (2, 5),
    "lmr_improving_adj":  (-4, 4),
    "lmr_history_good_adj": (-4, 4),
    "lmr_history_bad_adj":  (-4, 4),
    "lmr_history_good_thresh": (0, 10000),
    "lmr_history_bad_thresh":  (-10000, 0),
    "futility_margin":    (30, 400),
    "futility_max_depth": (1, 6),
    "lmp_base":           (1, 4),
    "lmp_div":            (1, 4),
    "lmp_max_depth":      (3, 12),
    "razor_margin":       (0, 300),
    "razor_max_depth":    (1, 5),
    "delta_pruning_margin": (0, 1200),
    "see_prune_threshold":  (-300, 0),
    "continuation_score_div": (1, 64),
    "contempt":           (-100, 100),
}

PARAM_DEFAULTS: Dict[str, int] = {
    "aspiration_window":   35,
    "nmp_min_depth":       3,
    "nmp_reduction_base":  2,
    "nmp_reduction_div":   6,
    "rfp_margin":          25,
    "rfp_depth":           8,
    "probcut_depth":       5,
    "probcut_margin":      40,
    "probcut_reduce":      4,
    "iir_min_depth":       4,
    "se_depth":            8,
    "se_margin":           2,
    "se_reduced_div":      2,
    "lmr_min_depth":       3,
    "lmr_improving_adj":   -1,
    "lmr_history_good_adj": -1,
    "lmr_history_bad_adj":  1,
    "lmr_history_good_thresh": 2000,
    "lmr_history_bad_thresh":  -2000,
    "futility_margin":     65,
    "futility_max_depth":  3,
    "lmp_base":            2,
    "lmp_div":             2,
    "lmp_max_depth":       8,
    "razor_margin":        80,
    "razor_max_depth":     3,
    "delta_pruning_margin": 250,
    "see_prune_threshold":  -50,
    "continuation_score_div": 12,
    "contempt":            12,
}

PARAM_UCI_OPTIONS: Dict[str, str] = {
    "aspiration_window":   "AspirationWindow",
    "nmp_min_depth":       "NmpMinDepth",
    "nmp_reduction_base": "NmpReductionBase",
    "nmp_reduction_div":  "NmpReductionDiv",
    "rfp_margin":         "RfpMargin",
    "rfp_depth":          "RfpDepth",
    "probcut_depth":      "ProbcutDepth",
    "probcut_margin":     "ProbcutMargin",
    "probcut_reduce":     "ProbcutReduce",
    "iir_min_depth":      "IirMinDepth",
    "se_depth":           "SeDepth",
    "se_margin":          "SeMargin",
    "se_reduced_div":     "SeReducedDiv",
    "lmr_min_depth":      "LmrMinDepth",
    "lmr_improving_adj":  "LmrImprovingAdj",
    "lmr_history_good_adj": "LmrHistoryGoodAdj",
    "lmr_history_bad_adj":  "LmrHistoryBadAdj",
    "lmr_history_good_thresh": "LmrHistoryGoodThresh",
    "lmr_history_bad_thresh":  "LmrHistoryBadThresh",
    "futility_margin":    "FutilityMargin",
    "futility_max_depth": "FutilityMaxDepth",
    "lmp_base":           "LmpBase",
    "lmp_div":            "LmpDiv",
    "lmp_max_depth":      "LmpMaxDepth",
    "razor_margin":       "RazorMargin",
    "razor_max_depth":    "RazorMaxDepth",
    "delta_pruning_margin": "DeltaPruningMargin",
    "see_prune_threshold":  "SeePruneThreshold",
    "continuation_score_div": "ContinuationScoreDiv",
    "contempt":           "Contempt",
}

PARAM_NAMES = tuple(PARAM_RANGES.keys())

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


def params_to_side_uci_option_args(params: Dict[str, int], side: str) -> List[str]:
    """Convert snake_case tuning params into selfplay.py --option-{side} args."""
    args: List[str] = []
    for param, value in params.items():
        option_name = PARAM_UCI_OPTIONS[param]
        args += [f"--option-{side}", f"{option_name}={value}"]
    return args


def params_to_uci_option_args(params: Dict[str, int]) -> List[str]:
    """Convert snake_case tuning params into selfplay.py --option-a args."""
    return params_to_side_uci_option_args(params, "a")


def random_candidate(rng: random.Random) -> Dict[str, int]:
    return {
        name: rng.randint(lo, hi)
        for name, (lo, hi) in PARAM_RANGES.items()
    }


def clamp_unit(value: float) -> float:
    return max(0.0, min(1.0, value))


def clamp_param(name: str, value: int) -> int:
    lo, hi = PARAM_RANGES[name]
    return max(lo, min(hi, value))


def param_to_unit(name: str, value: int) -> float:
    lo, hi = PARAM_RANGES[name]
    if hi == lo:
        return 0.0
    return clamp_unit((value - lo) / (hi - lo))


def unit_to_param(name: str, value: float) -> int:
    lo, hi = PARAM_RANGES[name]
    return clamp_param(name, int(round(lo + clamp_unit(value) * (hi - lo))))


def params_to_unit(params: Dict[str, int]) -> Dict[str, float]:
    return {name: param_to_unit(name, params[name]) for name in PARAM_NAMES}


def unit_to_params(theta: Dict[str, float]) -> Dict[str, int]:
    return {name: unit_to_param(name, theta[name]) for name in PARAM_NAMES}


def default_resume_file(optimizer_name: str) -> str:
    if optimizer_name == "spsa":
        return SPSA_RESULT_FILE
    return RESULT_FILE


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
                    openings: Optional[str] = DEFAULT_OPENINGS,
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


def evaluate_param_pair(plus_params: Dict[str, int],
                        minus_params: Dict[str, int],
                        engine: str = DEFAULT_ENGINE,
                        baseline: str = DEFAULT_ENGINE,
                        games: int = 10,
                        movetime: Optional[int] = 100,
                        depth: Optional[int] = None,
                        max_moves: Optional[int] = None,
                        concurrency: int = 4,
                        openings: Optional[str] = DEFAULT_OPENINGS) -> Optional[float]:
    """
    Run a paired SPSA match and return plus score as win percentage.
    Engine A receives plus_params; engine B receives minus_params.
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
    cmd += params_to_side_uci_option_args(plus_params, "a")
    cmd += params_to_side_uci_option_args(minus_params, "b")

    print(f"[SPSA EVAL] {' '.join(cmd)}")
    start = time.time()
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    elapsed = time.time() - start

    if result.returncode != 0:
        print(f"[SPSA EVAL FAILED] rc={result.returncode}")
        return None

    m = re.search(r"Win %:\s+([\d.]+)%", result.stdout)
    if m:
        win_pct = float(m.group(1))
        illegal_count = result.stdout.count("(illegal move")
        failed_count = result.stdout.count("failed:")
        total_games = games
        problem_rate = (illegal_count + failed_count) / total_games * 100 if total_games > 0 else 0
        print(f"[SPSA OK] Plus Win %: {win_pct:.2f}  Illegal:{illegal_count} Failed:{failed_count}  ({elapsed:.1f}s)")
        if problem_rate > 10:
            print(f"[SPSA WARNING] Problem rate {problem_rate:.1f}% > 10%, treating as neutral")
            return 50.0
        return win_pct

    print("[SPSA EVAL PARSE ERROR]")
    return None


def params_match_current_surface(params: object) -> bool:
    """Return True when saved params match the active tuning surface."""
    if not isinstance(params, dict):
        return False
    if set(params.keys()) != set(PARAM_RANGES.keys()):
        return False
    for name, value in params.items():
        if isinstance(value, bool) or not isinstance(value, int):
            return False
        lo, hi = PARAM_RANGES[name]
        if value < lo or value > hi:
            return False
    return True


def entry_matches_current_surface(entry: dict) -> bool:
    params = entry.get("params")
    best_params = entry.get("best_params", params)
    return params_match_current_surface(params) and params_match_current_surface(best_params)


def load_history(resume_file: Optional[str], optimizer: Optional[str] = None) -> List[dict]:
    if resume_file and os.path.exists(resume_file):
        with open(resume_file) as f:
            history = json.load(f)
        if not isinstance(history, list):
            print("[RESUME] Ignoring progress file with unexpected format")
            return []
        filtered = []
        incompatible = 0
        other_optimizer = 0
        for entry in history:
            if not isinstance(entry, dict) or not entry_matches_current_surface(entry):
                incompatible += 1
                continue
            if optimizer is not None and entry.get("optimizer") != optimizer:
                other_optimizer += 1
                continue
            filtered.append(entry)
        if incompatible > 0:
            print(f"[RESUME] Skipped {incompatible} incompatible previous evaluations")
        if other_optimizer > 0:
            print(f"[RESUME] Skipped {other_optimizer} evaluations from another optimizer")
        print(f"[RESUME] Loaded {len(filtered)} previous evaluations")
        return filtered
    return []


def best_from_history(history: List[dict]) -> Tuple[Dict[str, int], float]:
    best_score = -1.0
    best_params: Dict[str, int] = {}
    for entry in history:
        score = float(entry.get("best_score", entry.get("score", 0.0)))
        if score > best_score:
            best_score = score
            best_params = dict(entry.get("best_params", entry.get("params", {})))
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
                  openings: Optional[str] = DEFAULT_OPENINGS,
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
    history = load_history(resume_file, optimizer="nevergrad")
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
                      openings: Optional[str] = DEFAULT_OPENINGS,
                      resume_file: Optional[str] = None,
                      use_uci_options: bool = True,
                      seed: int = 1) -> Tuple[Dict[str, int], float]:
    """Run dependency-free random search over the same parameter ranges."""
    rng = random.Random(seed)
    history = load_history(resume_file, optimizer="random")
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


def make_spsa_pair(theta: Dict[str, float],
                   signs: Dict[str, int],
                   ck: float) -> Tuple[Dict[str, int], Dict[str, int]]:
    plus: Dict[str, int] = {}
    minus: Dict[str, int] = {}
    for name in PARAM_NAMES:
        sign = signs[name]
        plus_value = unit_to_param(name, theta[name] + sign * ck)
        minus_value = unit_to_param(name, theta[name] - sign * ck)
        if plus_value == minus_value:
            lo, hi = PARAM_RANGES[name]
            if sign > 0:
                if plus_value < hi:
                    plus_value += 1
                elif minus_value > lo:
                    minus_value -= 1
            else:
                if plus_value > lo:
                    plus_value -= 1
                elif minus_value < hi:
                    minus_value += 1
        plus[name] = clamp_param(name, plus_value)
        minus[name] = clamp_param(name, minus_value)
    return plus, minus


def theta_from_history(history: List[dict]) -> Dict[str, float]:
    if history:
        last = history[-1]
        theta = last.get("theta")
        if isinstance(theta, dict) and set(theta.keys()) == set(PARAM_NAMES):
            return {name: clamp_unit(float(theta[name])) for name in PARAM_NAMES}
        params = last.get("params")
        if params_match_current_surface(params):
            return params_to_unit(params)
    return params_to_unit(PARAM_DEFAULTS)


def run_spsa(budget: int,
             engine: str,
             baseline: str,
             games_per_eval: int = 10,
             movetime: Optional[int] = 100,
             depth: Optional[int] = None,
             max_moves: Optional[int] = None,
             concurrency: int = 4,
             openings: Optional[str] = DEFAULT_OPENINGS,
             resume_file: Optional[str] = None,
             seed: int = 1,
             a: float = 0.08,
             c: float = 0.10,
             alpha: float = 0.602,
             gamma: float = 0.101,
             stability: Optional[float] = None) -> Tuple[Dict[str, int], float]:
    """Run dependency-free paired SPSA over normalized UCI parameters."""
    if a <= 0.0:
        raise ValueError("SPSA learning-rate scale must be positive")
    if c <= 0.0:
        raise ValueError("SPSA perturbation scale must be positive")
    if alpha <= 0.0 or gamma <= 0.0:
        raise ValueError("SPSA decay exponents must be positive")

    rng = random.Random(seed)
    history = load_history(resume_file, optimizer="spsa")
    theta = theta_from_history(history)
    best_params, best_score = best_from_history(history)
    if not best_params:
        best_params = unit_to_params(theta)
        best_score = 50.0

    # Keep resumed runs deterministic by consuming the signs already used.
    for _ in range(len(history)):
        for _name in PARAM_NAMES:
            rng.choice((-1, 1))

    A = stability if stability is not None else max(1.0, budget * 0.10)

    for iteration in range(len(history), budget):
        k = iteration + 1
        ak = a / ((k + A) ** alpha)
        ck = c / (k ** gamma)
        signs = {name: rng.choice((-1, 1)) for name in PARAM_NAMES}
        plus_params, minus_params = make_spsa_pair(theta, signs, ck)

        print(f"\n{'='*60}")
        print(f"SPSA ITERATION {iteration + 1} / {budget}")
        print(f"{'='*60}")
        print(f"  ak={ak:.6f} ck={ck:.6f}")
        print(f"  Center: {unit_to_params(theta)}")
        print(f"  Plus:   {plus_params}")
        print(f"  Minus:  {minus_params}")

        score = evaluate_param_pair(
            plus_params,
            minus_params,
            engine=engine,
            baseline=baseline,
            games=games_per_eval,
            movetime=movetime,
            depth=depth,
            max_moves=max_moves,
            concurrency=concurrency,
            openings=openings,
        )
        if score is None:
            score = 50.0

        if score > best_score:
            best_score = score
            best_params = dict(plus_params)
            print(f"  *** NEW BEST PAIR SIDE: plus {score:.2f}% ***")
        if 100.0 - score > best_score:
            best_score = 100.0 - score
            best_params = dict(minus_params)
            print(f"  *** NEW BEST PAIR SIDE: minus {100.0 - score:.2f}% ***")

        score_delta = (score - 50.0) / 50.0
        denom = max(1.0e-9, 2.0 * ck)
        for name in PARAM_NAMES:
            theta[name] = clamp_unit(theta[name] + ak * score_delta * signs[name] / denom)

        current_params = unit_to_params(theta)
        history.append({
            "iteration": iteration + 1,
            "params": current_params,
            "score": score,
            "score_delta": score_delta,
            "best_score": best_score,
            "best_params": dict(best_params),
            "plus_params": plus_params,
            "minus_params": minus_params,
            "theta": theta.copy(),
            "optimizer": "spsa",
            "ak": ak,
            "ck": ck,
        })
        save_history(resume_file, history)
        print(f"  Updated center: {current_params}")

    return unit_to_params(theta), best_score


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

  # Dependency-free paired SPSA tuning
  python3 nevergrad_tuner.py --engine ./mantis \\
      --optimizer spsa --budget 80 --games 20 --movetime 200

  # Resume interrupted run
  python3 nevergrad_tuner.py --engine ./mantis --budget 50 --resume tuning_progress_uci.json
        """,
    )

    parser.add_argument("--optimizer", choices=["auto", "nevergrad", "random", "spsa"], default="auto",
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
    parser.add_argument("--openings", default=DEFAULT_OPENINGS,
                        help=f"Opening FEN/move file for selfplay.py (default: {DEFAULT_OPENINGS})")
    parser.add_argument("--no-openings", action="store_true",
                        help="Do not pass an openings file to selfplay.py")
    parser.add_argument("--source-edit", action="store_true",
                        help="Legacy mode: edit search/tuning.odin and rebuild each candidate")
    parser.add_argument("--seed", type=int, default=1,
                        help="Random-search seed (default: 1)")
    parser.add_argument("--spsa-a", type=float, default=0.08,
                        help="SPSA normalized learning-rate scale (default: 0.08)")
    parser.add_argument("--spsa-c", type=float, default=0.10,
                        help="SPSA normalized perturbation scale (default: 0.10)")
    parser.add_argument("--spsa-alpha", type=float, default=0.602,
                        help="SPSA learning-rate decay exponent (default: 0.602)")
    parser.add_argument("--spsa-gamma", type=float, default=0.101,
                        help="SPSA perturbation decay exponent (default: 0.101)")
    parser.add_argument("--spsa-stability", type=float, default=None,
                        help="SPSA stability constant A; default is 10%% of budget")
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
    if args.optimizer == "spsa" and args.source_edit:
        parser.error("--optimizer spsa requires UCI option mode; omit --source-edit")
    if args.spsa_a <= 0.0:
        parser.error("--spsa-a must be positive")
    if args.spsa_c <= 0.0:
        parser.error("--spsa-c must be positive")
    if args.spsa_alpha <= 0.0:
        parser.error("--spsa-alpha must be positive")
    if args.spsa_gamma <= 0.0:
        parser.error("--spsa-gamma must be positive")
    if args.spsa_stability is not None and args.spsa_stability < 0.0:
        parser.error("--spsa-stability must be non-negative")

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
    if optimizer_name == "spsa":
        stability_display = args.spsa_stability if args.spsa_stability is not None else max(1.0, args.budget * 0.10)
        print(
            f"SPSA schedule: a={args.spsa_a} c={args.spsa_c} "
            f"alpha={args.spsa_alpha} gamma={args.spsa_gamma} A={stability_display}"
        )
    resume_file = args.resume or default_resume_file(optimizer_name)
    print(f"Progress file: {resume_file}")
    print(f"Parameters: {list(PARAM_RANGES.keys())}")
    print()

    try:
        if optimizer_name == "spsa":
            best_params, best_score = run_spsa(
                budget=args.budget,
                engine=engine,
                baseline=baseline,
                games_per_eval=args.games,
                movetime=movetime,
                depth=args.depth,
                max_moves=args.max_moves,
                concurrency=args.concurrency,
                openings=openings,
                resume_file=resume_file,
                seed=args.seed,
                a=args.spsa_a,
                c=args.spsa_c,
                alpha=args.spsa_alpha,
                gamma=args.spsa_gamma,
                stability=args.spsa_stability,
            )
        elif optimizer_name == "nevergrad":
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
                resume_file=resume_file,
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
                resume_file=resume_file,
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
    if optimizer_name == "spsa":
        print(f"Best pair-side score seen: {best_score:.2f}%")
        print("Final center parameters:")
    else:
        print(f"Best score: {best_score:.2f}%")
        print("Best parameters:")
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
