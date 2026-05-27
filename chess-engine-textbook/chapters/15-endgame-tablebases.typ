== Endgame Tablebases: Perfect Play for the Endgame

Endgame tablebases are the closest thing to perfection in chess computing. A tablebase is a database that stores the exact outcome of every possible position with a limited number of pieces—win, draw, or loss under optimal play. For any tablebase position, the engine can play perfectly: it need not search, evaluate, or guess. It simply consults the tablebase and makes the move that leads to the quickest win or the most stubborn draw.

This chapter covers the Syzygy tablebase format (the modern standard), how tablebases are generated through retrograde analysis, how engines probe them during search, and the practical considerations of storing and accessing petabytes-level data.

=== What Are Endgame Tablebases?

An endgame tablebase is a lookup table indexed by the arrangement of ≤N pieces on the chess board. For each position, it stores:

1. *WDL (Win/Draw/Loss)*: The theoretical outcome. For the side to move: WIN (can force checkmate), DRAW (can force a draw, or opponent can force a draw), LOSS (opponent can force checkmate).

2. *DTZ (Distance to Zero)*: The number of half-moves until a zeroing move (a capture or pawn push) that transitions into a simpler, already-solved endgame. DTZ guides optimal play toward the fastest win (minimizing DTZ) or the most stubborn defense (maximizing DTZ).

Tablebases exist for up to 7 pieces (including kings) on the board. An "N-piece tablebase" covers all positions with exactly N pieces (e.g., a 6-piece tablebase covers KQ vs KRP, KR vs KBP, KBB vs KN, etc.).

==== Historical Development

- *1980s*: Ken Thompson generated the first 4-piece tablebases (e.g., KQ vs K, KR vs K) using a Cray supercomputer. These were stored on magnetic tape.
- *1990s*: Lewis Stiller extended to 5 pieces. Eugene Nalimov created the widely-used Nalimov tablebases with a compressed format and a DTM (Distance to Mate) metric.
- *2000s*: 6-piece Nalimov tablebases were generated, totaling ~1.2 TB.
- *2010s*: Ronald de Man created the Syzygy tablebases, which use a WDL/DTZ split and much better compression. The 6-piece Syzygy bases are ~150 GB.
- *2018*: The Lomonosov 7-piece tablebases were generated at Moscow State University, consuming ~140 TB.
- *2020s*: 7-piece Syzygy tablebases: WDL files ~18 TB, DTZ files ~80 TB.

Engines today universally use Syzygy tablebases. The older Nalimov and Gaviota formats are historical footnotes, though some engines still support them for backward compatibility.

=== The Syzygy Tablebase Format

Syzygy (named after the astronomical term for alignment, reflecting the alignment of pieces into perfect play) is the state-of-the-art format used by Stockfish, Leela Chess Zero, and all major engines. It separates WDL and DTZ into different files:

==== WDL Files

WDL files store win/draw/loss information per position. The encoding uses 2 bits per position:

- `0b00` = LOSS (cursed win in some sub-formats, where the win requires more than 50 moves without captures/pawn moves)
- `0b01` = BLESSED LOSS (a win that requires more than 50 moves—opponent can claim a draw under 50-move rule)
- `0b10` = DRAW
- `0b11` = WIN

With 2 bits per position and typically 32-64 positions packed per byte (after symmetry reduction and run-length encoding), WDL files are remarkably compact.

==== DTZ Files

DTZ files store the distance to a zeroing move (a capture or pawn push) for the winning side, or the distance for the losing side to hold a draw. The DTZ value is stored in 1, 2, or 4 bytes depending on the table size.

For winning positions: DTZ is the number of half-moves until a zeroing move that leads to a simpler endgame. The winning side wants to minimize DTZ (win quickly). For losing positions: DTZ is the number of half-moves the loser can hold out before the winner makes a zeroing move. The losing side wants to maximize DTZ (delay the loss as long as possible).

==== Compression Techniques

Syzygy achieves its compact size through multiple compression layers:

1. *Symmetry reduction*: Positions that are mirror images (left-right, or color-swapped) map to the same table entry. This reduces the search space by up to 8x (2 colors × 2 mirroring × 2 rotation).

2. *Pawn factorization*: Positions with pawns are indexed by pawn configuration first, then by piece positions. Two positions that differ only in the position of non-pawn pieces can share the same pawn index, reducing combinatorial explosion.

3. *Run-Length Encoding (RLE)*: Consecutive positions with the same WDL outcome are compressed. Since endgame outcomes tend to be locally consistent (adjacent king positions often have the same result), RLE is very effective.

4. *LZMA compression*: After in-memory packing, the data is compressed using LZMA (Lempel-Ziv-Markov chain algorithm), which achieves an additional 10-20x compression ratio on the already-reduced data.

5. *Probing on demand*: The engine does not load the entire tablebase into memory. Instead, it memory-maps the file and reads only the necessary blocks. The OS page cache efficiently manages the working set.

==== File Organization

A typical Syzygy installation looks like:

```text
syzygy/
  KQvK.rtbw       → WDL for KQ vs K (White's turn)
  KQvK.rtbz       → DTZ for KQ vs K
  KBBvK.rtbw      → WDL for KBB vs K
  KBBvK.rtbz      → DTZ for KBB vs K
  KRPvKR.rtbw     → WDL for KRP vs KR
  KRPvKR.rtbz     → DTZ for KRP vs KR
  ... thousands of files ...
```

For 6-piece tablebases, there are approximately 3,500 files (one WDL + one DTZ per unique piece combination). For 7-piece tablebases, approximately 54,000 files.

=== The Probing API: Fathom

The *Fathom* library is the standard Syzygy probing library used by virtually all engines. It provides a simple C API:

```c
#include "fathom/tbprobe.h"

// Initialize the tablebase system
bool tb_init(const char *path);  // path to directory containing .rtbw/.rtbz files

// Get the number of pieces in the largest available tablebase
unsigned tb_largest(unsigned max_pieces);

// Probe WDL
unsigned tb_probe_wdl(
    uint64_t white, uint64_t black,   // bitboards for white and black pieces
    uint64_t kings, uint64_t queens,  // bitboards per piece type (for both colors)
    uint64_t rooks, uint64_t bishops,
    uint64_t knights, uint64_t pawns,
    unsigned rule50,                  //  50-move rule counter (number of reversible half-moves)
    unsigned castling,                //  castling rights mask
    unsigned ep,                      //  en passant file (0-8, or 0 if none)
    bool turn                         //  true = white to move
);
// Returns:
//   TB_WIN, TB_LOSS, TB_DRAW, TB_CURSED_WIN, TB_BLESSED_LOSS, TB_PROMOTION, TB_RESULT_FAILED

// Probe DTZ
unsigned tb_probe_dtz(
    uint64_t white, uint64_t black,
    uint64_t kings, uint64_t queens,
    uint64_t rooks, uint64_t bishops,
    uint64_t knights, uint64_t pawns,
    unsigned rule50, unsigned castling,
    unsigned ep, bool turn, unsigned *success
);
// Returns: DTZ value (number of half-moves to zeroing move)
```

==== Integration into Search

Tablebase probing is integrated at two levels in the search:

1. *Root Probing*: If the root position has ≤N pieces (where N is the largest available tablebase), the engine can play perfectly using DTZ probing—no search needed. For each legal root move, probe DTZ. Choose the move with the best DTZ (lowest for winning, highest for losing, 0 for drawing).

2. *Search Probing*: During search, when the engine reaches a node with ≤N pieces, it probes WDL. This provides an immediate evaluation rather than searching further. The WDL result is converted to a score:

```c
#define TB_WIN_SCORE  20000  // Large positive to indicate tablebase win
#define TB_LOSS_SCORE -20000 // Large negative
#define TB_DRAW_SCORE 0

int tb_adjust_score(unsigned wdl_result, int ply) {
    switch (wdl_result) {
        case TB_WIN:   return TB_WIN_SCORE - ply;
        case TB_LOSS:  return -TB_WIN_SCORE + ply;
        case TB_DRAW:  return TB_DRAW_SCORE;
        case TB_CURSED_WIN: return TB_WIN_SCORE - ply - 500;  // de-prioritize 50-move-rule wins
        case TB_BLESSED_LOSS: return -TB_WIN_SCORE + ply + 500;
        default: return 0;
    }
}
```

The `ply` adjustment ensures the engine prefers shorter wins over longer ones (a mate in 10 is worth more than a mate in 20).

==== DTZ-Based Move Selection at the Root

When the root position is in the tablebase:

```c
Move best_tb_move() {
    // For the root position, find the move with the best DTZ
    int best_dtz = INT_MAX;
    Move best_move = NO_MOVE;

    MoveList moves;
    generate_moves(&pos, &moves);

    for (int i = 0; i < moves.count; i++) {
        make_move(&pos, moves[i]);
        unsigned success;
        int dtz = tb_probe_dtz(/* ... */, &success);

        if (success) {
            // For winning: minimize DTZ. For losing: maximize DTZ.
            if (dtz < best_dtz) {
                best_dtz = dtz;
                best_move = moves[i];
            }
        }
        unmake_move(&pos);
    }
    return best_move;
}
```

=== How Tablebases Are Generated: Retrograde Analysis

Tablebases are created through *retrograde analysis*—working backward from known terminal positions (checkmates, stalemates) to all reachable positions.

==== The Algorithm

1. *Enumerate all positions*: For a given material configuration (e.g., KQ vs K), generate all legal positions of those pieces on the board. This is the "universe" of positions.

2. *Mark terminal positions*: Any position that is checkmate (the opponent's king is in check and cannot escape) is marked as WIN for the checkmating side, LOSS for the mated side. Stalemates are marked as DRAW.

3. *Iterate (retrograde step)*:
   a. For each unmarked position, generate all legal moves.
   b. If any move leads to a WIN position, mark this position as WIN.
   c. If all moves lead to LOSS positions, mark this position as LOSS.
   d. If some moves lead to DRAW and no moves lead to WIN, mark this position as DRAW.
   e. Positions that are not marked in this iteration are "unknown" and will be reconsidered in the next iteration.

4. *Repeat* until no new positions are marked.

5. *Compute DTZ*: For WIN positions, DTZ is 1 + the minimum DTZ among the positions reached by a winning move. For LOSS positions, DTZ is 1 + the maximum DTZ among the positions reached by any move. For DRAW positions, DTZ is irrelevant (but stored for completeness).

This algorithm is a form of *backward induction*—the same principle behind minimax and game theory, but applied exhaustively to an entire game fragment.

==== Computational Scale

Generating a 7-piece tablebase is a massive computational undertaking:

- Number of unique piece configurations: approximately 423,000.
- Average number of positions per configuration: millions to billions.
- Total positions for 7 pieces: approximately `4 × 10^14` (with symmetry reduction).
- The Lomonosov 7-piece generation used a supercomputer at Moscow State University with hundreds of nodes over several months.
- Generating 8-piece tablebases is currently infeasible (estimated `10^17` positions, requiring exabyte-scale storage).

=== Practical Considerations for Engine Authors

==== Storage Requirements

```text
Pieces    WDL Size    DTZ Size    Total      Typical Engine Needs
────────  ──────────  ──────────  ─────────  ───────────────────
3-4 pc    < 1 MB      < 1 MB      ~1 MB      All engines support
5 pc      ~1 GB       ~1 GB       ~2 GB      Standard inclusion
6 pc      ~70 GB      ~80 GB      ~150 GB    High-end engines
7 pc      ~18 TB      ~80 TB      ~98 TB     Top engines only, SSD required
```

Most engines ship with 5-piece or 6-piece Syzygy support. 7-piece tablebases are typically only used on dedicated analysis machines with fast NVMe SSDs.

==== Memory-Mapped Probing

To avoid loading gigabytes of tablebase data into RAM, Syzygy uses memory-mapped files:

```c
#include <sys/mman.h>

// Fathom internally does this:
int fd = open("syzygy/KQvK.rtbw", O_RDONLY);
void *data = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
// The OS loads pages on demand; frequently accessed pages stay in page cache
```

The operating system's page cache automatically manages the working set. Engines typically probe only a small fraction of all tablebase positions during a game, so the effective RAM usage is modest (a few hundred MB even with 6-piece tablebases).

==== Fifty-Move Rule Handling

The fifty-move rule (a draw can be claimed if 50 moves pass without a capture or pawn push) presents a complication for tablebases. A theoretically won endgame (e.g., KQ vs KBN) might require more than 50 moves before the first capture or pawn push. Under tournament rules, the opponent can claim a draw before the win is completed.

Syzygy handles this with two additional result codes:

- *TB_CURSED_WIN*: The position is a theoretical win but requires more than 50 moves to the next zeroing move. Under the 50-move rule, the opponent can claim a draw.
- *TB_BLESSED_LOSS*: The position is a theoretical loss, but the win takes more than 50 moves, so the losing side can hold a draw by claiming the 50-move rule.

These are rare (affecting approximately 0.3% of 6-piece positions) but important for correct tournament behavior. Engines typically score cursed wins slightly below regular wins and blessed losses slightly above regular losses, so they prefer the guaranteed win/draw over the 50-move-rule-dependent outcome.

=== Tablebase Draws: The Fortress Problem

Tablebases reveal that many endgames previously thought to be winning are actually drawn. The most famous example is KRB vs KR: with a rook and bishop against a lone rook, it was long believed to be a win for the side with the bishop. The tablebase shows it is generally a draw (though with very difficult defense). The Philidor position (a specific KRB vs KR defensive setup) is the key drawing technique.

Similarly, KQ vs KRP with the pawn on the 7th rank is a draw in many positions because the pawn shielded by the rook creates a "fortress" that the queen cannot penetrate. Tablebases have fundamentally altered endgame theory by precisely identifying which positions are wins and which are draws.

=== Implementing Syzygy Probing in an Engine

==== Step 1: Initialize Fathom

```c
#include "fathom/tbprobe.h"

bool initialize_tablebases(const char *path) {
    if (!tb_init(path)) {
        fprintf(stderr, "Failed to initialize tablebases at %s\n", path);
        return false;
    }
    unsigned max_pieces = tb_largest(0);  // 0 = no limit
    printf("Tablebases loaded: up to %u pieces\n", max_pieces);
    return true;
}
```

==== Step 2: Probe at Internal Nodes

```c
int search_with_tb(Position *pos, int depth, int alpha, int beta, int ply) {
    // Check if position is in tablebase
    int piece_count = popcount(pos->white_pieces | pos->black_pieces);
    if (piece_count <= TB_LARGEST && pos->rule50 >= 0) {
        unsigned result = tb_probe_wdl(
            pos->white_pieces, pos->black_pieces,
            pos->kings, pos->queens,
            pos->rooks, pos->bishops,
            pos->knights, pos->pawns,
            pos->rule50, pos->castling,
            pos->ep_square, pos->side == WHITE
        );

        if (result != TB_RESULT_FAILED) {
            // Convert to score and return without further search
            int score = tb_adjust_score(result, ply);
            return score;
        }
    }

    // Normal search continues...
    return pvs(pos, depth, alpha, beta, ply);
}
```

==== Step 3: Probe at the Root

```c
void root_search_with_tb(Position *pos, int max_depth) {
    // If the root position is in the tablebase, play perfectly
    int piece_count = popcount(pos->white_pieces | pos->black_pieces);
    if (piece_count <= TB_LARGEST) {
        // Find the best move using DTZ
        Move best = best_tb_move();
        if (best != NO_MOVE) {
            printf("bestmove %s\n", move_to_string(best));
            return;  // No need to search
        }
    }
    // Otherwise, normal search
    iterative_deepening(pos, max_depth);
}
```

=== Tablebase Caching

Probing the tablebase is relatively expensive (involving a memory-mapped read, decompression, and indexing). To reduce the cost, engines cache recent probe results:

```c
#define TB_CACHE_SIZE 65536

typedef struct {
    uint64_t hash;
    int score;
    int depth;  // could be large since TB is perfect
} TBCacheEntry;

TBCacheEntry tb_cache[TB_CACHE_SIZE];

int tb_probe_cached(uint64_t hash, int piece_count, /* ... */) {
    // Check cache first
    int index = hash & (TB_CACHE_SIZE - 1);
    if (tb_cache[index].hash == hash) {
        return tb_cache[index].score;
    }

    // Probe the actual tablebase
    unsigned result = tb_probe_wdl(/* ... */);
    int score = tb_adjust_score(result, ply);

    // Store in cache
    tb_cache[index].hash = hash;
    tb_cache[index].score = score;

    return score;
}
```

This small cache typically achieves a hit rate of 80-95% because tablebase-eligible positions are revisited frequently (the same endgame positions appear at many search nodes).

=== The Future: 8-Piece Tablebases?

The prospect of 8-piece tablebases remains distant. Key challenges:

1. *Storage*: Estimated at ~50 PB (petabytes). This would require a data center, not a single computer.
2. *Generation time*: Even on the world's fastest supercomputers, generation would take years.
3. *Utility*: Most games are decided before reaching an 8-piece endgame. The practical benefit (ELO gain) would be minimal compared to 7-piece tablebases.
4. *Computational breakthroughs*: New mathematical techniques for retrograde analysis or quantum computing could change this calculus, but for now, 7 pieces is the practical limit.

=== Summary

Endgame tablebases provide engines with perfect knowledge for positions with up to 7 pieces. The Syzygy format, using WDL/DTZ separation and aggressive compression, makes 6-piece tablebases accessible on consumer hardware (~150 GB) and 7-piece tablebases feasible on high-end systems (~100 TB). The Fathom library provides a standard API for probing, which every major engine uses.

Key concepts:

- *Retrograde analysis*: Working backward from terminal positions to solve all positions of a material configuration.
- *WDL*: Win/Draw/Loss outcome at the root—used for pruning and evaluation during search.
- *DTZ*: Distance to Zeroing—used for optimal move selection at the root.
- *Cursed wins and blessed losses*: Fifty-move rule edge cases that engines handle with slightly adjusted scores.
- *Memory-mapped probing*: Efficiently accessing terabyte-scale databases through the OS page cache.

Tablebases are one of the clearest examples of how raw computation—solving chess exhaustively for small numbers of pieces—provides a direct ELO boost and eliminates endgame blind spots that plagued earlier generations of engines.
