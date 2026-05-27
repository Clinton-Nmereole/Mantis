== Move Ordering: The Art of Searching the Best Move First

Move ordering is the single most important factor in alpha-beta search efficiency. With perfect move ordering, alpha-beta achieves its optimal `O(b^(d/2))` node count. With random ordering, it degrades to `O(b^(3d/4))`. With worst-first ordering, it regresses to full minimax—`O(b^d)`—a nine-order-of-magnitude difference at depth 10.

This chapter covers every aspect of move ordering: static heuristics (MVV-LVA, SEE), dynamic heuristics (killer moves, history, countermoves), and the architecture that combines them into a coherent ordering pipeline. The ordering techniques described here are the scaffolding upon which the search enhancements of Chapters 6-7 depend: PVS, LMR, and null-move pruning all assume that the first few moves in the list are likely to be good.

=== Why Move Ordering Matters: A Quantitative Analysis

Consider a node with branching factor `b = 35` and depth `d = 8`. With alpha-beta:

- *Perfect ordering*: Best move first at every node → approximately `35^4 = 1,500,625` leaf nodes.
- *Good ordering* (best move in top 3): → approximately `2,500,000` leaf nodes (1.7x worse).
- *Random ordering*: → approximately `35^6 = 1,838,265,625` leaf nodes (1,224x worse).
- *Worst-first ordering*: → approximately `35^8 = 2.25 × 10^12` leaf nodes (1,500,000x worse).

The multiplier between "good" and "perfect" ordering is modest (1.7x). The difference between "good" and "random" is catastrophic (1,224x). Move ordering does not need to be perfect—it just needs to be good enough that the best move is among the first few examined.

==== The Ordering Pipeline

Moves are sorted into categories, with each category ordered internally by a different heuristic. The standard ordering from highest to lowest priority:

1. *Transposition table move* (hash move): The best move from a previous search of this position.
2. *Captures that win material* (SEE > 0), ordered by MVV-LVA.
3. *Promotions* (especially to queen), ordered by promotion piece value.
4. *Killer moves* (up to 2 per ply): Quiet moves that caused cutoffs in sibling nodes.
5. *Countermove*: The response to the opponent's previous move that has historically been good.
6. *Quiet moves ordered by history heuristic*: Quiet moves with high history scores.
7. *Captures that lose material* (SEE <= 0), ordered by MVV-LVA (these are "bad" captures).
8. *Remaining quiet moves*: Low-history quiet moves, often just in static order.

This pipeline is universal across all modern engines. The differences lie in the specific implementation of each heuristic.

=== The Transposition Table Move: The Gold Standard

When a position has been searched before (at any depth), the transposition table (Chapter 10) stores the best move found. This move is the single best guess for "the best move" at this node—it was, after all, the best move at some previous depth in some previous part of the search. The TT move is always searched first, unconditionally.

```c
Move tt_move = NO_MOVE;
TTEntry *tte = probe_tt(pos->hash);
if (tte && tte->depth >= 0) {
    tt_move = tte->move;
}
// ... in the ordering function:
if (move == tt_move) score = INFINITY;  // always first
```

The TT move is so reliable that some engines use it as the only move ordering heuristic at interior nodes, skipping all other ordering work if the TT move causes a cutoff. This is particularly effective at Cut nodes, where the TT move is highly likely to cause a cutoff.

=== Captures and MVV-LVA: Most Valuable Victim, Least Valuable Attacker

Captures are naturally strong candidates because they change the material balance. But not all captures are equal. MVV-LVA (Most Valuable Victim, Least Valuable Attacker) ranks captures by:

1. Primary key: Value of the captured piece (victim). Higher is better.
2. Secondary key: Value of the capturing piece (attacker). Lower is better (we prefer to capture queens with pawns, not queens with queens).

This ensures that `P x Q` (pawn captures queen, gain +800) is searched before `Q x P` (queen captures pawn, gain +100), and far before `Q x Q` (queen captures queen, gain 0 or minimal).

```c
int mvv_lva_score(Move move, Position *pos) {
    int victim_value = piece_value(pos->piece_on[to_square(move)]);
    int attacker_value = piece_value(pos->piece_on[from_square(move)]);

    // MVV-LVA formula: victim * 64 - attacker (or victim * 10 - attacker, etc.)
    return victim_value * 64 - attacker_value;
}
```

The factor 64 ensures that the victim's value dominates (victim differences of 100 become 6,400 MVV-LVA score difference). This prevents a knight capturing a queen from being outranked by a queen capturing a rook.

==== Limitations of MVV-LVA

MVV-LVA assumes all captures are good. But consider: a queen captures a pawn that is defended by a knight. MVV-LVA ranks this highly (Q x P: victim=100, attacker=900, score = 100*64 - 900 = 5,500). But the capture loses material (900 lost, 100 gained, net -800). MVV-LVA does not account for whether the captured piece is defended.

This is where SEE (Static Exchange Evaluation) comes in.

=== SEE: Static Exchange Evaluation

SEE determines whether a capture on a given square wins or loses material, considering all possible recaptures in sequence. Unlike quiescence search (which searches dynamically), SEE is a *static* analysis: it assumes each side captures with its least valuable attacker in turn, and the side that initiated the exchange can stop at any point.

==== The SEE Algorithm

Given a target square `sq` and the piece types and colors of all attackers, SEE computes the net material gain:

```c
int see(Position *pos, int sq, int stm) {
    // Collect all attackers of sq, sorted by piece value (least valuable first)
    int attackers[16];
    int n_attackers = collect_attackers(pos, sq, stm, attackers);

    int gain[16];
    gain[n_attackers] = 0;  // after all captures, no gain

    // Compute gain array: working backward from deepest capture
    for (int i = n_attackers - 1; i >= 0; i--) {
        gain[i] = max(0, attackers[i] - gain[i + 1]);
    }

    return gain[0];  // net gain from the initial capture
}
```

Let us trace through an example. A square contains an enemy rook (value 500). It is attacked by:

1. Our pawn (value 100)
2. Our knight (value 325) — blocked behind the pawn
3. Enemy queen (value 900)
4. Our queen (value 900)

The sorted attackers (least valuable first, alternating colors):
```text
att[0] = 100 (our pawn)
att[1] = 900 (enemy queen, after pawn captures)
att[2] = 900 (our queen, after enemy queen recaptures)
```

Computing gains backward:
```text
n = 3
gain[3] = 0
i=2: gain[2] = max(0, 900 - 0) = 900   (our queen captures last)
i=1: gain[1] = max(0, 900 - 900) = 0    (enemy queen recaptures, net zero)
i=0: gain[0] = max(0, 100 - 0) = 100    (our pawn captures, net gain +100 — stop here!)
```

The SEE value is 100 centipawns (gain of a rook by a pawn). Our side should capture with the pawn, and after the enemy queen recaptures, our queen recaptures—but we stop after the pawn capture because the enemy queen recapture would lead to a queen trade (net zero additional gain), and capturing with the pawn already gives us a net +100.

However, if the enemy queen were NOT behind the rook, the SEE might be different—the pawn captures the rook, and the exchange ends (no recapture available), giving a net gain of 500.

==== SEE in Move Ordering

SEE is used to rank captures more precisely than MVV-LVA:

- *Good captures* (SEE > 0): The capture wins material. Searched early.
- *Equal captures* (SEE == 0): The capture breaks even (e.g., queen trades queen). Searched after good captures.
- *Bad captures* (SEE < 0): The capture loses material. Searched late, sometimes pruned entirely in quiescence.

```c
int capture_ordering_score(Move move, Position *pos) {
    int see_score = see(pos, to_square(move), pos->side);

    if (see_score > 0) {
        // Good capture: order by MVV-LVA within good captures
        return GOOD_CAPTURE_BASE + mvv_lva_score(move, pos);
    } else if (see_score == 0) {
        return EQUAL_CAPTURE_BASE + mvv_lva_score(move, pos);
    } else {
        // Bad capture: low priority, but still ordered by MVV-LVA
        return BAD_CAPTURE_BASE + mvv_lva_score(move, pos);
    }
}
```

The `GOOD_CAPTURE_BASE` is a high constant (e.g., 10,000,000) that ensures all good captures are searched before any equal or bad captures. `EQUAL_CAPTURE_BASE` is lower (e.g., 5,000,000). `BAD_CAPTURE_BASE` is the lowest (e.g., 0), meaning bad captures are searched even after killer moves and high-history quiet moves.

==== SEE-Based Pruning in Quiescence

In quiescence search, captures with negative SEE are often pruned entirely:

```c
if (see(pos, to_square(move), pos->side) < 0) {
    continue;  // skip bad captures in quiescence
}
```

This dramatically reduces the quiescence search tree. However, it can be wrong: a capture that appears bad by SEE might be a sacrifice that leads to checkmate, or a capture that removes a key defender. Therefore, some engines only prune captures with very negative SEE (e.g., SEE < -200) in quiescence, or skip SEE pruning when the depth is very small (allowing all captures near the horizon).

=== Killer Moves: The Sibling Effect

A *killer move* is a quiet (non-capture) move that caused a beta cutoff in a sibling node (another move at the same ply). The intuition: if a quiet move is good in one sibling, it is likely good in other siblings too, because the position structure is similar.

Each ply maintains two killer move slots. When a quiet move causes a beta cutoff:

```c
if (score >= beta && !is_capture(move)) {
    // Shift the second-oldest killer out, add new killer
    killers[ply][1] = killers[ply][0];
    killers[ply][0] = move;
}
```

If either killer is the same as the current move (duplicate killer), it is not stored twice. Killer moves are searched after good captures and before other quiet moves.

==== Why Killers Work

Consider a position where White is attacking Black's kingside. At a particular ply, White has several candidate moves: knight to g5, bishop to d3, rook to e1. If knight to g5 causes a cutoff in one sibling (it threatens checkmate), it is likely to be good in sibling positions too—the kingside attack structure is similar across variations.

Killers are particularly effective at Cut nodes: the first move at a Cut node causes a cutoff, and its killer is immediately available for sibling Cut nodes.

==== Killer Move Aging

Some engines use more than two killer slots (e.g., 3-4 per ply) but apply *aging*: older killers, if not re-triggered, have their priority decay over time. This prevents stale killers from persisting into unrelated parts of the search.

=== Countermove Heuristic

The countermove heuristic (Chapter 7) records, for each opponent move, which of our quiet moves has historically been a good response. It is a more specific version of the killer heuristic:

```c
// countermove[prev_piece][prev_to] = a move (our piece, our to-square)
Move countermove[12][64];  // indexed by opponent's (piece, to_square)

// Update: when our move (piece, to) causes cutoff after opponent's (prev_piece, prev_to):
countermove[prev_piece_index][prev_to] = make_move(piece, to);
```

In move ordering, the countermove for the opponent's preceding move is given priority just below killer moves:

```c
Move cm = countermove[opponent_piece_index][opponent_prev_to];
if (move == cm) score = COUNTERMOVE_SCORE;  // between killers and history
```

Countermoves are particularly effective at capturing patterns like "after knight to f6, play bishop to g5" or "after pawn to e5, play pawn to d4."

=== History Heuristic: Global Move Learning

While killers and countermoves are local (restricted to specific plies or preceding moves), the *history heuristic* is global: it learns, across the entire search, which quiet moves tend to be good.

==== Butterfly Boards

The standard implementation uses a 2D array called *butterfly boards*:

```c
int16_t history[12][64];  // [colored piece type][to square]
```

When a quiet move `(piece, to_square)` causes a cutoff at depth `d`:

```c
void update_history(int piece, int to, int depth) {
    int bonus = depth * depth;  // gravity formula
    // Clamp bonus to prevent overflow and runaway values
    if (bonus > 400) bonus = 400;

    // Apply with exponential moving average to prevent saturation
    int delta = bonus - history[piece][to] * abs(bonus) / 512;
    history[piece][to] += delta;
}
```

The gravity formula gives exponentially more weight to cutoffs at deep nodes (near the root), where correctly identifying the best move matters most. A cutoff at depth 10 receives a bonus of 100, while a cutoff at depth 2 receives only 4.

==== History Score Normalization

Without careful handling, history scores can grow without bound, saturating at 16-bit limits. The exponential moving average decay (`history * abs(bonus) / 512`) ensures that scores asymptotically approach a maximum and that old values decay if not reinforced.

Some engines also periodically normalize the entire history table: every 10,000 nodes or so, divide all entries by 2. This prevents saturation and ensures that recent cutoffs (which are more relevant to the current search) dominate stale ones.

==== History in Move Ordering

During move ordering, quiet moves are scored by their history value:

```c
int history_score(int piece, int to) {
    return history[piece][to];
}
```

Captures and killer moves outrank history-based ordering, so the history heuristic only orders the "remaining" quiet moves—but this is still crucial because most moves in the list are quiet moves, and ordering them well significantly affects LMR decisions (LMR reduces late moves; "late" depends on ordering quality).

=== Capture History: Extending History to Captures

The standard history heuristic applies only to quiet moves. But some engines extend the concept to captures using a *capture history* table:

```c
int16_t capture_history[12][64][6];  // [piece][to][captured_piece_type]
```

This learns which specific capture patterns tend to be good. A pawn capturing a queen (P x Q) should have a very high capture history score, while a queen capturing a defended pawn (Q x P) should have a low score. This is more informed than MVV-LVA—it accounts for the context of which pieces are involved.

=== Continuation History: Multi-Ply Patterns

The *continuation history* heuristic extends history across multiple plies, learning sequences of moves:

```c
// continuation_history[ply-1 piece][ply-1 to][ply piece][ply to]
int16_t continuation_history[12][64][12][64];
```

This captures two-ply patterns: "after our knight goes to f3, and the opponent plays pawn to d5, our pawn captures on d5." The continuation history table is 4D (12 × 64 × 12 × 64 = 589,824 entries) and requires careful memory management, but it provides significantly better ordering than 2D history alone.

Modern engines like Stockfish use continuation history with 1, 2, and even 4-ply lookback, trading memory for search efficiency. The tables are large (several megabytes) but fit comfortably in L3 cache on modern CPUs.

=== Move Ordering in Quiescence Search

Quiescence search has narrower ordering requirements because it only searches captures (and sometimes promotions). The ordering priorities in quiescence:

1. *SEE > 0 captures*: Captures that win material. Ordered by MVV-LVA.
2. *Queen promotions*: Pawn promotes to queen, changing material balance.
3. *Underpromotions*: Pawn promotes to knight (with check), rook, or bishop. De-prioritized but searched.
4. *SEE == 0 captures*: Neutral captures. Lower priority but searched.
5. *SEE < 0 captures*: Losing captures. Often pruned entirely in quiescence.

The key difference from full-width search ordering: quiet moves are not searched at all in standard quiescence, so killer moves, history, and countermove heuristics are not needed. This simplifies the ordering pipeline significantly.

However, some engines use *extended quiescence* that includes "threatening" quiet moves (checks, moves that attack undefended pieces), in which case killer and history heuristics return.

=== Ordering Pipeline Architecture

The full ordering pipeline, combining all heuristics:

```c
void score_moves(Position *pos, MoveList *moves, Move tt_move, int ply,
                 KillerMoves *killers, HistoryTable *history,
                 CounterTable *counter) {
    Move opp_move = pos->last_move;  // opponent's preceding move

    for (int i = 0; i < moves->count; i++) {
        Move move = moves->list[i];

        if (move == tt_move) {
            moves->score[i] = SCORE_TT_MOVE;       // e.g., 10,000,000
        } else if (is_capture(move)) {
            int see_val = see(pos, to_square(move), pos->side);
            if (see_val > 0) {
                moves->score[i] = SCORE_GOOD_CAPTURE + mvv_lva_score(move, pos);
            } else if (see_val == 0) {
                moves->score[i] = SCORE_EQUAL_CAPTURE + mvv_lva_score(move, pos);
            } else {
                moves->score[i] = SCORE_BAD_CAPTURE + mvv_lva_score(move, pos);
            }
        } else if (is_promotion(move)) {
            moves->score[i] = SCORE_PROMOTION + promotion_piece_value(move);
        } else if (move == killers->slot[ply][0]) {
            moves->score[i] = SCORE_KILLER_1;      // e.g., 900,000
        } else if (move == killers->slot[ply][1]) {
            moves->score[i] = SCORE_KILLER_2;      // e.g., 800,000
        } else if (move == counter[opp_move_piece][opp_move_to]) {
            moves->score[i] = SCORE_COUNTERMOVE;   // e.g., 700,000
        } else {
            // Quiet move: order by history heuristic
            int piece_idx = piece_index(pos->piece_on[from_square(move)]);
            moves->score[i] = SCORE_QUIET + history[piece_idx][to_square(move)];
        }
    }

    // Sort moves by score (selection sort is common because moves.count is small)
    sort_moves_by_score(moves);
}
```

The score constants form a strict hierarchy:

```c
SCORE_TT_MOVE      = 10_000_000;
SCORE_GOOD_CAPTURE =  9_000_000;  // + mvv_lva (0 to ~63,000)
SCORE_PROMOTION    =  8_000_000;  // + piece_value
SCORE_KILLER_1     =  7_000_000;
SCORE_KILLER_2     =  6_000_000;
SCORE_COUNTERMOVE  =  5_000_000;
SCORE_EQUAL_CAPTURE=  4_000_000;  // + mvv_lva
SCORE_QUIET        =  2_000_000;  // + history score (0 to ~16,000 max)
SCORE_BAD_CAPTURE  =  1_000_000;  // + mvv_lva
```

This hierarchy ensures strict ordering: TT move always first, then good captures, then promotions, then killers, etc. Within each category, the additive component provides finer ranking.

=== Selection Sort vs. Pick-Best for Move Ordering

With 30-70 moves per node, sorting the entire move list is unnecessary—we only need the first few moves to be correct (the ones that might be searched before a cutoff). The standard approach is *pick-best selection*:

```c
Move select_best(MoveList *moves, int index) {
    // Find the move with the highest score among moves[index..count-1]
    int best_idx = index;
    for (int i = index + 1; i < moves->count; i++) {
        if (moves->score[i] > moves->score[best_idx]) {
            best_idx = i;
        }
    }
    // Swap best to position index
    swap(moves->list[index], moves->list[best_idx]);
    swap(moves->score[index], moves->score[best_idx]);
    return moves->list[index];
}
```

This avoids the `O(n log n)` cost of full sorting and only costs `O(n)` per move. Since most nodes experience a cutoff after 1-5 moves, the remaining moves are never examined—and the sorting cost for them would be wasted.

=== Move Ordering and Search Instability

Aggressive move ordering can cause search instability (Chapter 6). If the history heuristic learns that move `M` is good, it orders `M` early, which causes `M` to be searched at full depth, which confirms that `M` is good—a self-reinforcing loop. This is usually beneficial (it correctly identifies good moves) but can sometimes lock onto a suboptimal move, especially early in the search when history values are noisy.

To mitigate this, some engines:

1. *Decay history values* over time, allowing new information to override stale patterns.
2. *Limit history influence* near the root, where errors are most costly.
3. *Use separate history tables* for different search phases (opening vs. endgame), since move patterns differ significantly.

=== Language-Specific Implementations

==== C Implementation

```c
// Compact ordering: scores stored alongside moves in a parallel array
typedef struct {
    Move moves[MAX_MOVES];
    int   scores[MAX_MOVES];
    int   count;
} MoveList;

// Fast MVV-LVA: lookup table for (attacker, victim) → score
static const int mvv_lva_table[6][6] = {
    // pawn, knight, bishop, rook, queen, king (attacker →)
    {105, 205, 305, 405, 505, 605},   // victim = pawn
    {104, 204, 304, 404, 504, 604},   // victim = knight
    {103, 203, 303, 403, 503, 603},   // victim = bishop
    {102, 202, 302, 402, 502, 602},   // victim = rook
    {101, 201, 301, 401, 501, 601},   // victim = queen
    {100, 200, 300, 400, 500, 600},   // victim = king (invalid capture)
};
```

==== C++ Implementation

```cpp
// Type-safe scoring with enum classes
enum class MoveCategory : int32_t {
    TT_MOVE       = 10'000'000,
    GOOD_CAPTURE  =  9'000'000,
    PROMOTION     =  8'000'000,
    KILLER_1      =  7'000'000,
    KILLER_2      =  6'000'000,
    COUNTERMOVE   =  5'000'000,
    EQUAL_CAPTURE =  4'000'000,
    QUIET         =  2'000'000,
    BAD_CAPTURE   =  1'000'000,
};

class MoveOrdering {
    // Template-based dispatch for compile-time optimization
    template<MoveCategory Cat>
    static int score(const Position& pos, Move move);
};
```

==== Rust Implementation

```rust
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ScoredMove {
    pub mv: Move,
    pub score: i32,
}

impl Ord for ScoredMove {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other.score.cmp(&self.score)  // descending: higher score first
    }
}

impl MoveList {
    pub fn score_moves(&mut self, pos: &Position, tt_move: Move, ply: usize,
                        killers: &KillerMoves, history: &HistoryTable) {
        for mv in &mut self.moves {
            mv.score = if *mv == tt_move {
                SCORE_TT_MOVE
            } else if mv.is_capture() {
                score_capture(pos, *mv)
            } else {
                score_quiet(pos, *mv, ply, killers, history)
            };
        }
        self.moves.sort_unstable();  // Rust's sort is fast enough for typical move counts
    }
}
```

==== Zig Implementation

```zig
const MoveScore = enum(i32) {
    tt_move       = 10_000_000,
    good_capture  =  9_000_000,
    promotion     =  8_000_000,
    killer_1      =  7_000_000,
    killer_2      =  6_000_000,
    countermove   =  5_000_000,
    equal_capture =  4_000_000,
    quiet         =  2_000_000,
    bad_capture   =  1_000_000,

    pub fn add(self: MoveScore, bonus: i32) i32 {
        return @intFromEnum(self) + bonus;
    }
};

fn scoreMoves(pos: *const Position, moves: *MoveList, tt_move: Move,
              ply: usize, killers: *KillerMoves, history: *HistoryTable) void {
    for (moves.slice()) |*mv| {
        mv.score = if (mv.move == tt_move)
            MoveScore.tt_move.add(0)
        else if (mv.isCapture())
            scoreCapture(pos, mv.move)
        else
            scoreQuiet(pos, mv.move, ply, killers, history);
    }
}
```

==== Odin Implementation

```odin
Score_TT_Move       :: 10_000_000;
Score_Good_Capture  ::  9_000_000;
Score_Promotion     ::  8_000_000;
Score_Killer_1      ::  7_000_000;
Score_Killer_2      ::  6_000_000;
Score_Countermove   ::  5_000_000;
Score_Equal_Capture ::  4_000_000;
Score_Quiet         ::  2_000_000;
Score_Bad_Capture   ::  1_000_000;

score_moves :: proc(pos: ^Position, moves: ^MoveList, tt_move: Move,
                    ply: int, killers: ^KillerMoves, history: ^HistoryTable) {
    for &mv in moves_slice(moves) {
        if mv == tt_move {
            mv.score = Score_TT_Move;
        } else if is_capture(mv) {
            mv.score = score_capture(pos, mv);
        } else {
            mv.score = score_quiet(pos, mv, ply, killers, history);
        }
    }
}
```

=== The History of Move Ordering Heuristics

The evolution of move ordering reflects the broader evolution of chess engines:

- *1970s (Chess 4.x, early programs)*: Static ordering. Captures first, then moves toward the center, then everything else. No learning.
- *1980s (Belle, Cray Blitz)*: Killer heuristic (Gillogly, 1972), history heuristic (Schaeffer, 1983). First dynamic ordering.
- *1990s (Deep Blue, Crafty)*: SEE-based capture ordering, refined history tables, countermove heuristic.
- *2000s (Fruit, Glaurung)*: Piece-square based quiet move ordering, PVS-aware scoring adjustments.
- *2010s (Stockfish)*: Continuation history, capture history, gravity formula for history updates, SPSA-tuned scoring.
- *2020s (Stockfish NNUE)*: History tables working alongside NNUE evaluation—the ordering and evaluation systems cooperate rather than compete.

Today's engines integrate dozens of ordering heuristics, each contributing a small but measurable ELO gain. The collective effect is that the best move is ordered first 85-95% of the time in most positions—close enough to perfect that alpha-beta achieves near-optimal pruning.

=== Summary

Move ordering is the linchpin of alpha-beta efficiency. The key techniques, in order of priority:

1. *Transposition table move*: Unconditionally first. The most reliable predictor of the best move.
2. *SEE-ranked captures*: Good captures (SEE > 0) by MVV-LVA, equal captures, then bad captures.
3. *Promotions*: High priority, especially to queen.
4. *Killer moves*: Two quiet moves per ply that caused recent cutoffs in siblings.
5. *Countermove*: The historically best response to the opponent's preceding move.
6. *History heuristic*: Global learning of which quiet moves tend to be good, with gravity formula updates.
7. *Continuation history*: Multi-ply patterns for deeper strategic understanding.

Together, these heuristics ensure that in 85-95% of nodes, the best move is among the first 2-3 moves examined. This is what makes PVS (Chapter 6) and LMR (Chapter 7) effective: with good ordering, the first move is usually correct, null-window searches on later moves rarely trigger re-searches, and late moves can be safely reduced. Move ordering is not just "an" optimization—it is *the* optimization that all other search optimizations depend upon.
