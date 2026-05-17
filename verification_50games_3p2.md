# Mantis Chess Engine — Extended Stability Verification

**Date:** 2026-05-17
**Time Control:** 3+2 (3 minutes base + 2 second increment)
**Games:** 50
**Concurrency:** 2
**Openings:** openings.epd (EPD format, -repeat enabled)
**Binary:** ./mantis (UCI protocol)

---

## 1. Total Games Played

**50 / 50 games completed successfully.**

## 2. Time Forfeits

**0 time forfeits.** No engine lost on time in any game.

## 3. Connection Stalls or Crashes

**0 stalls, 0 crashes, 0 disconnections.**
No abnormal terminations, connection errors, or engine crashes were observed.

## 4. W-L-D Breakdown

### By Color (White vs Black)

| Result     | Count  | Percentage |
| ---------- | ------ | ---------- |
| White wins | 33     | 66.0%      |
| Black wins | 15     | 30.0%      |
| Draws      | 2      | 4.0%       |
| **Total**  | **50** | **100%**   |

### Termination Reasons

| Reason                    | Count |
| ------------------------- | ----- |
| White mates               | 33    |
| Black mates               | 15    |
| Draw by 3-fold repetition | 2     |

### Engine1 vs Engine2 (Mantis vs Mantis)

Since both engines are identical binaries, the first-listed engine scored:

- **Wins:** 26
- **Losses:** 22
- **Draws:** 2
- **Score:** 27.0 / 50 (54.0%)

**Elo difference:** 27.9 ± 97.0, LOS: 71.8%, DrawRatio: 4.0%

### Per-Side Breakdown

| Side           | Wins | Losses | Draws | Games | Score |
| -------------- | ---- | ------ | ----- | ----- | ----- |
| Mantis (White) | 18   | 7      | 0     | 25    | 72.0% |
| Mantis (Black) | 8    | 15     | 2     | 25    | 36.0% |

## 5. All 50 Games Completed Successfully

**Yes.** Every scheduled game started and finished with a clean, adjudicated result. No games were interrupted, abandoned, or terminated abnormally.

## 6. Issues Found

**None.** No time forfeits, crashes, stalls, illegal moves, or connection failures occurred in any of the 50 games.

---

## Verdict

✅ **PASSED** — Mantis demonstrates stable execution under 3+2 increment time control across 50 self-play games with no reliability issues detected.

---

## Raw cutechess-cli Log

```
Started game 2 of 50 (Mantis vs Mantis)
Started game 1 of 50 (Mantis vs Mantis)
Finished game 1 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 1 - 0 - 0  [1.000] 1
Started game 3 of 50 (Mantis vs Mantis)
Finished game 2 (Mantis vs Mantis): 1/2-1/2 {Draw by 3-fold repetition}
Score of Mantis vs Mantis: 1 - 0 - 1  [0.750] 2
Started game 4 of 50 (Mantis vs Mantis)
Finished game 3 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 1 - 1 - 1  [0.500] 3
Started game 5 of 50 (Mantis vs Mantis)
Finished game 4 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 1 - 2 - 1  [0.375] 4
Started game 6 of 50 (Mantis vs Mantis)
Finished game 5 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 2 - 2 - 1  [0.500] 5
Started game 7 of 50 (Mantis vs Mantis)
Finished game 6 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 2 - 3 - 1  [0.417] 6
Started game 8 of 50 (Mantis vs Mantis)
Finished game 7 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 3 - 3 - 1  [0.500] 7
Started game 9 of 50 (Mantis vs Mantis)
Finished game 8 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 3 - 4 - 1  [0.438] 8
Started game 10 of 50 (Mantis vs Mantis)
Finished game 9 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 4 - 4 - 1  [0.500] 9
Started game 11 of 50 (Mantis vs Mantis)
Finished game 10 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 5 - 4 - 1  [0.550] 10
Started game 12 of 50 (Mantis vs Mantis)
Finished game 11 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 5 - 5 - 1  [0.500] 11
Started game 13 of 50 (Mantis vs Mantis)
Finished game 12 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 5 - 6 - 1  [0.458] 12
Started game 14 of 50 (Mantis vs Mantis)
Finished game 13 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 6 - 6 - 1  [0.500] 13
Started game 15 of 50 (Mantis vs Mantis)
Finished game 15 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 7 - 6 - 1  [0.536] 14
Started game 16 of 50 (Mantis vs Mantis)
Finished game 14 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 8 - 6 - 1  [0.567] 15
Started game 17 of 50 (Mantis vs Mantis)
Finished game 16 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 9 - 6 - 1  [0.594] 16
Started game 18 of 50 (Mantis vs Mantis)
Finished game 17 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 10 - 6 - 1  [0.618] 17
Started game 19 of 50 (Mantis vs Mantis)
Finished game 18 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 10 - 7 - 1  [0.583] 18
Started game 20 of 50 (Mantis vs Mantis)
Finished game 19 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 10 - 8 - 1  [0.553] 19
Started game 21 of 50 (Mantis vs Mantis)
Finished game 20 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 10 - 9 - 1  [0.525] 20
Started game 22 of 50 (Mantis vs Mantis)
Finished game 22 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 10 - 10 - 1  [0.500] 21
Started game 23 of 50 (Mantis vs Mantis)
Finished game 21 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 11 - 10 - 1  [0.523] 22
Started game 24 of 50 (Mantis vs Mantis)
Finished game 24 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 12 - 10 - 1  [0.543] 23
Started game 25 of 50 (Mantis vs Mantis)
Finished game 23 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 13 - 10 - 1  [0.563] 24
Started game 26 of 50 (Mantis vs Mantis)
Finished game 25 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 14 - 10 - 1  [0.580] 25
Started game 27 of 50 (Mantis vs Mantis)
Finished game 26 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 14 - 11 - 1  [0.558] 26
Started game 28 of 50 (Mantis vs Mantis)
Finished game 27 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 15 - 11 - 1  [0.574] 27
Started game 29 of 50 (Mantis vs Mantis)
Finished game 28 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 15 - 12 - 1  [0.554] 28
Started game 30 of 50 (Mantis vs Mantis)
Finished game 29 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 16 - 12 - 1  [0.569] 29
Started game 31 of 50 (Mantis vs Mantis)
Finished game 30 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 16 - 13 - 1  [0.550] 30
Started game 32 of 50 (Mantis vs Mantis)
Finished game 31 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 17 - 13 - 1  [0.565] 31
Started game 33 of 50 (Mantis vs Mantis)
Finished game 32 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 18 - 13 - 1  [0.578] 32
Started game 34 of 50 (Mantis vs Mantis)
Finished game 34 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 18 - 14 - 1  [0.561] 33
Started game 35 of 50 (Mantis vs Mantis)
Finished game 33 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 18 - 15 - 1  [0.544] 34
Started game 36 of 50 (Mantis vs Mantis)
Finished game 35 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 19 - 15 - 1  [0.557] 35
Started game 37 of 50 (Mantis vs Mantis)
Finished game 36 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 19 - 16 - 1  [0.542] 36
Started game 38 of 50 (Mantis vs Mantis)
Finished game 37 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 20 - 16 - 1  [0.554] 37
Started game 39 of 50 (Mantis vs Mantis)
Finished game 38 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 20 - 17 - 1  [0.539] 38
Started game 40 of 50 (Mantis vs Mantis)
Finished game 40 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 20 - 18 - 1  [0.526] 39
Started game 41 of 50 (Mantis vs Mantis)
Finished game 39 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 20 - 19 - 1  [0.512] 40
Started game 42 of 50 (Mantis vs Mantis)
Finished game 42 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 21 - 19 - 1  [0.524] 41
Started game 43 of 50 (Mantis vs Mantis)
Finished game 41 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 22 - 19 - 1  [0.536] 42
Started game 44 of 50 (Mantis vs Mantis)
Finished game 44 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 22 - 20 - 1  [0.523] 43
Started game 45 of 50 (Mantis vs Mantis)
Finished game 43 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 23 - 20 - 1  [0.534] 44
Started game 46 of 50 (Mantis vs Mantis)
Finished game 45 (Mantis vs Mantis): 1-0 {White mates}
Score of Mantis vs Mantis: 24 - 20 - 1  [0.544] 45
Started game 47 of 50 (Mantis vs Mantis)
Finished game 46 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 25 - 20 - 1  [0.554] 46
Started game 48 of 50 (Mantis vs Mantis)
Finished game 47 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 25 - 21 - 1  [0.543] 47
Started game 49 of 50 (Mantis vs Mantis)
Finished game 49 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 25 - 22 - 1  [0.531] 48
Started game 50 of 50 (Mantis vs Mantis)
Finished game 48 (Mantis vs Mantis): 0-1 {Black mates}
Score of Mantis vs Mantis: 26 - 22 - 1  [0.541] 49
Finished game 50 (Mantis vs Mantis): 1/2-1/2 {Draw by 3-fold repetition}
Score of Mantis vs Mantis: 26 - 22 - 2  [0.540] 50
...      Mantis playing White: 18 - 7 - 0  [0.720] 25
...      Mantis playing Black: 8 - 15 - 2  [0.360] 25
...      White vs Black: 33 - 15 - 2  [0.680] 50
Elo difference: 27.9 +/- 97.0, LOS: 71.8 %, DrawRatio: 4.0 %
SPRT: llr 0 (0.0%), lbound -inf, ubound inf

Player: Mantis
   "Draw by 3-fold repetition": 2
   "Loss: Black mates": 7
   "Loss: White mates": 15
   "Win: Black mates": 8
   "Win: White mates": 18
Player: Mantis
   "Draw by 3-fold repetition": 2
   "Loss: Black mates": 8
   "Loss: White mates": 18
   "Win: Black mates": 7
   "Win: White mates": 15
Finished match
```
