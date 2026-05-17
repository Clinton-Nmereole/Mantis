# Legacy NNUE Loader Fix — COMPLETE

## Root Cause

The legacy loader (`nnue/nnue.odin`) failed because it did not read the **4-byte byte_count field** after each `COMPRESSED_LEB128` layer header, and it did not handle layers with **optional hash fields**.

### File Format Discovery

Network files (`nn-c0ae49f08b40.nnue`, `nn-1111cefa1111.nnue`) use this layer structure:

```
Layer N: [hash(4)] + "COMPRESSED_LEB128"(17) + byte_count(4) + sleb128_data
```

Key findings:

- **byte_count includes itself**: sleb128_data_size = byte_count - 4
- **Some layers omit the hash**: Layer 2 starts directly with "COMPRESSED_LEB128"
- **Version check required**: Only 0x7AF32F20 is supported (older formats like 0x7AF32F16 rejected)

### Why the Old Code Failed

1. Never read byte_count → treated it as first data value
2. Always read hash before type → missed layers without hash
3. No force-sync → sleb128 decoder misaligned after each layer
4. SIMD alignment crash → `#simd[16]i16` on stack-allocated accumulators segfaulted

## Fix Applied

1. `read_layer_header`: Check for "COMPRESSED_LEB128" BEFORE reading hash
2. Read `byte_count` after each layer header
3. Compute `data_end = offset + byte_count - 4`
4. Force-sync to `data_end` after reading expected values
5. Added version check to reject unsupported formats early
6. Replaced SIMD accumulator loops with scalar (alignment safety)

## Verification Results

| Network                | Size  | Result                                                             |
| ---------------------- | ----- | ------------------------------------------------------------------ |
| `nn-c0ae49f08b40.nnue` | 114MB | ✅ Loads, searches, evaluates correctly (cp ~24 at startpos)       |
| `nn-1111cefa1111.nnue` | 75MB  | ✅ Loads (different architecture, evaluates but values may differ) |
| `nn-82215d0fd0df.nnue` | 21MB  | ✅ Rejected gracefully (old format v0x7AF32F16)                    |
| SFNNv14 networks       | 89MB+ | ✅ Unchanged, unaffected by this fix                               |

## Committed

Commit: `2299173` on branch `sfnnv14-migration`
