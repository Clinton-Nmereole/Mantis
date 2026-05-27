== Testing and Quality Assurance

Chess engine development is fundamentally an empirical science. You propose a change—a new heuristic, a smarter reduction formula, a refined evaluation term, a re-tuned table—and you must determine whether it actually improves the engine's playing strength. The only reliable way to do this is through rigorous statistical testing. This chapter covers the complete testing pipeline used by modern chess engines, from the underlying statistical theory to the practical infrastructure that runs millions of games per day.

=== Why Testing Is Hard

Chess is a high-variance game. Even a strong engine can lose to a weaker one due to a single blunder, an unlucky opening, or a misevaluation. A single game proves almost nothing about an engine's true strength. We need hundreds or thousands of games to reliably detect small improvements, and the number of games required grows quadratically as the expected improvement shrinks.

Consider the challenge: you make a change that you believe adds 3 Elo to your engine. At typical time controls (10+0.1s), the draw rate is high (60-70%) and the expected score difference is tiny—perhaps 50.4% vs 49.6%. Statistically distinguishing a 50.4% true win rate from 50% requires approximately:

```
N >= (Z * sigma / delta)^2
```

Where `Z ≈ 1.96` for 95% confidence, `sigma ≈ 0.45` (standard deviation per game for chess), and `delta = 0.004` (50.4% - 50%). This gives `N >= 48,600` games. A 3 Elo improvement—which in human terms is almost imperceptible—requires nearly 50,000 games to verify. A 1 Elo improvement requires nearly 450,000 games. Welcome to the brutal mathematics of engine testing.

=== The SPRT: Sequential Probability Ratio Test

The SPRT (Sequential Probability Ratio Test), invented by Abraham Wald in 1945 and popularized in chess engine testing by the Stockfish project, is the gold standard for engine testing. Unlike classical fixed-sample hypothesis testing (where you decide the number of games in advance), SPRT is *sequential*: you test after each game whether the accumulated evidence is sufficient to reach a conclusion.

==== The SPRT Framework

SPRT tests two hypotheses:

- **H0 (null hypothesis)**: The engine has not improved. Its true score is `p0` (typically 50%, or slightly below the self-play expectation).
- **H1 (alternative hypothesis)**: The engine has improved. Its true score is `p1` (e.g., 50.4% for a +3 Elo test).

The test computes a likelihood ratio after each game:

```
LR = (probability of observed results under H1) / (probability of observed results under H0)
```

Let `wins`, `losses`, and `draws` be the game counts. Let `p0_win`, `p0_loss`, `p0_draw` be the expected probabilities under H0, and `p1_win`, `p1_loss`, `p1_draw` under H1. The log-likelihood ratio is:

```
LLR = wins * log(p1_win / p0_win) + losses * log(p1_loss / p0_loss) + draws * log(p1_draw / p0_draw)
```

After each game, we compare `LLR` against two thresholds:

- If `LLR >= log((1 - beta) / alpha)`: **Accept H1** (the change is an improvement).
- If `LLR <= log(beta / (1 - alpha))`: **Accept H0** (the change is not an improvement).
- Otherwise: **Continue testing**.

Where `alpha` is the Type I error rate (false positive: accepting H1 when H0 is true) and `beta` is the Type II error rate (false negative: accepting H0 when H1 is true). Typical values: `alpha = 0.05`, `beta = 0.05`.

==== SPRT in Practice: Fishtest Parameters

Stockfish's distributed testing framework, Fishtest, uses these SPRT parameters:

```text
Type I error (alpha):  0.05
Type II error (beta):  0.05
H0 (null):  elo0 = 0  (no improvement)
H1 (alt):   elo1 = X  (X Elo improvement, typical 0.5 to 6.0)
```

The Elo parameters are converted to expected scores using the logistic Elo model:

```
expected_score = 1 / (1 + 10^(-delta_elo / 400))
```

For a `delta_elo = 3`, the expected score is approximately 50.43% (accounting for the draw rate). Fishtest handles the conversion internally.

A typical SPRT test with `elo0 = 0.5` and `elo1 = 4.0` will:

- Accept H1 after approximately 6,000-20,000 games if the change is genuinely +3 Elo.
- Accept H0 after approximately 4,000-15,000 games if the change is neutral or negative.
- Terminate early for large improvements (a +10 Elo change may be detected in under 1,000 games).

The sequential nature is its greatest strength: the test stops as soon as the evidence is sufficient, rather than running a predetermined number of games.

==== Python Implementation of SPRT

```python
import math
from enum import Enum

class SPRTResult(Enum):
    ACCEPT_H1 = 1
    ACCEPT_H0 = 2
    CONTINUE = 3

class SPRT:
    def __init__(self, alpha=0.05, beta=0.05, elo0=0.0, elo1=3.0, draw_rate=0.65):
        self.alpha = alpha
        self.beta = beta
        self.elo0 = elo0
        self.elo1 = elo1
        self.lo = math.log(beta / (1 - alpha))   # lower bound
        self.hi = math.log((1 - beta) / alpha)    # upper bound
        
        # Convert Elo to expected scores for wins and losses
        self.score0 = 1.0 / (1.0 + 10.0 ** (-elo0 / 400.0))
        self.score1 = 1.0 / (1.0 + 10.0 ** (-elo1 / 400.0))
        
        self.win0 = (1.0 - draw_rate) * self.score0
        self.loss0 = (1.0 - draw_rate) * (1.0 - self.score0)
        self.draw0 = draw_rate
        
        self.win1 = (1.0 - draw_rate) * self.score1
        self.loss1 = (1.0 - draw_rate) * (1.0 - self.score1)
        self.draw1 = draw_rate
        
        self.wins = 0
        self.losses = 0
        self.draws = 0
        self.llr = 0.0
    
    def update(self, result):
        """result: 1.0 = win, 0.5 = draw, 0.0 = loss"""
        if result == 1.0:
            self.wins += 1
            self.llr += math.log(self.win1 / self.win0)
        elif result == 0.0:
            self.losses += 1
            self.llr += math.log(self.loss1 / self.loss0)
        else:
            self.draws += 1
            self.llr += math.log(self.draw1 / self.draw0)
        
        if self.llr >= self.hi:
            return SPRTResult.ACCEPT_H1
        elif self.llr <= self.lo:
            return SPRTResult.ACCEPT_H0
        return SPRTResult.CONTINUE
    
    def estimated_elo(self):
        """Estimate current Elo difference"""
        total = self.wins + self.losses + self.draws
        if total == 0:
            return 0.0
        score = (self.wins + 0.5 * self.draws) / total
        # Logistic transformation
        return -400.0 * math.log10(1.0 / score - 1.0)

# Example usage
sprt = SPRT(alpha=0.05, beta=0.05, elo0=0.0, elo1=3.0)
results = [1.0, 0.5, 1.0, 0.0, 0.5, ...]  # from cutechess output
for r in results:
    decision = sprt.update(r)
    if decision != SPRTResult.CONTINUE:
        break
print(f"Games: {sprt.wins + sprt.losses + sprt.draws}, "
      f"LLR: {sprt.llr:.3f}, Elo: {sprt.estimated_elo():.1f}")
```

==== Type I and Type II Errors in Testing

- **Type I Error (False Positive)**: The test says your change is an improvement, but it's actually neutral or negative. Probability: `alpha` (typically 5%). Consequence: you merge a non-improving patch, wasting future testing resources (since all future tests now have a slightly worse baseline).
- **Type II Error (False Negative)**: The test says your change is not an improvement, but it actually IS. Probability: `beta` (typically 5%). Consequence: you discard a genuinely good idea.

Chess engine testing typically accepts higher Type II error rates than Type I because:
1. False positives accumulate and degrade the master branch permanently.
2. False negatives can be recovered by re-testing (the same idea tried a different way, or at a different time, may pass).
3. The cost of merging bad code exceeds the cost of discarding good ideas.

Fishtest adds an additional protection: *bounds* (H0 acceptance truncated at 0 games for very obvious losses). If the LLR immediately plummets after 1,000 games with a crushing score (< 30%), the test is terminated without waiting for the full SPRT boundary.

=== Cutechess-Cli: The Workhorse of Engine Testing

`cutechess-cli` is the command-line tool that orchestrates most modern engine testing. It manages the engine processes, passes the UCI protocol commands, runs the games, and outputs results in a format suitable for SPRT analysis.

==== Installing and Configuring Cutechess

```bash
# Build from source (recommended for latest features)
git clone https://github.com/cutechess/cutechess.git
cd cutechess
qmake
make -j$(nproc)
sudo make install
```

==== A Complete Test Suite Script

```bash
#!/bin/bash
# test_suite.sh - Run an SPRT test between two engine versions

BASE="./engines/MyEngine-v1.0"
TEST="./engines/MyEngine-v1.1"
OPENINGS="./books/8moves_v3.pgn"
THREADS=1
HASH=64
TIME_CONTROL="10+0.1"
GAMES=50000
CONCURRENCY=8  # number of parallel game pairs

cutechess-cli \
    -engine name="Base" cmd="$BASE" proto=uci \
    -engine name="Test" cmd="$TEST" proto=uci \
    -each tc=$TIME_CONTROL threads=$THREADS hash=$HASH \
    -openings file=$OPENINGS format=pgn order=random \
    -games $GAMES \
    -concurrency $CONCURRENCY \
    -repeat \
    -recover \
    -resign movecount=5 score=800 \
    -draw movenumber=40 movecount=10 score=5 \
    -pgnout "games/test_$(date +%Y%m%d_%H%M%S).pgn" \
    -resultformat wide \
    -sprt elo0=0 elo1=3 alpha=0.05 beta=0.05
```

Breaking down the flags:

- `-each tc=10+0.1 threads=1 hash=64`: Each engine gets 10 seconds base time + 0.1s increment, 1 CPU thread, 64MB hash.
- `-openings file=$OPENINGS order=random`: Use a pre-selected opening book to ensure diverse positions. The same openings are played from both sides (with `-repeat`).
- `-concurrency 8`: Run 8 games simultaneously (one per CPU core). This maximizes throughput.
- `-resign movecount=5 score=800`: Auto-resign if the engine's score is below -800 centipawns (8 pawns down) for 5 consecutive moves.
- `-draw movecount=10 score=5`: Auto-adjudicate a draw if both engines score within ±5 centipawns for 10 consecutive moves after move 40.
- `-sprt elo0=0 elo1=3 alpha=0.05 beta=0.05`: Use SPRT termination with the specified parameters.
- `-repeat`: Each opening is played with both colors (engine A as white, then engine B as white), eliminating opening bias.
- `-recover`: If an engine crashes, cutechess attempts to restart it rather than aborting the entire test.

==== Opening Book Selection

The choice of opening book dramatically affects test sensitivity:

**Small books (250-2,000 positions)**: Most common for fast testing. Positions are carefully selected to be balanced (evaluations near zero), avoiding forced draws, forced wins, or book lines that lead to premature simplification.

**Large books (10,000-100,000+ positions)**: Used for thorough regression testing. Better coverage of chess space but dilutes the test (more positions with trivial outcomes).

**Balanced books**: The standard. A 2,000-position book where each position has been evaluated between -0.5 and +0.5 by a strong engine, excluding positions with forced tactical sequences.

**Pentanomial books**: A newer idea—five categories of positions (slightly better for white, slightly better for black, equal, tactical, positional). This provides better statistical power because it controls for the color advantage.

The best practice: use a 2,000-5,000 position balanced book for rapid SPRT testing, then a 50,000-position large book for final regression testing before release.

==== Elo Calculation from Match Results

Given a match result with `wins`, `losses`, and `draws`, the Elo difference is estimated using the logistic model:

```python
def calculate_elo(wins, losses, draws):
    total = wins + losses + draws
    if total == 0:
        return 0, 0
    # Observed score (draw = 0.5)
    score = (wins + 0.5 * draws) / total
    
    # Avoid saturation at 0 or 1
    score = max(0.001, min(0.999, score))
    
    # Logistic Elo formula
    elo = -400 * math.log10(1.0 / score - 1.0)
    
    # Standard error (approximate)
    win_pct = wins / total
    loss_pct = losses / total
    draw_pct = draws / total
    variance = (win_pct * (1 - score)**2 + 
                loss_pct * (0 - score)**2 + 
                draw_pct * (0.5 - score)**2) / total
    std_error = 400 * math.sqrt(variance) / (score * (1 - score) * math.log(10))
    
    return elo, std_error

# Example: 100 wins, 80 losses, 320 draws (500 games)
elo, err = calculate_elo(100, 80, 320)
print(f"Elo: {elo:.1f} +/- {1.96 * err:.1f} (95% CI)")
# Output: Elo: +14.0 +/- 11.3 (95% CI)
```

The 95% confidence interval is approximately `elo ± 1.96 * std_error`. If this interval does not include zero, the result is statistically significant at the 5% level.

==== Understanding the Draw Rate Impact

The draw rate is the single most important factor in test efficiency. A higher draw rate *reduces* the effective sample size because draws contribute less information than decisive games. The relationship is:

```
effective_games = wins + losses + 0.25 * draws  (approximate)
```

Or more precisely, the variance of the score is:

```
Var(score) = (p_win + p_draw/4) / N
```

For `p_draw = 0.65` vs `p_draw = 0.30`, the required sample size scales by approximately:

```
N_required ∝ 1 - (p_draw / 2)
```

So 65% draw rate requires roughly 3x as many games as a 30% draw rate for the same precision. This is why developers test at faster time controls (where the draw rate is lower) and why some tests use deliberately unbalanced opening books (to force decisive games).

=== Distributed Testing: The Fishtest Model

Stockfish's Fishtest is the most successful distributed testing framework in chess engine history. At any moment, hundreds of volunteers contribute CPU time, running over 100,000 games per day across thousands of concurrent tests.

==== Architecture

Fishtest consists of:

1. **Web Server (Flask/Python)**: Manages the test queue, assigns work to workers, collects results, performs SPRT calculations.
2. **Worker (Python)**: Runs on volunteer machines, downloads engine binaries, runs cutechess-cli, uploads PGN results.
3. **Database (MongoDB)**: Stores test results, worker history, engine binaries.
4. **Build System**: Compiles proposed patches into binaries for both Linux and Windows workers.

A test submission specifies:
- The base branch (usually master).
- A git diff (the proposed change).
- SPRT parameters (elo0, elo1, alpha, beta).
- Number of games per worker chunk (typically 200-500).

The server allocates work in *chunks*: each worker receives a chunk (e.g., "play 400 games of base vs. test with this opening book") and returns the results. The server aggregates results across all workers and updates the SPRT after each chunk.

==== Setting Up a Private Fishtest-Like System

For individual developers or small teams, a full Fishtest deployment is overkill. A simpler alternative:

```bash
#!/bin/bash
# distributed_test.sh - Split work across multiple machines

MACHINES=("node1" "node2" "node3" "node4")
GAMES_PER_MACHINE=$((TOTAL_GAMES / ${#MACHINES[@]}))

for machine in "${MACHINES[@]}"; do
    ssh $machine "cd /path/to/engine && ./test_suite.sh" &
done
wait

# Collect and aggregate results
cat games/node*/*.pgn > combined.pgn
python sprt_analysis.py combined.pgn
```

Alternatively, use a simple web service: a central database (SQLite is sufficient for individual use) where workers register, fetch work items, and post results. This is 500-1000 lines of Python and can be set up in a day.

=== Testing for Regressions

A *regression* is a change that accidentally decreases playing strength. Regressions are the bane of engine development—they're easy to introduce (a typo, a sign error, a misplaced optimization) and sometimes hard to detect (a -0.5 Elo loss is effectively invisible without thousands of games).

==== Regression Test Framework

1. **Non-regression bounds**: Before merging any patch, run a "non-regression" SPRT with `elo0 = -1.5` and `elo1 = 0.5`. This tests that the patch does NOT lose more than 1.5 Elo. The asymmetric bounds (higher threshold for H1 than |H0|) reflect the cost asymmetry: merging a 1 Elo gain is good, but merging a 2 Elo loss is terrible.

2. **Bisection**: When a regression IS detected (the master branch suddenly loses Elo), the standard debugging technique is git bisect with SPRT at each step:

```bash
git bisect start
git bisect bad HEAD
git bisect good <last_known_good_commit>

# At each step, compile and run an SPRT against the known-good baseline
git bisect run bash -c '
    make clean && make -j$(nproc) && \
    cutechess-cli -engine cmd=./engine ... -sprt elo0=0 elo1=5 ... && \
    python check_sprt_result.py
'
```

This is expensive (each bisect step requires thousands of games), but it's the only reliable way to find the offending commit when the Elo loss is small.

3. **Continuous Benchmarking**: Run a fixed set of test positions (e.g., find the best move in 100 tactical puzzles, time to depth on 50 positions) on every commit. While these benchmarks don't directly measure Elo, a significant regression in NPS (nodes per second) or solve rate is a strong signal that something is wrong.

=== Testing Methodology: Advanced Topics

==== SPRT vs. Fixed-Game Matches

SPRT is universally superior to fixed-game-count testing for individual patches because:
- It uses fewer games on average (stops early for both clear wins and clear losses).
- It provides statistical guarantees that fixed-game testing cannot (without extremely careful power analysis).
- It naturally handles sequential correlation (games are independent, but the sequential nature of SPRT means you can stop at any time without invalidating the statistics).

Fixed-game tests are still useful for:
- **Tournament reports**: When you need a precise Elo number with tight confidence intervals (not just a yes/no decision).
- **Scalability testing**: Testing at multiple time controls with fixed game counts to produce an Elo vs. time curve.
- **Gauntlet testing**: Playing against a diverse field of opponents (not just self-play), where the SPRT hypothesis framework is harder to define.

==== Opening Book Bias and Pentanomial SPRT

Traditional SPRT assumes binomial outcomes (win/loss for each game, with draws handled as half-wins). But chess games played from the same opening with colors reversed are correlated: if position `P` is good for White, then engine A as White and engine B as Black is an asymmetric pair that's correlated with engine B as White and engine A as Black.

Pentanomial SPRT models five outcomes per *paired game* (two games from the same opening with colors reversed):

```
(w, w): Both wins for the "Test" engine        → +2
(w, d): Win for Test, draw                      → +1.5
(w, l) or (d, d): Split or both draws           → +1 or +0
(l, d): Loss for Test, draw                     → -0.5
(l, l): Both losses for Test                    → -1
```

This models the intra-pair correlation correctly and can reduce the required number of games by 10-20% compared to binomial SPRT.

==== Time Control Selection

The choice of testing time control is a critical trade-off:

**Ultra-fast (5+0.05s)**: Used by Stockfish and most top engines for primary testing. Games are decided quickly (5-15 seconds per game), allowing tens of thousands of games per day. However, ultra-fast games emphasize tactics and speed over deep strategic understanding, and Elo differences at ultra-fast time controls may not perfectly translate to longer time controls.

**Standard-fast (60+0.6s)**: Used as a secondary filter. After a patch passes at 10+0.1s, it is re-tested at 60+0.6s to verify that the improvement scales. The Elo gain at 60+0.6s is typically 70-90% of the gain at 10+0.1s.

**Tournament (120+1.2s or longer)**: Used only for final release validation. Very few games can be played, so statistical significance is low, but any gross regression at tournament time control would be caught.

The scaling factor—how well fast-time-control Elo predicts long-time-control Elo—is a subject of ongoing research. Empirically, the correlation is strong (r ≈ 0.8-0.9) for improvements that are primarily search or evaluation based, and weaker (r ≈ 0.5-0.7) for improvements that are speed-based (faster move generation, better memory layout).

=== Practical Testing Pipeline

A complete testing pipeline for a developing chess engine:

```
1. Compile change (with profiling flags optionally)
   ↓
2. Run "fast SPRT" (5+0.05s, elo0=0, elo1=6, 20000 game max)
   → FAIL: Discard or rework
   → PASS: Continue to step 3
   ↓
3. Run "standard SPRT" (10+0.1s or 60+0.6s, elo0=0, elo1=3, 50000 game max)
   → FAIL: Discard
   → PASS: Continue to step 4
   ↓
4. Run "non-regression SPRT" (60+0.6s, elo0=-1.5, elo1=0.5, 60000 game max)
   → FAIL (regression detected): Discard, possibly bisect
   → PASS: Continue to step 5
   ↓
5. Merge to development branch
   ↓
6. Periodic "regression sweep": Test dev branch vs. master branch
   (120+1.2s, elo0=-3, elo1=0, 100000 game max)
   → FAIL: Bisect to find offending commit(s)
   → PASS: Dev branch becomes new master
```

The exact time controls and thresholds depend on your computational resources. A developer with a single 16-core machine can run roughly 500-1000 games per day at 10+0.1s, making the fast SPRT practical (2-4 weeks for a single test) but scaling tests impractical. Distributed testing (Fishtest-style) is what makes modern engine development possible for large teams.

=== Automated Bisection for Performance Changes

When you notice that the engine's NPS or search depth has changed unexpectedly, automated bisection can find the responsible commit:

```bash
#!/bin/bash
# bisect_perf.sh - Find the commit that changed NPS

BASELINE_NPS=25000000  # nodes per second on a reference position
TOLERANCE=500000       # acceptable NPS drift

function measure_nps() {
    make clean && make -j$(nproc) 2>/dev/null
    # Run engine, send "go depth 15" to a specific position, extract NPS
    echo "position startpos moves e2e4 e7e5
go depth 15" | ./engine 2>&1 | grep "nodes per second" | awk '{print $NF}'
}

git bisect start
git bisect bad HEAD
git bisect good <commit_with_known_nps>

git bisect run bash -c '
    NPS=$(measure_nps)
    DIFF=$((NPS - BASELINE_NPS))
    # Return 0 if NPS is good (within tolerance), 1 if bad
    [[ $DIFF -lt $TOLERANCE ]] && [[ $DIFF -gt -$TOLERANCE ]]
'

git bisect log
```

This is much faster than Elo bisection because NPS can be measured in seconds (not thousands of games). However, NPS changes don't always correlate with Elo changes—an NPS improvement from a bug fix that incorrectly skips moves might increase NPS but decrease Elo.

=== Testing at Scale: Resources and Costs

Let us calculate the computational resources needed for serious engine testing:

A developer working alone with:
- 16 CPU cores available 24/7
- 10+0.1s time control (~15 seconds per game)
- 8 concurrent games (2 cores per game, engines alternate on cores)

Games per day: `(24 * 3600 / 15) * 8 = 46,080` games per day (theoretical maximum; overhead reduces this to ~25,000-30,000).

At this rate:
- Fast SPRT (~8,000 games avg): 6-8 hours
- Standard SPRT (~20,000 games avg): 16-24 hours  
- Non-regression SPRT (~35,000 games avg): 30-36 hours

With distributed computing (Fishtest):
- Stockfish processes 100,000-200,000 games per day
- A single patch can be tested in 30-60 minutes
- ~100 patches tested simultaneously

The lesson: individual developers must be strategic about what they test. Focus on changes that are likely to yield meaningful Elo gains (2+ Elo), use fast time controls, and leverage any available distributed resources (cloud instances during off-peak hours, team members' machines overnight).

=== Summary

Testing is the engine developer's primary feedback loop. The key concepts:

- **SPRT**: The sequential test that stops as soon as evidence is sufficient, minimizing wasted games.
- **Cutechess-cli**: The standard tool for running engine matches and SPRT tests.
- **Opening books**: Balanced, diverse positions are essential for statistical power and avoiding bias.
- **Elo calculation**: The logistic model estimates strength differences with confidence intervals.
- **Draw rate**: The primary determinant of how many games are needed; high draw rates demand more games.
- **Fishtest**: Stockfish's distributed framework, the model for large-scale engine testing.
- **Regression protection**: Non-regression bounds and bisection prevent accidental strength losses.
- **Time control scaling**: Fast tests are practical but imperfect; scaling validation matters.

Without rigorous testing, engine development is guesswork. With it, you can confidently improve your engine one verified step at a time.
