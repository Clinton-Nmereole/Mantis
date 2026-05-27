== Static Evaluation: Material, Position, and Piece-Square Tables

The evaluation function is the heart of a chess engine—the component that answers the question "How good is this position for White?" Every node in the search tree eventually terminates at an evaluation call. If the evaluation function is inaccurate, the engine will make poor decisions no matter how deep it searches. If it is too slow, the search will not reach sufficient depth.

Modern evaluation functions exist on a spectrum from simple material counters to billion-parameter neural networks. But every engine, from the simplest hobby project to Stockfish, follows the same basic architecture: an evaluation pipeline that scores a position as a signed integer, typically in centipawns (1 pawn = 100 centipawns), where positive values favor White and negative values favor Black. This chapter covers the *classical* evaluation approach—handcrafted heuristics based on chess knowledge. The NNUE approach (Chapter 13) represents the modern alternative, but understanding classical evaluation is essential because NNUE is essentially a learned replacement for (and generalization of) these handcrafted features.

=== The Evaluation Function as a Heuristic

An evaluation function is necessarily a heuristic: it cannot be perfectly accurate because chess is not solved (and likely never will be for the standard starting position). The evaluation function must estimate the true game-theoretic value of a position based on observable features, and it must do so quickly enough to be called millions of times per second.

==== Desiderata for an Evaluation Function

A good evaluation function should:

1. *Be fast*: Target 1-5 million evaluations per second for a classical eval on modern hardware. NNUE is even faster at 10-20 million evaluations per second.
2. *Be consistent*: Similar positions should have similar evaluations. A one-square difference in king position should not flip the evaluation by a pawn unless there is a genuine tactical reason.
3. *Correlate with game outcome*: In positions that are objectively drawn, the eval should be near zero. In winning positions, it should accurately reflect the winning margin.
4. *Be monotonic in material*: Trading a queen for a pawn should always decrease the evaluation for the side losing the queen, regardless of positional compensation. (In practice, engines sometimes break this rule when positional compensation is huge, but it is a guiding principle.)
5. *Handle all game phases*: The evaluation should smoothly transition between opening, middlegame, and endgame—what matters in the opening (development, center control) matters less in the endgame (pawn promotion, king activity).

==== The Evaluation Pipeline

At its simplest, the evaluation pipeline looks like this:

```
Score = Material(p) + Positional(p)
```

But in practice, it is far richer:

```
Score = Tempo
      + MaterialCount(mg_weight, eg_weight)
      + PieceSquareTables[piece][square](phase)
      + PawnStructure(phase)
      + Mobility(phase)
      + KingSafety(phase)
      + ImbalanceTerms(phase)
      + PassedPawns(phase)
      + MiscTerms(phase)
```

Where `phase` interpolates between middlegame and endgame, and each term is computed independently and summed. The key insight: the evaluation is *composable*. Each term is computed by a separate subroutine and added to a running total. This modularity makes it easy to add, remove, or tune individual features.

=== Material Counting: The Foundation

The most basic evaluation term is material: the sum of piece values. No matter how sophisticated the positional evaluation, getting the material count right is paramount—a one-pawn error in material will override nearly every positional consideration.

==== Standard Piece Values

The canonical piece values (in centipawns) used by most engines:

```text
Piece      Value (cp)    Notes
────────   ───────────   ──────────────────────────────
Pawn       100           The unit of measurement
Knight     320-325       Approximately 3 pawns
Bishop     330-335       Slightly more than knight
Rook       500-510       Approximately 5 pawns
Queen      900-1000      Approximately 9 pawns
King       0 (infinite)  King capture ends the game
```

But these are approximations. In reality, piece values are *context-dependent*:

- A knight is worth more than a bishop in closed positions (many pawns blocking diagonals).
- A bishop is worth more than a knight in open positions (clear diagonals) and in endgames with pawns on both wings.
- Two bishops are worth more than the sum of their parts (the bishop pair bonus, approximately +50 cp). This is because bishops complement each other, controlling both color complexes, and a single bishop can only control half the squares.
- Rooks gain value in open files and in the endgame (where the board is open).
- Queens lose some relative value in the early opening (they can be harassed by minor pieces).

==== Tapered Evaluation

A critical innovation in evaluation is the *tapered* approach, where each material value has two components: a middlegame value (mg) and an endgame value (eg). The actual value is interpolated based on the *phase* of the game:

```
value = mg_value * phase + eg_value * (1 - phase)
```

Where `phase` ranges from 0 (pure endgame) to 1 (pure middlegame). The phase is computed from the material remaining on the board. A common formula:

```
phase = min(1.0, total_material / MAX_MATERIAL)
```

where `total_material` counts only non-pawn material (knights, bishops, rooks, queens) weighted by typical values, and `MAX_MATERIAL` is the total at the start (4 knights + 4 bishops + 4 rooks + 2 queens ≈ 62 in Kaufman units). Specifically:

```text
phase = (knight_count * 1 + bishop_count * 1 + rook_count * 2 + queen_count * 4) / 24.0
```

In the starting position, `phase = 24/24 = 1.0` (pure middlegame). In a king + pawn endgame, `phase = 0` (pure endgame).

==== Tapered Piece Values

With tapered evaluation, each piece gets separate mg and eg values:

```text
Piece      MG (cp)    EG (cp)    Rationale
────────   ────────   ────────   ──────────────────────────────
Pawn       85         110        Pawns increase in value as promoting nears
Knight     345        290        Knights lose value in open endgames
Bishop     355        300        Bishops gain relative to knights in endgames
Rook       510        590        Rooks dramatically gain value in endgames
Queen      950        1010       Queens become slightly more valuable
```

Notice: in the middlegame, knights and bishops are nearly equal (345 vs 355). In the endgame, bishops pull ahead (300 vs 290) and rooks become much more important (590 vs 510). These values were derived from statistical analysis of millions of games (texel tuning, Chapter 17) and represent the optimal values for maximizing correlation with game outcomes.

==== Material Counting Implementation

```c
typedef struct {
    int mg;  // middlegame value
    int eg;  // endgame value
} Score;

Score piece_values[7] = {
    {   0,   0 },  // EMPTY
    {  85, 110 },  // PAWN
    { 345, 290 },  // KNIGHT
    { 355, 300 },  // BISHOP
    { 510, 590 },  // ROOK
    { 950, 1010 }, // QUEEN
    {   0,   0 },  // KING (value from PSTs)
};

Score evaluate_material(Position *pos) {
    Score score = {0, 0};
    for (int piece = PAWN; piece <= QUEEN; piece++) {
        score.mg += popcount(pos->pieces[WHITE][piece]) * piece_values[piece].mg;
        score.mg -= popcount(pos->pieces[BLACK][piece]) * piece_values[piece].mg;
        score.eg += popcount(pos->pieces[WHITE][piece]) * piece_values[piece].eg;
        score.eg -= popcount(pos->pieces[BLACK][piece]) * piece_values[piece].eg;
    }
    return score;
}
```

==== Phase Calculation

```c
int calculate_phase(Position *pos) {
    // Kaufman phase: count knights=1, bishops=1, rooks=2, queens=4
    static const int phase_weight[7] = {0, 0, 1, 1, 2, 4, 0};
    int phase = 0;
    for (int piece = KNIGHT; piece <= QUEEN; piece++) {
        phase += popcount(pos->pieces[WHITE][piece]) * phase_weight[piece];
        phase += popcount(pos->pieces[BLACK][piece]) * phase_weight[piece];
    }
    return phase;  // 0 (endgame) to 24 (middlegame)
}

// Linearly interpolate a Score based on phase
int score_to_cp(Score score, int phase) {
    return (score.mg * phase + score.eg * (24 - phase)) / 24;
}
```

==== Rust Implementation

```rust
#[derive(Copy, Clone)]
struct Score { mg: i32, eg: i32 }

impl Score {
    fn interpolate(self, phase: i32) -> i32 {
        (self.mg * phase + self.eg * (24 - phase)) / 24
    }
}

const PIECE_VALUES: [Score; 7] = [
    Score { mg: 0, eg: 0 },    // empty
    Score { mg: 85, eg: 110 }, // pawn
    Score { mg: 345, eg: 290 },// knight
    Score { mg: 355, eg: 300 },// bishop
    Score { mg: 510, eg: 590 },// rook
    Score { mg: 950, eg: 1010 },// queen
    Score { mg: 0, eg: 0 },    // king
];
```

==== Zig Implementation

```zig
const Score = struct { mg: i32, eg: i32 };

const piece_values = [7]Score{
    .{ .mg = 0,   .eg = 0 },
    .{ .mg = 85,  .eg = 110 },
    .{ .mg = 345, .eg = 290 },
    .{ .mg = 355, .eg = 300 },
    .{ .mg = 510, .eg = 590 },
    .{ .mg = 950, .eg = 1010 },
    .{ .mg = 0,   .eg = 0 },
};
```

==== Odin Implementation

```odin
Score :: struct { mg, eg: i32 }

piece_values := [7]Score{
    {0, 0},
    {85, 110},
    {345, 290},
    {355, 300},
    {510, 590},
    {950, 1010},
    {0, 0},
}
```

=== Piece-Square Tables (PSTs)

Piece-square tables are the single most powerful classical evaluation concept. The idea is simple but profound: a piece's value depends not just on what type it is, but also on *where it is on the board*. A knight on e4 (a central outpost) is worth more than a knight on a1 (the corner). A king on g1 behind a pawn shield is safe; a king on e4 in the middlegame is vulnerable.

==== What Are PSTs?

A piece-square table is a 64-element array (one entry per square) that gives a bonus or penalty for placing a piece of a given type on that square. The table is applied additively: the total evaluation includes the PST value for each square that contains a piece.

```c
// Example: Knight PST (White's perspective, middlegame)
int knight_pst_mg[64] = {
    -50, -40, -30, -30, -30, -30, -40, -50,
    -40, -20,   0,   5,   5,   0, -20, -40,
    -30,   5,  10,  15,  15,  10,   5, -30,
    -30,   0,  15,  20,  20,  15,   0, -30,
    -30,   5,  15,  20,  20,  15,   5, -30,
    -30,   0,  10,  15,  15,  10,   0, -30,
    -40, -20,   0,   0,   0,   0, -20, -40,
    -50, -40, -30, -30, -30, -30, -40, -50,
};
```

This table encodes the chess knowledge that knights prefer the center (+20 on d5/e5/e4/d4), tolerate the flanks (small negative on a4/h4), and dislike the corners (-50 on a1/h1). The table is symmetric across the vertical midline (mirrored left-right) and has quadrant symmetry.

==== How PSTs Are Used

For each piece on the board, we look up its PST value at its square and add it to the evaluation:

```c
Score evaluate_pst(Position *pos) {
    Score score = {0, 0};
    for (int sq = 0; sq < 64; sq++) {
        int piece = pos->board[sq];
        if (piece == EMPTY) continue;
        int color = piece_color(piece);
        int type  = piece_type(piece);
        int relative_sq = color == WHITE ? sq : mirror_square(sq);
        score.mg += (color == WHITE ? 1 : -1) * pst_mg[type][relative_sq];
        score.eg += (color == WHITE ? 1 : -1) * pst_eg[type][relative_sq];
    }
    return score;
}
```

The key detail: the PST is indexed by the *relative* square (from the piece's own perspective). For White, square index 0 is a1. For Black, we mirror the board so that Black's a8 (square index 56) maps to relative square 0, Black's b8 maps to 1, etc. This means we only need one set of PSTs per piece type, not two.

```c
int mirror_square(int sq) {
    return sq ^ 56;  // Flip rank: 0↔56, 1↔57, ..., 7↔63
}
```

==== PST Symmetry Principles

Good piece-square tables reflect chess knowledge and exhibit several symmetries:

1. *Centricity*: Central squares (d4, e4, d5, e5) have the highest bonuses for most pieces. Knights and bishops gain the most from centralization. Rooks are more complex: in the middlegame, rooks on the back rank are fine; in the endgame, rooks on the 7th rank are devastating.

2. *Rank-based progression*: Pawns gain value as they advance (closer to promotion). A pawn on the 7th rank is worth roughly 200-300 centipawns more than on the 2nd rank, even in the middlegame.

3. *King safety patterns*: The king's PST encodes castling position. In the middlegame, the king wants to be castled (g1/c1 for White) with pawns on f2/g2/h2 (the pawn shield). In the endgame, the king wants to be centralized.

4. *Mirror symmetry*: The table is symmetric across the vertical midline (files a=h, b=g, c=f, d=e). This means the left and right sides of the board are treated identically, which is correct.

5. *Piece-type variation*: Each piece type gets its own PST, and some pieces get fundamentally different PSTs in mg vs eg. For example, the king's PST flips from "stay in the corner" (mg) to "march to the center" (eg).

==== Constructing PSTs

How are PST values determined? There are three approaches:

1. *Manual construction*: A human expert writes values based on chess knowledge. This was the approach in early engines (pre-2000) and produces reasonable but suboptimal PSTs.

2. *Texel tuning*: A large database of positions with known outcomes (from self-play or human games) is used to optimize the PST values to maximize correlation with game results. This is the standard modern approach (Chapter 17).

3. *Learned from scratch*: The NNUE approach (Chapter 13) essentially learns PST-like features as part of the neural network, without explicit PST tables.

==== Detailed PST Examples

Let us examine plausible PSTs for each piece type, designed to encode chess principles. These are in centipawns, from White's perspective, for the middlegame.

*Pawn PST (Middlegame)*:

```c
int pawn_pst_mg[64] = {
     0,   0,   0,   0,   0,   0,   0,   0,  // rank 1
    50,  50,  50,  50,  50,  50,  50,  50,  // rank 2
    10,  10,  20,  30,  30,  20,  10,  10,  // rank 3
     5,   5,  10,  25,  25,  10,   5,   5,  // rank 4
     0,   0,   0,  20,  20,   0,   0,   0,  // rank 5
     5,  -5, -10,   0,   0, -10,  -5,   5,  // rank 6
     5,  10,  10, -20, -20,  10,  10,   5,  // rank 7
     0,   0,   0,   0,   0,   0,   0,   0,  // rank 8 (promotion, handled separately)
};
```

Pawns gain +50 bonus on their starting rank (development incentive). Central pawns (d/e files) are worth more on ranks 3-6. Pawns on the 7th rank get a bonus (queening threat), but note that the near-promotion bonus is typically handled by passed-pawn evaluation rather than PST.

*Knight PST (Middlegame)* — as shown above, with central squares (d4/e4/d5/e5) getting +20.

*Bishop PST (Middlegame)*:

```c
int bishop_pst_mg[64] = {
    -20, -10, -10, -10, -10, -10, -10, -20,
    -10,   0,   0,   0,   0,   0,   0, -10,
    -10,   0,   5,  10,  10,   5,   0, -10,
    -10,   5,   5,  10,  10,   5,   5, -10,
    -10,   0,  10,  10,  10,  10,   0, -10,
    -10,  10,  10,  10,  10,  10,  10, -10,
    -10,   5,   0,   0,   0,   0,   5, -10,
    -20, -10, -10, -10, -10, -10, -10, -20,
};
```

Bishops want open diagonals. The central squares on the long diagonals (a1-h8, a8-h1) are particularly valuable. Note the slightly different pattern from knights—bishops on the long diagonals (a1, h8) get value because they control key squares.

*Rook PST (Middlegame)*:

```c
int rook_pst_mg[64] = {
     0,   0,   0,   0,   0,   0,   0,   0,  // rank 1 (back rank is fine for rooks)
     5,  10,  10,  10,  10,  10,  10,   5,  // rank 2
    -5,   0,   0,   0,   0,   0,   0,  -5,  // rank 3
    -5,   0,   0,   0,   0,   0,   0,  -5,  // rank 4
    -5,   0,   0,   0,   0,   0,   0,  -5,  // rank 5
    -5,   0,   0,   0,   0,   0,   0,  -5,  // rank 6
    -5,   0,   0,   0,   0,   0,   0,  -5,  // rank 7
     0,   0,   0,   5,   5,   0,   0,   0,  // rank 8 (but White rooks never start here)
};
```

Rooks are unique: they do not gain much from centralization in the middlegame. Instead, they value open files and the 7th rank (evaluated separately as mobility/bonus terms). The PST mainly penalizes rooks placed passively. In the *endgame* PST, rooks get large bonuses for centralization and 7th rank occupation.

*Queen PST (Middlegame)*:

```c
int queen_pst_mg[64] = {
    -20, -10, -10,  -5,  -5, -10, -10, -20,
    -10,   0,   0,   0,   0,   0,   0, -10,
    -10,   0,   5,   5,   5,   5,   0, -10,
     -5,   0,   5,   5,   5,   5,   0,  -5,
      0,   0,   5,   5,   5,   5,   0,   0,
    -10,   5,   5,   5,   5,   5,   0, -10,
    -10,   0,   5,   0,   0,   0,   0, -10,
    -20, -10, -10,  -5,  -5, -10, -10, -20,
};
```

The queen is penalized for early centralization (she becomes a target). The middlegame PST mildly encourages keeping the queen a bit back. In the endgame PST, the queen is heavily rewarded for centralization.

*King PST* — the most dramatically different between mg and eg:

```c
int king_pst_mg[64] = {
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -20, -30, -30, -40, -40, -30, -30, -20,
    -10, -20, -20, -20, -20, -20, -20, -10,
     20,  20,   0,   0,   0,   0,  20,  20,  // castled position
     20,  30,  10,   0,   0,  10,  30,  20,  // castled + pawn shield
};

int king_pst_eg[64] = {
    -50, -40, -30, -20, -20, -30, -40, -50,
    -30, -20, -10,   0,   0, -10, -20, -30,
    -30, -10,  20,  30,  30,  20, -10, -30,
    -30, -10,  30,  40,  40,  30, -10, -30,
    -30, -10,  30,  40,  40,  30, -10, -30,
    -30, -10,  20,  30,  30,  20, -10, -30,
    -30, -30,   0,   0,   0,   0, -30, -30,
    -50, -30, -30, -30, -30, -30, -30, -50,
};
```

In the middlegame, the king is safest castled (g1/c1) with high penalties (-50) for being in the center. In the endgame, this flips entirely: the center gives +40 bonuses, and the edges are punishing (-50 on a1/a8).

==== Implementation with Tapered PSTs

Each piece type gets two PSTs (mg and eg), and the evaluation interpolates between them using phase:

```c
int evaluate_piece_pst(Position *pos, int sq, int piece) {
    int color = piece_color(piece);
    int type  = piece_type(piece);
    int rsq   = color == WHITE ? sq : mirror_square(sq);
    int sign  = color == WHITE ? 1 : -1;
    // Tapered interpolation:
    int pst_value = (pst_mg[type][rsq] * phase + pst_eg[type][rsq] * (24 - phase)) / 24;
    return sign * pst_value;
}
```

==== Combined Material + PST

The complete classical evaluation foundation combines material and PST:

```c
Score evaluate(Position *pos) {
    Score score = {0, 0};
    int phase = calculate_phase(pos);

    for (int sq = 0; sq < 64; sq++) {
        int piece = pos->board[sq];
        if (piece == EMPTY) continue;

        int color = piece_color(piece);
        int type  = piece_type(piece);
        int rsq   = color == WHITE ? sq : mirror_square(sq);
        int sign  = color == WHITE ? 1 : -1;

        score.mg += sign * (piece_values[type].mg + pst_mg[type][rsq]);
        score.eg += sign * (piece_values[type].eg + pst_eg[type][rsq]);
    }

    return score;
}
```

This gives about 70% of the total evaluation accuracy. The remaining 30% comes from pawn structure, mobility, king safety, and other positional terms.

=== Pawn Structure Evaluation

Pawn structure is the "skeleton" of a chess position. Because pawns cannot move backward, pawn structure changes are permanent and define the strategic character of the position for the rest of the game. A deep understanding of pawn structure is what separates grandmasters from amateurs—and in engine terms, it is a critical evaluation component.

==== Isolated Pawns

An *isolated pawn* is a pawn with no friendly pawns on either adjacent file. Isolated pawns are weak because they cannot be defended by other pawns and become targets for enemy pieces (especially rooks in the endgame). The penalty is typically -10 to -20 centipawns per isolated pawn, depending on whether it is in the center (worse) or on the wing (less bad).

```c
int evaluate_isolated_pawns(Position *pos) {
    int score = 0;
    for (int file = 0; file < 8; file++) {
        uint64_t file_mask = FILE_A << file;
        uint64_t adjacent_mask = ((file > 0 ? FILE_A << (file - 1) : 0) |
                                   (file < 7 ? FILE_A << (file + 1) : 0));
        // For each color: if there are pawns on this file but none on adjacent files
        if ((pos->pawns & WHITE_BB & file_mask) &&
            !(pos->pawns & WHITE_BB & adjacent_mask)) {
            score -= ISOLATED_PAWN_PENALTY;  // e.g., 15
        }
        // Same for Black
    }
    return score;
}
```

*Doubled Pawns*: Two (or more) pawns of the same color on the same file. Doubled pawns are weaker than normal pawns because they cannot defend each other, and the rear pawn blocks the front pawn's mobility. Penalty: -15 to -25 centipawns per pair.

```c
if (popcount(pos->pawns & WHITE_BB & file_mask) >= 2) {
    score -= DOUBLED_PAWN_PENALTY * (popcount(pos->pawns & WHITE_BB & file_mask) - 1);
}
```

*Backward Pawns*: A pawn that cannot advance because the square in front is attacked by an enemy pawn, AND it cannot be defended by a friendly pawn because its adjacent-file friendly pawns are ahead of it. Backward pawns are structural weaknesses. Penalty: -10 to -15 centipawns.

*Passed Pawns*: A pawn with no enemy pawns on the same file or adjacent files that can block its advance. Passed pawns are potential queening threats and get large bonuses (Chapter 12 covers this in detail). For now, a simple bonus of +5 to +60 centipawns depending on rank.

==== Pawn Shield Evaluation

The *pawn shield* is the configuration of pawns in front of the castled king. A solid pawn shield (pawns on f2, g2, h2 for White castled kingside) protects the king from checks and attacks. A damaged pawn shield (pawns advanced or missing) exposes the king.

The pawn shield is evaluated by checking the integrity of pawns on the three files in front of the king's castling position:

```c
int evaluate_pawn_shield(Position *pos, int king_sq) {
    int king_file = square_file(king_sq);
    int king_rank = square_rank(king_sq);
    int shield = 0;

    // Check pawns on the king's file and adjacent files, one rank in front
    for (int f = max(0, king_file - 1); f <= min(7, king_file + 1); f++) {
        for (int r = king_rank; r <= king_rank + (pos->side == WHITE ? 2 : -2); ) {
            int sq = square(f, r);
            if (pos->board[sq] == (pos->side == WHITE ? WHITE_PAWN : BLACK_PAWN)) {
                shield += PAWN_SHIELD_BONUS;  // e.g., 20
                break;
            }
        }
    }
    return shield;
}
```

A perfect shield (f2, g2, h2 all present for White O-O) gives a full bonus. Missing pawns reduce the bonus. When the shield completely disappears, the king safety evaluation (below) applies heavy penalties.

*Open files near the king* are especially dangerous: an open g-file or h-file facing the castled king allows enemy rooks and queens to attack directly.

==== Pawn Chains

A *pawn chain* is a diagonal line of pawns, each defended by the pawn behind it. Pawn chains are strong because they control key squares and protect each other. The evaluation can reward pawn chains:

```c
if (pos->board[sq] == WHITE_PAWN && pos->board[sq + 7] == WHITE_PAWN) {
    score += PAWN_CHAIN_BONUS;  // e.g., 5 cp for each diagonal connection
}
```

Pawn chains are particularly important in French Defense and King's Indian Defense structures. The bonus encodes that pawns that can defend each other diagonally are stronger than isolated pawns.

==== C++ Pawn Structure Implementation

```cpp
class PawnStructure {
    static constexpr int ISOLATED   = -15;
    static constexpr int DOUBLED    = -20;
    static constexpr int BACKWARD   = -12;
    static constexpr int SHIELD     =  20;

    int evaluate(const Position& pos) {
        int score = 0;
        uint64_t pawns_w = pos.pieces(WHITE, PAWN);
        uint64_t pawns_b = pos.pieces(BLACK, PAWN);

        for (int f = 0; f < 8; f++) {
            uint64_t file_mask = FileBB[f];
            uint64_t adj_mask   = (f > 0 ? FileBB[f-1] : 0) | (f < 7 ? FileBB[f+1] : 0);

            // Isolated pawns (both sides)
            if ((pawns_w & file_mask) && !(pawns_w & adj_mask))
                score -= ISOLATED;
            if ((pawns_b & file_mask) && !(pawns_b & adj_mask))
                score += ISOLATED;

            // Doubled pawns
            int w_count = popcount(pawns_w & file_mask);
            int b_count = popcount(pawns_b & file_mask);
            score -= DOUBLED * max(0, w_count - 1);
            score += DOUBLED * max(0, b_count - 1);
        }
        return score;
    }
};
```

==== Rust Pawn Evaluation

```rust
fn evaluate_pawn_structure(pos: &Position) -> i32 {
    let mut score = 0;
    let pawns_w = pos.pieces(Color::White, Piece::Pawn);
    let pawns_b = pos.pieces(Color::Black, Piece::Pawn);

    for file in 0..8u8 {
        let file_mask = 1u64 << file;
        // Adjacent file masks (with bounds checking)
        let adj_mask = if file > 0 { 1u64 << (file - 1) } else { 0 }
                     | if file < 7 { 1u64 << (file + 1) } else { 0 };

        // Isolated
        if pawns_w & file_mask != 0 && pawns_w & adj_mask == 0 { score -= 15; }
        if pawns_b & file_mask != 0 && pawns_b & adj_mask == 0 { score += 15; }

        // Doubled
        let w_count = (pawns_w & file_mask).count_ones();
        let b_count = (pawns_b & file_mask).count_ones();
        score -= 20 * w_count.saturating_sub(1) as i32;
        score += 20 * b_count.saturating_sub(1) as i32;
    }
    score
}
```

=== Mobility Evaluation

*Mobility* is the number of legal moves available to a piece. More mobile pieces control more squares, threaten more enemy pieces, and have more tactical options. Mobility is a strong predictor of positional advantage.

Mobility is evaluated by counting the number of legal destination squares for each piece (or just non-pawn pieces, since pawn mobility is largely captured by PSTs) and applying a per-square bonus:

```c
int evaluate_mobility(Position *pos) {
    int score = 0;
    uint64_t occupied = pos->white_pieces | pos->black_pieces;

    // Knight mobility
    uint64_t knights = pos->pieces[WHITE][KNIGHT];
    while (knights) {
        int sq = pop_lsb(&knights);
        uint64_t attacks = knight_attacks[sq] & ~pos->white_pieces;
        score += popcount(attacks) * KNIGHT_MOBILITY_BONUS;  // ~4 cp per move
    }

    // Bishop mobility
    uint64_t bishops = pos->pieces[WHITE][BISHOP];
    while (bishops) {
        int sq = pop_lsb(&bishops);
        uint64_t attacks = bishop_attacks(sq, occupied) & ~pos->white_pieces;
        score += popcount(attacks) * BISHOP_MOBILITY_BONUS;  // ~3 cp per move
    }

    // Rook mobility
    uint64_t rooks = pos->pieces[WHITE][ROOK];
    while (rooks) {
        int sq = pop_lsb(&rooks);
        uint64_t attacks = rook_attacks(sq, occupied) & ~pos->white_pieces;
        score += popcount(attacks) * ROOK_MOBILITY_BONUS;  // ~2 cp per move
    }

    // Queen mobility
    uint64_t queens = pos->pieces[WHITE][QUEEN];
    while (queens) {
        int sq = pop_lsb(&queens);
        uint64_t attacks = queen_attacks(sq, occupied) & ~pos->white_pieces;
        score += popcount(attacks) * QUEEN_MOBILITY_BONUS;  // ~1 cp per move
    }

    // Subtract Black mobility similarly...

    return score;
}
```

Mobility is expensive to compute (it requires generating attacks for every piece), so it is often cached in the pawn hash or computed incrementally. Many engines only compute mobility for a subset of pieces or skip it entirely in high-speed search.

=== King Safety

King safety is the most important non-material evaluation term in the middlegame. A king under attack can lose the game even when the material balance is favorable. King safety evaluation combines:

1. *King zone attacks*: Count how many enemy pieces attack squares in the "king zone" (the 3×3 or 5×5 area around the king). Each attacker is weighted by type (queen attacks are more dangerous than knight attacks).

2. *Pawn shield integrity*: As discussed above. Missing or advanced pawns reduce the shield bonus.

3. *Open files near the king*: Enemy rooks on open files adjacent to the king's file are severely penalized.

4. *Defender count*: Friendly pieces near the king can defend against attacks, partially offsetting attacker bonuses.

```c
int evaluate_king_safety(Position *pos, int king_sq, int side) {
    int score = 0;
    int king_zone = KING_ZONE[king_sq];  // bitboard of 8-12 squares around king

    // Count enemy attacks on the king zone
    int attack_weight = 0;
    uint64_t enemy = pos->pieces[!side][ALL];
    // For each enemy piece type, count attacks hitting the king zone
    attack_weight += count_attacks(KNIGHT, ...) * 2;
    attack_weight += count_attacks(BISHOP, ...) * 2;
    attack_weight += count_attacks(ROOK,   ...) * 3;
    attack_weight += count_attacks(QUEEN,  ...) * 4;

    // Count friendly defenders near the king
    int defender_bonus = count_defenders(...) * 1;

    // Combine: attacks weighted by phase (more important in middlegame)
    score = -(attack_weight * attack_weight / 16) + defender_bonus * 5;

    // Pawn shield
    score += evaluate_pawn_shield(pos, king_sq);

    // Open files near king
    for (int f = max(0, king_file - 1); f <= min(7, king_file + 1); f++) {
        if (is_open_file(pos, f)) score -= 30;
        if (is_semi_open_file(pos, f, !side)) score -= 20;
    }

    return score;
}
```

The `attack_weight * attack_weight / 16` formula is quadratic: the danger is nonlinear. Two attackers are more than twice as dangerous as one. This quadratic term is crucial for correctly evaluating attacks—it means that piling on attackers is heavily penalized, which encourages the engine to defend before the king zone is swarmed.

=== Piece Coordination and Bonuses

Several special piece configurations provide bonuses beyond mobility and PST:

*Bishop Pair*: Possessing both bishops while the opponent lacks at least one gives a bonus of +40 to +60 centipawns. This is one of the strongest non-material evaluation terms:

```c
if (popcount(pos->pieces[WHITE][BISHOP]) >= 2 &&
    popcount(pos->pieces[BLACK][BISHOP]) <  2) {
    score += BISHOP_PAIR_BONUS;
}
```

The bishop pair is powerful because the two bishops control all squares (one controls light squares, the other dark squares), and the opponent with a single bishop (or none) cannot contest one color complex.

*Rook on Open File*: A rook on a file with no pawns (open file) gets a bonus of +15 to +25 centipawns. A rook on a file with only enemy pawns (semi-open file) gets +10 to +15:

```c
for (int f = 0; f < 8; f++) {
    uint64_t file_bb = FILE_A << f;
    if (!(pos->pawns & file_bb)) {
        // Open file
        if (pos->rooks & WHITE_BB & file_bb) score += 20;
    } else if (!(pos->pawns & WHITE_BB & file_bb) && (pos->pawns & BLACK_BB & file_bb)) {
        // Semi-open for White
        if (pos->rooks & WHITE_BB & file_bb) score += 12;
    }
}
```

*Rook on 7th Rank*: A rook on the opponent's 2nd rank (our 7th rank for White) is famously powerful because it attacks the opponent's pawns from behind and restricts the opponent's king. Bonus: +30 to +50 centipawns.

*Knight Outpost*: A knight on a square that is defended by a friendly pawn and cannot be attacked by an enemy pawn is an "outpost." Outpost knights are worth an extra +20 to +40 centipawns because they are nearly impossible to dislodge:

```c
if (piece == WHITE_KNIGHT) {
    bool defended_by_pawn = (pawn_attacks[BLACK][sq] & pos->pawns & WHITE_BB) != 0;
    bool attacked_by_pawn  = (pawn_attacks[WHITE][sq] & pos->pawns & BLACK_BB) != 0;
    if (defended_by_pawn && !attacked_by_pawn) {
        score += KNIGHT_OUTPOST_BONUS;  // e.g., 30
    }
}
```

=== Tempo Bonus

The *tempo* bonus is a small adjustment (typically +10 to +30 centipawns) given to the side to move. It reflects the inherent advantage of having the initiative—being able to act rather than react. The tempo bonus is simply added to the evaluation at the end:

```c
score += (pos->side == WHITE) ? TEMPO_BONUS : -TEMPO_BONUS;  // e.g., 20
```

The tempo bonus serves a subtle but important purpose: it ensures that the evaluation is not symmetric when the position is symmetric. In an otherwise perfectly symmetric position, the side to move should have a slight advantage. Without a tempo bonus, the evaluation of a symmetric position would be exactly 0.00, which makes the engine indifferent. The tempo bonus gives a reason to prefer to be on move.

=== The Complete Classical Evaluation Function

Putting it all together, a complete classical evaluation function:

```c
int evaluate(Position *pos) {
    int phase = calculate_phase(pos);
    int score_mg = 0, score_eg = 0;

    // Material + PST (computed together for efficiency)
    for (int sq = 0; sq < 64; sq++) {
        int piece = pos->board[sq];
        if (piece == EMPTY) continue;
        int color = piece_color(piece);
        int type  = piece_type(piece);
        int rsq   = color == WHITE ? sq : mirror_square(sq);
        int sign  = color == WHITE ? 1 : -1;
        score_mg += sign * (piece_values[type].mg + pst_mg[type][rsq]);
        score_eg += sign * (piece_values[type].eg + pst_eg[type][rsq]);
    }

    // Pawn structure
    int pawn_mg = evaluate_pawn_structure_mg(pos);
    int pawn_eg = evaluate_pawn_structure_eg(pos);
    score_mg += pawn_mg;
    score_eg += pawn_eg;

    // Mobility (expensive - taper similarly)
    int mob_mg = evaluate_mobility_mg(pos);
    int mob_eg = evaluate_mobility_eg(pos);
    score_mg += mob_mg;
    score_eg += mob_eg;

    // King safety (middlegame only - in endgame, king is a fighting piece)
    int ks_mg = evaluate_king_safety_mg(pos);
    score_mg += ks_mg;
    // In endgame, king safety becomes king activity (handled by PST)

    // Piece coordination bonuses
    int coord_mg = evaluate_coordination_mg(pos);
    int coord_eg = evaluate_coordination_eg(pos);
    score_mg += coord_mg;
    score_eg += coord_eg;

    // Tapered interpolation
    int score = (score_mg * phase + score_eg * (24 - phase)) / 24;

    // Tempo
    score += (pos->side == WHITE) ? TEMPO_BONUS : -TEMPO_BONUS;

    // Clamp to avoid overflow
    if (score > MATE_SCORE - 100) score = MATE_SCORE - 100;
    if (score < -MATE_SCORE + 100) score = -MATE_SCORE + 100;

    return score;
}
```

=== Odin Complete Eval

```odin
evaluate :: proc(pos: ^Position) -> i32 {
    phase := calculate_phase(pos);
    score_mg, score_eg: i32;

    // Material + PST
    for sq in 0..<64 {
        piece := pos.board[sq];
        if piece == .EMPTY do continue;
        color := piece_color(piece);
        type  := piece_type(piece);
        rsq   := color == .WHITE ? sq : mirror_square(sq);
        sign  := color == .WHITE ? 1 : -1;
        score_mg += sign * (piece_values[type].mg + pst_mg[type][rsq]);
        score_eg += sign * (piece_values[type].eg + pst_eg[type][rsq]);
    }

    // Pawn structure
    pawn_mg, pawn_eg := evaluate_pawn_structure(pos);
    score_mg += pawn_mg;
    score_eg += pawn_eg;

    // Mobility
    mob_mg, mob_eg := evaluate_mobility(pos);
    score_mg += mob_mg;
    score_eg += mob_eg;

    // King safety (mg only)
    score_mg += evaluate_king_safety(pos);

    // Coordination
    coord_mg, coord_eg := evaluate_coordination(pos);
    score_mg += coord_mg;
    score_eg += coord_eg;

    // Taper
    score := (score_mg * phase + score_eg * (24 - phase)) / 24;

    // Tempo
    score += pos.side == .WHITE ? TEMPO_BONUS : -TEMPO_BONUS;

    return clamp(score, -MATE_SCORE + 100, MATE_SCORE - 100);
}
```

=== Performance Characteristics

A well-optimized classical evaluation function can execute in 200-500 nanoseconds on modern hardware (circa 2026). At 2 million evaluations per second, the evaluation consumes about 10% of search time. The primary cost breakdown:

- Material + PST: ~20 nanoseconds (simple arithmetic, easily vectorized).
- Pawn structure: ~50 nanoseconds (bitboard operations, popcount).
- Mobility: ~200 nanoseconds (magic bitboard lookups for each slider—the dominant cost).
- King safety: ~50 nanoseconds (attack counting, zone evaluation).
- Coordination: ~30 nanoseconds (bitboard tests, file occupancy checks).

This is why mobility is sometimes omitted in the quiescence search: it alone can double evaluation cost while providing a modest ELO gain.

=== Summary

The classical evaluation function combines chess knowledge with efficient computation:

- *Material counting* with tapered values provides the foundation.
- *Piece-square tables* encode positional knowledge about where each piece wants to be, with separate mg and eg tables interpolated by game phase.
- *Pawn structure* evaluates the permanent features of the position: isolated, doubled, backward, and passed pawns, plus pawn shield integrity.
- *Mobility* rewards pieces with many legal moves.
- *King safety* penalizes positions where the king is under attack, using quadratic attack-weight formulas.
- *Coordination bonuses* reward specific piece configurations (bishop pair, rook on open file, knight outpost).
- *Tempo* gives a slight bonus to the side to move.

Together, these components produce evaluations that correlate strongly with game outcomes, enabling the search to distinguish good positions from bad. The next chapter covers advanced evaluation concepts that push this classical framework toward master-level play, and Chapter 13 covers the neural network approach that has largely superseded handcrafted evaluation at the top level.
