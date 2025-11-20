# Mantis - Next Steps Roadmap

## Quick Wins (1-2 hours each)

### 1. Aspiration Windows ⭐⭐⭐⭐⭐
**Impact**: 10-20% node reduction, +20-40 Elo  
**Complexity**: Low  
**Implementation**:
```odin
// In iterative deepening
window := 50
alpha := prev_score - window
beta := prev_score + window
score := negamax(b, alpha, beta, depth)

// If outside window, re-search with full window
if score <= alpha || score >= beta {
    score = negamax(b, -INF, INF, depth)
}
```

### 2. Killer Heuristic ⭐⭐⭐⭐⭐
**Impact**: Better move ordering, +30-50 Elo  
**Complexity**: Low  
**Implementation**:
- Track 2 killer moves per ply
- Score killers between hash move and captures
- Update on beta cutoffs from non-captures

### 3. Check Extensions ⭐⭐⭐⭐
**Impact**: Better tactics, +20-30 Elo  
**Complexity**: Low  
**Implementation**:
```odin
if in_check {
    depth += 1  // Extend by 1 ply when in check
}
```

## Medium Improvements (4-8 hours each)

### 4. History Heuristic ⭐⭐⭐⭐
**Impact**: +30-50 Elo  
**Complexity**: Medium  
**Implementation**:
- Track `history[piece][to_square]` counters
- Increment on beta cutoffs
- Use for move ordering after killers

### 5. Better LMR Formula ⭐⭐⭐⭐
**Impact**: +30-50 Elo  
**Complexity**: Low  
**Implementation**:
```odin
import "core:math"
reduction := int(math.log(f64(depth)) * math.log(f64(move_number)) / 2.5)
```

### 6. Multi-PV ⭐⭐⭐
**Impact**: Analysis feature, no Elo gain  
**Complexity**: Medium  
**Use Case**: Engine analysis, debugging

## Major Projects (16-40 hours each)

### 7. Singular Extensions ⭐⭐⭐⭐⭐
**Impact**: +40-60 Elo  
**Complexity**: High  
**When**: After killers + history

### 8. Lazy SMP (Parallel Search) ⭐⭐⭐⭐⭐
**Impact**: +150-200 Elo (8 cores)  
**Complexity**: Very High  
**Implementation**:
- Spawn helper threads
- Each searches root position
- Share transposition table
- Requires thread safety

### 9. Syzygy Tablebases ⭐⭐⭐
**Impact**: Perfect endgames, +50-100 Elo in endgames  
**Complexity**: High  
**Requires**: External tablebase files

### 10. Automated Tuning ⭐⭐⭐⭐
**Impact**: +50-100 Elo  
**Complexity**: High  
**Methods**: SPSA, Genetic Algorithms  
**What to Tune**: Piece values, LMR parameters, NMP reduction, etc.

## Recommended Order

**Phase 1: Quick Wins (Weekend)**
1. Aspiration Windows
2. Killer Heuristic  
3. Check Extensions

**Phase 2: Refinement (Week)**
4. History Heuristic
5. Better LMR Formula

**Phase 3: Advanced (Month)**
6. Singular Extensions
7. Multi-PV
8. Automated Tuning

**Phase 4: Scaling (Month+)**
9. Lazy SMP
10. Syzygy Tablebases

## Testing Strategy

After each feature:
1. **Build**: `odin build . -out:mantis`
2. **Quick Test**: Fixed depth search
3. **Gauntlet**: 100 games vs previous version
4. **Verify**: No regressions, Elo gain

Use **Cute Chess CLI** for automated testing:
```bash
cutechess-cli -engine cmd=./mantis_old -engine cmd=./mantis_new \
  -each tc=40/60 -rounds 100 -pgnout games.pgn
```

## Current Bottlenecks

1. **Move Ordering**: Killers + History will help most
2. **Search Depth**: Aspiration + Better LMR will help
3. **Speed**: SMP will multiply by core count
4. **Accuracy**: Singular extensions + tuning

## Resources

- **Chess Programming Wiki**: https://www.chessprogramming.org/
- **TalkChess Forum**: http://talkchess.com/forum3/
- **CCRL Testing**: http://ccrl.chessdom.com/
- **Stockfish Source**: Reference implementation

## Summary

Focus on **Phase 1** first for maximum impact with minimum effort. The trio of Aspiration Windows + Killers + Check Extensions can easily add **+100 Elo** in a weekend of work.
