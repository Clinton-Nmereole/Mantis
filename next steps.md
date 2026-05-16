# Mantis — Next Steps (Session Continuation)

**Session ended:** 2026-05-15
**Current branch:** detached HEAD at commit `0cbb81c`
**Status:** Illegal move fixes partially applied; board divergence still under investigation

---

## What Was Done Today

1. ✅ Reverted dangerous tuned parameters (`nmp_reduction_base=2`, `lmp_base=2`, etc.)
2. ✅ Added fallback bestmove logic in `search/search.odin`
3. ✅ Added TT move validation in `search/tt.odin`
4. ✅ Added parse failure logging in `uci/uci.odin`
5. ✅ Added failure-rate guard in `nevergrad_tuner.py`
6. ✅ Created `ILLEGAL_MOVE_ANALYSIS.md` with detailed findings
7. ✅ Problem rate reduced from **~23% → ~5%**

---

## The Remaining Problem (~5% failure rate)

**Symptom:** Engine returns moves for the wrong color or from empty squares.

**Root cause hypothesis:** Gradual board divergence between the engine's Odin `Board` and the Python `MinimalBoard` in `selfplay.py`. When they disagree on a move's legality, the Python board rejects it but the engine already applied it internally. On the next turn, the boards are out of sync.

**Evidence:**
- Happens even with `concurrency=1` (not a race condition)
- Debug logging shows **no parse failures** in `uci/uci.odin`
- Specific pattern: `e1g1` when it's Black's turn (White already castled earlier)
- Another: `a1g7` from empty square (bishop moved `g7a1` earlier, possibly rejected by Python)

---

## Priority 1: Confirm Board Divergence with python-chess

You mentioned you installed `python-chess`. Here's the plan:

### Step 1: Install python-chess in the venv
```bash
cd /home/clinton/Developer/Odin/Mantis
source venv/bin/activate
pip install chess
```

### Step 2: Create `selfplay_chess.py`
Write a drop-in replacement for `selfplay.py` that uses `chess.Board` instead of `MinimalBoard`:

```python
import chess

class ChessBoardWrapper:
    def __init__(self, fen="startpos"):
        self.board = chess.Board() if fen == "startpos" else chess.Board(fen)
    
    def apply_uci_move(self, move_str):
        try:
            move = chess.Move.from_uci(move_str)
            if move in self.board.legal_moves:
                self.board.push(move)
                return True
            return False
        except:
            return False
    
    def get_result(self):
        if self.board.is_checkmate():
            return "1-0" if self.board.turn == chess.BLACK else "0-1"
        if self.board.is_stalemate() or self.board.is_insufficient_material():
            return "1/2-1/2"
        if self.board.is_fivefold_repetition() or self.board.is_seventyfive_moves():
            return "1/2-1/2"
        return None
    
    def fen(self):
        return self.board.fen()
```

Then adapt the `play_game()` function to use `ChessBoardWrapper` instead of `MinimalBoard`.

### Step 3: Run identical test with both boards
```bash
# Test with python-chess board
python3 selfplay_chess.py --engine-a ./mantis --engine-b ./mantis_baseline \
  --games 20 --movetime 2000 --concurrency 1

# Compare failure rate
```

**Expected outcome:**
- If failure rate drops to **0%**: The bug was in `MinimalBoard`. Keep `selfplay_chess.py` and delete `MinimalBoard`.
- If failure rate stays at **~5%**: The bug is in the engine's `make_move_fast` / `apply_move_to_board`. We need to audit the Odin board code.

---

## Priority 2: If Bug Is in Engine (python-chess still fails)

### Audit `apply_move_to_board` in `board/perft.odin`

Focus on these edge cases:

1. **Castling rights update:**
   - Does `b.castle &= castling_rights_mask[move.source]` handle rook captures correctly?
   - Does it handle king moves correctly when the king has already moved and castling rights were lost?

2. **En passant square handling:**
   - When a pawn moves, is `b.en_passant` set correctly?
   - When a non-pawn moves, is `b.en_passant` reset to -1?
   - Does `parse_fen` set `b.en_passant` correctly for all FENs?

3. **Promotion piece placement:**
   - After promotion, is the promoted piece placed on the correct bitboard?
   - Is the original pawn removed from the pawn bitboard?
   - Is the mailbox updated correctly?

4. **Rook placement during castling:**
   - Kingside: rook from h-file to f-file
   - Queenside: rook from a-file to d-file
   - Are BOTH bitboard and mailbox updated?

### Add UCI `d` (display) command

In `uci/uci.odin`, add:
```odin
} else if command == "d" {
    board.print_board(game_board)
    fmt.printf("FEN: %s\n", board.get_fen(&game_board))
}
```

Use this after every move in selfplay to compare engine FEN vs Python FEN.

---

## Priority 3: If Bug Was in Python Board (python-chess fixes it)

1. Replace `MinimalBoard` with `ChessBoardWrapper` in `selfplay.py`
2. Delete `test_crash*.py` files
3. Run a full 100-game verification at 3+0
4. If clean, proceed with tuning

---

## Priority 4: Continue Tuning (Once Engine Is Verified Stable)

### Option A: Local Tuning with Nevergrad
```bash
source venv/bin/activate
python3 nevergrad_tuner.py --budget 50 --games 15 --movetime 200 --concurrency 4
```

### Option B: Cutechess-CLI Integration
Once `cutechess-cli` is installed:
```bash
# Quick SPRT test
cutechess-cli \
  -engine cmd=./mantis \
  -engine cmd=./mantis_baseline \
  -each tc=3+0 -games 100 -concurrency 4 \
  -openings file=openings.epd format=epd \
  -sprt elo0=0 elo1=2 alpha=0.05 beta=0.05
```

### Option C: Cloud Tuning
See `CLOUD_TUNING.md` for GCP/AWS setup. Recommended for serious TCEC prep.

---

## Priority 5: TCEC Readiness Checklist

Before declaring Mantis TCEC-ready, verify:

- [ ] **0% failure rate** in 100+ games at 3+0 or longer
- [ ] **Never returns illegal move** in 500+ games
- [ ] **Handles all UCI edge cases:** `go infinite`, `stop`, `ponderhit`, `ucinewgame`
- [ ] **Time management tested** with increment (TCEC uses increment)
- [ ] **Multi-threaded search tested** (TCEC uses 176 threads)
- [ ] **Syzygy tablebases work** in endgames
- [ ] **Opening book compatibility** tested
- [ ] **Bench is stable** (same node count across runs)

---

## Files to Review Tomorrow

| File | Purpose |
|------|---------|
| `board/perft.odin` | `apply_move_to_board` — likely source of divergence |
| `uci/uci.odin` | `parse_position`, `parse_move` — verify move application |
| `selfplay.py` | `MinimalBoard` — replace with `python-chess` |
| `search/search.odin` | Fallback bestmove logic — verify it works |
| `search/tt.odin` | TT validation — verify no regressions |

---

## Commands to Remember

```bash
# Activate environment
source venv/bin/activate

# Build engine
./build_safe.sh

# Quick test with python-chess board (once written)
python3 selfplay_chess.py --engine-a ./mantis --engine-b ./mantis_baseline \
  --games 20 --movetime 2000 --concurrency 1

# Install cutechess-cli (Arch Linux)
sudo pacman -S cutechess-cli

# SPRT with cutechess-cli
cutechess-cli -engine cmd=./mantis -engine cmd=./mantis_baseline \
  -each tc=3+0 -games 100 -concurrency 4 -openings file=openings.epd format=epd

# Run Nevergrad tuning
python3 nevergrad_tuner.py --budget 50 --games 15 --movetime 200 --concurrency 4
```

---

## Open Questions

1. Is the divergence caused by `MinimalBoard` or `apply_move_to_board`?
2. Does the fallback bestmove logic ever trigger in practice?
3. What is the engine's true Elo with safe parameters?
4. Should we tune at 100ms (fast) or 500ms (more accurate but slower)?

---

*Created for session continuation. See you tomorrow!*
