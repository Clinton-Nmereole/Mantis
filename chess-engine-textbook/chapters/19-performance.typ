== Performance Optimization: Making Every Cycle Count

A chess engine's Elo strength depends on two factors: how *accurately* it evaluates positions, and how *many* positions it can evaluate per second. The latter—raw search throughput measured in nodes per second (NPS)—is a function of performance optimization. A 10% faster engine searches 10% more nodes in the same time, which translates directly to greater search depth and, consequently, higher playing strength.

This chapter covers every dimension of chess engine performance optimization: from CPU microarchitecture and memory hierarchy to compiler optimization flags, profiling tools, and data-oriented design. We will examine real performance numbers and provide concrete code transformations that demonstrably improve NPS.

=== Profiling: Finding Where Cycles Are Spent

Before optimizing, measure. Guesswork optimization—"this looks slow"—is worse than useless because it often optimizes code that accounts for 1% of runtime while ignoring the 40% hot spot. Profiling answers the fundamental question: *where is the engine spending its time?*

==== Sampling Profilers (perf, VTune, Instruments)

A sampling profiler interrupts the CPU at regular intervals (e.g., 1,000 times per second) and records the instruction pointer. Over time, this builds a statistical picture of execution time:

```bash
# Linux perf
perf record ./engine bench  # collect samples
perf report                 # interactive flame graph

# VTune (Intel)
vtune -collect hotspots ./engine bench
vtune -report hotspots

# Instruments (macOS)
instruments -t "Time Profiler" ./engine bench
```

For a chess engine, the typical hot spots (percentages from a well-tuned Stockfish-class engine at depth 15 from the starting position, single-threaded):

```text
Function                    % of CPU
─────────────────────────── ────────
Evaluate (NNUE inference)   25-35%
Move Generation             15-20%
TT Probe/Store              10-15%
Make/Unmake Move             8-12%
Search (recursive overhead)  8-10%
Move Ordering/Scoring        5-8%
Check Detection              3-5%
Other                        5-15%
```

These proportions shift with depth and position type: shallow searches spend more time in move generation and evaluation; deep searches spend more time in TT operations and the recursive search overhead.

==== Instrumented Profiling (for Detailed Per-Call Data)

Instrumentation adds timing code to specific functions, providing exact call counts and times:

```c
// Function-level instrumentation
static uint64_t tt_probes = 0;
static uint64_t tt_hits = 0;
static uint64_t tt_probe_time = 0;

TTEntry* probe_tt(uint64_t hash) {
    uint64_t start = rdtsc();
    tt_probes++;
    TTEntry* entry = &tt[hash & tt_mask];
    if (entry->hash == hash) tt_hits++;
    tt_probe_time += rdtsc() - start;
    return entry;
}

void print_stats() {
    printf("TT Probes: %lu, Hits: %lu (%.1f%%), Avg cycles: %.1f\n",
           tt_probes, tt_hits, 100.0 * tt_hits / tt_probes,
           (double)tt_probe_time / tt_probes);
}
```

The `rdtsc()` intrinsic (Read Time-Stamp Counter) provides cycle-accurate timing on x86:

```c
#include <x86intrin.h>
static inline uint64_t rdtsc() {
    return __rdtsc();
}
```

==== Node Counts and NPS

The standard throughput metric is *nodes per second* (NPS)—the number of positions searched per wall-clock second. A strong modern engine on a single core achieves:

```text
Engine Type             Typical NPS (1 core, modern CPU)
─────────────────────── ────────────────────────────────
Classical eval (C)      2-5 million
NNUE eval (C++)         1-2 million
Classical eval (Rust)   1.5-3 million
NNUE eval (Rust)        0.8-1.5 million
```

NNUE engines are typically slower per-node but more accurate per-node, resulting in higher overall Elo. The performance optimization challenge for NNUE is different: focusing on inference throughput and memory bandwidth rather than traditional evaluation efficiency.

=== Memory Hierarchy and Cache Optimization

Modern CPUs are memory-starved: accessing main memory takes ~100 CPU cycles (50-100 nanoseconds), while an L1 cache access takes ~4 cycles (~1 nanosecond). The chess engine's data structures must be laid out to maximize cache hits.

==== The Cache Hierarchy

```text
Cache Level    Size (Typical)    Latency    Bandwidth
────────────── ────────────────  ───────── ──────────
L1 (Data)      32 KB per core    4 cycles   64 bytes/cycle
L2             256-512 KB/core   12 cycles  32 bytes/cycle
L3 (Shared)    2-32 MB/socket    40 cycles  16 bytes/cycle
Main Memory    8-256 GB          100+ cyc.  8-16 bytes/cycle
```

The critical insight: a 64-byte cache line means that accessing any single byte in a cache line loads the entire 64-byte chunk. Data structures should be arranged so that frequently accessed fields are contiguous and fit within a single cache line.

==== Cache-Line Alignment

The `Position` structure is accessed at every node of the search tree—tens of millions of times per second. It must fit in as few cache lines as possible:

```c
// BAD: 64+ bytes with poor layout, scattered across multiple cache lines
struct Position {
    uint64_t pieces[12];     // 96 bytes
    uint64_t occupancy[3];   // 24 bytes
    int piece_on[64];        // 256 bytes
    int king_sq[2];          // 8 bytes
    int side_to_move;        // 4 bytes
    // alignment padding wastes more cache lines
};

// GOOD: Cache-line-conscious layout
struct alignas(64) Position {
    // Hot fields (accessed at every node) in first cache line
    uint64_t occupancy[3];   // 24 bytes
    uint64_t pieces[6];      // 48 bytes (one side only, reconstructed as needed)
    int16_t piece_list[32];  // 64 bytes: indices of pieces
    uint8_t king_sq[2];      // 2 bytes
    uint8_t side;            // 1 byte
    // Total: ~140 bytes → 3 cache lines (first line handles 90% of accesses)
    
    // Cold fields (accessed only during make/unmake): subsequent cache lines
    uint64_t pieces_other[6];  // 48 bytes
    uint8_t piece_on[64];      // 64 bytes
    uint8_t castle_rights;     // 1 byte
    uint8_t ep_square;         // 1 byte
    uint8_t rule50;            // 1 byte
    uint16_t game_ply;         // 2 bytes
    // ...
};
```

The `alignas(64)` ensures the Position starts on a cache-line boundary, preventing the hot fields from being split across cache lines.

==== False Sharing

In parallel search (Chapter 14), *false sharing* occurs when two threads modify variables that reside on the same cache line, even if those variables are logically independent. The cache coherence protocol forces the entire cache line to bounce between CPU cores, degrading parallel performance.

```c
// BAD: Thread A writes to its_tt_probes, Thread B writes to its_nps
// Both are in the same 64-byte region → cache line ping-pong
struct ThreadData {
    uint64_t tt_probes;   // Thread A writes here
    uint64_t nodes;       // Thread B writes here (same cache line!)
};
ThreadData threads[64];   // array of structs → false sharing

// GOOD: Each thread has its own cache line
struct alignas(64) ThreadData {
    uint64_t tt_probes;
    uint64_t nodes;
    // padding ensures this struct is exactly 64 bytes
    uint8_t __pad[64 - 2 * sizeof(uint64_t)];
};
ThreadData threads[64];   // array of aligned structs → no false sharing
```

Or, more elegantly, use a structure-of-arrays layout:

```c
struct ThreadDataSoA {
    uint64_t tt_probes[64];  // All probes in contiguous array
    uint64_t nodes[64];      // All counts in contiguous array (separate cache line)
};
```

==== Prefetching

Prefetching gives the CPU a "heads up" that you'll need a memory location soon, allowing it to begin the cache line load in the background while you do other useful work:

```c
void search(Position *pos, int depth, int alpha, int beta) {
    // Prefetch the transposition table entry BEFORE move generation
    TTEntry *tte = &tt[pos->hash & tt_mask];
    __builtin_prefetch(tte, 0, 3);  // read, high temporal locality
    
    // Move generation runs while TT loads in background
    MoveList moves;
    generate_moves(pos, &moves);
    
    // By now, the TT entry is likely in cache
    if (tte->hash == pos->hash) {
        // TT hit; data is ready
    }
}
```

Prefetching is most effective for:
- Transposition table lookups (the TT is too large for cache; without prefetching, every probe is a cache miss).
- Magic bitboard tables (sliding piece attack tables accessed during move generation).
- NNUE weight loading (during evaluation, weights for the current layer can be prefetched while computing the previous layer).

The prefetch distance—how far in advance to issue the prefetch—must be tuned. Issuing it too early wastes the cache (the data may be evicted before use); issuing it too late provides no benefit. A common pattern: prefetch the TT entry *before* the recursive search call, so it's ready when the child node starts.

=== CPU-Specific Optimizations

Modern CPUs have specialized instructions that can dramatically accelerate chess engine operations.

==== POPCNT (Population Count)

The `POPCNT` instruction counts the number of set bits in a register in a single cycle. This is essential for:
- Counting pieces on the board (material evaluation).
- Counting attacks (mobility evaluation).
- Counting legal moves (ordering heuristics).

```c
#include <nmmintrin.h>  // SSE4.2

int count_moves(uint64_t moves) {
    return _mm_popcnt_u64(moves);  // single instruction on modern CPUs
}
```

Without POPCNT, the fastest fallback uses the SWAR (SIMD Within A Register) technique:

```c
int popcount_swar(uint64_t x) {
    x = x - ((x >> 1) & 0x5555555555555555ULL);
    x = (x & 0x3333333333333333ULL) + ((x >> 2) & 0x3333333333333333ULL);
    x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0FULL;
    return (x * 0x0101010101010101ULL) >> 56;
}
```

This SWAR popcount is approximately 3-5x slower than hardware POPCNT but works on all CPUs. Modern engines build both paths and select at runtime:

```c
static int (*popcount)(uint64_t);

void init_popcount() {
    if (__builtin_cpu_supports("popcnt")) {
        popcount = popcount_hw;
    } else {
        popcount = popcount_swar;
    }
}
```

==== LSB/BSF (Bit Scan Forward)

Finding the least significant set bit (used in bitboard iteration):

```c
int lsb(uint64_t x) {
    return __builtin_ctzll(x);  // counts trailing zeros → BSF on x86, CLZ on ARM
}
```

Many engines combine pop and clear:

```c
#define pop_lsb(b) ({ int lsb = __builtin_ctzll(b); (b) &= (b) - 1; lsb; })
```

The `(b) &= (b) - 1` clears the LSB; together this iterates over all set bits in a bitboard.

==== BMI2: PEXT and PDEP

PEXT (Parallel Bits Extract) and PDEP (Parallel Bits Deposit) are bit-manipulation instructions introduced with Intel's Haswell (2013). They are essential for the fast magic bitboard replacement:

```c
uint64_t pext_rook_attacks(int sq, uint64_t occupied) {
    uint64_t blockers = occupied & rook_masks[sq];
    uint64_t index = _pext_u64(blockers, rook_masks[sq]);
    return rook_table[sq][index];
}
```

The PEXT approach is significantly faster than traditional magic bitboards because it replaces a 64-bit multiply and shift with a single hardware instruction. It also eliminates the need for magic number search.

Detection and fallback:

```c
static bool has_pext;

void init_cpu_features() {
    has_pext = __builtin_cpu_supports("bmi2");
}

uint64_t bishop_attacks(int sq, uint64_t occupied) {
    if (has_pext) {
        return pext_bishop_attacks(sq, occupied);
    } else {
        return magic_bishop_attacks(sq, occupied);
    }
}
```

==== AVX2 for NNUE

NNUE (Chapter 13) relies heavily on small matrix-vector multiplications: a dense weight matrix multiplied by an input feature vector. AVX2 enables processing 8 weight elements at once (for 16-bit weights) or 16 at once (for 8-bit quantized weights):

```c
#include <immintrin.h>

// Accumulate: output += weights * inputs (16-bit weights, 8 accumulation at a time)
void affine_transform_16bit(const int16_t *weights, const int8_t *inputs,
                            int32_t *output, int input_size, int output_size) {
    for (int o = 0; o < output_size; o++) {
        __m256i acc = _mm256_setzero_si256();
        const int16_t *w = weights + o * input_size;
        
        for (int i = 0; i < input_size; i += 16) {
            // Load 16 input values (extend int8 → int16)
            __m128i in8 = _mm_loadu_si128((const __m128i*)(inputs + i));
            __m256i in16 = _mm256_cvtepi8_epi16(in8);
            
            // Load 16 weight values
            __m256i w16 = _mm256_loadu_si256((const __m256i*)(w + i));
            
            // Multiply and accumulate
            acc = _mm256_add_epi32(acc, _mm256_madd_epi16(in16, w16));
        }
        
        // Horizontal sum of 8 int32 accumulators
        __m128i lo = _mm256_castsi256_si128(acc);
        __m128i hi = _mm256_extracti128_si256(acc, 1);
        __m128i sum = _mm_add_epi32(lo, hi);
        sum = _mm_hadd_epi32(sum, sum);
        sum = _mm_hadd_epi32(sum, sum);
        output[o] = _mm_cvtsi128_si32(sum);
    }
}
```

The key performance trick is the `_mm256_madd_epi16` instruction (Multiply-Add Pairs): it multiplies 8 pairs of int16 values and accumulates them pairwise into 4 int32 accumulators, all in a single instruction. This provides 16 operations per cycle (8 multiplies + 8 adds).

=== Compiler Optimizations

==== Profile-Guided Optimization (PGO)

PGO uses runtime profiling data to inform compilation:

```bash
# Stage 1: Instrument the binary
gcc -fprofile-generate -O3 -march=native -o engine *.c

# Stage 2: Run representative workloads
./engine bench  # typical search pattern

# Stage 3: Recompile with profile data
gcc -fprofile-use -O3 -march=native -o engine *.c
```

PGO typically improves NPS by 5-15% by:
- Inlining functions that profiling shows are frequently called (even if they exceed the normal inlining threshold).
- Laying out basic blocks so that the hot path is contiguous (improving instruction cache).
- Optimizing branch prediction for branches that profiling shows are highly biased.

==== Link-Time Optimization (LTO)

LTO enables cross-translation-unit optimization:

```bash
gcc -flto -O3 -march=native -o engine *.c
```

With LTO, the compiler can:
- Inline functions across source files (critical for small, hot-path functions defined in separate `.c` files).
- Eliminate dead code across the entire program.
- Perform whole-program constant propagation.

LTO with PGO together (using `-fprofile-generate -flto` in stage 1) provides cumulative benefits of 10-25% NPS improvement. This is the "free lunch" of performance optimization—no code changes required.

==== Compiler Flags for Maximum Performance

A typical production build:

```bash
gcc -static -O3 -march=x86-64-v3 -mtune=znver4 \
    -flto -fprofile-use \
    -fno-math-errno -fno-trapping-math \
    -DNDEBUG \
    -o engine *.c
```

Breaking down the flags:

- `-march=x86-64-v3`: Target a specific baseline supporting SSE4.2, AVX2, BMI2, FMA (all modern CPUs). Use `native` for the build machine, but `v3` for portable binaries.
- `-mtune=znver4`: Optimize instruction scheduling for AMD Zen 4. Use `native` or the appropriate target.
- `-static`: Link statically for easy distribution (single binary, no DLL dependencies).
- `-fno-math-errno`, `-fno-trapping-math`: Chess engines perform no floating-point math, but these flags prevent the compiler from generating runtime math library calls for libc functions.
- `-DNDEBUG`: Remove assertions in production builds. (Testing builds should keep assertions enabled.)

==== Language-Specific Performance Notes

**C**: The standard. Zero-cost abstractions (there are none). Direct control over memory layout, alignment, and intrinsics. Downside: manual memory management and no type safety for bitboard operations (a `uint64_t` might be a bitboard, a hash, or a node count—the compiler won't catch mixing them).

**C++**: Near-parity with C for performance when used carefully. Templates enable compile-time specialization (e.g., `template<bool InCheck> void generate_moves(...)`) that eliminates runtime branches. But virtual functions, exceptions, and dynamic allocations can silently degrade performance—avoid them in hot paths.

```cpp
// Template-based dispatch: InCheck is a compile-time constant
template<bool InCheck>
void generate_moves(const Position& pos, MoveList& moves) {
    if constexpr (InCheck) {
        generate_evasions(pos, moves);
    } else {
        generate_all(pos, moves);
    }
}
```

**Rust**: Performance is comparable to C when using `unsafe` for bitboard intrinsics and avoiding bounds checks (using `get_unchecked`). The optimizer (LLVM) generates identical machine code for equivalent Rust and C expressions. The advantage: the safe wrapper layer catches bugs at compile time without runtime overhead.

```rust
fn pop_lsb(bb: &mut u64) -> usize {
    let lsb = bb.trailing_zeros() as usize;
    *bb &= *bb - 1;
    lsb
}
```

**Zig**: Similar performance to C with explicit SIMD support via `@Vector`. Zig's comptime allows generating optimized code paths for specific CPU features without runtime detection overhead.

```zig
const has_popcnt = std.Target.x86.featureSetHas(builtin.cpu.features, .popcnt);
const popcount = if (has_popcnt) popcount_hw else popcount_swar;
```

**Odin**: Explicit SIMD vectors and the `@(rodata)` annotation for compile-time table placement. Odin's `#config` directives allow CPU-feature-specific builds.

=== Memory Allocation Strategies

Chess engines allocate very little memory at runtime (most structures are fixed-size and allocated at initialization). But the few allocations that occur—move lists, search stacks, TT entries—can add up.

==== Arena Allocators

An arena allocator is perfect for search-time allocations (move lists per node). It allocates by bumping a pointer, and all memory is freed at once when the search completes:

```c
typedef struct {
    uint8_t *memory;
    size_t capacity;
    size_t offset;
} Arena;

void *arena_alloc(Arena *a, size_t size) {
    // Align to 8 bytes
    size_t aligned = (a->offset + 7) & ~7;
    if (aligned + size > a->capacity) return NULL;
    void *ptr = a->memory + aligned;
    a->offset = aligned + size;
    return ptr;
}

void arena_reset(Arena *a) {
    a->offset = 0;  // "free" everything instantly
}
```

Arena allocation is an O(1) pointer bump versus O(log n) for `malloc`. Move lists per node are a natural fit: each recursive search node allocates a move list from the arena, and when the search completes (or the search stack unwinds), the arena resets.

==== Pool Allocators for Move Lists

A pool allocator pre-allocates a fixed number of identically-sized objects and hands them out from a free list:

```c
#define MAX_MOVES 256
#define MAX_MOVE_LISTS 1024

typedef struct {
    MoveList lists[MAX_MOVE_LISTS];
    uint16_t free_list[MAX_MOVE_LISTS];
    int free_count;
} MoveListPool;

MoveList *pool_alloc(MoveListPool *pool) {
    if (pool->free_count == 0) return NULL;
    int index = pool->free_list[--pool->free_count];
    pool->lists[index].count = 0;
    return &pool->lists[index];
}

void pool_free(MoveListPool *pool, MoveList *list) {
    int index = list - pool->lists;
    pool->free_list[pool->free_count++] = index;
}
```

This is faster than arena allocation (no alignment calculation) and avoids memory fragmentation entirely. The maximum number of concurrent move lists is bounded by the search depth × the number of moves examined, which is predictable.

==== TT Memory Layout

The transposition table is typically a large (4MB to 1GB) flat array of power-of-two size. The index is `hash & (size - 1)`. This layout:

- Makes probing O(1) with a single bitwise AND.
- Is cache-friendly (consecutive probes tend to hit nearby entries).
- Allows the OS to use huge pages (2MB or 1GB pages) for the TT, reducing TLB misses.

```c
void init_tt(size_t size_mb) {
    // Align to huge page boundary (2MB)
    size_t size = 1ULL << (64 - __builtin_clzll(size_mb * 1024 * 1024));
    // Use mmap with MAP_HUGETLB if available
    tt = mmap(NULL, size, PROT_READ | PROT_WRITE,
              MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
    if (tt == MAP_FAILED) {
        // Fall back to regular allocation
        tt = calloc(size, 1);
    }
}
```

Huge pages reduce TLB (Translation Lookaside Buffer) misses: a 1 GB TT mapped with 2 MB pages requires only 512 TLB entries, versus 262,144 entries with 4 KB pages. This can improve TT probe throughput by 5-15%.

=== Branch Prediction Optimization

Modern CPUs predict branches with >95% accuracy. But chess engine code is notoriously branch-unfriendly because the game state is highly variable. Every `if` in a hot loop is a potential branch misprediction (~15-20 cycle penalty).

==== Techniques to Improve Branch Prediction

**1. Convert branches to conditional moves**:

```c
// BAD: Branch
int score = (side == WHITE) ? mg_score : eg_score;  // unpredictable!

// BETTER: Conditional move (compiler may do this automatically at -O3)
int score = mg_table[side] + eg_table[side];  // table lookup, no branch
```

**2. Use lookup tables for small decision spaces**:

```c
// BAD: Branch chain
int piece_value(int piece, int phase) {
    if (piece == PAWN)   return phase == MG ? 100 : 120;
    if (piece == KNIGHT) return phase == MG ? 320 : 300;
    // ...
}

// BETTER: Two-dimensional table
const int piece_values[2][6] = {
    {100, 320, 330, 500, 900, 0},  // middlegame
    {120, 300, 330, 520, 940, 0},  // endgame
};
int value = piece_values[phase][piece];  // single memory access
```

**3. Sort moves to make common paths predictable**:

Move ordering (Chapter 9) is as much about branch prediction as it is about alpha-beta efficiency. The first move at each node is usually the best; if the CPU learns "the first few moves will cause a cutoff," it can predict the loop termination with high accuracy.

**4. Use `__builtin_expect` for unlikely branches**:

```c
if (__builtin_expect(pos->rule50 >= 100, 0)) {  // unlikely
    return DRAW;  // fifty-move rule
}
```

This hints to the compiler to lay out the "likely" path contiguously in memory (improving I-cache) and to pessimize the branch predictor for the unlikely case.

=== Benchmarking NPS

A standard NPS benchmark measures single-threaded search throughput on a fixed position:

```bash
# Standard "bench" command
./engine << EOF
position startpos
go depth 15
EOF
```

To compare optimizations fairly, average over multiple runs:

```bash
#!/bin/bash
# nps_bench.sh
for i in {1..10}; do
    echo "position startpos moves e2e4 e7e5
go depth 15" | ./engine 2>&1
done | grep "nodes per second" | awk '{sum += $NF; count++} END {print sum/count}'
```

Key factors that affect NPS benchmarks:
- CPU frequency (disable frequency scaling: `cpupower frequency-set -g performance`).
- Thermal throttling (ensure the CPU is cool; sustained benchmarks heat up the CPU and trigger throttling).
- Competing processes (run on an idle system, or use `taskset` to isolate cores).
- Position characteristics (tactical positions generate fewer moves but more node-intensive evaluations; quiet positions are the opposite).

=== Performance-Critical Code Patterns

==== Fast Bitboard Iteration

```c
// While there are bits set, extract and clear the LSB
uint64_t bb = rook_attacks(sq, occupied) & ~friendly;
while (bb) {
    int to = __builtin_ctzll(bb);
    bb &= bb - 1;  // clears LSB
    add_move(sq, to, 0);
}
```

This loop compiles to ~3 instructions per bit (TZCNT, AND, MOV). It is essentially optimal.

==== Avoid Division and Modulo

```c
// BAD: Division/modulo for square decomposition
int rank = sq / 8;
int file = sq % 8;

// BETTER: Bitwise operations for power-of-2
int rank = sq >> 3;   // sq / 8
int file = sq & 7;    // sq % 8
```

On older CPUs, integer division is 20-80 cycles. On modern CPUs, it's 10-20 cycles for 32-bit division—still much slower than shift/AND (~1 cycle each).

==== Minimize Function Call Overhead

For functions called millions of times per second (like `make_move` and `unmake_move`), function call overhead (stack frame setup, argument passing) can be significant. Use `inline` or `static` for small, hot-path functions:

```c
static inline void add_move(MoveList *list, int from, int to, int flags) {
    list->moves[list->count++] = (from << 6) | to | flags;
}
```

The compiler will inline this automatically at `-O3` for `static` functions, but `inline` makes the intent explicit and works across translation units with LTO.

=== The Performance Optimization Loop

Performance optimization should follow a disciplined loop:

1. **Profile**: Identify the hottest function. Use `perf` or VTune.
2. **Hypothesize**: What cache or instruction bottleneck limits this function? (Cache misses? Branch mispredictions? Data dependencies?)
3. **Transform**: Apply a specific optimization (reorder data, eliminate branches, add prefetching, use intrinsics).
4. **Measure**: Run the NPS benchmark before and after. Did it improve?
5. **Verify correctness**: Run perft (Chapter 4) to ensure you didn't break anything. Run a short SPRT to ensure Elo didn't regress.
6. **Repeat**: Find the next hot spot.

The most common mistakes:
- Optimizing before profiling (fixing 1% bottlenecks).
- Micro-optimizing at the expense of correctness (a fast engine that plays bad moves is worthless).
- Ignoring memory layout (algorithmic improvements + data layout changes produce 10x the gains of instruction-level tweaks).
- Premature "optimization" of cold paths (initialization code, UCI parsing, statistics collection).

=== Summary

Performance optimization is a multiplier on engine strength. A 20% faster engine at the same quality searches 20% deeper, which typically translates to 20-40 Elo. The key techniques:

1. **Profiling**: Use sampling profilers to identify hot spots—never guess.
2. **Cache optimization**: Align hot data structures to cache lines, avoid false sharing, prefetch TT entries.
3. **CPU intrinsics**: Use POPCNT for bit counting, BMI2/PEXT for fast magic bitboards, AVX2 for NNUE inference.
4. **Compiler options**: PGO + LTO for 10-25% free speedup; `-march=native` for CPU-specific instruction scheduling.
5. **Memory allocation**: Arena allocators for per-node move lists, pool allocators for fixed-size objects, huge pages for TT.
6. **Branch prediction**: Table-driven decision making, conditional moves, and good move ordering all improve branch prediction.
7. **Measured iteration**: Every optimization must be verified with benchmarks and correctness tests.
