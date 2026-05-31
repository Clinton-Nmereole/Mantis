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
