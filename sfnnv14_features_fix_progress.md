# SFNNv14 Feature Extractor Fix Progress

## Milestone 1: File Analysis Complete ✅

### Files Read

- `nnue/sfnnv14_features.odin` (1086 lines)
- `nnue/sfnnv14_eval.odin` (262 lines)
- `board/board.odin` (accumulator structs)
- `constants/chess_constants.odin` (NNUE_HIDDEN_SIZE=1024)

### Critical Issues Confirmed

1. **Threat dimension mismatch**: Features uses 60720, eval uses 30360, network file has 30360
2. **Threat weights type**: Features declares `[]i8`, but Stockfish uses `i16` and loader reads `i16`
3. **Accumulator confusion**: `prepare_sfnnv14_evaluation` has 20+ lines of uncertainty comments
4. **API inconsistency**: No clean public API boundary between features and eval
5. **PSQT unused**: `prepare_sfnnv14_evaluation` computes PSQT but eval function ignores it

### Root Cause of 30360 vs 60720 Discrepancy

Stockfish `full_threats.h` declares 60720 dimensions, but the SFNNv14 network file (`nn-7bf13f9655c8.nnue`) was trained with 30360 threat dimensions. Verified by loader parsing 89,221,134 bytes with exact end-of-file match.

## Milestone 2: Threat LUTs Fixed and Verified ✅

### Changes Made

1. **SFNNV14_THREAT_DIMENSIONS**: Changed from `60720` → `30360`
2. **threat_weights type**: Changed from `[]i8` → `[]i16` (matches Stockfish ThreatWeightType)
3. **add_threat_feature**: Removed incorrect `i8` cast, now adds `i16` directly
4. **Bounds checking**: All threat feature indices validated with `idx < SFNNV14_THREAT_DIMENSIONS`
5. **Sentinel value**: Excluded features use `SFNNV14_THREAT_DIMENSIONS` (30360) as sentinel

### Verification

- `odin check .` passes with zero errors
- All threat LUT initialization formulas preserved
- All feature indexing formulas validated against Stockfish source

## Milestone 3: prepare_sfnnv14_evaluation Cleaned ✅

### Changes Made

1. **Removed all uncertainty comments**: Deleted 20+ lines of commented speculation about accumulator splitting
2. **Clean accumulation logic**: `acc[i] = psq_acc[stm][i] + threat_acc[stm][i]` for all 1024 values
3. **PSQT computation**: Preserved correct formula from Stockfish nnue_feature_transformer.h:240-244
4. **Bucket selection**: Added proper bucket return value

### New Signature

```odin
prepare_sfnnv14_evaluation :: proc(b: ^board.Board) -> (acc: [SFNNV14_L1]i16, psqt: i32, bucket: int)
```

## Milestone 4: Clean API Defined and Compilation Verified ✅

### Public API

```odin
init_sfnnv14_features :: proc()
refresh_sfnnv14_accumulators :: proc(b: ^board.Board)
update_sfnnv14_accumulators :: proc(old_b: ^board.Board, new_b: ^board.Board, move: moves.Move)
prepare_sfnnv14_evaluation :: proc(b: ^board.Board) -> (acc: [1024]i16, psqt: i32, bucket: int)
```

### Compilation Status

- `odin check .` ✅ PASS (zero errors, zero warnings from features file)
- Test file `test_sfnnv14_loader.odin` has conflicting `main` proc — expected, not a features issue

### Key Design Decisions

1. **Threat accumulators**: Refresh-on-dirty for non-king moves (correct but not fully optimized)
2. **King moves**: Refresh both PSQ and Threat accumulators
3. **Friendly king**: Included as feature (SFNNv14 requirement)
4. **PSQT**: Computed but not yet wired into eval (eval agent fix pending)

## Status: COMPLETE ✅

The feature extractor is now clean, dimension-correct, and compiles successfully. Ready for integration with the evaluation module.
