# Quiet History Investigation

Date: 2026-05-30

Baseline: `./mantis_order_scaled`

The target was stale or overgrown quiet-history ordering. Mantis already has a
configured `age_history` helper using `history_decay_numer/history_decay_denom`
(`9/10`), but it was intentionally not called after these tests.

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
compensating for weaknesses in root/opening ordering. Future work should focus
on the history update formula itself rather than decaying the whole table:

- Use a gravity-style update that scales bonus by existing magnitude.
- Track separate quiet malus quality instead of weakening maluses over time.
- Measure root quiet candidates with `trace-order` before changing history.
