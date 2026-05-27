== Search Enhancements II: Advanced Pruning and Reduction

The first wave of search enhancements (Chapter 6) focused on windowing techniques: PVS, aspiration windows, and null-window search. These improve alpha-beta's efficiency by reducing the *width* of search windows. This chapter covers the second, more powerful wave: techniques that reduce the *depth* and *breadth* of search directly. Late Move Reductions (LMR), null-move pruning, futility pruning, and their variants collectively provide a 3-6x speedup over already-optimized alpha-beta—making them arguably the most impactful search innovations since alpha-beta itself.

=== The Fundamental Insight: Not All Moves Are Equal

Chapter 5 established that alpha-beta prunes branches proved irrelevant. But alpha-beta still searches *all* moves at *all* non-pruned nodes to *full* depth. The key realization of modern search engineering is that this is wasteful: moves that are unlikely to be good (late moves in the move list, quiet moves in volatile positions, moves that lose material) can be searched to *reduced* depth without significantly affecting the final result.

This is not a provably correct optimization like alpha-beta. It is a *heuristic* one—it can, and occasionally does, cause errors. But these errors are rare enough, and the speedup is large enough, that the net effect on playing strength is overwhelmingly positive. Every top engine uses these techniques, and their continuous refinement has yielded hundreds of ELO points over the past two decades.

==== The Risk-Reward Calculus of Pruning

Every pruning decision is a trade-off: skip some analysis (save time) at the risk of missing something important (lose accuracy). The art of search engineering is calibrating this trade-off so that time saved outweighs accuracy lost. Formally, if a pruning technique saves `S` nodes but causes an incorrect evaluation `E` times per million positions, the net ELO effect is positive if:

```text
ELO_gain = f(search_speed_increase) - g(error_rate)
```

where `f` and `g` are empirically determined functions. In practice, `f` grows logarithmically with speed (double speed → ~50-70 ELO), while `g` grows linearly with error rate. This means small error rates are tolerable, but they must be *very* small.

=== Late Move Reductions (LMR): The Cornerstone of Modern Search

Late Move Reductions (LMR) is the single most impactful search enhancement after alpha-beta and transposition tables. The idea is beautifully simple: moves that are searched later in the move list (after the TT move, captures, and killers) are, statistically, less likely to be good. Therefore, we can search them to a reduced depth.

==== The Basic LMR Formula

For the `i`-th move searched at a node (0-indexed), the reduction is:

```text
reduction = LMR_BASE + floor(log(i) / log(LMR_DIVISOR))
```

Typical values: `LMR_BASE = 0`, `LMR_DIVISOR = 2.0` to `2.5`. This gives:

```text
Move 0: reduction = 0     (first move, usually PV or TT move, no reduction)
Move 1: reduction = 0     (second move, often a killer)
Move 2: reduction = 1     (reduce by 1 ply)
Move 3: reduction = 1     
Move 4: reduction = 2     (reduce by 2 plies)
Move 5: reduction = 2
Move 7: reduction = 2
Move 8: reduction = 3
...
Move 15+: reduction = 3-4
```

The reduction is subtracted from the search depth. If the nominal depth is 8 plies, move 15 is searched to depth 8 - 3 = 5 plies instead of 8. This saves enormous numbers of nodes: searching to depth 5 instead of 8 reduces the sub-tree by roughly `35^(8-5) = 35^3 ≈ 42,875` nodes (in the worst case). Multiplied across thousands of nodes in the search tree, the savings are staggering.

==== The LMR Re-Search Condition

Reducing depth can cause us to miss a good move. The safety net is the re-search: if the reduced-depth search returns a score that beats alpha (unexpectedly good), we re-search the move to full depth:

```c
int R = lmr_reduction(depth, moves_searched);

int score = -pvs(pos, depth - 1 - R, -alpha - 1, -alpha, ply + 1);

if (score > alpha) {
    // Reduced search suggests this move is good—re-search at full depth
    score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1);
}
```

The re-search is expensive (we search the move twice), but it happens rarely when move ordering is good—typically 5-15% of LMR-reduced moves trigger a re-search. The net savings far exceed the occasional re-search cost.

==== Conditions for Applying LMR

LMR is not applied blindly. Moves that are tactically important should not be reduced. Standard conditions for *skipping* LMR (searching at full depth):

1. *The move gives check*: Checks are forcing and often lead to tactical shots. Reducing them risks missing checkmate or decisive material gain.
2. *The move is a capture*: Captures (and promotions) change material balance. Reducing them risks misevaluating tactics.
3. *The move is a killer move*: Killer moves (Chapter 9) have caused cutoffs in sibling nodes. They deserve full depth.
4. *The depth is already shallow*: If `depth <= 3`, the remaining depth is too small for safe reduction—the horizon is too close.
5. *The node is a PV node*: PV nodes (Chapter 5) are more important than non-PV nodes. Reductions at PV nodes are either skipped or made less aggressive.
6. *The move escapes from check*: When in check, all legal moves are tactically significant. Reducing them is risky.
7. *The static evaluation suggests a volatile position*: If the static eval is far from alpha (large gap), the position may be quiet and safe for reductions. If the eval is close to alpha, reductions are riskier.

==== Adaptive LMR: Tuning Reductions to the Position

Modern engines use adaptive LMR, where the reduction amount depends on multiple factors:

```c
int lmr_reduction(int depth, int move_index, Move move, Position *pos, int ply) {
    int R = (int)(log(move_index + 1) / log(2.0));  // base reduction

    // Increase reduction for quiet moves
    if (!is_capture(move) && !is_promotion(move)) R++;

    // Decrease reduction for moves that improve piece placement
    if (is_improving_move(move, pos)) R--;

    // Increase reduction at deeper plies (more nodes at stake)
    if (depth > 6) R++;

    // Decrease reduction for moves to squares near the enemy king
    if (near_enemy_king(to_square(move), pos)) R--;

    // Clamp to reasonable range
    if (R < 1) R = 1;
    if (R > depth - 1 && depth > 1) R = depth - 1;

    return R;
}
```

Engines like Stockfish have dozens of such conditions, each tuned through tens of thousands of test games. The reduction formula is one of the most heavily optimized components in any top engine.

==== Node Count Analysis with LMR

Consider a position with branching factor 35 at depth 10. Without LMR, PVS with good move ordering visits approximately 5 million nodes (as calculated in Chapter 6). With LMR:

- The first 3-4 moves are searched at full depth (PV move, TT move, killers).
- The next 5-8 moves are searched at depth - 1 or depth - 2.
- The remaining 20+ moves are searched at depth - 3 or depth - 4.

The effective branching factor drops from `b^(d/2)` (alpha-beta optimal) to approximately `b^(d/3)` or better. At depth 10, this means roughly `35^(10/3) ≈ 35^3.3 ≈ 66,000` nodes—a 75x reduction compared to alpha-beta alone. In practice, the true savings are somewhat less (move ordering is imperfect, re-searches add overhead), but a 10-20x reduction is typical.

=== Null-Move Pruning: The "Pass" Heuristic

Null-move pruning (also called the null-move heuristic) is based on an audacious assumption: if the side to move were to "pass" (do nothing), and the opponent still cannot raise the score above beta, then the current position is so good for the side to move that almost any move will preserve the advantage. Therefore, we can reduce the search depth.

Formally, null-move pruning works as follows:

```c
if (depth >= 3 && !in_check && !pv_node) {
    int stand_pat = evaluate(pos);
    if (stand_pat >= beta) {
        // Position is already good enough—the opponent cannot improve
        // Search with reduced depth to verify
        int score = -pvs(pos, depth - 1 - R, -beta, -beta + 1, ply + 1);
        if (score >= beta) {
            return beta;  // null-move cutoff
        }
    }
}
```

The parameter `R` (reduction factor) is typically 3 for depths above 6, and 2 for shallower depths. Some engines use `R = 2` everywhere (Fruit-style), while others use adaptive R:

- `R = 3` for `depth >= 8` (deep nodes—aggressive pruning is safe).
- `R = 2` for `depth >= 4` (medium nodes).
- No null-move pruning for `depth < 4` (shallow nodes—too risky).

==== Why Null-Move Pruning Works

Null-move pruning works because chess is not a game where "doing nothing" is a neutral option. The side to move has the initiative—the ability to improve their position or attack the opponent. If the side to move passes, they forfeit this advantage. If the position is STILL good after passing, it must be VERY good—so good that almost any legal move preserves the advantage.

The risk: null-move pruning assumes the side to move has at least one move that maintains the advantage. In zugzwang positions (where the obligation to move is a disadvantage), this assumption fails. Zugzwang is rare in middlegames but common in endgames. Therefore, null-move pruning is typically disabled or made less aggressive when material is low (less than a queen + minor piece on the board).

==== Verification Search

Some engines use a verification search to catch null-move errors: if the null-move search fails high, the engine searches a few additional moves at reduced depth to confirm that the position truly is winning. If any of these verification searches fails low, the null-move cutoff is rejected. This adds some overhead but dramatically reduces null-move errors.

=== Futility Pruning: Skipping Hopeless Moves Near the Leaves

Futility pruning addresses the question: "Can any legal move improve the position's score enough to matter?" Near the leaves of the search tree (depth 1 or 2), the maximum possible gain from any single move is bounded. If the current score is so far below alpha that not even the best possible move could reach it, we can safely prune all moves without searching them.

==== Futility at Depth 1 (Pre-Frontier Nodes)

At depth 1 (the last ply before quiescence search), a move can improve the evaluation by at most some margin. If the static evaluation plus this margin is still below alpha, all moves are futile:

```c
if (depth == 1 && !in_check) {
    int stand_pat = evaluate(pos);
    int futility_margin = 300;  // centipawns: roughly a minor piece

    if (stand_pat + futility_margin <= alpha) {
        return quiesce(pos, alpha, beta, ply);  // skip depth-1 search entirely
    }
}
```

The futility margin of 300 corresponds to the value of a knight or bishop—the maximum plausible gain from a non-capture move at depth 1. Captures can gain more (up to a queen), so they are excluded from futility pruning (searched normally in quiescence).

==== Futility at Depth 2 (Frontier Nodes)

At depth 2, futility is riskier because the opponent can make two moves. The margin must be larger:

```c
if (depth == 2 && !in_check) {
    int stand_pat = evaluate(pos);
    int futility_margin = 500;  // larger margin for depth 2

    if (stand_pat + futility_margin <= alpha) {
        // Prune quiet moves (captures and checks still searched)
        // ...
    }
}
```

At depth 2, individual moves (rather than the entire node) are pruned if they cannot plausibly reach alpha. This is *move-count-based futility pruning*: after searching the first few moves, if the remaining moves are "quiet" (non-captures, non-checks) and the score gap is large, skip them.

==== Futility Margin Tuning

The futility margin is typically a linear function of depth:

```c
int futility_margin(int depth) {
    return 100 * depth * depth;  // e.g., 100 at depth 1, 400 at depth 2
}
```

Some engines use piece-value-based margins, where the margin depends on the piece being moved. A pawn move cannot improve the score as much as a queen move, so pawn moves can be pruned more aggressively.

=== Delta Pruning in Quiescence Search

Quiescence search (Chapter 8) searches captures to resolve tactical sequences. But even within quiescence, some captures are hopeless. If our queen is hanging and we are down 900 centipawns, capturing a pawn (worth 100) will not recover the deficit. Delta pruning skips these futile captures:

```c
int quiesce(Position *pos, int alpha, int beta, int ply) {
    int stand_pat = evaluate(pos);
    if (stand_pat >= beta) return beta;
    if (stand_pat > alpha) alpha = stand_pat;

    // Delta pruning: skip captures that cannot reach alpha
    int delta_margin = 200;  // margin over the captured piece's value

    MoveList captures;
    generate_captures(pos, &captures);

    for (int i = 0; i < captures.count; i++) {
        Move move = captures.list[i];
        int captured_value = piece_value(captured_piece(pos, move));

        // If capturing this piece + margin still doesn't reach alpha, skip
        if (stand_pat + captured_value + delta_margin <= alpha) {
            continue;  // delta prune
        }

        // Otherwise, search the capture normally
        make_move(pos, move);
        int score = -quiesce(pos, -beta, -alpha, ply + 1);
        unmake_move(pos);
        // ... score updates ...
    }
    return alpha;
}
```

The delta margin accounts for the possibility that after this capture, we can capture again (a "recapture"). A margin of 200 means "I expect to win the captured piece plus possibly another pawn or piece in the exchange sequence."

=== Singular Extensions: Finding the Critical Move

While most techniques in this chapter *reduce* the search, singular extensions *extend* it—but only for moves that are demonstrably better than all alternatives. A move is *singular* if it is significantly better than every other legal move in the position.

The classic definition (from the Deep Blue and later Crafty eras): a move is singular if its score exceeds the second-best move's score by a threshold `S` (typically 50 centipawns), AND the second-best move was searched to a sufficient depth. In practice:

```c
// At a PV node, after searching the first move (the TT move):
int best_score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1);

// Search remaining moves with a shifted window to test for singularity
int second_best = -INFINITY;
for (remaining moves) {
    int score = -pvs(pos, depth - 1 - R, -best_score - S, -best_score - S + 1, ply + 1);
    second_best = max(second_best, score);
}

if (best_score - second_best > S) {
    // First move is singular—extend it
    depth++;  // extend by one ply for the singular move
}
```

The extension is expensive (re-searching the singular move to additional depth), but singular moves are precisely those that are most critical to tactical accuracy—a sacrifice, a killer quiet move, a deep tactical shot. Extending them helps resolve the horizon effect.

Stockfish and other top engines use a refined version: *multi-cut* with singular extensions. The idea is that if multiple moves in a node appear to be singular (very close in score to the best move), the position is "singular" and deserves an extension. This catches positions where there are multiple strong candidate moves, all of which need deeper analysis.

=== Probcut: Probabilistic Cutoffs

Probcut is a statistical technique for forward pruning. The idea: use a shallow search to predict the result of a deep search. If the shallow search's score (adjusted by a linear regression) is far outside the current window, we can prune without doing the deep search.

```c
// Before searching a move at depth d:
int shallow_score = -pvs(pos, D_SHALLOW, -beta, -alpha, ply + 1);

// Linear regression: deep_score ≈ a * shallow_score + b
int predicted_deep = a * shallow_score + b;

if (predicted_deep >= beta + PROBCUT_MARGIN) {
    return beta;  // probcut: predicted to fail high at full depth
}
if (predicted_deep <= alpha - PROBCUT_MARGIN) {
    continue;  // probcut: predicted to fail low, skip this move
}
```

The coefficients `a` and `b` are determined offline by analyzing millions of positions where both shallow and deep scores are available, then fitting a linear regression. The `PROBCUT_MARGIN` accounts for prediction error—typically 50-100 centipawns.

Probcut is most effective at cut nodes, where we want to quickly prove that a move is good enough to cause a cutoff. It is less effective at PV nodes, where we need the exact score.

=== History Heuristic: Learning Move Quality During Search

Traditional move ordering uses static heuristics: captures first (ranked by MVV-LVA), then killer moves, then quiet moves in some arbitrary order. The *history heuristic* improves this by dynamically learning which quiet moves tend to be good.

The idea: maintain a table `history[piece][to_square]` that records how often each `(piece, square)` combination has caused a beta cutoff. When a quiet move to a particular square with a particular piece causes a cutoff, its history score is increased. Moves with high history scores are ordered earlier.

```c
int history[12][64];  // 12 colored piece types, 64 squares

// When a quiet move causes a cutoff at depth d:
void update_history(int piece, int to, int depth) {
    history[piece][to] += depth * depth;  // gravity formula: deeper cutoffs = more weight
}

// When ordering quiet moves:
int history_score(int piece, int to) {
    return history[piece][to];
}
```

The "gravity formula" (`depth * depth` instead of just `depth`) gives exponentially more weight to moves that cause cutoffs near the root, where finding the correct move matters most.

==== Countermove Heuristic

A refinement of the history heuristic: the *countermove heuristic*. If the opponent plays move `M`, and in response we play move `C` that causes a cutoff, then `C` is a good "countermove" to `M`. The countermove table `counter[prev_piece][prev_to][piece][to]` records these relationships:

```c
// When move (piece, to) causes a cutoff after opponent's move (prev_piece, prev_to):
counter[prev_piece][prev_to][piece][to] = depth * depth;
```

This is more specific than the history heuristic—it accounts for the opponent's preceding move, capturing patterns like "after White plays knight to f3, Black responds with pawn to d5."

==== Follow-up Heuristic

Similar to the countermove heuristic: if *we* play move `M1`, and on our next turn (after the opponent responds) we play move `M2` that causes a cutoff, then `M2` is a good "follow-up" to `M1`. This captures planning patterns: "knight to f3, then after the opponent's reply, bishop to c4."

=== Putting It All Together: The Complete Modern Search

A modern search function integrates all these techniques. Here is a pseudocode skeleton showing the full integration:

```c
int search(Position *pos, int depth, int alpha, int beta, int ply, bool pv_node) {
    // 1. Early termination checks
    if (is_draw(pos)) return 0;
    if (ply >= MAX_PLY) return evaluate(pos);

    // 2. Mate distance pruning
    if (alpha < -MATE_SCORE + ply) alpha = -MATE_SCORE + ply;
    if (beta  >  MATE_SCORE - ply - 1) beta = MATE_SCORE - ply - 1;
    if (alpha >= beta) return alpha;

    // 3. Transposition table probe
    TTEntry *tte = probe_tt(pos->hash);
    // Use TT score if depth is sufficient...

    // 4. Quiescence search at horizon
    if (depth <= 0) return quiesce(pos, alpha, beta, ply);

    // 5. Check extension
    if (in_check(pos)) depth++;

    // 6. Null-move pruning
    if (!pv_node && !in_check && depth >= 3 && evaluate(pos) >= beta) {
        int R = 3 + (depth >= 8 ? 1 : 0);
        int score = -search(pos, depth - 1 - R, -beta, -beta + 1, ply + 1, false);
        if (score >= beta) return beta;
    }

    // 7. Futility pruning (depth 1 and 2)
    if (depth == 1 && !in_check && evaluate(pos) + 300 <= alpha) {
        return quiesce(pos, alpha, beta, ply);
    }

    // 8. Internal iterative deepening
    if (pv_node && depth >= 3 && tt_move == NO_MOVE) {
        search(pos, depth - 2, alpha, beta, ply, true);
        tt_move = probe_tt(pos->hash)->move;
    }

    // 9. Move generation and ordering
    MoveList moves;
    generate_moves(pos, &moves);
    score_moves(pos, &moves, tt_move, ply, killers, history, counter);

    // 10. Main search loop
    int best_score = -INFINITY;
    Move best_move = NO_MOVE;
    int moves_searched = 0;

    for (int i = 0; i < moves.count; i++) {
        Move move = select_best(&moves, i);
        if (!make_move(pos, move)) continue;
        moves_searched++;

        // LMR reduction calculation
        int R = 0;
        bool do_lmr = (depth >= 3 && moves_searched >= 4 && !is_capture(move)
                       && !gives_check(move) && !is_killer(move));

        if (do_lmr) {
            R = lmr_reduction(depth, moves_searched, move, pos);
        }

        // Search with PVS + LMR
        int score;
        if (moves_searched == 1) {
            score = -search(pos, depth - 1, -beta, -alpha, ply + 1, pv_node);
        } else {
            score = -search(pos, depth - 1 - R, -alpha - 1, -alpha, ply + 1, false);

            if (score > alpha && R > 0) {
                // LMR re-search at full depth
                score = -search(pos, depth - 1, -alpha - 1, -alpha, ply + 1, false);
            }
            if (score > alpha && score < beta) {
                // PVS re-search with full window
                score = -search(pos, depth - 1, -beta, -alpha, ply + 1, true);
            }
        }

        unmake_move(pos);

        // 11. Score updates
        if (score > best_score) {
            best_score = score;
            best_move = move;
            if (score > alpha) alpha = score;
        }

        // 12. Beta cutoff
        if (alpha >= beta) {
            if (!is_capture(move)) {
                update_killers(move, ply);
                update_history(move, depth);
            }
            break;
        }
    }

    // 13. Checkmate / stalemate
    if (moves_searched == 0) {
        return in_check(pos) ? -MATE_SCORE + ply : 0;
    }

    // 14. Store in transposition table
    store_tt(pos->hash, best_score, depth, best_move, /* flag */, ply);

    return best_score;
}
```

This single function, with all the enhancements from Chapters 5-7, is the core of Stockfish, Ethereal, Berserk, and virtually every modern alpha-beta engine. The differences between engines lie in the specific parameter values, the exact conditions for each pruning decision, and the fine details of move ordering—not in the overall structure.

=== Language-Specific Implementations

==== C Implementation

```c
// LMR reduction table, precomputed for speed
static const int lmr_reduction_table[64][64] = {
    // depth \ moves_searched →
    {0,0,0,0,0,0,0,0, /*...*/},
    {0,0,0,0,0,0,0,0, /*...*/},
    {0,1,2,2,3,3,3,3, /*...*/},
    // ...
};

static inline int reduction(int depth, int move_index) {
    return lmr_reduction_table[MIN(depth, 63)][MIN(move_index, 63)];
}

// History gravity update
static inline void update_history(int piece, int to, int depth) {
    int bonus = MIN(depth * depth, 400);
    int clamped = MAX(history[piece][to] + bonus - history[piece][to] * bonus / 512, -512);
    history[piece][to] = clamped;
}
```

==== C++ Implementation

```cpp
// Template-driven search with compile-time PV node dispatch
template<NodeType NT>
int Search::pvs(Position& pos, int depth, int alpha, int beta, int ply) {
    constexpr bool PV = (NT == PV_NODE);

    // Compile-time pruning decisions
    if constexpr (!PV) {
        // Null-move pruning only at non-PV nodes
        if (depth >= 3 && !pos.in_check() && pos.evaluate() >= beta) {
            // ...
        }
    }

    // ...
}

// SPSA-tuned LMR parameters
struct LMRParams {
    int base = 0;
    int divisor = 218;  // fixed-point: actual divisor = divisor / 64.0
    // ...
};
static constexpr LMRParams lmr_params = {/* tuned values */};
```

==== Rust Implementation

```rust
pub struct Search<'a> {
    pos: &'a mut Position,
    tt: &'a TranspositionTable,
    killers: &'a mut [[Move; 2]; MAX_PLY],
    history: &'a mut HistoryTable,
    counter: &'a mut CounterTable,
}

impl<'a> Search<'a> {
    fn reduction(&self, depth: i32, move_index: usize) -> i32 {
        // Lifetime-safe history lookup
        if move_index < 4 { return 0; }
        let r = (move_index as f64).ln() / 2.0_f64.ln();
        (r as i32).min(depth - 1).max(0)
    }

    pub fn search(&mut self, depth: i32, mut alpha: i32, beta: i32, ply: usize, pv: bool) -> i32 {
        // ... (full search logic with Rust safety)
    }
}
```

==== Zig Implementation

```zig
const LmrTable = blk: {
    var table: [64][64]i32 = undefined;
    for (0..64) |depth| {
        for (0..64) |move_idx| {
            table[depth][move_idx] = if (move_idx < 4) @as(i32, 0)
                else @intCast(@min(@as(f64, @floatFromInt(move_idx)).log2() / 2.0, @as(f64, @floatFromInt(depth - 1))));
        }
    }
    break :blk table;
};

fn search(pos: *Position, depth: i32, alpha: i32, beta: i32, ply: usize, tt: *TT) i32 {
    // Zig's comptime LMR table is embedded in the binary
    const reduction = LmrTable[@intCast(@min(depth, 63))][@intCast(@min(move_idx, 63))];
    // ... search logic
}
```

==== Odin Implementation

```odin
lmr_table: [64][64]i32;

init_lmr :: proc() {
    for depth in 0..<64 {
        for move_idx in 0..<64 {
            if move_idx < 4 {
                lmr_table[depth][move_idx] = 0;
            } else {
                r := int(math.ln(f64(move_idx)) / math.ln(2.0) / 2.0);
                lmr_table[depth][move_idx] = clamp(r, 0, max(depth - 1, 0));
            }
        }
    }
}

search :: proc(pos: ^Position, depth: i32, alpha, beta: i32, ply: int, pv: bool) -> i32 {
    // Odin's straightforward approach with pre-initialized tables
    reduction := lmr_table[min(depth, 63)][min(moves_searched, 63)];
    // ... search logic (same structure as C version)
}
```

=== The Horizon Effect: A Deeper Look

We touched on the horizon effect in Chapter 6. LMR and null-move pruning, while enormously beneficial, exacerbate the horizon effect: by reducing search depth for "unlikely" moves, they can accidentally push a tactical threat beyond the reduced horizon, causing the engine to completely miss it.

Consider this classic example:

```text
Position: White king on g1, White queen on d1, Black rook on e8, Black queen on d8.
White is about to lose the queen to Re1+ (a skewer). 
Depth 6 with LMR reduces the Re1+ branch because it's "quiet" (not a capture, not a check until the move is made).
The engine evaluates the position as equal at depth 6. At depth 7, the skewer is found.
```

This is why singular extensions exist: they extend the search specifically for moves like Re1+ that are demonstrably better than alternatives. And this is why check extensions exist: Re1+ IS a check (once made), and if the engine tests for checks during move generation, it can extend the branch.

The interplay between reductions and extensions is the central tension in modern search engineering. Too much reduction → horizon effect errors. Too many extensions → search explosion. The art lies in finding the right balance for each position.

=== Search Consistency and the Multi-PV Problem

Multi-PV mode (where the engine returns the N best moves, not just the best) interacts poorly with aggressive pruning. LMR and null-move pruning assume we only care about the best move. When searching for the 2nd, 3rd, and 4th best moves, the pruning assumptions break down: the "late" moves might be the 2nd and 3rd best, and reducing them too aggressively can cause the engine to miss them.

Engines handle this by relaxing pruning in multi-PV mode: reducing LMR amounts, disabling null-move pruning for deep nodes, and using wider aspiration windows. Some engines perform a separate search for each PV line, using the previous line's score as a lower bound for the next line.

=== Empirical Tuning: SPSA and the Art of Parameter Optimization

The parameters that control LMR, futility, null-move pruning, and delta pruning are not derived from first principles. They are *tuned* through empirical testing. The standard approach is SPSA (Simultaneous Perturbation Stochastic Approximation), which we cover in depth in Chapter 17.

A typical SPSA tuning run for LMR parameters involves:

1. Start with reasonable initial values (e.g., `LMR_BASE = 0`, `LMR_DIVISOR = 2.0`).
2. Play 50,000-100,000 self-play games with perturbed parameters (add small random noise).
3. Compute the win/loss/draw ratio for each parameter perturbation.
4. Update parameters in the direction that increased wins.
5. Repeat for 10-20 iterations until convergence.

The result is a set of parameters that would be nearly impossible to derive analytically but that work superbly in practice. Stockfish's current LMR parameters are the product of hundreds of thousands of CPU-hours of SPSA tuning.

=== Summary

The search enhancements in this chapter reduce the effective branching factor from approximately `b^(d/2)` (alpha-beta optimal) to `b^(d/3)` or lower, providing a 5-15x speedup over already-optimized alpha-beta:

- *Late Move Reductions (LMR)*: Search late moves at reduced depth, with re-search for promising moves. The largest single contributor to modern engine strength.
- *Null-Move Pruning*: If the position is already good enough, skip the opponent's search with reduced-depth verification.
- *Futility Pruning*: Skip hopeless moves near the leaves when even the best outcome cannot reach alpha.
- *Delta Pruning*: Skip futile captures in quiescence search.
- *Singular Extensions*: Counteract reductions by extending demonstrably critical moves.
- *History Heuristic*: Dynamically learn which quiet moves tend to be good.
- *Probcut*: Use shallow searches to predict deep search outcomes and prune accordingly.

Together with the windowing techniques of Chapter 6, these form the complete search architecture of every modern chess engine. The remaining chapters in this part refine specific components: move ordering (Chapter 9) makes these pruning techniques more effective by ensuring the right moves are searched first, and transposition tables (Chapter 10) ensure we never search the same position twice.
