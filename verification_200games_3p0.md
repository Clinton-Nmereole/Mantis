# Mantis Chess Engine – Extended Stability Verification Report

**Date:** 2026-05-17  
**Command:**

```bash
cutechess-cli \
  -engine cmd=./mantis proto=uci \
  -engine cmd=./mantis proto=uci \
  -each tc=3+0 -games 200 -concurrency 4 \
  -openings file=openings.epd format=epd \
  -repeat
```

**Time Control:** 3+0  
**Openings:** `openings.epd` (repeated, both colors)  
**Total Games Requested:** 200

---

## 1. Total Games Played

**200 / 200** – All requested games completed.

## 2. W-L-D Breakdown

### Aggregate (self-play perspective)

| Result            | Count   |
| ----------------- | ------- |
| Wins (Engine 1)   | 83      |
| Losses (Engine 1) | 74      |
| Draws             | 43      |
| **Total**         | **200** |

### By Color

| Side  | W   | L   | D   | Total |
| ----- | --- | --- | --- | ----- |
| White | 75  | 82  | 43  | 200   |
| Black | 82  | 75  | 43  | 200   |

_Note: Because both engines are the identical Mantis binary, every win for one engine is a loss for the other. The “White vs Black” split shows a slight edge for Black (+7), which is expected statistical noise in self-play._

## 3. Illegal Move Warnings

**Count:** 0  
No illegal-move warnings, forfeits, or engine disconnections were reported by cutechess-cli.

## 4. Crashes or Timeouts

**Crashes:** 0  
**Time Forfeits:** 0  
**Engine Disconnections:** 0

The engine remained stable across all 200 games; no process crashes or time losses occurred.

## 5. Draw Rate and Average Game Length

**Draw Rate:** 21.5 % (43 draws / 200 games)

| Draw Reason       | Count  |
| ----------------- | ------ |
| 3-fold repetition | 37     |
| Stalemate         | 6      |
| **Total Draws**   | **43** |

**Average Game Length:** Not captured in this run (no PGN output was requested).  
If needed for future runs, add `-pgnout output.pgn` to the cutechess-cli invocation.

## 6. Final Win Percentage

- **Engine 1 win %:** 41.5 % (83 / 200)
- **Engine 2 win %:** 37.0 % (74 / 200)
- **Draw %:** 21.5 %

_As expected in self-play between identical binaries, the outcome is statistically balanced around 50 % with a small LOS of 76.4 % (within noise)._

### Elo / Statistical Summary

```
Elo difference: 15.6 +/- 42.8, LOS: 76.4 %, DrawRatio: 21.5 %
SPRT: llr 0 (0.0%), lbound -inf, ubound inf
```

## 7. Run Completion Status

✅ **Completed successfully.**  
All 200 games were started and finished without interruption, engine failures, or arbiter errors.

---

## Raw cutechess-cli Output

See `/home/clinton/Developer/Odin/Mantis/cutechess_run.log` for the complete unfiltered log.
