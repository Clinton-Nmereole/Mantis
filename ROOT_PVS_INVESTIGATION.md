# Root PVS Investigation

Date: 2026-05-29

Baseline: `./mantis_movetime_fill`

Harness:

```sh
python3 compare_candidates.py \
  --baseline ./mantis_movetime_fill \
  --candidate ./CANDIDATE \
  --depths 6 \
  --timeout 60 \
  --fail-on-score-delta 25
```

The goal was to explain why a normal root PVS optimization changed many fixed-depth best moves. The accepted root search currently searches every legal root move with a full child window. Root PVS searches later root moves first with a null window, then re-searches only if the null-window score raises alpha.

## Results

| Candidate | Root PVS Scope | Null Child Mode | Best Move Changes | Nodes | Time | Max Score Delta |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| `mantis_root_pvs_safe` | every iterative depth | non-PV | 14/44 | -16.97% | -26.61% | 292 cp |
| `mantis_root_pvs_pvnull` | every iterative depth | PV-safe | 13/44 | +32.11% | +9.23% | 264 cp |
| `mantis_root_pvs_finalonly_pvnull` | final depth only | PV-safe | 1/44 | +14.09% | -5.85% | 266 cp |
| `mantis_root_pvs_finalonly_nonpv` | final depth only | non-PV | 3/44 | +0.42% | -18.55% | 386 cp |

## Findings

The main divergence is accumulated search-state feedback across iterative deepening. Running root PVS at every depth changes TT contents, history/countermove updates, and later root move ordering before the final depth is reached. That is why forcing the null child to remain PV-safe did not fix the full root-PVS version.

Restricting root PVS to only the final iteration nearly eliminated best-move churn. This points away from a simple root move ordering bug and toward shared state pollution from earlier narrow-window searches.

True non-PV root children are still risky. The final-depth-only non-PV variant was faster, but it still produced a large score swing on this position:

```text
r4rk1/1pp2ppp/2p2n2/p2b4/8/3P2P1/P1P2P1P/R1B1R1K1 w - - 0 22
```

At depth 6, the accepted search chose `c1b2`, while final-depth-only non-PV root PVS chose `c2c4` with a `-386 cp` score delta. That is the clearest evidence that at least one non-PV pruning/reduction path can fail low too aggressively for a root child.

## Conclusion

Do not enable root PVS globally yet.

The safer future route is:

1. Reintroduce root PVS only on the final iterative-deepening depth.
2. Treat root null-window children as a protected context.
3. Initially disable or soften non-PV pruning at protected root children, especially NMP, RFP, ProbCut, razoring, futility, LMP, and aggressive LMR.
4. Re-enable those mechanisms one at a time behind the fixed-depth parity guard.
5. Require zero best-move changes and a small score-delta ceiling before any version is accepted.

Recommended acceptance command for the next attempt:

```sh
python3 compare_candidates.py \
  --baseline ./mantis_movetime_fill \
  --candidate ./mantis_next_candidate \
  --depths 6 7 \
  --timeout 90 \
  --fail-on-bestmove-change \
  --fail-on-score-delta 25
```

