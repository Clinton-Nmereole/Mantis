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
| 2 | `b6b4` | `e7g5` | `e7g5` | Not reproduced by cold or warm fixed-depth. |
| 3 | `d3f1` | `g5f6` | `g5f6` | Not reproduced by cold or warm fixed-depth. |
| 4 | `e7f7` | `e7f7` | `e7f7` | Still preferred by max depth. |
| 5 | `d1e1` | `e5f3` | `e5g4` | Not reproduced by fixed-depth. |
| 8 | `d7e6` | `f5f4` | `a7a5` | Warm d8 chose PGN, but d10/d12 avoided it. |
| 10 | `c6e5` | `c6e5` | `c6e5` | Still preferred; likely eval/horizon/endgame-search. |

Warm state alone does not explain most first collapses. The bad PGN move
reappears at depth 12 in only the same positions where cold fixed-depth also
likes it. The clearest warm-state effect is round 8, where stateful depth 8
selects the PGN move but deeper stateful searches avoid it.

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
| 2 | `b6b4` | Avoids PGN | PGN from 750ms onward | Warm/timed instability reproduces the game move. |
| 3 | `d3f1` | Avoids PGN | Avoids PGN | Not reproduced; inspect deeper root/eval if needed. |
| 4 | `e7f7` | PGN at 750/1500ms | PGN at 250/1500ms | Unstable timed choice. |
| 5 | `d1e1` | Avoids PGN | Avoids PGN | Not reproduced by timed replay. |
| 8 | `d7e6` | Avoids PGN | PGN at 1500ms | Warm/timed instability reproduces the game move. |
| 10 | `c6e5` | PGN at all budgets | PGN at all budgets | Persistent eval/horizon/endgame-search failure. |

This separates the collapses into two groups:

1. Persistent failures where Mantis likes the PGN move across cold, stateful,
   fixed-depth, and timed probes: rounds 1 and 10.
2. Timed/warm instability where fixed-depth often avoids the PGN move but
   movetime/stateful replay can bring it back: rounds 2, 4, and 8.

## Next

Focus on the timed/warm instability group first. Add a root-move trace mode for
timed/stateful probes that records each root move's score at the budget where
the PGN move is chosen. The first target should be round 2 `b6b4`, because
cold timed avoids it while stateful timed selects it from 750ms onward.
