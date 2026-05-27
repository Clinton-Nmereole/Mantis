== Building a Chess Engine in Rust

Rust is an increasingly popular choice for chess engine development, offering C-level performance with memory safety guarantees that eliminate entire classes of bugs. This chapter walks through building a complete chess engine in Rust, from board representation to UCI interface, with an emphasis on idiomatic Rust patterns and the unique advantages the language provides.

=== Why Rust for Chess Engines?

Rust's key advantages for chess engine development:

1. **Zero-cost abstractions**: Iterators, enums with data (sum types), and generics compile to the same machine code as hand-written C. The `for sq in bitboard` iterator pattern generates identical assembly to a `while (bits)` loop.

2. **Memory safety without garbage collection**: No use-after-free, no double-free, no null pointer dereferences. The borrow checker catches these at compile time. For a chess engine—which allocates very little at runtime anyway—this primarily benefits correctness during development, not runtime performance.

3. **Pattern matching**: Chess is full of discriminated cases (piece types, move types, search node types). Rust's `match` with exhaustive checking ensures you handle every case.

4. **Cargo and crates.io**: The build system and package ecosystem make dependency management trivial. No more Makefile debugging.

5. **Fearless concurrency**: The type system prevents data races at compile time. Lazy SMP parallel search can be implemented with confidence.

=== Project Structure

```
rust-chess/
├── Cargo.toml
├── src/
│   ├── main.rs           # Entry point, UCI loop
│   ├── board.rs          # Position representation, FEN parsing
│   ├── bitboard.rs       # Bitboard utilities, magic/PEXT attacks
│   ├── movegen.rs        # Move generation (all piece types)
│   ├── search.rs         # PVS search, iterative deepening
│   ├── evaluate.rs       # Classical evaluation or NNUE interface
│   ├── nnue.rs           # NNUE accumulator and inference
│   ├── transposition.rs  # Transposition table
│   ├── moveorder.rs      # Move ordering, killers, history
│   ├── uci.rs            # UCI protocol parsing
│   └── timeman.rs        # Time management
├── networks/             # Embedded NNUE network files
└── tests/
    ├── perft.rs          # Perft correctness tests
    └── search.rs         # Search regression tests
```

=== Board Representation

Rust's enums and bitfield-style types are ideal for chess:

```rust
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Piece {
    WhitePawn,   WhiteKnight, WhiteBishop, WhiteRook, WhiteQueen, WhiteKing,
    BlackPawn,   BlackKnight, BlackBishop, BlackRook, BlackQueen, BlackKing,
}

impl Piece {
    pub const COUNT: usize = 12;
    
    pub fn color(self) -> Color {
        match self {
            Piece::WhitePawn | Piece::WhiteKnight | Piece::WhiteBishop
            | Piece::WhiteRook | Piece::WhiteQueen | Piece::WhiteKing => Color::White,
            _ => Color::Black,
        }
    }
    
    pub fn piece_type(self) -> PieceType {
        match self {
            Piece::WhitePawn | Piece::BlackPawn => PieceType::Pawn,
            Piece::WhiteKnight | Piece::BlackKnight => PieceType::Knight,
            // ...
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PieceType { Pawn, Knight, Bishop, Rook, Queen, King }

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Color { White, Black }

impl Color {
    pub fn flip(self) -> Color {
        match self { Color::White => Color::Black, Color::Black => Color::White }
    }
}
```

=== Square and Bitboard Types

Type safety for squares and bitboards prevents mixing them with arbitrary integers:

```rust
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Square(u8);

impl Square {
    pub const fn new(index: u8) -> Self { Square(index) }
    pub const fn from_rank_file(rank: u8, file: u8) -> Self {
        Square(rank * 8 + file)
    }
    pub fn rank(self) -> u8 { self.0 >> 3 }
    pub fn file(self) -> u8 { self.0 & 7 }
    pub fn index(self) -> usize { self.0 as usize }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Bitboard(u64);

impl Bitboard {
    pub const EMPTY: Bitboard = Bitboard(0);
    pub const ALL: Bitboard = Bitboard(!0);
    
    pub fn is_set(self, sq: Square) -> bool {
        (self.0 >> sq.0) & 1 != 0
    }
    
    pub fn set(&mut self, sq: Square) {
        self.0 |= 1u64 << sq.0;
    }
    
    pub fn clear(&mut self, sq: Square) {
        self.0 &= !(1u64 << sq.0);
    }
    
    pub fn pop_lsb(&mut self) -> Option<Square> {
        if self.0 == 0 { return None; }
        let lsb = self.0.trailing_zeros() as u8;
        self.0 &= self.0 - 1;
        Some(Square(lsb))
    }
    
    pub fn count(self) -> u32 { self.0.count_ones() }
}

// Bitboard operators
impl std::ops::BitAnd for Bitboard { /* ... */ }
impl std::ops::BitOr for Bitboard { /* ... */ }
impl std::ops::Not for Bitboard { /* ... */ }
impl std::ops::Shl<u8> for Bitboard { /* ... */ }
impl std::ops::Shr<u8> for Bitboard { /* ... */ }
```

The newtype pattern (`Square(u8)`, `Bitboard(u64)`) prevents accidentally passing a hash value where a bitboard is expected—the compiler catches these errors.

=== Position Representation

```rust
pub struct Position {
    // Bitboards for each piece type (white + black)
    pieces: [Bitboard; 12],     // indexed by Piece enum
    
    // Aggregate bitboards for fast queries
    occupancy: [Bitboard; 3],   // WHITE, BLACK, BOTH (indexed by Color + Both)
    
    // Piece on each square
    board: [Option<Piece>; 64],
    
    // King positions (for fast check detection)
    king_sq: [Square; 2],       // indexed by Color
    
    // Game state
    side_to_move: Color,
    castle_rights: CastleRights,
    en_passant: Option<Square>,
    rule50: u8,
    game_ply: u16,
    
    // Zobrist hash
    hash: u64,
    
    // State stack for unmake_move
    history: Vec<StateHistory>,
}

#[derive(Clone, Copy)]
struct StateHistory {
    hash: u64,
    castle_rights: CastleRights,
    en_passant: Option<Square>,
    rule50: u8,
    captured: Option<Piece>,
}
```

=== Move Representation

```rust
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Move(u16);

impl Move {
    pub const NULL: Move = Move(0);
    
    pub fn new(from: Square, to: Square, flags: MoveFlags) -> Self {
        Move((from.0 as u16) | ((to.0 as u16) << 6) | ((flags.bits() as u16) << 12))
    }
    
    pub fn from(self) -> Square { Square((self.0 & 0x3F) as u8) }
    pub fn to(self) -> Square { Square(((self.0 >> 6) & 0x3F) as u8) }
    pub fn flags(self) -> MoveFlags { MoveFlags::from_bits(((self.0 >> 12) & 0xF) as u8) }
}

bitflags! {
    pub struct MoveFlags: u8 {
        const NORMAL    = 0;
        const PROMOTION = 1;
        const EN_PASSANT= 2;
        const CASTLE    = 3;
        // Promotion pieces encoded separately in the top bits
        const PROMO_N   = 0 << 2;
        const PROMO_B   = 1 << 2;
        const PROMO_R   = 2 << 2;
        const PROMO_Q   = 3 << 2;
    }
}
```

=== Move Generation

Using iterator patterns for clean, fast move generation:

```rust
pub fn generate_moves(pos: &Position, moves: &mut MoveList) {
    let us = pos.side_to_move;
    let them = us.flip();
    let occupied = pos.occupancy_all();
    
    // Pawn moves
    generate_pawn_moves(pos, us, moves);
    
    // Knight moves
    let knights = pos.pieces(Piece::from_color_type(us, PieceType::Knight));
    for from in knights {
        let targets = KNIGHT_ATTACKS[from.index()] & !pos.occupancy(us);
        for to in targets {
            moves.push(Move::new(from, to, MoveFlags::NORMAL));
        }
    }
    
    // Sliding pieces (magic bitboards)
    let bishops_queens = pos.pieces(Piece::from_color_type(us, PieceType::Bishop))
                       | pos.pieces(Piece::from_color_type(us, PieceType::Queen));
    for from in bishops_queens {
        let targets = bishop_attacks(from, occupied) & !pos.occupancy(us);
        for to in targets {
            moves.push(Move::new(from, to, MoveFlags::NORMAL));
        }
    }
    
    // ... similar for rooks/queens and king ...
    
    // Castling
    generate_castling(pos, us, occupied, moves);
}
```

The `for from in bitboard` pattern uses Rust's `Iterator` trait:

```rust
impl Iterator for Bitboard {
    type Item = Square;
    
    fn next(&mut self) -> Option<Square> {
        self.pop_lsb()
    }
}

impl IntoIterator for Bitboard {
    type Item = Square;
    type IntoIter = Bitboard;
    
    fn into_iter(self) -> Bitboard { self }
}
```

This enables the elegant `for from in knights { ... }` syntax while compiling to identical assembly as the manual `while` loop.

=== Search Implementation

Rust's ownership model requires careful design for recursive search. The Position is mutable (make/unmake), so we pass `&mut Position`:

```rust
pub fn pvs(
    pos: &mut Position,
    depth: i32,
    mut alpha: i32,
    beta: i32,
    ply: usize,
    tt: &TranspositionTable,
    killers: &mut KillerTable,
    history: &mut HistoryTable,
    nodes: &mut u64,
) -> i32 {
    // Repetition detection
    if pos.is_repetition() || pos.rule50 >= 100 {
        return 0;
    }

    // Mate distance pruning
    alpha = alpha.max(-MATE_SCORE + ply as i32);
    if alpha >= beta { return alpha; }
    
    // TT probe
    if let Some(entry) = tt.probe(pos.hash) {
        if entry.depth >= depth {
            match entry.flag {
                TTFlag::Exact => return entry.score,
                TTFlag::Alpha if entry.score <= alpha => return entry.score,
                TTFlag::Beta  if entry.score >= beta  => return entry.score,
                _ => {}
            }
        }
    }
    
    // Quiescence search at depth 0
    if depth <= 0 {
        return quiesce(pos, alpha, beta, ply, tt, nodes);
    }
    
    *nodes += 1;
    
    // Generate and order moves
    let mut moves = MoveList::new();
    generate_moves(pos, &mut moves);
    let tt_move = tt.probe(pos.hash).map(|e| e.best_move);
    score_moves(pos, &moves, tt_move, ply, killers, history);
    
    let mut best_score = -MATE_SCORE;
    let mut best_move = Move::NULL;
    let mut moves_searched = 0;
    
    for (i, &mv) in moves.iter().enumerate() {
        if !pos.make_move(mv) { continue; }
        moves_searched += 1;
        
        let score = if moves_searched == 1 {
            -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history, nodes)
        } else {
            // LMR logic
            let reduction = if moves_searched >= 4 && depth >= 3 { 1 + moves_searched / 6 } else { 0 };
            let mut score = -pvs(pos, depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, tt, killers, history, nodes);
            if score > alpha && reduction > 0 {
                // Re-search with full depth
                score = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1, tt, killers, history, nodes);
            }
            if score > alpha && score < beta {
                score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history, nodes);
            }
            score
        };
        
        pos.unmake_move();
        
        if score > best_score {
            best_score = score;
            best_move = mv;
            if score > alpha {
                alpha = score;
            }
        }
        if alpha >= beta {
            if !pos.is_capture(mv) {
                killers.store(mv, ply);
                history.update(mv, depth, ply);
            }
            break;
        }
    }
    
    if moves_searched == 0 {
        return if pos.is_in_check() { -MATE_SCORE + ply as i32 } else { 0 };
    }
    
    // Store in TT
    let flag = if best_score >= beta { TTFlag::Beta }
              else if best_move != Move::NULL { TTFlag::Exact }
              else { TTFlag::Alpha };
    tt.store(pos.hash, best_score, depth, best_move, flag, ply);
    
    best_score
}
```

=== NNUE Integration

Rust's compile-time function evaluation (`const fn`) enables constant-time NNUE accumulator initialization:

```rust
pub struct NnueAccumulator {
    values: [i16; HIDDEN_SIZE],  // 512 elements
}

impl NnueAccumulator {
    /// Full refresh: recompute from scratch (used when position changes significantly)
    pub fn refresh(&mut self, pos: &Position, perspective: Color) {
        // Zero the accumulator
        self.values.fill(0);
        
        // For each active feature, add its weight
        for sq in Square::all() {
            if let Some(piece) = pos.piece_on(sq) {
                let feature_idx = halfkp_index(pos.king_sq(perspective), sq, piece);
                for i in 0..HIDDEN_SIZE {
                    self.values[i] += NNUE_WEIGHTS[feature_idx][i];
                }
            }
        }
    }
    
    /// Incremental update: add/remove features for the moved pieces
    pub fn update(&mut self, pos: &Position, mv: Move, perspective: Color) {
        // Only the from/to squares (and potentially en passant capture) change
        // This is the O(1) "efficiently updatable" property
        let added_features = features_added(pos, mv, perspective);
        let removed_features = features_removed(pos, mv, perspective);
        
        for feat in added_features {
            for i in 0..HIDDEN_SIZE {
                self.values[i] += NNUE_WEIGHTS[feat][i];
            }
        }
        for feat in removed_features {
            for i in 0..HIDDEN_SIZE {
                self.values[i] -= NNUE_WEIGHTS[feat][i];
            }
        }
    }
}

/// Evaluate using the NNUE accumulator
pub fn nnue_evaluate(accumulator: &NnueAccumulator, perspective: Color) -> i32 {
    // Layer 1: ClippedReLU activation
    let mut l1_output = [0i32; 32];
    for o in 0..32 {
        let mut sum: i32 = L1_BIASES[o] as i32;
        for i in 0..HIDDEN_SIZE {
            sum += accumulator.values[i] as i32 * L1_WEIGHTS[i][o] as i32;
        }
        l1_output[o] = sum.clamp(0, QA);  // QA = 255 (quantized activation)
    }
    
    // Layer 2
    let mut l2_output = [0i32; 32];
    for o in 0..32 {
        let mut sum: i32 = L2_BIASES[o] as i32;
        for i in 0..32 {
            sum += l1_output[i] * L2_WEIGHTS[i][o] as i32;
        }
        l2_output[o] = sum.clamp(0, QA);
    }
    
    // Output layer
    let mut output: i32 = OUTPUT_BIAS as i32;
    for i in 0..32 {
        output += l2_output[i] * OUTPUT_WEIGHTS[i] as i32;
    }
    
    // Scale to centipawns
    output * SCALE / (QA * QB)
}
```

=== Performance Optimization in Rust

```rust
// Use repr(align) for cache-line alignment
#[repr(align(64))]
struct ThreadData {
    tt_probes: u64,
    nodes: u64,
    // No padding needed; align(64) ensures each instance gets its own cache line
}

// Use inline(always) for hot-path functions
#[inline(always)]
fn pop_lsb(bb: &mut u64) -> usize {
    let lsb = bb.trailing_zeros() as usize;
    *bb &= *bb - 1;
    lsb
}

// Use target_feature for CPU-specific code
#[cfg(target_feature = "bmi2")]
#[inline]
fn pext_rook_attacks(sq: Square, occupied: Bitboard) -> Bitboard {
    let blockers = occupied & ROOK_MASKS[sq.index()];
    let index = unsafe { core::arch::x86_64::_pext_u64(blockers.0, ROOK_MASKS[sq.index()].0) };
    ROOK_TABLE[sq.index()][index as usize]
}

// Use const for compile-time table generation
const KNIGHT_ATTACKS: [Bitboard; 64] = {
    let mut table = [Bitboard(0); 64];
    let mut sq = 0;
    while sq < 64 {
        let k = 1u64 << sq;
        table[sq] = Bitboard(
            ((k << 17) & !FILE_A) | ((k << 10) & !(FILE_A | FILE_B)) |
            ((k >>  6) & !(FILE_A | FILE_B)) | ((k >> 15) & !FILE_A) |
            ((k << 15) & !FILE_H) | ((k <<  6) & !(FILE_G | FILE_H)) |
            ((k >> 10) & !(FILE_G | FILE_H)) | ((k >> 17) & !FILE_H)
        );
        sq += 1;
    }
    table
};
```

=== UCI Interface

```rust
use std::io::{self, BufRead, Write};

pub fn uci_loop() {
    let mut engine = Engine::new();
    let stdin = io::stdin();
    
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        let tokens: Vec<&str> = line.split_whitespace().collect();
        
        match tokens.first() {
            Some(&"uci") => {
                println!("id name MyEngine 1.0");
                println!("id author YourName");
                println!("uciok");
            }
            Some(&"isready") => {
                println!("readyok");
            }
            Some(&"position") => {
                // Parse "position startpos" or "position fen ..."
                // Apply moves if "moves e2e4 e7e5 ..."
                engine.set_position(&tokens[1..]);
            }
            Some(&"go") => {
                // Parse time controls and search limits
                let best_move = engine.search(/* parameters */);
                println!("bestmove {}", best_move);
            }
            Some(&"stop") => {
                engine.stop_search();
            }
            Some(&"quit") => {
                break;
            }
            _ => {}
        }
        io::stdout().flush().unwrap();
    }
}
```

=== Testing

Rust's test framework makes correctness testing trivially easy:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_perft_initial_position() {
        let pos = Position::from_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1").unwrap();
        assert_eq!(perft(&pos, 1), 20);
        assert_eq!(perft(&pos, 2), 400);
        assert_eq!(perft(&pos, 3), 8902);
        assert_eq!(perft(&pos, 4), 197281);
    }
    
    #[test]
    fn test_perft_kiwipete() {
        let pos = Position::from_fen(
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        ).unwrap();
        assert_eq!(perft(&pos, 1), 48);
        assert_eq!(perft(&pos, 2), 2039);
    }
}

// Run: cargo test
```

=== Building and Optimizing

```toml
# Cargo.toml
[profile.release]
opt-level = 3          # maximum optimization
lto = true             # link-time optimization
codegen-units = 1      # single codegen unit (better optimization)
panic = "abort"        # no panic unwinding (smaller binary, faster)
strip = true           # strip debug symbols

[profile.dev]
opt-level = 1          # faster debug builds
```

Build and test:

```bash
# Debug build (fast compile, slower execution)
cargo build

# Optimized release build
cargo build --release

# Run perft tests
cargo test --release

# Run the engine
cargo run --release

# Benchmark
perf record ./target/release/myengine bench
perf report
```

=== Lessons for Rust Engine Developers

1. **Type safety is your friend**: The `Square` and `Bitboard` newtypes caught multiple bugs during development of this chapter. A `Color` cannot be accidentally used as an array index where a `usize` is expected.

2. **Const evaluation is powerful**: Generating attack tables, piece-square tables, and magic numbers at compile time eliminates startup costs and ensures the data is in read-only memory.

3. **The borrow checker encourages good design**: The need to explicitly manage mutable vs. immutable access forces clean separation of concerns. The Position is mutable during make/unmake; the TT is shared immutably across threads.

4. **Performance parity with C is achievable**: With `#[inline(always)]`, `unsafe` for intrinsics, and careful attention to data layout, Rust engines match C engine NPS within 5-10%.

5. **The ecosystem saves time**: `clap` for command-line parsing, `bitflags` for move flags, `memmap2` for TT allocation—each replaces hours of custom code with a one-line dependency.
