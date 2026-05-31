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
