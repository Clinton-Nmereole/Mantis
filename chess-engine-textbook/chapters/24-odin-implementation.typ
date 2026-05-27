== Building a Chess Engine in Odin

Odin is a systems programming language designed for clarity, simplicity, and joy of use. It compiles to native code with C-comparable performance, features first-class support for SIMD and SOA data layout, and provides a clean procedural syntax that makes chess engine code exceptionally readable. This chapter builds a complete chess engine in Odin, showcasing the language features that make it a uniquely satisfying choice.

=== Why Odin for Chess Engines?

Odin's key advantages for chess engine development:

1. **Clarity over cleverness**: Odin's design philosophy prioritizes readable, straightforward code. The chess engine's logic is complex enough; the language shouldn't add to the complexity.

2. **First-class SOA/AOS transforms**: Odin's `#soa` directive automatically transforms arrays-of-structs to structs-of-arrays—cache-friendly data layout with zero code changes.

3. **Explicit control flow**: No hidden allocations, no implicit conversions, no operator overloading. Every instruction is visible in the source.

4. **Rich compile-time execution**: `#load` for embedding files, `#config` for conditional compilation, and compile-time procedures for table generation.

5. **Built-in vector types**: SIMD operations are expressed with `#simd` vectors, not compiler intrinsics. The same code works across ISAs.

=== Project Structure

```
odin-chess/
├── main.odin              # Entry point, UCI loop
├── types.odin             # Square, Bitboard, Piece, Color, Move
├── board.odin             # Position, make/unmake, FEN
├── attacks.odin           # Magic bitboard tables, attack generation
├── movegen.odin           # Move generation (all piece types)
├── search.odin            # PVS search, quiescence, iterative deepening
├── evaluate.odin          # Classical evaluation
├── nnue.odin              # NNUE accumulator and inference
├── transposition.odin     # Transposition table
├── moveorder.odin         # Move ordering, killers, history
├── uci.odin               # UCI protocol
├── timeman.odin           # Time management
└── test_perft.odin        # Perft correctness tests
```

=== Core Types

Odin's type system is clean and explicit. Enums with backing types are ideal for chess:

```odin
PieceType :: enum u8 {
    Pawn   = 0,
    Knight = 1,
    Bishop = 2,
    Rook   = 3,
    Queen  = 4,
    King   = 5,
}

Color :: enum u8 {
    White = 0,
    Black = 1,
}

Piece :: enum u8 {
    WhitePawn   = 0,  WhiteKnight = 1, WhiteBishop = 2,
    WhiteRook   = 3,  WhiteQueen  = 4, WhiteKing   = 5,
    BlackPawn   = 8,  BlackKnight = 9, BlackBishop = 10,
    BlackRook   = 11, BlackQueen  = 12, BlackKing   = 13,
    None        = 14,
}

color_of_piece :: proc(p: Piece) -> Color {
    return Color(u8(p) >> 3);
}

piece_type :: proc(p: Piece) -> PieceType {
    return PieceType(u8(p) & 7);
}

make_piece :: proc(c: Color, pt: PieceType) -> Piece {
    return Piece((u8(c) << 3) | u8(pt));
}
```

=== Square and Bitboard Types

```odin
Square :: distinct u8;

SQUARE_A1 :: Square(0);  SQUARE_B1 :: Square(1);  // ... through ...
SQUARE_G8 :: Square(62); SQUARE_H8 :: Square(63);

square_rank :: proc(sq: Square) -> u8 { return u8(sq) >> 3; }
square_file :: proc(sq: Square) -> u8 { return u8(sq) & 7; }
square_from_rf :: proc(rank, file: u8) -> Square { return Square((rank << 3) | file); }

Bitboard :: distinct u64;

bit_set :: proc(bb: ^Bitboard, sq: Square) {
    bb^ |= Bitboard(1 << u64(sq));
}

bit_clear :: proc(bb: ^Bitboard, sq: Square) {
    bb^ &= ~Bitboard(1 << u64(sq));
}

bit_test :: proc(bb: Bitboard, sq: Square) -> bool {
    return (u64(bb) >> u64(sq)) & 1 != 0;
}

bit_pop_lsb :: proc(bb: ^Bitboard) -> (Square, bool) {
    if bb^ == {} do return Square(0), false;
    lsb := Square(bit_scan_forward(u64(bb^)));
    bb^ &= Bitboard(u64(bb^) - 1);
    return lsb, true;
}

bit_count :: proc(bb: Bitboard) -> int {
    return count_ones(u64(bb));
}

bit_scan_forward :: proc(x: u64) -> int {
    if x == 0 do return 64;
    return int(transmute(u32)count_trailing_zeros(x));
}
```

The `distinct` keyword creates types that cannot be implicitly converted to their underlying type. `Square` and `Bitboard` are distinct from `u8` and `u64`—you cannot accidentally pass a hash value to a function expecting a `Bitboard`.

=== Move Representation

```odin
Move :: distinct u16;

MOVE_NULL :: Move(0);

move_from :: proc(m: Move) -> Square {
    return Square(m & 0x3F);
}

move_to :: proc(m: Move) -> Square {
    return Square((m >> 6) & 0x3F);
}

move_flags :: proc(m: Move) -> MoveFlags {
    return MoveFlags((m >> 12) & 0xF);
}

move_make :: proc(from, to: Square, flags: MoveFlags) -> Move {
    return Move(u16(from) | (u16(to) << 6) | (u16(flags) << 12));
}

MoveFlags :: enum u16 {
    Normal       = 0,
    PromotionN   = 1,
    PromotionB   = 2,
    PromotionR   = 3,
    PromotionQ   = 4,
    EnPassant    = 5,
    Castle       = 6,
}
```

=== Move List with SOA Layout

Odin's `#soa` directive is perfect for move lists. A move list is an array of `Move` structs, but `#soa` lays them out as three separate arrays (from, to, flags) for better cache performance:

```odin
MoveEntry :: struct {
    move: Move,
    score: i32,
}

MoveList :: struct {
    entries: [MAX_MOVES]MoveEntry #soa,  // SOA layout for cache efficiency
    count: int,
}

moves_add :: proc(list: ^MoveList, from, to: Square, flags: MoveFlags) {
    list.entries[list.count].move = move_make(from, to, flags);
    list.entries[list.count].score = 0;
    list.count += 1;
}

moves_clear :: proc(list: ^MoveList) {
    list.count = 0;
}

// Iterate in SOA order (three separate arrays at the machine level)
moves_iter :: proc(list: ^MoveList, i: int) -> (Move, i32) {
    return list.entries[i].move, list.entries[i].score;
}
```

The `#soa` directive transforms `[MAX_MOVES]MoveEntry` into three parallel arrays in memory: `moves_from[MAX_MOVES]`, `moves_to[MAX_MOVES]`, `moves_score[MAX_MOVES]`. When the search loop accesses only the move and score (not all fields of a hypothetical larger struct), only those arrays are loaded into cache—doubling effective cache capacity.

=== Position Representation

```odin
Position :: struct {
    // Bitboards
    pieces: [12]Bitboard,        // per piece type and color
    occupancy: [3]Bitboard,      // White, Black, Both
    
    // Board array
    board: [64]Piece,
    
    // King positions
    king_sq: [2]Square,          // White king, Black king
    
    // Game state
    side_to_move: Color,
    castle_rights: u8,           // bit flags for KQkq
    en_passant: Square,          // NO_SQUARE if none
    rule50: u8,
    game_ply: u16,
    
    // Zobrist hash
    hash: u64,
    
    // History stack
    history: [MAX_GAME_PLY]StateInfo,
    history_count: int,
}

StateInfo :: struct {
    hash: u64,
    castle_rights: u8,
    en_passant: Square,
    rule50: u8,
    captured: Piece,
}

piece_on :: proc(pos: ^Position, sq: Square) -> Piece {
    return pos.board[sq];
}

color_occupied :: proc(pos: ^Position, c: Color) -> Bitboard {
    return pos.occupancy[c];
}

all_occupied :: proc(pos: ^Position) -> Bitboard {
    return pos.occupancy[.White] | pos.occupancy[.Black];
}
```

=== Comptime Attack Tables

Odin executes procedures marked `@(init)` at program startup, but for truly zero-cost initialization, compile-time table generation is preferred:

```odin
FILE_A :: Bitboard(0x0101010101010101);
FILE_H :: Bitboard(0x8080808080808080);
FILE_AB :: Bitboard(FILE_A | Bitboard(0x0202020202020202));
FILE_GH :: Bitboard(Bitboard(0x4040404040404040) | FILE_H);

@(rodata)
knight_attacks: [64]Bitboard = {
    // All 64 entries computed manually or via a separate code generator
    // that outputs Odin syntax. In practice, compute these once and paste.
    // (The Odin compiler does not yet have full comptime array generation,
    //  so these are typically precomputed externally.)
    0x0000000000020400,  // a1
    0x0000000000050800,  // b1
    // ... 62 more entries ...
};
```

For engines that want comptime generation, a small Python script or a separate Odin program generates the table as Odin source code:

```python
# generate_attacks.py
for sq in range(64):
    k = 1 << sq
    attacks = ((k << 17) & ~FILE_A) | ((k << 10) & ~FILE_AB) | ...
    print(f"    0x{attacks:016x},  // {square_name(sq)}")
```

=== Move Generation

```odin
generate_moves :: proc(pos: ^Position, moves: ^MoveList) {
    moves_clear(moves);
    
    us := pos.side_to_move;
    them := us == .White ? .Black : .White;
    friendly := pos.occupancy[us];
    enemy := pos.occupancy[them];
    occupied := friendly | enemy;
    empty := ~occupied;
    
    // Pawns
    generate_pawn_moves(pos, us, empty, enemy, moves);
    
    // Knights
    knights := friendly & pos.pieces[make_piece(us, .Knight)];
    for sq, ok := bit_pop_lsb(&knights); ok; sq, ok = bit_pop_lsb(&knights) {
        targets := knight_attacks[sq] & ~friendly;
        for to, ok2 := bit_pop_lsb(&targets); ok2; to, ok2 = bit_pop_lsb(&targets) {
            moves_add(moves, sq, to, .Normal);
        }
    }
    
    // Bishops and queens (diagonal)
    diag_pieces := friendly & (pos.pieces[make_piece(us, .Bishop)] | pos.pieces[make_piece(us, .Queen)]);
    for sq, ok := bit_pop_lsb(&diag_pieces); ok; sq, ok = bit_pop_lsb(&diag_pieces) {
        targets := bishop_attacks(sq, occupied) & ~friendly;
        for to, ok2 := bit_pop_lsb(&targets); ok2; to, ok2 = bit_pop_lsb(&targets) {
            moves_add(moves, sq, to, .Normal);
        }
    }
    
    // Rooks and queens (straight)
    straight_pieces := friendly & (pos.pieces[make_piece(us, .Rook)] | pos.pieces[make_piece(us, .Queen)]);
    for sq, ok := bit_pop_lsb(&straight_pieces); ok; sq, ok = bit_pop_lsb(&straight_pieces) {
        targets := rook_attacks(sq, occupied) & ~friendly;
        for to, ok2 := bit_pop_lsb(&targets); ok2; to, ok2 = bit_pop_lsb(&targets) {
            moves_add(moves, sq, to, .Normal);
        }
    }
    
    // King
    king_sq := pos.king_sq[us];
    targets := king_attacks[king_sq] & ~friendly;
    for to, ok := bit_pop_lsb(&targets); ok; to, ok = bit_pop_lsb(&targets) {
        if !is_square_attacked(pos, to, them) {
            moves_add(moves, king_sq, to, .Normal);
        }
    }
    
    // Castling
    generate_castling(pos, us, occupied, moves);
}
```

=== Make/Unmake Move

Odin's clean procedural style makes the complex make_move logic readable:

```odin
make_move :: proc(pos: ^Position, move: Move) -> bool {
    from := move_from(move);
    to := move_to(move);
    flags := move_flags(move);
    us := pos.side_to_move;
    them := us == .White ? .Black : .White;
    piece := pos.board[from];
    captured := pos.board[to];
    pt := piece_type(piece);
    
    // Save state
    state := StateInfo{
        hash = pos.hash,
        castle_rights = pos.castle_rights,
        en_passant = pos.en_passant,
        rule50 = pos.rule50,
        captured = captured,
    };
    pos.history[pos.history_count] = state;
    pos.history_count += 1;
    
    // Remove from source
    pos.pieces[piece] &^= Bitboard(u64(1) << u64(from));
    pos.occupancy[us] &^= Bitboard(u64(1) << u64(from));
    pos.board[from] = .None;
    
    // Remove captured piece (if any)
    if captured != .None {
        pos.pieces[captured] &^= Bitboard(u64(1) << u64(to));
        pos.occupancy[them] &^= Bitboard(u64(1) << u64(to));
        pos.rule50 = 0;
    }
    
    // Place piece (handle promotions)
    final_piece := piece;
    #partial switch flags {
    case .PromotionN: final_piece = make_piece(us, .Knight);
    case .PromotionB: final_piece = make_piece(us, .Bishop);
    case .PromotionR: final_piece = make_piece(us, .Rook);
    case .PromotionQ: final_piece = make_piece(us, .Queen);
    }
    
    pos.pieces[final_piece] |= Bitboard(u64(1) << u64(to));
    pos.occupancy[us] |= Bitboard(u64(1) << u64(to));
    pos.board[to] = final_piece;
    
    // En passant capture
    if flags == .EnPassant {
        captured_sq := Square(us == .White ? u64(to) - 8 : u64(to) + 8);
        captured_pawn := make_piece(them, .Pawn);
        pos.pieces[captured_pawn] &^= Bitboard(u64(1) << u64(captured_sq));
        pos.occupancy[them] &^= Bitboard(u64(1) << u64(captured_sq));
        pos.board[captured_sq] = .None;
    }
    
    // Castling: move rook
    if flags == .Castle {
        #partial switch to {
        case SQUARE_G1: move_piece_simple(pos, SQUARE_H1, SQUARE_F1);
        case SQUARE_C1: move_piece_simple(pos, SQUARE_A1, SQUARE_D1);
        case SQUARE_G8: move_piece_simple(pos, SQUARE_H8, SQUARE_F8);
        case SQUARE_C8: move_piece_simple(pos, SQUARE_A8, SQUARE_D8);
        }
    }
    
    // Update king position
    if pt == .King {
        pos.king_sq[us] = to;
    }
    
    // Update castling rights, EP, hash, side to move, rule50
    pos.castle_rights &= CASTLE_MASKS[u64(from)] & CASTLE_MASKS[u64(to)];
    pos.en_passant = SQUARE_NONE;
    if pt == .Pawn && abs(i64(to) - i64(from)) == 16 {
        ep_sq := Square(u64(from) + (us == .White ? 8 : -8));
        pos.en_passant = ep_sq;
    }
    pos.side_to_move = them;
    pos.game_ply += 1;
    if pt != .Pawn && captured == .None {
        pos.rule50 += 1;
    } else {
        pos.rule50 = 0;
    }
    pos.hash ^= ZOBRIST_SIDE;
    
    // Check legality
    if is_square_attacked(pos, pos.king_sq[us], them) {
        unmake_move(pos);
        return false;
    }
    
    return true;
}

unmake_move :: proc(pos: ^Position) {
    pos.history_count -= 1;
    state := pos.history[pos.history_count];
    
    // Reverse: restore captured piece, move rook back, etc.
    // ... (inverse of make_move) ...
}
```

=== Search Implementation

Odin's `for` loops with multiple return values from `bit_pop_lsb` are ergonomic:

```odin
pvs :: proc(
    pos: ^Position,
    depth: i32,
    alpha, beta: i32,
    ply: int,
    tt: ^TranspositionTable,
    killers: ^KillerTable,
    history: ^HistoryTable,
) -> i32 {
    // Repetition / fifty-move
    if is_repetition(pos) || pos.rule50 >= 100 {
        return 0;
    }
    
    // Mate distance pruning
    mated_in := -MATE_SCORE + i32(ply);
    alpha = max(alpha, mated_in);
    if alpha >= beta do return alpha;
    
    // TT probe
    tt_entry, tt_hit := tt_probe(tt, pos.hash);
    tt_move := tt_entry.best_move if tt_hit else MOVE_NULL;
    
    if tt_hit && tt_entry.depth >= depth {
        #partial switch tt_entry.flag {
        case .Exact: return tt_entry.score;
        case .Alpha: if tt_entry.score <= alpha do return tt_entry.score;
        case .Beta:  if tt_entry.score >= beta  do return tt_entry.score;
        }
    }
    
    // Quiescence search
    if depth <= 0 {
        return quiesce(pos, alpha, beta, ply, tt);
    }
    
    // Check extension
    if is_in_check(pos) do depth += 1;
    
    // Generate and score moves
    moves: MoveList;
    generate_moves(pos, &moves);
    score_moves(pos, &moves, tt_move, ply, killers, history);
    
    best_score := -MATE_SCORE;
    best_move := MOVE_NULL;
    moves_searched := 0;
    
    for i in 0..<moves.count {
        move, _ := moves_iter(&moves, i);
        if !make_move(pos, move) do continue;
        moves_searched += 1;
        
        // LMR
        reduction: i32 = 0;
        if moves_searched >= 4 && depth >= 3 && !is_capture(pos, move) {
            reduction = 1 + i32(moves_searched / 6);
        }
        
        score: i32;
        if moves_searched == 1 {
            score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history);
        } else {
            score = -pvs(pos, depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, tt, killers, history);
            if score > alpha && reduction > 0 {
                score = -pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1, tt, killers, history);
            }
            if score > alpha && score < beta {
                score = -pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history);
            }
        }
        
        unmake_move(pos);
        
        if score > best_score {
            best_score = score;
            best_move = move;
            if score > alpha do alpha = score;
        }
        if alpha >= beta {
            if !is_capture(pos, move) {
                killer_store(killers, move, ply);
                history_update(history, move, depth, ply);
            }
            break;
        }
    }
    
    if moves_searched == 0 {
        return -MATE_SCORE + i32(ply) if is_in_check(pos) else 0;
    }
    
    // Store in TT
    flag: TTFlag = .Alpha if best_score >= beta 
        else .Alpha if best_move == MOVE_NULL 
        else .Exact;
    tt_store(tt, pos.hash, best_score, depth, best_move, flag, ply);
    
    return best_score;
}
```

=== Iterative Deepening

```odin
iterative_deepening :: proc(pos: ^Position, time_limit: f64) -> Move {
    best_move := MOVE_NULL;
    start_time := time_now();
    
    for depth: i32 = 1; depth <= MAX_DEPTH; depth += 1 {
        score := pvs(pos, depth, -INFINITY, INFINITY, 0, &pos.tt, &pos.killers, &pos.history);
        
        // Check time
        if time_now() - start_time > time_limit {
            break;
        }
        
        // Get best move from TT
        tt_entry, hit := tt_probe(&pos.tt, pos.hash);
        if hit {
            best_move = tt_entry.best_move;
        }
        
        // Output search info
        elapsed := time_now() - start_time;
        uci_info(depth, score, elapsed, nodes_searched);
        
        // Stop if mate found
        if abs(score) > MATE_SCORE - MAX_DEPTH {
            break;
        }
    }
    
    return best_move;
}
```

=== Transposition Table

```odin
TTEntry :: struct {
    hash: u64,
    best_move: Move,
    score: i32,
    depth: i16,
    flag: i8,  // 0=empty, 1=alpha, 2=beta, 3=exact
}

TranspositionTable :: struct {
    entries: []TTEntry,
    mask: u64,
}

tt_init :: proc(tt: ^TranspositionTable, size_mb: int) -> bool {
    entry_count := u64(size_mb) * 1024 * 1024 / size_of(TTEntry);
    // Round down to power of two
    power_of_two: u64 = 1;
    for power_of_two * 2 <= entry_count do power_of_two *= 2;
    
    tt.entries = make([]TTEntry, power_of_two);
    tt.mask = power_of_two - 1;
    return tt.entries != nil;
}

tt_destroy :: proc(tt: ^TranspositionTable) {
    delete(tt.entries);
}

tt_probe :: proc(tt: ^TranspositionTable, hash: u64) -> (TTEntry, bool) {
    idx := hash & tt.mask;
    entry := tt.entries[idx];
    if entry.hash == hash && entry.flag != 0 {
        return entry, true;
    }
    return TTEntry{}, false;
}

tt_store :: proc(tt: ^TranspositionTable, hash: u64, score: i32, depth: i32, best_move: Move, flag: TTFlag, ply: int) {
    idx := hash & tt.mask;
    existing := tt.entries[idx];
    
    // Always replace unless existing is deeper exact entry
    if existing.flag == 3 && existing.depth > depth {
        return;
    }
    
    tt.entries[idx] = TTEntry{
        hash = hash,
        best_move = best_move,
        score = score,
        depth = i16(depth),
        flag = i8(flag),
    };
}
```

=== UCI Interface

```odin
uci_loop :: proc() {
    stdin := os.stream_from_handle(os.stdin);
    buf: [4096]u8;
    
    engine: Engine;
    engine_init(&engine);
    
    for {
        n, err := os.read(stdin, buf[:]);
        if err != nil || n == 0 do break;
        
        line := string(buf[:n]);
        tokens := strings.split(line, " ");
        
        switch tokens[0] {
        case "uci":
            fmt.println("id name OdinChess 1.0");
            fmt.println("id author YourName");
            fmt.println("uciok");
            
        case "isready":
            fmt.println("readyok");
            
        case "position":
            fen, moves := parse_position(tokens[1:]);
            position_from_fen(&engine.pos, fen);
            for move_str in moves {
                m := parse_move(&engine.pos, move_str);
                make_move(&engine.pos, m);
            }
            
        case "go":
            time_limit := parse_go_params(tokens[1:]);
            best_move := engine_search(&engine, time_limit);
            fmt.printfln("bestmove %s", move_to_string(best_move));
            
        case "stop":
            engine_stop(&engine);
            
        case "quit":
            engine_destroy(&engine);
            return;
        }
    }
}
```

=== Building and Testing

```bash
# Build optimized
odin build main.odin -file -o:speed -subsystem:console

# Build with PEXT support
odin build main.odin -file -o:speed -define:HAS_PEXT=true

# Run perft tests
odin test test_perft.odin -file

# Profile
perf record ./odin-chess bench
```

=== Odin-Specific Performance Notes

**SOA data layout**: The `#soa` directive is Odin's unique contribution to chess engine performance. The `MoveList` with `#soa` stores `from`, `to`, `flags`, and `score` in separate arrays. When the search loop iterates over moves, only the score array and move data arrays are accessed—providing better cache utilization than AOS (Array of Structs) where unused fields waste cache space.

```odin
// AOS: 8 bytes per entry, 4 used (50% waste for alignment/padding)
// SOA: 4 separate arrays, only accessed arrays loaded into cache
// Result: ~2x effective cache capacity for move lists
```

**Zero-cost distinct types**: `Square :: distinct u8` and `Bitboard :: distinct u64` compile to the same machine code as their underlying types. The distinction exists only at compile time, preventing bugs with zero runtime cost.

**Manual memory management with clarity**: `make([]TTEntry, count)` is explicit. There's no garbage collector scanning the TT, no reference counting overhead. The engine's memory is precisely what you allocate.

=== Lessons for Odin Engine Developers

1. **Readability is a feature**: The Odin chess engine's code is noticeably more readable than equivalent C or C++. The `for sq, ok := bit_pop_lsb(&bb); ok; sq, ok = bit_pop_lsb(&bb)` loop is verbose but crystal clear about intent.

2. **SOA transforms are a genuine innovation**: Moving from AOS to SOA with a single `#soa` annotation is transformative for cache-sensitive code like move lists and history tables.

3. **Distinct types prevent entire bug classes**: Mixing up squares, bitboards, and hash values is impossible when the type system distinguishes them.

4. **The language stays out of your way**: No borrow checker, no lifetime annotations, no trait bounds. Just straightforward procedural programming with modern conveniences (defer, switch, for-in).

5. **The toolchain is simple**: `odin build` with a few flags. No build system, no package manager, no configuration file unless you want one. This keeps the focus on the engine, not the tooling.
