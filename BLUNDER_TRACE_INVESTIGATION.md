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

## Accepted: PV Syzygy WDL Probing

Change: internal Syzygy WDL probes now run before TT cutoffs and are available
at PV nodes as well as cut nodes, while still skipping singular-extension
excluded searches. The path is guarded by `tb.syzygy_enabled`, so normal
no-tablebase searches do not pay extra probe overhead. When `SyzygyPath` is
configured, exact tablebase WDL scores can no longer be hidden by a cached TT
bound on the principal line. PV lines that end because of a tablebase cutoff
are marked as tablebase-terminal, so the short-PV timed extension does not
mistake a legitimate exact endgame cutoff for an unstable clipped PV.

Validation:

```text
odin build . -out:mantis_syzygy_pv -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_timed_verify_mixed \
  --candidate ./mantis_syzygy_pv \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/syzygy_pv_compare_first_collapse.csv
python3 tactical_regression.py --binary ./mantis_syzygy_pv
python3 correctness_test.py --binary ./mantis_syzygy_pv
python3 stats_benchmark.py --binary ./mantis_syzygy_pv --timeout 90
python3 stats_benchmark.py --binary ./mantis_syzygy_pv --own-book --limit 3 --timeout 30
```

First-collapse clock compare with no local Syzygy path loaded:

```text
positions:        13
bestmove_changes: 0
avg_depth:        14.69 -> 14.69
nodes:            15471647 -> 15471647 (+0.00%)
time_ms:          77889 -> 77929 (+0.05%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
oracle regressions: none
```

Tactical regression, perft correctness, raw stats benchmark, and the three-move
own-book smoke test passed. The raw-search benchmark remains at `473960` nodes.
The latest practice-game binary from this pass is `./mantis_syzygy_pv`.

## Accepted: Quiescence Syzygy WDL Frontier

Change: quiescence search now probes Syzygy WDL before static evaluation when
tablebases are enabled. This lets exact tablebase results survive all the way
to depth-zero frontier nodes instead of being replaced by heuristic eval plus
capture-only quiescence. The path is still gated by `tb.syzygy_enabled`, so
normal no-tablebase searches are unchanged.

Validation:

```text
odin build . -out:mantis_syzygy_qfrontier -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_syzygy_pv \
  --candidate ./mantis_syzygy_qfrontier \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/syzygy_qfrontier_compare_first_collapse.csv
python3 tactical_regression.py --binary ./mantis_syzygy_qfrontier
python3 correctness_test.py --binary ./mantis_syzygy_qfrontier
python3 stats_benchmark.py --binary ./mantis_syzygy_qfrontier --timeout 90
python3 stats_benchmark.py --binary ./mantis_syzygy_qfrontier --own-book --limit 3 --timeout 30
```

First-collapse clock compare with no local Syzygy path loaded:

```text
positions:        13
bestmove_changes: 0
avg_depth:        14.69 -> 14.69
nodes:            15471647 -> 15471647 (+0.00%)
time_ms:          78437 -> 78190 (-0.31%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
oracle regressions: none
```

Tactical regression, perft correctness, raw stats benchmark, and the three-move
own-book smoke test passed. The raw-search benchmark remains at `473960` nodes.
The latest practice-game binary from this pass is `./mantis_syzygy_qfrontier`.

## Rejected: Narrow `c8c2` Root Flip Verification

Target:

```text
FEN: 2r1kb1r/pp1b1ppp/1q2p3/3pP3/3n4/3BB3/PPN2PPP/R2Q1RK1 b k - 1 13
Current clock move: c8c2
Oracle move:        f8c5
Oracle loss:        36 cp
```

Fresh diagnostics with `./mantis_syzygy_qfrontier` showed a root-search
inconsistency rather than a simple static-eval miss:

```text
python3 timed_root_trace.py \
  --pgn games/MantisVsViridthas0601.pgn \
  --binary ./mantis_syzygy_qfrontier \
  --target 4:26 \
  --depths 15 \
  --warm-depth 8 \
  --multipv 8 \
  --timeout 120 \
  --report games/syzygy_qfrontier_c8c2_depth15_trace.md \
  --csv games/syzygy_qfrontier_c8c2_depth15_trace.csv
```

Result:

```text
normal d15:  c8c2, score -1.45, nodes 1314643
MultiPV d15: f8c5 rank 1 at -2.15; c8c2 rank 2 at -2.46
```

The normal root-debug trace shows depth 15 can enter fail-low or fail-high
aspiration recovery with a clipped root seed and then flatten alternatives
against the recovery window. A first prototype verified only the initial
fail-high best against the re-search best from a pre-research TT snapshot:

```text
./mantis_failhigh_pair_verify
```

It repaired fixed-depth d15:

```text
c8c2 -> f8c5
nodes 1314643 -> 2496287
time  7874ms -> 14501ms
```

But the reproduced clock target rejected it:

```text
c8c2 -> c8c2
depth 15 -> 13
oracle_loss 36 -> 36
```

Restricting the fail-high pair verification to depth 15+ was inert on the
clock target:

```text
./mantis_failhigh_pair_verify_d15
c8c2 -> c8c2
depth 15 -> 15
oracle_loss 36 -> 36
```

A matching late fail-low suspect verification was also rejected:

```text
./mantis_faillow_suspect_verify_d15
c8c2 -> c8c2
depth 15 -> 14
oracle_loss 36 -> 36
```

Conclusion: the `c8c2` mismatch is still a useful root-search target, but
two-move fail-high verification and late fail-low suspect verification are not
safe practical fixes. Keep `./mantis_syzygy_qfrontier` as the latest accepted
practice-game binary.

## Rejected: Root Child Window Clamps

The same `c8c2` trace also exposed root child searches where the propagated
child window could become zero-width or inverted after a root fail-high. Two
minimal clamps were tested in `run_root_search_pass`.

First candidate:

```text
./mantis_root_window_clamp
child_beta <= child_alpha -> child_beta = child_alpha + 1
```

Target compare:

```text
c8c2 -> f8c5
oracle_loss 36 -> 0
depth 15 -> 15
nodes 1296320 -> 1338738 (+3.27%)
time 7404ms -> 7434ms (+0.41%)
```

This repaired the target row, but tactical regression rejected it:

```text
queen-defense expected h7g6, got g8h8
```

Second candidate:

```text
./mantis_root_inverted_window_clamp
child_beta < child_alpha -> child_beta = child_alpha + 1
```

Target compare:

```text
c8c2 -> c8c2
oracle_loss 36 -> 36
depth 15 -> 15
nodes 1296320 -> 1543803 (+19.09%)
time 7220ms -> 8839ms (+22.42%)
```

This did not repair the target row and tactical regression also rejected it:

```text
queen-defense expected h7g6, got b8d8
```

Conclusion: broad root child-window invariant changes are too risky against the
accepted short-PV tactical behavior. Future work on the `c8c2` root mismatch
should preserve the queen-defense `h7g6` result as a first-class guardrail.
Keep `./mantis_syzygy_qfrontier` as the latest accepted practice-game binary.

## Accepted: Lazy SMP Shared-State Reset

Change: `search_position` now has a narrow `reset_shared_state` switch, and
`parallel_search` resets shared counters/stats exactly once before spawning
helper threads. Lazy SMP helpers call the same search entry without clearing
`total_nodes`, `search_stats`, or the root completed-depth cache while the main
thread is searching. This repairs the UCI `Threads > 1` path without changing
the default single-thread search tree.

Validation:

```text
odin build . -out:mantis_thread_reset_fix -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_syzygy_qfrontier \
  --candidate ./mantis_thread_reset_fix \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/thread_reset_fix_compare_first_collapse.csv
python3 compare_candidates.py \
  --baseline ./mantis_syzygy_qfrontier \
  --candidate ./mantis_thread_reset_fix \
  --depth 8 \
  --timeout 60 \
  --csv games/thread_reset_fix_depth8_compare.csv
python3 tactical_regression.py --binary ./mantis_thread_reset_fix
python3 correctness_test.py --binary ./mantis_thread_reset_fix
python3 stats_benchmark.py --binary ./mantis_thread_reset_fix --timeout 90
python3 stats_benchmark.py --binary ./mantis_thread_reset_fix --own-book --limit 3 --timeout 30
```

First-collapse clock compare:

```text
positions:        13
bestmove_changes: 0
avg_depth:        14.69 -> 14.77
nodes:            15471647 -> 16422810 (+6.15%)
time_ms:          77643 -> 82764 (+6.60%)
abs_score_delta:  6 cp
max_score_delta:  6 cp
oracle regressions: none
```

The only depth change was an oracle-approved `h2h3` row completing one extra
ply. Fixed-depth depth-8 comparison stayed exact across all 44 benchmark FENs:

```text
positions:        44
bestmove_changes: 0
nodes:            1559564 -> 1559564 (+0.00%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
```

Tactical regression, perft correctness, raw stats benchmark, own-book smoke,
and a `Threads=2` UCI SearchStats smoke passed. The raw-search benchmark
remains at `473960` nodes. The latest accepted practice-game binary from this
pass is `./mantis_thread_reset_fix`.

## Accepted: Lazy SMP Helper Shutdown

Change: after the main Lazy SMP thread finishes `search_position` and emits the
root move, `parallel_search` now signals `stop_search()` before joining helper
threads. This prevents helper threads from continuing stale analysis after the
move has already been chosen, while preserving their TT-sharing contribution
during the actual search.

Validation:

```text
odin build . -out:mantis_thread_stop_fix -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_thread_reset_fix \
  --candidate ./mantis_thread_stop_fix \
  --depth 8 \
  --timeout 60 \
  --csv games/thread_stop_fix_depth8_compare.csv
python3 tactical_regression.py --binary ./mantis_thread_stop_fix
python3 correctness_test.py --binary ./mantis_thread_stop_fix
python3 stats_benchmark.py --binary ./mantis_thread_stop_fix --timeout 90
python3 stats_benchmark.py --binary ./mantis_thread_stop_fix --own-book --limit 3 --timeout 30
```

Fixed-depth depth-8 comparison stayed exact across all 44 benchmark FENs:

```text
positions:        44
bestmove_changes: 0
nodes:            1559564 -> 1559564 (+0.00%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
```

Tactical regression, perft correctness, raw stats benchmark, own-book smoke,
`Threads=2` UCI SearchStats smoke, and `Threads=4` depth-12 UCI smoke passed.
The raw-search benchmark remains at `473960` nodes. The latest accepted
practice-game binary from this pass is `./mantis_thread_stop_fix`.

## Accepted: 7-Man Syzygy Probe Default

Change: `SyzygyProbeLimit` now defaults to 7 instead of 6, and tablebase probes
are clamped by the loaded Fathom `TB_LARGEST` cardinality. This lets Mantis use
7-man Syzygy files by default when they are configured, while avoiding needless
failed probes when only smaller tablebases are present. With no Syzygy path
loaded, normal search remains unchanged.

Validation:

```text
odin build . -out:mantis_syzygy7_default -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_thread_stop_fix \
  --candidate ./mantis_syzygy7_default \
  --depth 8 \
  --timeout 60 \
  --csv games/syzygy7_default_depth8_compare.csv
python3 compare_candidates.py \
  --baseline ./mantis_thread_stop_fix \
  --candidate ./mantis_syzygy7_default \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/syzygy7_default_compare_first_collapse.csv
python3 tactical_regression.py --binary ./mantis_syzygy7_default
python3 correctness_test.py --binary ./mantis_syzygy7_default
python3 stats_benchmark.py --binary ./mantis_syzygy7_default --timeout 90
python3 stats_benchmark.py --binary ./mantis_syzygy7_default --own-book --limit 3 --timeout 30
```

Fixed-depth depth-8 comparison stayed exact across all 44 benchmark FENs:

```text
positions:        44
bestmove_changes: 0
nodes:            1559564 -> 1559564 (+0.00%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
```

First-collapse clock compare had zero bestmove changes and no oracle-loss
regressions. Tactical regression, perft correctness, raw stats benchmark, and
own-book smoke passed. The raw-search benchmark remains at `473960` nodes, and
UCI now reports `SyzygyProbeLimit` default `7`. The latest accepted
practice-game binary from this pass is `./mantis_syzygy7_default`.

## Accepted: Interruptible UCI Infinite Search

Change: `go infinite` now runs through the existing background-search lifecycle
instead of blocking the UCI input loop. The shared background state now tracks
whether a worker is a ponder search or a plain infinite search, and `stop` /
`quit` join and destroy the worker cleanly. `ponderhit` remains limited to
actual ponder searches, while infinite search can answer `isready` and then
return a normal `bestmove` after `stop`.

Validation:

```text
odin build . -out:mantis_uci_infinite_stop -o:speed
python3 compare_candidates.py \
  --baseline ./mantis_syzygy7_default \
  --candidate ./mantis_uci_infinite_stop \
  --depth 8 \
  --timeout 60 \
  --csv games/uci_infinite_stop_depth8_compare.csv
python3 tactical_regression.py --binary ./mantis_uci_infinite_stop
python3 correctness_test.py --binary ./mantis_uci_infinite_stop
python3 stats_benchmark.py --binary ./mantis_uci_infinite_stop --timeout 90
python3 stats_benchmark.py --binary ./mantis_uci_infinite_stop --own-book --limit 3 --timeout 30
```

Targeted UCI smokes passed for immediate `go infinite` / `stop`, `go infinite`
with `isready` answered before `stop`, `go ponder` / `ponderhit`, and the same
background paths with `Threads=2`.

Fixed-depth depth-8 comparison stayed exact across all 44 benchmark FENs:

```text
positions:        44
bestmove_changes: 0
nodes:            1559564 -> 1559564 (+0.00%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
```

Tactical regression, perft correctness, raw stats benchmark, and own-book smoke
passed. The raw-search benchmark remains at `473960` nodes. The latest accepted
practice-game binary from this pass is `./mantis_uci_infinite_stop`.

## Accepted: UCI Search Tuning Options

Change: expose a focused SPSA/cutechess tuning surface for the eight
high-leverage search parameters already targeted by the local Nevergrad tuner:
`NmpReductionBase`, `NmpReductionDiv`, `RfpMargin`, `RfpDepth`,
`LmrMinDepth`, `FutilityMargin`, `LmpBase`, and `LmpDiv`. The UCI-advertised
`Contempt` default now matches the actual search default of `12`. The self-play
harness can pass repeated `--option`, `--option-a`, and `--option-b`
`Name=Value` assignments so tuned candidates can play default baselines without
source edits or rebuilds per parameter value.

Validation:

```text
odin build . -out:mantis_uci_tune_options -o:speed
python3 -m py_compile selfplay.py
python3 compare_candidates.py \
  --baseline ./mantis_uci_infinite_stop \
  --candidate ./mantis_uci_tune_options \
  --depth 8 \
  --timeout 60 \
  --csv games/uci_tune_options_depth8_compare.csv
python3 tactical_regression.py --binary ./mantis_uci_tune_options
python3 correctness_test.py --binary ./mantis_uci_tune_options
python3 stats_benchmark.py --binary ./mantis_uci_tune_options --timeout 90
python3 stats_benchmark.py --binary ./mantis_uci_tune_options --own-book --limit 3 --timeout 30
```

Targeted option smokes confirmed that UCI advertises the new options, that
`FutilityMargin=400` changes a depth-6 startpos node count (`8077 -> 8095`),
and that `selfplay.py` applies separate A/B options while preserving color
swaps.

Fixed-depth depth-8 comparison stayed exact across all 44 benchmark FENs:

```text
positions:        44
bestmove_changes: 0
nodes:            1559564 -> 1559564 (+0.00%)
abs_score_delta:  0 cp
max_score_delta:  0 cp
```

Tactical regression, perft correctness, raw stats benchmark, and own-book smoke
passed. The raw-search benchmark remains at `473960` nodes. The latest accepted
practice-game binary from this pass is `./mantis_uci_tune_options`.

## Accepted: No-Rebuild UCI Tuning Harness

Change: `nevergrad_tuner.py` now evaluates candidates through the UCI tuning
options instead of rewriting `search/tuning.odin` and rebuilding for every
parameter set. The tuner compares engine A with candidate `--option-a`
assignments against engine B at defaults, honors the requested baseline instead
of the old hardcoded baseline, and keeps source-edit/rebuild tuning as an
explicit `--source-edit` fallback. It also adds a dependency-free random-search
optimizer and uses it automatically when Nevergrad is not installed. Fresh UCI
tuning runs now default to `tuning_progress_uci.json` and `best_params_uci.json`
to avoid resuming stale source-edit tuning artifacts.

Validation:

```text
python3 -m py_compile nevergrad_tuner.py selfplay.py
python3 nevergrad_tuner.py --help
python3 nevergrad_tuner.py \
  --engine ./mantis_uci_tune_options \
  --baseline ./mantis_uci_tune_options \
  --optimizer auto \
  --budget 1 \
  --games 2 \
  --depth 1 \
  --max-moves 4 \
  --concurrency 1 \
  --no-openings \
  --resume /tmp/mantis_tuner_final_progress.json \
  --output /tmp/mantis_tuner_final_best.json \
  --seed 9
```

The smoke confirmed that the local environment falls back from missing
Nevergrad to random search, emits candidate parameters as UCI `--option-a`
assignments, runs a self-play evaluation without rebuilding, and completes with
zero illegal moves or failed games. Explicit `--optimizer nevergrad` without the
package installed now reports a clean error instead of a Python traceback.
`git diff --check` passed.

## Accepted: Real Self-Play Clock Accounting

Change: `selfplay.py` now maintains per-side clocks in `wtime`/`btime` mode
instead of sending the original starting clocks on every move. It subtracts
measured search time, applies the configured increment after completed moves,
and adjudicates a time forfeit when a side flags. The tournament runner now
also passes `--max-moves`, `--adjudicate-eval`, and `--adjudicate-moves` through
to each game, making short tuning screens and bounded validation runs behave as
requested. Opening lines containing move sequences such as `e2e4 e7e5` are no
longer misclassified as FENs just because they contain spaces.

Validation:

```text
python3 -m py_compile selfplay.py nevergrad_tuner.py
python3 selfplay.py \
  --engine-a ./mantis_uci_tune_options \
  --engine-b ./mantis_uci_tune_options \
  --games 1 \
  --wtime 1000 \
  --btime 1000 \
  --winc 100 \
  --binc 100 \
  --max-moves 6 \
  --concurrency 1 \
  --option OwnBook=false \
  --verbose
python3 selfplay.py \
  --engine-a ./mantis_uci_tune_options \
  --engine-b ./mantis_uci_tune_options \
  --games 1 \
  --wtime 1 \
  --btime 1000 \
  --max-moves 4 \
  --concurrency 1 \
  --option OwnBook=false
python3 selfplay.py \
  --engine-a ./mantis_uci_tune_options \
  --engine-b ./mantis_uci_tune_options \
  --games 1 \
  --movetime 10 \
  --max-moves 4 \
  --concurrency 1 \
  --option OwnBook=false
python3 nevergrad_tuner.py \
  --engine ./mantis_uci_tune_options \
  --baseline ./mantis_uci_tune_options \
  --optimizer auto \
  --budget 1 \
  --games 2 \
  --depth 1 \
  --max-moves 4 \
  --concurrency 1 \
  --no-openings \
  --resume /tmp/mantis_tuner_clock_path_progress.json \
  --output /tmp/mantis_tuner_clock_path_best.json \
  --seed 10
```

The clock smoke printed changing clocks and stopped after exactly six plies via
`max moves reached`; the flag smoke produced a white time forfeit; the movetime
smoke still reached `max moves reached`; the tuner smoke completed through the
now-functional `--max-moves` path; and an in-memory `e2e4 e7e5` opening sequence
smoke passed through `run_tournament()`.

## Accepted: Reject Pseudo-Legal King Captures

While revisiting the unresolved `c8c2` vs `f8c5` root mismatch, the root parity
and pipeline diagnostics crashed when unquoted multi-field FEN arguments were
used and when descendant searches reached positions where a pseudo move had
captured the opponent king. The second issue is a core correctness problem:
the opponent king should remain an occupancy blocker, but it must never be a
capture target for normal all-move or capture-only generation.

Change:

- `generate_all_moves()` now treats the opponent king as a blocker for quiet
  and capture generation.
- `generate_capture_moves()` removes the opponent king from the capture target
  mask.
- root trace legality now rejects tentative children where either king is
  missing, and the continuation/pipeline trace pass uses that shared helper.
- one-shot trace commands keep joined FEN strings alive until the trace call
  returns, so quoted and unquoted FEN arguments behave the same.

Focused diagnostic result:

```text
./mantis_no_king_captures trace-root-parity 15 c8c2 f8c5 fen \
  2r1kb1r/pp1b1ppp/1q2p3/3pP3/3n4/3BB3/PPN2PPP/R2Q1RK1 b k - 1 13
```

The unquoted command no longer crashes. It confirms the remaining root issue:
`f8c5` has a much better comparable full-window score than `c8c2`, but the
root PVS probe is pinned at alpha:

```text
c8c2 full=-892
f8c5 full=-609 pvs=-892 note=PVS_MISS
```

Validation:

```text
odin build . -out:mantis_no_king_captures -o:speed
python3 correctness_test.py --binary ./mantis_no_king_captures
python3 tactical_regression.py --binary ./mantis_no_king_captures
python3 compare_candidates.py \
  --baseline ./mantis_current \
  --candidate ./mantis_no_king_captures \
  --depth 8 \
  --timeout 60 \
  --csv games/no_king_captures_depth8_compare.csv
python3 stats_benchmark.py --binary ./mantis_no_king_captures --timeout 90
python3 compare_candidates.py \
  --baseline ./mantis_current \
  --candidate ./mantis_no_king_captures \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/no_king_captures_compare_first_collapse.csv
```

Results:

```text
perft correctness: passed
tactical regression: passed, including h7g6 queen-defense guard
depth-8 comparison: 0/44 bestmove changes, 0 node changes, 0 score changes
raw stats benchmark: 473960 nodes
first-collapse clock compare: 0/13 bestmove changes, 0 node changes,
  0 score changes, no oracle-loss regressions
```

The fixed-depth depth-15 search can still recover `f8c5`, but it takes about
111 seconds on this machine. The 3+2-style clock search still keeps `c8c2`, so
the next behavior target remains a cheaper timed verifier or root PVS recovery
gate for this exact class, with `h7g6` as the first guardrail.

## Accepted: Late Root-Capture Timed Verification

Target:

```text
FEN: 2r1kb1r/pp1b1ppp/1q2p3/3pP3/3n4/3BB3/PPN2PPP/R2Q1RK1 b k - 1 13
Previous clock move: c8c2
Oracle move:         f8c5
```

Root-debug confirmed the clock search reached depth 15 but never prepared clean
verification there:

```text
depth=15 verify_clean=false
initial c8c2 score=-633, root seed failed low
fail-low research c8c2 score=-670
```

The accepted change adds a very narrow clock-only verifier preparation trigger:

- root PV search under managed time;
- depth 15 or deeper;
- previous completed PV is full length;
- aspiration history is fail-high-heavy;
- the carried root seed is a capture.

For this trigger, clean verification compares the carried baseline against only
the top two positive-history quiets from the clean root snapshot. It skips the
usual nonpositive-history suspect pool, which was too expensive and could spend
the whole timed budget before reaching `f8c5`.

Target result:

```text
go wtime 180000 btime 180000 winc 2000 binc 2000
before: bestmove c8c2, depth 15, nodes 1296320
after:  bestmove f8c5, depth 15, nodes 2096596
```

First-collapse clock compare:

```text
python3 compare_candidates.py \
  --baseline ./mantis_no_king_captures \
  --candidate ./mantis_timed_capture_verify \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --clock 180000 180000 2000 2000 \
  --timeout 90 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv games/timed_capture_verify_compare_first_collapse.csv
```

Result:

```text
bestmove_changes: 1
c8c2 -> f8c5, oracle_loss 36 -> 0
avg_depth: 14.77 -> 14.77
nodes: +4.87%
time: +6.11%
oracle regressions: none
```

Validation:

```text
odin build . -out:mantis_timed_capture_verify -o:speed
python3 tactical_regression.py --binary ./mantis_timed_capture_verify
python3 compare_candidates.py \
  --baseline ./mantis_no_king_captures \
  --candidate ./mantis_timed_capture_verify \
  --depth 8 \
  --timeout 60 \
  --csv games/timed_capture_verify_depth8_compare.csv
python3 correctness_test.py --binary ./mantis_timed_capture_verify
python3 stats_benchmark.py --binary ./mantis_timed_capture_verify --timeout 90
python3 stats_benchmark.py --binary ./mantis_timed_capture_verify --own-book --limit 3 --timeout 30
```

Fixed-depth depth-8 stayed exact across all 44 benchmark positions: zero
bestmove, node, and score changes. Tactical regression passed, including the
`h7g6` queen-defense guard. Perft correctness passed. The raw stats benchmark
remains `473960` nodes, and own-book smoke still returns zero-node book moves.

Next: re-run or gather fresh practice games against Viridithas using the latest
binary, then extract a new first-collapse/oracle set. The old `c8c2` target is
now fixed under reproduced 3+2 clock conditions; the remaining known oracle
mismatch is `d7e7` vs `g1f1` at about 21 cp.

## Accepted: Oracle Target Reporting

Follow-up diagnostic on the remaining endgame row:

```text
FEN: 8/3R1p2/6p1/1P2k3/1r1p2p1/6P1/5P2/6K1 w - - 7 52
Mantis clock move: d7e7
Oracle move:       g1f1
Oracle loss:       21 cp
```

Root parity and pipeline traces both prefer `d7e7` over `g1f1` in Mantis's own
full-window tree. This is not the same PVS/root recovery class as `c8c2`:

```text
trace-root-parity depth 16:
  g1f1 full=-941
  d7e7 full=-770

trace-root-pipeline depth 16:
  normal final_best=d7e7 final_score=-770
  g1f1 verify=-941
  d7e7 verify=-770
```

So the old first-collapse oracle suite is now mostly exhausted as a search-bug
source. To make that visible, `compare_candidates.py --oracle-csv` now prints an
oracle summary after CSV output, and `oracle_target_report.py` can summarize an
existing compare CSV without rerunning engines.

Command used:

```sh
python3 oracle_target_report.py \
  games/timed_capture_verify_compare_first_collapse.csv \
  --limit 8
```

Result:

```text
positions:      13
known_oracle:   13
improved:       1
fixed:          1
regressed:      0
remaining_loss: 1
loss_cp_total:  57 -> 21 (-36)

top_improvements:
  1: c8c2 -> f8c5, oracle loss 36 -> 0

remaining_targets:
  12: d7e7 -> d7e7, oracle loss 21
```

Validation:

```text
python3 -m py_compile compare_candidates.py oracle_target_report.py
python3 compare_candidates.py \
  --baseline ./mantis_timed_capture_verify \
  --candidate ./mantis_timed_capture_verify \
  --fen-file games/mantis_vs_viridithas_0601_first_collapse.fens \
  --depths 1 \
  --limit 2 \
  --timeout 20 \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --oracle-summary-limit 2 \
  --csv /tmp/mantis_compare_smoke.csv
python3 oracle_target_report.py \
  games/timed_capture_verify_depth8_compare.csv \
  --oracle-csv games/mantis_vs_viridithas_0601_score_parity_first_collapse_oracle.csv \
  --limit 3
```

Next: gather fresh practice-game evidence with the latest binary. Without the
Viridithas executable available locally, use either a new supplied opponent
binary or mine current self-play/Stockfish-assessed games for a fresh
first-collapse/oracle set before making another behavior change.

## Accepted: Self-Play PGN Export

Change: add `--pgn-out` to `selfplay.py` so local practice games can feed
directly into `blunder_trace.py`. The exporter writes standard PGN with
White-perspective `[%eval ...]` comments after each searched ply. Opening-book
moves without an engine score keep score alignment with empty comments.

The self-play result list is now sorted by game index before final summaries
and PGN export. This matters under concurrency, where games can finish out of
order while color assignment still depends on the original game number.

Validation:

```text
python3 -m py_compile selfplay.py
python3 selfplay.py \
  --engine-a ./mantis_timed_capture_verify \
  --engine-b ./mantis_timed_capture_verify \
  --games 2 \
  --depth 1 \
  --max-moves 6 \
  --concurrency 1 \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_selfplay_smoke.pgn
python3 blunder_trace.py \
  --pgn /tmp/mantis_selfplay_smoke.pgn \
  --mode first-collapse \
  --limit 2 \
  --binary ./mantis_timed_capture_verify \
  --depths 1 \
  --timeout 20 \
  --report /tmp/mantis_selfplay_smoke_blunders.md \
  --csv /tmp/mantis_selfplay_smoke_blunders.csv
python3 selfplay.py \
  --engine-a ./mantis_timed_capture_verify \
  --engine-b ./mantis_timed_capture_verify \
  --games 2 \
  --depth 1 \
  --max-moves 4 \
  --concurrency 2 \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_selfplay_concurrent_smoke.pgn
```

The extractor parsed both generated games and found no artificial collapse in
the tiny depth-1 smoke. In the concurrent smoke, game 2 finished before game 1,
but the final per-game summary and PGN remained ordered by round.

Next: run a longer latest-binary self-play batch with `--pgn-out`, then use
`blunder_trace.py --oracle-binary stockfish-debug/src/stockfish` on any fresh
first-collapse candidates.

## Accepted: FEN-Start Stateful Replay

Fresh latest-vs-latest self-play with the new PGN exporter produced two
worst-drop candidates from four 80ms games seeded by `2moves_v1.epd`. Neither
passed the strict first-collapse filter, but worst-mode surfaced one serious
endgame target:

```text
Round 2, ply 143
FEN:    8/8/1KP5/8/3N4/4q2k/7p/8 w - - 9 74
Played: b6b7
Cold d8 best: c6c7
Oracle best: b6a5
Oracle played loss: mate
Oracle cold d8 loss: 158 cp
```

The first stateful replay attempt returned the impossible move `d7d5`, which
exposed a harness bug: PGNs generated from an opening FEN were replayed from
`startpos` in the warmed path. Cold searches used each candidate FEN and were
unaffected.

Change:

- `blunder_trace.py` stateful replay now carries the PGN `FEN` header into UCI
  `position fen ... moves ...` commands for warmup and target searches.
- stateful rows label this path with `-pgnfen`.
- add `--warm-movetime-ms` so warmed replay can use the same timed budget that
  generated a self-play PGN, instead of only fixed-depth warmup.

Validation:

```text
python3 -m py_compile blunder_trace.py
python3 blunder_trace.py \
  --pgn /tmp/mantis_latest_selfplay_0603.pgn \
  --mode worst \
  --limit 4 \
  --candidate-indexes 2 \
  --binary ./mantis_timed_capture_verify \
  --no-depths \
  --movetimes-ms 80 250 \
  --stateful-replay \
  --warm-depth 8 \
  --timeout 60 \
  --report /tmp/mantis_latest_selfplay_0603_stateful_candidate2_fixed.md \
  --csv /tmp/mantis_latest_selfplay_0603_stateful_candidate2_fixed.csv
python3 blunder_trace.py \
  --pgn /tmp/mantis_latest_selfplay_0603.pgn \
  --mode worst \
  --limit 4 \
  --candidate-indexes 2 \
  --binary ./mantis_timed_capture_verify \
  --no-depths \
  --movetimes-ms 80 250 \
  --stateful-replay \
  --warm-movetime-ms 80 \
  --timeout 60 \
  --report /tmp/mantis_latest_selfplay_0603_stateful_candidate2_warm80.md \
  --csv /tmp/mantis_latest_selfplay_0603_stateful_candidate2_warm80.csv
```

Corrected result:

```text
stateful-warm8-pgnfen:
  80ms  -> b6a6
  250ms -> b6a6

stateful-warm80ms-pgnfen:
  80ms  -> b6c5
  250ms -> b6a6
```

The original `b6b7` was not deterministic under replay, but the 80ms timed warm
path still shifts away from the cold `b6a6` choice. This is a useful fresh
timing-sensitive endgame target, not yet an accepted engine behavior change.

## Accepted: Self-Play Search Metadata

The `b6b7` target did not reproduce under an exact single-process replay matrix:

```text
searchstats=false, ucinewgame=false: 80ms b6a6 d10, 250ms b6b5 d10
searchstats=false, ucinewgame=true:  80ms b6a6 d9,  250ms b6c5 d11
searchstats=true,  ucinewgame=false: 80ms b6a6 d9,  250ms b6a6 d11
searchstats=true,  ucinewgame=true:  80ms b6a6 d9,  250ms b6a6 d11
```

That leaves CPU-load and timed-depth variance as plausible explanations for the
original self-play move. To make future mined targets more actionable,
`selfplay.py --pgn-out` now records per-move search metadata in comments:

```text
[%eval +0.17] [%depth 2] nodes 196 time 0ms
```

`blunder_trace.py` still reads the `[%eval ...]` prefix normally.

Validation:

```text
python3 -m py_compile selfplay.py
python3 selfplay.py \
  --engine-a ./mantis_timed_capture_verify \
  --engine-b ./mantis_timed_capture_verify \
  --games 1 \
  --depth 2 \
  --max-moves 4 \
  --concurrency 1 \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_selfplay_meta_smoke.pgn
python3 blunder_trace.py \
  --pgn /tmp/mantis_selfplay_meta_smoke.pgn \
  --mode worst \
  --limit 2 \
  --binary ./mantis_timed_capture_verify \
  --depths 1 \
  --timeout 20 \
  --report /tmp/mantis_selfplay_meta_smoke.md \
  --csv /tmp/mantis_selfplay_meta_smoke.csv
```

Next: run a larger metadata-rich self-play batch under concurrency and rank only
targets where the PGN move was made at a plausible depth/time, then promote
stable Stockfish-confirmed targets into engine changes.

## Accepted: Blunder Reports Read PGN Search Metadata

An eight-game metadata-rich self-play batch produced two threshold worst-drop
targets and no strict first-collapse targets:

```text
python3 selfplay.py \
  --engine-a ./mantis_timed_capture_verify \
  --engine-b ./mantis_timed_capture_verify \
  --games 8 \
  --movetime 80 \
  --max-moves 180 \
  --concurrency 2 \
  --openings 2moves_v1.epd \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_latest_selfplay_meta8_0603.pgn
```

`blunder_trace.py` now parses `[%depth ...]`, `nodes ...`, and `time ...ms`
from PGN comments into `played_depth`, `played_nodes`, and `played_time_ms`.
Markdown reports include a `Played Search` column.

Validation:

```text
python3 -m py_compile blunder_trace.py
python3 blunder_trace.py \
  --pgn /tmp/mantis_latest_selfplay_meta8_0603.pgn \
  --mode worst \
  --limit 2 \
  --report /tmp/mantis_latest_selfplay_meta8_metadata_report.md \
  --csv /tmp/mantis_latest_selfplay_meta8_metadata_report.csv
```

Result:

```text
Round 2 ply 89: h6e3, d8 15087 nodes 52ms, eval -7.65 -> -13.34
Round 8 ply 31: h2h3, d6 7907 nodes 35ms, eval -4.63 -> -6.38
```

Stockfish depth-12 filtering on these positions:

```text
Round 2 h6e3: played loss 333 cp, but position was already -7.65.
Round 8 h2h3: played move outside Stockfish MultiPV 8; cold d8 b1c3 is only
  7 cp behind Stockfish's top move.
```

Focused replay for the round-8 target:

```text
cold 80ms:                 h2h3, d6, -6.38
cold 250ms:                h2h3, d10, -6.74
stateful-warm80ms 80ms:    h2h3, d6, -6.38
stateful-warm80ms 250ms:   h2h3, d10, -6.74
3+2-style clock:           f4d6, d15, -7.98
```

Root parity at depth 10 shows the underlying class:

```text
h2h3 full=-2614
g3f3 full=-2432, pvs=-2614, PVS_MISS
a4a5 full=-2344, pvs=-2432, PVS_MISS
```

This is a reproducible fast-movetime root-PVS miss, but the current clock path
already searches past it and avoids `h2h3`. Treat it as a future movetime/root
verification target, not yet an accepted engine patch.

## Accepted: Snapshot Root-PVS Miss Diagnostics

The round-8 `h2h3` target was rechecked with exact root-child snapshots.  A
temporary root-child prune guard that skipped futility/LMP at `ply == 1` did
not change the 80 ms or 250 ms move, and the exact snapshot variants showed the
miss was not explained by TT cutoffs, LMR, futility, LMP, NMP, RFP, razoring, or
probcut:

```text
g3f3 snapshot_full=-2432, snapshot_baseline=-2614, snapshot_no_all_prune_reduce=-2614
a4a5 snapshot_full=-2344, snapshot_baseline=-2432, snapshot_no_all_prune_reduce=-2432
```

Adding an IIR debug toggle split the target:

```text
g3f3 snapshot_no_iir=-2432
a4a5 snapshot_no_iir=-2993
```

So `a4a5` was largely PV-IIR optimism, while `g3f3` remained a full/null-window
disagreement.  Replacing the existing PV Internal Iterative Reduction with true
Internal Iterative Deepening was rejected: it did not fix the played `h2h3`
move at 80 ms or 250 ms and failed the `Viridithas 2026-06-01: keep queen
defense` tactical regression (`g8h8` instead of `h7g6`).

Accepted change: `trace-root-child` and targeted `trace-root-parity` misses now
include IIR-aware snapshot variants, making this class diagnosable without
temporary source edits.

Validation:

```text
odin build . -out:mantis_trace_iir_diag -o:speed
python3 tactical_regression.py --binary ./mantis_trace_iir_diag
python3 correctness_test.py --binary ./mantis_trace_iir_diag --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_trace_iir_diag --limit 3 --timeout 90
```

## Accepted: UCI Option Benchmark Comparison

`stats_benchmark.py` and `compare_candidates.py` now accept arbitrary repeated
UCI tuning options:

```text
python3 stats_benchmark.py \
  --binary ./mantis_timed_capture_verify \
  --limit 1 \
  --option FutilityMargin=400

python3 compare_candidates.py \
  --baseline ./mantis_timed_capture_verify \
  --candidate ./mantis_timed_capture_verify \
  --limit 1 \
  --depths 6 \
  --candidate-option FutilityMargin=400
```

The smoke verifies option delivery: depth-6 startpos changes from `8077` nodes
to `8095` nodes when `FutilityMargin=400` is applied.

This was used to re-screen the stale best UCI tuning set from
`tuning_progress.json`:

```text
NmpReductionBase=1
NmpReductionDiv=6
RfpMargin=86
RfpDepth=7
LmrMinDepth=3
FutilityMargin=271
LmpBase=3
LmpDiv=3
```

Current fixed-depth comparison rejects it as a default change:

```text
Depth 6: 9/44 bestmove changes, nodes 473960 -> 682603 (+44.02%)
Depth 7: 15/44 bestmove changes, nodes 963416 -> 1590727 (+65.11%)
```

A 12-game 80 ms self-play sanity check was neutral:

```text
Wins: 4, Losses: 4, Draws: 4, Win %: 50.00%
```

Conclusion: keep the option-comparison harness improvement, but do not promote
the stale tuned parameters.  Future local tuning should compare candidates with
these option gates before touching `search/tuning.odin`.

## Accepted: PGN-FEN Movetime Root Trace

Fresh latest-vs-latest self-play at 80 ms generated a new metadata-rich PGN:

```text
python3 selfplay.py \
  --engine-a ./mantis_goal_current \
  --engine-b ./mantis_goal_current \
  --games 20 \
  --movetime 80 \
  --max-moves 180 \
  --concurrency 2 \
  --openings 2moves_v1.epd \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_goal_current_meta20_0603.pgn
```

The run scored `11/3/6` for engine A.  Strict first-collapse mining found no
searchable targets, but worst-mode surfaced a useful round-17 low-depth miss:

```text
FEN: 6Q1/1k2q1p1/1p6/r4p1p/3R4/5P2/PP4P1/1KR5 w - - 1 39
Played: c1d1, search d4 7792 nodes 29ms, eval +8.35 -> +6.26
Stockfish d12: g8c8
```

Cold Mantis at fixed depth and movetime chooses `g8c8`, but exact warmed replay
from the PGN start FEN reproduces the played move at 80 ms and recovers at
250 ms:

```text
cold 80ms:                    g8c8, +8.35, d5
cold 250ms:                   g8c8, +8.62, d7
stateful-warm80ms-fen 80ms:   c1d1, +6.26, d4
stateful-warm80ms-fen 250ms:  g8c8, +8.62, d7
```

Change: `timed_root_trace.py` now carries the PGN `FEN` header into all warmup
and target UCI searches, and adds `--warm-movetime-ms` so root traces can warm
the same way the self-play PGN was generated.

Exact stateful root trace:

```text
python3 timed_root_trace.py \
  --pgn /tmp/mantis_goal_current_meta20_0603.pgn \
  --binary ./mantis_goal_current \
  --target 17:73 \
  --movetimes-ms 80 250 \
  --warm-movetime-ms 80 \
  --root-debug \
  --multipv 6 \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 12 \
  --oracle-multipv 6 \
  --oracle-timeout 60 \
  --timeout 90 \
  --report /tmp/mantis_goal_current_candidate6_stateful_root_trace.md \
  --csv /tmp/mantis_goal_current_candidate6_stateful_root_trace.csv
```

The 80 ms warmed normal trace selects `c1d1` at depth 4.  Warmed MultiPV also
ranks `c1d1` above `g8c8` at depth 4, while the 250 ms trace reaches depth 7
and restores `g8c8`.  This makes the fresh target a stateful depth-completion /
low-depth tactical issue.  Next engine candidates should test root check
ordering, movetime overhead, or bestmove stability against this position before
promotion.

Validation:

```text
python3 -m py_compile timed_root_trace.py
python3 timed_root_trace.py ... --target 17:73 --movetimes-ms 80 250 --warm-movetime-ms 80
```

## Accepted: Root Trace UCI Option Probes

Change: `timed_root_trace.py` now accepts repeated `--option Name=Value`
arguments and applies them to the traced binary before warmup and target
searches.  This keeps root-target probes aligned with the other comparison
harnesses and makes UCI tuning checks possible without one-off scripts.

The first use was the round-17 warmed target above:

```text
python3 timed_root_trace.py \
  --pgn /tmp/mantis_goal_current_meta20_0603.pgn \
  --binary ./mantis_goal_current \
  --target 17:73 \
  --movetimes-ms 80 250 \
  --warm-movetime-ms 80 \
  --multipv 6 \
  --option "Move Overhead=0" \
  --timeout 90 \
  --report /tmp/mantis_goal_current_candidate6_overhead0.md \
  --csv /tmp/mantis_goal_current_candidate6_overhead0.csv
```

`Move Overhead=0` did not fix the 80 ms warmed miss:

```text
80ms:  c1d1, +6.26, d4
250ms: g8c8, +8.62, d7
```

Rejected experiment: a temporary root quiet-check ordering bonus was tested
against the same target.  Scores of `500` and `1000` rescued the target
(`c1d1 -> d4d7`) and kept the queen-defense tactical gate passing, but `1500+`
already broke that gate.  With a default-equivalent score of `1000`, broader
checks were mixed:

```text
tactical_regression.py: passed
correctness_test.py --random 20 --seed 0603: passed
stats_benchmark.py --limit 3: unchanged nodes
compare_candidates.py --depths 6 7: 1/88 bestmove change, Stockfish-approved
compare_candidates.py --movetimes 80: 1/44 bestmove change, Stockfish-improved but not best
selfplay.py 20 games at 80ms: 3 wins, 9 losses, 8 draws
```

Conclusion: do not promote root quiet-check ordering as a default.  The rescued
round-17 target remains useful, but the candidate lost too much practical
self-play strength.

## Accepted: Fresh 40-Game Mate-Evasion Target

A larger latest-vs-latest 80 ms sample was generated from the current clean
engine source:

```text
python3 selfplay.py \
  --engine-a ./mantis_goal_probe \
  --engine-b ./mantis_goal_probe \
  --games 40 \
  --movetime 80 \
  --max-moves 180 \
  --concurrency 2 \
  --openings 2moves_v1.epd \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_goal_probe_meta40_0603.pgn
```

The match scored `18/10/12` for engine A.  Strict first-collapse mode again
found no searchable targets, but worst-mode found one useful reproduced
mate-evasion failure:

```text
FEN: N5k1/3bn3/7r/8/5p2/2q2B2/P1P2B2/1R2K3 w - - 0 46
Played: e1f1, search d8 13071 nodes 46ms, eval -6.84 -> -8.40
Stockfish d12: e1e2
```

Cold and warmed 80 ms searches both reproduce the mate-losing move, while
250 ms recovers:

```text
cold 80ms:                   e1f1, oracle rank 3, mate loss
cold 250ms:                  e1d1, oracle rank 2, 353 cp loss
stateful-warm80ms-fen 80ms:  e1f1, oracle rank 3, mate loss
stateful-warm80ms-fen 250ms: e1e2, oracle rank 1
```

Root trace command:

```text
python3 timed_root_trace.py \
  --pgn /tmp/mantis_goal_probe_meta40_0603.pgn \
  --binary ./mantis_goal_probe \
  --target 2:87 \
  --movetimes-ms 80 250 \
  --warm-movetime-ms 80 \
  --root-debug \
  --multipv 6 \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 12 \
  --oracle-multipv 6 \
  --oracle-timeout 60 \
  --timeout 90 \
  --report /tmp/mantis_goal_probe_round2_ply87_root_trace.md \
  --csv /tmp/mantis_goal_probe_round2_ply87_root_trace.csv
```

The 80 ms root is a check-evasion horizon problem.  `e1f1` is seeded from TT
and remains best through completed depth 8.  At 250 ms, depth-9 fail-low
research finally promotes `e1e2`; depth 10 briefly tries `e1f1` again before
fail-high research restores `e1e2`.

Rejected experiments:

```text
Shallow completed-depth fallback: wrong model for round 17; warmed search
  already switched to c1d1 at depth 3 with only a small displayed score drop.
Root-child TT cutoff guard: tested by skipping TT score cutoffs at ply 1;
  round-2 ply-87 still chose e1f1 at 80 ms.
Partial aborted-depth bestmove reuse: rejected from rootdebug evidence because
  the round-17 aborted depth-5 partial best g8h7 was Stockfish-inferior.
```

Conclusion: the next engine candidate should focus on check-evasion horizon
behavior or aspiration/root research timing around depth 8-10, not generic root
TT cutoff suppression or incomplete-depth bestmove reuse.

## Accepted: Blunder Trace UCI Option Probes

Change: `blunder_trace.py` now accepts repeated `--option Name=Value`
arguments and applies them to the traced Mantis binary for both cold searches
and stateful warm/target searches.  The report records active engine options,
matching `timed_root_trace.py` and the benchmark comparison harnesses.

Smoke:

```text
python3 blunder_trace.py \
  --pgn /tmp/mantis_goal_probe_meta40_0603.pgn \
  --mode worst \
  --limit 12 \
  --candidate-indexes 5 \
  --binary ./mantis_goal_probe \
  --no-depths \
  --movetimes-ms 80 \
  --stateful-replay \
  --warm-movetime-ms 80 \
  --stateful-target-fen \
  --option "Move Overhead=0" \
  --timeout 60 \
  --report /tmp/mantis_blunder_trace_option_smoke.md \
  --csv /tmp/mantis_blunder_trace_option_smoke.csv
```

The smoke reproduced the same round-2 mate-evasion loss and printed:

```text
Engine options: `Move Overhead=0`
cold 80ms:                  e1f1, -6.68
stateful-warm80ms-fen 80ms: e1f1, -8.40
```

Rejected check-evasion candidates:

```text
Forced clean root verifier after movetime fail-low:
  spent remaining time too early and degraded 250ms recovery.
Unseeded fail-low research ordering when root is in check:
  80ms still chose e1f1, and 250ms recovered only to e1d1.
History tie-breaks during root-in-check fail-low research:
  80ms still chose e1f1 and 250ms worsened in cold/stateful probes.
```

Conclusion: the current target is not fixed by shallow root ordering tweaks.
Future work should either reduce the cost of the depth-9 fail-low research or
add a more principled check-evasion extension/search rule that survives
self-play.

## Accepted: Tight Movetime Check-Evasion Unseed

Change: when the root side is in check under a very short `go movetime` budget
(`hard_time <= 100ms`), do not preserve the previous completed root PV move as
the root seed.  The normal TT move still exists for diagnostics, but root move
ordering is allowed to start from current history/order signals.  Longer
movetime searches, fixed-depth searches, and clock-managed searches keep the
existing seed behavior.

Target probe:

```text
python3 blunder_trace.py \
  --pgn /tmp/mantis_goal_probe_meta40_0603.pgn \
  --mode worst \
  --limit 12 \
  --candidate-indexes 5 \
  --binary ./mantis_tight_check_unseed \
  --no-depths \
  --movetimes-ms 80 250 \
  --stateful-replay \
  --warm-movetime-ms 80 \
  --stateful-target-fen \
  --timeout 60 \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 12 \
  --oracle-multipv 6 \
  --oracle-timeout 60 \
  --report /tmp/mantis_tight_check_unseed_candidate5_stateful.md \
  --csv /tmp/mantis_tight_check_unseed_candidate5_stateful.csv
```

Result on round 2, ply 87:

```text
Baseline stateful 80ms:  e1f1, oracle rank 3, mate loss
Candidate stateful 80ms: e1d1, oracle rank 2, +3.53 cp loss
Candidate cold 80ms:     e1f1, still mate-losing
Candidate 250ms:         e1d1, oracle rank 2
```

The 250ms warmed target no longer gets the baseline's lucky `e1e2` recovery,
but it still avoids the mate-losing `e1f1`.  Wider top-drop tracing over the
five filtered candidates in `/tmp/mantis_goal_probe_meta40_0603.pgn` did not
expose a new worse known blunder:

```text
python3 blunder_trace.py ... --binary ./mantis_tight_check_unseed \
  --no-depths --movetimes-ms 80 250 --stateful-replay \
  --warm-movetime-ms 80 --stateful-target-fen

report: /tmp/mantis_tight_check_unseed_top12_stateful.md
```

Gates:

```text
python3 tactical_regression.py --binary ./mantis_tight_check_unseed
python3 correctness_test.py --binary ./mantis_tight_check_unseed --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_tight_check_unseed --limit 3 --timeout 90
```

All tactical and perft checks passed.  The small stats benchmark stayed within
expected noise.

Candidate comparison:

```text
python3 compare_candidates.py --baseline ./mantis_goal_probe \
  --candidate ./mantis_tight_check_unseed --movetimes 80 --timeout 90 \
  --csv /tmp/mantis_tight_check_unseed_movetime80_compare.csv
python3 compare_candidates.py --baseline ./mantis_goal_probe \
  --candidate ./mantis_tight_check_unseed --movetimes 250 --timeout 90 \
  --csv /tmp/mantis_tight_check_unseed_movetime250_compare.csv
```

Summary:

```text
80ms:  1/44 bestmove change, f7f8 -> c8e6, -13 cp, +1.97% nodes
250ms: 0/44 bestmove changes, +1.22% nodes
```

Self-play at 80ms:

```text
python3 selfplay.py --engine-a ./mantis_goal_probe \
  --engine-b ./mantis_tight_check_unseed --games 20 --movetime 80 \
  --concurrency 2 --pgn-out /tmp/mantis_tight_check_unseed_selfplay20_80.pgn
```

The result is reported from engine A's perspective.  Baseline scored
`3W-12L-5D`, so the candidate scored `12W-3L-5D`.

## Accepted: Fast Movetime Check-Evasion TT Clear

Change: before starting the `go movetime` timer, clear TT when the root side is
in check and the post-overhead hard budget is at most 250ms.  Clock-managed
searches already clear TT before each move; this extends that protection to
short exact-movetime check evasions without changing fixed-depth, infinite, or
non-check movetime searches.

The accepted `<=100ms` root-seed unseed made the fresh root ordering less stale,
but the fresh 2026-06-03 meta run showed a warmed target where child TT entries
from earlier positions still kept a mate-losing queen evasion alive:

```text
FEN: k7/8/p4P2/4PK2/8/2r4q/P3Q3/7r w - - 6 50
Played: e2g4 (Qg4)
Oracle best: f5f4; e2g4 is mate-losing
```

Focused target probe:

```text
python3 blunder_trace.py \
  --pgn /tmp/mantis_current_meta40_0603.pgn \
  --mode worst \
  --limit 12 \
  --candidate-indexes 4 12 \
  --binary ./mantis_movetime_check_clear \
  --no-depths \
  --movetimes-ms 80 250 \
  --stateful-replay \
  --warm-movetime-ms 80 \
  --stateful-target-fen \
  --timeout 60 \
  --oracle-binary ./stockfish-debug/src/stockfish \
  --oracle-depth 12 \
  --oracle-multipv 6 \
  --oracle-timeout 60 \
  --report /tmp/mantis_movetime_check_clear_candidate4_12_final.md \
  --csv /tmp/mantis_movetime_check_clear_candidate4_12_final.csv
```

Result:

```text
Round 20 ply 95:
  stateful 80ms:  f5g5, oracle rank 2, +0.09 cp loss
  stateful 250ms: f5g5, oracle rank 2, +0.09 cp loss
  baseline stateful had reproduced e2g4 at 80/250 in the same warmed setup.

Round 8 ply 43:
  80ms remains the known cold horizon miss e5c4.
  250ms remains c1d2, oracle rank 1.
```

Guards:

```text
odin build . -out:mantis_movetime_check_clear -o:speed
python3 tactical_regression.py --binary ./mantis_movetime_check_clear
python3 correctness_test.py --binary ./mantis_movetime_check_clear --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_movetime_check_clear --limit 3 --timeout 90
python3 compare_candidates.py --baseline ./mantis_current_probe \
  --candidate ./mantis_movetime_check_clear --movetimes 80 250 \
  --timeout 60 --oracle-csv /tmp/mantis_current_meta40_0603_blunders.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv /tmp/mantis_movetime_check_clear_compare_movetime_final.csv
python3 compare_candidates.py --baseline ./mantis_current_probe \
  --candidate ./mantis_movetime_check_clear --movetimes 80 250 \
  --keep-hash --timeout 60 \
  --oracle-csv /tmp/mantis_current_meta40_0603_blunders.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv /tmp/mantis_movetime_check_clear_compare_movetime_keephash_final.csv
```

Summary:

```text
Tactical regression: passed, including h7g6 queen-defense guard.
Perft correctness:   passed.
Default compare:     80ms 0/44 bestmove changes; 250ms 0/44.
Keep-hash compare:   80ms 0/44 bestmove changes; 250ms 0/44.
```

Self-play at 80ms:

```text
python3 selfplay.py --engine-a ./mantis_movetime_check_clear \
  --engine-b ./mantis_current_probe --games 40 --movetime 80 \
  --max-moves 180 --concurrency 2 --openings 2moves_v1.epd \
  --option OwnBook=false \
  --pgn-out /tmp/mantis_movetime_check_clear_vs_current_40x80.pgn
```

Candidate scored `18W-15L-7D` from engine A's perspective.  Two wins came from
illegal `a1a1` moves by the baseline/current engine, so the match is supportive
but noisy rather than decisive.

## Rejected: Aborted Initial-Pass Fallback

Experiment: when an aspiration re-search timed out after a completed initial
root pass, return that initial pass' root best move instead of the previous
completed-depth best.  The narrow version only applied to root check evasions in
exact movetime searches with a post-overhead hard budget at or below 100ms.

Motivation: the current 2026-06-03 meta run still had one short movetime
check-evasion horizon failure after the TT-clear change:

```text
FEN: r7/ppp2p1k/7r/2q1Nb1p/P7/5P2/1P4PP/2KR4 w - - 0 24
Played: e5c4 (Nc4)
Oracle best: c1d2; e5c4 is mate-losing
```

Direct root tracing showed the 80ms search completed the depth-9 initial pass
with `c1d2`, then timed out during the fail-low re-search and restored the older
completed depth's `e5c4`.

Useful evidence:

```text
Focused candidate-4/12 replay:
  Round 20 ply 95 remained fixed: f5g5 at 80/250 cold and stateful.
  Round 8 ply 43 became fixed: c1d2 at 80/250 cold and stateful.

Tactical regression: passed.
Perft correctness:   passed.
Stats benchmark:     normal.

Default compare:
  80ms:  1/44 bestmove change, e2d2 -> c4d5 on a non-check FEN.
         Stockfish targeted depth-14 searchmoves preferred c4d5 by about 90 cp.
  250ms: 0/44 bestmove changes.

Keep-hash compare:
  80ms:  0/44 bestmove changes.
  250ms: 0/44 bestmove changes.
```

Rejected because self-play did not support the patch:

```text
candidate vs baseline, 40x80ms:
  candidate scored 6W-14L-20D as engine A.
  one illegal a1a1 occurred while candidate was White.

baseline vs candidate, 40x80ms:
  baseline scored 18W-8L-14D as engine A.
  one illegal a1a1 occurred while baseline was White.

Combined candidate score: 31/80.
```

Conclusion: the fallback is attractive for the specific candidate-12 failure,
but it gives under-validated aborted-depth root output too much authority in
short check evasions.  Keep the trace as a warning and look for a safer fix that
either completes the verification or improves the depth before the fail-low
re-search is started.

## Accepted: Scoped Two-Evasion Check Extension

Change: keep the normal frontier-only check extension everywhere except a very
narrow fast-movetime root shape: the root side is in check, post-overhead hard
time is at most 100ms, and the root has at most two legal evasions.  In that
shape only, the search thread extends every checked node by one ply.  The
existing tight check-evasion root-seed suppression and fast movetime TT clear
remain in place.

Motivation: the rejected aborted-depth fallback fixed the target by trusting a
completed narrow initial pass after the fail-low re-search timed out.  Root
debugging showed a safer direction: the position has only two legal evasions,
and the bad `e5c4` line is a forcing queen-check sequence.  Extending checked
nodes only for this constrained root shape lets the 80ms search prove enough of
the tactic without returning an aborted depth.

The broad full-check-extension experiment was rejected first: it fixed the
target but made round 20 ply 95 choose `f5g6`, an oracle mate-losing move.  The
two-evasion gate leaves that position on the previous safe `f5g5` path.

Focused target replay:

```text
python3 blunder_trace.py --pgn /tmp/mantis_current_meta40_0603.pgn \
  --mode worst --limit 12 --candidate-indexes 4 12 \
  --binary ./mantis_tight_two_evasion_check_ext --no-depths \
  --movetimes-ms 80 250 --stateful-replay --warm-movetime-ms 80 \
  --stateful-target-fen --timeout 60 \
  --oracle-binary ./stockfish-debug/src/stockfish --oracle-depth 12 \
  --oracle-multipv 6 --oracle-timeout 60 \
  --report /tmp/mantis_tight_two_evasion_check_ext_candidate4_12.md \
  --csv /tmp/mantis_tight_two_evasion_check_ext_candidate4_12.csv
```

Result:

```text
Round 20 ply 95:
  cold/stateful 80ms:  f5g5, oracle rank 2, +0.09 cp loss
  cold/stateful 250ms: f5g5, oracle rank 2, +0.09 cp loss

Round 8 ply 43:
  cold/stateful 80ms:  c1d2, oracle rank 1, +0.00 cp loss
  cold/stateful 250ms: c1d2, oracle rank 1, +0.00 cp loss
```

Old round-2 guard stayed unchanged:

```text
FEN: N5k1/3bn3/7r/8/5p2/2q2B2/P1P2B2/1R2K3 w - - 0 46
80ms:  e1f1, still mate-losing
250ms: e1d1, oracle rank 2
```

Gates:

```text
odin build . -out:mantis_tight_two_evasion_check_ext -o:speed
python3 tactical_regression.py --binary ./mantis_tight_two_evasion_check_ext
python3 correctness_test.py --binary ./mantis_tight_two_evasion_check_ext \
  --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_tight_two_evasion_check_ext \
  --limit 3 --timeout 90
python3 compare_candidates.py --baseline ./mantis_movetime_check_clear \
  --candidate ./mantis_tight_two_evasion_check_ext --movetimes 80 250 \
  --timeout 60 --oracle-csv /tmp/mantis_current_meta40_0603_blunders.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv /tmp/mantis_tight_two_evasion_check_ext_compare_movetime.csv
python3 compare_candidates.py --baseline ./mantis_movetime_check_clear \
  --candidate ./mantis_tight_two_evasion_check_ext --movetimes 80 250 \
  --keep-hash --timeout 60 \
  --oracle-csv /tmp/mantis_current_meta40_0603_blunders.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv /tmp/mantis_tight_two_evasion_check_ext_compare_movetime_keephash.csv
```

Summary:

```text
Tactical regression: passed.
Perft correctness:   passed.
Stats benchmark:     normal.
Default compare:     80ms 0/44 bestmove changes; 250ms 0/44.
Keep-hash compare:   80ms 0/44 bestmove changes; 250ms 0/44.
```

Top-12 current-meta replay:

```text
python3 blunder_trace.py --pgn /tmp/mantis_current_meta40_0603.pgn \
  --mode worst --limit 12 \
  --binary ./mantis_tight_two_evasion_check_ext --no-depths \
  --movetimes-ms 80 250 --stateful-replay --warm-movetime-ms 80 \
  --stateful-target-fen --timeout 60 \
  --oracle-binary ./stockfish-debug/src/stockfish --oracle-depth 12 \
  --oracle-multipv 6 --oracle-timeout 60 \
  --report /tmp/mantis_tight_two_evasion_check_ext_top12.md \
  --csv /tmp/mantis_tight_two_evasion_check_ext_top12.csv
```

Candidate 12 remains fixed in cold and stateful 80/250.  No known oracle
regressions appeared in the top-12 report.

Self-play at 80ms was mixed rather than decisive:

```text
candidate vs baseline: 12W-10L-18D, no illegal moves.
baseline vs candidate: 14W-11L-15D from baseline's perspective.
```

The reversed match included one `a1a1` illegal move by the baseline/current
engine, giving the candidate one win.  Combined candidate score was `47/80`, so
self-play is neutral-to-mildly-negative noise, not positive proof.  The patch is
accepted on the deterministic tactical fix plus clean compare surface, with this
self-play caveat documented.

## Accepted: UCI No-Move Formatting

The recurring self-play `a1a1` illegal move was reproducible from a terminal
mate position, not from a searched legal move:

```text
FEN: 4rrk1/p1p3Qp/1p6/5P1N/8/P2q4/1PR5/RKB4b b - - 0 29
python-chess: check=True, mate=True, legal_count=0
```

Before the fix, Mantis correctly found no legal moves but printed the zero-value
move sentinel as coordinates:

```text
info string CRITICAL: no legal moves found!
bestmove a1a1
```

Change: `board.print_move()` now emits UCI `0000` for an empty `Move{}`.
`selfplay.py` also treats `bestmove 0000` the same as `(none)`, so future
self-play runs record the game result instead of awarding an illegal-move
forfeit after mate or stalemate.

Verification:

```text
odin build . -out:mantis_no_move_uci -o:speed
python3 -m py_compile selfplay.py
patched mate repro: bestmove 0000
selfplay Engine.go(depth=1) on the mate FEN: (None, None)
python3 tactical_regression.py --binary ./mantis_no_move_uci
python3 correctness_test.py --binary ./mantis_no_move_uci --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_no_move_uci --limit 3 --timeout 90
python3 compare_candidates.py --baseline ./mantis_current_probe \
  --candidate ./mantis_no_move_uci --depths 6 --timeout 60 \
  --csv /tmp/mantis_no_move_uci_depth6_compare.csv
```

Summary: tactical regression passed; randomized perft passed; the short stats
benchmark was normal; depth-6 comparison over 44 positions had `0/44` bestmove
changes, `0` node changes, and `0 cp` score delta.

## Accepted: Quiet Promotions In Quiescence

Change: quiescence now searches non-capturing pawn promotions as tactical moves
alongside captures.  The compact quiescence move generator still avoids full
quiet move generation; it appends only quiet promotions after the existing
capture generator.  Capture-only qsearch parity diagnostics keep using the
capture generator path.

Motivation: a promotion on an empty square is tactically forcing but was
invisible at quiet qsearch frontiers.  The candidate-6 queen endgame remains a
deeper evaluation/search problem; this patch closes the general horizon hole
without being accepted as a candidate-6 fix.

```text
FEN: 8/p4R1p/1p4pk/7q/7Q/7P/P2rp1P1/7K w - - 3 44
```

The top-12 replay initially showed a cold 80ms `h4f4` result, but repeated
direct and blunder-trace probes on the accepted binary returned `h4e7`.
Stateful 80/250 and cold 250 also choose `h4e7`, so this target is still open:

```text
Repeated direct cold 80ms after the commit: 5/5 h4e7, depth 6, 15492 nodes.
Blunder trace cold repeat: h4e7, +2.88, rank 5.
Stateful clear-hash after warm-up: h4e7.
```

Gates:

```text
odin build . -out:mantis_qsearch_quiet_promos -o:speed
python3 tactical_regression.py --binary ./mantis_qsearch_quiet_promos
python3 correctness_test.py --binary ./mantis_qsearch_quiet_promos \
  --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_qsearch_quiet_promos \
  --limit 3 --timeout 90
python3 compare_candidates.py --baseline ./mantis_current_next \
  --candidate ./mantis_qsearch_quiet_promos --depths 6 --timeout 60 \
  --csv /tmp/mantis_qsearch_quiet_promos_depth6_compare.csv
python3 compare_candidates.py --baseline ./mantis_current_next \
  --candidate ./mantis_qsearch_quiet_promos --movetimes 80 250 \
  --timeout 60 --oracle-csv /tmp/mantis_current_meta40_0603_blunders.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv /tmp/mantis_qsearch_quiet_promos_movetime_compare.csv
python3 compare_candidates.py --baseline ./mantis_current_next \
  --candidate ./mantis_qsearch_quiet_promos --movetimes 80 250 \
  --keep-hash --timeout 60 \
  --oracle-csv /tmp/mantis_current_meta40_0603_blunders.csv \
  --fail-on-oracle-loss-regression 0 \
  --csv /tmp/mantis_qsearch_quiet_promos_movetime_keephash_compare.csv
python3 blunder_trace.py --pgn /tmp/mantis_current_meta40_0603.pgn \
  --mode worst --limit 12 \
  --binary ./mantis_qsearch_quiet_promos --no-depths \
  --movetimes-ms 80 250 --stateful-replay --warm-movetime-ms 80 \
  --stateful-target-fen --timeout 60 \
  --oracle-binary ./stockfish-debug/src/stockfish --oracle-depth 12 \
  --oracle-multipv 6 --oracle-timeout 60 \
  --report /tmp/mantis_qsearch_quiet_promos_top12.md \
  --csv /tmp/mantis_qsearch_quiet_promos_top12.csv
./mantis_qsearch_quiet_promos validate-qcaptures 3 \
  '8/p4R1p/1p4pk/7q/7Q/7P/P2rp1P1/7K w - - 3 44'
python3 selfplay.py --engine-a ./mantis_qsearch_quiet_promos \
  --engine-b ./mantis_current_next --games 30 --movetime 80 \
  --concurrency 4 \
  --pgn-out /tmp/mantis_qsearch_quiet_promos_vs_current_30x80.pgn
```

Summary:

```text
Build: passed.
Tactical regression: passed.
Randomized perft: passed.
Stats benchmark: normal.
Depth-6 compare: 0/44 bestmove changes, +0.06% nodes, 0 cp score delta.
Movetime compare: no known oracle regressions; unknown flips only.
Keep-hash movetime compare: 0/44 flips at 80ms; 1/44 unknown flip at 250ms.
Top-12 replay: candidate 12 remains fixed; candidate 6 still open after repeats.
QCapture parity: OK, 9311 positions at depth 3 on candidate-6 FEN.
Self-play 30x80ms: candidate scored 19W-9L-2D with no illegal/invalid PGN markers.
```

## Rejected: Quiet Checks In Quiescence

Trial: generate all quiet moves for shallow non-check qsearch nodes, search only
quiet non-promotion moves that give check after make, and disable delta pruning
while that quiet-check window is active.

Result: rejected.  It did not fix candidate 6 and it disturbed fixed-depth
behavior enough to be a poor trade.

```text
Candidate 6 FEN:
8/p4R1p/1p4pk/7q/7Q/7P/P2rp1P1/7K w - - 3 44

Quiet-check qsearch:
  cold 80ms:      h4e7, +2.48, rank 5, +5.94 loss
  cold 250ms:     h4e7, +2.48, rank 5, +5.94 loss
  stateful 80ms:  h4e7, +5.24, rank 5
  stateful 250ms: h4e7, +2.00, rank 5
```

Fixed-depth comparison against the accepted quiet-promotion binary:

```text
Depth 6 compare: 6/44 bestmove changes, +5.23% nodes, +7.72% time,
180 cp total absolute score delta, 37 cp max score delta.
```

Conclusion: searching quiet checks at shallow qsearch ply adds broad churn and
cost without solving the target.  Keep quiet promotions only.

## Rejected: Fail-Low Beta Retry Without TT Cutoffs

Target: latest smoke candidate 1, where cold 250ms kept the depth-6 root seed
`c8b7` even though depth 8 and the oracle prefer `d7c5`/`f7f5`.

```text
FEN:
r1b2rk1/3nbp1p/p2p2p1/1p1Pp3/1q2P3/3BB1NP/2Q2PP1/R3R1K1 b - - 1 25

Baseline:
  cold d7:    c8b7
  cold d8:    f7f5
  cold 250ms: c8b7

Pipeline diagnosis at depth 7:
  root seed c8b7 failed low exactly at alpha.
  fail-low research returned the old beta bound for c8b7.
  isolated full scores preferred d7c5.
```

Experiments:

```text
1. Change the fail-low beta retry guard from strict > alpha to the equality
   case as well.
2. Run that retry with TT cutoffs disabled so beta-bound TT entries from the
   fail-low pass cannot re-mask later root moves.
3. Scope the retry to depth >= 7 after the broad version changed depth-6
   decisions.
```

The depth-gated version fixed the target:

```text
candidate cold d7:    d7c5, oracle rank 1
candidate cold d8:    d7c5, oracle rank 1
candidate cold 250ms: d7c5, oracle rank 1
```

Rejected because the broader gates were not safe enough:

```text
Broad equality/no-TT retry:
  depth 6 compare: 4/44 bestmove changes, +9.51% nodes, 156 cp abs delta.
  depth 7 compare: 3/44 bestmove changes, +6.40% nodes, 193 cp abs delta.

Depth-gated retry:
  depth 6 compare: 0/44 bestmove changes, 0 node changes, 0 cp delta.
  depth 7 compare: 0/44 bestmove changes, +2.36% nodes, 30 cp abs delta.
  movetime 80ms compare: 1/44 bestmove change with -359 cp score delta.
  movetime 250ms compare: lost depth on multiple rows and crashed at
  search/search.odin static_eval_stack[ply] with ply == 64.
```

Conclusion: the root aspiration diagnosis is useful, but disabling TT cutoffs
inside the beta retry is too invasive under time controls.  Future attempts
should avoid changing completed-depth behavior first, and should include an
explicit ply guard if any retry path can extend the tree near `MAX_PLY`.

## Accepted: Max-Ply Search Guard

The rejected fail-low retry experiment exposed a real robustness hole: a timed
search reached `ply == 64` and crashed when `negamax()` wrote
`static_eval_stack[ply]`, whose valid indexes are `0..<64`.

Change: both `negamax()` and `quiescence()` now stop expanding when
`ply >= MAX_PLY` and return a static evaluation.  Tablebase/TT results can
still answer before this guard in the main search path; the guard protects the
fixed ply-indexed search state and prevents qsearch from extending beyond the
same bound.

Verification:

```text
odin build . -out:mantis_ply_guard -o:speed
python3 tactical_regression.py --binary ./mantis_ply_guard
python3 correctness_test.py --binary ./mantis_ply_guard --random 20 --seed 0603
python3 stats_benchmark.py --binary ./mantis_ply_guard --limit 3 --timeout 90
python3 compare_candidates.py --baseline ./mantis_after_revert \
  --candidate ./mantis_ply_guard --depths 6 --timeout 90 \
  --csv /tmp/mantis_ply_guard_depth6_compare.csv
```

Summary: tactical regression passed; randomized perft passed; short stats
benchmark was normal; depth-6 comparison over 44 positions had `0/44` bestmove
changes, `0` node changes, and `0 cp` score delta.

## Accepted: Expanded UCI Tuning Surface

Change: expose the rest of the bounded `SearchParams` controls as UCI spin
options, including aspiration windows, null-move depth, probcut, internal
iterative reductions, singular-extension thresholds, LMR adjustments, LMP
depth, razoring, delta pruning, SEE pruning, continuation-history scaling, and
contempt.  The local Nevergrad/random tuner now maps the same 30 parameters to
UCI `--option-a` arguments and defaults fresh runs to the existing
`2moves_v1.epd` opening file.

The UCI `setoption` parser now finds the `value` token and joins the preceding
tokens into the full option name, which fixes the pre-existing multi-word
option path for `Move Overhead` and keeps path-valued options working.  The
tuner also filters incompatible resume entries so old 8-parameter progress
files cannot seed or short-circuit the expanded surface.

Verification:

```text
odin build . -out:mantis_uci_tune_surface -o:speed
python3 -m py_compile nevergrad_tuner.py
UCI smoke: Move Overhead plus representative positive and negative tuning
  options parsed, then returned uciok/readyok.
UCI option list: AspirationWindow, ProbcutMargin, ContinuationScoreDiv, and
  Move Overhead advertised with expected bounds.
python3 compare_candidates.py --baseline ./mantis_ply_guard \
  --candidate ./mantis_uci_tune_surface --depths 6 --timeout 90 \
  --csv /tmp/mantis_uci_tune_surface_depth6_compare.csv
python3 nevergrad_tuner.py --engine ./mantis_uci_tune_surface \
  --baseline ./mantis_uci_tune_surface --optimizer random --budget 1 \
  --games 2 --movetime 20 --concurrency 1 --max-moves 20
```

Summary: depth-6 comparison over 44 positions had `0/44` bestmove changes,
`0` node changes, and `0 cp` score delta.  The tuner smoke passed all 30 UCI
options through `selfplay.py` against `2moves_v1.epd` with `0` illegal moves
and `0` failed games; a stale-resume smoke skipped the incompatible old row
and ran a fresh expanded candidate.

## Accepted: Paired SPSA Tuning Mode

Change: `nevergrad_tuner.py` now includes a dependency-free `--optimizer spsa`
mode.  SPSA keeps the 30 UCI-exposed search parameters on a normalized
`0..1` scale, creates plus/minus perturbation pairs around the current center,
and evaluates the pair directly through `selfplay.py --option-a` and
`--option-b`.  This gives the tuner a standard chess-engine optimization path
without rewriting source files, rebuilding each candidate, or requiring
Nevergrad to be installed.

The tuner now also:

- Stores current search defaults explicitly for SPSA startup.
- Keeps optimizer-specific resume filtering, so random/Nevergrad/SPSA progress
  rows are not mixed.
- Uses `tuning_progress_spsa.json` as the default SPSA progress file.
- Prints the selected progress file in the run banner.

Verification:

```text
python3 -m py_compile nevergrad_tuner.py
python3 nevergrad_tuner.py --help
python3 nevergrad_tuner.py --engine ./mantis_uci_tune_surface \
  --baseline ./mantis_uci_tune_surface --optimizer spsa --budget 1 \
  --games 2 --movetime 20 --concurrency 1 --max-moves 20 \
  --output /tmp/mantis_spsa_smoke_best_after_progress.json \
  --resume /tmp/mantis_spsa_smoke_progress_after_progress.json --seed 11
python3 nevergrad_tuner.py --engine ./mantis_uci_tune_surface \
  --baseline ./mantis_uci_tune_surface --optimizer spsa --budget 2 \
  --games 2 --movetime 20 --concurrency 1 --max-moves 20 \
  --output /tmp/mantis_spsa_smoke_best_resume.json \
  --resume /tmp/mantis_spsa_smoke_progress.json --seed 7
python3 nevergrad_tuner.py --engine ./mantis_uci_tune_surface \
  --baseline ./mantis_uci_tune_surface --optimizer random --budget 1 \
  --games 2 --movetime 20 --concurrency 1 --max-moves 20 \
  --output /tmp/mantis_random_regression_best.json \
  --resume /tmp/mantis_random_regression_progress.json --seed 13
```

Summary: SPSA smoke passed all 30 plus/minus UCI options through self-play with
`0` illegal moves and `0` failed games.  SPSA resume loaded the prior row and
continued at iteration 2.  Random-mode regression still completed through the
shared UCI option path.

## Accepted: Cutechess PGN Eval Parsing Guard

External calibration smoke used the current `./mantis` build from `2c98c21`
against the local Stockfish dev binary with UCI strength limiting:

```text
odin build . -out:mantis -o:speed -microarch:native
cutechess-cli ... SF2700 UCI_Elo=2700 ... -each tc=1+0.01 -games 8
  Mantis: 1W-6L-1D, score 18.8%, Elo diff -254.7
cutechess-cli ... SF2400 UCI_Elo=2400 ... -each tc=1+0.01 -games 8
  Mantis: 2W-4L-2D, score 37.5%, Elo diff -88.7 +/- 261.3
cutechess-cli ... SF2200 UCI_Elo=2200 ... -each tc=1+0.01 -games 8
  Mantis: 3W-3L-2D, score 50.0%, Elo diff 0.0 +/- 240.4
```

These tiny fast-time-control matches are not a rating claim, but they are
enough to treat the earlier `2700-ish` estimate as unproven and probably
optimistic until longer external gauntlets say otherwise.

Tooling change: `blunder_trace.py` now parses cutechess eval comments such as
`{+0.31/5 0.049s}` and mate scores like `{+M5/10 ...}`, preserving played
depth and time metadata.  Because external PGNs alternate engine comments, the
extractor now tracks whether the previous eval came from a Mantis-named engine
and skips mixed-engine adjacent eval comparisons by default.  The old behavior
is still available behind `--allow-mixed-engine-evals` for diagnostics.

Validation:

```text
python3 -m py_compile blunder_trace.py
python3 blunder_trace.py --pgn /tmp/mantis_vs_sf2400_smoke.pgn \
  --mode worst --limit 8 --threshold-cp 150 \
  --report /tmp/mantis_sf2400_blunders_guarded.md \
  --csv /tmp/mantis_sf2400_blunders_guarded.csv
python3 blunder_trace.py --pgn /tmp/mantis_vs_sf2400_smoke.pgn \
  --mode worst --limit 2 --threshold-cp 150 --allow-mixed-engine-evals \
  --report /tmp/mantis_sf2400_blunders_mixed_explicit.md \
  --csv /tmp/mantis_sf2400_blunders_mixed_explicit.csv
python3 blunder_trace.py --pgn /tmp/mantis_current_meta40_0603.pgn \
  --mode worst --limit 4 --threshold-cp 150 \
  --report /tmp/mantis_selfplay_guarded_blunders.md \
  --csv /tmp/mantis_selfplay_guarded_blunders.csv
```

Summary: the guarded SF2400 extraction skipped all `403` Mantis moves with
mixed-engine adjacent evals and produced `0` candidates.  The explicit mixed
override reproduced the diagnostic candidates.  A Mantis-vs-Mantis self-play
PGN still produced the expected same-engine candidates.

## Accepted: Source-Rescored Blunder Extraction

The external Stockfish-limited smoke PGNs exposed a measurement problem: PGN
comments are not a reliable source of Mantis-perspective before/after evals
when different engines annotate alternating moves, and some future gauntlets may
not contain usable comments at all.

Tooling change: `blunder_trace.py` now supports `--rescore-binary`. In this
mode the tool ignores adjacent PGN eval comments and searches the position
before and after every Mantis move with the requested UCI engine. Scores are
converted into Mantis perspective by using the before-position side-to-move
score directly and negating the after-position score, since the opponent is then
to move. Terminal positions are handled directly from python-chess outcomes.

The rescoring path:

- disables `OwnBook` for the rescoring engine before applying explicit options;
- clears hash between rescored positions by default, with
  `--keep-rescore-hash` available for diagnostics;
- supports fixed-depth and movetime rescoring through `--rescore-depth` and
  `--rescore-movetime-ms`;
- writes `eval_source`, `eval_search`, and before/after node/time metadata to
  CSV reports.

The shared `stats_benchmark.parse_stats()` parser now also preserves UCI mate
scores as large centipawn equivalents so rescored reports do not silently drop
mate-only searches.

Smoke command:

```sh
python3 blunder_trace.py \
  --pgn /tmp/mantis_vs_sf2400_smoke.pgn \
  --rescore-binary ./mantis \
  --rescore-depth 2 \
  --rescore-timeout 10 \
  --threshold-cp 150 \
  --mode worst \
  --limit 3 \
  --report /tmp/mantis_sf2400_rescore_smoke.md \
  --csv /tmp/mantis_sf2400_rescore_smoke.csv
```

Result:

```text
Games parsed: 8
Games with Mantis: 8
Mantis moves rescored: 407
Mantis moves missing rescored evals: 0
Mantis eval drops: 306
Candidates at threshold: 21
Candidates searched in this report: 3
```

This shallow depth-2 run is only a plumbing validation, not a tactical oracle.
The important outcome is that future external gauntlets can now be mined for
Mantis move-loss candidates without trusting mixed-engine PGN comments.
