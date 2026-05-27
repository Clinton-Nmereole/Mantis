== Advanced Evaluation: Tapering, Tuning, and Deep Positional Understanding

Chapter 11 established the classical evaluation framework: material counting, piece-square tables, pawn structure, mobility, king safety, and coordination bonuses. This chapter extends that framework with advanced concepts that push the evaluation toward master-level play. We cover the sophisticated tapered evaluation pipeline, material imbalance tables, advanced pawn evaluation (passed pawns in depth), space and initiative, draw detection, and the integration of multiple evaluation components into a single coherent system.

=== The Tapered Evaluation Pipeline in Depth

Chapter 11 introduced the basic idea of tapering: each evaluation term has separate middlegame (mg) and endgame (eg) scores, linearly interpolated by the game phase. Here we examine the full pipeline design, which is the foundation of every strong classical engine.

==== Phase Calculation Refined

The Kaufman phase calculation (knight=1, bishop=1, rook=2, queen=4, total=24) is widely used but has limitations. A more refined phase calculation can:

1. *Include pawns*: Pawns are worth approximately 1/4 of a minor piece in phase terms. Including pawns makes the phase more granular.
2. *Use actual piece values*: The phase weight is proportional to the tapered value of each piece.
3. *Separate mg/eg phase*: Some engines compute separate phase values for mg and eg terms, allowing terms that are "middlegame only" or "endgame only."

```c
// Refined phase calculation (including pawns)
typedef struct {
    int mg_weight;  // contribution to middlegame phase
    int eg_weight;  // contribution to endgame phase
} PhaseWeights;

PhaseWeights piece_phase[7] = {
    { 0, 0 },   // EMPTY
    { 1, 0 },   // PAWN
    { 2, 1 },   // KNIGHT
    { 2, 1 },   // BISHOP
    { 4, 2 },   // ROOK
    { 8, 4 },   // QUEEN
    { 0, 0 },   // KING
};

void calculate_phase(Position *pos, int *mg_phase, int *eg_phase) {
    *mg_phase = *eg_phase = 0;
    for (int sq = 0; sq < 64; sq++) {
        int piece = piece_type(pos->board[sq]);
        *mg_phase += piece_phase[piece].mg_weight;
        *eg_phase += piece_phase[piece].eg_weight;
    }
}
```

The `MAX_MG_PHASE` (starting position) would be 16 pawns × 1 + 4 knights × 2 + 4 bishops × 2 + 4 rooks × 4 + 2 queens × 8 = 64. The actual phase ratio is `mg_phase / eg_phase`, which typically runs from 1.0 (middlegame) down to 0.0 (endgame).

==== The Score Pair as a Fundamental Type

In a tapered evaluation, nearly every function returns a *pair* of scores, not a single value:

```c
#define S(mg, eg) ((Score){ .mg = (mg), .eg = (eg) })

Score score_add(Score a, Score b) {
    return S(a.mg + b.mg, a.eg + b.eg);
}

Score score_sub(Score a, Score b) {
    return S(a.mg - b.mg, a.eg - b.eg);
}

Score score_mul(Score a, int factor) {
    return S(a.mg * factor, a.eg * factor);
}
```

The entire evaluation pipeline operates on `Score` pairs, and the final interpolation happens only once at the end:

```c
int evaluate(Position *pos) {
    int mg_phase, eg_phase;
    calculate_phase(pos, &mg_phase, &eg_phase);

    Score s = S(0, 0);
    s = score_add(s, evaluate_material(pos));
    s = score_add(s, evaluate_pst(pos));
    s = score_add(s, evaluate_pawns(pos));
    s = score_add(s, evaluate_mobility(pos));
    s = score_add(s, evaluate_king_safety(pos));
    s = score_add(s, evaluate_passed_pawns(pos));
    s = score_add(s, evaluate_imbalance(pos));
    s = score_add(s, evaluate_space(pos));
    s = score_add(s, evaluate_initiative(pos));

    // Single interpolation at the end
    int score = (s.mg * mg_phase + s.eg * (MAX_EG_PHASE - eg_phase)) / MAX_EG_PHASE;
    score += pos->side == WHITE ? TEMPO : -TEMPO;
    return score;
}
```

This design is modular: each evaluation component can be developed, tested, and tuned independently. Adding a new term is as simple as writing a new function returning a `Score` pair and adding it to the pipeline.

==== Evaluation Caching

Many evaluation terms are expensive to compute but change infrequently. *Pawn hash tables*, *material hash tables*, and *evaluation caches* are the standard solution.

*Pawn Hash Table*: Pawn structure changes only on pawn moves, captures, or promotions—roughly 15-25% of all moves. Caching the pawn evaluation in a small hash table (16K-256K entries) eliminates redundant pawn structure computation:

```c
typedef struct {
    uint64_t pawn_hash;  // hash of pawn positions
    Score    pawn_score; // cached pawn evaluation (mg + eg)
} PawnHashEntry;

PawnHashEntry pawn_hash_table[PAWN_HASH_SIZE];

Score evaluate_pawns_cached(Position *pos) {
    uint64_t pawn_hash = pos->pawn_hash;  // incrementally updated
    PawnHashEntry *entry = &pawn_hash_table[pawn_hash % PAWN_HASH_SIZE];

    if (entry->pawn_hash == pawn_hash) {
        return entry->pawn_score;  // cache hit!
    }

    // Cache miss: compute from scratch
    Score s = evaluate_pawns_raw(pos);
    entry->pawn_hash  = pawn_hash;
    entry->pawn_score = s;
    return s;
}
```

The pawn hash typically gives a 75-85% hit rate, eliminating most redundant pawn evaluations. This is a pure speed optimization (no ELO change, just faster search).

*Material Hash Table*: Material configuration (how many of each piece each side has) changes even less frequently than pawn structure. A material hash caches material balance and imbalance terms:

```c
typedef struct {
    uint32_t material_hash;  // compact hash of material counts
    Score    material_score;
    int      game_phase;
} MaterialEntry;
```

=== Material Imbalance Tables

Standard material counting assumes piece values are additive: two knights are worth exactly double a single knight. But this is not true. Certain material combinations have synergistic or antagonistic effects that simple addition does not capture.

==== Kaufman's Material Imbalances

Grandmaster Larry Kaufman (who later became a key contributor to Komodo and Stockfish) published a series of empirical studies on material imbalances based on statistical analysis of millions of master games. His key findings:

1. *The Exchange* (rook vs minor piece): In the middlegame, a rook is worth about 1.75 pawns more than a minor piece. In the endgame, this grows to 2.0-2.25 pawns. Therefore, "winning the exchange" (trading a knight/bishop for a rook) is worth ~175 centipawns in the middlegame and ~210 centipawns in the endgame.

2. *Queen vs Two Rooks*: Two rooks are worth roughly 1.25 queens in the middlegame and 1.1 queens in the endgame. Without pawns, two rooks beat a queen. With many pawns, the queen's mobility makes it competitive.

3. *Bishop Pair*: Two bishops beat bishop+knight by about 50 centipawns, and beat two knights by about 75 centipawns (all else equal). The bishop pair bonus is non-linear: it depends on how many pawns are on the board (more pawns = more closed position = smaller bonus) and how many open diagonals exist.

4. *Wrong-Colored Bishop*: In the endgame, if one side has only a bishop and the opponent's remaining pawns are all on the opposite color squares, the bishop is nearly useless. This "wrong-colored bishop" endgame is worth a penalty of 50-100 centipawns.

5. *Knight vs Bishop*: In positions with many pawns (especially locked pawns), knights gain about 10-20 centipawns relative to bishops. In open positions where both sides have pawns on both wings, bishops gain about 15-25 centipawns.

==== Imbalance Table Implementation

Rather than hand-coding each imbalance, we use an *imbalance table*: a lookup table indexed by the material difference in each piece type:

```c
// Imbalance table: bonus/malus for piece count differences
// Index: [our_knights][our_bishops][our_rooks][our_queens]
//         [their_knights][their_bishops][their_rooks][their_queens]
// Too large for naive approach! Use factorization.

int imbalance_table[IMBALANCE_SIZE];  // indexed by material signature

int material_signature(Position *pos, int side) {
    int count[2][7] = {0};
    // Count pieces...
    // Encode as a compact integer:
    int sig = 0;
    sig = (sig * 3 + count[side][KNIGHT]) % IMBALANCE_SIZE;
    sig = (sig * 3 + count[side][BISHOP]) % IMBALANCE_SIZE;
    sig = (sig * 3 + count[side][ROOK])   % IMBALANCE_SIZE;
    sig = (sig * 3 + count[side][QUEEN])  % IMBALANCE_SIZE;
    sig = (sig * 3 + count[!side][KNIGHT]) % IMBALANCE_SIZE;
    sig = (sig * 3 + count[!side][BISHOP]) % IMBALANCE_SIZE;
    sig = (sig * 3 + count[!side][ROOK])   % IMBALANCE_SIZE;
    sig = (sig * 3 + count[!side][QUEEN])  % IMBALANCE_SIZE;
    return sig;
}
```

In practice, the imbalance table is smaller than the full combinatorial space because many piece-count combinations are impossible (no one has more than 9 queens). A typical table uses 8K-32K entries, each containing an mg/eg score pair, precomputed from statistical analysis or texel tuning.

==== Quadratic Imbalances

Beyond pairwise imbalances, there are *quadratic* interactions: the value of having two bishops AND a knight, or a queen AND a knight, differs from the sum of the individual pairwise interactions. These are captured by a more general imbalance formulation:

```c
// Quadratic imbalance: count_a[i] * count_b[j] interacts
int evaluate_quadratic_imbalance(Position *pos) {
    int counts[2][6] = {0};
    // ... fill counts ...

    int score = 0;
    for (int p1 = PAWN; p1 <= QUEEN; p1++) {
        for (int p2 = PAWN; p2 <= QUEEN; p2++) {
            score += counts[WHITE][p1] * counts[BLACK][p2] * quadratic_imbalance[p1][p2].mg;
            // ... similarly for endgame
        }
    }
    return score;
}
```

This is more expensive but more accurate, capturing effects like "the exchange is worth more when the opponent has the bishop pair."

=== Advanced Passed Pawn Evaluation

Passed pawns were introduced in Chapter 11. Here we develop the full theory.

==== What Makes a Passed Pawn Dangerous?

A passed pawn is evaluated on multiple dimensions:

1. *Rank*: How close to promotion? Each rank adds roughly +5 to +15 centipawns.
2. *Connected/Protected*: A passed pawn defended by another pawn is much stronger because the defending pawn prevents the opponent from simply blockading with the king. Bonus: +10 to +30 centipawns.
3. *Unstoppable*: A passed pawn that the opponent's king cannot reach in time to stop from queening is worth +800 to +1200 centipawns (nearly a full queen). Detecting unstoppable pawns requires a short "pawn race" calculation.
4. *Outside passed pawn*: A passed pawn far from the main theater of action (e.g., a-pawn while kings are on the kingside) is especially dangerous because it distracts the opponent's king. Bonus: +10 to +20 centipawns.
5. *Blockaded*: A passed pawn blockaded by an enemy piece (especially a knight) loses much of its value. Penalty: -20 to -40 centipawns.
6. *King proximity*: If the friendly king supports the pawn's advance, bonus. If the enemy king is nearby and can stop it, penalty.

==== Passed Pawn Evaluation Function

```c
Score evaluate_passed_pawns(Position *pos) {
    Score s = {0, 0};
    int phase = calculate_phase(pos);

    // White passed pawns
    uint64_t w_passed = passed_pawn_mask(pos, WHITE);
    while (w_passed) {
        int sq = pop_lsb(&w_passed);
        int rank = square_rank(sq);  // 0-7, 0=rank1
        Score bonus = passed_pawn_bonus[rank];  // precomputed by rank

        // Connected bonus
        if (is_supported_by_friendly_pawn(pos, WHITE, sq))
            bonus = score_add(bonus, PASSED_CONNECTED_BONUS);

        // Unstoppable?
        if (is_unstoppable(pos, sq, WHITE))
            bonus = score_add(bonus, PASSED_UNSTOPPABLE_BONUS);

        // Blockaded?
        if (is_blockaded(pos, sq, WHITE))
            bonus = score_mul(bonus, 1, 2);  // halve the bonus (roughly)

        // King support
        int w_king_sq = pos->white_king_sq;
        int dist_to_passer = max(abs(square_file(w_king_sq) - square_file(sq)),
                                  abs(square_rank(w_king_sq) - square_rank(sq)));
        bonus.eg += max(0, 5 - dist_to_passer) * KING_PROXIMITY_BONUS.eg;

        s = score_add(s, bonus);
    }

    // Black passed pawns (subtract from score)
    // ... analogous ...

    return s;
}
```

==== The Passed Pawn Race (Unstoppable Detection)

The most dramatic passed pawn evaluation is detecting an *unstoppable* pawn. The algorithm: compute the number of moves required for the pawn to promote, and the number of moves required for the enemy king to reach the promotion square. If the pawn promotes first and the enemy king cannot capture it or blockade the promotion square, the pawn is unstoppable.

```c
bool is_unstoppable(Position *pos, int pawn_sq, int color) {
    int promo_sq = promotion_square(pawn_sq, color);
    int pawn_moves = 7 - square_rank(pawn_sq);  // number of advances needed

    // Enemy king's distance to the promotion square
    int enemy_king_sq = color == WHITE ? pos->black_king_sq : pos->white_king_sq;
    int king_moves = chebyshev_distance(enemy_king_sq, promo_sq);

    // Side to move matters: if it's the pawn's turn, the pawn moves first
    int side_to_move = (pos->side == color) ? 0 : 1;

    if (pawn_moves + side_to_move < king_moves) {
        // Pawn promotes before king can reach
        return true;
    }

    // Also check if the pawn blocks the king's path (the "square rule")
    // More sophisticated: simulate the race with a short search
    return false;
}
```

This detection transforms the evaluation: finding an unstoppable passed pawn adds nearly a queen's worth of value (800+ centipawns), which can cause the search to correctly identify winning pawn advances that were previously invisible.

==== Protected and Connected Passed Pawns

A *protected* passed pawn is defended by another pawn (so the king cannot safely capture it). A *connected* passed pawn has a friendly pawn on an adjacent file, also passed or about to become passed. These formations are exponentially more dangerous:

```c
Score passed_eval_by_type[] = {
    S( 0,  0),  // isolated passed pawn (base, per-rank bonus applied separately)
    S(15, 30),  // protected passed pawn
    S(20, 40),  // connected passed pawns
    S(40, 80),  // two connected passed pawns on adjacent files
};
```

Two connected passed pawns on the 6th rank typically win against a rook, so the bonus must be large enough to reflect this.

=== Space Evaluation

*Space* is the portion of the board controlled by a player, measured as the number of squares attacked (by pawns and pieces) on the opponent's side of the board. Space advantage is correlated with positional advantage: controlling more squares gives more options, restricts the opponent's pieces, and creates attacking chances.

```c
Score evaluate_space(Position *pos) {
    Score s = {0, 0};
    int phase = calculate_phase(pos);

    // White's space: squares attacked by White pieces that are on ranks 1-3
    uint64_t white_space = SQUARES_RANK_1_TO_3;  // White's "territory"
    uint64_t white_attacks = compute_all_attacks(pos, WHITE);
    int white_space_count = popcount(white_attacks & white_space);

    // Black's space: squares attacked by Black pieces on ranks 6-8
    uint64_t black_space = SQUARES_RANK_6_TO_8;
    uint64_t black_attacks = compute_all_attacks(pos, BLACK);
    int black_space_count = popcount(black_attacks & black_space);

    int space_diff = white_space_count - black_space_count;
    s.mg = (space_diff * SPACE_WEIGHT_MG) / 8;  // normalize by typical counts
    s.eg = (space_diff * SPACE_WEIGHT_EG) / 8;

    return s;
}
```

Space is primarily a middlegame concept. In the endgame, space advantage matters less because piece counts are lower and attacking squares is less meaningful.

=== Initiative and Complexity

Some positions are "active" — one side has threats, the opponent must respond. The *initiative* bonus rewards the side with active threats, compensating for slight material deficits:

```c
int evaluate_initiative(Position *pos) {
    int score = 0;

    // Bishop attacking the opponent's king side (hints at an attack)
    if (bishop_attacks_king_zone(pos, WHITE)) score += 10;
    if (bishop_attacks_king_zone(pos, BLACK)) score -= 10;

    // Knight near the opponent's king
    // ...

    // Rook on the 7th rank
    if (pos->rooks & WHITE_BB & RANK_7) score += 15;
    if (pos->rooks & BLACK_BB & RANK_2) score -= 15;

    return score;
}
```

The initiative bonus is small (10-30 cp) but can swing decisions in dynamic positions where the engine might otherwise be too materialistic.

*Complexity* is a measure of how many unresolved tactical motifs exist in the position. High-complexity positions are difficult for both humans and engines. Some engines use complexity to modulate search depth (search deeper in complex positions) or to avoid simplifications when behind (complicating matters can create swindling chances).

=== Draw Detection and Drawishness

Chess has many positions where one side is nominally ahead but the game is a theoretical draw. Recognizing these draws in the evaluation prevents the engine from overestimating its advantage and making poor decisions.

==== Common Drawn Endgames

1. *Insufficient mating material*: King vs King, King+Knight vs King, King+Bishop vs King. These are trivially drawn and should evaluate to exactly 0.

2. *Knight+Bishop vs King*: Technically a win, but requires up to 33 moves with perfect play. Engines must handle the 50-move rule and correctly evaluate this as winning but "practically drawn" if beyond a certain distance.

3. *Rook pawn + wrong bishop*: King+Bishop+RP (rook pawn on the a or h file) where the bishop does not control the promotion square. This is drawn because the defending king can occupy the corner and cannot be forced out.

4. *Knight vs Pawn*: Many positions are drawn because the knight can sacrifice itself for the last pawn. The engine must recognize that the knight can give itself up.

==== Drawishness Heuristics

Beyond theoretical draws, many positions are "drawish" — the winning chances are low even with a material advantage:

- *Opposite-colored bishops*: With only bishops on opposite colors remaining, even a one-pawn advantage is often drawn because the defender's bishop controls the promotion squares of the opposite color.
- *Blocked pawn center*: When all center pawns are locked, piece advantages may not be enough to win.
- *Queen vs Rook endgames*: Queen + King vs Rook + King is technically won, but requires 30+ moves of perfect play. Many engines scale down the evaluation in this endgame.

The standard approach: add a *drawishness factor* that scales the evaluation toward zero:

```c
int scale_factor = calculate_drawishness(pos);  // 0 to 128 (representing 0% to 100%)
return (score * scale_factor) / 128;
```

Where `scale_factor` is low when the position is drawish and high when the position is sharp.

=== Trapped Pieces

Certain piece placements are disastrously bad, not captured by PSTs. A *trapped bishop* (e.g., on a7 after b6, or on h6 after g5) is worth a penalty because it has no safe squares. A *trapped rook* in the corner or on a closed file wastes its mobility.

```c
int evaluate_trapped_pieces(Position *pos) {
    int score = 0;

    // White bishop on a7 with b6 pawn blocking (example)
    if (pos->board[A7] == WHITE_BISHOP && pos->board[B6] == BLACK_PAWN) {
        uint64_t bishop_moves = bishop_attacks(A7, occupied) & ~friendly;
        if (popcount(bishop_moves) <= 1) {  // only one (or zero) safe squares
            score -= TRAPPED_BISHOP_PENALTY;  // e.g., 120 cp
        }
    }

    // Similarly for other trapped piece patterns...

    return score;
}
```

Trapped piece detection adds maybe 2-5 ELO (small but consistent) and prevents embarrassing blunders where the engine fails to see a piece is about to be lost.

=== King Safety with Attack Tables

The simple king safety from Chapter 11 counts attackers and defenders. A more sophisticated approach uses *attack tables*: for each square in the king zone, we weight the attack by chess principles:

```c
// King zone: 12 squares around the king (4 corners excluded for efficiency)
int king_zone_bonus[64] = {
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 2, 3, 3, 2, 1, 0,
    0, 2, 4, 6, 6, 4, 2, 0,
    0, 3, 6, 9, 9, 6, 3, 0,
    0, 3, 6, 9, 9, 6, 3, 0,
    0, 2, 4, 6, 6, 4, 2, 0,
    0, 1, 2, 3, 3, 2, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
```

Each square in the king zone has a weight proportional to how dangerous an attack on that square is. Squares directly adjacent to the king (weight 9) are more dangerous than squares two away (weight 4). An enemy piece attacking a 9-weight square contributes more to the king danger score than one attacking a 1-weight square.

Combined with piece-type attack weights:

```c
int attack_weight[7] = {0, 0, 2, 2, 3, 4, 0};  // pawn, knight, bishop, rook, queen

int evaluate_king_safety_advanced(Position *pos, int king_sq, int attacker) {
    int danger = 0;
    uint64_t king_zone = KING_ZONE_BB[king_sq];
    uint64_t enemies = pos->pieces[attacker][ALL];

    // For each enemy piece type...
    for (int pt = KNIGHT; pt <= QUEEN; pt++) {
        uint64_t pieces = pos->pieces[attacker][pt];
        while (pieces) {
            int sq = pop_lsb(&pieces);
            uint64_t attacks = piece_attacks(pt, sq, occupied) & king_zone;
            while (attacks) {
                int target = pop_lsb(&attacks);
                danger += king_zone_bonus[target] * attack_weight[pt];
            }
        }
    }

    // Nonlinear: danger * danger / 32
    return -(danger * danger) / 32;
}
```

This produces king safety values of -50 to -500 centipawns, with heavily attacked kings getting severely punished. The quadratic dependence (`danger^2`) means the penalty grows nonlinearly, correctly modeling that a king with 2 attackers is more than 2× as dangerous as with 1 attacker.

=== Evaluation Grain Size and Interpolation Details

The evaluation function returns integer centipawns. But internally, terms can be computed at higher precision (e.g., 1/4 cp) to avoid rounding bias from the tapering.

```c
// Internal evaluation: 4× centipawn units
Score evaluate_internal(Position *pos) {
    Score s = {0, 0};
    // ... all terms in 4× cp ...
    return s;
}

// External: convert to centipawns
int evaluate(Position *pos) {
    Score s = evaluate_internal(pos);
    int phase = calculate_phase(pos);
    int cp = (s.mg * phase + s.eg * (MAX_PHASE - phase)) / (MAX_PHASE * 4);
    return cp + (pos->side == WHITE ? TEMPO : -TEMPO);
}
```

This avoids the "sawtooth" effect where alternating interpolation rounding causes evaluations to oscillate as the phase changes.

==== Edge Cases

- *Evaluation overflow*: Scores near `+-MATE_SCORE` must be avoided for non-mate positions, or they'll confuse the search. Clamp to `+-MATE_SCORE - 1000` for heuristic evaluations.
- *Draw score*: Stalemate and insufficient material should return exactly 0, not a small heuristic score.
- *Fortress detection*: Positions where the defending side has built an impenetrable fortress should evaluate near 0 despite a material deficit.

=== Texel Tuning Connection

All the parameters discussed (piece values, PST entries, pawn structure weights, mobility bonuses, king safety weights, imbalance table entries) must be tuned to maximize playing strength. Texel tuning (Chapter 17) is the systematic method for optimizing these parameters against a database of positions with known outcomes.

The typical tuning pipeline:
1. Start with reasonable hand-crafted values.
2. Generate 1-10 million self-play positions with known results.
3. Use logistic regression to adjust weights to maximize the correlation between eval and result.
4. Validate by playing matches against the untuned version.
5. Iterate: tune, test, tune, test...

A well-tuned classical evaluation can gain 50-100 ELO over a hand-tuned one. The NNUE approach (Chapter 13) essentially automates this process and extends it to enormous feature sets.

=== Summary

Advanced evaluation extends the classical framework with:

- *Sophisticated phase calculation and interpolation*: Every term returns an mg/eg pair, linearly interpolated by phase.
- *Material imbalance tables*: Precomputed tables capture non-additive material interactions (bishop pair, exchange, queen vs two rooks).
- *Passed pawn theory*: Rank-dependent bonuses, protection/connection bonuses, and unstoppable pawn detection.
- *Space, initiative, and complexity*: Higher-level positional concepts that correlate with winning chances.
- *Draw detection*: Recognizing theoretically drawn endgames and applying drawishness scaling prevents overestimation.
- *Advanced king safety*: Quadratic attack-weight formulas with king-zone square weighting.
- *Trapped piece detection*: Pattern-based penalties for badly placed pieces.

Combined with texel tuning (Chapter 17), the classical evaluation framework can reach approximately 2900-3100 ELO—roughly the level of engines like Crafty, Fruit, and early Stockfish (pre-NNUE). The next chapter covers NNUE, which extends evaluation to the 3500+ ELO level by replacing handcrafted features with learned neural networks.
