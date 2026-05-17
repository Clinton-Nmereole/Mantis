# SFNNv14 Migration Plan for Mantis

## Current State (Committed)

- **Commit:** `9e06449` — Pre-SFNNv14 checkpoint
- **Architecture:** HalfKAv2_hm-1024x2-8-32-1 (Old Stockfish ~SFNNv5)
- **Network format:** 45056 -> 1024 -> 32 -> 32 -> 1
- **Works with:** `nn-c0ae49f08b40.nnue`, `nn-1111cefa1111.nnue`, `nn-82215d0fd0df.nnue`

## Target State

- **Architecture:** SFNNv14 (Stockfish 14+)
- **Network format:** 45056+ -> 1024 -> (31+1) -> [62 -> 32 -> 1] x 8 layer stacks
- **Goal:** Load `nn-7bf13f9655c8.nnue` and other modern networks

---

## Architecture Differences

### Current Mantis

```
Features: HalfKAv2_hm (45056 inputs)
Transformer: 45056 -> 1024 (i16 accumulators)
Layer 1: 1024 -> 32 (dense, i8 weights, i32 biases)
Activation: ClippedReLU(0, 255)
Layer 2: 32 -> 32 (dense, i8 weights, i32 biases)
Activation: ClippedReLU(0, 255)
Output: 32 -> 1 (i8 weight, i32 bias)
Scale: /16 -> centipawns
```

### SFNNv14

```
Features: HalfKAv2_hm (45056) + FullThreats (~10,000+)
Transformer: 45056+ -> 1024 (i16 accumulators) + 1024 PSQT (i32)
Layer 0 (fc_0): Sparse 1024 -> 31+1 (i8 weights, i32 biases)
Activation 1: SqrClippedReLU on first 31 outputs
Activation 2: ClippedReLU on first 31 outputs
Concatenate: 31 (squared) + 31 (clipped) = 62 inputs
Forward path: fc_0_out[31] * scale -> directly added to final output
Layer 1 (fc_1): 62 -> 32 (i8 weights, i32 biases)
Activation: ClippedReLU
Layer 2 (fc_2): 32 -> 1 (i8 weight, i32 bias)
LayerStacks: 8 networks for different piece counts (0-4, 5-8, ..., 29-32 pieces)
Scale: /OutputScale -> centipawns
```

---

## Implementation Steps

### Phase 1: Network Loader Rewrite (Day 1)

**Goal:** Parse the SFNNv14 network file format

**Changes:**

- Rewrite `nnue/nnue.odin` `init_nnue()` to read SFNNv14 format
- Add `SqrClippedReLU` and dual-activation logic
- Add forward path computation
- Add layer stack selection (8 networks)
- Keep backward compatibility or create separate loader

**Test:** Load `nn-7bf13f9655c8.nnue` without crashing

### Phase 2: Feature Transformer Updates (Day 2)

**Goal:** Support PSQT buckets and FullThreats

**Changes:**

- Add `PSQT_BUCKETS :: 8` constant
- Add `LayerStacks :: 8` constant
- Update accumulator to store PSQT values alongside hidden activations
- Add threat detection for FullThreats features
- Update `update_accumulators` in `search/search.odin`

**Test:** Verify accumulator values match known positions

### Phase 3: FullThreats Feature Extraction (Day 2-3)

**Goal:** Generate correct feature indices for threat patterns

**Changes:**

- Add `full_threats.odin` with threat detection logic
- Implement `pawn_single_push_bb`, `pawn_attacks_bb`
- Add threat feature indices to the accumulator update path
- Update `get_feature_index` to include threat features

**Test:** Compare feature counts against Stockfish for test positions

### Phase 4: Evaluation Rewrite (Day 3-4)

**Goal:** Implement SFNNv14 forward pass

**Changes:**

- Rewrite `nnue.evaluate()`:
  1. Select layer stack based on piece count
  2. Run feature transformer (get hidden + PSQT)
  3. Run fc_0 (sparse affine)
  4. Apply SqrClippedReLU + ClippedReLU
  5. Concatenate into 62-element buffer
  6. Run fc_1 (62 -> 32)
  7. Apply ClippedReLU
  8. Run fc_2 (32 -> 1)
  9. Add forward path contribution
  10. Scale to centipawns

**Test:** Match Stockfish's evaluation for 100 test positions

### Phase 5: Integration & Regression Testing (Day 4-5)

**Goal:** Ensure no performance regressions

**Changes:**

- Update UCI `EvalFile` default to new network
- Add bench command for reproducible node counts
- Run perft to verify move generation still works
- Run selfplay to verify no illegal moves
- Test at multiple time controls

### Phase 6: Performance Optimization (Day 5-7)

**Goal:** Match or exceed current NPS

**Changes:**

- SIMD vectorize the new layers
- Optimize sparse matrix multiplication
- Cache layer stack selection
- Profile and optimize hot paths

---

## Risk Mitigation

1. **Rollback:** Current state committed at `9e06449`
2. **Incremental:** Each phase is independently testable
3. **Dual support:** Can keep old loader alongside new one
4. **Validation:** Perft + selfplay at each phase

## Success Criteria

- [ ] `nn-7bf13f9655c8.nnue` loads successfully
- [ ] Evaluation matches Stockfish within ±10cp for 100 positions
- [ ] Selfplay shows improved strength (fewer `e2e3` openings)
- [ ] NPS is within 20% of current performance
- [ ] 0 illegal moves in 100+ games
- [ ] No time forfeits at 3+2

---

## Notes

- SFNNv14 networks are CC0 licensed (free to use)
- Training data not needed — using pre-trained networks
- The main risk is implementation bugs in the evaluation function
- Feature extraction bugs are the hardest to detect (silent wrong eval)
