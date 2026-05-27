== Transposition Tables: Never Search the Same Position Twice

The transposition table (TT) is the single most important data structure in a chess engine. It converts the alpha-beta search from an exponential-time algorithm that repeatedly re-searches identical positions into a near-linear-time algorithm that remembers and reuses previous results. Without a TT, a chess engine at depth 10 would visit billions of nodes; with a TT, millions. The difference is three orders of magnitude.

This chapter covers every aspect of transposition tables: Zobrist hashing, table structure and sizing, replacement strategies, aging, lockless hashing, score adjustment for mate distances, integration with the search algorithm, memory layout, and the critical-path performance analysis that determines whether your TT is a bottleneck or an accelerator.

=== Why Transpositions Occur: The Graph Nature of Chess

A chess position can be reached through many different move sequences. For example, the position after:

- `1.e4 e5 2.Nf3 Nc6`
- `1.Nf3 Nc6 2.e4 e5`

is identical. These two move sequences *transpose* into the same position. In the search tree, a position at depth 5 might be reached through dozens of different paths, each exploring different lines that happened to converge on the same arrangement of pieces.

Without a transposition table, the engine would search this position from scratch each time it encounters it. With a TT, the first search stores the result, and subsequent encounters retrieve it in constant time. Since a typical search tree contains millions of unique positions but billions of total nodes, the TT effectively caches the results of entire sub-trees.

==== Quantifying Transposition Frequency

In the opening, transpositions are frequent—the same position can be reached through many move orders. In the middlegame, transpositions are less common but still significant, especially through piece repositioning. In the endgame, transpositions are extremely frequent—with few pieces on the board, move order matters little, and positions repeat constantly.

Empirically, at depth 10 from the starting position, approximately 40-60% of positions searched are transpositions of previously searched positions. The TT hit rate (percentage of nodes where the TT provides useful information) typically ranges from 15-40% in middlegame search and 50-80% in endgame search.

=== Zobrist Hashing: The Foundation of Position Identity

To use a transposition table, we must be able to identify each position by a compact, unique key. *Zobrist hashing* (invented by Albert Zobrist in 1970) provides this: a 64-bit hash key computed as the XOR of random 64-bit numbers, one for each `(piece, color, square)` combination, plus additional keys for side to move, castling rights, and en passant square.

==== The Zobrist Key Construction

For each of the 12 piece types (6 types × 2 colors), and for each of the 64 squares, generate a random 64-bit number:

```c
uint64_t zobrist_pieces[12][64];  // 12 pieces × 64 squares = 768 random numbers
uint64_t zobrist_side_to_move;    // 1 key for Black to move
uint64_t zobrist_castling[16];    // 16 keys for castling rights (4 bits)
uint64_t zobrist_en_passant[8];   // 8 keys for en passant file (none + files A-H)
```

The position's hash key is computed as:

```c
uint64_t compute_hash(Position *pos) {
    uint64_t hash = 0;

    // XOR in each piece on the board
    for (int sq = 0; sq < 64; sq++) {
        Piece p = pos->board[sq];
        if (p != NO_PIECE) {
            int index = piece_type_index(p_type(p), p_color(p));
            hash ^= zobrist_pieces[index][sq];
        }
    }

    // XOR in side to move (only if Black to move — White is "default")
    if (pos->side == BLACK) {
        hash ^= zobrist_side_to_move;
    }

    // XOR in castling rights and en passant
    hash ^= zobrist_castling[pos->castle_rights];
    if (pos->en_passant != NO_SQUARE) {
        hash ^= zobrist_en_passant[file_of(pos->en_passant)];
    }

    return hash;
}
```

The critical property: XOR is commutative and each number is its own inverse. This means we can incrementally update the hash during make_move, rather than recomputing from scratch:

```c
// During make_move, the hash is updated incrementally:
void update_hash(Move move, Position *pos) {
    // Remove the moving piece from its source square
    pos->hash ^= zobrist_pieces[piece_idx][from_sq];

    // Place the moving piece on its destination square
    pos->hash ^= zobrist_pieces[piece_idx][to_sq];

    // If capturing, remove the captured piece from the destination
    if (is_capture(move)) {
        pos->hash ^= zobrist_pieces[captured_piece_idx][to_sq];
    }

    // Toggle side to move (XOR flips it: White→Black, Black→White)
    pos->hash ^= zobrist_side_to_move;

    // Update castling and en passant keys as needed
    // ...
}
```

The incremental update costs only a handful of XOR operations, compared to the `O(64)` cost of full recomputation. This is critical because hash updates occur in the make/unmake path, which is called at every node of the search.

==== Zobrist Key Quality

The Zobrist keys must be high-quality random numbers—specifically, they must have low *collision probability*. With 64-bit keys generated by a good pseudo-random number generator, the probability of a hash collision between two different positions is:

```text
P(collision) ≈ 1 - e^(-n^2 / (2^64))
```

For `n = 2^30` (one billion) positions, the collision probability is approximately `1 - e^(-2^60 / 2^65) ≈ 1 - e^(-1/32) ≈ 0.03`, or about 3%. For the ~50 million positions in a typical search, it is far lower—effectively zero.

However, poor-quality random keys (e.g., using a weak PRNG or reusing keys) can cause systematic collisions that silently corrupt search results. This is a notorious source of bugs: the engine plays nonsense moves because it "thinks" it has searched a position when in fact it retrieved results for a different position that happened to collide.

*Best practice*: Use a 64-bit Mersenne Twister or Xorshift generator to create the Zobrist keys, store the keys in the engine binary, and never change them. Changing Zobrist keys invalidates all stored analysis, transposition table files, and opening books.

==== Lockless Hashing: The XOR Trick

In a basic TT, the hash key identifies the position. But if two positions collide (same hash key), the engine cannot tell them apart—it treats the stored data as valid for the current position. The *lockless hashing* trick provides protection:

Instead of storing the full 64-bit key, store the XOR of the key with the stored data:

```c
uint64_t lock = hash_key ^ ((uint64_t)score << 32 | (uint64_t)move);
```

When retrieving an entry, recompute the hash, XOR it with the lock to recover the data. If the result contains valid-looking data (score in range, legal move), the entry is almost certainly correct. If not, a collision occurred, and the entry is discarded.

This costs one additional XOR per TT access but eliminates virtually all collision-induced errors.

=== Transposition Table Structure

A TT is a fixed-size hash table mapping 64-bit hash keys to search results. The structure is straightforward but the details—size, indexing, replacement—determine its performance.

==== Table Size

The TT size is typically a power of two, specified at engine startup:

```c
// Typical sizes: 16 MB (2^24 bytes), 64 MB (2^26), 256 MB (2^28), 1024 MB (2^30)
size_t tt_size = 1 << 24;  // 16 MB
```

The TT is divided into *buckets* (or "clusters"), each containing 2-4 entries. Power-of-two sizing allows fast indexing with a bitmask:

```c
int bucket_index = hash_key & (num_buckets - 1);
```

==== Entry Structure

Each TT entry stores:

```c
typedef struct {
    uint64_t hash_key;    // 16 bits typically (full key is 64, store the upper bits)
    int16_t  score;       // Search score in centipawns
    int16_t  static_eval; // Static evaluation (for evaluation-based cutoffs)
    uint16_t move;        // Best move (compact encoding)
    uint8_t  depth;       // Search depth
    uint8_t  age  : 4;    // Age bits (for replacement)
    uint8_t  flag : 2;    // TT_EXACT, TT_ALPHA, or TT_BETA
    // Total: ~12 bytes per entry
} TTEntry;
```

A typical TT bucket holds 4 entries (48 bytes per bucket). For a 16 MB TT, this gives:

```text
num_buckets = 16 MB / 48 bytes per bucket = ~350,000 buckets
total_entries = 350,000 × 4 = 1.4 million entries
```

1.4 million entries is sufficient for many positions, but deep searches can generate 10-50 million nodes—far exceeding TT capacity. This is where replacement strategies become critical.

==== Score Flag Types

Each TT entry stores one of three *score flags* indicating the precision of the stored score:

- `TT_EXACT`: The stored score is the exact value of the position (from a PV node or after a fail-soft re-search).
- `TT_ALPHA` (upper bound): The score is an upper bound—the true score is at most this value. Used when a search fails low (all moves failed to raise alpha).
- `TT_BETA` (lower bound): The score is a lower bound—the true score is at least this value. Used when a search fails high (a beta cutoff occurred).

These flags determine how the stored score can be used:

```c
TTEntry *tte = probe_tt(hash_key);

if (tte && tte->depth >= depth) {
    if (tte->flag == TT_EXACT) {
        return score_from_tt(tte);  // exact score, can use directly
    }
    if (tte->flag == TT_ALPHA && tte->score <= alpha) {
        return alpha;  // upper bound below our lower bound → fail-low
    }
    if (tte->flag == TT_BETA && tte->score >= beta) {
        return beta;   // lower bound above our upper bound → fail-high
    }
}
```

=== Replacement Strategies

When a new entry must be stored in a full bucket, which old entry is evicted? Several strategies exist:

==== Always-Replace

The simplest strategy: always store the new entry, overwriting whatever was there. This ensures the most recent search results are always available, but it can discard deep, expensive search results in favor of shallow, cheap ones.

==== Depth-Preferred

Store the new entry, but prefer to evict the entry with the *lowest depth*. The intuition: a deep search result is more valuable than a shallow one, because deeper searches cost exponentially more nodes. If all entries have equal or greater depth, evict the oldest.

```c
int replace_index = -1;
int min_depth = depth + 1;  // higher than our depth

for (int i = 0; i < BUCKET_SIZE; i++) {
    if (bucket[i].depth < min_depth) {
        min_depth = bucket[i].depth;
        replace_index = i;
    }
}

if (replace_index >= 0) {
    bucket[replace_index] = new_entry;
}
```

If no entry has a lower depth, the replacement is refused (the new entry is not stored). This avoids replacing a deep result with a shallow one, but it can cause "starvation": the TT fills up with deep entries and never updates, causing stale data.

==== Two-Tier (Age-Preferred + Depth-Preferred)

Modern engines use a hybrid: each bucket has slots with different priorities. Stockfish uses a 4-entry bucket with two "age" slots and two "depth" slots:

- *Age slots* (2 entries): Overwritten by any entry with a newer age.
- *Depth slots* (2 entries): Overwritten only by entries with greater or equal depth.

If an entry's age is newer than any age-slot entry, it replaces the oldest age-slot entry. Otherwise, if its depth is greater than or equal to the shallowest depth-slot entry, it replaces that entry. Otherwise, it's not stored.

This balances freshness (recent search results are available) with depth quality (deep results are preserved).

==== Aging

TT entries become stale over time. When starting a new search (at the root, for a new position), the engine increments an *age counter*. Each TT entry stores the age at which it was written. During probing, entries with an old age are treated as lower priority:

```c
if (tte->age != current_age) {
    // Entry is from a previous search—treat its depth as reduced
    effective_depth = tte->depth - AGE_PENALTY;
}
```

Aging also affects replacement: entries with old age are always replaced, regardless of depth, because they are from a previous search and no longer relevant.

=== TT in Search: The Complete Integration

The TT is not just a lookup table—it is deeply integrated into the search algorithm, affecting move ordering, pruning decisions, and score bounds.

==== TT Move Ordering

The TT move is the single most important move ordering input. Before generating moves, probe the TT:

```c
TTEntry *tte = probe_tt(hash);
Move tt_move = (tte && tte->depth >= 0) ? tte->move : NO_MOVE;
```

If the TT has a move, it is searched first. Even if the TT score is not reusable (depth insufficient), the move is still an excellent guess.

==== TT-Based Pruning

When the TT provides a bound that is sufficient to cause a cutoff, the search can return immediately without generating or searching any moves:

```c
TTEntry *tte = probe_tt(hash);

if (tte && tte->depth >= depth) {
    if (tte->flag == TT_EXACT) {
        return adjust_score(tte->score, ply);  // adjust for mate distance
    }
    if (tte->flag == TT_ALPHA && tte->score <= alpha) {
        return alpha;  // upper bound proves we can't reach alpha
    }
    if (tte->flag == TT_BETA && tte->score >= beta) {
        return beta;   // lower bound proves cutoff
    }
}
```

This is the most impactful TT use case: it eliminates the entire node's search (including move generation) for positions that have been searched before at sufficient depth.

==== TT Score Adjustment for Mate Distance

Scores involving checkmate are stored relative to the root position. If a position is "mate in 5" (from the root), and we encounter it at ply 3, the stored score must be adjusted to "mate in 2" (from the current position). Similarly, when storing:

```c
int score_to_tt(int score, int ply) {
    if (score > MATE_SCORE - MAX_PLY) {
        return score + ply;  // winning mate: adjust outward
    }
    if (score < -MATE_SCORE + MAX_PLY) {
        return score - ply;  // losing mate: adjust outward
    }
    return score;  // normal score: no adjustment
}

int score_from_tt(int score, int ply) {
    if (score > MATE_SCORE - MAX_PLY) {
        return score - ply;  // winning mate: adjust inward
    }
    if (score < -MATE_SCORE + MAX_PLY) {
        return score + ply;  // losing mate: adjust inward
    }
    return score;
}
```

Without this adjustment, a stored "mate in 5" score at ply 3 would be treated as "mate in 5" from the current position (ply 3), when it should be "mate in 2." This would cause the engine to think a checkmate is further away than it actually is.

=== Memory Layout and Cache Performance

A TT is a large, randomly accessed data structure. Its memory layout significantly impacts performance because it competes for L2/L3 cache space with other data structures (pawn hash, material hash, evaluation tables).

==== Cache Line Alignment

A TT bucket should fit within a single cache line (typically 64 bytes on x86-64). With 4 entries at 12 bytes each (48 bytes total), a bucket fits comfortably in one cache line plus metadata. Padding to 64 bytes ensures that probing a bucket requires only one cache line load:

```c
typedef struct {
    TTEntry entries[4];  // 48 bytes
    uint8_t  padding[16]; // pad to 64 bytes (cache line alignment)
} __attribute__((aligned(64))) TTBucket;
```

==== Prefetching

The TT probe is on the critical path of every node. The address of the probed bucket depends on the hash key, which is available early (before move generation). Engines can issue a *prefetch* instruction to begin loading the cache line while other work proceeds:

```c
// Issue prefetch early, before move generation
_mm_prefetch(&tt->buckets[bucket_index], _MM_HINT_T0);

// ... do other work (move generation, move ordering) ...

// Later, the bucket is in L1 cache
TTEntry *bucket = tt->buckets[bucket_index];
```

On modern x86 CPUs, prefetching can reduce TT probe latency from 20-50 cycles (L3 cache) to 4-5 cycles (L1 cache), providing a measurable speedup.

==== Competing Data Structures

The TT is not the only large data structure in an engine. Pawn structure hash, material hash, and evaluation cache all compete for cache space. If these structures are too large, they evict the TT from cache, slowing down TT probes. The TT should be sized to fit within the available L3 cache (typically 16-32 MB on modern CPUs) if possible, while other structures are kept smaller.

=== TT in Parallel Search

In parallel search (Chapter 14), multiple threads access the same TT simultaneously. This requires careful handling to avoid data races and corruption.

==== Lock-Based TT

The simplest approach: protect each bucket with a mutex or spinlock. But this adds lock contention overhead, which can serialize the search. For small numbers of threads (2-4), a lock per bucket with a simple spinlock is acceptable. For large numbers (64+ on a threadripper), lock contention becomes a major bottleneck.

==== Lockless TT (The XOR Trick Revisited)

The lockless approach stores each entry atomically. On x86, aligned 64-bit writes are atomic. Using the XOR trick (storing `hash XOR data`), a reader can validate the entry without locking:

```c
// Store (atomic on x86 for aligned 64-bit writes):
void store_lockless(TTBucket *bucket, TTEntry entry) {
    uint64_t packed = pack_entry(entry);  // pack score, move, depth, flags into 64 bits
    uint64_t lock = hash_key ^ packed;
    bucket->slot[i].lock = lock;  // single 64-bit write
}

// Probe (lock-free read):
bool probe_lockless(TTBucket *bucket, uint64_t hash_key, TTEntry *out) {
    uint64_t lock = bucket->slot[i].lock;
    uint64_t packed = lock ^ hash_key;
    TTEntry entry = unpack_entry(packed);

    // Validate
    if (!is_valid_entry(entry)) return false;

    *out = entry;
    return true;
}
```

Since XOR with the correct hash recovers the correct data (and an incorrect hash produces garbage that fails validation), this provides lock-free reads. Writes require a single aligned store, which is atomic on x86.

For platforms without guaranteed atomic 64-bit writes, the lock can be built with two 32-bit writes and a sequence counter. This is more complex but works on all architectures.

=== TT in Endgame Tablebases

When tablebases (Chapter 15) are available, the TT interacts with them: a tablebase probe provides the exact score of any position with 7 or fewer pieces. This score can be stored in the TT, effectively extending the tablebase to positions reachable from the endgame:

```c
if (popcount(pos->occupied) <= TB_MAX_PIECES) {
    int score = probe_tablebase(pos);
    if (score != TB_UNKNOWN) {
        store_tt(hash, score, MAX_PLY, NO_MOVE, TT_EXACT, 0);
        return score;
    }
}
```

Storing tablebase scores in the TT means that a position 1-2 plies away from a tablebase position (8 pieces on the board) can be evaluated by the TT without a tablebase probe, because the tablebase score was stored during the search of the 7-piece position.

=== TT Performance Analysis: Hit Rate and Critical Path

The performance of a TT is measured by two metrics:

1. *Hit rate*: Percentage of TT probes that find a useful entry (depth sufficient, score usable). Typical: 15-40% in middlegames, 50-80% in endgames.

2. *Critical path latency*: Time from hash computation to score retrieval. This is on the critical path of every node.

A TT probe involves:
- Hash computation: 0 cycles (hash is maintained incrementally, available immediately).
- Index calculation: 1 cycle (bitwise AND with bitmask).
- Cache line load: 3-5 cycles if in L1, 10-15 cycles if in L2, 40-80 cycles if in L3, 200-300 cycles if in RAM.
- Entry search within bucket: 2-3 cycles per entry (linear scan of 2-4 entries).
- Score adjustment: 2-3 cycles.

Total: 5-15 cycles in the best case (L1 cache hit), 300+ cycles in the worst case (RAM access). At 4 GHz, this means 1.25-75 nanoseconds per probe—acceptable given the enormous savings from avoiding entire sub-tree searches.

==== Optimizing for L1/L2 Hit Rate

The TT hit rate in L1/L2 cache depends on the *working set size*: the set of entries that are repeatedly accessed during a search. A smaller TT fits more of its working set in faster cache levels, which reduces probe latency. But too small a TT causes more overwrites, reducing the hit rate.

The optimal TT size balances these concerns. Empirically, for a single-threaded search at depth 12-14, a 16 MB TT achieves 80-90% L3 cache hit rates on modern CPUs with 32 MB L3 cache. Larger TTs (64-256 MB) primarily benefit long time-control analysis where the search tree is deeper and the working set is larger.

=== Language-Specific Implementations

==== C Implementation

```c
// Memory-efficient TT entry (12 bytes)
typedef struct {
    int16_t  score;
    uint16_t move;
    int16_t  static_eval;
    uint16_t hash_hi;     // upper 16 bits of hash (for disambiguation)
    uint8_t  depth_age;   // depth in high 5 bits, age in low 3 bits
    uint8_t  flag_pad;    // flag in low 2 bits, padding
} TTEntry;

// Lockless store
static inline void tt_store(TT *tt, uint64_t hash, int score, Move move,
                            int depth, int flag, int ply, int age) {
    int index = hash & (tt->num_buckets - 1);
    TTBucket *bucket = &tt->buckets[index];
    TTEntry *replace = NULL;

    // Find the best entry to replace (depth-preferred with age override)
    for (int i = 0; i < 4; i++) {
        if (bucket->entries[i].depth_age >> 3 != age) {
            replace = &bucket->entries[i];  // stale entry, always replace
            break;
        }
        if (!replace || (bucket->entries[i].depth_age >> 3) < (replace->depth_age >> 3)) {
            replace = &bucket->entries[i];  // lowest depth
        }
    }

    // Store
    replace->score = score_to_tt(score, ply);
    replace->move = move;
    replace->static_eval = evaluate_approx(pos);  // or stored from search
    replace->hash_hi = (uint16_t)(hash >> 48);
    replace->depth_age = (depth << 3) | age;
    replace->flag_pad = flag;
}
```

==== C++ Implementation

```cpp
class TranspositionTable {
    static constexpr int BUCKET_SIZE = 4;
    static constexpr int ENTRY_SIZE = 12;  // bytes
    static constexpr int BUCKET_BYTES = 64; // cache-line aligned

    struct alignas(64) Bucket {
        std::array<Entry, BUCKET_SIZE> entries;
    };

    std::vector<Bucket> buckets;

public:
    void resize(size_t megabytes) {
        size_t bytes = megabytes << 20;
        size_t num_buckets = bytes / sizeof(Bucket);
        buckets.resize(num_buckets);
    }

    // Template-based probe with compile-time dispatch for exact/alpha/beta
    template<BoundType BT>
    int probe(uint64_t hash, int depth, int alpha, int beta, int ply);
};
```

==== Rust Implementation

```rust
use std::sync::atomic::{AtomicU64, Ordering};

pub struct TranspositionTable {
    buckets: Box<[Bucket]>,
    mask: usize,
}

struct Bucket {
    entries: [AtomicEntry; 4],  // atomic for lockless access
}

struct AtomicEntry {
    pub lock: AtomicU64,  // hash ^ packed_data
}

impl TranspositionTable {
    pub fn new(megabytes: usize) -> Self {
        let bytes = megabytes << 20;
        let num_buckets = bytes / std::mem::size_of::<Bucket>();
        let buckets = vec![Bucket::default(); num_buckets].into_boxed_slice();
        let mask = num_buckets - 1;
        Self { buckets, mask }
    }

    pub fn probe(&self, hash: u64, depth: u8, alpha: i16, beta: i16, ply: usize) -> Option<ProbeResult> {
        let index = hash as usize & self.mask;
        let bucket = &self.buckets[index];

        for entry in &bucket.entries {
            let lock = entry.lock.load(Ordering::Relaxed);
            let packed = lock ^ hash;
            if let Some(result) = Entry::unpack(packed).validate(hash >> 48) {
                // Check depth and bound conditions...
                return Some(result);
            }
        }
        None
    }
}
```

==== Zig Implementation

```zig
const TTBucket = struct {
    entries: [4]TTEntry align(64),

    pub fn probe(self: *const TTBucket, hash: u64, depth: u5, alpha: i16, beta: i16) ?ProbeResult {
        for (self.entries) |entry| {
            const lock = entry.lock;
            const packed = lock ^ hash;
            if (validateEntry(packed, hash >> 48)) {
                const score = entry.scoreFromTT(ply);
                // Check bounds...
                if (entry.depth >= depth) {
                    return ProbeResult{ .score = score, .move = entry.move };
                }
            }
        }
        return null;
    }

    pub fn store(self: *TTBucket, hash: u64, score: i16, mv: Move, depth: u5, flag: Flag) void {
        const replace_idx = self.findReplacement(depth, age);
        self.entries[replace_idx].store(hash, score, mv, depth, flag);
    }
};
```

==== Odin Implementation

```odin
TTBucket :: struct #align 64 {
    entries: [4]TTEntry,
}

TTEntry :: struct {
    lock:     u64,  // hash ^ packed_data
}

probe :: proc(tt: ^TranspositionTable, hash: u64, depth: u8, alpha, beta: i16, ply: int) -> (i16, bool) {
    bucket := &tt.buckets[uint(hash) & tt.mask];

    for &entry in bucket.entries {
        packed := entry.lock ~ hash;  // XOR
        score, move, stored_depth, flag := unpack_entry(packed);

        if !validate_entry(score, move, stored_depth, flag) do continue;
        if u16(hash >> 48) != entry.hash_hi do continue;

        // Score adjustment and bound checking
        adjusted_score := score_from_tt(score, ply);
        if stored_depth >= depth {
            switch flag {
            case .EXACT:
                return adjusted_score, true;
            case .ALPHA:
                if adjusted_score <= alpha do return alpha, true;
            case .BETA:
                if adjusted_score >= beta do return beta, true;
            }
        }
    }
    return 0, false;
}
```

=== The History of Transposition Tables

The concept of position caching in game-playing programs dates to the earliest days of computer chess:

- *1966 (Greenblatt/MIT)*: The Mac Hack program used a simple position table to avoid repeatedly searching the same position. This was a 4096-entry table in an era when memory was measured in kilobytes.
- *1970 (Zobrist)*: The Zobrist hashing technique provided a mathematically sound foundation for position identification with minimal collision probability.
- *1978 (Slate and Atkin, Chess 4.7)*: The modern transposition table architecture, combining Zobrist hashing with depth-preferred replacement, was described in their landmark paper.
- *1990s (Deep Blue)*: IBM's Deep Blue used a massive, custom-built TT with hardware-assisted probing.
- *2000s (Crafty, Fruit)*: Two-tier replacement, lockless hashing, and TT score adjustment for mate distances became standard.
- *2010s-Present (Stockfish)*: Refinements like TT-based singular extensions, evaluation caching in the TT, and sophisticated age management continue to extract the last percentage points of performance.

=== Summary

The transposition table transforms the search algorithm from an exponential-time brute-force exploration into a near-linear-time cached computation:

- *Zobrist hashing*: Incrementally maintainable, collision-resistant position identification using XOR of random 64-bit keys.
- *Table structure*: Power-of-two sized, cache-line-aligned buckets with 2-4 entries each, storing score, move, depth, and bound flags.
- *Replacement strategies*: Depth-preferred with age override—newer and deeper entries survive, older and shallower entries are evicted.
- *Score flags* (EXACT, ALPHA, BETA): Enable using stored scores as exact values, upper bounds, or lower bounds, dramatically increasing cutoff opportunities.
- *TT move ordering*: The stored best move is the single most reliable move ordering heuristic, searched unconditionally first.
- *Lockless hashing*: The XOR trick enables safe concurrent access without locks, essential for parallel search.
- *Performance*: A 16 MB TT achieves 15-40% hit rates in middlegames, saving billions of nodes per search and reducing effective search complexity by one to two orders of magnitude.

The TT is not an optional optimization—it is an essential component without which modern chess engine search would be computationally infeasible. Every top engine devotes 10-30% of its total search time to TT operations, and this investment is repaid a thousandfold in avoided redundant search.
