== Move Generation: From Position to Possibilities

Move generation is the process of computing all legal moves from a given chess position. It is, along with evaluation, one of the two fundamental operations that a chess engine performs. While evaluation estimates "how good" a position is, move generation enumerates "what we can do" from that position. Together, they form the backbone of search—and move generation, being called at nearly every node of the search tree, must be exceptionally fast.

In a typical engine searching 10 million nodes per second, and generating an average of 35 moves per node, move generation runs 350 million times per second. Every microsecond wasted in move generation costs millions of nodes per second of search throughput. This chapter covers every aspect of move generation: from the simple piece-move patterns to the intricate handling of checks, pins, en passant, and castling, culminating in the `perft` testing framework that verifies correctness.

=== The Move Enumeration Problem: What Must Be Generated

Before writing any code, we must understand exactly *what* constitutes a legal chess move and *how many* possibilities exist from a typical position.

==== What Is a Move?

A chess move consists of:

1. A *from square* (the square the moving piece occupies before the move).
2. A *to square* (the square the moving piece will occupy after the move).
3. Optionally, a *promotion piece* (when a pawn reaches the eighth rank).
4. Optionally, a *special move flag* indicating castling or en passant.

Any complete move representation must encode all of these. We discussed compact move encoding in Chapter 2 (typically 16 bits: 6+6+2+2), but here we focus on *generating* the moves, not encoding them.

==== Legal vs. Pseudo-Legal Moves

A *pseudo-legal* move is one that follows the basic movement pattern of the piece and does not leave the moving side's own king in check. It does *not* account for:

- Whether the king is in check (a move that does not resolve check is illegal).
- Whether the move exposes the king to check (moving a pinned piece is illegal).
- Special rules for castling (cannot castle through or out of check).

A *legal* move is a pseudo-legal move that passes all of these additional checks. Most engines generate pseudo-legal moves first, then filter to legal moves during search (either by testing each move for legality or by generating only legal moves directly). Modern engines tend toward generating legal moves directly because it avoids the work of generating moves that will be rejected.

==== Volume of Moved Generation

How many moves are there? The answer varies dramatically with the position:

- Opening position: 20 moves (16 pawn moves + 4 knight moves).
- Typical middlegame: 30-45 moves.
- Complex tactical position: 50-70 moves (many piece interactions).
- Endgame with queens: can exceed 80 moves (the queen has long range).
- Maximum possible: approximately 218 moves (a theoretically constructed position with nine queens).

The average across all phases is about 35 moves per position. This is the *branching factor* we must handle at each node of the search tree.

=== Move Generation with Bitboards: The Modern Approach

We established in Chapter 3 that bitboards are the dominant representation for high-performance engines. Move generation with bitboards is particularly elegant because we can generate moves for each piece type using precomputed attack tables, then combine them into a complete move list.

==== Pawn Moves

Pawns are the simplest pieces to generate moves for, yet they have the most special cases: single pushes, double pushes, captures (including en passant), and promotions. Let us handle each in turn.

*Single Push*: A pawn can advance one square forward if the destination square is empty. For White pawns, this is one rank north; for Black, one rank south. Using bitboards:

```c
// White pawns: shift north by 8 (one rank)
uint64_t pawn_single_push = (pawns & ~occupied) << 8;
// Black pawns: shift south by 8
uint64_t pawn_single_push_black = (pawns & ~occupied) >> 8;
```

But we must also restrict to squares that are not occupied by *any* piece (friendly or enemy):

```c
uint64_t empty = ~(white_pieces | black_pieces);
uint64_t wpawn_push = (wpawns << 8) & empty;
```

*Double Push*: A pawn on its starting rank (rank 2 for White, rank 7 for Black) can advance two squares if both the first and second squares are empty:

```c
// White double push: starting rank is rank 2 (bitboard rank mask for rank 2 = 0x000000000000FF00)
uint64_t wpawn_double = ((wpawn_push & RANK_3) << 8) & empty;
// The pawn must have been on rank 2, pushed to rank 3 (empty), then to rank 4 (empty)
```

*Captures*: Pawns capture diagonally. A White pawn captures to the northeast and northwest (left and right one file, forward one rank):

```c
uint64_t wpawn_captures = ((wpawns << 7) & ~FILE_A) |  // capture left (northwest)
                          ((wpawns << 9) & ~FILE_H);   // capture right (northeast)
// Only captures into enemy pieces (or en passant target):
wpawn_captures &= black_pieces;
```

The `~FILE_A` and `~FILE_H` masks prevent wraparound: a pawn on the a-file cannot capture left (it would wrap to the h-file), and a pawn on the h-file cannot capture right.

*En Passant*: If the opponent's last move was a double pawn push, and one of our pawns is on the same rank and adjacent file, we can capture the pawn as if it had moved only one square. The en passant target square is the square the opponent's pawn passed through. Our pawn moves to that square, and the opponent's pawn (on the square behind it) is removed.

```c
if (en_passant_square != NO_SQUARE) {
    uint64_t ep_attackers = wpawns & pawn_attacks(black, en_passant_square);
    while (ep_attackers) {
        int from = pop_lsb(&ep_attackers);
        add_move(from, en_passant_square, EN_PASSANT);
    }
}
```

*Promotions*: A pawn reaching the eighth rank (rank 8 for White, rank 1 for Black) must promote to a knight, bishop, rook, or queen. Each promotion generates four separate moves (or fewer if we can prune underpromotions):

```c
uint64_t wpawn_promotions = (wpawns & RANK_7) << 8 & empty;
while (wpawn_promotions) {
    int from = pop_lsb(&wpawn_promotions) - 8;
    add_promotion(from, from + 8, QUEEN);
    add_promotion(from, from + 8, ROOK);
    add_promotion(from, from + 8, BISHOP);
    add_promotion(from, from + 8, KNIGHT);
}
```

Note that underpromotions (to rook, bishop, or knight) are rarely useful, but they are legal and must be generated. Engines often de-prioritize non-queen promotions in move ordering but must generate them for correctness.

==== Knight Moves

Knights move in an L-shape: two squares in one direction and one square perpendicular. There are exactly 8 possible knight moves from any square (fewer from squares near edges). Knight moves are completely independent of blocking pieces—knights jump over any intervening pieces, so no occupancy test is needed.

The standard approach uses a precomputed lookup table `knight_attacks[64]`, where each entry is a bitboard of squares a knight on that square attacks:

```c
const uint64_t knight_attacks[64] = { /* precomputed */ };

// Generate knight moves:
uint64_t knight_moves = knight_attacks[from_square] & ~friendly_pieces;
while (knight_moves) {
    int to = pop_lsb(&knight_moves);
    add_move(from_square, to, 0);
}
```

The only constraint: knights cannot move to squares occupied by friendly pieces. They *can* move to squares occupied by enemy pieces (captures).

*Precomputing Knight Attacks*: For completeness, here is how the `knight_attacks` table is computed:

```c
uint64_t knight_attack_map(int sq) {
    uint64_t k = 1ULL << sq;
    // For each of the 8 knight directions, shift and mask
    return ((k << 17) & ~FILE_A) | ((k << 10) & ~(FILE_A | FILE_B)) |
           ((k >>  6) & ~(FILE_A | FILE_B)) | ((k >> 15) & ~FILE_A) |
           ((k << 15) & ~FILE_H) | ((k <<  6) & ~(FILE_G | FILE_H)) |
           ((k >> 10) & ~(FILE_G | FILE_H)) | ((k >> 17) & ~FILE_H);
}
```

The file masks prevent wraparound: a knight on the a-file shifting left would produce a "move" to the h-file, which is physically impossible on a chessboard. Each shift is masked accordingly.

==== King Moves

Like the knight, the king is a non-sliding piece with exactly 8 possible destinations (the eight adjacent squares). King moves are generated identically to knight moves, using a precomputed `king_attacks[64]` table:

```c
const uint64_t king_attacks[64] = { /* precomputed */ };

uint64_t king_moves = king_attacks[from_square] & ~friendly_pieces;
while (king_moves) {
    int to = pop_lsb(&king_moves);
    // Must also check that the destination is not attacked
    if (!is_square_attacked(to, opponent)) {
        add_move(from_square, to, 0);
    }
}
```

The critical difference from knights: the king cannot move to a square that is attacked by any enemy piece. This requires an attack-detection test for each destination. For efficiency, many engines defer this legality check and instead test legality after making the move—but king moves are one of the most frequent causes of illegal pseudo-legal moves, so testing proactively can be worthwhile.

*Castling*: Castling is the most complex special move. The conditions for castling are:

1. The king and the chosen rook must not have moved previously.
2. The squares between the king and rook must be empty.
3. The king must not be in check.
4. The king must not pass through or land on an attacked square.

With bitboards, these conditions translate directly:

```c
// White kingside castling (e1→g1, h1→f1):
if (castle_rights & WHITE_KINGSIDE) {
    uint64_t path = (1ULL << F1) | (1ULL << G1);  // squares king passes through/lands on
    uint64_t empty_mask = path | (1ULL << F1);      // F1 must also be empty
    if (!(occupied & empty_mask) &&                  // squares empty
        !is_square_attacked(E1, BLACK) &&            // king not in check
        !is_square_attacked(F1, BLACK) &&            // not through check
        !is_square_attacked(G1, BLACK)) {            // not into check
        add_move(E1, G1, CASTLE);
    }
}
```

The castling move itself moves the king two squares toward the rook, and the rook jumps to the square the king passed through. In the internal board representation, this is handled during make_move, not during generation.

==== Sliding Pieces: Rooks, Bishops, and Queens

Sliding pieces (rooks, bishops, queens) are the most computationally expensive to generate moves for, because their range depends on blocking pieces. A rook on an empty board attacks 14 squares; a bishop attacks 7-13 squares (depending on its position); a queen combines both.

The modern approach uses *magic bitboards* (Chapter 3) to compute slider attacks with a single table lookup:

```c
uint64_t rook_attacks(int sq, uint64_t occupancy) {
    uint64_t blockers = occupancy & rook_masks[sq];
    int index = (blockers * rook_magics[sq]) >> rook_shifts[sq];
    return rook_table[sq][index];
}

uint64_t bishop_attacks(int sq, uint64_t occupancy) {
    uint64_t blockers = occupancy & bishop_masks[sq];
    int index = (blockers * bishop_magics[sq]) >> bishop_shifts[sq];
    return bishop_table[sq][index];
}
```

With these functions, generating slider moves is trivial:

```c
// Generate rook moves from a square:
uint64_t rook_moves = rook_attacks(from_square, occupied) & ~friendly_pieces;
while (rook_moves) {
    int to = pop_lsb(&rook_moves);
    add_move(from_square, to, 0);
}

// A queen's attacks are the union of rook and bishop attacks:
uint64_t queen_moves = (rook_attacks(from_sq, occupied) |
                         bishop_attacks(from_sq, occupied)) & ~friendly_pieces;
```

*Rust implementation*:

```rust
fn generate_rook_moves(from: Square, occupied: Bitboard, friendly: Bitboard, moves: &mut MoveList) {
    let attacks = rook_attacks(from, occupied) & !friendly;
    let mut bb = attacks;
    while bb != 0 {
        let to = bb.trailing_zeros() as usize;
        moves.push(Move::new(from, to, MoveType::Normal));
        bb &= bb - 1;  // clear LSB
    }
}
```

*Zig implementation*:

```zig
fn generateRookMoves(from: u6, occupied: u64, friendly: u64, moves: *MoveList) void {
    const attacks = rookAttacks(from, occupied) & ~friendly;
    var bb = attacks;
    while (bb != 0) {
        const to = @ctz(bb);
        moves.add(Move.init(from, @intCast(to), .normal));
        bb &= bb - 1;
    }
}
```

*Odin implementation*:

```odin
generate_rook_moves :: proc(from: Square, occupied: u64, friendly: u64, moves: ^MoveList) {
    attacks := rook_attacks(from, occupied) & ~friendly;
    bb := attacks;
    for bb != 0 {
        to := Square(bit_scan_forward(bb));
        moves_add(moves, Move{from, to, .Normal});
        bb &= bb - 1;
    }
}
```

==== Generating All Pseudo-Legal Moves

Combining all piece types, the complete pseudo-legal move generation function looks like this:

```c
void generate_moves(Position *pos, MoveList *moves) {
    moves->count = 0;
    uint64_t friendly  = pos->side == WHITE ? pos->white_pieces : pos->black_pieces;
    uint64_t enemy     = pos->side == WHITE ? pos->black_pieces : pos->white_pieces;
    uint64_t occupied  = friendly | enemy;
    uint64_t empty     = ~occupied;

    // Pawns (for side to move)
    generate_pawn_moves(pos, friendly, enemy, empty, moves);

    // Knights
    uint64_t knights = friendly & pos->knights;
    while (knights) {
        int from = pop_lsb(&knights);
        uint64_t attacks = knight_attacks[from] & ~friendly;
        while (attacks) add_move(from, pop_lsb(&attacks), 0, moves);
    }

    // Bishops and Queens (diagonal)
    uint64_t bishops = friendly & (pos->bishops | pos->queens);
    while (bishops) {
        int from = pop_lsb(&bishops);
        uint64_t attacks = bishop_attacks(from, occupied) & ~friendly;
        while (attacks) add_move(from, pop_lsb(&attacks), 0, moves);
    }

    // Rooks and Queens (orthogonal)
    uint64_t rooks = friendly & (pos->rooks | pos->queens);
    while (rooks) {
        int from = pop_lsb(&rooks);
        uint64_t attacks = rook_attacks(from, occupied) & ~friendly;
        while (attacks) add_move(from, pop_lsb(&attacks), 0, moves);
    }

    // King
    int king_sq = pos->side == WHITE ? pos->white_king_sq : pos->black_king_sq;
    uint64_t king_moves = king_attacks[king_sq] & ~friendly;
    while (king_moves) add_move(king_sq, pop_lsb(&king_moves), 0, moves);

    // Castling
    generate_castling(pos, occupied, moves);
}
```

Note that each piece type is turned into a sequence of isolated bits using `pop_lsb()`, and each bit position is converted to a square index. This is the standard "bitboard iteration" pattern used throughout all modern engines.

=== Check Detection and Evasion

When the king is in check, the legal moves are severely restricted. Only three types of moves are legal:

1. *King moves* to a square that is not attacked.
2. *Capture the checking piece* (if it is the only checker).
3. *Block the check* by interposing a piece between the king and the checking piece (only possible if the check is from a sliding piece and there is exactly one checker).

This is the foundation of *check evasion*. Most engines generate all moves normally and then test each for legality, but in check, special-casing the generation can be faster because the set of candidate moves is much smaller.

==== Detecting Check

To detect whether a side is in check, we test whether the opponent's attacks include the king square:

```c
bool is_in_check(Position *pos) {
    int king_sq = pos->side == WHITE ? pos->white_king_sq : pos->black_king_sq;
    return is_square_attacked(pos, king_sq, !pos->side);
}
```

The `is_square_attacked` function tests whether any enemy piece attacks the given square:

```c
bool is_square_attacked(Position *pos, int sq, int by_side) {
    uint64_t enemy = by_side == WHITE ? pos->white_pieces : pos->black_pieces;

    // Pawn attacks (pawns attack diagonally)
    uint64_t pawn_attackers = pawn_attacks(by_side ^ 1, sq) & enemy & pos->pawns;
    if (pawn_attackers) return true;

    // Knight attacks
    if (knight_attacks[sq] & enemy & pos->knights) return true;

    // King attacks (for adjacency check)
    if (king_attacks[sq] & enemy & pos->kings) return true;

    // Sliding piece attacks
    uint64_t occupied = pos->white_pieces | pos->black_pieces;
    if (bishop_attacks(sq, occupied) & enemy & (pos->bishops | pos->queens)) return true;
    if (rook_attacks(sq, occupied) & enemy & (pos->rooks | pos->queens)) return true;

    return false;
}
```

The order matters slightly: pawns and knights are the cheapest to test (single table lookup), so checking them first can short-circuit the more expensive slider tests.

==== Identifying Checkers

When the king is in check, we often need to know *which pieces* are giving check. If there are two checkers (a "double check"), the only legal response is to move the king—no capture or block can handle both checkers simultaneously.

```c
int checkers_count(Position *pos, int king_sq, int by_side, uint64_t *checkers) {
    // Similar to is_square_attacked but accumulates all attackers into checkers bitboard
    uint64_t enemy = by_side == WHITE ? pos->white_pieces : pos->black_pieces;
    *checkers = 0;

    // Test each piece type...
    *checkers |= pawn_attacks(!by_side, king_sq) & enemy & pos->pawns;
    *checkers |= knight_attacks[king_sq] & enemy & pos->knights;
    *checkers |= (bishop_attacks(king_sq, occupied) & enemy & (pos->bishops | pos->queens));
    *checkers |= (rook_attacks(king_sq, occupied) & enemy & (pos->rooks | pos->queens));

    return popcount(*checkers);
}
```

==== Generating Legal Moves in Check

With the checkers identified, legal move generation in check becomes:

```c
void generate_evasions(Position *pos, MoveList *moves) {
    int king_sq = king_square(pos);
    uint64_t checkers;
    int n_checkers = find_checkers(pos, &checkers);

    // 1. King moves (always legal candidates in check)
    uint64_t king_moves = king_attacks[king_sq] & ~friendly;
    while (king_moves) {
        int to = pop_lsb(&king_moves);
        if (!is_square_attacked(to, opponent))
            add_move(king_sq, to, 0, moves);
    }

    // 2. If double check, only king moves are legal
    if (n_checkers > 1) return;

    // 3. Single check: capture the checker or block it
    int checker_sq = get_lsb(checkers);
    uint64_t block_squares = 0;

    // If the checker is a slider, compute the squares between king and checker
    if (pos->piece_on[checker_sq] is slider) {
        block_squares = squares_between[king_sq][checker_sq];
    }

    uint64_t targets = checkers | block_squares;  // squares we must move to

    // Generate all non-king moves but filter to only target squares
    generate_captures_and_blocks(pos, targets, moves);
}
```

The `squares_between[64][64]` table is precomputed: for any two squares on the same rank, file, or diagonal, it gives a bitboard of all squares strictly between them. This is invaluable not just for check evasion but also for detecting pinned pieces.

=== Pin Detection

A piece is *pinned* if moving it would expose the king to check from a sliding enemy piece (a rook, bishop, or queen). Pinned pieces can still move, but only along the pin ray (toward or away from the attacker). Moving off the ray is illegal.

*Absolute pin*: The piece is pinned to the king. Moving it off the pin ray exposes the king to check—this is illegal.

*Relative pin*: The piece is pinned to a less valuable piece. Moving it is legal (it's just a move that loses material), but this matters for evaluation, not legality.

To detect absolute pins, we compute the set of squares from which enemy sliding pieces attack the king, treating friendly pieces as "transparent":

```c
uint64_t pinned_pieces(Position *pos, int king_sq) {
    uint64_t pinned = 0;
    uint64_t enemy = opponent_pieces(pos);
    uint64_t friendly = pos->side == WHITE ? pos->white_pieces : pos->black_pieces;
    uint64_t occupied = pos->white_pieces | pos->black_pieces;

    // Potential pinners: enemy rooks/queens on same rank/file, bishops/queens on same diagonal
    uint64_t pinners = (rook_attacks(king_sq, occupied) & enemy & (pos->rooks | pos->queens)) |
                       (bishop_attacks(king_sq, occupied) & enemy & (pos->bishops | pos->queens));

    while (pinners) {
        int pinner = pop_lsb(&pinners);
        uint64_t between = squares_between[king_sq][pinner] & friendly;
        // If exactly one friendly piece is between king and pinner, it is pinned
        if (between && !(between & (between - 1))) {  // exactly one bit set
            pinned |= between;
        }
    }
    return pinned;
}
```

The test `!(between & (between - 1))` is the classic "is power of two" check—it returns true if `between` has exactly one bit set, meaning exactly one friendly piece is between the king and the pinner.

==== Using Pin Information During Move Generation

When we know which pieces are pinned (and in which direction), we can filter moves efficiently:

- A pinned piece may only move along the pin ray (the line connecting the king, the pinned piece, and the pinner). 
- Moving a pinned piece off the pin ray is illegal.
- A pinned piece can capture the pinner (which removes the pin).
- A pinned piece cannot move at all if required to block a check (it must stay on the pin ray, which may not include the check-blocking squares).

This is particularly important for pawn moves: a pinned pawn on the e-file cannot capture to the d-file or f-file if the pin ray runs along the e-file. But it *can* push forward along the e-file. En passant also interacts with pins: a pawn performing en passant may be pinned if the capture exposes the king.

=== En Passant in Depth

En passant is the most misunderstood rule in chess, and it creates subtle bugs in move generation. The key points:

1. En passant is available only immediately after the opponent's double pawn push. It is not available on any subsequent turn. The engine must store the en passant target square in the position state and clear it after the next move.

2. The en passant capture removes the opponent's pawn from its *current* square, not the en passant target square. Our pawn moves to the target square. This requires make_move to handle the removal correctly.

3. En passant interacts with check in a unique way: capturing en passant can *discover* check (our pawn moving off a file that was blocking a slider) or *resolve* check (capturing the checking pawn).

4. The *en passant pin trick*: An en passant capture can be illegal even though the moving pawn is not pinned, if the capture *itself* would expose the king. Consider a position where our king is on e1, our pawn is on e5, and an enemy rook is on e8. The enemy just played d7-d5, and our pawn on e5 could capture en passant on d6. But if we capture, the e-file opens and our king is in check from the rook. This is illegal—and many engines historically mis-handled this case.

The correct implementation:

```c
if (en_passant_square != NO_SQUARE) {
    int ep_sq = en_passant_square;
    uint64_t ep_attackers = pawn_attacks(!side, ep_sq) & friendly_pawns;

    while (ep_attackers) {
        int from = pop_lsb(&ep_attackers);
        // Make temporary move, check legality, then undo
        // OR: test if removing both pawns exposes the king to a slider
        if (is_en_passant_legal(pos, from, ep_sq)) {
            add_move(from, ep_sq, EN_PASSANT, moves);
        }
    }
}
```

Testing legality can be done by temporarily removing both pawns (the capturing pawn and the captured pawn) and checking if the king is attacked. The simpler and more common approach is to generate the move as pseudo-legal and test legality during search.

=== Perft: Verifying Move Generation Correctness

*Perft* (performance test) is the standard technique for verifying move generation correctness. Perft counts, at a given depth, the total number of leaf nodes reachable from the starting position. It does not evaluate or prune—it simply generates all moves at each node and counts leaf nodes.

```c
uint64_t perft(Position *pos, int depth) {
    if (depth == 0) return 1;

    MoveList moves;
    generate_moves(pos, &moves);

    uint64_t nodes = 0;
    for (int i = 0; i < moves.count; i++) {
        if (!make_move(pos, moves.list[i])) continue;  // illegal move
        nodes += perft(pos, depth - 1);
        unmake_move(pos);
    }
    return nodes;
}
```

==== Known Perft Results

The chess community maintains a set of known perft results for the starting position and common test positions. These serve as a "ground truth" for move generation correctness:

```text
Perft(1) = 20
Perft(2) = 400
Perft(3) = 8,902
Perft(4) = 197,281
Perft(5) = 4,865,609
Perft(6) = 119,060,324
Perft(7) = 3,195,901,860
```

If your engine's perft numbers match these exactly (including the breakdown by move at each depth), your move generation is correct. If they don't, you have a bug—and debugging perft mismatches is one of the most valuable skills in chess engine development.

==== Debugging Perft Mismatches

When perft returns a different count than expected, the standard debugging technique is *divide*: perft with a move filter. For each legal move in the position, compute perft(depth-1) for that move alone. Sum the results. Compare against known perft(depth) breakdowns by move.

For example, at the starting position with depth 2:

```text
Move        Perft(1)
a2a3        20
a2a4        20
b2b3        20
b2b4        20
...
```

If your a2a3 gives 19 instead of 20, the issue is specifically in the subtree after a2a3—which narrows the bug search dramatically. Divide perft further (depth 2 perft from the position after a2a3) to isolate the specific move that is mis-handled.

=== Specialized Move Generation: Captures Only and Checks Only

Not all search nodes need full move generation. In quiescence search (Chapter 8), we generate only captures (and sometimes promotions). In some specialized search extensions, we generate only checks. Specializing move generation for these subsets provides significant speedups.

==== Captures-Only Generation

Capture generation is simpler than full move generation because we only need to generate moves that land on enemy-occupied squares (plus en passant). For sliding pieces, this means computing the attacks as usual but masking with `enemy_pieces` instead of `~friendly_pieces`:

```c
void generate_captures(Position *pos, MoveList *moves) {
    // ... similar to generate_moves, but all attack bitboards are masked with enemy pieces
    moves &= enemy_pieces;  // captures only (friendly squares already excluded by piece iteration)
}
```

For pawns, this means only diagonal captures and en passant (not pushes). For knights, bishops, rooks, queens: only attacks into enemy pieces. For the king: only attacks into enemy pieces.

Promotions to queen are captures (the pawn replaces the promoted piece). But promotions to an empty square (pawn push to the 8th rank) are not—though quiescence search typically includes them because they immediately change the material balance.

==== Check Generation

Generating checking moves (moves that put the opponent in check) is more complex because it requires computing, for each candidate move, whether it attacks the opponent's king. This is needed for certain search extensions and for specialized move ordering.

A move gives check if:

1. The moving piece, from its new square, attacks the enemy king directly.
2. The move is a "discovered check"—the moving piece was blocking a friendly sliding piece from attacking the enemy king, and by moving, the slide is revealed.

Discovered checks are particularly powerful because the moving piece can go anywhere (capturing a queen, for example) while simultaneously checking the king. Engines that extend the search on checks (Chapter 6) need to identify discovered checks to avoid missing tactical sequences.

=== Language-Specific Implementation Notes

==== C Implementation

C is the dominant language for high-performance chess engines. The primary considerations:

- Use `uint64_t` for bitboards (guaranteed 64-bit width).
- Use compiler intrinsics for bit scanning: `__builtin_ctzll` (count trailing zeros, GCC/Clang) or `_BitScanForward64` (MSVC). These compile to single CPU instructions (BSF/BSR on x86, CLZ on ARM).
- Use lookup tables generously—memory is cheap, and L1/L2 cache holds most tables.
- Prefer `inline` functions in headers for small, hot-path helpers.

```c
#define pop_lsb(b) \
    ({ int lsb = __builtin_ctzll(b); (b) &= (b) - 1; lsb; })
```

==== C++ Implementation

C++ adds type safety and abstraction without performance overhead (when used correctly):

```cpp
class MoveGenerator {
    const Position& pos;
    MoveList& moves;

public:
    void generate();
    void generate_captures();
    void generate_evasions();

private:
    template<PieceType PT>
    void generate_piece_moves(uint64_t pieces);
};
```

Templates and `constexpr` allow compile-time computation of attack tables, eliminating the need for runtime initialization:

```cpp
consteval std::array<uint64_t, 64> compute_knight_attacks() {
    std::array<uint64_t, 64> table{};
    for (int sq = 0; sq < 64; sq++) {
        uint64_t k = 1ULL << sq;
        table[sq] = ((k << 17) & ~FILE_A) | /* ... */;
    }
    return table;
}
```

==== Rust Implementation

Rust's safety guarantees are a natural fit for chess engines, preventing entire classes of bugs (buffer overflows, use-after-free) that are common in C:

```rust
pub struct MoveGenerator {
    attacks: [Bitboard; 64],  // knight or king attacks
}

impl MoveGenerator {
    pub fn generate(&self, pos: &Position, moves: &mut MoveList) {
        // Bitboard iteration with safe abstractions
        for sq in self.friendly_knights(pos) {
            let targets = self.attacks[sq] & !pos.friendly();
            for to in targets {
                moves.push(Move::new(sq, to, MoveKind::Normal));
            }
        }
    }
}
```

The `for sq in ...` iterator pattern eliminates the manual `while (bits)` loop, making the code more idiomatic while compiling to identical machine code.

==== Zig Implementation

Zig's comptime capabilities are ideal for precomputing attack tables at compile time, and its explicit allocator model gives fine-grained memory control:

```zig
const KnightAttacks = blk: {
    var table: [64]u64 = undefined;
    for (0..64) |sq| {
        const k = @as(u64, 1) << @intCast(sq);
        table[sq] = ((k << 17) & ~FILE_A) | // ...comptime computation...
    }
    break :blk table;
};
```

The entire `KnightAttacks` table is computed at compile time and embedded in the binary as a constant, with zero runtime initialization cost.

==== Odin Implementation

Odin provides a clean procedural syntax with first-class support for bitwise operations and compile-time execution:

```odin
@(rodata)
knight_attacks := [64]u64{
    // computed at compile time
};

generate_moves :: proc(pos: ^Position, moves: ^MoveList) {
    // Odin's `for` over bits:
    for sq in iterate_bits(friendly & pos.knights) {
        targets := knight_attacks[sq] & ~friendly;
        for to in iterate_bits(targets) {
            moves_add(moves, Move{from = sq, to = to, kind = .Normal});
        }
    }
}
```

=== Performance Considerations

Move generation performance is measured in *millions of moves per second* (Mnps). A well-tuned engine on modern hardware (circa 2026) can generate 300-500 million moves per second during perft. Key optimizations:

1. *Cache-friendly data layout*: The `MoveList` should be a stack-allocated array (not heap-allocated), and moves should be stored contiguously. The `Move` struct should be small (ideally 16 bits, but 32 bits is acceptable for alignment).

2. *Avoid branching*: In the hot path, prefer bitwise operations over if-else chains. For example, use `bitboard & -bitboard` to isolate the LSB instead of `if (bitboard)`.

3. *Bulk operations*: When possible, generate moves for all pieces of a type at once using bitboard operations, rather than looping over squares.

4. *Incremental updates*: Some engines maintain incremental attack information that makes move generation faster at the cost of more complex make/unmake. This is an advanced technique beyond the scope of this chapter.

5. *Prefetch*: On platforms with sufficient cache, precompute the most common move-generation patterns and prefetch the relevant cache lines.

=== Summary

Move generation is the first major algorithmic component of a chess engine. The key concepts:

- *Pseudo-legal vs. legal moves*: Most engines generate pseudo-legal moves and test legality during search. For moves in check, specialized evasion generation is more efficient.
- *Bitboard iteration*: For each piece type, compute a bitboard of legal destinations and iterate over set bits to emit moves. This is the standard pattern across all modern engines.
- *Magic bitboards*: Precomputed lookup tables make slider attack generation nearly as fast as knight/king attacks.
- *Pin and check handling*: Pins restrict the moves of pinned pieces to the pin ray. In check, only moves that resolve the check are legal.
- *Special moves*: En passant, castling, and promotions require explicit handling with careful attention to edge cases.
- *Perft*: The universal correctness verification tool. Matching known perft numbers is the gold standard for move generation correctness.

In the next chapter, we will take these generated moves and feed them into a search algorithm—starting with the basics and building up to the sophisticated search techniques that make modern engines so formidable.
