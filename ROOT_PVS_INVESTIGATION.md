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
| `mantis_root_pvs_protected` | final depth only | non-PV, protected child | 2/44 | +18.27% | -1.45% | 266 cp |
| `mantis_root_pvs_depth8` at depth 8 | final depth only, depth >= 8 | PV-safe, protected child | 4/44 | +9.13% | -10.88% | 229 cp |

## Findings

The main divergence is accumulated search-state feedback across iterative deepening. Running root PVS at every depth changes TT contents, history/countermove updates, and later root move ordering before the final depth is reached. That is why forcing the null child to remain PV-safe did not fix the full root-PVS version.

Restricting root PVS to only the final iteration nearly eliminated best-move churn. This points away from a simple root move ordering bug and toward shared state pollution from earlier narrow-window searches.

True non-PV root children are still risky. The final-depth-only non-PV variant was faster, but it still produced a large score swing on this position:

```text
r4rk1/1pp2ppp/2p2n2/p2b4/8/3P2P1/P1P2P1P/R1B1R1K1 w - - 0 22
```

At depth 6, the accepted search chose `c1b2`, while final-depth-only non-PV root PVS chose `c2c4` with a `-386 cp` score delta. That is the clearest evidence that at least one non-PV pruning/reduction path can fail low too aggressively for a root child.

A later protected-root-child attempt disabled TT cutoffs/stores, NMP, RFP,
ProbCut, razoring, futility, LMP, singular extension, and LMR at the protected
root child itself. This still failed parity. At depth 6 it changed 2/44 best
moves and had a 266 cp maximum score delta. Adding a depth >= 8 activation
guard made depth 6 identical, but the real depth 8 test still changed 4/44 best
moves, including opening positions:

```text
rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1
r1bqk2r/ppp2ppp/2n2n2/3pp3/1b1PP3/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 5 6
r1bq1rk1/1pp2ppp/p1np1n2/4p3/2PPP3/2N2N2/PP2BPPP/R1BQ1RK1 w - - 3 9
```

That result argues against landing root PVS as a local root-only patch. The
engine's current root search, TT replacement, aspiration behavior, and
PV/non-PV scoring are too coupled for this optimization to be added safely in
isolation.

## Conclusion

Do not enable root PVS globally yet.

## Root Trace Tool

`trace-root` is now available as a diagnostic command:

```sh
./mantis_root_trace trace-root 8 fen "r1bqk2r/ppp2ppp/2n2n2/3pp3/1b1PP3/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 5 6"
```

It warms the TT to `depth - 1`, sorts the root moves, then prints each legal
root move's wide-window score beside a synthetic null-window probe from the
same pre-move TT/search state. `MISS_FAIL_HIGH` marks a move where the
wide-window score raises root alpha but the null-window probe would not have
triggered a re-search.

The trace must refresh NNUE accumulators after parsing the FEN and must sort
the target-depth root moves with the previous completed depth's best move.
Without both details, the diagnostic can disagree with normal UCI search order.

## Trace Findings

Using the corrected trace on the known churn positions:

| FEN | Depth | Warmup Best | Exact Trace Best | Misses | Finding |
| --- | ---: | --- | --- | ---: | --- |
| `r4rk1/1pp2ppp/2p2n2/p2b4/8/3P2P1/P1P2P1P/R1B1R1K1 w - - 0 22` | 6 | `c2c4` | `c1b2` | 2 | Non-PV null-window root child can miss a fail-high. |
| `rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1` | 8 | `g8f6` | `g8f6` | 0 | No local null-window miss in the corrected trace. |
| `r1bqk2r/ppp2ppp/2n2n2/3pp3/1b1PP3/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 5 6` | 8 | `e4d5` | `e4d5` | 0 | No local null-window miss in the corrected trace. |
| `r1bq1rk1/1pp2ppp/p1np1n2/4p3/2PPP3/2N2N2/PP2BPPP/R1BQ1RK1 w - - 3 9` | 8 | `c1g5` | `c1g5` | 0 | No local null-window miss in the corrected trace. |

The clearest local root-PVS bug is the depth-6 endgame case: after `c2c4`
sets alpha, both `c2c3` and especially the accepted `c1b2` fail low in the
null-window probe even though their wide-window scores raise alpha. The depth-8
opening churn is probably not this same local root-child failure; it points
back toward TT/aspiration/search-state interaction.

## Child Probe Findings

`trace-root-child` is now available for focused ablation at one root move:

```sh
./mantis_rfp_root_guard trace-root-child 6 c1b2 fen "r4rk1/1pp2ppp/2p2n2/p2b4/8/3P2P1/P1P2P1P/R1B1R1K1 w - - 0 22"
```

Before the RFP guard, the failing null probes returned after two nodes and did
not use TT cutoffs, LMR, futility pruning, or LMP. They did use reverse
futility pruning at the root child:

| Move | Full Score | Baseline Null | No RFP Null | Finding |
| --- | ---: | ---: | ---: | --- |
| `c2c3` | `-1621` | `-1976` | `-1817` | Disabling RFP makes the null probe raise alpha. |
| `c1b2` | `-1342` | `-1730` | `-1620` | Disabling RFP makes the null probe raise alpha. |

The fix is intentionally narrow: RFP is skipped at `ply == 1`. Root children
are PV-significant even when a root-PVS implementation probes later moves with
a null window. This guard leaves the accepted full-window root search unchanged
but removes this local root-PVS fail-low trap. After the guard:

```text
trace-root depth 6 endgame: misses=0, researches=3
```

The safer future route is now:

1. Do not spend more time on root PVS until the underlying PV/non-PV score
   stability is improved.
2. Use `trace-root` on positions with root-PVS best-move churn and inspect any
   `MISS_FAIL_HIGH` rows before changing search behavior.
3. Retry the safest root-PVS experiment with the RFP root-child guard in place,
   starting with final-depth-only root PVS.
4. For remaining depth-8 opening churn, audit TT bound storage/replacement and
   aspiration re-search state; root PVS should be retried only after the trace
   shows null-window probes are reliable.
5. Require zero best-move changes and a small score-delta ceiling before any
   version is accepted.

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
