# Illegal Move / Engine Failure Analysis

**Date:** 2026-05-15
**Context:** Nevergrad-tuned parameters vs baseline at 3+0 verification
**Problem rate:** 22.4% (17 failures out of 76 attempted games)

---

## Observed Failure Modes

### 1. "illegal move" — 8 occurrences (~10.5%)

The engine returned a move that the selfplay harness's minimal board rejected.

### 2. "Engine did not return bestmove" — 9 occurrences (~11.8%)

The engine either crashed, hung, or failed to produce a `bestmove` response within the timeout window.

---

## Root Cause Hypotheses

### Hypothesis A: Parameter-Induced Search Instability (MOST LIKELY)

The tuned parameters include:

- `nmp_reduction_base = 1` (was 2) — very aggressive null-move pruning
- `rfp_margin = 86` (was 90) — tighter static pruning
- `futility_margin = 271` (was 250) — deeper futility pruning
- `lmp_base = 3` (was 2) — more aggressive late-move pruning
- `lmp_div = 3` (was 2) — more aggressive late-move pruning

**Why this causes issues:**

1. **Null-move with base=1** means even at depth 3, null move reduces by only 1 ply. This can create zugzwang blindness or cause the search to miss critical defensive moves.
2. **Aggressive LMP** at deeper depths can prune moves that are tactically necessary, leading to positions where the engine believes it's safe but is actually in trouble.
3. **The combination** of aggressive pruning + 3+0 time control means the engine searches deeper but with more blind spots. At 100ms these blind spots don't manifest because the search is too shallow. At 3+0, the engine reaches depths where tactical oversights cause it to hang or return invalid moves.

**Evidence:**

- The baseline engine (default params) has **zero** illegal moves or failures in the same test.
- The tuned engine scores 90% at 100ms but only ~60% at 3+0 — suggesting the parameters cause deeper search to go wrong.

### Hypothesis B: Hash Table Collision / TT Corruption

At longer time controls, the engine searches many more nodes and accesses the transposition table more frequently. If the tuned parameters cause deeper searches that stress the TT in unusual ways, hash collisions could corrupt the search state, leading to:

- Invalid moves being stored as "best" in TT
- Search returning inconsistent results
- Engine hanging when it tries to resolve contradictory TT entries

**Evidence:**

- The failures are intermittent (not every game)
- Both "illegal move" and "no bestmove" suggest corrupted search state

### Hypothesis C: Integer Overflow in Search Stack

The search uses `static_eval_stack[MAX_PLY]` and various depth-dependent calculations. With check extensions and the tuned parameters causing deeper effective search, there might be edge cases where:

- `ply` exceeds expected bounds
- History table values overflow (though clamping exists)
- Continuation history array access goes out of bounds

**Evidence:**

- The `continuation_history` access has extensive bounds checking, suggesting past issues
- Some failures could be silent crashes that don't produce error output

### Hypothesis D: Selfplay Harness Bug (LESS LIKELY)

The minimal Python board or UCI communication might have a race condition.

**Counter-evidence:**

- The baseline engine (identical binary except params) has zero failures
- The failures correlate with the tuned engine specifically
- If it were a harness bug, both engines would fail equally

---

## Recommended Investigations

### Immediate (to confirm Hypothesis A):

1. **Test each parameter individually:**

   ```bash
   # Test NMP base=1 alone
   python3 selfplay.py --engine-a ./mantis_nmp1 --engine-b ./mantis_baseline --verify

   # Test LMP base=3 alone
   python3 selfplay.py --engine-a ./mantis_lmp3 --engine-b ./mantis_baseline --verify
   ```

2. **Run with assertions enabled:**

   ```bash
   # Build with bounds checking and assertions
   odin build . -o:mantis_debug -debug
   ```

   Then run a few games and check for crashes.

3. **Log engine stderr:**
   Modify `selfplay.py` to capture and print engine stderr on failure.

### Medium-term:

4. **Add a "safe mode" search:**
   When depth > 20 or node count > 1M, disable the most aggressive pruning (LMP, NMP) to avoid search instability at deep depths.

5. **Clamp NMP reduction:**

   ```odin
   nmp_reduction := params.nmp_reduction_base + effective_depth / params.nmp_reduction_div
   if nmp_reduction > effective_depth - 2 { nmp_reduction = effective_depth - 2 }
   ```

6. **Sanity-check LMP threshold:**
   ```odin
   lmp_threshold = params.lmp_base + depth * depth / params.lmp_div
   if lmp_threshold > move_list.count { lmp_threshold = move_list.count }
   ```

---

## Conclusion

The most likely cause is **Hypothesis A: parameter-induced search instability**. The aggressive pruning tuned for 100ms bullet chess becomes dangerous at longer time controls where deeper search exposes tactical blind spots.

**Recommendation:** Do not commit the current tuned values. Instead:

1. Run Nevergrad again with a **safety constraint**: LMP threshold cannot exceed 50% of legal moves
2. Verify each candidate with 20 games at 3+0 before accepting
3. Consider tuning at a mixed time control (50% 100ms, 50% 500ms) to avoid overfitting

---

_Generated automatically when problem rate exceeded 20% threshold._
