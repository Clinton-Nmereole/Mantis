# Blunder Trace Investigation

Date: 2026-05-30

Baseline practice binary: `./mantis_root_verify`

PGN source: `games/Games.pgn`

## Accepted: First-Collapse Harness Mode

Candidate tool: `./blunder_trace.py`

Change: add `--mode first-collapse` to select the earliest Mantis move in each
game where the position moves from playable to clearly worse.

Default first-collapse filter:

```text
previous Mantis-perspective eval >= -400 cp
post-move Mantis-perspective eval <= -600 cp
drop >= 150 cp
```

Command used:

```sh
python3 blunder_trace.py \
  --pgn games/Games.pgn \
  --mode first-collapse \
  --limit 12 \
  --binary ./mantis_root_verify \
  --depths 8 10 12 \
  --timeout 120 \
  --report games/first_collapse_root_verify.md \
  --csv games/first_collapse_root_verify.csv
```

Result:

```text
games parsed:                  10
Mantis moves with evals:       521
Mantis eval drops:             368
threshold candidates:          214
first-collapse candidates:     7
```

## First Collapses

| Round | Ply | Side | Played | Mantis Eval | Classification |
| ---: | ---: | --- | --- | --- | --- |
| 1 | 37 | white | `d7f6` `Nxf6+` | `-2.22 -> -6.22` | still preferred at fixed depth |
| 2 | 36 | black | `b6b4` `Qb4` | `-2.85 -> -6.47` | fixed-depth avoids PGN move |
| 3 | 39 | white | `d3f1` `Bf1` | `-2.81 -> -6.46` | fixed-depth avoids PGN move |
| 4 | 54 | black | `e7f7` `Kf7` | `-2.24 -> -6.84` | returns to PGN move by max depth |
| 5 | 73 | white | `d1e1` `Ke1` | `-2.69 -> -6.06` | fixed-depth avoids PGN move |
| 8 | 48 | black | `d7e6` `Bxe6` | `-3.86 -> -9.56` | fixed-depth avoids PGN move |
| 10 | 82 | black | `c6e5` `Nxe5` | `-3.01 -> -7.24` | still preferred at fixed depth |

Three collapses remain attractive to the engine at fixed depth 12. Those are
likely evaluation/horizon/endgame-search failures. Four collapses are avoided
by cold fixed-depth search, which suggests that actual timed play may be
affected by warm TT/history state, time allocation, or a different depth/stop
profile than the cold harness reproduces.

## Next

Add a stateful replay mode that walks through each PGN in game order and
queries Mantis at the first-collapse positions without resetting the process.
That will tell us whether the bad practice-game move reappears only with warm
TT/history state. If it does, inspect TT/history/aspiration at those positions;
if it does not, focus on timed-budget reproduction.

## Accepted: Stateful Replay Mode

Change: add `--stateful-replay` to `blunder_trace.py`. The mode launches one
persistent UCI process, sends `ucinewgame` at each PGN game boundary, replays
the game from `startpos`, and searches earlier Mantis-to-move positions at a
warmup depth before querying the first-collapse position.

Important engine detail: `ucinewgame` clears the TT, and `search_position`
clears killer/history/counter/continuation state per search. So this mode is
primarily testing warm in-game TT/process effects, not persistent history.

Command used:

```sh
python3 blunder_trace.py \
  --pgn games/Games.pgn \
  --mode first-collapse \
  --limit 12 \
  --binary ./mantis_root_verify \
  --depths 8 10 12 \
  --stateful-replay \
  --warm-depth 8 \
  --timeout 120 \
  --report games/first_collapse_stateful_root_verify.md \
  --csv games/first_collapse_stateful_root_verify.csv
```

Result:

| Round | PGN Move | Cold d12 | Stateful d12 | Finding |
| ---: | --- | --- | --- | --- |
| 1 | `d7f6` | `d7f6` | `d7f6` | Still preferred; likely eval/horizon/endgame-search. |
| 2 | `b6b4` | `e7g5` | `b6b4` | Warm fixed-depth reproduces PGN at d12. |
| 3 | `d3f1` | `g5f6` | `h2h4` | Warm state changes the preferred move, but not to PGN. |
| 4 | `e7f7` | `e7f7` | `e7f7` | Still preferred by max depth. |
| 5 | `d1e1` | `e5f3` | `e5g4` | Not reproduced by fixed-depth. |
| 8 | `d7e6` | `f5f4` | `d7e6` | Warm fixed-depth reproduces PGN at d8 and d12. |
| 10 | `c6e5` | `c6e5` | `c6e5` | Still preferred; likely eval/horizon/endgame-search. |

Warm state matters for fixed-depth searches. Rounds 2 and 8 are not reproduced
by cold fixed-depth, but are reproduced by isolated stateful replay at depth
12. This points to TT/search-state interaction, not merely static evaluation.

## Next

Run a timed-budget replay of the same first-collapse positions. If timed replay
reproduces moves that fixed-depth avoids, the issue is time/depth instability.
If timed replay still avoids them, inspect the original GUI/game conditions or
focus on the fixed-depth failures with root move traces and endgame evaluation.

## Accepted: Timed Replay Matrix

Change: add movetime search specs to `blunder_trace.py` through
`--movetimes-ms`, plus `--no-depths` for timed-only reports. Timed specs work
for both cold FEN searches and stateful replay.

Command used:

```sh
python3 blunder_trace.py \
  --pgn games/Games.pgn \
  --mode first-collapse \
  --limit 12 \
  --binary ./mantis_root_verify \
  --no-depths \
  --movetimes-ms 250 750 1500 3000 \
  --stateful-replay \
  --warm-depth 8 \
  --timeout 60 \
  --report games/first_collapse_timed_root_verify.md \
  --csv games/first_collapse_timed_root_verify.csv
```

Result:

| Round | PGN Move | Cold Timed | Stateful Timed | Finding |
| ---: | --- | --- | --- | --- |
| 1 | `d7f6` | PGN at all budgets | PGN at all budgets | Persistent eval/horizon failure. |
| 2 | `b6b4` | Avoids PGN | Avoids PGN; prefers `h8h5` from 750ms onward | Fixed-depth warm issue, not reproduced by isolated movetime. |
| 3 | `d3f1` | Avoids PGN | Avoids PGN | Not reproduced; inspect deeper root/eval if needed. |
| 4 | `e7f7` | PGN at 750/1500ms | PGN only at 250ms | Unstable timed choice. |
| 5 | `d1e1` | Avoids PGN | Avoids PGN | Not reproduced by timed replay. |
| 8 | `d7e6` | Avoids PGN | Avoids PGN | Fixed-depth warm issue, not reproduced by isolated movetime. |
| 10 | `c6e5` | PGN at all budgets | PGN at all budgets | Persistent eval/horizon/endgame-search failure. |

This corrected report isolates each stateful target budget in a fresh warmed
engine. An earlier draft ran target budgets sequentially in one process, which
allowed the 250ms target probe itself to warm later 750/1500/3000ms probes.
That artifact made round 2 appear to reproduce `b6b4` under movetime. The
isolated replay does not support that conclusion.

The corrected grouping is:

1. Persistent failures where Mantis likes the PGN move across cold, stateful,
   fixed-depth, and timed probes: rounds 1 and 10.
2. Fixed-depth warm-state failures where cold search avoids the PGN move but
   isolated stateful depth-12 can bring it back: rounds 2 and 8.
3. Timed instability where movetime choices vary around the collapse but do
   not consistently reproduce the PGN move: round 4.

## Next

Focus on the fixed-depth warm-state group first. Add a root-move trace mode for
stateful probes that records normal search and MultiPV root rankings. The first
target should remain round 2 because cold d12 chooses `e7g5`, while stateful
d12 chooses the PGN move `b6b4`.

## Accepted: Timed Root Trace Tool

Tool: `timed_root_trace.py`

Change: add a focused diagnostic that replays one PGN target with a fresh
warmed engine per movetime budget. For each budget it runs:

1. a normal MultiPV=1 movetime search,
2. a separate diagnostic MultiPV search from the same warmed game path.

Command used:

```sh
python3 timed_root_trace.py \
  --movetimes-ms 250 750 1500 3000 \
  --multipv 8 \
  --timeout 120 \
  --report games/timed_root_trace_round2_ply36.md \
  --csv games/timed_root_trace_round2_ply36.csv
```

Round 2 result:

```text
normal 250ms:  e7g5
normal 750ms:  h8h5
normal 1500ms: h8h5
normal 3000ms: h8h5
```

MultiPV diagnostics show `b6b4` is nearby but not top under movetime:

```text
250ms:  rank 3, score -7.22
750ms:  rank 4, score -5.67
1500ms: rank 4, score -4.06
3000ms: rank 6, score -6.15
```

Conclusion: round 2 `b6b4` is not a movetime root-choice bug under isolated
replay. It is a stateful fixed-depth d12 issue. The immediate next diagnostic
should be a depth-12 stateful root trace, not another movetime trace.

## Accepted: Stateful Depth Root Trace

Tool: `timed_root_trace.py`

Change: generalize the root trace tool so it supports fixed-depth probes through
`--depths` and repeated targets through `--target ROUND:PLY`. Each normal search
and MultiPV diagnostic still uses a fresh engine warmed along the same PGN path.

Command used:

```sh
python3 timed_root_trace.py \
  --target 2:36 \
  --target 8:48 \
  --depths 12 \
  --multipv 8 \
  --timeout 180 \
  --report games/stateful_depth_root_trace_root_verify.md \
  --csv games/stateful_depth_root_trace_root_verify.csv
```

Result:

| Round | PGN Move | Normal warm d12 | MultiPV warm d12 | Finding |
| ---: | --- | --- | --- | --- |
| 2 | `b6b4` | `b6b4`, score -5.94 | `e7g5` rank 1 (-5.18), `b6b4` rank 2 (-5.55) | Normal root chooses the worse move; MultiPV avoids it. |
| 8 | `d7e6` | `d7e6`, score -10.14 | `a7a5` rank 1 (-6.94), `d7e6` rank 4 (-9.73) | Normal root chooses the worse move; MultiPV avoids it. |

Conclusion: these two warm-state failures are not simple NNUE/eval preference
bugs. Under the same warmed PGN path, the normal root search selects the PGN
collapse while a separate warmed MultiPV search ranks better root moves above
it. MultiPV is not behavior-identical to normal search, but the divergence is
now sharply localized to normal root search state: TT/root ordering,
aspiration/fail-low recovery, or PV/non-PV score handling.

## Next

Add a normal-root debug trace for warmed depth-12 searches that records each
completed root move score, the final root ordering, TT move at the root, and
any root fail-low/fail-high verification. Run it on rounds 2 and 8 and compare
the normal root path against the MultiPV ranking above. Also confirm whether
reported root scores are side-to-move or white-perspective before using score
margins as evidence.

## Accepted: Normal Root Debug Trace

Change: add a gated UCI option, `RootDebugTrace`, and teach
`timed_root_trace.py --root-debug` to enable it for normal warmed searches. The
option is off by default and only prints `info string rootdebug ...` lines when
explicitly enabled.

Diagnostic binary: `./mantis_root_debug`

Command used:

```sh
python3 timed_root_trace.py \
  --binary ./mantis_root_debug \
  --target 2:36 \
  --target 8:48 \
  --depths 12 \
  --multipv 8 \
  --root-debug \
  --timeout 240 \
  --report games/root_debug_trace_root_debug.md \
  --csv games/root_debug_trace_root_debug.csv
```

Result:

| Round | Root seed | Actual root TT | Initial d12 | Fail-low research | Final |
| ---: | --- | --- | --- | --- | --- |
| 2 | `h8h5` | `e7g5` | `h8h5` fails low at -4.24 | `e7g5` raises to -6.24, then `b6b4` raises to -6.06 | `b6b4` |
| 8 | `a7a6` | `d7e6` | `a7a6` fails low at -4.22 | `d7e6` raises to -10.26; later `a7a5` only returns the same bound, -10.26 | `d7e6` |

Conclusion: the bad moves are selected in root fail-low recovery, not in the
initial aspiration pass. Round 8 is especially suspicious: the MultiPV trace
ranks `a7a5` first, but normal fail-low research searches it after `d7e6` and
only gets an equal alpha-bound score, so strict `>` tie handling leaves
`d7e6` as best. Round 2 also disagrees with MultiPV after fail-low recovery,
where `b6b4` raises alpha above the actual root TT move `e7g5`.

## Next

Fix root fail-low recovery conservatively. When a final-depth root aspiration
fails low, verify the recovered best move against a clean full-window root
pass, or at minimum full-window verify the recovered best plus the actual root
TT move and later candidates that only returned the alpha bound. The acceptance
test should be that warmed d12 rounds 2 and 8 no longer choose `b6b4`/`d7e6`,
while the 44-position stats harness remains stable.

## Accepted: Scoped Root Fail-Low Verification

Candidate: `./mantis_root_fail_verify`

Change: when the final fixed-depth root search fails low, restore the clean
pre-depth TT snapshot and run a full-window verification pass over the previous
PV root seed, the recovered best move, the actual root TT move, and existing
forcing/high-signal alternatives. This is narrower than verifying every legal
root move.

Command used:

```sh
python3 timed_root_trace.py \
  --binary ./mantis_root_fail_verify \
  --target 2:36 \
  --target 8:48 \
  --depths 12 \
  --multipv 8 \
  --root-debug \
  --timeout 240 \
  --report games/root_fail_verify_trace.md \
  --csv games/root_fail_verify_trace.csv
```

Result:

| Round | Before | After | Verification result |
| ---: | --- | --- | --- |
| 2 | `b6b4` | `h8h5` | Clean verify chooses the previous-PV/root seed and rejects the fail-low recovered `b6b4`. |
| 8 | `d7e6` | `a7a5` | Clean verify promotes the later high-signal candidate and rejects actual root TT move `d7e6`. |

Benchmark comparison:

```sh
python3 compare_candidates.py \
  --baseline ./mantis_root_verify \
  --candidate ./mantis_root_fail_verify \
  --depths 8 9 \
  --timeout 120 \
  --csv games/root_fail_verify_compare_d8_d9.csv
```

Summary:

| Depth | Bestmove changes | Max score delta | Nodes | Time |
| ---: | ---: | ---: | ---: | ---: |
| 8 | 0/44 | 0 cp | +0.00% | -7.22% |
| 9 | 4/44 | 166 cp | +45.54% | +33.40% |

Depth 9 changed moves all had positive candidate score deltas in the benchmark
sample. The cost is real but much smaller than the all-legal-root proof pass,
which caused 8/44 bestmove changes and roughly +240% time at depth 9.

## Next

Measure this candidate in timed mode and practice games. Because the current
verification is scoped to final fixed-depth searches, it may not affect normal
3+2 play much yet. If practice strength does not move, the next step is to make
the same verification available to time-managed searches only when the engine
is about to stop after a completed depth, rather than on every depth.

## Accepted: Timed Stop-Boundary Root Verification

Candidate: `./mantis_timed_verify`

The 25-game `MantisVsViridthas0601.pgn` match confirmed that the fixed-depth
root fail-low fix was not enough for normal 3+2 play. Mantis scored 0.5/25, and
the first-collapse report found 13 positions where Mantis crossed from playable
or bad-but-defensible into clearly lost.

Change: prepare the clean root TT snapshot for likely final timed depths, then
run the same scoped full-window root verification only when a completed clock
search is about to stop instead of starting the next depth. Exact `go movetime`
searches are left alone.

PGN first-collapse extraction:

```sh
python3 blunder_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --mode first-collapse \
  --threshold-cp 150 \
  --limit 13 \
  --binary ./mantis_root_fail_verify \
  --depths 8 10 12 \
  --movetimes-ms 500 1500 \
  --timeout 120 \
  --report games/mantis_vs_viridithas_0601_first_collapse_search.md \
  --csv games/mantis_vs_viridithas_0601_first_collapse_search.csv
```

Clock safety checks against `./mantis_root_fail_verify`:

| Suite | Bestmove changes | Avg depth | Nodes | Time | Max score delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| 44-position 3+2 smoke, first 16 | 0/16 | 13.62 -> 13.62 | +2.15% | +2.34% | 14 cp |
| PGN first-collapse FENs | 0/13 | 15.46 -> 15.46 | +2.09% | +2.85% | 19 cp |

Fixed-depth parity against `./mantis_root_fail_verify` stayed exact:

| Depth | Bestmove changes | Nodes | Score delta |
| ---: | ---: | ---: | ---: |
| 8 | 0/44 | +0.00% | 0 cp |
| 9 | 0/44 | +0.00% | 0 cp |

Conclusion: this is a safe consistency improvement for clock play, but not the
main cause of the 25-game losses. Several PGN first-collapse positions are
still preferred by cold searches, while several others are avoided cold but were
played in the actual games.

## Next

Build a stateful clock replay for the PGN first-collapse positions. The next
question is why some positions are avoided by cold clock search but selected in
the live game, which points toward TT/history/search-state contamination rather
than only raw tactical depth.

## Accepted: Stateful Clock Replay Harness

Tooling change: `blunder_trace.py` now accepts UCI clock budgets through
`--clock WTIME BTIME WINC BINC` and can run those target searches in both cold
and stateful replay modes. Stateful replay warms all previous Mantis-to-move
positions from the same game in one engine process before searching the target.

Command:

```sh
python3 blunder_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --mode first-collapse \
  --threshold-cp 150 \
  --limit 13 \
  --binary ./mantis_timed_verify \
  --no-depths \
  --clock 180000 180000 2000 2000 \
  --stateful-replay \
  --warm-depth 8 \
  --timeout 120 \
  --report games/mantis_vs_viridithas_0601_stateful_clock.md \
  --csv games/mantis_vs_viridithas_0601_stateful_clock.csv
```

Result:

| Category | Count | Positions |
| --- | ---: | --- |
| Stateful bestmove changed from cold | 7/13 | 3, 5, 8, 9, 11, 12, 13 |
| Cold avoided PGN, stateful reproduced PGN blunder | 3/13 | 5, 8, 13 |
| Cold and stateful both preferred PGN blunder | 3/13 | 2, 6, 10 |
| Cold preferred PGN, stateful avoided PGN | 1/13 | 11 |

The three stateful-reproduced PGN blunders are especially important:

| # | Round | Played | Cold clock | Stateful clock |
| ---: | ---: | --- | --- | --- |
| 5 | 11 | `d3e4` | `d3c2` | `d3e4` |
| 8 | 17 | `f5d3` | `h2h3` | `f5d3` |
| 13 | 25 | `f5c2` | `g3d6` | `f5c2` |

Search history, capture history, counter moves, continuation history, and
killers are cleared at the start of each root search. That made TT state the
prime suspect for these cold-vs-stateful flips, not long-lived history tables.

## Accepted: Stateful TT and Position-State Isolation

Tooling change: `blunder_trace.py` can now:

- clear TT after warmup but before the target search with
  `--clear-hash-before-target`;
- set the stateful target from its FEN with `--stateful-target-fen`;
- select exact first-collapse candidates with `--candidate-indexes`.

The first isolation pass showed a split:

| # | Played | Cold clock | Stateful clock | Stateful clock after TT clear |
| ---: | --- | --- | --- | --- |
| 5 | `d3e4` | `d3c2` | `d3e4` | `d3e4` |
| 8 | `f5d3` | `h2h3` | `f5d3` | `f5d3` |
| 13 | `f5c2` | `g3d6` | `f5c2` | `g3d6` |

Candidate 13 was TT-sensitive, but 5 and 8 still reproduced the PGN blunder
after clearing TT. That pointed away from pure TT contamination.

The next check compared `position startpos moves ...` with the equivalent FEN
target. Before the fix, Mantis printed the correct piece placement but always
reported `0 1` for halfmove/fullmove after replaying UCI moves. That mattered
because root ordering uses `b.fullmove_number` to taper the opening pawn/knight
bias after move 12. In real GUI games, Mantis was effectively treating late
middlegame positions as move 1 for that root-ordering term.

Engine fix: `board.apply_move_to_board()` now updates:

- `halfmove_clock`: reset on pawn moves/captures, otherwise increment;
- `fullmove_number`: increment after Black moves.

Validation:

```text
candidate 5: startpos-moves FEN now matches python-chess FEN
candidate 8: startpos-moves FEN now matches python-chess FEN
candidate 13: startpos-moves FEN now matches python-chess FEN
44-position depth-8 comparison vs ./mantis_timed_verify: 0 bestmove changes,
0 node changes, 0 score changes
```

Fixed-depth target replay with `./mantis_position_state`:

```sh
python3 blunder_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --mode first-collapse \
  --threshold-cp 150 \
  --candidate-indexes 5 8 13 \
  --limit 3 \
  --binary ./mantis_position_state \
  --depths 14 \
  --stateful-replay \
  --clear-hash-before-target \
  --skip-cold \
  --warm-depth 8 \
  --timeout 180 \
  --report games/mantis_vs_viridithas_0601_position_state_targets_d14.md \
  --csv games/mantis_vs_viridithas_0601_position_state_targets_d14.csv
```

Result:

| # | Played | Fixed replay bestmove | Finding |
| ---: | --- | --- | --- |
| 5 | `d3e4` | `d3c2` | Avoids PGN blunder |
| 8 | `f5d3` | `h2h3` | Avoids PGN blunder |
| 13 | `f5c2` | `g3d6` | Avoids PGN blunder |

Clock replay with warm TT still reproduced candidates 5 and 8, but clearing TT
before the target made all three avoid the PGN move:

| # | Played | Warm clock | Warm clock after TT clear |
| ---: | --- | --- | --- |
| 5 | `d3e4` | `d3e4` | `d3c2` |
| 8 | `f5d3` | `f5d3` | `h2h3` |
| 13 | `f5c2` | `g3d6` | `g3d6` |

Conclusion: the UCI replay counter bug was real and fixed. The remaining
practice-game issue is warm TT influence under clock play, especially at
candidates 5 and 8.

## Accepted: Clock-Managed TT Isolation

First attempt: clear the warm TT only for a likely-final timed root depth. That
fixed candidate 5 but candidate 8 still reproduced the PGN move. Candidate 8
needed the whole timed target search to begin from a clean TT, not only the
final root depth.

Engine change: for normal UCI clock searches (`go wtime/btime/...`), Mantis now
clears TT once at the start of the search. Fixed-depth analysis, `go movetime`,
and infinite searches keep the previous behavior. This preserves TT use inside
the current move search, but prevents earlier game positions from steering a
new managed-clock move.

Target replay with `./mantis_clock_isolated`:

```sh
python3 blunder_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --mode first-collapse \
  --threshold-cp 150 \
  --candidate-indexes 5 8 13 \
  --limit 3 \
  --binary ./mantis_clock_isolated \
  --no-depths \
  --clock 180000 180000 2000 2000 \
  --stateful-replay \
  --skip-cold \
  --warm-depth 8 \
  --timeout 120 \
  --report games/mantis_vs_viridithas_0601_clock_isolated_targets.md \
  --csv games/mantis_vs_viridithas_0601_clock_isolated_targets.csv
```

Result:

| # | Played | Warm clock after engine change | Finding |
| ---: | --- | --- | --- |
| 5 | `d3e4` | `d3c2` | Avoids PGN blunder |
| 8 | `f5d3` | `h2h3` | Avoids PGN blunder |
| 13 | `f5c2` | `g3d6` | Avoids PGN blunder |

Full 13-position stateful clock replay:

| Category | Count | Positions |
| --- | ---: | --- |
| Avoids PGN blunder under searched limit | 9/13 | 1, 3, 4, 5, 7, 8, 9, 12, 13 |
| Still prefers PGN blunder | 4/13 | 2, 6, 10, 11 |

Validation:

```text
python3 correctness_test.py --binary ./mantis_clock_isolated
python3 tactical_regression.py --binary ./mantis_clock_isolated
python3 -m py_compile blunder_trace.py timed_root_trace.py stats_benchmark.py compare_candidates.py
git diff --check
```

All passed.

## Next

Validate the remaining first-collapse positions with an external oracle before
treating them as engine bugs. Start with candidates 2 and 6 because they are
middlegame tactical collapses that remain preferred even from clean timed
searches.

## Accepted: External Oracle Validation

Tooling change: `blunder_trace.py` now accepts `--oracle-binary`,
`--oracle-depth`, `--oracle-multipv`, and `--oracle-timeout`. The report and
CSV include the oracle best move, the PGN move's oracle rank, and the estimated
root-move loss. This makes the PGN eval comments useful as a candidate source
without assuming each eval drop is a true move-choice blunder.

Command:

```sh
python3 blunder_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --mode first-collapse \
  --threshold-cp 150 \
  --limit 13 \
  --binary ./mantis_clock_isolated \
  --no-depths \
  --clock 180000 180000 2000 2000 \
  --stateful-replay \
  --skip-cold \
  --warm-depth 8 \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 18 \
  --oracle-multipv 6 \
  --oracle-timeout 120 \
  --timeout 120 \
  --report games/mantis_vs_viridithas_0601_clock_oracle_combined.md \
  --csv games/mantis_vs_viridithas_0601_clock_oracle_combined.csv
```

Result:

| # | Round | Played | Current Mantis | Oracle best | Finding |
| ---: | ---: | --- | --- | --- | --- |
| 2 | 5 | `d2c3` | `d2c3` | `d2c3` | False positive; oracle agrees with the played move. |
| 6 | 12 | `b6b4` | `b6b4` | `b6b4` | False positive; oracle agrees with the played move. |
| 10 | 21 | `d1f1` | `d1f1` | `d1f1` | False positive; oracle agrees with the played move. |
| 11 | 22 | `d4c6` | `d4c6` | `d4c6` | False positive; oracle agrees with the played move. |
| 4 | 10 | `e5f7` | `g8h8` | `h7g6` | Main remaining mismatch, about 53 cp behind oracle. |
| 12 | 23 | `d7f7` | `d7e7` | `g1f1` | Smaller mismatch, about 21 cp behind oracle. |
| 1 | 4 | `f8c5` | `c8c2` | `f8c5` | Minor mismatch, about 36 cp behind oracle. |

Conclusion: the four "still preferred" positions after TT isolation are not
currently good engine-bug targets. The latest binary already avoids most PGN
first-collapse moves under reproduced clock conditions, and several remaining
PGN eval drops are oracle-approved moves. The next engine target should be the
largest current Mantis-vs-oracle mismatch, candidate 4:

```text
FEN: 1r3rk1/1p1b3q/3NpP1p/p2pn1p1/8/6P1/PP1QBR1P/2R3K1 b - - 0 25
Mantis: g8h8
Oracle: h7g6
```

## Next

Build a focused root trace for candidate 4 with current clock settings and
oracle MultiPV side by side. The question is whether `h7g6` is missed because
of root ordering/aspiration behavior, pruning at non-PV nodes, or Mantis'
static/search score calibration in already-lost middlegame positions.

## Accepted: Candidate 4 Clock Root Trace

Tooling change: `timed_root_trace.py` now supports UCI clock searches through
`--clock WTIME BTIME WINC BINC` and can include an external oracle MultiPV
table through `--oracle-binary`. The engine-side `RootDebugTrace` option now
also prints root-debug lines for managed-clock searches; the option is still
off by default, so normal play is unchanged.

Diagnostic binary: `./mantis_candidate4_trace`

Clock command:

```sh
python3 timed_root_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --binary ./mantis_candidate4_trace \
  --target 10:50 \
  --clock 180000 180000 2000 2000 \
  --warm-depth 8 \
  --multipv 8 \
  --root-debug \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 18 \
  --oracle-multipv 6 \
  --timeout 240 \
  --report games/candidate4_clock_root_trace.md \
  --csv games/candidate4_clock_root_trace.csv
```

Clock result:

| Search | Bestmove | Score | Depth | Finding |
| --- | --- | ---: | ---: | --- |
| Normal clock | `g8h8` | -5.87 | 14 | Still misses oracle best. |
| Stockfish d18 | `h7g6` | -3.60 | 18 | `g8h8` is oracle rank 3, about 53 cp worse. |

At clock depth 14, the normal search fails low and starts clean-root
verification, but the verification pass runs out of time after checking only
`g8h8`:

```text
clean_root_verify completed=false best=g8h8
```

Fixed-depth command:

```sh
python3 timed_root_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --binary ./mantis_candidate4_trace \
  --target 10:50 \
  --depths 14 \
  --warm-depth 8 \
  --multipv 8 \
  --root-debug \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 18 \
  --oracle-multipv 6 \
  --timeout 300 \
  --report games/candidate4_depth14_root_trace.md \
  --csv games/candidate4_depth14_root_trace.csv
```

Fixed-depth result:

| Search | Bestmove | Score | Depth | Finding |
| --- | --- | ---: | ---: | --- |
| Normal d14 | `g8h8` | -5.90 | 14 | Still misses `h7g6`. |
| Mantis MultiPV d14 | `h7g6` | -5.13 | 14 | Mantis can find the better move when forced through MultiPV. |
| Mantis MultiPV d14 rank 2 | `g8h8` | -6.94 | 14 | Mantis itself scores `g8h8` much worse in MultiPV. |

The fixed-depth clean-root verifier completed, but skipped `h7g6`:

```text
move=h7g6 reason=quiet_nonpositive_history
```

Conclusion: candidate 4 is not primarily a static-eval or NNUE blindness case.
Mantis can find `h7g6` in MultiPV at the same depth. The normal root path loses
it because fail-low recovery returns bound-like scores for many quiet moves,
then the scoped clean verifier filters out quiet moves with nonpositive
history. In clock mode there is a second issue: the verifier starts too late
and can spend the remaining time on `g8h8` alone.

## Next

Make root fail-low verification include a tiny set of ambiguous quiet moves
from the failed/recovered root pass, not only quiets with positive history.
Candidate 4's acceptance test is that a fixed-depth d14 trace promotes
`h7g6`, and the clock trace either promotes `h7g6` or demonstrably verifies it
before stopping. Keep the change narrow and re-run the 44-position benchmark,
the first-collapse replay, tactical regression, and correctness tests.

## Ambiguous Quiet Verification Attempt

Status: rejected as an engine change.

A narrow prototype collected up to four deep ambiguous queen quiets from
fail-low root passes and made the clean verifier consider them explicitly. The
shallow gate was later restricted to depth 12+ after the first version caused
depth-9 opening drift, including `a2a3` flips in benchmark positions.

After narrowing, the depth 8/9 comparison against `./mantis_clock_isolated`
returned to zero move/score/node changes across all 44 positions, but the d14
candidate-4 trace still did not produce a stable fix:

| Trace | Result |
| --- | --- |
| Clean verifier with `h7g6` promoted early | `h7g6` searched, but scored below `g8h8`. |
| Mantis MultiPV d14 | Still ranks `h7g6` first. |
| `trace-root-child 14 h7g6` | Late null-window baseline pins `h7g6` at alpha even with TT, LMR, futility, LMP, NMP, RFP, razor, and probcut individually disabled. |

Conclusion: this is not safely fixed by adding more quiet exceptions to the
clean verifier. The root score depends too much on root/PVS/TT/history context.
The next productive task is a root verification parity pass: score a small set
of candidate root moves from comparable search state, then decide whether the
normal root, clean verifier, or MultiPV path is producing the unstable score.

One correctness fix from the experiment was kept: if a timed clean-root
verification starts but does not complete, the depth is now treated as
incomplete, matching fixed-depth verification behavior.

## Root Parity Trace

Added `trace-root-parity` as a focused diagnostic. It warms to `depth - 1`,
sorts root moves normally, then scores each requested root candidate from the
same TT snapshot and cloned history. This avoids the usual root-order
contamination while still using the same NNUE/search stack.

Example:

```sh
./mantis_root_parity trace-root-parity 14 g8h8 h7g6 fen "1r3rk1/1p1b3q/3NpP1p/p2pn1p1/8/6P1/PP1QBR1P/2R3K1 b - - 0 25"
```

Candidate-4 result:

| Move | Comparable full score | Comparable PVS score | Finding |
| --- | ---: | ---: | --- |
| `g8h8` | -698 | n/a | First root move in normal ordering. |
| `e5f7` | -529 | -697 | Full-window score raises alpha, PVS/bound score hides it. |
| `h7g6` | -510 | -529 | Best comparable full score; PVS equality misses the raise. |

This proves the normal root can lose candidates because bound-style root
searches return alpha even when a comparable full-window search would raise it.

A root equality re-search prototype was tested and rejected. It gave true
full-window searches to deep equality-bound root probes, but the focused d14
trace still chose `g8h8`, took roughly 69 seconds for the normal search, and
shifted MultiPV back toward `g8h8`. The likely problem is not a single root
equality rule; it is that root, clean-verifier, and MultiPV paths update and
consume TT/history differently enough to change the searched position tree.

Next: make a parity scorer for the exact normal-root, clean-verifier, and
MultiPV candidate sets so all three paths can be compared from identical
snapshots before attempting another engine behavior change.

## Root Pipeline Trace

Added `trace-root-pipeline` as the next diagnostic. It warms to `depth - 1`,
reconstructs the normal root aspiration pass, replays the clean verifier from
the saved root snapshot, then runs MultiPV-style excluded root passes. For each
requested move it prints normal root score, fail-low/research score, verifier
inclusion/score, MultiPV score, and isolated full/PVS parity score.

Example:

```sh
./mantis_root_pipeline trace-root-pipeline 14 g8h8 h7g6 e5f7 fen "1r3rk1/1p1b3q/3NpP1p/p2pn1p1/8/6P1/PP1QBR1P/2R3K1 b - - 0 25"
```

Candidate-4 result:

| Move | Normal fail-low score | Verifier result | Isolated full/PVS | Finding |
| --- | ---: | --- | --- | --- |
| `g8h8` | -643 | -698, `root_seed` | -698 / -665 | Normal root stays on the seed, but clean full score is worse. |
| `e5f7` | -643 | -907, `positive_history_quiet` | -529 / -666 | Isolated PVS misses a raise, but verifier context scores it poorly. |
| `h7g6` | -643 | -550, `positive_history_quiet` | -510 / -666 | Best verifier result and another isolated PVS miss. |

New finding: the verifier marked `h7g6` and `e5f7` as
`positive_history_quiet` even though their base root histories were negative in
the printed snapshot. That means the clean verifier's candidate set is not
snapshot-stable; earlier full-window verifier searches can mutate history and
make later quiet moves eligible. This happened to rescue `h7g6` here, but it is
not a reliable candidate-selection rule.

Next: make clean root verification choose its candidate set from a precomputed
root snapshot, then add an explicit, tiny suspect-quiet list from the normal
fail-low pass so moves like `h7g6` are considered deliberately rather than by
verifier-history side effect.

## Stable Snapshot Root Verification

Implemented the behavior fix for the candidate-4 failure mode:

- Clean root verification now precomputes candidate inclusion from the clean
  root history snapshot, so verifier searches cannot mutate history and make
  later quiets eligible by accident.
- At depth 12+, fail-low clean verification scores a bounded suspect-quiet
  pool from the clean root snapshot: first 20 root-order quiets that were
  bound-pinned in the fail-low pass, keeping at most four by reduced-depth
  full-window score.
- The full verifier then scores candidates from the same TT/history snapshot
  instead of sequentially contaminating later candidates.
- Depths 9-11 keep the previous verifier path to avoid shallow opening drift.

Candidate-4 fixed-depth result:

```text
go depth 14
bestmove h7g6
```

The shallow benchmark gate is unchanged against `./mantis_timed_verify_guard`:
depth 8 and depth 9 both had zero best-move, score, and node changes across all
44 benchmark positions.

Next: test this binary in practice games and then measure whether the same
snapshot-verifier idea helps timed root verification without spending too much
of the clock on suspect quiets.

## Timed Snapshot Root Verification

Implemented a bounded clock-mode version of the snapshot verifier:

- Managed-clock clean verification now gets a small instability extension only
  when the original hard limit was not already capped by time pressure.
- Timed suspect prefiltering uses a shallower reduced-depth probe.
- Timed snapshot verification compares suspects against the recovered root best
  and verifies only the top suspect quiets plus forcing moves, so it can finish
  before falling back to the previous completed depth.
- Fixed-depth verification keeps the fuller candidate set.

Candidate-4 3+2 clock result:

```text
go wtime 180000 btime 180000 winc 2000 binc 2000
bestmove h7g6
```

Clock comparison against `./mantis_stable_verify`:

| Suite | Bestmove changes | Avg depth | Nodes | Time | Max score delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| Viridithas first-collapse FENs | 1/13 | 15.38 -> 15.46 | +10.71% | +11.15% | 3 cp |
| 44-position 3+2 smoke, first 16 | 0/16 | 13.56 -> 13.62 | +6.51% | +7.07% | 20 cp |

The only first-collapse bestmove change was candidate 4, `g8h8 -> h7g6`.
Fixed-depth comparison against `./mantis_stable_verify` stayed exact at depths
8 and 9 across all 44 benchmark positions: zero bestmove, node, and score
changes.

Validation passed:

```text
python3 tactical_regression.py --binary ./mantis_timed_snapshot_verify
python3 correctness_test.py --binary ./mantis_timed_snapshot_verify
python3 stats_benchmark.py --binary ./mantis_timed_snapshot_verify
```

Next: test `./mantis_timed_snapshot_verify` in practice games, then inspect any
new Viridithas losses for fresh first-collapse positions rather than continuing
to tune candidate 4.

## Score-Scale Reporting Pass

Added oracle reporting for the move selected by the current test binary, not
just the move that appeared in the saved PGN. The report now shows Mantis best,
oracle rank, and oracle loss per engine search row.

Found that SFNNv14 feature parity was intact on late-game false-collapse
positions, but Mantis was emitting raw Stockfish internal NNUE units as UCI
centipawns. Example:

```text
raw_total=-1319
Static evaluation: -345 cp (-1319 internal, side to move perspective)
```

The conservative fix keeps search on the existing raw internal units, converts
UCI `score cp` output through Stockfish's material WDL scale, and raises the
time-management score-drop thresholds to internal-unit equivalents. A fuller
Stockfish final-eval formula was tested but backed out because it changed root
choices in the existing Viridithas regression set.

Candidate-4 3+2 clock result remains fixed:

```text
go wtime 180000 btime 180000 winc 2000 binc 2000
bestmove h7g6
```

Score-parity first-collapse oracle run on `./mantis_score_parity`:

| Suite | Max current Mantis loss | Candidate 4 |
| --- | ---: | --- |
| Viridithas first-collapse FENs | 36 cp | `h7g6`, oracle rank 1 |

Validation passed:

```text
python3 tactical_regression.py --binary ./mantis_score_parity
python3 correctness_test.py --binary ./mantis_score_parity
python3 stats_benchmark.py --binary ./mantis_score_parity
```

Next: use `./mantis_score_parity` for practice games, then run the broader
worst-playable trace with the scaled score output to separate real move-choice
losses from old raw-score false collapses.

## Root TT-Bound Recovery Diagnostic

Added `RootDebugTrace` child TT metadata so root aspiration traces now print
the child search window plus the pre-search TT entry for each root child:
slot, flag, stored depth, requested depth, decoded score, raw score, age,
depth usability, and cutoff kind.

Sensitive FEN:

```text
1r3rk1/1p1b3q/3NpP1p/p2pn1p1/8/6P1/PP1QBR1P/2R3K1 b - - 0 25
```

Depth-11 trace on `./mantis_tt_bound_trace` explains why fail-high recovery can
collapse to the lower edge:

```text
phase=fail_high_research move=g8h8 score=-549
child_window=[-50000,549]
child_tt=hit(slot=0 flag=beta depth=10/10 score=549 ... cutoff=beta)
```

The initial aspiration pass keeps searching after a root fail-high and can
produce invalid child windows once `current_alpha >= beta`. A candidate that
stopped the root pass immediately on beta was tested as
`./mantis_root_beta_cut`; it fixed the depth-11 `h7g6` trace and removed the
invalid-window tail, but it failed the existing tactical suite by reviving the
bad `h4g3` move in the 2026-05-29 Viridithas position. That behavior change was
rejected.

The accepted change is diagnostic-only. Search behavior remains matched to
`./mantis_score_parity`; the new trace gives the next pass direct evidence for
TT-bound handling during root aspiration recovery.

## Fail-High Clean Verify Rejection

Tested a candidate `./mantis_failhigh_clean_verify` that reused the existing
clean-root verification machinery after fail-high re-searches. It passed the
small tactical suite once, but the broader first-collapse clock comparison
against `./mantis_score_parity` rejected it:

```text
python3 compare_candidates.py \
  --baseline ./mantis_score_parity \
  --candidate ./mantis_failhigh_clean_verify \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --csv games/failhigh_clean_verify_compare_first_collapse.csv
```

Full 13-position result:

```text
avg_depth:        15.46 -> 14.62
nodes:            18422938 -> 12543507 (-31.91%)
time_ms:          77256 -> 62643 (-18.92%)
changed:
   4: h7g6 -> g8h8 score_delta=-1 node_delta=-1781737
```

Conclusion: fail-high verification can spend enough budget to lose a completed
depth and undo the `h7g6` queen-defense improvement. Do not accept future root
recovery candidates from the small tactical suite alone; run the first-collapse
clock compare with `--fail-on-depth-loss` and `--fail-on-bestmove-change`.

## Fail-High Beta-Floor Rejection

Tested `./mantis_failhigh_beta_floor`, which changed fail-high aspiration
re-search to use the failed beta bound as the new root alpha. This is cheaper
than clean verification and did find some oracle-known improvements:

```text
1: c8c2 -> f8c5, oracle_loss 36 -> 0
5: d3c2 -> d3e4, oracle rank 2 -> 1
```

The broader first-collapse clock compare still rejected it:

```text
python3 compare_candidates.py \
  --baseline ./mantis_score_parity \
  --candidate ./mantis_failhigh_beta_floor \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --fail-on-depth-loss \
  --fail-on-bestmove-change \
  --csv games/failhigh_beta_floor_compare_first_collapse.csv
```

Full result:

```text
bestmove_changes: 5
avg_depth:        15.46 -> 15.31
nodes:            18422938 -> 17566559 (-4.65%)
time_ms:          77215 -> 87616 (+13.47%)
FAIL: 6 candidate searches lost at least 1 ply
```

Harmful changed moves included `e4e5 -> d5d4`, `h2h3 -> f5d3`, and
`d7e7 -> d7f7`, all worse by the existing Stockfish oracle notes.

The comparison harness now supports `--oracle-csv` and
`--fail-on-oracle-loss-regression` so future mixed candidates can be judged by
known oracle loss, not only by raw bestmove changes.

## UCI OwnBook Fix

Found a separate opening weakness in the UCI book path: with `OwnBook` enabled,
`position startpos` could replace the real game root with a random FEN from the
EPD position file. Those EPD files contain positions, not playable `bm`/`pv`
book moves, so this was not a valid opening book and could make Mantis search
or return moves for the wrong board.

Accepted fix:

- `position startpos` now always sets the actual chess starting position.
- `OwnBook` defaults to true for game play.
- UCI `go` checks a small built-in legal move book before search and returns a
  book move only when the current exact FEN is covered.
- `stats_benchmark.py` and `compare_candidates.py` disable `OwnBook` by default
  so search stats stay comparable; pass `--own-book` (or per-binary compare
  flags) to intentionally include book moves.

Validation:

```text
odin build . -out:mantis_opening_book_fix -o:speed
python3 tactical_regression.py --binary ./mantis_opening_book_fix
python3 correctness_test.py --binary ./mantis_opening_book_fix
python3 stats_benchmark.py --binary ./mantis_opening_book_fix --timeout 90
python3 stats_benchmark.py --binary ./mantis_opening_book_fix --own-book --limit 3 --timeout 30
```

The raw-search benchmark remains at `473960` nodes across the 44 positions with
book disabled, while `--own-book --limit 3` returns immediate book moves at
depth 0/nodes 0. The latest practice-game binary from this pass is
`./mantis_opening_book_fix`.

## Opening Repertoire And Timed Instability Extension

Several search-quality candidates were tested and rejected before accepting
this pass:

- `./mantis_staged_picker`: fixed-depth score gates and first-collapse clock
  compare showed bad bestmove churn and depth losses.
- `./mantis_timed_seed_verify`: tried preparing a timed clean-root snapshot
  when the carried root seed looked like a losing capture, but it still kept
  the bad `c8c2` candidate and lost a completed ply.
- `./mantis_fail_low_tie` and `./mantis_fail_low_tie_timed`: fail-low
  tie-break variants fixed one narrow trace but changed too many timed
  first-collapse moves and lost depth.

The accepted practical change expands the exact-FEN built-in book with a compact
repertoire covering common Ruy Lopez, Italian, Scotch, Sicilian, French, Caro,
Scandinavian, Pirc/Modern, QGD/Slav/KID/Nimzo/London, English, and Reti
prefixes. The table is generated from Mantis' own FEN output, so en-passant and
move counters match the engine's UCI positions.

During validation, `./mantis_book_repertoire` exposed a timed-search cliff in
the 2026-06-01 Viridithas queen-defense regression:

```text
depth 13: bestmove g8h8
depth 14: bestmove h7g6
```

The old binary sometimes reached depth 14 because timed root verification had
extended the hard budget; the book-repertoire binary stopped at depth 13 when a
few milliseconds changed the next-depth projection. The accepted timing fix
reuses the existing conservative hard-time extension at the iteration boundary
when the just-completed depth is unstable or close to the projected budget. This
does not affect fixed-depth search or `go movetime`; it only gives unstable
clock searches the same capped extra time already used by timed root
verification.

Validation:

```text
odin build . -out:mantis_book_time_stability -o:speed
python3 tactical_regression.py --binary ./mantis_book_time_stability
python3 correctness_test.py --binary ./mantis_book_time_stability
python3 stats_benchmark.py --binary ./mantis_book_time_stability --timeout 90
```

Book smoke checks confirmed exact book hits for the root, Ruy Lopez, Italian,
and Sicilian `...d6` transition positions, and confirmed `OwnBook=false` still
forces search. The raw-search benchmark remains at `473960` nodes across the 44
positions with book disabled. The latest practice-game binary from this pass is
`./mantis_book_time_stability`.

## Refined Timed Instability Extension

The broad iteration-boundary instability extension was too permissive. A
first-collapse clock comparison against `./mantis_opening_book_fix` showed no
best-move improvements across 13 Viridithas collapse positions, but it spent
substantially more time:

```text
./mantis_book_time_stability:
bestmove_changes: 0
avg_depth:        14.77 -> 15.46
nodes:            15276407 -> 18422938 (+20.60%)
time_ms:          75922 -> 90953 (+19.80%)
```

The worst case reached depth 18 instead of depth 13, but kept the same
oracle-losing `d3c2` move:

```text
6k1/r4pp1/b1p2n1p/p2r4/N7/1PBB1P1P/P5P1/R5K1 w - - 1 26
d3c2 -> d3c2, oracle_loss 24 -> 24
```

The useful queen-defense fix had a different signature: the bad stopping depth
reported a clipped PV (`g8h8 d2a5`), while the no-benefit over-extensions had
normal-length PVs. The accepted refinement only extends the hard budget at the
iteration boundary when the just-completed PV has length two or less. Timed
root verification still keeps its existing capped extension path.

Validation:

```text
odin build . -out:mantis_time_shortpv -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_opening_book_fix \
  --candidate ./mantis_time_shortpv \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --csv games/time_shortpv_compare_first_collapse.csv
python3 tactical_regression.py --binary ./mantis_time_shortpv
python3 correctness_test.py --binary ./mantis_time_shortpv
python3 stats_benchmark.py --binary ./mantis_time_shortpv --timeout 90
```

Comparison result:

```text
bestmove_changes: 0
avg_depth:        14.77 -> 14.69
nodes:            15276407 -> 14325244 (-6.23%)
time_ms:          76243 -> 71338 (-6.43%)
oracle_loss:      no regressions
```

The queen-defense tactical regression still reaches depth 14 and returns
`h7g6`. The raw-search benchmark remains at `473960` nodes. The latest
practice-game binary from this pass is `./mantis_time_shortpv`.

## Rejected: Aspiration-Count Timed Verification

Next target was the remaining first-collapse oracle losses:

```text
c8c2 -> f8c5, oracle_loss 36
d3c2 -> d3e4, oracle_loss 24
d7e7 -> g1f1, oracle_loss 21
```

Pipeline tracing showed different failure modes:

- `c8c2`: fixed-depth normal search and isolated clean scores are inconsistent
  with MultiPV; a simple MultiPV override is unsafe.
- `d3c2`: fixed-depth final clean-root verification at depth 13 finds `d3e4`,
  while clock search stops at depth 13 without that verification.
- `d7e7`: the oracle move is only second in Mantis MultiPV at depth 14, so this
  still looks like endgame/eval/search disagreement.

Tested candidate binaries:

```text
./mantis_timed_verify_asp
./mantis_timed_verify_quiets
./mantis_timed_verify_core
./mantis_timed_verify_clean
```

The final candidate prepared timed verification when aspiration failures were
already high, kept core/root-seed moves plus positive-history quiets in the
timed verification set, and removed the optimistic carried baseline from timed
snapshot verification. It fixed the target row:

```text
d3c2 -> d3e4, oracle_loss 24 -> 0
```

But the 13-position first-collapse clock compare rejected it:

```text
python3 compare_candidates.py \
  --baseline ./mantis_time_shortpv \
  --candidate ./mantis_timed_verify_clean \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/timed_verify_clean_compare_first_collapse.csv
```

Summary:

```text
bestmove_changes: 5
avg_depth:        14.77 -> 14.23
time_ms:          76975 -> 68547 (-10.95%)
oracle regressions:
  e4e5 -> d5d4, oracle_loss 0 -> 91
  g1g5 -> g1h1, oracle_loss 0 -> 60
queen-defense regression:
  h7g6 -> g8h8
```

Conclusion: aspiration-count alone is not a safe trigger for timed clean-root
verification. The promising sub-result is narrower: if a future gate can
identify the `d3c2` class without stealing time/depth from short-PV tactical
positions, then timed verification can recover `d3e4`. Keep
`./mantis_time_shortpv` as the latest practice-game binary.

## Mixed-Instability Timed Verification

The accepted follow-up keeps the existing short-PV timed verification behavior
unchanged, but adds a narrower mixed-instability trigger for the `d3c2` class.
The trigger only prepares the expanded timed clean-root verification when all
of these hold:

- timed search is active at root PV index 0,
- current depth is at least 12,
- the previous completed PV was nearly full length,
- aspiration history has both repeated fail-lows and fail-highs.

That signature hit the target row but avoided the previously rejected
queen-defense, row-7, and row-9 regressions. For this mixed path, timed
verification keeps core/root-seed/current-best moves and positive-history
quiets, and it does not seed snapshot verification with the optimistic carried
baseline. Ordinary timed verification still uses the previous capped candidate
set and baseline behavior.

Validation:

```text
odin build . -out:mantis_timed_verify_mixed -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_time_shortpv \
  --candidate ./mantis_timed_verify_mixed \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/timed_verify_mixed_compare_first_collapse.csv
python3 tactical_regression.py --binary ./mantis_timed_verify_mixed
python3 correctness_test.py --binary ./mantis_timed_verify_mixed
python3 stats_benchmark.py --binary ./mantis_timed_verify_mixed --timeout 90
python3 stats_benchmark.py --binary ./mantis_timed_verify_mixed --own-book --limit 3 --timeout 30
```

First-collapse clock compare:

```text
bestmove_changes: 1
avg_depth:        14.77 -> 14.77
nodes:            15276407 -> 16422810 (+7.50%)
time_ms:          76985 -> 82896 (+7.68%)
abs_score_delta:  1 cp
changed:
  d3c2 -> d3e4, oracle_loss 24 -> 0
oracle regressions: none
```

The raw-search benchmark remains at `473960` nodes. Tactical regression and
perft correctness passed, and book smoke still returns immediate zero-node
book moves for the first three benchmark positions. The latest practice-game
binary from this pass is `./mantis_timed_verify_mixed`.
