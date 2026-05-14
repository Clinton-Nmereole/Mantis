# Mantis Chess Engine — Comprehensive Analysis & Path to TCEC

> **Prepared by:** AI Code Analysis Harness  
> **Date:** 2026-05-13  
> **Scope:** Full codebase audit for performance, correctness, algorithmic strength, and architectural fitness for Top Chess Engine Championship (TCEC) participation.

---

## Executive Summary

Mantis, as it stands today, is **not a competitive chess engine**. It is a functional educational engine with severe architectural, algorithmic, and performance deficiencies that place it likely in the **1200–1800 Elo range** (depending on time control), vastly below the ~3500+ Elo required for TCEC participation.

**The single most devastating issue:** Mantis copies an **~8.5KB `Board` struct at every single node** in the search tree because it lacks an `unmake_move` (takeback) function. This is not a minor optimization miss — it is an **existential architectural flaw** that makes high-depth search physically impossible.

To reach TCEC level, Mantis would require **not incremental improvements but a near-complete rewrite** of its search core, move handling, evaluation pipeline, and parallelization strategy.

---

## 1. CATASTROPHIC Performance Bottlenecks (Fix These First)

### 1.1 The "Board Copy" Disaster — Priority: CRITICAL 🔴

**Location:** `search/search.odin`, `board/perft.odin`  
**Pattern:** `next_board := b^` (struct copy)

The `Board` struct is enormous:

| Field | Size |
|-------|------|
| `bitboards[12]` | 96 bytes |
| `occupancies[3]` | 24 bytes |
| `mailbox[64]` | 64 bytes |
| `accumulators[2][2048]i16` | **8,192 bytes** |
| Other fields | ~40 bytes |
| **Total** | **~8,416 bytes** |

Every `negamax` call, every quiescence node, every move trial copies **8.4KB of memory**. At 1 million nodes per second, that's **8.4 GB/sec of memory bandwidth** just for board copying — saturating L3 cache and destroying performance.

**World-class engines (Stockfish, Leela, Koivisto, etc.)** use:
- **Make/Unmake** (undo move) with a small `StateInfo` struct (~32-64 bytes pushed/popped)
- Incremental updates to hash, material, PST, and NNUE accumulators
- **No board copies in the hot path**

**What you must do:**
1. Implement `unmake_move(board, move, state_info)` that reverses all changes.
2. Store only reversible state (captured piece, old en passant, old castling rights, old hash, old halfmove clock) in a small stack-allocated struct.
3. Replace `next_board := b^` with `make_move(b, move)` → search → `unmake_move(b, move, state)`.
4. This single change alone could yield **10–50x speedup**.

---

### 1.2 Dynamic Memory Allocation in the Hot Path — Priority: CRITICAL 🔴

**Location:** `search/search.odin:negamax`, `quiescence`, `generate_all_moves`

```odin
move_list := make([dynamic]moves.Move)
defer delete(move_list)
board.generate_all_moves(b, &move_list)
```

`[dynamic]` arrays in Odin are heap-allocated growable vectors. In the search hot path, **every node allocates from the heap**. At millions of nodes per second, this triggers:
- Allocator contention (even with allocators, it's unnecessary overhead)
- Cache pollution
- Potential GC/arena pressure

**World-class engines** pre-allocate a fixed-size `MoveList` array on the stack (max 256 moves) and pass it by reference. No heap in the search loop.

**What you must do:**
```odin
MoveList :: struct {
    moves: [256]moves.Move,
    count: int,
}
```
Pass `^MoveList` everywhere. Zero allocations in search.

---

### 1.3 `make_move` Performs Full Legality Checking — Priority: HIGH 🟠

**Location:** `board/perft.odin:make_move`

`make_move` checks `is_square_attacked` on the king **after** every move to validate legality. This means:
- Move generation produces pseudo-legal moves
- `make_move` verifies them one by one
- In check positions, most moves are legal; in non-check, ~90% are legal anyway
- The check test calls `is_square_attacked` which itself runs the full attack detector

**World-class engines** generate pseudo-legal moves and skip the legality test during `make_move`. Instead, they detect illegal moves by:
- If in check: only generate evasions (already legal-ish)
- If king moves: check if destination is attacked (cheap)
- For pinned pieces: either handle in movegen or let `make_move` check only when necessary

Better yet: generate **legal moves directly** (more complex but faster in practice).

**What you must do:**
- Separate `make_move` into `make_move_fast` (no legality check) and `make_move_legal` (for root/UCI)
- In search, assume pseudo-legal and only verify if king is left in check after the move
- Or better: implement legal move generation

---

### 1.4 `is_square_attacked` Called Excessively — Priority: HIGH 🟠

**Location:** `board/perft.odin:is_square_attacked`

This function is called:
- Once per `make_move` (to verify legality)
- For castling rights verification (2 squares)
- Potentially elsewhere

It rebuilds slider attacks from scratch using magic bitboards every time. While magic bitboards are fast, doing this **millions of times per second** is wasteful.

**What you must do:**
- Cache/check `in_check` status at the start of each `negamax` call (you already compute `king_sq` and `in_check` — use it!)
- Don't call `is_square_attacked` inside `make_move` during search
- Pre-compute pinned pieces and checkers at the start of the node

---

### 1.5 No Incremental/Make-Unmake for NNUE Accumulators — Priority: CRITICAL 🔴

**Location:** `nnue/nnue.odin:update_accumulators`

Because Mantis copies the board, the NNUE accumulator is copied too (`new_board.accumulators = old_board.accumulators`). If you fix issue #1 and implement make/unmake, you **must also** incrementally update/unupdate the NNUE accumulator.

Currently, `update_accumulators` does incremental updates, but:
- It loops over **2048 hidden units** for every feature add/remove
- A typical move changes 2–4 features (source remove, target add, capture remove, promotion add)
- That's 4 × 2048 = **8192 i16 operations per move**
- At 10M nodes/sec, that's **81 billion i16 ops/sec** — doable but not ideal

**World-class engines** use SIMD (AVX2/AVX-512) for accumulator updates, doing 16–32 elements per instruction. Without SIMD, you're leaving ~8–16x performance on the table.

**What you must do:**
- For now: keep scalar incremental updates, but ensure they work with make/unmake
- Long-term: implement AVX2 accumulator updates (Odin supports inline assembly or vendor intrinsics)
- Alternatively: use a smaller hidden size network (256 or 512 instead of 2048)

---

## 2. Search Algorithm Deficiencies

### 2.1 LMR (Late Move Reduction) is Primitive

**Location:** `search/search.odin`

```odin
reduction = int(math.ln(f64(combined_depth)) * math.ln(f64(legal_moves)) / 1.5)
```

This formula:
- Has no move-dependent tuning (history, capture, PV, etc.)
- No depth-dependent clamping table
- No consideration of whether the move gives check
- No "improving" flag (whether static eval improved from parent's)

**World-class engines** use a 2D table `reductions[depth][move_number]` with many exceptions:
- Don't reduce if move gives check
- Don't reduce if static eval is improving
- Don't reduce captures
- History-based adjustments
- PV-node reductions
- Deep reduction for very late moves

**What you must do:**
- Implement a `LMR_Table[64][64]int` precomputed at startup
- Add all standard LMR conditions
- Tune the table using SPSA or manual testing

---

### 2.2 Missing Critical Search Pruning Techniques

Mantis is missing several modern pruning techniques that are **mandatory** for strong play:

| Technique | Status | Impact |
|-----------|--------|--------|
| **Null Move Pruning** | ✅ Present (basic) | Medium |
| **Razoring** | ✅ Present (very basic) | Low |
| **Reverse Futility Pruning** | ✅ Present | Medium |
| **Futility Pruning** | ✅ Present | Low |
| **Late Move Pruning (LMP)** | ❌ **MISSING** | **HIGH** |
| **Probcut** | ❌ **MISSING** | **HIGH** |
| **Delta Pruning (in Q-search)** | ❌ **MISSING** | **HIGH** |
| **QS SEE Pruning** | ⚠️ Basic (threshold -100) | Medium |
| **Internal Iterative Deepening** | ✅ Present | Low |
| **Singular Extensions** | ✅ Present (but buggy) | Medium |

**Late Move Pruning (LMP)** is the biggest miss. After searching the first N moves at a given depth, if no cutoff occurred, you can skip searching quiet moves entirely. This prunes 30–50% of nodes.

**What you must do:**
- Implement LMP with a depth-dependent move count threshold
- Implement Probcut: `if (static_eval + probcut_margin < beta) try tactical moves at reduced depth`
- Implement delta pruning in Q-search: `if (stand_pat + delta < alpha) return alpha`
- Tune all margins

---

### 2.3 Aspiration Windows are Broken / Inefficient

**Location:** `search/search.odin:search_position`

The aspiration window code exists but is clunky:
- It only applies to the first MultiPV line
- Failed low/high triggers a **complete re-search of ALL root moves** from scratch
- No gradual widening (should widen by ~50, then ~200, then infinity)

**What you must do:**
- Use progressively wider windows: `±25`, `±100`, `±300`, `±INF`
- Don't re-search all moves — just continue where you left off
- Only re-search the move that failed, not all moves

---

### 2.4 No Principal Variation Search (PVS) at Root

The root search does a full-window search for every move. It should:
- Search first move with full window `(-INF, +INF)`
- Search subsequent moves with null window `(-alpha-1, -alpha)`
- Re-search with full window only if null window score > alpha

This is present in `negamax` but **not at the root**, wasting significant time.

---

### 2.5 Check Extension is Too Restrictive

```odin
if in_check && ply < 40 {
    effective_depth = 1
}
```

This extends by exactly 1 ply and only up to ply 40. Modern engines:
- Extend by 1 ply for any check (no ply limit)
- Use **double extensions** sparingly for very dangerous checks
- Use **singular extensions** more aggressively

Also: the check detection happens at `depth == 0`, which means you miss extensions at higher depths where they matter more.

---

### 2.6 Singular Extension Implementation is Fragile

```odin
if depth >= SE_DEPTH && !in_check && ply > 0 && tt_move.source != 0 && excluded_move.source == 0
```

Issues:
- `ply > 0` prevents SE at root — acceptable but limits strength
- No double extension logic
- No margin tuning based on depth
- No verification that the TT entry is actually from a sufficient depth
- The singular search uses `excluded_move` parameter but there's no mechanism to pass it down correctly through all call sites

---

## 3. Move Ordering Issues

### 3.1 MVV-LVA is Slow

**Location:** `search/sort.odin:score_move`

For captures, the scorer iterates over enemy bitboards to find the victim piece:
```odin
for i in start_piece ..< end_piece {
    if (b.bitboards[i] & (1 << u64(move.target))) != 0 {
        victim_piece = i % 6
        break
    }
}
```

This is O(6) per capture move. With 30 captures and millions of nodes, this adds up.

**What you must do:**
- Use a precomputed `MvvLvaScores[6][6]int` table
- Store victim type in the `Move` struct at generation time (add a `victim: i8` field)
- Or compute from mailbox: `victim = b.mailbox[move.target] % 6`

### 3.2 No SEE (Static Exchange Evaluation) for Move Ordering

Mantis has a `see_capture` function but **doesn't use it for move ordering**. Captures are sorted purely by MVV-LVA, which is blind to whether a capture actually wins material.

**What you must do:**
- Compute SEE for all captures at generation or scoring time
- Sort winning captures before equal captures before losing captures
- Use SEE threshold in Q-search (you have basic threshold, but should use proper SEE)

### 3.3 Insertion Sort is Suboptimal

For small move lists (≤30 moves), insertion sort is fine. But a hybrid approach (quick sort for large lists, insertion for small) is better. More importantly, you should use **partial sorting** — you only need the best move for LMR/LMP decisions, not a fully sorted list.

---

## 4. Transposition Table is Primitive

### 4.1 No Buckets / Single Entry Per Slot

```odin
index := key % u64(len(tt))
entry := &tt[index]
```

Only one entry per hash slot. Collisions cause immediate overwrites. Modern engines use **2–4 entry buckets** (always-replace + depth-preferred slots) to retain more useful entries.

### 4.2 Replacement Scheme is Too Simple

```odin
if old_key != 0 && old_key != key && entry.depth > depth + 2 {
    return
}
```

This keeps deeper entries but ignores:
- Entry age (old entries from previous searches are less valuable)
- Whether the entry is from the current search iteration
- PV-node entries (which are more valuable)

### 4.3 TT Move Can Be Invalid

`get_tt_move` returns the move from the TT without verifying it's legal in the current position. If the hash collides or the position changed, the TT move could be illegal, wasting a search slot.

### 4.4 No TT Cutoffs in Q-Search

The quiescence function doesn't probe the TT at all. Many Q-search positions repeat, especially in tactical lines.

---

## 5. Parallel Search is Broken

### 5.1 "Lazy SMP" is Not Actually Lazy SMP

**Location:** `search/thread_pool.odin`

```odin
// Add search diversity: each thread searches at slightly different depth
if data.thread_id % 2 == 1 {
    adjusted_depth = max(1, data.depth - 1)
}
```

This is not Lazy SMP. This is "wasted work SMP." True Lazy SMP:
- All threads search the same position at the same depth
- They share the TT
- The TT acts as a communication channel
- Threads may have different aspiration windows or move ordering biases
- No artificial depth reduction

**What Mantis does wrong:**
- Odd threads search 1 ply shallower → they find weaker results that don't help the main thread
- No shared TT communication (each thread has its own globals)
- Killer moves, history, counter moves are **global variables**, causing thread contention and corruption

### 5.2 Global Search State is Not Thread-Local

```odin
nodes: u64 = 0
killer_moves: [MAX_PLY][2]moves.Move
history_table: [12][64]int
counter_moves: [12][64]moves.Move
```

These are global variables. In parallel search:
- `nodes` is incremented without atomics → data races, incorrect counts
- `killer_moves` is overwritten by multiple threads → corrupted move ordering
- `history_table` has data races → corrupted history values
- `counter_moves` has data races

**What you must do:**
- Create a `SearchThread` struct containing all thread-local state
- Each thread gets its own `SearchThread`
- Only the TT is shared (with proper atomic operations)
- Use `sync.atomic_add` for shared `nodes` counter

---

## 6. NNUE Evaluation is Misconfigured

### 6.1 Architecture Mismatch

The code claims `HalfKAv2_hm` with `INPUT_SIZE :: 45056` and `HIDDEN_SIZE :: 2048`.

However:
- The biases only read **1024 values** from the file (`for i in 0 ..< 1024`)
- The feature weights read `INPUT_SIZE * 2048` values
- But `HIDDEN_SIZE` is defined as 2048

Standard HalfKAv2 networks have **1024 hidden units** (512 per perspective, concatenated to 1024). A 2048-hidden network would be unusual and the file format doesn't match.

**Likely bug:** The network has 1024 hidden units, but the code treats it as 2048. This means:
- Only half the biases are read
- The weight indexing is wrong
- The evaluation is producing garbage values

### 6.2 No SIMD in NNUE Forward Pass

```odin
for i in 0 ..< HIDDEN_SIZE {
    val := input[i]
    if val < 0 {val = 0}
    if val > QA {val = QA}
    if val != 0 {
        for j in 0 ..< 32 {
            l1_out[j] += i32(val) * i32(current_network.l1_weights[i * 32 + j])
        }
    }
}
```

This is a scalar dot product over 2048×32 = 65,536 multiply-adds per evaluation. At 100K evals/sec, that's 6.5 billion ops/sec.

With AVX2, you could do 16 i16 multiplies per instruction, reducing this by ~8–16x.

### 6.3 Accumulator Refresh on King Move is Expensive

When the king moves, `compute_accumulator` does a full refresh by iterating all 64 squares and adding features. This is correct but slow. Modern engines use:
- **Incremental updates even for king moves** (by tracking both king-bucket accumulators)
- Or: maintain a stack of accumulator states and pop them on unmake

Because Mantis has no unmake, it can't use accumulator stacks.

---

## 7. Evaluation Fallback (HCE) is Minimal

### 7.1 No Tapered Eval

The hand-crafted evaluation uses a single set of PSTs with no midgame/endgame interpolation. This causes:
- King to stay in the corner in endgames (using midgame king table)
- Pawns to advance too aggressively in endgames
- No recognition of specific endgame types

### 7.2 Missing Basic Evaluation Terms

- No pawn structure evaluation (doubled, isolated, passed pawns)
- No mobility evaluation
- No king safety (pawn shield, storm)
- No bishop pair bonus
- No rook on open file
- No tempo bonus
- No drawishness detection (insufficient material, opposite bishops, etc.)

---

## 8. Time Management is Conservative but OK

The time management in `search/time_manager.odin` is actually reasonable for a basic engine. Issues:
- No "panic time" extension when score drops significantly
- No "easy move" detection (if first move is obviously best, play quickly)
- No move time smoothing across iterations
- `exceeded_optimal` stops search between depths, which is fine but could be more sophisticated

---

## 9. UCI & Interface Issues

### 9.1 `parse_move` is Inefficient

Called for every move in `position moves ...`:
```odin
move_list := make([dynamic]moves.Move)
defer delete(move_list)
board.generate_all_moves(b, &move_list)
for m in move_list { ... }
```

This generates ALL legal moves and does string comparison for every UCI move. Use a map or direct square/piece lookup.

### 9.2 No `bench` Command

TCEC and testing frameworks require a `bench` command for reproducible performance measurement.

### 9.3 Ponder Implementation is Incomplete

The ponder code spawns a thread but doesn't integrate cleanly with search state.

---

## 10. Missing TCEC-Mandatory Features

| Feature | Required for TCEC? | Status |
|---------|-------------------|--------|
| UCI Protocol | ✅ | Partial |
| MultiPV | ✅ | Present but inefficient |
| Ponder | ⚠️ | Incomplete |
| Hash resizing | ✅ | Present |
| Thread support | ✅ | Broken |
| NNUE eval | ⚠️ | Misconfigured |
| Syzygy TB | ❌ No | Missing |
| Draw adjudication | ❌ No | Missing (GUI handles) |
| Opening book | ❌ No | Missing |
| TB adjudication | ❌ No | Missing |

---

## 11. Odin-Specific Concerns

### 11.1 No SIMD Intrinsics
Odin supports inline assembly but not high-level SIMD intrinsics like C++'s `<immintrin.h>`. For a competitive engine, you'll need to write AVX2/AVX-512 assembly or use Odin's `core:simd` if available.

### 11.2 Memory Safety vs Performance
Odin's bounds checking and nil checking can add overhead in tight loops. Use `#no_bounds_check` judiciously in hot paths.

### 11.3 Build System
No `build.sh`, `Makefile`, or CI. No release builds with optimizations.

---

## Prioritized Roadmap to TCEC Viability

### Phase 1: Fix Architecture (Weeks 1–2) — +500 Elo potential
1. **Implement `unmake_move`** with small state struct
2. **Replace all `Board` copies** with make/unmake pattern
3. **Replace dynamic move lists** with fixed-size stack arrays
4. **Verify NNUE dimensions** match the network file (1024 vs 2048)

### Phase 2: Search Modernization (Weeks 2–4) — +300 Elo potential
1. Implement proper **LMR table** with all standard conditions
2. Implement **Late Move Pruning (LMP)**
3. Implement **Probcut**
4. Implement **Delta Pruning** in Q-search
5. Fix **aspiration windows** with gradual widening
6. Add **PVS at root**

### Phase 3: Parallel Search Fix (Weeks 4–5) — +100 Elo potential
1. Make all search state **thread-local**
2. Implement proper **Lazy SMP** (all threads same depth)
3. Add atomic node counter
4. Test with 4–8 threads

### Phase 4: Move Ordering & TT (Weeks 5–6) — +100 Elo potential
1. Add **victim field** to `Move` struct
2. Implement **SEE** for capture sorting
3. Implement **TT buckets** (2–4 entries)
4. Add **TT aging**
5. Add **TT probe in Q-search**

### Phase 5: Evaluation (Weeks 6–8) — +200 Elo potential
1. Fix NNUE architecture to match file format
2. Add **AVX2 SIMD** for accumulator updates and forward pass
3. Add **tapered eval** to HCE fallback
4. Add basic **pawn structure**, **mobility**, **king safety**

### Phase 6: TCEC Hardening (Weeks 8–10)
1. Implement `bench` command
2. Add Syzygy tablebase support
3. Add opening book support
4. Add robust crash handling
5. Extensive testing with OpenBench/FGS

---

## Honest Assessment

| Metric | Mantis Today | TCEC Minimum | Gap |
|--------|-------------|--------------|-----|
| NPS | ~50K–200K | 10M+ | **50–200×** |
| Search Depth (1s) | ~6–8 ply | ~18–22 ply | **10–14 ply** |
| Elo (estimated) | ~1500 | ~3200 | **~1700 Elo** |
| Board Copy Cost | 8.4KB/node | ~32 bytes/node | **260×** |
| Threads | Broken | 176+ | N/A |

**The Bottom Line:**

Mantis is a good learning project. It has magic bitboards, a working UCI loop, basic NNUE support, and some modern search ideas. But the **fundamental decision to copy the entire board instead of make/unmake** makes it impossible to compete at any serious level.

If your goal is TCEC, you have two paths:
1. **Rewrite Mantis from the ground up**, keeping only the bitboard move generation and magic bitboard code. Rebuild search, state management, and evaluation around make/unmake.
2. **Fork a proven engine** (e.g., Weiss, Berserk, or an open-source Stockfish derivative) and adapt it. This is how most TCEC engines started.

The choice depends on whether your goal is **learning** (fix Mantis iteratively) or **competing** (start from a stronger base or do a major rewrite).
