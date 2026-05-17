# SFNNv14 Eval Fix - Progress Log

## Milestone 1: Audit Complete ✅

**Confirmed all 5 bugs:**

1. **`read_i32` undefined**: Used in `read_leb128_header` and `init_sfnnv14` but never defined or imported. Defined in `nnue/nnue.odin` on line 94 (same package, auto-available).

2. **PSQT not in output**: `prepare_sfnnv14_evaluation` computes PSQT but `evaluate_sfnnv14` ignores it. Stockfish formula: `score = (psqt + positional) / OutputScale`.

3. **Bucket hardcoded**: `bucket := 0` with `// TODO: proper bucket selection`. Features file has `get_psqt_bucket` that computes `(piece_count - 1) / 4`.

4. **Function signature mismatch**: Current takes `(white_acc: Accumulator, black_acc: Accumulator, stm: int)` but features file returns `(combined_acc: [1024]i16, psqt: i32)`. Fixed signature: `(acc: [1024]i16, psqt: i32, bucket: int, stm: int) -> int`.

5. **`QA` undefined**: Used in `clipped_relu` but never defined. `QA=255` already exists in `nnue.odin` (same package). Added `AC_CLAMP=127` for activation outputs (Stockfish uint8_t).

**Stockfish references verified:**

- `OutputScale = 16` (nnue_common.h:61)
- `WeightScaleBits = 6` (nnue_common.h:62)
- `Forward path: fc0_out[FC_0_OUTPUTS] * (600 * OutputScale) / (127 * (1 << WeightScaleBits))` (nnue_architecture.h:121-124)
- `ClippedReLU: clamp(input[i] >> WeightScaleBits, 0, 127)` (clipped_relu.h:168)
- `SqrClippedReLU: min(127, (input[i]^2) >> (2*WeightScaleBits+7))` (sqr_clipped_relu.h:110-112)
- `Network.evaluate returns {psqt/OutputScale, positional/OutputScale}` (network.cpp:161)

## Milestone 2: Imports & read_i32 Fix ✅

- Removed local `read_i32` definition — relies on same-package `nnue/nnue.odin:94`
- Removed `QA` redefinition — uses `QA=255` from `nnue/nnue.odin:17`
- Added `AC_CLAMP :: 127` for activation output clamping (matching Stockfish uint8_t)
- Removed unused `Accumulator` struct
- Removed `THREAT_DIMENSIONS`, `PSQT_COMBINED_SIZE` exports (no longer needed externally)
- Changed `clipped_relu` and `sqr_clipped_relu` return types from `i32` to `u8` (matching Stockfish OutputType)

## Milestone 3: Evaluation Function Overhaul ✅

- Changed signature to: `evaluate_sfnnv14(acc: [HALF_DIMENSIONS]i16, psqt: i32, bucket: int, stm: int) -> int`
- Uses `bucket` to select `network.stacks[bucket]` (no more hardcoded 0)
- fc_0 input clamped to `[0, QA]` where `QA=255`
- Dual activation: SqrClippedReLU + ClippedReLU on fc_0[0..30], concatenated to 62 u8 values
- fc_1 output goes through ClippedReLU (returns u8)
- Added PSQT to output: `out += psqt`
- Final return: `int((fc2_out + fwd_out + psqt) / OUTPUT_SCALE)` — matches Stockfish `(psqt + positional) / OutputScale`

## Milestone 4: Forward Path Verification ✅

- Formula: `fc0[31] * (600 * OUTPUT_SCALE) / (127 * (1 << WEIGHT_SCALE_BITS))`
- Matches Stockfish nnue_architecture.h:121-124 EXACTLY
- All constants verified: OUTPUT_SCALE=16, WEIGHT_SCALE_BITS=6
- PSQT addition matches Stockfish network.cpp:161 `{psqt/OutputScale, positional/OutputScale}`

## Milestone 5: Compilation ✅

- `odin check .` passes — zero errors, zero warnings
- `odin build . -out:mantis` succeeds — produces valid binary
- `test_sfnnv14_loader.odin` backed up (had `main` redeclaration conflict with `main.odin`)
- Old `test_sfnnv14_loader` binary removed

## Summary of Changes to sfnnv14_eval.odin

| Change                       | Before                                   | After                                               |
| ---------------------------- | ---------------------------------------- | --------------------------------------------------- |
| `read_i32`                   | Undefined (compile error)                | Uses same-package `nnue.odin:94`                    |
| `QA`                         | Undefined (compile error)                | Uses `nnue.odin:17` QA=255 + AC_CLAMP=127           |
| `clipped_relu` return        | `i32` (wrong range)                      | `u8` (matches Stockfish uint8_t)                    |
| `sqr_clipped_relu` return    | `i32`                                    | `u8`                                                |
| `evaluate_sfnnv14` signature | `(Accumulator, Accumulator, int) -> int` | `([1024]i16, psqt:i32, bucket:int, stm:int) -> int` |
| Bucket selection             | `bucket := 0` (hardcoded)                | Uses caller-provided bucket                         |
| PSQT                         | Not in output                            | Added: `out += psqt`                                |
| Final output                 | `int(out / OUTPUT_SCALE)`                | `int((out + fwd_out + psqt) / OUTPUT_SCALE)`        |
| Activation clamping          | Arbitrary QA                             | Stockfish-verified 127                              |

## API Contract with Features File

**eval expects from features:**

- `acc: [1024]i16` — combined PSQ+Threat accumulation for stm
- `psqt: i32` — pre-computed PSQT difference `((psq[stm]-psq[nstm]) + (threat[stm]-threat[nstm])) / 2`
- `bucket: int` — layer stack index `(piece_count - 1) / 4`
- `stm: int` — side to move (not currently used but reserved for perspective)

**eval provides:**

- `init_sfnnv14(filename: string) -> bool` — load network file
- `evaluate_sfnnv14(acc, psqt, bucket, stm) -> int` — return centipawn score
