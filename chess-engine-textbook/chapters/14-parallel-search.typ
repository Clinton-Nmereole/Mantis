== Parallel Search: Scaling Across Cores

Modern CPUs feature dozens of cores, and chess engines must harness this parallelism to remain competitive. However, alpha-beta search is notoriously difficult to parallelize because its pruning power depends on information from previously searched moves—the very sequential dependency that parallelism seeks to break. This chapter covers the techniques that have evolved from early experiments with tree splitting to the elegantly simple Lazy SMP that dominates modern engine design.

=== Why Parallelizing Alpha-Beta Is Hard

Alpha-beta achieves its pruning by maintaining bounds (alpha and beta) that tighten as the search progresses. A parallel search faces a fundamental tension:

1. *Search overhead*: Parallel threads inevitably duplicate work. If thread A and thread B both search the same subtree, the total work increases, reducing the effective speedup. In the worst case, N threads can do more work than a single thread, yielding a speedup less than 1: this is called *search overhead*.

2. *Synchronization cost*: Sharing information between threads (such as updated alpha-beta bounds or transposition table entries) requires synchronization, which introduces latency and contention. A lock on the transposition table can serialize N threads into a single thread.

3. *Speculative work*: A thread may search a subtree that, in a sequential search, would be pruned by a beta cutoff from a move the thread does not yet know about. This speculative work is wasted.

4. *Non-determinism*: Two parallel searches of the same position may return different results because the move-ordering information propagated between threads is timing-dependent. This non-determinism makes parallel search difficult to debug and test.

The challenge, then, is to design a parallel search algorithm that achieves *scalable speedup*: for N threads, the effective search depth or time-to-depth improvement should grow predictably.

=== Search Overhead and Speedup Metrics

Define the *effective speedup* of N threads as:

`S(N) = T(1) / T(N)`

where `T(1)` is the time for a single thread to reach a given depth, and `T(N)` is the time for N threads to reach the *same* depth. If `S(N) = N`, we have linear speedup. In practice, chess search achieves sub-linear speedup due to overhead.

The *search overhead* is:

`O(N) = W(N) / W(1) - 1`

where `W(N)` is the total work (nodes visited) by N threads. If N threads visit the same number of nodes as 1 thread, overhead is zero. In typical implementations, overhead grows with N: for 8 threads, overhead might be 20-50% (meaning 20-50% more total nodes are visited than with 1 thread).

The effective speedup is then:

`S(N) = N / (1 + O(N))`

Empirically, typical Lazy SMP scaling:

```text
Threads    Speedup    Overhead   Effective NPS   Time to depth 20
────────   ────────   ────────   ─────────────  ─────────────────
1          1.0x       0%         100%            100% (baseline)
2          1.9x       5%         190%            53%
4          3.5x       14%        350%            29%
8          6.3x       27%        630%            16%
16         10.8x      48%        1080%           9.3%
32         17.5x      83%        1750%           5.7%
64         25x        156%       2500%           4.0%
```

The speedup falls off with increasing thread count, consistent with Amdahl's Law: the sequential fraction of the search (root moves, TT access) becomes the bottleneck.

=== Lazy SMP: The Dominant Modern Technique

Lazy SMP (Symmetric Multi-Processing) is the parallel search algorithm used by Stockfish, Ethereal, Berserk, and virtually every top engine today. Its key insight is radical simplicity: *all threads search the full tree independently, sharing only the transposition table*. There is no explicit work division, no task queues, no master-worker hierarchy.

==== How Lazy SMP Works

The algorithm is:

1. At the root position, each thread independently runs an iterative deepening search (depth 1, 2, 3, ...) on the full set of root moves.
2. All threads share a single transposition table (TT). When a thread stores a TT entry (score, depth, best move), other threads can read it.
3. Each thread uses a slightly different search depth or move ordering to *de-synchronize* the threads and ensure they explore different parts of the tree.
4. There is no explicit synchronization beyond the atomic TT read/write operations.
5. The "best" result across all threads is used (typically the deepest completed iteration).

```c
void lazy_smp_worker(Position *root, int thread_id, int num_threads) {
    // Each thread runs its own iterative deepening
    for (int depth = 1; ; depth++) {
        // Optional: skip some depths to de-synchronize
        if (depth % num_threads != thread_id % min(num_threads, 4)) {
            // Still search, but with slight perturbation
        }

        int score = pvs(root, depth, -INFINITY, +INFINITY, 0, thread_id);

        // Atomically update the best result
        update_best_result(thread_id, depth, score);
    }
}
```

The threads are completely independent except for two shared data structures:

1. *The Transposition Table*: All threads read and write the same TT. This is the primary mechanism of information sharing. When thread A discovers a good move during its search, it stores the result in the TT. Thread B, searching a related position, finds the entry and uses it to improve move ordering or cause cutoffs.

2. *The Best Result*: A small shared structure (or atomic variables) that tracks the best score and PV from each thread. The UCI output thread reads this to report the best move.

==== Depth Skipping: De-Synchronizing Threads

If all threads searched at exactly the same depth, they would tend to follow similar paths through the tree, duplicating work. *Depth skipping* is the most common de-synchronization technique: each thread searches at a slightly different depth, so they reach different parts of the tree at different times.

```c
int thread_depth = base_depth + (thread_id % 4);  // thread 0: depth D, thread 1: D+1, etc.
```

Stockfish uses a more sophisticated scheme where each thread's depth offset varies with the iteration number and thread ID to minimize systematic overlap. Some threads search deeper, others shallower, ensuring all parts of the tree are explored.

==== Lock-Free Transposition Table Access

The TT is the only shared data structure and the only synchronization point. To avoid locking overhead (which would serialize all threads), engines use *lock-free* or *lockless* TT implementations based on atomic operations.

The standard approach uses a *bucket* organization: the TT is an array of buckets, each containing 2-4 entries. When storing a new entry, the thread chooses the "worst" existing entry in the bucket (shallowest depth, oldest) and overwrites it using an atomic compare-and-swap or a simple atomic store.

```c
typedef struct {
    uint64_t hash;      // 16 bits of the full hash (used for matching)
    int16_t  score;
    uint16_t move;
    int8_t   depth;
    uint8_t  flag;      // TT_EXACT, TT_ALPHA, TT_BETA
} TTEntry;

typedef struct {
    TTEntry entries[4];  // 4 entries per bucket
} TTBucket;

TTBucket tt[HASH_SIZE];  // global shared array

void tt_store(uint64_t hash, int score, int depth, Move move, int flag) {
    TTBucket *bucket = &tt[hash & (HASH_SIZE - 1)];
    // Find the worst entry to replace
    int worst_index = 0;
    int worst_score = depth;  // prefer to keep deep entries
    for (int i = 0; i < 4; i++) {
        if (bucket->entries[i].depth < worst_score) {
            worst_score = bucket->entries[i].depth;
            worst_index = i;
        }
    }
    // Store using atomic write (no lock needed on x86 for aligned 64-bit writes)
    TTEntry new_entry = { (uint16_t)(hash >> 48), (int16_t)score, (uint16_t)move, depth, flag };
    bucket->entries[worst_index] = new_entry;  // x86: aligned 64-bit store is atomic
}

TTEntry *tt_probe(uint64_t hash) {
    TTBucket *bucket = &tt[hash & (HASH_SIZE - 1)];
    uint16_t key = (uint16_t)(hash >> 48);
    for (int i = 0; i < 4; i++) {
        if (bucket->entries[i].hash == key) {
            return &bucket->entries[i];  // found
        }
    }
    return NULL;
}
```

On x86/x64 architectures, aligned 64-bit reads and writes are atomic by default (no `LOCK` prefix needed), making this TT implementation lock-free. On ARM and other architectures, explicit memory barriers or atomic types may be required.

==== Thread-Local Data and NUMA Awareness

While the TT is shared, most other search data is thread-local:

- Thread-local move lists (stack-allocated, no sharing).
- Thread-local history tables (move ordering heuristics learned during search).
- Thread-local killer move tables.
- Thread-local counter-move tables.

This minimizes contention. Some engines go further and implement *NUMA-aware* memory allocation: on multi-socket systems, each thread's local data is allocated on the NUMA node closest to that thread's CPU, reducing memory access latency.

```c
// Thread-local search state
typedef struct {
    int thread_id;
    Position root_position;

    // Local heuristics (not shared)
    int history[PIECE_NB][SQUARE_NB];  // history heuristic
    Move killers[MAX_PLY][2];          // killer moves
    Move counter_moves[PIECE_NB][SQUARE_NB];  // counter-move heuristic

    // Search stack (one entry per ply)
    SearchStack stack[MAX_PLY + 4];
} ThreadState;

ThreadState threads[MAX_THREADS];  // NUMA-aware allocation
```

=== Historical Parallel Search Algorithms

Before Lazy SMP became dominant, several more structured parallel search algorithms were developed. While they are largely obsolete for chess, understanding them provides insight into the parallel search problem and why Lazy SMP ultimately won.

==== YBWC: Young Brothers Wait Concept

Developed by Rainer Feldmann in the 1990s (based on work by Carl Ebeling), YBWC was the dominant parallel alpha-beta algorithm for over a decade. The algorithm is:

1. A "master" thread controls the search at the root.
2. When the master finds a node with multiple unsearched child moves, it can "split" the node: assign some child subtrees to idle "helper" threads.
3. The critical restriction: the *first move* at any node must be fully searched before any helper can be assigned to sibling moves. This is the "Young Brothers Wait" concept—the first child (the eldest) must complete before younger siblings get help.
4. The master waits for all helpers to finish, combines results, and continues.

YBWC ensures that the sequential alpha-beta information (the bound tightened by the first move) is available before parallel work begins. This avoids most of the speculative work that would be wasted if threads searched moves before knowing the alpha bound.

However, YBWC suffers from:
- *Synchronization overhead*: The master must manage task queues, assign work, and wait for completion.
- *Idle threads*: Threads can be idle waiting for the first move to complete.
- *Poor scaling*: As N increases, the fraction of time threads spend waiting grows.

Despite these limitations, YBWC achieved reasonable scaling up to ~16 threads and powered engines like Crafty for many years.

==== DTS: Dynamic Tree Splitting

DTS (Dynamic Tree Splitting), developed by Robert Hyatt for Crafty, extended YBWC with dynamic task management:

- Work is distributed via a shared task queue.
- Threads can "steal" tasks from each other when idle.
- The splitting depth is dynamically chosen based on expected sub-tree size (shallow splits risk high overhead; deep splits risk idle threads).
- Split points can be "recalled" if a thread finds a cutoff that makes the parallel work unnecessary.

DTS improved on YBWC but added implementation complexity. The overhead of task queue management limited its scaling to ~32 threads.

==== ABDADA

ABDADA (Alpha-Beta Distribution with Asynchronous Dynamic Allocation), proposed by Jean-Christophe Weill, is in some ways a precursor to Lazy SMP. The key idea: threads search the full tree simultaneously and share information through the TT, with no explicit task division. However, ABDADA uses a "pseudo-lock" mechanism in the TT to prevent two threads from searching the same node simultaneously:

- When a thread enters a node, it writes a "busy" flag in the TT for that position.
- Other threads that encounter the same position see the busy flag and skip it (or search alternative moves).
- When the thread finishes, it writes the result and clears the busy flag.

ABDADA reduces redundant work compared to pure Lazy SMP, but the TT locking adds overhead. Modern Lazy SMP accepts some redundant work in exchange for zero synchronization cost, which empirically wins at high thread counts.

=== Advanced Lazy SMP Optimizations

Modern engines incorporate several refinements that improve Lazy SMP scaling:

==== Shared Hash Table with Aging

The TT can fill up quickly with many threads storing entries. *Aging* ensures that old entries from previous searches don't crowd out current entries:

```c
void tt_new_search() {
    // Increment the "generation" counter
    generation++;
    // Entries with an older generation are preferred for replacement
}
```

==== Thread Voting at the Root

When the search completes, how is the best move determined? Each thread may have a different opinion (PV) based on what it explored. The simplest approach: pick the thread with the deepest completed depth. But this can be noisy.

A more robust approach is *thread voting*: each thread "votes" for the move it believes is best (based on its root search). The move with the most votes is selected. If there is a tie, the move with the highest average score is chosen.

```c
Move thread_vote(int num_threads) {
    int votes[MAX_MOVES] = {0};

    for (int t = 0; t < num_threads; t++) {
        Move best_move = threads[t].root_best_move;
        if (best_move != NO_MOVE) {
            votes[best_move]++;
        }
    }

    // Select move with most votes; tiebreak by score
    Move best = NO_MOVE;
    int best_votes = -1;
    for (int m = 0; m < root_move_count; m++) {
        Move move = root_moves[m];
        if (votes[move] > best_votes) {
            best_votes = votes[move];
            best = move;
        }
    }
    return best;
}
```

==== Auxiliary Tables (Pawn Hash, Material Hash)

In addition to the main TT, engines often maintain auxiliary hash tables that are also shared between threads:

- *Pawn hash table*: Caches pawn structure evaluation (passed pawns, doubled pawns, pawn shields). Pawn structure changes slowly, so a dedicated cache avoids recomputing this expensive evaluation.
- *Material hash table*: Caches the material balance evaluation for each unique combination of material. Since material changes only on captures and promotions, this is highly cacheable.

These tables use the same lock-free bucket approach as the main TT and can be allocated per-NUMA-node for better scaling.

=== NUMA Considerations

On multi-socket systems (e.g., dual-socket servers with two physical CPU packages), memory access is non-uniform: accessing memory attached to the "local" NUMA node is faster than accessing memory on a "remote" node. A naive single shared TT can become a bottleneck as threads from different sockets contend for the same memory.

Solutions:

1. *NUMA-aware TT allocation*: Allocate the TT using `numa_alloc_onnode` or `libnuma`, placing TT pages on both NUMA nodes in an interleaved pattern.

2. *Per-NUMA TT segments*: Split the TT into one segment per NUMA node. Threads on each node preferentially access their local segment. A hashing scheme can bias threads toward their local segment.

3. *Thread pinning*: Bind each thread to a specific CPU core using `pthread_setaffinity_np` (Linux) or `SetThreadAffinityMask` (Windows). This prevents the OS scheduler from moving threads between cores, which would invalidate cached data.

```c
void pin_thread_to_core(int thread_id, int core_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
}
```

=== Pondering: Thinking on Opponent's Time

All modern engines support *pondering*: searching during the opponent's turn, anticipating their likely move. This effectively doubles the search time in many positions.

```c
void ponder_loop(Position *pos, Move expected_move) {
    // The GUI tells us what move the opponent is pondering about
    if (make_move(pos, expected_move)) {
        // Search this position while the opponent thinks
        iterative_deepening(pos, INFINITE_TIME, thread_id);
    }
    // When opponent moves, stop search and start the real search
}
```

Pondering works best when the opponent plays predictably. Against unpredictable opponents or in time scrambles, pondering can waste computation and overheat the CPU. Some engines disable pondering when the clock is very low.

*Ponderhit*: If the opponent plays the expected move, the engine has already searched that position and can move instantly. The GUI sends `ponderhit` to tell the engine that the pondered move was played, and the engine switches the pondering search into a normal search.

=== Amdahl's Law and Chess Search

Amdahl's Law states that the maximum speedup of a parallel computation is limited by its sequential portion:

`S(N) <= 1 / (s + (1-s)/N)`

where `s` is the fraction of the computation that is inherently sequential. As `N` approaches infinity, `S(N)` approaches `1/s`.

In a chess engine, what is sequential?

- *Root move ordering*: The root moves must be sorted, and the first iteration (depth 1) is inherently sequential.
- *TT probe at the root*: Each root move probes the TT, which can be sequentialized by contention.
- *UCI communication*: The UI thread that reads stdin and writes stdout is sequential.
- *Time management*: Deciding when to stop requires global state.

The sequential fraction `s` is typically around 2-5% in modern engines, which imposes a theoretical maximum speedup of 20-50x. This means that even with infinite cores, a chess engine cannot achieve more than ~50x speedup over a single core. In practice, the combination of search overhead and sequential bottlenecks limits useful scaling to about 16-32 threads for current engines.

=== Performance Testing Parallel Search

Testing parallel search is notoriously difficult because of non-determinism. Two runs with the same number of threads and time control may produce different moves. The standard approach is *statistical testing*:

1. Run N engines (all identical, same parallel search) against each other for thousands of games.
2. Measure the ELO gain for each doubling of thread count.
3. Typical result: +50 ELO for 2→4 threads, +30 ELO for 4→8 threads, +15 ELO for 8→16 threads. Diminishing returns are the norm.

=== Code Examples: Lazy SMP Worker

==== C Implementation

```c
#include <pthread.h>
#include <stdatomic.h>

typedef struct {
    int thread_id;
    int num_threads;
    Position root_position;
    BoardState root_state;
    atomic_bool *stop;
    atomic_int *best_move;
    atomic_int *best_score;
    atomic_int *best_depth;
    TranspositionTable *tt;
} ThreadArgs;

void *lazy_smp_worker(void *arg) {
    ThreadArgs *args = (ThreadArgs *)arg;
    Position pos = args->root_position;

    // Pin thread to core for better cache locality
    pin_thread_to_core(args->thread_id, args->thread_id);

    // Thread-local search state
    SearchState state;
    init_search_state(&state, args->thread_id);

    // Iterative deepening
    for (int depth = 1; !atomic_load(args->stop); depth++) {
        // Depth skipping: each thread varies its depth slightly
        int my_depth = depth + (args->thread_id % 4);

        // Aspiration window from previous iteration
        int alpha = -INFINITY;
        int beta  = +INFINITY;
        int prev_score = atomic_load(args->best_score);

        if (depth >= 4) {
            alpha = prev_score - 50;
            beta  = prev_score + 50;
        }

        int score = pvs(&pos, my_depth, alpha, beta, 0, &state, args->tt, args->stop);

        // Update best result atomically
        if (!atomic_load(args->stop)) {
            atomic_store(args->best_score, score);
            atomic_store(args->best_depth, my_depth);
        }
    }
    return NULL;
}

void start_parallel_search(Position *root, int num_threads, int time_ms) {
    pthread_t threads[MAX_THREADS];
    ThreadArgs args[MAX_THREADS];
    atomic_bool stop = false;
    atomic_int best_move = NO_MOVE;
    atomic_int best_score = 0;
    atomic_int best_depth = 0;

    TranspositionTable tt;
    tt_init(&tt, 256);  // 256 MB TT

    // Spawn worker threads
    for (int i = 0; i < num_threads; i++) {
        args[i] = (ThreadArgs){
            .thread_id = i,
            .num_threads = num_threads,
            .root_position = *root,
            .stop = &stop,
            .best_move = &best_move,
            .best_score = &best_score,
            .best_depth = &best_depth,
            .tt = &tt,
        };
        pthread_create(&threads[i], NULL, lazy_smp_worker, &args[i]);
    }

    // Main thread manages time
    sleep_ms(time_ms);
    atomic_store(&stop, true);

    // Wait for all threads
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }

    printf("bestmove %s\n", square_to_string(best_move));
}
```

==== C++ Implementation

```cpp
#include <thread>
#include <atomic>
#include <vector>

class SearchManager {
public:
    SearchManager(Position& root, int threads, int time_ms)
        : root_(root), num_threads_(threads), stop_(false) {}

    Move search() {
        std::vector<std::thread> workers;
        workers.reserve(num_threads_);

        for (int i = 0; i < num_threads_; i++) {
            workers.emplace_back([this, i]() {
                worker(i);
            });
        }

        // Time management
        std::this_thread::sleep_for(std::chrono::milliseconds(time_ms_));
        stop_.store(true, std::memory_order_release);

        for (auto& t : workers) t.join();

        return best_move_.load(std::memory_order_acquire);
    }

private:
    void worker(int thread_id) {
        Position pos = root_;
        SearchState state(thread_id);

        for (int depth = 1; !stop_.load(std::memory_order_acquire); depth++) {
            int my_depth = depth + (thread_id % 4);
            int alpha = -MATE_SCORE, beta = MATE_SCORE;

            int score = pvs(pos, my_depth, alpha, beta, 0, state, tt_, stop_);

            if (!stop_.load(std::memory_order_acquire)) {
                best_score_.store(score, std::memory_order_release);
                best_depth_.store(my_depth, std::memory_order_release);
            }
        }
    }

    Position& root_;
    int num_threads_;
    int time_ms_;
    std::atomic<bool> stop_;
    std::atomic<Move> best_move_;
    std::atomic<int> best_score_;
    std::atomic<int> best_depth_;
    TranspositionTable tt_;
};
```

==== Rust Implementation

```rust
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;

pub struct ParallelSearch {
    tt: Arc<TranspositionTable>,
    stop: Arc<AtomicBool>,
    best_score: Arc<AtomicI32>,
    best_depth: Arc<AtomicI32>,
}

impl ParallelSearch {
    pub fn search(&self, root: &Position, num_threads: usize, time_ms: u64) -> Move {
        let mut handles = vec![];

        for thread_id in 0..num_threads {
            let root = root.clone();
            let tt = Arc::clone(&self.tt);
            let stop = Arc::clone(&self.stop);
            let best_score = Arc::clone(&self.best_score);
            let best_depth = Arc::clone(&self.best_depth);

            handles.push(thread::spawn(move || {
                let mut pos = root;
                let mut state = SearchState::new(thread_id);

                for depth in 1.. {
                    if stop.load(Ordering::Acquire) { break; }
                    let my_depth = depth + (thread_id as i32 % 4);

                    let score = pvs(
                        &mut pos, my_depth, -MATE_SCORE, MATE_SCORE, 0,
                        &mut state, &tt, &stop
                    );

                    if !stop.load(Ordering::Acquire) {
                        best_score.store(score, Ordering::Release);
                        best_depth.store(my_depth, Ordering::Release);
                    }
                }
            }));
        }

        // Time management
        thread::sleep(std::time::Duration::from_millis(time_ms));
        self.stop.store(true, Ordering::Release);

        for h in handles {
            h.join().unwrap();
        }

        // Return best move (from TT or root search)
        self.get_best_move()
    }
}
```

=== Summary

Parallel search is essential for modern chess engines, and Lazy SMP has emerged as the clear winner due to its simplicity and scalability:

- *Lazy SMP*: All threads search independently, sharing only the TT. No explicit work division. Depth skipping de-synchronizes threads.
- *Lock-free TT*: Atomic writes and reads on aligned data structures eliminate locking overhead.
- *Scaling*: 8 threads typically achieve ~6x speedup; 16 threads ~11x; 32 threads ~18x. Beyond 32 threads, Amdahl's Law limits further gains.
- *Thread-local data*: History tables, killer moves, and state are per-thread to minimize contention.
- *NUMA awareness*: On multi-socket systems, NUMA-aware allocation of the TT and thread pinning improve scaling.

The combination of parallel search with the other techniques covered in this part—efficient evaluation, NNUE networks, and endgame tablebases—is what enables engines to search 100+ million nodes per second and play at superhuman strength.
