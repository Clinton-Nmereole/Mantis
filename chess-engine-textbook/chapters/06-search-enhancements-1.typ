== Search Enhancements I: Beyond Basic Alpha-Beta

The alpha-beta algorithm (Chapter 5) provides provably optimal pruning, but its efficiency depends critically on move ordering. In this chapter, we examine techniques that extend alpha-beta to extract further performance gains: principal variation search, null-window search, aspiration windows, and the theoretical underpinnings of modern search reduction. These form the foundation upon which late move reductions and other advanced techniques (Chapter 7) are built.

=== The Theoretical Limits: Why Alpha-Beta Can Still Be Beaten

Recall that with perfect move ordering, alpha-beta visits approximately `O(b^(d/2))` nodes—the square root of minimax. For a branching factor of 35 and depth 10, this means about `sqrt(35^10) = 35^5 ≈ 52 million` nodes instead of `35^10 ≈ 2.76 × 10^15`. This is a staggering improvement of nine orders of magnitude.

However, perfect move ordering is an *upper bound* on efficiency. In practice, move ordering is good but not perfect—the best move is found first only 70-90% of the time, depending on the position and ordering heuristics. The techniques in this chapter aim to:

1. Make alpha-beta even more efficient in the common case where the first move IS the best (Principal Variation Search).
2. Narrow the search window to force more cutoffs (Aspiration Windows).
3. Identify moves that can be searched less deeply without affecting the result (theoretical basis for LMR in Chapter 7).

=== Principal Variation Search (PVS): Exploiting the First-Move Heuristic

Principal Variation Search (also called NegaScout) is the single most important enhancement to alpha-beta. The insight is simple: if we assume our move ordering is good—meaning the first move at any node is likely to be the best—then the remaining moves will likely fail low (fail to improve alpha). We can test this hypothesis cheaply using a *null-window search*.

==== Null-Window Search (Zero-Window Search)

A null-window search tests whether a move improves alpha by searching with a window of width zero: `alpha = beta - 1` (or more precisely, the window `(alpha, alpha+1)`). Since the window contains no integer scores, any score `>= alpha+1` is a fail-high (move is better than alpha), and any score `<= alpha` is a fail-low (move is not better than alpha).

```text
function null_window_search(position, depth, beta):
    // Search with window (beta-1, beta)
    return alpha_beta(position, depth, beta-1, beta)
```

The null-window search is faster than a full-window search because:
- Beta cutoffs occur more frequently (the window is small, so more scores exceed beta).
- Fewer nodes need to be searched at full width.

However, a null-window search does NOT return an exact score—it only tells us whether the score is above or below the threshold. If the score is above, we must re-search with a full window to get the exact score.

==== The PVS Algorithm

PVS combines null-window searches with selective re-searches:

```text
function pvs(position, depth, alpha, beta):
    if depth == 0: return evaluate(position)

    best_score = -INFINITY
    first_move = true

    for each move in legal_moves(position):
        make_move(position, move)

        if first_move:
            score = -pvs(position, depth-1, -beta, -alpha)
            first_move = false
        else:
            // Try a null-window search first
            score = -null_window_search(position, depth-1, -alpha)

            // If the null-window search indicates this move might beat alpha,
            // re-search with full window to get exact score
            if score > alpha and score < beta:
                score = -pvs(position, depth-1, -beta, -alpha)

        unmake_move(position)

        if score > best_score:
            best_score = score
        if score > alpha:
            alpha = score
        if alpha >= beta:
            break  // beta cutoff

    return best_score
```

The key insight: the first move is searched with a full window. For all subsequent moves, we first try a cheap null-window search. If the null-window search indicates the move is no better than alpha, we avoid the expensive full-window search. Only when the null-window search surprisingly scores above alpha do we re-search with a full window.

==== Why PVS Works: The Principle of Optimality

In a well-ordered search tree, the first move at each node is typically the best. This means:
- At PV nodes: the first move is the PV move. Subsequent moves are tried but usually fail low. PVS tests them with null-window first, saving work.
- At Cut nodes: the first move (or an early move) causes a beta cutoff. PVS still searches the first move with full window but immediately cuts off.
- At All nodes: all moves fail low. PVS tests each with null-window and never re-searches.

The expected savings: with good move ordering, approximately `(b - 1)/b` of moves are searched with null-window instead of full window, where `b` is the branching factor. For `b ≈ 35`, this means ~97% of moves are searched with the cheaper null-window. In practice, PVS reduces the search tree by another 15-30% compared to plain alpha-beta.

==== Re-Search Overhead

The risk of PVS is that a null-window search fails high (indicating the move IS better than alpha), requiring a full-window re-search. This means the node is searched *twice*. If this happens too frequently, PVS can actually be slower than plain alpha-beta.

The overhead is minimized when:
1. Move ordering is very good (first move IS best → re-searches are rare).
2. The null-window search is implemented efficiently (shallow searches may re-search even more because the null-window result is less reliable).
3. Transposition tables (Chapter 10) cache null-window results, avoiding re-searches.

A common optimization is to add a margin to the null window: instead of `(alpha, alpha+1)`, use `(alpha, alpha+N)` where `N ≈ 50 centipawns`. This "lazy alpha" approach reduces false fail-highs from the null-window search while still providing most of the pruning benefit.

==== Code Implementation

```c
int pvs(Position *pos, int depth, int alpha, int beta, int ply) {
    if (depth == 0) return quiesce(pos, alpha, beta, ply);

    // Check transposition table (Chapter 10)
    TTEntry *tte = probe_tt(pos->hash);
    if (tte && tte->depth >= depth) {
        // Use TT score to narrow window or cause immediate cutoff
        // ...
    }

    MoveList moves;
    generate_moves(pos, &moves);
    score_moves(pos, &moves, ply);  // move ordering!

    int best_score = -INFINITY;
    Move best_move = NO_MOVE;
    int moves_searched = 0;

    for (int i = 0; i < moves.count; i++) {
        if (!make_move(pos, moves.list[i])) continue;
        moves_searched++;

        int score;
        if (moves_searched == 1) {
            // First move: full window
            score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1);
        } else {
            // Later moves: try null window first
            score = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1);
            // If null window fails high, re-search with full window
            if (score > alpha && score < beta) {
                score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1);
            }
        }

        unmake_move(pos);

        if (score > best_score) {
            best_score = score;
            best_move = moves.list[i];
            if (score > alpha) {
                alpha = score;
                // Update PV
                // ...
            }
        }
        if (alpha >= beta) break;
    }

    // Store in transposition table
    store_tt(pos->hash, best_score, depth, best_move, /* flags */);

    return best_score;
}
```

=== Aspiration Windows: Dynamic Window Narrowing

At the root of the search (the position the engine is actually playing from), we initially search with an infinite window `(-INFINITY, +INFINITY)`. But after the first iteration, we have a score from the previous iteration. For the next iteration (deeper search), we can use this score as a guide to narrow the window.

An *aspiration window* is a narrow search window centered on the previous iteration's score. For example, if the previous iteration returned a score of +25 centipawns, we might search the next iteration with the window `(25 - 50, 25 + 50)` = `(-25, +75)`. This narrow window causes more cutoffs, making the search faster.

If the search returns a score within the window, the aspiration was correct and we have our result. If the search returns a score outside the window (fail-high or fail-low), we must re-search with a wider (or infinite) window.

==== Adaptive Aspiration Windows

The simplest approach is to search each iteration with a window of `(prev_score - DELTA, prev_score + DELTA)` where `DELTA` is typically 25-50 centipawns:

```c
int aspiration_search(Position *pos, int depth) {
    int alpha = -INFINITY, beta = +INFINITY;
    int prev_score = 0;

    for (int d = 1; d <= depth; d++) {
        if (d >= 4) {  // Use aspiration only after a few iterations
            alpha = prev_score - ASPIRATION_DELTA;  // e.g., 50
            beta  = prev_score + ASPIRATION_DELTA;
        }

        int score = pvs(pos, d, alpha, beta, 0);

        if (score <= alpha) {
            // Fail-low: score is worse than expected
            alpha = -INFINITY;  // re-search with open lower bound
            score = pvs(pos, d, alpha, beta, 0);
        } else if (score >= beta) {
            // Fail-high: score is better than expected
            beta = +INFINITY;   // re-search with open upper bound
            score = pvs(pos, d, alpha, beta, 0);
        }

        prev_score = score;
    }
    return prev_score;
}
```

==== The Cost of Aspiration Failures

An aspiration failure (score outside the window) requires a re-search, which costs additional time. The trade-off depends on:

- *DELTA size*: Smaller deltas → more failures → more re-searches. Larger deltas → fewer failures → less speedup.
- *Score volatility*: In tactical positions, the score changes significantly between iterations, causing frequent failures and making aspiration windows counterproductive.
- *Iteration depth*: Shallower iterations have more volatile scores, so aspiration is typically only used from depth 4 or 5 onward.

Empirically, aspiration windows with DELTA ≈ 25-50 provide a 10-20% speedup in most positions. Some engines use an adaptive DELTA that expands and contracts based on the frequency of aspiration failures, mimicking a PID controller.

=== Internal Iterative Deepening (IID)

Internal Iterative Deepening addresses a chicken-and-egg problem in PVS: the first move at each node should be the best move (for both PVS efficiency and good move ordering), but we do not know the best move until we have searched the node. At the root, we use iterative deepening (search depth 1, then depth 2, etc.) to get a good first move. IID applies the same idea *inside* the search tree.

If we are at a PV node with depth `d` and no transposition table move is available, we first search the position at depth `d - 2` (or `d/2`) to find a good move, then use that move as the first move for the full-depth search:

```c
if (depth >= 3 && tte->move == NO_MOVE) {
    // No hash move: do internal iterative deepening
    int iid_score = pvs(pos, depth - 2, alpha, beta, ply);
    // Now the TT contains a best move from the shallow search
    // Probe TT again to get it
    tte = probe_tt(pos->hash);
}
```

IID is most valuable at PV nodes deep in the search tree, where the position is unfamiliar and the TT has nothing. It adds overhead (re-searching at reduced depth) but improves move ordering quality, which pays back through better PVS pruning. In modern engines, IID can reduce the search tree by 10-25% compared to searching moves in static order without a TT move.

=== The Concept of Search Instability

One of the subtle challenges in alpha-beta search is *search instability*—the phenomenon where a search at depth `d+1` returns a different best move than the search at depth `d`. This can cause:

1. *Fail-lows at PV nodes*: The previous iteration's best move is suddenly not good enough, requiring expensive re-searches.
2. *Horizon effect artifacts*: Tactical motifs that were invisible at depth `d` suddenly appear at depth `d+1`, invalidating previous conclusions.
3. *Aspiration window failures*: The score changes significantly between iterations.

Search instability is inherent in chess because of tactical discontinuities. A position may look safe at depth 4, but at depth 5, a sacrifice appears that changes the evaluation by several pawns. Extensions (Chapter 7) and quiescence search (Chapter 8) mitigate this, but some instability is unavoidable.

==== Handling PV Changes

When the PV (Principal Variation—the best sequence of moves found so far) changes between iterations, engines often record this as an event. Some engines use PV instability as a signal to:

- Extend the search at the point where the PV changed (to resolve the instability).
- Widen the aspiration window for the next iteration (anticipating more volatility).
- Apply more aggressive pruning at stable PV nodes and less pruning at volatile nodes.

=== Enhanced Transposition Table Cutoffs (ETC)

The transposition table (Chapter 10) stores the best move from previous searches. When we encounter a position with a TT entry whose depth is sufficient, we can not only use the stored score but also try the stored best move *before* generating any other moves. This is the single most powerful move ordering heuristic.

ETC (Enhanced Transposition Table Cutoffs) extends this idea: if the TT move for position `P` causes a beta cutoff, we can also use the TT move for positions that are "nearby" in the search tree. Specifically, if the TT move at position `P` is a capture that refutes a previous move, there is a good chance that the same capture will refute a different move in a sibling node.

This is the basis for *killer moves* (Chapter 9): moves that have caused cutoffs in sibling nodes are tried early in the current node, even if they are not the TT move. ETC generalizes killer moves by using the TT move from all ancestor nodes, weighted by recency.

=== Search Extensions: A Preview

While this chapter focuses on *reductions* (pruning moves to save time), the flip side is *extensions*: spending *more* time on moves that are tactically important. Extensions increase the search depth for specific moves that appear critical. Common extension triggers include:

- *Check extension*: When a move gives check, search it one ply deeper (or half a ply deeper using fractional extensions). Checks are forcing and often lead to tactical sequences.
- *Recapture extension*: When a move recaptures a piece on the same square, extend the search to see if the capture sequence continues.
- *Singular extension*: If only one move is significantly better than all others (a "singular" move), extend it. This is used in Stockfish and other top engines.
- *Pawn push to 7th rank*: A pawn advancing to the 7th rank creates a queening threat and may deserve an extension.

Extensions are expensive—they counteract the pruning of alpha-beta. Modern engines are conservative with extensions, typically using fractional plies (e.g., extend by 0.5 plies rather than a full ply) and limiting total extensions to avoid search explosion.

=== Fail-Soft vs. Fail-Hard Alpha-Beta

We've described alpha-beta in *fail-soft* form: when a search fails low (no move beats alpha), we return alpha (the bound). But a fail-soft implementation returns the *actual best score found*, even if it is below alpha. This provides additional information:

```c
// Fail-soft: return best_score (may be below alpha)
int best_score = -INFINITY;
// ... search loop ...
return best_score;  // may be less than alpha
```

vs.

```c
// Fail-hard: return alpha when no move beats it
int best_score = alpha;
// ... search loop ...
return best_score;  // always >= alpha
```

Fail-soft is preferred because the returned score (even if below alpha) can be used by the transposition table to set better bounds for future searches. If we know that a position is "at most -150", we can store that as an upper bound, potentially causing cutoffs in other parts of the search tree. Stockfish and most modern engines use fail-soft.

=== Multi-Cut Pruning

Multi-cut pruning is a probabilistic technique that attempts to prove that a node is an All node (all moves fail low) by examining only a subset of moves at reduced depth. If `N` moves (typically 6-8) all fail low at reduced depth `R = depth - reduction`, the node is very likely to be an All node, and we can return a fail-low without searching the remaining moves.

```c
if (depth >= 3 && !in_check && !pv_node) {
    int count = 0;
    for (int i = 0; i < min(moves.count, MULTI_CUT_MARGIN); i++) {
        make_move(move);
        int score = -pvs(pos, depth - 1 - REDUCTION, -beta, -beta + 1, ply + 1);
        unmake_move();
        if (score >= beta) { count++; break; }  // at least one move beats beta → this is NOT an All node
        if (++count >= MULTI_CUT_THRESHOLD) {
            return alpha;  // all tested moves failed low → assume this is an All node
        }
    }
}
```

Multi-cut is aggressive and can cause errors if the reduced-depth searches miss a tactical shot. But with conservative reduction and reasonable thresholds, it typically reduces the search tree by 5-10% with negligible ELO loss.

=== Razoring

Razoring is an extreme form of forward pruning used near the leaves of the search tree. If the static evaluation plus a margin is still below alpha (even after adding the maximum possible gain from the best move), we can safely prune the entire sub-tree:

```c
if (depth == 1 && !in_check) {
    int stand_pat = evaluate(pos);
    if (stand_pat + RAZOR_MARGIN <= alpha) {
        return quiesce(pos, alpha, beta, ply);  // don't even search at depth 1
    }
}
```

The razor margin is typically 300-500 centipawns (roughly 3-5 pawns worth of material). The intuition: if the position is so bad that even winning a queen would not raise it above alpha, then no plausible move will improve it enough to matter.

Razoring is applied only at depth 1 (pre-frontier nodes) because the error margin grows with depth. At depth 2 and beyond, the static evaluation is too noisy to razor safely.

=== The Horizon Effect and Search Consistency

The *horizon effect* is a fundamental limitation of fixed-depth search. When a search reaches its depth limit, it evaluates the position statically—but the static evaluation may be blind to forcing sequences that begin just beyond the horizon. The classic example: at depth 5, a forced sequence of checks leads to a queen loss at depth 6. The engine, unable to see depth 6, evaluates the position at depth 5 as equal.

The horizon effect manifests in several forms:

1. *Delayed loss*: The engine postpones an unavoidable loss by sacrificing material to push the losing line beyond the search horizon.
2. *Phantom threats*: The static evaluation detects a threat that the opponent can easily parry, but the parry is beyond the horizon, causing the engine to overestimate the threat.
3. *Quiescence artifacts*: Even with quiescence search, deep tactical sequences with quiet intermezzo moves can fool the evaluation.

Extensions (extending the search for checks, captures, and other forcing moves) are the primary defense against the horizon effect. By dynamically extending the search for tactically important lines, extensions effectively create a variable-depth search that sees deeper where it matters.

=== Summary

The enhancements in this chapter build on alpha-beta to create the modern search framework:

- *Principal Variation Search*: Exploits good move ordering by using cheap null-window searches for non-first moves, saving 15-30% of nodes.
- *Aspiration Windows*: Narrows the root search window based on the previous iteration's score, providing a 10-20% speedup.
- *Internal Iterative Deepening*: Finds a good first move at PV nodes with no TT move, improving move ordering deep in the tree.
- *Fail-Soft*: Returns exact bounds even on fail-lows, improving transposition table quality.
- *Multi-Cut and Razoring*: Aggressive forward pruning near the leaves, trading a small risk of errors for significant node savings.

Together with the advanced reduction techniques in Chapter 7, these form the complete search architecture used by every top engine from Stockfish to Berserk to Ethereal.

=== Code Examples: PVS Implementations

==== C Implementation

```c
int pvs(Position *pos, int depth, int alpha, int beta, int ply) {
    // Check for draw by repetition, fifty-move rule
    if (is_draw(pos)) return 0;

    // Mate distance pruning
    if (alpha < -MATE_SCORE + ply) alpha = -MATE_SCORE + ply;
    if (beta  >  MATE_SCORE - ply - 1) beta = MATE_SCORE - ply - 1;
    if (alpha >= beta) return alpha;

    // Transposition table probe
    TTEntry *tte = probe_tt(pos->hash);
    int tt_score = tte ? tt_score_from_entry(tte, ply) : -INFINITY;
    Move tt_move = tte ? tte->move : NO_MOVE;

    if (tte && tte->depth >= depth) {
        if (tte->flag == TT_EXACT) return tt_score;
        if (tte->flag == TT_ALPHA && tt_score <= alpha) return tt_score;
        if (tte->flag == TT_BETA  && tt_score >= beta)  return tt_score;
    }

    // Quiescence search at depth 0
    if (depth <= 0) return quiesce(pos, alpha, beta, ply);

    // Check extension
    if (in_check(pos)) depth++;

    // Null-move pruning (conditionally skip move generation if static eval is very good)
    // ... (Chapter 6 advanced)

    // Internal iterative deepening
    if (depth >= 3 && tt_move == NO_MOVE) {
        pvs(pos, depth - 2, alpha, beta, ply);
        tte = probe_tt(pos->hash);
        tt_move = tte ? tte->move : NO_MOVE;
    }

    MoveList moves;
    generate_moves(pos, &moves);
    score_moves(pos, &moves, tt_move, ply);  // includes TT move, captures, killers, history

    int best_score = -INFINITY;
    Move best_move = NO_MOVE;
    int moves_searched = 0;

    for (int i = 0; i < moves.count; i++) {
        Move move = select_best_move(&moves, i);  // pick best among remaining
        if (!make_move(pos, move)) continue;
        moves_searched++;

        int score;
        if (moves_searched == 1) {
            score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1);
        } else {
            // Late move reductions (Chapter 7)
            // ... reduction logic here ...

            score = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1);

            if (score > alpha && score < beta) {
                score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1);
            }
        }

        unmake_move(pos);

        if (score > best_score) {
            best_score = score;
            best_move = move;
            if (score > alpha) {
                alpha = score;
                // Update PV line
            }
        }

        if (alpha >= beta) {
            // Store killer move, update history
            if (!pos->piece_on[to_square(move)]) {
                update_killers(move, ply);
                update_history(move, depth, ply);
            }
            break;
        }
    }

    if (moves_searched == 0) {
        // No legal moves: checkmate or stalemate
        return in_check(pos) ? -MATE_SCORE + ply : 0;
    }

    // Store in transposition table
    TTFlag flag = best_score >= beta ? TT_BETA :
                  (best_move != NO_MOVE ? TT_EXACT : TT_ALPHA);
    store_tt(pos->hash, best_score, depth, best_move, flag, ply);

    return best_score;
}
```

==== C++ Implementation

```cpp
template<bool PvNode>
int Search::pvs(Position& pos, int depth, int alpha, int beta, int ply) {
    // ... (same structure as C, with template-driven compile-time branching)

    if constexpr (PvNode) {
        // PV node: do internal iterative deepening, wider search
        // ...
    } else {
        // Non-PV node: more aggressive pruning
        // ...
    }
}
```

The template parameter `PvNode` allows the compiler to generate two versions of `pvs`: one optimized for PV nodes (conservative pruning, IID) and one for non-PV nodes (aggressive pruning). This eliminates runtime branching in the hot path.

==== Rust Implementation

```rust
fn pvs(
    pos: &mut Position,
    depth: i32,
    mut alpha: i32,
    mut beta: i32,
    ply: usize,
    tt: &TranspositionTable,
    killers: &mut KillerMoves,
    history: &mut HistoryTable,
) -> i32 {
    // ... (structured similarly, with Rust's safety guarantees)

    // Move selection with iterators
    let mut moves = MoveList::new();
    generate_moves(pos, &mut moves);
    score_moves(pos, &mut moves, tt_move, ply, killers, history);

    let mut best_score = -MATE_SCORE;
    let mut best_move = Move::NULL;

    for (i, mv) in moves.iter().enumerate() {
        if !pos.make_move(*mv) { continue; }

        let score = if i == 0 {
            -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history)
        } else {
            // Null-window search then possibly re-search
            let mut score = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1, tt, killers, history);
            if score > alpha && score < beta {
                score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history);
            }
            score
        };

        pos.unmake_move();
        // ... score updates, alpha/beta updates ...
    }
    // ...
    best_score
}
```

==== Zig Implementation

```zig
fn pvs(
    pos: *Position,
    depth: i32,
    alpha: i32,
    beta: i32,
    ply: usize,
    tt: *TranspositionTable,
) i32 {
    // Zig's explicit allocator and error handling make TT management explicit
    const tt_entry = tt.probe(pos.hash) orelse null;

    // ... search logic ...

    var moves = MoveList{};
    generateMoves(pos, &moves);
    scoreMoves(pos, &moves, tt_move, ply);

    var best_score: i32 = -MATE_SCORE;
    var moves_searched: usize = 0;

    for (moves.slice()) |move| {
        if (!pos.makeMove(move)) continue;
        moves_searched += 1;

        const score = if (moves_searched == 1)
            -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt)
        else blk: {
            var s = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1, tt);
            if (s > alpha and s < beta) {
                s = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt);
            }
            break :blk s;
        };
        // ...
    }
    return best_score;
}
```

==== Odin Implementation

```odin
pvs :: proc(
    pos: ^Position,
    depth: i32,
    alpha, beta: i32,
    ply: int,
    tt: ^TranspositionTable,
) -> i32 {
    // Odin's straightforward procedural style with compile-time table generation
    tt_entry := tt_probe(tt, pos.hash);

    // ... search logic ...

    moves: MoveList;
    generate_moves(pos, &moves);
    score_moves(pos, &moves, tt_move, ply);

    best_score := -MATE_SCORE;
    moves_searched := 0;

    for move in moves_slice(&moves) {
        if !make_move(pos, move) do continue;
        moves_searched += 1;

        score: i32;
        if moves_searched == 1 {
            score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt);
        } else {
            score = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1, tt);
            if score > alpha && score < beta {
                score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt);
            }
        }

        unmake_move(pos);
        // ... score updates ...
    }
    return best_score;
}
```

=== Performance Benchmarks

The following table summarizes the typical performance impact of each search enhancement, measured as node count reduction relative to plain alpha-beta at depth 10 from the starting position (branching factor ≈ 35):

```text
Technique                   Node Reduction    Typical Speedup
──────────────────────────  ────────────────  ────────────────
Plain Alpha-Beta            (baseline)        1.00x
+ PVS                       20-30%            1.30x
+ Aspiration Windows        10-20%            1.15x
+ Internal Iterative Deep.  10-25%            1.20x
+ Transposition Table       40-70%            2.50x
+ Killer Moves (Ch.9)       15-25%            1.25x
+ History Heuristic (Ch.9)  10-20%            1.15x
+ Null-Move Pruning         5-10%             1.08x
+ Multi-Cut                 5-10%             1.08x
+ Razoring                  5-8%              1.06x
──────────────────────────────────────────────────────────
Combined (all)              85-95%            8-15x
```

These are multiplicative, not additive: each technique further reduces the already-reduced tree. The combined effect is dramatic: at depth 10, a search that would visit 52 million nodes with perfect alpha-beta ordering might visit only 3-5 million nodes with all these techniques applied.

But the story does not end here. The most powerful reduction technique—Late Move Reductions (LMR)—is the subject of the next chapter, and it alone can provide an additional 2-4x speedup.
