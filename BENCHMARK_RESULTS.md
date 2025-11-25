# NNUE Benchmark Results

## Purpose
Track NNUE performance improvements from SIMD optimization.

## Baseline (Current Scalar Implementation)

Run `./run_benchmark.sh` and paste results here:

```
Date: 
System: 
Compiler: Odin with -o:speed -no-bounds-check -disable-assert

--- Benchmark 1: Accumulator Update ---
[Paste results]

--- Benchmark 2: Full Evaluation ---
[Paste results]

--- Benchmark 3: Batch Evaluation ---
[Paste results]
```

## After SIMD Implementation

```
Date: 
Expected improvements:
- Accumulator updates: 10-15x faster
- Full evaluation: 3-5x faster
- Batch evaluation: 3-5x faster

[Paste results after SIMD]
```

## Speedup Calculations

| Operation | Baseline | SIMD | Speedup |
|-----------|----------|------|---------|
| Accumulator update | | | |
| Single evaluation | | | |
| Batch (1000 pos) | | | |

## Notes
- Baseline measurements taken before SIMD
- SIMD measurements should show 3-5x overall speedup
- Target: 150+ Elo gain from faster evaluation
