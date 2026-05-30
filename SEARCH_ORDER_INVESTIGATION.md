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

## Verification

Accepted candidate results:

| Test | Result |
| --- | --- |
| `python3 tactical_regression.py --binary ./mantis_order_trace` | Passed |
| `python3 correctness_test.py --binary ./mantis_order_trace` | Passed |
| `./mantis_order_trace validate-qcaptures 4` | Passed |
| Depth-6 compare vs `mantis_movetime_fill` | 1/44 bestmove change, opening only |
| Depth-7 compare vs `mantis_movetime_fill` | 2/44 bestmove changes, opening only |

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
