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

## Accepted: Raw Continuation-History Alignment Diagnostics

Candidate: `./mantis_cont_raw_stats`

Change: split continuation-history diagnostics into raw table hits versus
scaled move-ordering contribution. Also track whether continuation writes and
post-write table values are below the `/16` visibility threshold. Diagnostic
arithmetic is guarded by `search_stats_enabled` so normal play avoids the extra
stats work.

Result: accepted as a diagnostic checkpoint.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_cont_stats` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_cont_stats` | 0/44 | 0 cp | +0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_raw_stats` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_raw_stats` | Passed |
| `./mantis_cont_raw_stats validate-qcaptures 4` | Passed |

Sample depth-6 benchmark over the first 8 positions:

```text
cont_score_probes:        144135
cont_raw_nonzero:          17142
cont_raw_nonzero_pct:       11.9
cont_raw_under_pct:         99.0
cont_raw_pos_pct:            6.1
cont_raw_neg_pct:           93.9
cont_raw_avg_abs:            2.9
cont_scaled_nonzero:         163
cont_scaled_nonzero_pct:     0.1
cont_store_bonus_under_pct:  99.6
cont_store_result_under_pct: 83.9
cont_store_visible:          549
```

Conclusion: the read path is not dead. Raw continuation-history hits appear on
11.9% of quiet scoring probes in this opening sample, but 99.0% of those raw
hits are too small to survive the `/16` divisor. The active issue is muted
signal strength, not missing write/read alignment.

## Accepted: Conservative Continuation-History Divisor

Candidate: `./mantis_cont_div14`

Change: make the continuation-history ordering divisor explicit as
`params.continuation_score_div`, and set it to `14` instead of the previous
hard-coded `/16`. This is a deliberately mild amplification of the continuation
signal.

Result: accepted.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_cont_raw_stats` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_cont_raw_stats` | 0/44 | 0 cp | -0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_div14` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_div14` | Passed |
| `./mantis_cont_div14 validate-qcaptures 4` | Passed |

Sample depth-6 benchmark over the first 8 positions:

```text
cont_raw_nonzero_pct:       11.9
cont_raw_under_pct:         98.8
cont_scaled_nonzero:         207
cont_scaled_nonzero_pct:     0.1
cont_store_result_under_pct: 81.9
cont_store_visible:          619
```

This is intentionally small: the sample increases visible continuation scores
from 163 to 207 without changing benchmark best moves or scores at depths 6/7.

## Diagnostic: Child Continuation-Ordering Trace

Candidate: `./mantis_cont_trace`

Change: add `trace-continuation <depth> <rootmove> fen "<FEN>"`. The command
warms the search to `depth - 1`, restores a clean root board, makes the chosen
root move, then prints child move ordering with raw continuation score and
hypothetical `/16`, `/14`, `/12`, and `/8` totals.

Result: accepted as a diagnostic checkpoint.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_cont_div14` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_cont_div14` | 0/44 | 0 cp | +0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_trace` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_trace` | Passed |
| `./mantis_cont_trace validate-qcaptures 4` | Passed |

Sensitive FEN:

```text
r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3
```

Root trace after depth-6 warmup still prefers `g1f3`; `b1c3` is nearby only
because both receive the same root opening bias:

```text
g1f3 total=20000 tag=tt
b1c3 total=339 hist=-11 opening=350
```

First child trace does not explain the rejected `/12` flip:

```text
after g1f3: g8f6 tag=tt/counter raw_cont=136 cont_used=false
after g1f3: e7e6 raw_cont=27 total14=400 total12=401 total8=402
after b1c3: c6d4 tag=counter raw_cont=28 cont_used=false
after b1c3: e7e6 raw_cont=-2 total14=399 total12=399 total8=399
```

Conclusion: the dangerous `/12` and `/8` changes are not caused by the first
child ply's ordinary quiet ordering. The high-impact continuation entries at
that ply are masked by TT/counter/killer stages, and the remaining quiet
continuation deltas are only a few ordering points. The instability is likely
deeper in the tree, after the TT/counter move is made.

## Diagnostic: Deeper Continuation-Line Trace

Candidate: `./mantis_cont_line_trace`

Change: add `trace-continuation-line <depth> <rootmove> [reply] fen "<FEN>"`.
The command warms the search to `depth - 1`, follows the selected root move,
then follows either the child TT move, child counter move, first sorted legal
move, or an explicit reply. It then prints the next ordering layer with raw
continuation score and hypothetical `/16`, `/14`, `/12`, and `/8` totals.

Result: accepted as a diagnostic checkpoint.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_cont_trace` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_cont_trace` | 0/44 | 0 cp | +0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_line_trace` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_line_trace` | Passed |
| `./mantis_cont_line_trace validate-qcaptures 4` | Passed |

Sensitive FEN, depth 7, after depth-6 warmup:

```text
g1f3 -> g8f6: next_tt=b5c6, next_counter=e4e5
b1c3 -> g8f6: next_tt=b5c6, next_counter=e4e5
b1c3 -> c6d4: explicit counter branch
```

The deeper ordering layer still does not explain the rejected `/12` flip:

```text
g1f3 g8f6: e4e5 tag=counter raw_cont=6 cont_used=false
g1f3 g8f6: f3d4 raw_cont=-1 total16=136 total14=136 total12=136 total8=136

b1c3 g8f6: e4e5 tag=counter raw_cont=6 cont_used=false
b1c3 g8f6: c3d5 raw_cont=0 total16=97 total14=97 total12=97 total8=97

b1c3 c6d4: quiet layer raw_cont=0 for all listed non-killer quiets
```

Conclusion: the sensitive `/12` instability is probably not a simple local
continuation-ordering bump on the first two plies. The visible continuation
signal along the natural TT line is either masked by TT/counter/killer stages
or too small to alter ordering even at `/8`. The next likely culprit is dynamic
search feedback deeper in the root child search: a small continuation divisor
change may alter a later cutoff, which then changes the returned root score.

## Diagnostic: Continuation Divisor Divergence Trace

Candidate: `./mantis_cont_diverge`

Change: add `trace-continuation-divergence <depth> [div_a div_b] fen "<FEN>"`.
The command defaults to `/14` vs `/12`, runs both divisors from clean TT state,
uses the normal depth-1 warmup, follows the root aspiration re-search path, and
prints the first root child whose phase, move order, score, or node counters
diverge. The trace also refreshes NNUE accumulators after restoring the root
board from the warmup snapshot, fixing a diagnostic-only trace accuracy bug.

Result: accepted as a diagnostic checkpoint.

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 vs `mantis_cont_line_trace` | 0/44 | 0 cp | +0.00% |
| depth 7 vs `mantis_cont_line_trace` | 0/44 | 0 cp | +0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_diverge` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_diverge` | Passed |
| `./mantis_cont_diverge validate-qcaptures 4` | Passed |

Sensitive FEN, depth 7:

```text
r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3
```

The rejected `/12` flip is now explained as an aspiration-phase fork, not a
visible first-ply continuation-ordering bump:

```text
div=14 phase=fail_low_research best=g1f3 best_score=84
div=12 phase=initial best=b1c3 best_score=40
phase_divergence div14=fail_low_research div12=initial
first_score_divergence move=g1f3 div14_idx=1 score=84 div12_idx=1 score=35 delta=-49
```

Interpretation: `/14` fails low in the initial aspiration pass, then re-searches
with a wide lower bound and recovers `g1f3`. `/12` changes the dynamic search
just enough that `b1c3` raises alpha during the initial aspiration pass, so the
root never performs the fail-low re-search that would have recovered the better
move. This makes further continuation-history amplification unsafe until root
aspiration/PVS behavior is made more robust.

## Accepted: Root PV Fail-Low Aspiration Guard

Candidate: `./mantis_root_asp_guard`

Change: add `trace-root-aspiration <depth> [divisor] fen "<FEN>"` and harden
root aspiration handling. During a root aspiration search, if the previous PV
move itself fails low, the root now performs the fail-low recovery search even
when a later root move barely raises alpha. This directly addresses the
`/12` continuation-divisor failure mode where `b1c3` suppressed the recovery
search that would have restored `g1f3`.

Sensitive FEN with divisor `/12`, depth 7:

```text
reason=pv_fail_low_guard
warmup_best=g1f3 pv_initial_score=35 pv_failed_low=true
initial: best=b1c3 best_score=40
fail_low_research: best=g1f3 best_score=105
```

Result: accepted. The fixed-depth suite shows small overhead and no tactical or
correctness regression.

| Compare vs `mantis_cont_diverge` | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 | 0/44 | 3 cp | +0.72% |
| depth 7 | 1/44 | 1 cp | +1.13% |
| depth 8 | 0/44 | 60 cp | +0.60% |

The only best-move change was after `1.d4`, where Black changed from `e7e6`
to the more classical `d7d5` at `+1 cp`.

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_root_asp_guard` | Passed |
| `python3 correctness_test.py --binary ./mantis_root_asp_guard` | Passed |
| `./mantis_root_asp_guard validate-qcaptures 4` | Passed |

## Accepted: Continuation Divisor `/12` Behind Root Guard

Candidate: `./mantis_cont_div12_guard`

Change: set `params.continuation_score_div` from `14` to `12`. This makes
continuation-history ordering slightly more visible now that the root PV
fail-low guard prevents the old `g1f3 -> b1c3` aspiration failure.

Result: accepted. The old sensitive FEN now keeps `g1f3`, and the fixed-depth
suite shows no best-move changes through depth 8.

| Compare vs `mantis_root_asp_guard` | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 | 0/44 | 0 cp | -0.00% |
| depth 7 | 0/44 | 21 cp | +0.10% |
| depth 8 | 0/44 | 19 cp | -0.00% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_cont_div12_guard` | Passed |
| `python3 correctness_test.py --binary ./mantis_cont_div12_guard` | Passed |
| `./mantis_cont_div12_guard validate-qcaptures 4` | Passed |

This supersedes the earlier `/12` rejection below; `/8` remains rejected until
it is retested behind the root guard.

## Rejected: Continuation Divisor `/10`

Candidate: `./mantis_cont_div10_guard`

Change tested: set `params.continuation_score_div` from `12` to `10`.

Result: rejected conservatively. The 44-position fixed-depth suite looked
stable through depth 8, but one benchmark had a large score swing. A targeted
deeper check on that FEN then showed best-move instability at depths 9 and 10.

Target FEN:

```text
r4rk1/1pp2ppp/2p2n2/p2b4/8/3P2P1/P1P2P1P/R1B1R1K1 w - - 0 22
```

Fixed-depth suite:

| Compare vs `mantis_cont_div12_guard` | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 | 0/44 | 0 cp | +0.00% |
| depth 7 | 0/44 | 21 cp | -0.07% |
| depth 8 | 0/44 | 225 cp | +0.04% |

Targeted deeper check:

| Depth | `/12` | `/10` |
| --- | --- | --- |
| 8 | `c1b2`, -1226 cp | `c1b2`, -1451 cp |
| 9 | `c1b2`, -1565 cp | `c1g5`, -1404 cp |
| 10 | `c1b2`, -1588 cp | `c1f4`, -1645 cp |

Keep `/12` as the active continuation divisor for now.

## Rejected: Aggressive Continuation-History Divisors

Candidates: `./mantis_cont_div8`, `./mantis_cont_div12`

Result: rejected under the strict gate.

Both divisors changed the same sensitive opening benchmark at depth 7:

```text
r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3
g1f3 -> b1c3, score_delta=-44
```

The `/8` candidate produced a much larger sample effect
(`cont_scaled_nonzero_pct=1.2`), but the strict compare showed a score-losing
move change. The `/12` candidate reduced the sample effect
(`cont_scaled_nonzero_pct=0.2`) but still produced the same score-losing move
change. Keep further continuation-history amplification gated by this FEN.

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

## Accepted: Scoped Root Aspiration Beta Retry

Candidate: `./mantis_asp_retry`

Change: factor the root move pass into `run_root_search_pass`, then add one
bounded retry for the specific PV fail-low guard case where the guard-triggered
fail-low recovery returns at or above the old beta. The retry opens the upper
bound while keeping the original aspiration alpha, resolving a clipped
beta-bound score without making every ordinary aspiration failure more
expensive.

Sensitive FEN, depth 7:

```text
r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3
```

Trace result:

```text
reason=pv_fail_low_guard
fail_low_research: best=g1f3 best_score=105 root_window=[-50000,105]
retry_reason=fail_low_beta_bound
fail_low_beta_retry: best=g1f3 best_score=114 root_window=[35,50000]
```

An unscoped version that retried every fail-low recovery beta-bound was
rejected first. It changed `5/44` depth-6 best moves and added `+6.38%` nodes.
The accepted version only retries when the previous PV failed low but a later
move kept the initial aspiration pass nominally inside the window.

Fixed-depth suite:

| Compare vs `mantis_cont_div12_guard` | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| depth 6 | 0/44 | 0 cp | +0.00% |
| depth 7 | 0/44 | 9 cp | +0.16% |
| depth 8 | 0/44 | 2 cp | +0.57% |

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_asp_retry` | Passed |
| `python3 correctness_test.py --binary ./mantis_asp_retry` | Passed |
| `./mantis_asp_retry validate-qcaptures 4` | Passed |

## Conclusion

Do not enable blunt quiet-history aging.

The current history table is not merely stale noise; its negative maluses are
compensating for weaknesses in root/opening ordering. Gravity-style updates are
safe for quiet history because they reduce saturation pressure during updates
without globally weakening existing maluses.

Future work:

- Stop increasing continuation-history weight for now; `/10` is unstable.
- Track whether `asp_retry` appears in real games or longer fixed-depth suites.
- Measure root quiet candidates with `trace-order` before changing history
  weights again.
