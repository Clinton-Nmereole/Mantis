# Quiet History Investigation

Date: 2026-05-30

Baseline: `./mantis_order_scaled`

The target was stale or overgrown quiet-history ordering. Mantis already has a
configured `age_history` helper using `history_decay_numer/history_decay_denom`
(`9/10`), but it was intentionally not called after these tests.

## Accepted: Gravity Quiet-History Update

Candidate: `./mantis_history_gravity`

Change: replace raw additive quiet-history updates with a gravity-style update:

```text
history += bonus - history * abs(bonus) / history_max
```

This keeps the sign and direction of each bonus/malus, but naturally reduces
the effect as an entry approaches saturation. Capture history and continuation
history were left unchanged in this pass.

Result: accepted.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_order_scaled` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_order_scaled` | 0/44 | 0 cp | -0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_history_gravity` | Passed |
| `python3 correctness_test.py --binary ./mantis_history_gravity` | Passed |
| `./mantis_history_gravity validate-qcaptures 4` | Passed |

The previously dangerous benchmark no longer revives `a2a3`:

```text
r3kb1r/pppb1ppp/2np4/4p3/1PP1P3/5N2/PB3PPP/RN1QKB1R w KQkq - 2 9
trace-order depth 6: d1d2 remains TT/root best, a2a3 total=-1128
```

## Accepted: Gravity Capture-History Update

Candidate: `./mantis_capture_gravity`

Change: route capture-history updates through the same `history_gravity_update`
helper used for quiet history. Continuation history was left unchanged.

Result: accepted.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_history_gravity` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_history_gravity` | 0/44 | 0 cp | +0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_capture_gravity` | Passed |
| `python3 correctness_test.py --binary ./mantis_capture_gravity` | Passed |
| `./mantis_capture_gravity validate-qcaptures 4` | Passed |

The older-baseline depth-6 profile remains unchanged from the accepted quiet
history candidate:

```text
mantis_movetime_fill vs mantis_capture_gravity depth 6:
bestmove_changes=1/44, changed opening move b1c3 -> g1f3
```

## Accepted: Continuation-History Score Diagnostics

Candidate: `./mantis_cont_stats`

Change: add behavior-neutral search stats for continuation-history score
influence during quiet move ordering. The engine now reports continuation-score
probe count, nonzero count, sign split, and absolute score sum. The benchmark
harness summarizes those fields.

Result: accepted as a diagnostic checkpoint.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_capture_gravity` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_capture_gravity` | 0/44 | 0 cp | +0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_stats` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_stats` | Passed |
| `./mantis_cont_stats validate-qcaptures 4` | Passed |

Sample depth-6 benchmark over the first 8 positions:

```text
cont_updates:             1677
cont_maluses:             1742
cont_score_probes:      144135
cont_score_nonzero:        163
cont_score_nonzero_pct:    0.1
cont_score_pos_pct:       80.4
cont_score_neg_pct:       19.6
cont_score_avg_abs:        2.0
```

The current continuation-history score barely influences ordering in this
opening-heavy sample: only 0.1% of quiet scoring probes saw a nonzero
continuation contribution after scaling. Do not retune continuation history
yet; next step is to measure where the table is written versus where it is
queried, because the update path is active while the read path is mostly cold.

## Rejected: Symmetric Per-Depth Aging

Change tested: call `age_history(st)` after every fully completed iterative
deepening depth.

Result: rejected.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_order_scaled` | 7/44 | 1634 cp | +3.85% |
| depth 7 vs `mantis_order_scaled` | 7/44 | 292 cp | -0.07% |

The failure mode was exactly the one we wanted to avoid: quiet moves such as
`a2a3` resurfaced as best moves in opening/middlegame benchmarks. Symmetric
aging reduces both good bonuses and bad maluses, so it weakens the penalties
that currently suppress poor quiets.

Notable depth-6 failures:

```text
r3kb1r/pppb1ppp/2np4/4p3/1PP1P3/5N2/PB3PPP/RN1QKB1R w KQkq - 2 9
d1d2 -> a2a3, score_delta=+872

r1bq1rk1/1pp2ppp/p1np1n2/4p3/2PPP3/2N2N2/PP2BPPP/R1BQ1RK1 w - - 3 9
d4e5 -> a2a3, score_delta=-119
```

## Rejected: Positive-Only Per-Depth Aging

Change tested: decay only positive history entries after each completed depth,
leaving negative maluses intact.

Result: rejected.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_order_scaled` | 5/44 | 872 cp | +4.36% |
| depth 7 vs `mantis_order_scaled` | 4/44 | 292 cp | -0.15% |

This was better than symmetric aging, but still revived bad quiet moves and
created large endgame/tactical swings.

Notable failures:

```text
r3kb1r/pppb1ppp/2np4/4p3/1PP1P3/5N2/PB3PPP/RN1QKB1R w KQkq - 2 9
d1d2 -> a2a3, score_delta=+872

r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3
g1f3 -> a2a4, score_delta=-45
```

## Conclusion

Do not enable blunt quiet-history aging.

The current history table is not merely stale noise; its negative maluses are
compensating for weaknesses in root/opening ordering. Gravity-style updates are
safe for quiet history because they reduce saturation pressure during updates
without globally weakening existing maluses.

Future work:

- Measure continuation-history write/read alignment before changing update
  weights.
- Measure root quiet candidates with `trace-order` before changing history.
