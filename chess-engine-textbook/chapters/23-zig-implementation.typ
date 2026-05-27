== Building a Chess Engine in Zig

Zig is a systems programming language that prioritizes explicitness, no hidden control flow, and seamless C interoperability. For chess engine development, Zig offers unique advantages: compile-time code execution (comptime), explicit memory management, and zero-cost C ABI compatibility. This chapter builds a complete engine in Zig, highlighting the language features that make it a compelling choice.

=== Why Zig for Chess Engines?

Zig's key advantages:

1. **Comptime**: Execute arbitrary code at compile time. Generate attack tables, magic numbers, and piece-square tables as part of the compilation process. No runtime initialization, no separate code generation tool.

2. **No hidden allocations**: Every allocation is explicit (via an `Allocator` parameter). No garbage collector, no implicit heap usage. The engine's memory usage is completely transparent.

3. **C ABI compatibility**: Import C headers directly (`@cInclude`). Use existing C chess libraries without wrappers. The Zig compiler can compile C code natively.

4. **Cross-compilation as a first-class feature**: Build your engine for any target from any host. `zig build -Dtarget=x86_64-windows` produces a Windows binary from Linux with zero configuration.

5. **Predictable performance**: No operator overloading (you always know what `+` or `*` does). No hidden control flow. The generated assembly is as predictable as C.

=== Project Structure

```
zig-chess/
├── build.zig           # Build system
├── src/
│   ├── main.zig        # Entry point, UCI loop
│   ├── types.zig       # Square, Bitboard, Piece, Color, Move types
│   ├── board.zig       # Position, make/unmake, FEN
│   ├── bitboard.zig    # Bitboard utilities, attacks, magic tables
│   ├── movegen.zig     # Move generation
│   ├── search.zig      # PVS search, quiescence
│   ├── evaluate.zig    # Classical evaluation / NNUE
│   ├── nnue.zig        # NNUE accumulator and inference
│   ├── transposition.zig # Transposition table
│   ├── moveorder.zig   # Move ordering, killers, history
│   ├── uci.zig         # UCI protocol
│   └── timeman.zig     # Time management
└── test/
    └── perft.zig       # Perft tests
```

=== Core Types

Zig's type system is straightforward and explicit:

```zig
const std = @import("std");

pub const Color = enum(u1) {
    white = 0,
    black = 1,
    
    pub fn flip(self: Color) Color {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }
};

pub const PieceType = enum(u3) {
    pawn = 0, knight = 1, bishop = 2, rook = 3, queen = 4, king = 5,
};

pub const Piece = enum(u4) {
    white_pawn = 0,   white_knight = 1, white_bishop = 2, white_rook = 3, 
    white_queen = 4,  white_king = 5,
    black_pawn = 8,   black_knight = 9, black_bishop = 10, black_rook = 11,
    black_queen = 12, black_king = 13,
    none = 15,
    
    pub fn color(self: Piece) Color {
        return @enumFromInt(@intFromEnum(self) >> 3);
    }
    
    pub fn pieceType(self: Piece) PieceType {
        return @enumFromInt(@intFromEnum(self) & 7);
    }
};

pub const Square = enum(u6) {
    a1=0, b1=1, c1=2, d1=3, e1=4, f1=5, g1=6, h1=7,
    a2=8, b2=9, c2=10, d2=11, e2=12, f2=13, g2=14, h2=15,
    a3=16, b3=17, c3=18, d3=19, e3=20, f3=21, g3=22, h3=23,
    a4=24, b4=25, c4=26, d4=27, e4=28, f4=29, g4=30, h4=31,
    a5=32, b5=33, c5=34, d5=35, e5=36, f5=37, g5=38, h5=39,
    a6=40, b6=41, c6=42, d6=43, e6=44, f6=45, g6=46, h6=47,
    a7=48, b7=49, c7=50, d7=51, e7=52, f7=53, g7=54, h7=55,
    a8=56, b8=57, c8=58, d8=59, e8=60, f8=61, g8=62, h8=63,
    
    pub fn rank(self: Square) u3 { return @intCast(@intFromEnum(self) >> 3); }
    pub fn file(self: Square) u3 { return @intCast(@intFromEnum(self) & 7); }
    
    pub fn fromRankFile(rank: u3, file: u3) Square {
        return @enumFromInt((@as(u6, rank) << 3) | file);
    }
};

pub const Bitboard = packed struct(u64) {
    bits: u64 = 0,
    
    pub fn set(self: *Bitboard, sq: Square) void {
        self.bits |= @as(u64, 1) << @intFromEnum(sq);
    }
    
    pub fn clear(self: *Bitboard, sq: Square) void {
        self.bits &= ~(@as(u64, 1) << @intFromEnum(sq));
    }
    
    pub fn isSet(self: Bitboard, sq: Square) bool {
        return (self.bits >> @intFromEnum(sq)) & 1 != 0;
    }
    
    pub fn popLsb(self: *Bitboard) ?Square {
        if (self.bits == 0) return null;
        const lsb: u6 = @truncate(@ctz(self.bits));
        self.bits &= self.bits - 1;
        return @enumFromInt(lsb);
    }
    
    pub fn count(self: Bitboard) u32 {
        return @popCount(self.bits);
    }
    
    pub fn iterate(self: *Bitboard) BitboardIterator {
        return .{ .bb = self };
    }
};

pub const BitboardIterator = struct {
    bb: *Bitboard,
    
    pub fn next(self: *BitboardIterator) ?Square {
        return self.bb.popLsb();
    }
};
```

The `packed struct(u64)` ensures `Bitboard` is exactly 64 bits, with no hidden overhead. The enum definitions with explicit backing integers (`u1`, `u3`, `u4`, `u6`) ensure compact storage and explicit bit patterns.

=== Move Representation

```zig
pub const MoveFlags = enum(u4) {
    normal = 0,
    promotion_knight = 1 << 2,
    promotion_bishop = 2 << 2,
    promotion_rook = 3 << 2,
    promotion_queen = 4 << 2,
    en_passant = 5 << 2,
    castle = 6 << 2,
};

pub const Move = packed struct(u16) {
    from: u6,
    to: u6,
    flags: u4,
    
    pub const null = Move{ .from = 0, .to = 0, .flags = @intFromEnum(MoveFlags.normal) };
    
    pub fn init(from: Square, to: Square, flags: MoveFlags) Move {
        return .{
            .from = @intFromEnum(from),
            .to = @intFromEnum(to),
            .flags = @intFromEnum(flags),
        };
    }
    
    pub fn fromSq(self: Move) Square { return @enumFromInt(self.from); }
    pub fn toSq(self: Move) Square { return @enumFromInt(self.to); }
    pub fn moveFlags(self: Move) MoveFlags { return @enumFromInt(self.flags); }
};
```

The `packed struct(u16)` guarantees the move fits in 16 bits with the exact layout we define. No padding, no reordering—the bits are arranged exactly as specified.

=== Position and Make/Unmake

```zig
pub const Position = struct {
    pieces: [12]Bitboard,       // bitboard per piece type+color
    occupancy: [3]Bitboard,     // white, black, both
    board: [64]Piece,           // piece on each square
    king_sq: [2]Square,         // king positions
    
    side_to_move: Color,
    castle_rights: u4,          // KQkq as 4 bits
    en_passant: ?Square,
    rule50: u8,
    game_ply: u16,
    hash: u64,
    
    history: std.ArrayList(StateInfo),
    
    pub fn makeMove(self: *Position, move: Move, allocator: std.mem.Allocator) !bool {
        const from = move.fromSq();
        const to = move.toSq();
        const flags = move.moveFlags();
        const us = self.side_to_move;
        const them = us.flip();
        const piece = self.board[@intFromEnum(from)];
        
        // Save state for unmake
        const state = StateInfo{
            .hash = self.hash,
            .castle_rights = self.castle_rights,
            .en_passant = self.en_passant,
            .rule50 = self.rule50,
            .captured = self.board[@intFromEnum(to)],
        };
        try self.history.append(state);
        
        // Remove piece from source square
        self.pieces[@intFromEnum(piece)].clear(from);
        self.occupancy[@intFromEnum(us)].clear(from);
        self.board[@intFromEnum(from)] = .none;
        
        // Handle capture
        if (self.board[@intFromEnum(to)] != .none) {
            const captured = self.board[@intFromEnum(to)];
            self.pieces[@intFromEnum(captured)].clear(to);
            self.occupancy[@intFromEnum(them)].clear(to);
            self.rule50 = 0;
        }
        
        // Place piece on destination
        var final_piece = piece;
        if (flags == .promotion_queen or flags == .promotion_knight or
            flags == .promotion_bishop or flags == .promotion_rook) {
            const promo_type: PieceType = switch (flags) {
                .promotion_queen => .queen,
                .promotion_knight => .knight,
                .promotion_bishop => .bishop,
                .promotion_rook => .rook,
                else => unreachable,
            };
            final_piece = @enumFromInt((@intFromEnum(us) << 3) | @intFromEnum(promo_type));
        }
        
        self.pieces[@intFromEnum(final_piece)].set(to);
        self.occupancy[@intFromEnum(us)].set(to);
        self.board[@intFromEnum(to)] = final_piece;
        
        // Handle en passant capture
        if (flags == .en_passant) {
            const captured_sq: Square = if (us == .white)
                @enumFromInt(@intFromEnum(to) - 8)
            else
                @enumFromInt(@intFromEnum(to) + 8);
            const captured_pawn = @enumFromInt((@intFromEnum(them) << 3) | @intFromEnum(PieceType.pawn));
            self.pieces[@intFromEnum(captured_pawn)].clear(captured_sq);
            self.occupancy[@intFromEnum(them)].clear(captured_sq);
            self.board[@intFromEnum(captured_sq)] = .none;
        }
        
        // Handle castling (move rook)
        if (flags == .castle) {
            switch (to) {
                .g1 => { self.movePiece(.h1, .f1); },
                .c1 => { self.movePiece(.a1, .d1); },
                .g8 => { self.movePiece(.h8, .f8); },
                .c8 => { self.movePiece(.a8, .d8); },
                else => {},
            }
        }
        
        // Update king position
        if (piece.pieceType() == .king) {
            self.king_sq[@intFromEnum(us)] = to;
        }
        
        // Update castling rights
        self.castle_rights &= CASTLE_MASKS[@intFromEnum(from)] & CASTLE_MASKS[@intFromEnum(to)];
        
        // Update en passant
        self.en_passant = null;
        if (piece.pieceType() == .pawn and @abs(@as(i8, @intCast(@intFromEnum(to))) - @as(i8, @intCast(@intFromEnum(from)))) == 16) {
            self.en_passant = if (us == .white)
                @enumFromInt(@intFromEnum(from) + 8)
            else
                @enumFromInt(@intFromEnum(from) - 8);
        }
        
        // Update side to move, rule50, game ply
        self.side_to_move = them;
        if (piece.pieceType() != .pawn and self.board[@intFromEnum(to)] == .none) {
            self.rule50 += 1;
        }
        self.game_ply += 1;
        
        // Update hash
        self.hash ^= ZOBRIST_SIDE;
        // ... (hash updates for castling rights, EP, moved/captured pieces)
        
        // Check legality
        if (self.isSquareAttacked(self.king_sq[@intFromEnum(us)], them)) {
            self.unmakeMove(allocator);
            return false;
        }
        
        return true;
    }
    
    pub fn unmakeMove(self: *Position, allocator: std.mem.Allocator) void {
        const state = self.history.pop() orelse return;
        // Restore captured piece, move counts, etc.
        // ... (reverse of makeMove)
    }
};
```

=== Comptime Attack Table Generation

This is where Zig truly shines. Generate attack tables at compile time:

```zig
const FILE_A: u64 = 0x0101010101010101;
const FILE_B: u64 = 0x0202020202020202;
const FILE_G: u64 = 0x4040404040404040;
const FILE_H: u64 = 0x8080808080808080;
const FILE_AB: u64 = FILE_A | FILE_B;
const FILE_GH: u64 = FILE_G | FILE_H;

const KNIGHT_ATTACKS: [64]u64 = comptime blk: {
    var table: [64]u64 = undefined;
    for (0..64) |sq| {
        const k: u64 = @as(u64, 1) << @intCast(sq);
        table[sq] = ((k << 17) & ~FILE_A) |
                    ((k << 10) & ~FILE_AB) |
                    ((k >>  6) & ~FILE_AB) |
                    ((k >> 15) & ~FILE_A) |
                    ((k << 15) & ~FILE_H) |
                    ((k <<  6) & ~FILE_GH) |
                    ((k >> 10) & ~FILE_GH) |
                    ((k >> 17) & ~FILE_H);
    }
    break :blk table;
};

const KING_ATTACKS: [64]u64 = comptime blk: {
    var table: [64]u64 = undefined;
    for (0..64) |sq| {
        const k: u64 = @as(u64, 1) << @intCast(sq);
        table[sq] = ((k << 8) | (k >> 8) |
                     ((k << 1) & ~FILE_A) | ((k >> 1) & ~FILE_H) |
                     ((k << 9) & ~FILE_A) | ((k << 7) & ~FILE_H) |
                     ((k >> 7) & ~FILE_A) | ((k >> 9) & ~FILE_H));
    }
    break :blk table;
};

// Magic bitboard tables — all generated at comptime!
const ROOK_MAGICS: [64]u64 = comptime blk: {
    var magics: [64]u64 = undefined;
    var rng = std.rand.DefaultPrng.init(0);
    for (0..64) |sq| {
        magics[sq] = findMagic(sq, false, &rng);
    }
    break :blk magics;
};

fn findMagic(sq: usize, is_bishop: bool, rng: *std.rand.DefaultPrng) u64 {
    const mask = if (is_bishop) bishopMask(sq) else rookMask(sq);
    const bits = @popCount(mask);
    const permutations: usize = @as(usize, 1) << @intCast(bits);
    
    var blockers = [_]u64{0} ** 4096;
    var attacks = [_]u64{0} ** 4096;
    
    // Generate all blocker permutations
    var i: usize = 0;
    var bb: u64 = 0;
    while (true) {
        blockers[i] = bb;
        attacks[i] = if (is_bishop) bishopAttacksSlow(sq, bb) else rookAttacksSlow(sq, bb);
        i += 1;
        if (i >= permutations) break;
        bb = (bb - mask) & mask;  // carry-rippler
    }
    
    // Try random magic numbers
    var attempts: usize = 0;
    while (attempts < 100_000_000) : (attempts += 1) {
        const magic = rng.random().int(u64) & rng.random().int(u64) & rng.random().int(u64);
        if (@popCount((mask *% magic) >> 56) < 6) continue;
        
        var used = [_]usize{0} ** 4096;
        var fail = false;
        for (0..permutations) |j| {
            const index = (blockers[j] *% magic) >> (64 - bits);
            if (used[index] == 0) {
                used[index] = attacks[j];
            } else if (used[index] != attacks[j]) {
                fail = true;
                break;
            }
        }
        if (!fail) return magic;
    }
    @compileError("Failed to find magic number for square " ++ std.fmt.comptimePrint("{}", .{sq}));
}
```

The `comptime` keyword executes this code during compilation. The magic number search—which might take seconds for all 64 squares—happens once at build time. The resulting binary contains only the final tables, with zero runtime initialization cost.

=== Search Implementation

```zig
pub fn pvs(
    pos: *Position,
    depth: i32,
    alpha: i32,
    beta: i32,
    ply: usize,
    tt: *TranspositionTable,
    killers: *KillerTable,
    history: *HistoryTable,
    allocator: std.mem.Allocator,
) !i32 {
    // Repetition detection
    if (pos.isRepetition() or pos.rule50 >= 100) return 0;
    
    // Mate distance pruning
    const mated_in = -MATE_SCORE + @as(i32, @intCast(ply));
    if (mated_in > alpha) alpha = mated_in;
    if (alpha >= beta) return alpha;
    
    // TT probe
    if (tt.probe(pos.hash)) |entry| {
        if (entry.depth >= depth) {
            switch (entry.flag) {
                .exact => return entry.score,
                .alpha => if (entry.score <= alpha) return entry.score,
                .beta  => if (entry.score >= beta) return entry.score,
            }
        }
    }
    
    // Quiescence search
    if (depth <= 0) return try quiesce(pos, alpha, beta, ply, tt, allocator);
    
    // Generate and score moves
    var moves = MoveList{};
    generateMoves(pos, &moves);
    
    const tt_move = if (tt.probe(pos.hash)) |e| e.best_move else Move.null;
    scoreMoves(pos, &moves, tt_move, ply, killers, history);
    
    var best_score: i32 = -MATE_SCORE;
    var best_move = Move.null;
    var moves_searched: usize = 0;
    
    var i: usize = 0;
    while (i < moves.count) : (i += 1) {
        // Pick best remaining move
        const move = pickMove(&moves, i);
        
        if (!try pos.makeMove(move, allocator)) continue;
        moves_searched += 1;
        
        // Late move reductions
        var reduction: i32 = 0;
        if (moves_searched >= 4 and depth >= 3 and !pos.isCapture(move)) {
            reduction = @as(i32, @intCast(1 + moves_searched / 6));
        }
        
        const score = if (moves_searched == 1)
            -try pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history, allocator)
        else blk: {
            var s = -try pvs(pos, depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, tt, killers, history, allocator);
            if (s > alpha and reduction > 0) {
                s = -try pvs(pos, depth - 1, -alpha - 1, -alpha, ply + 1, tt, killers, history, allocator);
            }
            if (s > alpha and s < beta) {
                s = -try pvs(pos, depth - 1, -beta, -alpha, ply + 1, tt, killers, history, allocator);
            }
            break :blk s;
        };
        
        pos.unmakeMove(allocator);
        
        if (score > best_score) {
            best_score = score;
            best_move = move;
            if (score > alpha) alpha = score;
        }
        if (alpha >= beta) {
            if (!pos.isCapture(move)) {
                killers.store(move, ply);
                history.update(move, depth, ply);
            }
            break;
        }
    }
    
    if (moves_searched == 0) {
        return if (pos.isInCheck()) -MATE_SCORE + @as(i32, @intCast(ply)) else 0;
    }
    
    // TT store
    const flag: TTFlag = if (best_score >= beta) .beta
        else if (best_move.from != 0) .exact
        else .alpha;
    tt.store(pos.hash, best_score, depth, best_move, flag, ply);
    
    return best_score;
}
```

=== Transposition Table

Zig's explicit allocation model:

```zig
pub const TTEntry = packed struct {
    hash: u64,
    move_data: u16,    // compressed move
    score: i16,
    depth: i8,
    flag: u8,           // 0=empty, 1=alpha, 2=beta, 3=exact
};

pub const TranspositionTable = struct {
    entries: []TTEntry,
    mask: usize,
    
    pub fn init(allocator: std.mem.Allocator, size_mb: usize) !TranspositionTable {
        const entry_count = (size_mb * 1024 * 1024) / @sizeOf(TTEntry);
        const power_of_two = std.math.pow(usize, 2, std.math.log2(entry_count));
        const entries = try allocator.alloc(TTEntry, power_of_two);
        @memset(entries, TTEntry{ .hash = 0, .move_data = 0, .score = 0, .depth = 0, .flag = 0 });
        return TranspositionTable{
            .entries = entries,
            .mask = power_of_two - 1,
        };
    }
    
    pub fn deinit(self: *TranspositionTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
    
    pub fn probe(self: *const TranspositionTable, hash: u64) ?TTEntry {
        const index = hash & self.mask;
        const entry = self.entries[index];
        if (entry.hash == hash and entry.flag != 0) return entry;
        return null;
    }
    
    pub fn store(self: *TranspositionTable, hash: u64, score: i32, depth: i32, best_move: Move, flag: TTFlag, ply: usize) void {
        const index = hash & self.mask;
        const existing = self.entries[index];
        
        // Replacement strategy: always replace unless existing entry is deeper and exact
        if (existing.flag == 3 and existing.depth >= depth) return;
        
        self.entries[index] = TTEntry{
            .hash = hash,
            .move_data = @bitCast(best_move),
            .score = @truncate(score),
            .depth = @truncate(depth),
            .flag = @intFromEnum(flag),
        };
    }
};
```

=== NNUE Integration

Leveraging comptime for network data:

```zig
const NNUE_NETWORK = @embedFile("networks/nn-epoch200.nnue");

pub const NnueAccumulator = struct {
    values: [HIDDEN_SIZE]i16,
    
    pub fn refresh(self: *NnueAccumulator, pos: *const Position, perspective: Color) void {
        @memset(&self.values, 0);
        
        var sq: usize = 0;
        while (sq < 64) : (sq += 1) {
            const piece = pos.board[sq];
            if (piece == .none) continue;
            
            const feature = halfkpIndex(pos.king_sq[@intFromEnum(perspective)], @enumFromInt(sq), piece);
            const weights = NNUE_WEIGHTS[feature];
            
            var i: usize = 0;
            while (i < HIDDEN_SIZE) : (i += 1) {
                self.values[i] += weights[i];
            }
        }
    }
    
    pub fn evaluate(self: *const NnueAccumulator) i32 {
        // ... same layered computation as C++ version ...
    }
};
```

`@embedFile` bakes the NNUE network file directly into the binary as a compile-time byte array. No file I/O at runtime—the network is part of the executable.

=== Build System

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const exe = b.addExecutable(.{
        .name = "zig-chess",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Enable link-time optimization
    exe.want_lto = true;
    
    // Target-specific CPU features
    exe.root_module.addCMacro("HAS_POPCNT", if (target.result.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.popcnt))) "1" else "0");
    
    b.installArtifact(exe);
    
    // Perft tests
    const perft_tests = b.addTest(.{
        .root_source_file = b.path("test/perft.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const run_perft = b.addRunArtifact(perft_tests);
    const test_step = b.step("test", "Run perft tests");
    test_step.dependOn(&run_perft.step);
}
```

=== Cross-Compilation

```bash
# Build for Linux
zig build -Doptimize=ReleaseFast

# Build for Windows (from Linux!)
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu

# Build for macOS
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos

# Build with PEXT support
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -Dcpu=znver4
```

=== Lessons for Zig Engine Developers

1. **Comptime is the killer feature**: Generating all lookup tables at compile time eliminates entire classes of initialization bugs and improves startup time. The magic number search running at comptime is a perfect example of Zig's philosophy.

2. **Explicit allocators clarify ownership**: The `Allocator` parameter in every allocating function makes it obvious where memory comes from and who is responsible for freeing it. No hidden allocations, no leaks.

3. **Cross-compilation is truly zero-effort**: `zig build -Dtarget=x86_64-windows` is the entire story. No cross-toolchain, no sysroot, no configuration.

4. **Packed structs give precise bit layout**: The `Move` type as `packed struct(u16)` guarantees the exact bit layout you expect, with no padding and no surprises.

5. **C interop enables incremental migration**: An engine originally written in C can be migrated to Zig piece by piece, with both languages coexisting in the same binary through Zig's C compiler.
