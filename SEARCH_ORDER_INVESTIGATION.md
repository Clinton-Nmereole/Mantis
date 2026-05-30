# Search Order Investigation

Date: 2026-05-29

Baseline: `./mantis_movetime_fill`

Candidate: `./mantis_order_trace`

## Accepted Change

Added a root move ordering diagnostic:

```sh
./mantis_order_trace trace-order 6
./mantis_order_trace trace-order 6 fen "FEN"
```

The command warms the search to `depth - 1`, sorts the next root move list, and
prints each legal root move with its total ordering score and visible
components: TT tag, SEE, quiet history, capture history, opening bias, killer
tag, victim/attacker values, promotion bonus, and capture flag.

The trace exposed a concrete opening-ordering bug: the knight development bonus
used home-rank squares (`c1/f1/c8/f8`) instead of development squares
(`c3/f3/c6/f6`), and the rim penalty used corner squares instead of
`a3/h3/a6/h6`.

The accepted fix:

- Keeps the existing pawn root bias behavior unchanged.
- Corrects knight development targets to `c3/f3/c6/f6`.
- Corrects knight rim targets to `a3/h3/a6/h6`.
- Applies the knight-specific bias only through fullmove 12.

Starting-position trace now shows `Nf3/Nc3` receiving `+350`, `Na3/Nh3`
receiving `-200`, and `a2a3` still receiving the existing `-1200` wing-pawn
penalty.

## Follow-Up: Late Pawn Bias Scaling

Candidate: `./mantis_order_scaled`

The next pass kept the accepted knight fix and softened pawn-root bias after
the opening instead of deleting it. Pawn moves still receive the same target
preferences through fullmove 12, but after that the pawn opening-bias term is
scaled by `1/4`.

This is intentionally milder than a hard phase gate. A move-14 trace position
previously gave `e3e4` a full `+1200` opening bonus even though it was no
longer an opening move:

```text
rn2k2r/p4ppp/1q2p3/2bp2B1/1p6/4P3/PP1N1PPP/R2QK2R w KQkq - 0 14
```

With scaling, the trace reports:

```text
e3e4 opening=300
f2f3 opening=112
a2a3 opening=-300
```

So the bias remains a nudge, but no longer dominates genuine history by an
opening-sized margin in middlegame root ordering.

Verification against the previous accepted candidate:

| Compare | Best Move Changes | Max Score Delta | Nodes |
| --- | ---: | ---: | ---: |
| `mantis_order_trace` vs `mantis_order_scaled`, depth 6 | 0/44 | 0 cp | +0.07% |
| `mantis_order_trace` vs `mantis_order_scaled`, depth 7 | 0/44 | 0 cp | +0.07% |

Verification against `mantis_movetime_fill` keeps the same opening-only
bestmove changes as the previous accepted candidate:

| Compare | Best Move Changes | Changed Positions |
| --- | ---: | --- |
| depth 6 | 1/44 | opening only |
| depth 7 | 2/44 | opening only |

## Rejected Variants

Aspiration full-window recovery was tested before this pass and rejected. It
changed `8/44` depth-6 best moves, increased nodes by `9.83%`, and produced a
large aggregate score swing.

Gating all opening bias to fullmove 12 was also rejected. It looked principled,
but disturbed non-opening positions that currently depend on the existing pawn
ordering behavior:

| Variant | Depth | Best Move Changes | Notes |
| --- | ---: | ---: | --- |
| Gate all pawn+knight opening bias to fullmove 12 | 6 | 4/44 | Changed several middlegames. |
| Gate all pawn+knight opening bias to fullmove 12 | 7 | 5/44 | Changed the known endgame benchmark with a `-147 cp` score delta. |

Restricting pawn bias to only home-rank pawns was also rejected. It removed the
`e3e4` leak completely, but depth 7 changed `4/44` moves against
`mantis_order_trace`, including a `275 cp` score delta in a middlegame
benchmark. Soft scaling is safer than deleting the term.

## Verification

Accepted candidate results:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_order_trace` | Passed |
| `python3 correctness_test.py --binary ./mantis_order_trace` | Passed |
| `./mantis_order_trace validate-qcaptures 4` | Passed |
| Depth-6 compare vs `mantis_movetime_fill` | 1/44 bestmove change, opening only |
| Depth-7 compare vs `mantis_movetime_fill` | 2/44 bestmove changes, opening only |

Follow-up candidate results:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_order_scaled` | Passed |
| `python3 correctness_test.py --binary ./mantis_order_scaled` | Passed |
| `./mantis_order_scaled validate-qcaptures 4` | Passed |
| Depth-6 compare vs `mantis_order_trace` | 0/44 bestmove changes, 0 cp max score delta |
| Depth-7 compare vs `mantis_order_trace` | 0/44 bestmove changes, 0 cp max score delta |

Depth-6 changed move:

```text
rnbqkbnr/pppp1ppp/8/4p3/2P5/8/PP1PPPPP/RNBQKBNR w KQkq - 0 2
b1c3 -> g1f3, score_delta=+13
```

Depth-7 changed moves:

```text
r1bqkbnr/pp1ppppp/2n5/1Bp5/4P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3
a2a4 -> g1f3, score_delta=+15

rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1
g8f6 -> e7e6, score_delta=-1
```

## Next

Use `trace-order` on new bad-game positions before changing move ordering
again. The next likely target is to separate genuine history values from
hard-coded root opening bias so future opening fixes do not leak into tactical
move ordering.

## Follow-Up: Root Quiet Trace Harness

Candidate: `./mantis_asp_retry`

Change: add `root_quiet_trace.py`, a repeatable wrapper around `trace-order`
that runs the benchmark FEN set, parses root quiet ordering components, and
summarizes:

- the highest non-TT quiet in each position,
- watched wing-pawn quiets near the top of the order,
- positive history fighting wing-pawn penalties,
- early quiets dominated by hard-coded opening bias.

Depth-7 run over all 44 benchmark FENs:

```sh
python3 root_quiet_trace.py --binary ./mantis_asp_retry --depth 7 --top 12
```

Result: the old `a2a3` opening-ordering failure is not currently a root
ordering accident. In the known failure FENs, wing pawns remain low-ranked and
penalized; when wing pawns appear at the top in the trace, they are TT/warmup
moves already chosen by the previous search depth rather than quiet candidates
being promoted by sorting.

Notable depth-7 summary:

```text
Wing-pawn watch rows near the top:
#34 rank=04 move=g2g3 total=-1196 hist=+4 opening=-1200
#22 rank=25 move=a2a3 total=-286 hist=+14 opening=-300

Positive history fighting wing-pawn penalties:
#24 rank=27 move=a2a3 total=-826 hist=+374 opening=-1200
#19 rank=28 move=a2a3 total=-843 hist=+357 opening=-1200
#13 rank=31 move=a2a3 total=-1020 hist=+180 opening=-1200
```

The stats benchmark now also prints `asp_low`, `asp_high`, and `asp_retry`.
A depth-9 fixed suite showed `asp_retry=1` over 44 positions, so the scoped
aspiration retry remains a rare correction rather than a frequent search path.

Depth 9 also surfaced two remaining `a2a3` best moves:

```text
16: r4rk1/ppp1qppp/2n1p3/3p4/1b1P4/2N1PN2/PP2BPPP/R2Q1RK1 w - - 2 9
19: r1bq1rk1/1pp2ppp/p1np1n2/4p3/2PPP3/2N2N2/PP2BPPP/R1BQ1RK1 w - - 3 9
```

`trace-order` shows both are TT moves from the depth-8 warmup despite the
`-1200` wing-pawn opening penalty. `trace-root` full-score diagnostics prefer
other moves at depth 9 (`g2g3` in position 16 and `c4c5` in position 19), so
the next target is root full-score versus normal root search divergence, not
another root quiet-ordering tweak.

## Follow-Up: Scoped Root Fail-Low Verification

Candidate: `./mantis_root_verify`

Change: add a final-depth-only root verification guard for the stale TT/warmup
move case. The guard is deliberately narrow:

- first PV only,
- final requested depth only,
- depth 9 or deeper,
- root TT move has a negative opening-bias score,
- the root TT move failed low during aspiration recovery,
- recovery still kept that same TT move as best.

When all of those conditions hold, Mantis restores a pre-root TT snapshot and
runs a full-window verification pass from a cloned search thread. The verifier
does not repeat the rejected all-move prototype. It checks the stale TT move,
promotions, non-losing captures by SEE, and quiet moves with positive history.

Rejected prototype:

```text
depth 9 all-move verifier vs mantis_asp_retry:
bestmove_changes=2/44, nodes +33.44%, time +34.52%
```

Accepted narrower result:

```text
depth 8 vs mantis_asp_retry:
bestmove_changes=0/44, nodes +0.00%, max_score_delta=0

depth 9 vs mantis_asp_retry:
bestmove_changes=2/44, nodes +3.63%, time +4.20%, max_score_delta=37
16: a2a3 -> g2g3
19: a2a3 -> c4c5
```

The target-only depth-9 benchmark now fixes both remaining `a2a3` cases:

```text
pos 16: best=g2g3, nodes=192597
pos 19: best=c4c5, nodes=83708
asp_verify=2
```

Regression checks:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_root_verify` | Passed |
| `python3 correctness_test.py --binary ./mantis_root_verify` | Passed |
| `./mantis_root_verify validate-qcaptures 4` | Passed |

This is still a tactical safety valve, not a broad root-PVS solution. It is
worth keeping because it corrects the known bad opening TT cases at a small
measured cost, while staying inactive at depth 8 and below.
