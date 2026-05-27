== Stockfish Deep Dive

Stockfish is the strongest chess engine in the world and has been, with few interruptions, since approximately 2013. It is the reference implementation against which all other engines are measured. Understanding Stockfish is understanding the state of the art in chess engine engineering. This chapter traces Stockfish's evolution, examines its key architectural innovations, and extracts lessons for engine developers.

=== Stockfish's Place in Chess Engine History

Stockfish began in 2008 as a fork of Glaurung, an engine by Tord Romstad. The early Stockfish (versions 1-4) was a strong but relatively conventional engine: it used classical evaluation with hand-tuned weights, alpha-beta search with the standard enhancements of the time (PVS, null-move pruning, LMR), and a straightforward UCI implementation.

By 2013 (Stockfish 4), it had become the strongest open-source engine, surpassing Komodo in the TCEC. From 2014-2020, Stockfish maintained its dominance through incremental improvements: better evaluation terms, smarter search reductions, and most importantly, its revolutionary testing framework (Fishtest).

The critical turning point came in 2020 with Stockfish 12, which integrated NNUE (Efficiently Updatable Neural Networks) into its evaluation—a technique originally developed for Shogi engines. This single change, combined with Stockfish's world-class search, vaulted it to an unprecedented Elo lead of 70+ points over its nearest competitor.

=== Architecture Overview

The modern Stockfish architecture is a masterclass in separation of concerns:

```text
┌─────────────────────────────────────────────────────────┐
│                     UCI Interface                        │
│  (parses commands, manages time, outputs bestmove)       │
├─────────────────────────────────────────────────────────┤
│                   Thread Management                      │
│  (ThreadPool, worker threads, lazy SMP)                  │
├─────────────────────────────────────────────────────────┤
│                    Search                                 │
│  (iterative deepening, PVS, LMR, null move, extensions)  │
├──────────────┬──────────────────────┬────────────────────┤
│ Move Gen     │  Transposition Table │  Evaluation (NNUE) │
│ (bitboards,  │  (hash table, 16     │  (neural network,  │
│  magic/PEXT) │   bytes per entry)   │   incremental)     │
├──────────────┴──────────────────────┴────────────────────┤
│                   Position                               │
│  (bitboard representation, make/unmake, zobrist hash)    │
└─────────────────────────────────────────────────────────┘
```

Each component is optimized to a degree that borders on obsession. The TT entry is exactly 16 bytes to fit two per 32-byte bucket (a single L1 cache line on most CPUs). The NNUE inference code is hand-tuned for SSE2, SSSE3, AVX2, AVX-512, and increasingly for ARM NEON on Apple Silicon.

==== Key Source Files

```text
Stockfish Source Layout (conceptual, ~60k lines)
───────────────────────────────────────────────
bitboard.h/cpp     Bitboard utilities, magic tables, attack generation
position.h/cpp     Position representation, make/unmake, FEN
movegen.h/cpp      Move generation (all piece types, perft)
search.h/cpp       Search algorithm (PVS, LMR, extensions, quiescence)
evaluate.h/cpp     NNUE evaluation interface
nnue/              NNUE implementation (architecture, inference, training tools)
  nnue_architecture.h   Network layer definitions
  nnue_accumulator.h    Incremental update accumulator
  nnue_feature_transformer.h  Input feature encoding
tt.h/cpp           Transposition table
thread.h/cpp       Thread management, ThreadPool
uci.h/cpp          UCI protocol implementation
timeman.h/cpp      Time management
```

=== Evaluation Evolution

==== Classical Era (Stockfish 1-11)

The classical evaluation was a masterpiece of incremental refinement. By Stockfish 11, it consisted of approximately 25-30 distinct evaluation terms, each carefully tuned:

```text
Material (piece values, imbalance tables)
  ├── Piece-Square Tables (PST): bonus for each piece on each square
  ├── Pawn Structure: isolated, doubled, backward, connected, passed pawns
  ├── Mobility: number of legal moves per piece type
  ├── King Safety: pawn shield, open files near king, attacker count
  ├── Threats: hanging pieces, attacked pieces, push threats
  ├── Passed Pawns: supported, blocked, unstoppable
  ├── Space: control of center and opponent's territory
  ├── Initiative: compensation for material deficit
  └── Endgame Special Cases: KBNvK, KQvKP, etc.
```

Each term was tuned using a combination of Texel's tuning method (logistic regression on positions from self-play games with known outcomes) and SPSA (Simultaneous Perturbation Stochastic Approximation) for non-differentiable terms.

The classical evaluation topped out at roughly 3,500 Elo (on the CCRL scale). It was a remarkable achievement in hand-crafted evaluation, but it had reached a plateau: each new term or refinement added diminishing returns (1-3 Elo, with dozens of failed attempts per successful one).

==== NNUE Revolution (Stockfish 12-17)

Stockfish 12 (September 2020) introduced NNUE evaluation while keeping the search essentially unchanged. The NNUE architecture was adapted from computer Shogi, where it had proven enormously successful.

The Stockfish NNUE is a feed-forward neural network with a crucial property: it is *efficiently updatable*. When a move is made, only a small fraction of the input features change (at most 4 squares: the from and to squares of the moving piece, plus the capture square and any castling rook). The NNUE accumulator exploits this sparsity to update the network in O(1) time per move, rather than recomputing the entire first layer from scratch.

The architecture (simplified):

```text
Input Features (41,024 binary features)
  │
  ├── Feature Transformer (41,024 → 512, two halves: current + opponent)
  │     Weight: int16, Bias: int16
  │
  ├── HalfKP Encoder (king_square × piece_square × piece_type)
  │     each feature = (our_king_sq, piece_sq, piece_type, color)
  │
  ├── Accumulator (512 int16 values, incrementally updated)
  │     accumulator[perspective] += weights[changed_features]
  │     accumulator[perspective] -= weights[removed_features]
  │
  ├── L1 Normalization (squeeze to int8)
  ├── FC Layer 1 (512 → 32, ClippedReLU)
  ├── FC Layer 2 (32 → 32, ClippedReLU) 
  └── Output (32 → 1, int32 → centipawn score)
```

The "HalfKP" encoding represents a feature as the combination of the king position (one half, hence "Half") and the position/type/color of another piece. There are 64 king squares × 64 piece squares × 5 piece types × 2 colors = 40,960 possible features. This encoding captures the relationship between the king and every other piece—the single most important positional signal in chess.

*Stockfish 13* (2021): Improved NNUE training, introducing hybrid evaluation (classical + NNUE blended for certain endgame positions where the NNUE alone was unreliable). The network grew slightly larger (512 → 32 → 32 → 1).

*Stockfish 14* (2021): Replaced the classical evaluation entirely. The NNUE became the sole evaluation function. This simplified the codebase dramatically (removing ~1,500 lines of hand-tuned evaluation) while gaining 15-20 Elo.

*Stockfish 15* (2022): Introduced a *dual network* architecture: separate networks for positions with few pieces (endgame) vs. many pieces (middlegame). The engine selected the appropriate network dynamically based on the material count. This addressed the NNUE's tendency to misevaluate unconventional endgames.

*Stockfish 16* (2023): Refined the NNUE architecture further (feature transformer improvements, better activation functions). The training data expanded to billions of positions.

*Stockfish 16.1 and 17* (2023-2024): Continued refinement. The focus shifted from architectural innovation to training methodology improvements (better data filtering, WDL (Win-Draw-Loss) score modeling, and more sophisticated training targets).

=== Search Innovations

Stockfish's search is the primary differentiator between it and other NNUE engines (many of which use the same or similar network architectures). The key Stockfish-specific search innovations:

==== Singular Extensions

Singular extension is a technique that identifies *singular* moves—moves that are significantly better than all alternatives—and extends the search depth for them. A move is singular if, after searching all other moves with a reduced depth or reduced window, the original move's score is significantly better than any alternative.

The implementation is complex because identifying a singular move requires excluding that move from the search, which can be expensive. Stockfish uses TT-based exclusion search: it probes the TT to see if a move was singular in a previous search at a lower depth, and only performs the full exclusion test at PV nodes.

```cpp
// Simplified singular extension logic
if (depth >= 8 && move == ttMove && !excludedMove
    && abs(ttValue) < MATE_IN_MAX_PLY) {
    // Exclusion search: search all other moves with reduced depth
    Value singularBeta = ttValue - 2 * depth;
    int singularDepth = (depth - 1) / 2;
    
    excludedMove = move;
    value = search(pos, singularDepth, singularBeta - 1, singularBeta, ...);
    excludedMove = MOVE_NONE;
    
    if (value < singularBeta) {
        // Move is singular! Extend it
        extension = 1;
    }
}
```

Singular extensions are expensive (the exclusion search costs additional nodes), but they are also the single most important search innovation in Stockfish's history, responsible for 15-20 Elo compared to non-singular search.

==== Multi-Cut Pruning

Multi-cut (mentioned in Chapter 6) was pioneered by Stockfish. When multiple moves at a non-PV node fail low at reduced depth, the node is likely an All node, and the remaining moves can be skipped:

```cpp
if (!PvNode && depth >= 5 && abs(beta) < MATE_IN_MAX_PLY) {
    int count = 0;
    for (int i = 0; i < moveCount; i++) {
        value = -search(pos, depth - 4, -beta, -beta + 1, ...);
        if (value >= beta) return value;  // not an All node
        if (++count >= 6) return beta - 1;  // multi-cut
    }
}
```

==== ProbCut

ProbCut uses a statistical model: if a move's reduced-depth search score suggests that a full-depth search would exceed beta, we can prune the full-depth search and immediately return a fail-high. The condition is:

```cpp
if (depth >= 5 && abs(beta) < MATE_IN_MAX_PLY) {
    int rbeta = min(beta + 200, VALUE_INFINITE);
    int probeDepth = depth - 4;
    value = -search(pos, probeDepth, -(rbeta), -(rbeta - 1), ...);
    
    if (value >= rbeta) {
        // High prob-cut: skip full-depth search
        return beta;
    }
}
```

The threshold (200 centipawns) was determined empirically. Lower thresholds increase pruning but risk errors; higher thresholds are safer but prune less.

==== Counter-Move and Follow-Up History

Stockfish maintains two levels of move history:

1. **Counter-Move History**: For the opponent's last move, which of our moves has historically been a good response? Index: `[opponent_last_move][our_candidate_move]`.

2. **Follow-Up History**: For *our* last two moves (a two-move pattern), which continuation is best? Index: `[our_second_last_move][our_candidate_move]`.

These histories are continuously updated during search: when a move causes a beta cutoff, its history score is increased (and the scores of other moves for the same context are decreased). This creates a self-reinforcing move ordering system that learns the tactical patterns of the current position during the search itself.

```cpp
// History update on beta cutoff
int bonus = min(depth * depth, 400);
history[move][depth] += bonus - history[move][depth] * bonus / 324;
counter_history[prevMove][move] += bonus - counter_history[prevMove][move] * bonus / 324;
```

The formula `new = old + bonus - old * bonus / 324` is a common weighted update (324 = maximum history value) that asymptotically approaches a ceiling, preventing integer overflow.

==== Lazy SMP (Shared Memory Parallelization)

Stockfish's parallel search (Chapter 14) uses a technique called Lazy SMP (Symmetric Multi-Processing). Unlike the traditional YBW (Young Brothers Wait) or DTS (Dynamic Tree Splitting) algorithms, Lazy SMP is almost embarrassingly simple:

1. All threads run the *same* iterative deepening search independently.
2. Threads share the transposition table (hence "Shared Memory").
3. No explicit work distribution, no synchronization beyond the TT.
4. Threads communicate only through the TT: when Thread A stores a search result for a position that Thread B hasn't reached yet, Thread B benefits from Thread A's work.

The "Lazy" descriptor is slightly misleading: Lazy SMP is not lazy in the sense of being suboptimal. It's "lazy" in the sense of being algorithmically simple (no explicit work distribution), but its empirical performance is excellent, achieving near-linear speedup to 8-16 threads and ~0.7 efficiency at 64-128 threads.

The key insight: a shared transposition table IS an implicit communication channel. Different threads naturally explore different parts of the tree because their search orders diverge slightly (different random seeds, different time allocations). When they converge on the same position, the TT transfers the results.

=== Testing Infrastructure: Fishtest

Fishtest is arguably Stockfish's greatest innovation—not a search or evaluation technique, but an *organizational* one. It enables:

- Distributed testing across hundreds of volunteer machines.
- Automated SPRT-based decision making.
- Git integration: developers submit patches as pull requests; Fishtest automatically compiles and tests them.
- Queue management: multiple tests run concurrently, with priorities based on developer reputation and test significance.

A Fishtest worker runs:

```bash
#!/bin/bash
# Simplified Fishtest worker loop
while true; do
    # Fetch task from server
    TASK=$(curl -s "https://tests.stockfishchess.org/api/request_task" \
           -d "worker_name=$HOSTNAME&cores=$(nproc)")
    
    # Extract parameters
    TEST_REPO=$(echo $TASK | jq -r '.test_repo')
    BRANCH=$(echo $TASK | jq -r '.branch')
    NPM=$(echo $TASK | jq -r '.num_games')  # games per chunk
    
    # Clone, build both versions
    git clone --depth 1 -b master $TEST_REPO sf_base
    git clone --depth 1 -b $BRANCH $TEST_REPO sf_test
    cd sf_base/src && make -j$(nproc) build && cd ../..
    cd sf_test/src && make -j$(nproc) build && cd ../..
    
    # Run games
    cutechess-cli \
        -engine name=Base cmd=sf_base/stockfish \
        -engine name=Test cmd=sf_test/stockfish \
        -each tc=10+0.1 \
        -games $NPM \
        -concurrency $(nproc) \
        -openings file=8moves_v3.pgn \
        -sprt elo0=0 elo1=3 alpha=0.05 beta=0.05 \
        -pgnout games.pgn
    
    # Upload results
    curl -s "https://tests.stockfishchess.org/api/upload_results" \
         -F "pgn=@games.pgn" -F "worker=$HOSTNAME"
done
```

This simple loop, running on thousands of volunteer cores worldwide, processes 100-200 million positions per day—the computational equivalent of a small supercomputer, dedicated entirely to chess engine improvement.

=== Key Stockfish Innovations by Version

```text
Version  Year  Key Innovation                         Elo Gain (cumulative)
────────  ────  ────────────────────────────────────   ─────────────────────
SF 5      2013  Fishtest v1, SPSA tuning, improved      ~3200 → 3250
                 passed pawn eval
SF 6      2014  Asymmetric king safety, better LMR      ~3250 → 3280
SF 7      2016  Syzygy tablebase support, singular      ~3280 → 3340
                 extensions
SF 8      2016  Improved time management, contempt      ~3340 → 3380
SF 9      2017  ProbCut v2, improved move ordering      ~3380 → 3430
SF 10     2017  Better singular extensions, counter-    ~3430 → 3480
                 move history
SF 11     2020  Classical eval refinements (final)      ~3480 → 3540
SF 12     2020  NNUE evaluation (revolutionary)         ~3540 → 3630 (+90!)
SF 13     2021  Improved NNUE training, hybrid eval     ~3630 → 3670
SF 14     2021  Pure NNUE (classical removed)           ~3670 → 3720
SF 15     2022  Dual network (middlegame/endgame)       ~3720 → 3760
SF 16     2023  NNUE arch improvements, better data     ~3760 → 3790
SF 17     2024  Training methodology, WDL scoring       ~3790 → 3820*
─────────────────────────────────────────────────────────────────────
* CCRL 40/15 ratings (approximate, for illustration)
```

The jump at Stockfish 12 (+90 Elo) is the single largest version-to-version improvement in chess engine history. It validated a decade of neural network research in computer chess and permanently changed the competitive landscape.

=== Lessons for Engine Developers

1. **Testing is the engine that drives improvements**. Stockfish's dominance is as much about its testing infrastructure as its code. A developer who writes brilliant code but cannot test it properly will never catch Stockfish. Invest in testing infrastructure early.

2. **Good search + good eval > great search + mediocre eval > mediocre search + great eval**. Stockfish 12 proved that a world-class search with a neural evaluation is greater than the sum of its parts. The NNUE alone was not revolutionary—it was NNUE *plus* Stockfish's search that created the +90 Elo jump.

3. **Simplicity scales**. Lazy SMP, the simple SPRT-based git workflow, the 16-byte TT entry—Stockfish's best ideas are the simplest ones. Avoid complexity; it rarely pays off.

4. **Incrementalism works**. Stockfish improved 600+ Elo over a decade through thousands of 1-3 Elo improvements, each rigorously tested. There was no single "magic bullet" (except NNUE). Patience and methodology trump brilliance.

5. **Open source amplifies innovation**. Stockfish benefits from a global community of contributors, each with their own ideas and hardware. An engine developed in private cannot match this combinatorial creativity.

6. **Specialize at the right time**. Stockfish was a generalist engine for 12 years before NNUE forced specialization. Don't prematurely optimize for specific architectures or techniques—but when the right one appears, commit fully.
