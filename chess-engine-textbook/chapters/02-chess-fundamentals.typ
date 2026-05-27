== Chess Fundamentals for Engine Developers

This chapter is not a chess tutorial for beginners. It is a technical specification of the rules, conventions, and data formats that a chess engine must implement correctly. We approach every topic from the perspective of an engine developer who needs to represent, manipulate, and validate chess positions in code.

=== The Board: Coordinates and Square Encoding

==== Standard Chess Coordinates

The standard chess board is an 8×8 grid. The horizontal rows are called *ranks* and are numbered 1 through 8 from White's perspective (White's pieces start on ranks 1-2, Black's on ranks 7-8). The vertical columns are called *files* and are labeled a through h from White's left to right (White's queenside to kingside).

```text
  a  b  c  d  e  f  g  h
8  ♜ ♞ ♝ ♛ ♚ ♝ ♞ ♜  8  (Black's home rank)
7  ♟ ♟ ♟ ♟ ♟ ♟ ♟ ♟  7
6  · · · · · · · ·  6
5  · · · · · · · ·  5
4  · · · · · · · ·  4
3  · · · · · · · ·  3
2  ♙ ♙ ♙ ♙ ♙ ♙ ♙ ♙  2  (White's home rank)
1  ♖ ♘ ♗ ♕ ♔ ♗ ♘ ♖  1
  a  b  c  d  e  f  g  h
```

Each square has an algebraic name composed of a file letter followed by a rank number: a1 (bottom-left from White's perspective), h8 (top-right), e4 (center), etc.

==== Internal Square Encoding

For internal representation, engines do not use algebraic names. They map each square to an integer index, typically 0-63. The canonical mapping—used by virtually every modern engine including Stockfish, Crafty, and all bitboard-based engines—is the *Little-Endian Rank-File* (LERF) mapping:

```text
a1=0,  b1=1,  c1=2,  d1=3,  e1=4,  f1=5,  g1=6,  h1=7,
a2=8,  b2=9,  c2=10, d2=11, e2=12, f2=13, g2=14, h2=15,
a3=16, b3=17, c3=18, d3=19, e3=20, f3=21, g3=22, h3=23,
a4=24, b4=25, c4=26, d4=27, e4=28, f4=29, g4=30, h4=31,
a5=32, b5=33, c5=34, d5=35, e5=36, f5=37, g5=38, h5=39,
a6=40, b6=41, c6=42, d6=43, e6=44, f6=45, g6=46, h6=47,
a7=48, b7=49, c7=50, d7=51, e7=52, f7=53, g7=54, h7=55,
a8=56, b8=57, c8=58, d8=59, e8=60, f8=61, g8=62, h8=63
```

In this mapping, the square index is computed as rank \* 8 + file, where rank and file are 0-based (rank 0 = rank 1, file 0 = file a). Equivalently, using bitwise operations: `sq = (rank \<\< 3) | file`.

The file and rank can be extracted from a square index:
- file = sq & 7
- rank = sq >> 3

This mapping has several convenient properties for bitboard operations (Chapter 3):
- Shifting left by 1 (`b << 1`) moves one file east
- Shifting right by 1 (`b >> 1`) moves one file west
- Shifting left by 8 (`b << 8`) moves one rank north
- Shifting right by 8 (`b >> 8`) moves one rank south

Alternative mappings exist but are rarely used. The *mailbox* 0x88 representation uses a 16×8 board where the lower nibble of the index is the file and the upper nibble is the rank, allowing off-board detection via `(sq & 0x88) != 0`. We discuss board representations exhaustively in Chapter 3.

=== Pieces: Types, Colors, and Encoding

==== Piece Types

There are six piece types in chess, plus the empty square:

| Type   | Symbol | Typical internal value |
|--------|--------|----------------------|
| Pawn   | P      | 0 or 1               |
| Knight | N      | 1 or 2               |
| Bishop | B      | 2 or 3               |
| Rook   | R      | 3 or 4               |
| Queen  | Q      | 4 or 5               |
| King   | K      | 5 or 6               |
| None   | (empty)| 6 or 0               |

Some engines use 0 for pawns (matching array index conventions), while others use 1 for pawns and reserve 0 for "no piece" or empty. Stockfish uses 0 = NO_PIECE, 1 = PAWN, 2 = KNIGHT, 3 = BISHOP, 4 = ROOK, 5 = QUEEN, 6 = KING. This is consistent with the convention that 0 means "nothing." The specific values are arbitrary as long as they are used consistently; what matters is that each piece type has a unique identifier.

==== Colors

There are two colors: White and Black. Internally, colors are typically encoded as 0 (White) and 1 (Black). This binary encoding is extremely convenient because:

- Flipping a color is just XOR with 1: `black = white xor 1`
- The color bit can be combined with piece type: a 3-bit piece type and a 1-bit color gives a 4-bit "colored piece" identifier
- Bitboard computations often use separate boards per color

Stockfish defines:

```cpp
enum Color { WHITE, BLACK, COLOR_NB = 2 };
```

Where `COLOR_NB` is a convenient sentinel used as an array bound.

==== Piece Values

For evaluation purposes, pieces have approximate values in *centipawns* (hundredths of a pawn):

| Piece  | Value (cp) | Relative to Pawn |
|--------|-----------|------------------|
| Pawn   | 100       | 1.00             |
| Knight | 320-350   | 3.20-3.50        |
| Bishop | 330-360   | 3.30-3.60        |
| Rook   | 500-550   | 5.00-5.50        |
| Queen  | 900-1000  | 9.00-10.00       |
| King   | ∞         | (infinite)       |

These values are approximate and context-dependent. A bishop is typically worth slightly more than a knight (especially a bishop pair), but the difference is small. The exact values used by modern engines are learned through tuning (Chapter 17) and may differ from these traditional estimates.

The king is assigned an arbitrarily large value (typically 10,000-20,000 centipawns) to ensure that losing the king (which never happens in a legal position) scores as catastrophic. In practice, the king's value in evaluation is handled separately through king safety heuristics rather than material counting.

=== Algebraic Notation

Chess engines communicate moves with the outside world using various textual notations. Understanding these notations is essential for implementing UCI (Chapter 16) and for parsing test positions.

==== Long Algebraic Notation (LAN) / UCI Move Format

The UCI protocol uses *long algebraic notation*: a move is specified as the from-square followed by the to-square. Promotions append the promotion piece letter (lowercase):

```text
e2e4   - pawn from e2 to e4
g1f3   - knight from g1 to f3
e7e8q  - pawn from e7 to e8, promoting to queen
e1g1   - white kingside castling (king from e1 to g1)
e8c8   - black queenside castling (king from e8 to c8)
```

This format has the advantage of being unambiguous, easy to parse, and directly usable for move encoding (two 6-bit square indices). UCI move format does not include the piece type, check indicator (+), or capture indicator (x)—these are inferred from the position.

==== Short Algebraic Notation (SAN)

*Standard Algebraic Notation* (SAN) is the human-readable format used in chess literature and PGN files. It omits the from-square when unambiguous:

```text
e4     - pawn to e4 (only pawn can move there)
Nf3    - knight to f3
exd5   - e-pawn captures on d5
O-O    - kingside castling
O-O-O  - queenside castling
e8=Q   - pawn promotion to queen on e8
Rfe1   - rook from f-file to e1 (disambiguation when both rooks can go to e1)
```

SAN is complex to generate because it requires disambiguation logic: the engine must check whether multiple pieces of the same type can reach the to-square and, if so, include sufficient file and/or rank information to uniquely identify the from-square. Engines typically generate SAN only for display purposes in the `info` UCI response and use UCI format internally.

=== FEN Notation: The Position Specification Language

The *Forsyth-Edwards Notation* (FEN), created by David Forsyth and extended by Steven Edwards, is the standard format for representing a complete chess position as a single line of text. Every engine must be able to parse and generate FEN strings. FEN is the input format for the UCI `position fen` command and is used universally for position databases, test suites, and debugging.

A FEN string consists of six space-separated fields:

```text
rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1
|<-- field 1: piece placement -->| 2|  3 | 4 |5|6|
```

==== Field 1: Piece Placement

The board is described rank by rank, from rank 8 (top) to rank 1 (bottom). Within each rank, squares are described from file a (left) to file h (right). Uppercase letters (PNBRQK) represent white pieces; lowercase letters (pnbrqk) represent black pieces. Digits represent consecutive empty squares. Ranks are separated by slashes.

```text
rnbqkbnr = rank 8: black rook, knight, bishop, queen, king, bishop, knight, rook
pppppppp = rank 7: eight black pawns
8        = rank 6: eight empty squares (shorthand for "8 empty")
8        = rank 5: eight empty squares
4P3      = rank 4: 4 empty, white pawn, 3 empty
8        = rank 3: eight empty squares
PPPP1PPP = rank 2: 4 white pawns, 1 empty, 3 white pawns
RNBQKBNR = rank 1: white rook, knight, bishop, queen, king, bishop, knight, rook
```

The numbers in each rank segment must always sum to 8 (the number of files). An engine parsing FEN must verify this invariant.

==== Field 2: Active Color

A single character: `w` if White is to move, `b` if Black is to move. Internally, this is stored as the `side_to_move` field in the position structure.

==== Field 3: Castling Rights

A string of 1-4 characters indicating which castling moves are still legal:
- `K` = White can castle kingside (king hasn't moved, h1 rook hasn't moved)
- `Q` = White can castle queenside (king hasn't moved, a1 rook hasn't moved)
- `k` = Black can castle kingside
- `q` = Black can castle queenside
- `-` = No castling rights remain

Internally, castling rights are typically stored as a 4-bit field:

```text
Bit 0: White kingside  (K)
Bit 1: White queenside (Q)
Bit 2: Black kingside  (k)
Bit 3: Black queenside (q)
```

The constant `0b1111` = 15 represents all castling rights available (starting position). When the king moves, both rights for that color are cleared. When a rook moves from its starting square, the corresponding right is cleared. When a rook is captured on its starting square, the right is also cleared (the rook is no longer there to castle with).

==== Field 4: En Passant Target Square

A square in algebraic notation (e.g., `e3`, `d6`) if an en passant capture is legal, or `-` if none. The en passant target is the square *behind* the pawn that just moved two squares—the square the capturing pawn would move to (not the square the captured pawn occupies).

Example: After 1. e4, Black plays 1... d5. The en passant target is d6 (the square Black's d-pawn passed through). A white pawn on e5 can capture en passant on d6.

The en passant target is stored even if no enemy pawn is actually in position to capture it. The engine must verify during move generation that an en passant capture is actually legal (the capturing pawn exists, the move doesn't leave the king in check).

Internally, the en passant square is typically stored as a square index (0-63) or a sentinel value (e.g., 64 or NO_SQUARE) when no en passant is available. Some engines store only the file (0-7) since the rank is always implied (rank 3 for White, rank 6 for Black).

==== Field 5: Halfmove Clock

An integer representing the number of half-moves (plies) since the last capture or pawn advance. This counter is used to enforce the *fifty-move rule*: if no capture has been made and no pawn has been moved in the last 50 moves (100 plies), either player may claim a draw. Under FIDE rules as of 2014, the draw is automatic after 75 moves (150 plies) with no capture or pawn move.

The halfmove clock starts at 0. After each non-capture, non-pawn-advance move, it increments by 1. After a capture or pawn advance, it resets to 0.

Internally, this is stored as an unsigned integer in the position structure. It is used both for draw detection and for computing the FEN string for output.

==== Field 6: Fullmove Number

An integer representing the number of completed full moves in the game. It starts at 1 and increments after each Black move. In the starting position, this is 1 (no moves completed yet). After 1. e4, FEN would show fullmove number 1 (still White's first move). After 1... e5, the fullmove number becomes 2 (one full move completed).

This field is used when reconstructing PGN output and tracking the game phase. For most engine internals, the fullmove number is less important than the halfmove clock and side to move, but it must be stored and output correctly.

==== FEN Parsing Algorithm

Here is the FEN parsing algorithm in pseudocode. Implementations in all five languages follow.

```text
function parse_fen(fen_string):
    fields = split fen_string by spaces
    assert len(fields) == 6

    // Field 1: piece placement
    rank = 7  // start from rank 8 (0-indexed = 7)
    file = 0
    for each character c in fields[0]:
        if c == '/':
            rank -= 1
            file = 0
        else if c is digit:
            file += int(c)
        else:
            square = rank * 8 + file
            piece = decode_piece(c)  // uppercase=white, lowercase=black
            place_piece(square, piece)
            file += 1

    // Field 2: active color
    side_to_move = (fields[1] == 'w') ? WHITE : BLACK

    // Field 3: castling rights
    castle_rights = 0
    if fields[2] != '-':
        for each character c in fields[2]:
            if c == 'K': castle_rights |= WHITE_OO
            if c == 'Q': castle_rights |= WHITE_OOO
            if c == 'k': castle_rights |= BLACK_OO
            if c == 'q': castle_rights |= BLACK_OOO

    // Field 4: en passant
    if fields[3] == '-':
        ep_square = NO_SQUARE
    else:
        ep_square = algebraic_to_square(fields[3])

    // Field 5: halfmove clock
    halfmove_clock = parse_int(fields[4])

    // Field 6: fullmove number
    fullmove_number = parse_int(fields[5])

    // Compute Zobrist hash
    compute_hash()

    return position
```

=== Move Encoding

Moves need to be stored, sorted, and compared efficiently during search. Most engines encode moves as 16-bit or 32-bit integers, packing all necessary information into bit fields.

==== Typical 16-bit Move Encoding

A common encoding packs the following fields into 16 bits:

```text
Bits 0-5:   From square (6 bits, 0-63)
Bits 6-11:  To square (6 bits, 0-63)
Bits 12-13: Promotion piece (2 bits, 0=knight, 1=bishop, 2=rook, 3=queen)
Bits 14-15: Move type flags (2 bits, 0=normal, 1=promotion, 2=en passant, 3=castling)
```

From this encoding, we can extract:
- Is the move a promotion? `(move >> 14) == 1`
- Which piece is promoted to? `(move >> 12) & 3`
- From/to squares: `(move & 0x3F)` and `((move >> 6) & 0x3F)`

Stockfish uses a 16-bit move format with additional fields for the moving and captured pieces, allowing the move picker to score captures without consulting the position. We cover Stockfish's specific move encoding in the case study (Chapter 25).

==== 32-bit Move Encoding

Some engines use 32-bit moves to include more metadata:

```text
Bits 0-5:   From square
Bits 6-11:  To square
Bits 12-13: Promotion piece
Bits 14-15: Move type
Bits 16-21: Moving piece type
Bits 22-27: Captured piece type
Bits 28-31: Score (for move ordering)
```

The wider format allows storing the moving/captured piece and a move-ordering score directly in the move, which simplifies the move picker. The tradeoff is memory: 32-bit moves take twice the space in move lists.

=== PGN Format

*Portable Game Notation* (PGN) is the standard format for storing chess games as text. While engines don't typically output PGN directly (the GUI handles that), understanding PGN is important for:

- Reading opening books for testing
- Parsing test suites and training data
- Understanding the structure of game databases

A PGN file consists of *tag pairs* (metadata) followed by *movetext* (the moves):

```text
[Event "FIDE World Championship Match"]
[Site "New York, NY USA"]
[Date "1997.05.11"]
[Round "6"]
[White "Kasparov, Garry"]
[Black "Deep Blue"]
[Result "0-1"]

1. e4 c6 2. d4 d5 3. Nc3 dxe4 4. Nxe4 Nd7 5. Ng5 Ngf6 6. Bd3 e6
7. N1f3 h6 8. Nxe6 Qe7 9. O-O fxe6 10. Bg6+ Kd8 {Kasparov resigns} 0-1
```

The "Seven Tag Roster" required for standard PGN export is: Event, Site, Date, Round, White, Black, Result. Moves use SAN format. Comments appear in braces. The result appears both as a tag pair and at the end of the movetext.

=== Special Moves

Four types of moves require special handling in move generation, execution, and validation.

==== Castling

Castling is a king move that also moves a rook. It's the only chess move that involves moving two pieces simultaneously.

**Conditions for castling (all must be satisfied):**
1. Neither the king nor the castling rook has previously moved (tracked via castling rights)
2. The squares between the king and rook are empty (path clearance)
3. The king is not currently in check
4. The king does not pass through check (the square the king crosses must not be attacked)
5. The king does not end up in check (the destination square must not be attacked)
6. The rook's path can pass through an attacked square (this is a common mistake—only the king's path matters)

**Types:**
- *Kingside (O-O, short castling):* White king from e1 to g1, rook from h1 to f1. Black king from e8 to g8, rook from h8 to f8. Path: f1/f8 and g1/g8 must be clear and unattacked (for the king).
- *Queenside (O-O-O, long castling):* White king from e1 to c1, rook from a1 to d1. Black king from e8 to c8, rook from a8 to d8. Path: d1/d8 and c1/c8 must be clear and unattacked (for the king). b1/b8 may be attacked—only the king's path matters.

**Implementation:** When the king moves, clear both castling rights for that color. When a rook moves from its starting square (a1, h1, a8, h8), clear the corresponding castling right. When a rook is captured on its starting square, also clear the right—even though the rook didn't move, it's no longer available for castling.

==== En Passant

En passant ("in passing") is a pawn capture that can only occur immediately after an opponent's pawn moves two squares from its starting rank, landing adjacent to a pawn of the capturing color.

**Conditions:**
1. The opponent's pawn advanced two squares from its starting rank on the immediately preceding move
2. The advanced pawn is on an adjacent file to the capturing pawn
3. The capturing pawn is on its fifth rank (rank 5 for White, rank 4 for Black)
4. The en passant capture must be made on the very next move, or the right is lost

**How it works:** The capturing pawn moves diagonally to the square the opponent's pawn *passed through* (the en passant target square). The opponent's pawn is then removed from its actual square.

Example: White has a pawn on e5. Black plays d7-d5. The black pawn moves from d7 to d5. The en passant target is d6 (the square Black's pawn skipped). White can capture with exd6 (en passant)—the white pawn moves to d6, and the black pawn on d5 is removed.

**Internal implementation:** When a double pawn push is executed, set `ep_square` to the square behind the pawn (rank 3 for White pawn that moved from rank 2, rank 6 for Black pawn that moved from rank 7). During the next move generation, include an en passant capture for any enemy pawn on an adjacent file. After *any* move is made (not just the en passant capture), the en passant target is consumed—set `ep_square = NO_SQUARE`.

**Warning:** En passant can create discovered checks and pinned-piece issues. A classic bug is the position after 1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 b5 5. Bb3 d5 6. exd5 where White might have an en passant target on d6. But if Black then plays d7-d5, there is no en passant on d6 because Black's pawn moved from d7 to d5 (not d6). The en passant target is set by the *last* double pawn push—the previous one (if any) is consumed.

Additionally, en passant capture can be illegal if it leaves the king in check. Consider: White king on e5, White pawn on d5, Black pawn on e7, Black rook on e8. After e7-e5, White has an en passant target on e6. White could capture en passant on e6... but that would remove both the white pawn from d5 AND the black pawn from e5, leaving the white king on e5 attacked by the rook on e8. This capture is therefore illegal. Engines must validate en passant captures for king safety.

==== Pawn Promotion

When a pawn reaches the opponent's back rank (rank 8 for White, rank 1 for Black), it must be promoted to a knight, bishop, rook, or queen. Promotion to a queen is overwhelmingly the most common choice, but under-promotion to a knight can be critical in tactical positions (e.g., to fork king and queen with check).

**Implementation:** In move generation, when a pawn move reaches the promotion rank, generate four separate moves—one for each promotion piece. In UCI format, promote to knight = `e7e8n`, to bishop = `e7e8b`, to rook = `e7e8r`, to queen = `e7e8q`. When executing a promotion move, remove the pawn from the from-square, place the promoted piece on the to-square.

==== Double Pawn Push

On its very first move, a pawn may advance either one square or two squares forward, provided both squares are empty. The double pawn push always results in an en passant target being set for the opponent.

**Implementation:** When generating pawn moves, if the pawn is on its starting rank (rank 2 for White, rank 7 for Black), and both the square one step ahead and the square two steps ahead are empty, generate the double push move. Upon executing the move, set `ep_square` to the square behind the pawn.

=== Game Rules from an Engine Perspective

Engines must implement game rules correctly not just for legal play, but because incorrect rule implementation creates bugs that manifest as illegal moves, incorrect evaluations, and search inconsistencies.

==== Check

A king is *in check* when it is attacked by an enemy piece. Being in check constrains the opponent's legal moves: only moves that resolve the check are legal (king moves, capturing the checking piece, or blocking the check with a piece).

**Detection:** To determine if the side-to-move is in check, test whether any enemy piece attacks the king's square. This is typically done using the `is_square_attacked(square, by_color)` function, which checks for enemy pawn attacks, knight attacks, sliding piece attacks (using magic bitboards or PEXT), and adjacent king attacks.

**In-check constraint on move generation:** When generating moves for a side in check:
1. Check for double check (two enemy pieces attack the king) — only king moves are legal
2. Generate king moves (excluding squares attacked by the enemy)
3. If single check, generate captures of the checking piece
4. If single check and checking piece is a sliding piece, generate moves that block the check (interpose a piece between king and checker)

==== Checkmate

Checkmate occurs when the king is in check and there are no legal moves. The game ends immediately, and the checkmated side loses. In search, a checkmate is scored as the worst possible score for the side that is mated (adjusted for the distance to mate, so that faster mates are preferred).

==== Stalemate

Stalemate occurs when the side to move has no legal moves but is *not* in check. This is a draw. In standard chess (unlike some variants), stalemate is not a win for the stalemating side. Engines must distinguish stalemate from checkmate by checking whether the king is in check when no legal moves exist.

==== Threefold Repetition

A player may claim a draw if the same position occurs three times, with the same player to move and the same castling/en passant rights. This rule prevents infinite loops where both players repeat moves to avoid losing.

**Implementation:** Track the Zobrist hash (a 64-bit position fingerprint, covered in Chapter 10) of each position during the game. When examining a position, count how many times this hash has appeared. If the count reaches 3 (including the current position), the draw can be claimed.

Most engines implement this by maintaining a history of position keys and comparing the current key against the history. Some use a small hash table keyed by Zobrist key with occurrence counts.

**Search implications:** Repetition detection in search is more nuanced. Within the search tree, a position that has appeared earlier in the game history or earlier in the current search line is a draw. However, positions that appear in the search tree but not in the actual game line must be handled carefully: the first occurrence of a position in the search should be scored normally, but a repeated occurrence within the same search line should be scored as a draw. This prevents the search from "repeating" to artificially extend the depth and avoid horizon-effect issues.

==== Fifty-Move Rule

If 50 moves (100 plies) are made without a capture or pawn move, either player may claim a draw. Under FIDE rules (2014), the draw is *automatic* after 75 moves (150 plies) regardless of claims.

**Implementation:** The halfmove clock (FEN field 5) tracks this. When it reaches 100, a draw can be claimed. For the automatic 75-move rule, when the halfmove clock reaches 150, the game is a draw regardless of claims. In search, when the halfmove clock reaches or exceeds 100, the engine should score the position as a draw.

==== Insufficient Material

A draw may be claimed when neither player can possibly checkmate the opponent, regardless of play. The FIDE rules specify the exact combinations:

- King vs. King
- King + Bishop vs. King
- King + Knight vs. King
- King + Bishop vs. King + Bishop (bishops on the same color squares)

Note that King + two Knights vs. King is *not* automatically insufficient—checkmate is possible (though not forceable against a bare king), so engines should not declare this a draw.

**Implementation:** Count material for both sides. If the material combination matches one of the insufficient-material patterns, the position is a forced draw. This is typically checked in the evaluation function rather than as a legal-move constraint.

=== Algebraic Notation Parsing and Generation

Converting between internal square indices and algebraic notation is a common operation.

==== Square to Algebraic

```text
function square_to_algebraic(sq):
    file = 'a' + (sq & 7)
    rank = '1' + (sq >> 3)
    return file + rank
```

==== Algebraic to Square

```text
function algebraic_to_square(alg):
    file = alg[0] - 'a'
    rank = alg[1] - '1'
    return rank * 8 + file
```

