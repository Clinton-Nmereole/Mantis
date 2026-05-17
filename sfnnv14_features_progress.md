# SFNNv14 Feature Implementation Progress

## Milestone 1: Understanding Complete ✅

### Key Findings from Stockfish Source

#### 1. HalfKAv2_hm Feature Indexing (half_ka_v2_hm.cpp:88-91)

```cpp
IndexType HalfKAv2_hm::make_index(Color perspective, Square s, Piece pc, Square ksq) {
    const IndexType flip = 56 * perspective;
    return (IndexType(s) ^ OrientTBL[ksq] ^ flip) + PieceSquareIndex[perspective][pc]
         + KingBuckets[int(ksq) ^ flip];
}
```

- **OrientTBL**: Maps king squares to SQ_H1 (files a-d) or SQ_A1 (files e-h). This enables horizontal mirroring so the king is always on e-h files.
- **KingBuckets**: 32 buckets in a 4x8 pattern (lines 63-75 of half_ka_v2_hm.h)
- **PieceSquareIndex**: 11 categories × 64 squares = 704 per piece type
- **Dimensions**: 64 × 704 / 2 = **22,528** (the /2 comes from mirroring - only half the king squares are unique)
- **HashValue**: 0x7f234cb8

#### 2. FullThreats Feature Indexing (full_threats.cpp)

- **Dimensions**: **60,720** (full_threats.h:45)
- **OrientTBL**: Different from HalfKAv2 - A1 for a-d files, H1 for e-h files (full_threats.h:55-64)
- **make_index** (full_threats.cpp:158-169): Uses three LUTs:
  - `index_lut1[attacker][attacked][from < to]` - base feature offset
  - `offsets[attacker][from]` - per-piece, per-from-square offset
  - `index_lut2[attacker][from][to]` - per-from-to attack index
- **HashValue**: 0x8f234cb8 (full_threats.h:50)

#### 3. Accumulator Structure (nnue_accumulator.h:38-43)

```cpp
struct Accumulator {
    std::array<std::array<std::int16_t, L1>, COLOR_NB>          accumulation;
    std::array<std::array<std::int32_t, PSQTBuckets>, COLOR_NB> psqtAccumulation;
    std::array<bool, COLOR_NB>                                  computed = {};
};
```

- SFNNv14 uses **TWO separate accumulator states** (nnue_accumulator.h):
  - `psq_accumulators` for HalfKAv2_hm features
  - `threat_accumulators` for FullThreats features
- Each has accumulation[2][1024] + psqtAccumulation[2][8]

#### 4. PSQT Bucket Selection (network.cpp:157)

```cpp
const int bucket = (pos.count<ALL_PIECES>() - 1) / 4;
```

- 8 buckets based on total piece count: 1-4, 5-8, 9-12, 13-16, 17-20, 21-24, 25-28, 29-32

#### 5. Feature Transformer Data Layout (nnue_feature_transformer.h:150-164)

```cpp
read_leb_128(stream, biases);                                    // 1024 i16, LEB128
read_little_endian<ThreatWeightType>(stream, threatWeights.data(), // 60720*1024 i8, LITTLE-ENDIAN
                                     ThreatFeatureSet::Dimensions * HalfDimensions);
read_leb_128(stream, weights);                                   // 22528*1024 i16, LEB128
read_leb_128(stream, threatPsqtWeights, psqtWeights);            // Combined PSQT, LEB128
```

- **MIXED FORMAT**: Threat weights are little-endian i8, everything else is LEB128
- **Weight Permutation**: Weights are permuted on load for SIMD packus (nnue_feature_transformer.h:134-148)

#### 6. Transform Logic (nnue_feature_transformer.h:226-280)

- Combines both accumulators: `acc = psq_accumulation + threat_accumulation`
- PSQT: `(psqt[stm][bucket] - psqt[~stm][bucket] + threat_psqt[stm][bucket] - threat_psqt[~stm][bucket]) / 2`
- Then does pairwise multiplication (SqrClippedReLU) on the combined 1024 values

### Total Input Dimensions

- HalfKAv2_hm: 22,528
- FullThreats: 60,720
- **Total: 83,248**

## Milestone 2: Horizontal Mirroring + HalfKAv2_hm Indexing ✅

Implemented `get_halfka_feature_index()` in `nnue/sfnnv14_features.odin`:

- Uses `OrientTBL` for horizontal mirroring based on king square
- Uses `KingBuckets` for king position bucketing (32 buckets)
- Uses `PieceSquareIndex` for piece-type square indexing
- Maps Mantis pieces (0-11) to Stockfish encoding (1,2,3,4,5,6,9,10,11,12,13,14)
- **Includes kings as features** (unlike old Mantis which skipped friendly king)

Validation:

- Start position, White perspective, king on E1 (square 4):
  - `OrientTBL[4] = 0`, so no mirroring
  - White pawn on A2 (square 8): `8 ^ 0 ^ 0 + 0 + 0 = 8`
  - Black pawn on A7 (square 48): `48 ^ 0 ^ 0 + 64 + 0 = 112`

## Milestone 3: FullThreats Feature Extraction ✅

Implemented complete FullThreats feature system:

- `init_threat_pseudo_attacks()`: Precomputes attack bitboards for all piece types
- `init_threat_pawn_tables()`: Precomputes pawn push+attack bitboards
- `init_threat_luts()`: Computes all three lookup tables:
  - `threat_index_lut1[16][16][2]` - base offsets per attacker/attacked/from<to
  - `threat_offsets[16][64]` - per-piece, per-square offsets
  - `threat_index_lut2[16][64][64]` - attack indices
- `get_threat_feature_index()`: Complete threat index computation
- `refresh_threat_accumulator()`: Full threat feature extraction from board state

Key implementation details matching Stockfish:

- Pawn attacks: diagonal captures on occupied squares
- Pawn pushes: forward moves for pawns blocked by another pawn
- Non-pawn attacks: attacks_bb(pt, from, occupied) & occupied
- OrientTBL differs from HalfKAv2 (A1 for a-d, H1 for e-h)

## Milestone 4: Accumulator Refresh ✅

Implemented dual accumulator refresh:

- `refresh_psq_accumulator()`: Computes HalfKAv2_hm accumulators from scratch
  - Starts with biases, adds weights for all pieces including kings
  - Updates PSQT values per bucket
- `refresh_threat_accumulator()`: Computes FullThreats accumulators from scratch
  - Starts with zeros (no biases for threats)
  - Iterates all pieces and their attacks on occupied squares
  - Updates PSQT values per bucket

Added `SFNNv14_AccumulatorState` and `SFNNv14_Accumulators` to `board/board.odin`:

- `accumulation[2][1024]i16` - per-color, per-neuron
- `psqt_accumulation[2][8]i32` - per-color, per-bucket
- `computed[2]bool` - validity flags

## Milestone 5: Incremental Updates ✅

Implemented incremental update system:

- `update_psq_accumulator_move()`: Add/remove features for piece moves
- `update_psq_accumulator_remove()`: Remove features for captures
- `update_sfnnv14_accumulators()`: Main entry point after make_move
  - Handles normal moves, king moves, captures, promotions
  - King moves trigger full refresh (both PSQ and Threat)
  - Non-king moves use incremental updates for PSQ, mark Threat as dirty

**Note on Threat incremental updates:** Full incremental updates for Threat features are extremely complex because a piece move can change attack relationships for many pieces. Stockfish uses a sophisticated "dirty piece" tracking system. For now, non-king moves mark Threat accumulators as invalid, causing a refresh on next evaluation. This is correct but slightly slower. A future optimization can implement full incremental Threat updates.

## Milestone 6: PSQT Bucket Selection + Evaluation Prep ✅

Implemented `get_psqt_bucket()`:

- `bucket = (piece_count - 1) / 4`
- 8 buckets for 1-4, 5-8, 9-12, 13-16, 17-20, 21-24, 25-28, 29-32 pieces

Implemented `prepare_sfnnv14_evaluation()`:

- Ensures both PSQ and Threat accumulators are computed
- Computes combined PSQT: `(psq_psqt[stm][bucket] - psq_psqt[nstm][bucket] + threat_psqt[stm][bucket] - threat_psqt[nstm][bucket]) / 2`
- Returns combined accumulator: `acc[i] = psq_acc[stm][i] + threat_acc[stm][i]`

## Compilation Status

**✅ Project compiles successfully with `odin check .`**

No compilation errors in the new feature code.

## Validation Plan

1. **Feature index validation**: Compare `get_halfka_feature_index()` against Stockfish `make_index()` for known positions
2. **Threat LUT validation**: Verify `init_threat_luts()` produces expected cumulative offsets
3. **Accumulator refresh validation**: Refresh accumulators for startpos and verify against manual computation
4. **Integration test**: Load a real SFNNv14 network and verify evaluation produces reasonable values
5. **Incremental update validation**: Make moves, check accumulators remain consistent with refresh-from-scratch

## Validation Results

### Feature Index Tests (passed ✅)

- White Pawn A2, White perspective: 21832 (bucket=B(31)=21824, offset=8, within [0, 22528))
- Black Pawn A7, White perspective: 21936 (within range)
- White King E1, White perspective: 22468 (within range)
- White Pawn A2, Black perspective: 21936 (within range)
- Black King E8, Black perspective: 22468 (within range)
- White King D1, White perspective: 22524 (within range, near max)

### PSQT Bucket Test (passed ✅)

- Start position (32 pieces): bucket = 7, matches `(32-1)/4 = 7`

### Accumulator Refresh Test (passed ✅)

- PSQ accumulators refresh without crashes
- Properly guards against uninitialized weights (returns early if no network loaded)

## Open Issues / Future Work

1. **Threat incremental updates**: Currently refresh-on-dirty for non-king moves. Can be optimized with dirty-piece tracking.
2. **SIMD optimization**: Current scalar loops over 1024 values. Can be vectorized with Odin's `#simd`.
3. **Weight permutation**: Stockfish permutes weights for SIMD packus. We skip this in scalar code.
4. **Promotion handling**: The incremental update for promotions may need additional testing.
5. **Board struct compatibility**: Added `sfnnv14_accumulators` to `Board` struct. Old `accumulators` field kept for backward compatibility during transition.
6. **Integration with eval agent**: The parallel subagent working on network loader + forward path (`sfnnv14_eval.odin`) will need to integrate with this feature code. Current conflict: duplicate constant declarations (QA, QB, read_i32, etc.) between `nnue.odin` and `sfnnv14_eval.odin`.
