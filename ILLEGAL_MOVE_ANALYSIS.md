# Illegal Move / Engine Failure Analysis

**Date:** 2026-05-15
**Context:** Nevergrad-tuned parameters vs baseline at 3+0 verification
**Problem rate:** 22.4% → **~5% after fixes** (still above TCEC standard of <1%)

---

## Observed Failure Modes

### 1. "illegal move" — Engine returns move for wrong color or from empty square

Examples captured:

- `e1g1` when it's **Black's turn** (White castling)
- `e8g8` when it's **White's turn** (Black castling)
- `a1g7` from an **empty square** in the Python board
- `h6h5` when it's White's turn (Black pawn push)

**Root cause:** The engine's internal board has diverged from the selfplay harness's board. The engine thinks it's the other side's turn, or thinks a piece is on a square where the Python board has nothing.

### 2. "Engine did not return bestmove" — Timeout/crash

The engine hangs during search and doesn't respond within the timeout window.

---

## Root Cause Findings

### Fix 1: Dangerous Parameters (APPLIED)

Reverted:

- `nmp_reduction_base = 2` (was 1)
- `futility_margin = 250` (was 271)
- `lmp_base = 2` (was 3)
- `lmp_div = 2` (was 3)

**Result:** Problem rate dropped from 23% to ~5%.

### Fix 2: Fallback Bestmove (APPLIED)

Added fallback in `search_position`: if `best_move` is zero after search, regenerate legal moves and pick the first one. Prevents returning `bestmove (none)`.

### Fix 3: TT Move Validation (APPLIED)

Added `is_valid_tt_move()` to reject TT entries with out-of-bounds coordinates.

### Remaining Issue: Board Divergence

Even with safe parameters, illegal moves still occur (~5%). This happens **even with concurrency=1**, ruling out race conditions.

**Evidence:**

- Debug logging shows **no parse failures** (`parse_move` finds all moves)
- The divergence happens gradually over many moves
- Specific pattern: engine returns moves for the **wrong side**

**Hypothesis:** The Python `MinimalBoard` in `selfplay.py` disagrees with the Odin `Board` on edge cases (castling rights update, en passant square handling, or promotion piece placement). When they disagree, `apply_uci_move` rejects a move, but the engine already applied it internally. On the next search, the engine receives the OLD move list (without the rejected move), but its internal board is already ahead. It searches the wrong position and returns a move for the wrong side.

**Supporting evidence:**

- One illegal move was `e1g1` when it's Black's turn. The FEN showed the white king was ALREADY on g1, meaning `e1g1` was played earlier and applied by the engine but possibly rejected by Python.
- Another was `a1g7` from an empty square. Earlier in the game, `g7a1` was played (bishop to a1). The Python board might have rejected `g7a1` for some reason, causing divergence.

---

## Recommended Next Steps

### Immediate:

1. **Replace MinimalBoard with python-chess:**

   ```bash
   source venv/bin/activate
   pip install chess
   ```

   Then replace `MinimalBoard` in `selfplay.py` with `chess.Board`. This eliminates any possibility of a Python board bug.

2. **Add per-game FEN logging:**
   After every move, print both the engine's internal FEN (via a custom UCI command) and the Python board's FEN. Compare them to detect divergence immediately.

3. **Use cutechess-cli for serious testing:**
   ```bash
   cutechess-cli -engine cmd=./mantis -engine cmd=./mantis_baseline \
     -each tc=3+0 -games 100 -concurrency 4
   ```
   `cutechess-cli` has a battle-tested board implementation. If illegal moves still happen with cutechess, the bug is definitely in the engine.

### Medium-term:

4. **Add UCI `d` (display) command:**
   Implement a `d` command in the engine that prints the current board state. Use this after every move in selfplay to verify the engine's board matches the Python board.

5. **Audit `parse_position` move application:**
   The `parse_position` function in `uci/uci.odin` uses `make_move` (with legality checking). If `make_move` silently accepts an illegal move in some edge case, the board diverges from the first move of the game. Add assertions to verify the move is actually legal before applying it.

---

## Conclusion

The illegal move problem has **two distinct causes**:

1. **Aggressive pruning parameters** (fixed by revert) — caused 18% of failures
2. **Board divergence between engine and Python harness** (still under investigation) — causes the remaining ~5%

**Current status:** The engine is stable enough for local tuning (5% failure is manageable for exploration), but **NOT ready for TCEC** until the divergence is resolved.

**Fastest path to TCEC-ready:** Switch to `cutechess-cli` or `python-chess` for testing. If the engine still produces illegal moves with a battle-tested board, then the bug is in the engine's move application (likely `make_move_fast` or `apply_move_to_board`) and needs to be fixed there.

---

_Last updated: 2026-05-15 after parameter reversion and defensive fixes._
