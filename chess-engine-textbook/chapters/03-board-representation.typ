== Board Representation

How you represent the chess board in memory is the single most important architectural decision in your engine. The board representation determines:

1. *The speed of move generation* — how quickly you can compute which squares a piece attacks
2. *The efficiency of position queries* — how quickly you can answer "is square X attacked?" or "what piece is on square Y?"
3. *The memory footprint* — how much memory each position requires
4. *The ease of incremental updates* — how quickly you can make and unmake moves

In this chapter, we examine every board representation used in serious chess engines, from the simplest mailbox to the sophisticated bitboard approach used by Stockfish and all top engines. We explain every concept from first principles, with complete implementations in all five languages.

=== The Mailbox (Array) Representation

The simplest possible representation: a flat array of 64 entries, where each entry stores the piece on that square (or a sentinel value for empty).

==== Basic Mailbox

```c
// C: basic mailbox
enum { EMPTY, W_PAWN, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
            B_PAWN, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING };

int board[64];

// Initialize starting position
void init_board(int board[64]) {
    int starting[64] = {
        W_ROOK, W_KNIGHT, W_BISHOP, W_QUEEN, W_KING, W_BISHOP, W_KNIGHT, W_ROOK,
        W_PAWN, W_PAWN,   W_PAWN,   W_PAWN,  W_PAWN, W_PAWN,   W_PAWN,   W_PAWN,
        EMPTY,  EMPTY,    EMPTY,    EMPTY,   EMPTY,  EMPTY,    EMPTY,    EMPTY,
        EMPTY,  EMPTY,    EMPTY,    EMPTY,   EMPTY,  EMPTY,    EMPTY,    EMPTY,
        EMPTY,  EMPTY,    EMPTY,    EMPTY,   EMPTY,  EMPTY,    EMPTY,    EMPTY,
        EMPTY,  EMPTY,    EMPTY,    EMPTY,   EMPTY,  EMPTY,    EMPTY,    EMPTY,
        B_PAWN, B_PAWN,   B_PAWN,   B_PAWN,  B_PAWN, B_PAWN,   B_PAWN,   B_PAWN,
        B_ROOK, B_KNIGHT, B_BISHOP, B_QUEEN, B_KING, B_BISHOP, B_KNIGHT, B_ROOK
    };
    memcpy(board, starting, 64 * sizeof(int));
}
```

```cpp
// C++: mailbox with enum class
enum class Piece : uint8_t {
    EMPTY, W_PAWN, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
           B_PAWN, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING
};

std::array<Piece, 64> board;
```

```rust
// Rust: mailbox with enum
#[derive(Clone, Copy, PartialEq, Eq)]
enum Piece {
    Empty,
    WPawn, WKnight, WBishop, WRook, WQueen, WKing,
    BPawn, BKnight, BBishop, BRook, BQueen, BKing,
}

let mut board: [Piece; 64] = [Piece::Empty; 64];
```

```zig
// Zig: mailbox
const Piece = enum(u4) {
    empty,
    w_pawn, w_knight, w_bishop, w_rook, w_queen, w_king,
    b_pawn, b_knight, b_bishop, b_rook, b_queen, b_king,
};

var board: [64]Piece = [_]Piece{.empty} ** 64;
```

```odin
// Odin: mailbox
Piece :: enum u8 {
    EMPTY,
    W_PAWN, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
    B_PAWN, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING,
}

board: [64]Piece
```

==== Advantages and Disadvantages

**Advantages:**
- Extremely simple to implement and understand
- Direct square lookup in O(1): `piece = board[square]`
- Make/unmake is trivial: swap pieces in the array

**Disadvantages:**
- Move generation requires scanning the board to find pieces of each type
- Sliding piece attacks require ray-casting (iterating squares in each direction until hitting a piece or board edge)
- No efficient way to answer set-based questions ("which squares are attacked by white?")
- Evaluation requires iterating over all 64 squares to count material

For a beginning engine, mailbox is perfectly adequate and produces correct results. However, for a TCEC-level engine, mailbox is far too slow—move generation in particular is an order of magnitude slower than bitboard-based approaches.

==== The 0x88 Representation

The 0x88 representation is a clever variation on the mailbox that simplifies off-board detection and square relationship tests. Instead of an 8×8 board, it uses a 16×8 board (indices 0-127), but only the first 8 files of each rank (indices where `(sq & 0x88) == 0` are valid squares. The name "0x88" comes from the hexadecimal constant used for the test.

In 0x88, the square index is `(rank << 4) | file`, giving a 4-bit file (0-7 valid, 8-15 off-board) and a 4-bit rank (0-7). The off-board test is simply:

```c
if (sq & 0x88) return;  // off the board
```

This single bitwise AND replaces four separate boundary checks (rank < 0, rank > 7, file < 0, file > 7) for any square. The 0x88 representation was popular in the 1980s and 1990s but has been almost entirely superseded by bitboards in modern engines. We mention it here for historical completeness.

=== Bitboards: The Modern Standard

A bitboard is a 64-bit unsigned integer where each bit represents one square of the chess board. If bit $i$ is set (1), the corresponding square contains (or is attacked by) the piece. If it's clear (0), the square is empty (not attacked).

==== Why Bitboards?

Bitboards exploit the fact that modern CPUs process 64-bit integers in a single cycle. By representing the board as a set of 64-bit integers, we can use bitwise operations to perform chess computations in parallel across the entire board:

- *Union* (OR): combine attack sets. White piece attacks = knight_attacks | bishop_attacks | rook_attacks | ...
- *Intersection* (AND): find pieces of a color. White pieces on open files = white_pieces & ~file_occupancy
- *Complement* (NOT): find empty squares. empty = ~(white | black)
- *Shift*: move pieces. White pawns that can advance one square: (white_pawns << 8) & empty
- *Population count* (POPCNT): count pieces. int num_pawns = popcount(white_pawns)
- *Bit scan*: find individual pieces. int square = trailing_zeros(knights); // find first knight

The key insight is that a single bitwise operation replaces a loop over 64 squares. This is the foundation of bitboard-based engines.

==== Bitboard Layout

In the Little-Endian Rank-File mapping (standard for bitboard engines):

```text
Bit 0  = a1,  Bit 1  = b1,  Bit 2  = c1,  Bit 3  = d1
Bit 4  = e1,  Bit 5  = f1,  Bit 6  = g1,  Bit 7  = h1
Bit 8  = a2,  ...  Bit 63 = h8
```

When printed as a hexadecimal number, the board looks like:

```text
0xFFFF00000000FFFF  (starting position: all pieces on ranks 1-2 and 7-8)
```

In binary (MSB = h8, LSB = a1):

```text
11111111 00000000 00000000 00000000 00000000 00000000 11111111 11111111
<-rank8-> <-rank7-> <-rank6-> <-rank5-> <-rank4-> <-rank3-> <-rank2-> <-rank1->
```

==== The Eight-Board Representation (Stockfish Convention)

The most common bitboard layout uses 8 separate 64-bit integers:

- 6 piece-type boards: `pawns`, `knights`, `bishops`, `rooks`, `queens`, `kings`
- 2 color boards: `white`, `black`

From these 8 boards, we can derive anything:
- White pawns = `pawns & white`
- Black knights = `knights & black`
- All white pieces = `white`
- All pieces = `white | black`
- Empty squares = `~(white | black)`
- Piece on a specific square: test if `(bitboard_of_piece_type >> square) & 1`

This representation is compact (8 × 8 = 64 bytes for the bitboards), cache-friendly, and maps directly to the operations needed for move generation and evaluation.

```c
// C: bitboard type and board structure
typedef uint64_t Bitboard;

typedef struct {
    Bitboard pieces[6];   // PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING
    Bitboard colors[2];   // WHITE, BLACK
    int squares[64];      // optional: piece on each square (for fast lookup)
} Position;
```

```cpp
// C++: bitboard with std::array
using Bitboard = uint64_t;

struct Position {
    std::array<Bitboard, 6> pieces{};  // piece-type boards
    std::array<Bitboard, 2> colors{};  // color boards
    std::array<int, 64> board{};       // piece index per square

    Bitboard occupancy(Color c) const { return colors[c]; }
    Bitboard all() const { return colors[WHITE] | colors[BLACK]; }
    Bitboard empty() const { return ~all(); }
};
```

```rust
// Rust: bitboard type
pub type Bitboard = u64;

pub struct Position {
    pub pieces: [Bitboard; 6],
    pub colors: [Bitboard; 2],
    pub board: [usize; 64],
}

impl Position {
    pub fn occupancy(&self, color: usize) -> Bitboard { self.colors[color] }
    pub fn all(&self) -> Bitboard { self.colors[0] | self.colors[1] }
    pub fn empty(&self) -> Bitboard { !self.all() }
}
```

```zig
// Zig: bitboard type
const Bitboard = u64;

const Position = struct {
    pieces: [6]Bitboard,
    colors: [2]Bitboard,
    board: [64]u8,
};
```

```odin
// Odin: bitboard type
Bitboard :: distinct u64

Position :: struct {
    pieces: [6]Bitboard,
    colors: [2]Bitboard,
    board:  [64]u8,
}
```

==== Bitboard Fundamental Operations

Every bitboard engine needs these operations:

```c
// Count bits (population count)
int popcount(Bitboard b) {
    return __builtin_popcountll(b);  // x86 POPCNT instruction
}

// Find index of least significant set bit (bit scan forward)
int lsb(Bitboard b) {
    return __builtin_ctzll(b);  // x86 TZCNT/BSF instruction
}

// Find index of most significant set bit (bit scan reverse)
int msb(Bitboard b) {
    return 63 - __builtin_clzll(b);  // x86 LZCNT/BSR instruction
}

// Pop least significant bit (extract and clear)
int pop_lsb(Bitboard *b) {
    int sq = lsb(*b);
    *b &= *b - 1;  // Brian Kernighan's trick: clears LSB
    return sq;
}
```

The `pop_lsb` pattern is used universally for iterating over set bits:

```c
// Iterate over all white knights
Bitboard knights = pieces[KNIGHT] & colors[WHITE];
while (knights) {
    int sq = pop_lsb(&knights);
    // generate knight moves from sq
}
```

The `*b &= *b - 1` trick works because subtracting 1 from a binary number flips all bits from the LSB (inclusive) to the end. For example: b = 0b101000, b-1 = 0b100111, b & (b-1) = 0b100000. The LSB of b (bit 3) is cleared.

==== Bit Shifts for Move Generation

Directional shifts map to board geometry:

| Direction    | Operation    | Notes                                    |
|-------------|-------------|------------------------------------------|
| North (+rank) | `b << 8`    | Moves all pieces one rank up             |
| South (-rank) | `b >> 8`    | Moves all pieces one rank down           |
| East (+file)  | `b << 1`    | Moves all pieces one file right          |
| West (-file)  | `b >> 1`    | Moves all pieces one file left           |
| Northeast     | `b << 9`    | North + East                             |
| Northwest     | `b << 7`    | North + West                             |
| Southeast     | `b >> 7`    | South + East                             |
| Southwest     | `b >> 9`    | South + West                             |

**Critical: File wrapping.** When shifting east/west, pieces on the a-file (file 0) must not wrap around to the h-file, and vice versa. This requires masking:

```c
const Bitboard NOT_A_FILE = 0xFEFEFEFEFEFEFEFEULL;  // all bits except file A
const Bitboard NOT_H_FILE = 0x7F7F7F7F7F7F7F7FULL;  // all bits except file H
const Bitboard NOT_AB_FILE = 0xFCFCFCFCFCFCFCFCULL;  // all bits except files A,B
const Bitboard NOT_GH_FILE = 0x3F3F3F3F3F3F3F3FULL;  // all bits except files G,H

// Knight attacks (offsets: ±17, ±15, ±10, ±6)
Bitboard knight_attacks(Bitboard knights) {
    Bitboard l1 = (knights >> 1) & NOT_H_FILE;   // prevent a-file wrap
    Bitboard l2 = (knights >> 2) & NOT_GH_FILE;   // prevent g,h-file wrap
    Bitboard r1 = (knights << 1) & NOT_A_FILE;    // prevent h-file wrap
    Bitboard r2 = (knights << 2) & NOT_AB_FILE;   // prevent a,b-file wrap
    Bitboard h1 = l1 | r1;
    Bitboard h2 = l2 | r2;
    return (h1 << 16) | (h1 >> 16) | (h2 << 8) | (h2 >> 8);
}
```

This generates all knight attacks from all knights in parallel. The result is a bitboard where each set bit is a square attacked by at least one knight.

==== Pre-Computed Attack Tables

For pieces with fixed attack patterns (king, knight, pawn), the attack sets are independent of other pieces on the board. These can be pre-computed at startup:

```c
Bitboard knight_attacks_table[64];
Bitboard king_attacks_table[64];
Bitboard pawn_attacks_table[2][64];  // [color][square]

void init_knight_attacks() {
    for (int sq = 0; sq < 64; sq++) {
        Bitboard b = 1ULL << sq;
        Bitboard attacks =
            ((b << 17) & NOT_A_FILE)  |
            ((b << 15) & NOT_H_FILE)  |
            ((b << 10) & NOT_AB_FILE) |
            ((b << 6)  & NOT_AB_FILE) |
            ((b >> 17) & NOT_H_FILE)  |
            ((b >> 15) & NOT_A_FILE)  |
            ((b >> 10) & NOT_GH_FILE) |
            ((b >> 6)  & NOT_GH_FILE);
        knight_attacks_table[sq] = attacks;
    }
}

void init_king_attacks() {
    for (int sq = 0; sq < 64; sq++) {
        Bitboard b = 1ULL << sq;
        Bitboard attacks =
            ((b << 8)            ) |  // north
            ((b >> 8)            ) |  // south
            ((b << 1) & NOT_A_FILE) |  // east
            ((b >> 1) & NOT_H_FILE) |  // west
            ((b << 9) & NOT_A_FILE) |  // northeast
            ((b << 7) & NOT_H_FILE) |  // northwest
            ((b >> 7) & NOT_A_FILE) |  // southeast
            ((b >> 9) & NOT_H_FILE);   // southwest
        king_attacks_table[sq] = attacks;
    }
}

void init_pawn_attacks() {
    for (int sq = 0; sq < 64; sq++) {
        Bitboard b = 1ULL << sq;
        // White pawns attack northeast and northwest
        pawn_attacks_table[WHITE][sq] =
            ((b << 9) & NOT_A_FILE) | ((b << 7) & NOT_H_FILE);
        // Black pawns attack southeast and southwest
        pawn_attacks_table[BLACK][sq] =
            ((b >> 7) & NOT_A_FILE) | ((b >> 9) & NOT_H_FILE);
    }
}
```

These tables consume negligible memory (64 entries × 8 bytes × 4 tables = 2KB) and provide O(1) lookup for non-sliding piece attacks. For move generation, you simply:

```c
Bitboard attacks = knight_attacks_table[from_square];
attacks &= ~own_pieces;  // can't capture own pieces
while (attacks) {
    int to = pop_lsb(&attacks);
    add_move(from, to);
}
```

=== Magic Bitboards for Sliding Pieces

Bishops, rooks, and queens are *sliding pieces*: their attack range extends in a straight line until blocked by another piece. Unlike knights and kings, sliding piece attacks depend on the positions of *other* pieces on the board. This dependency makes sliding piece move generation the most computationally intensive part of a chess engine.

Magic bitboards solve this problem with a perfect hashing technique.

==== The Problem

Consider a rook on e4. Its attack set without blockers would be all squares on rank 4 and file e. But if there's a white pawn on e6, the rook cannot attack e7 or e8 (it's blocked by its own piece). If there's a black pawn on a4, the rook can attack squares up to and including a4 (capture), but not b4 or beyond.

For each of the 64 squares, and for each possible arrangement of blocking pieces on the relevant rays, we need to compute the attack set. There are $2^n$ possible blocker arrangements for $n$ relevant squares. For a rook on e4, there are 10 relevant squares (4 on the rank, 6 on the file), giving $2^10 = 1024$ possible blocker configurations.

Storing all $64 × 1024 × 8 = 524,288$ bytes is manageable, but this is just for rooks on one square. Across all 64 squares, the naive storage would be approximately $64 × (2^14 × 8) = 8$ MB for rooks (some squares have fewer relevant blockers) and similar for bishops—call it 16 MB total. This is workable but inelegant and wastes memory.

==== The Magic Insight

The "magic" in magic bitboards is using a multiplication by a carefully chosen constant to map the sparse set of relevant occupancy bits into a dense, contiguous index range. Specifically:

1. For each square, compute an *occupancy mask*: the set of squares that could block the sliding piece (all squares on the relevant rays except the edge squares—edge squares are always reachable regardless of blockers).

2. For each possible arrangement of blockers within this mask, compute an *attack set*: the squares the piece can actually reach, considering those blockers.

3. Find a *magic number* M such that: `index = (blockers * M) >> shift` maps each distinct blocker arrangement to a unique index in a compact table.

4. Store the attack set in an array at this index: `attack_table[index] = attacks`.

The "magic" is that for every square, there exists some 64-bit number $M$ (the magic number) and shift amount such that the mapping is collision-free and the resulting table is compact (typically 2,048 to 4,096 entries per square for bishops, 1,024 to 4,096 for rooks).

==== Computing the Occupancy Mask

The occupancy mask for a rook on a given square includes all squares the rook could slide to (excluding the edge squares in each direction, because the piece on the edge square would either block or be capturable regardless):

```c
Bitboard rook_occupancy_mask(int sq) {
    Bitboard mask = 0;
    int rank = sq >> 3, file = sq & 7;

    // North (increasing rank, excluding the edge)
    for (int r = rank + 1; r < 7; r++)
        mask |= 1ULL << (r * 8 + file);
    // South (decreasing rank, excluding the edge)
    for (int r = rank - 1; r > 0; r--)
        mask |= 1ULL << (r * 8 + file);
    // East (increasing file, excluding the edge)
    for (int f = file + 1; f < 7; f++)
        mask |= 1ULL << (rank * 8 + f);
    // West (decreasing file, excluding the edge)
    for (int f = file - 1; f > 0; f--)
        mask |= 1ULL << (rank * 8 + f);

    return mask;
}
```

For a bishop, the mask includes all squares on the four diagonals, excluding the edges. For a queen, the mask is the union of rook and bishop masks.

The size of the occupancy mask varies by square:
- Rook on a1: 12 relevant squares ($2^12 = 4096$ configurations)
- Rook on d4: 10 relevant squares ($2^10 = 1024$ configurations)
- Bishop on a1: 6 relevant squares ($2^6 = 64$ configurations)
- Bishop on d4: 9 relevant squares ($2^9 = 512$ configurations)

==== Generating All Blocker Combinations

To generate all possible blocker arrangements for a given mask, we need to enumerate all subsets of the set bits in the mask. The *Carry-Rippler* trick iterates through all subsets:

```c
Bitboard mask = rook_occupancy_mask[sq];
Bitboard blockers = 0;
do {
    // compute attack set for this blocker arrangement
    Bitboard attacks = compute_rook_attacks(sq, blockers);
    // store in table
    blockers = (blockers - mask) & mask;  // carry-rippler
} while (blockers);
```

The carry-rippler works by subtracting the mask from the current blockers and then AND-ing with the mask. This generates all $2^n$ subsets of the n bits in mask in a Gray-code-like order.

==== Computing Attack Sets for Given Blockers

Given a square and a specific blocker arrangement, we compute the attack set by ray-casting in each direction until we hit a blocker or the board edge:

```c
Bitboard compute_rook_attacks(int sq, Bitboard blockers) {
    Bitboard attacks = 0;
    int rank = sq >> 3, file = sq & 7;

    // North
    for (int r = rank + 1; r <= 7; r++) {
        int s = r * 8 + file;
        attacks |= 1ULL << s;
        if (blockers & (1ULL << s)) break;  // blocked
    }
    // South, East, West similarly...
    return attacks;
}
```

This is called for every blocker combination during table initialization. The attack sets are computed once at startup and stored for runtime lookup.

==== Finding Magic Numbers

A magic number M for a given square must satisfy:

`(blockers * M) >> (64 - bits)` maps each blocker arrangement to a unique index in `[0, 2^bits - 1]`

Where `bits` is the number of relevant squares for that square (the popcount of the occupancy mask).

Magic numbers are found by brute-force search using sparse random 64-bit numbers:

```c
uint64_t find_magic(int sq, int is_bishop) {
    Bitboard mask = is_bishop ? bishop_occupancy_mask[sq] : rook_occupancy_mask[sq];
    int bits = popcount(mask);
    int num_configs = 1 << bits;

    // Generate all blocker configurations and their attack sets
    Bitboard blockers[4096], attacks[4096];
    int i = 0;
    Bitboard b = 0;
    do {
        blockers[i] = b;
        attacks[i] = is_bishop ? compute_bishop_attacks(sq, b) : compute_rook_attacks(sq, b);
        i++;
        b = (b - mask) & mask;
    } while (b);

    // Try random magic numbers
    for (int attempt = 0; attempt < 100000000; attempt++) {
        uint64_t magic = random_uint64() & random_uint64() & random_uint64();  // sparse
        uint64_t used[4096] = {0};
        int fail = 0;

        for (int i = 0; i < num_configs; i++) {
            int index = (blockers[i] * magic) >> (64 - bits);
            if (used[index] == 0) {
                used[index] = attacks[i];
            } else if (used[index] != attacks[i]) {
                fail = 1;  // collision
                break;
            }
        }

        if (!fail) return magic;
    }
    return 0;  // fail (shouldn't happen for non-pathological squares)
}
```

For most squares, a magic number suitable for the given shift can be found within a few thousand random attempts. The hardest squares require millions of attempts and are typically pre-computed and hardcoded. The chess programming community has found magic numbers for all 64 squares; these are widely copied between engines.

Stockfish uses two sets of magic numbers—one optimized for rook attacks, one for bishop attacks. These are hardcoded as arrays.

==== Complete Magic Bitboard Lookup at Runtime

With magic numbers and attack tables pre-computed, the runtime lookup is:

```c
// Rook attacks for a given square, given all occupied squares
Bitboard rook_attacks(int sq, Bitboard occupancy) {
    Bitboard blockers = occupancy & rook_occupancy_mask[sq];
    int index = (blockers * rook_magics[sq]) >> rook_shifts[sq];
    return rook_attack_table[sq][index];
}

// Bishop attacks
Bitboard bishop_attacks(int sq, Bitboard occupancy) {
    Bitboard blockers = occupancy & bishop_occupancy_mask[sq];
    int index = (blockers * bishop_magics[sq]) >> bishop_shifts[sq];
    return bishop_attack_table[sq][index];
}

// Queen attacks = rook | bishop
Bitboard queen_attacks(int sq, Bitboard occupancy) {
    return rook_attacks(sq, occupancy) | bishop_attacks(sq, occupancy);
}
```

The entire sliding piece attack computation reduces to: one AND, one multiply, one shift, one array lookup. This is the fastest known method for sliding piece attack generation on CPUs without the BMI2 instruction set.

=== PEXT Bitboards (BMI2 Hardware Acceleration)

Intel's Haswell microarchitecture (2013) introduced the BMI2 (Bit Manipulation Instruction Set 2) extension, which includes the PEXT (Parallel Bits Extract) instruction. PEXT extracts bits from a source according to a mask and packs them into the low-order bits of the destination. This is precisely the operation needed for magic bitboard indexing.

```c
// PEXT-based rook attacks (requires BMI2 support)
#include <immintrin.h>

Bitboard rook_attacks_pext(int sq, Bitboard occupancy) {
    Bitboard blockers = occupancy & rook_occupancy_mask[sq];
    int index = _pext_u64(blockers, rook_occupancy_mask[sq]);
    return rook_attack_table[sq][index];
}
```

This is even simpler than magic: no magic numbers, no multiplication, just PEXT the occupancy bits using the mask as the bit selection pattern. The resulting index is always exactly popcount(mask) bits wide, eliminating the shift calculation.

The attack tables are the same ones used for magic bitboards—only the indexing mechanism changes. For engines that support both, the initialization can build one set of attack tables and use either magic or PEXT for lookup, selected at runtime based on CPU feature detection.

```c
// Runtime detection
bool has_bmi2 = __builtin_cpu_supports("bmi2");

Bitboard (*get_rook_attacks)(int, Bitboard);
Bitboard (*get_bishop_attacks)(int, Bitboard);

if (has_bmi2) {
    get_rook_attacks = rook_attacks_pext;
    get_bishop_attacks = bishop_attacks_pext;
} else {
    get_rook_attacks = rook_attacks_magic;
    get_bishop_attacks = bishop_attacks_magic;
}
```

On CPUs with BMI2, PEXT is slightly faster than magic multiplication (the PEXT instruction has 3-cycle latency vs. 3-4 cycles for the multiply-shift sequence in magic). On CPUs without BMI2 (including all AMD processors before Zen 3 due to microcode PEXT being extremely slow), the magic method is used.

=== Complete Board State

Beyond the bitboards, a chess engine must store additional position state:

```c
typedef struct {
    // Bitboards
    Bitboard pieces[6];   // piece-type boards (PAWN..KING)
    Bitboard colors[2];   // color boards (WHITE, BLACK)

    // Square-to-piece mapping (for fast piece-type lookup)
    int board[64];        // piece index (PAWN..KING) or NO_PIECE

    // Game state
    int side_to_move;     // WHITE or BLACK
    int castling_rights;  // 4-bit mask (KQkq)
    int ep_square;        // en passant target square or NO_SQUARE
    int halfmove_clock;   // for 50-move rule
    int fullmove_number;  // move count

    // History for unmake
    uint64_t position_key; // Zobrist hash (Chapter 10)
    int game_ply;          // current ply in the game
    int captured_piece;    // piece captured on last move (for unmake)

    // Repetition tracking
    uint64_t position_history[512];  // keys of previous positions
    int history_count;
} Position;
```

The `board[64]` array is technically redundant with the bitboards (you can find the piece on a square by testing each bitboard), but it provides O(1) lookup for piece-type queries, which is important for make/unmake. The tradeoff is 64 bytes of memory for a significant speed improvement in common operations.

