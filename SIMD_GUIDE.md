# SIMD Programming Guide for Mantis NNUE

## What is SIMD?

**SIMD** = Single Instruction, Multiple Data

Instead of processing one value at a time (scalar), SIMD processes multiple values simultaneously using special CPU instructions.

**Example**:
```odin
// Scalar - processes 1 value per operation
for i in 0 ..< 16 {
    result[i] = a[i] + b[i]  // 16 operations
}

// SIMD - processes 16 values in one operation
result_vec = simd.add_i16x16(a_vec, b_vec)  // 1 operation!
```

---

## Why SIMD for NNUE?

NNUE operations are **perfectly suited** for SIMD:
- Add/subtract thousands of i16 values (accumulator updates)
- Dot products (layer computations)
- Element-wise operations (ReLU activation)

**Current bottleneck**: Accumulator update processes 2,048 values one at a time.  
**With SIMD**: Process 16 values simultaneously → **16x faster** (theoretical)

---

## SIMD Vector Types in Odin

Odin's `core:simd` package provides vector types:

```odin
import "core:simd"

// Common types for NNUE
i16x16  // 16 signed 16-bit integers (256 bits total - AVX2)
i32x8   // 8 signed 32-bit integers (256 bits total)
i8x32   // 32 signed 8-bit integers (256 bits total)
```

**Why i16x16?**
- NNUE accumulator values are `i16`
- AVX2 can process 16× i16 in one instruction
- Perfect match for our `[2048]i16` accumulator

---

## Basic SIMD Operations

### 1. Load and Store

```odin
import "core:simd"

// Assume we have an aligned array
values: [16]i16 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

// Load 16 values into a SIMD register
vec := simd.lanes_eq(i16, 16, values[:])

// Store back to memory
result: [16]i16
simd.lanes_store(vec, result[:])
```

### 2. Arithmetic Operations

```odin
a := simd.lanes_eq(i16, 16, [16]i16{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})
b := simd.lanes_eq(i16, 16, [16]i16{16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1})

// Add all 16 pairs simultaneously
sum := a + b  // SIMD addition

// Subtract
diff := a - b  // SIMD subtraction

// Multiply
product := a * b  // SIMD multiplication
```

### 3. Horizontal Sum (Reduce)

```odin
// Sum all lanes in a vector
vec := simd.lanes_eq(i16, 16, [16]i16{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})

total := simd.reduce_add(vec)  // Returns sum of all 16 values
// total = 136
```

---

## Applying SIMD to NNUE

### Current Scalar Code (Slow)

From `nnue/nnue.odin` line 490:

```odin
// Remove feature from source (scalar - one value at a time)
for i in 0 ..< HIDDEN_SIZE {
    acc.values[i] -= current_network.feature_weights[idx_rem * HIDDEN_SIZE + i]
}
```

**Cost**: 2,048 operations (one per i16)

### SIMD Version (Fast)

```odin
import "core:simd"

// Process 16 values per iteration
for i := 0; i < HIDDEN_SIZE; i += 16 {
    // Load 16 accumulator values
    acc_vec := simd.lanes_eq(i16, 16, acc.values[i:i+16])
    
    // Load 16 weight values
    weights_vec := simd.lanes_eq(i16, 16, 
        current_network.feature_weights[idx_rem * HIDDEN_SIZE + i : idx_rem * HIDDEN_SIZE + i + 16])
    
    // Subtract all 16 pairs simultaneously
    result_vec := acc_vec - weights_vec
    
    // Store back to accumulator
    simd.lanes_store(result_vec, acc.values[i:i+16])
}
```

**Cost**: 128 operations (2048 / 16) → **16x reduction!**

---

## Memory Alignment

SIMD operations are **fastest** with aligned memory.

### What is Alignment?

Memory alignment means data starts at addresses divisible by a specific number (16, 32, 64 bytes).

**Example**:
```
Aligned to 32 bytes:   Address 0x1000 ✓
Not aligned:           Address 0x1003 ✗
```

### Aligning Arrays in Odin

```odin
// Force 32-byte alignment for SIMD
#align(32)
accumulator_values: [2048]i16

// Or use allocator with alignment
aligned_data := make([]i16, 2048, allocator, alignment = 32)
```

**Why it matters**:
- Aligned loads/stores: 1 cycle
- Unaligned loads/stores: 3-5 cycles
- **For NNUE**: Align accumulator and weight arrays

---

## ReLU Activation with SIMD

Current scalar ReLU (Layer 1):

```odin
for i in 0 ..< HIDDEN_SIZE {
    val := input[i]
    if val < 0 {val = 0}
    if val > QA {val = QA}
    // Use val...
}
```

SIMD ReLU:

```odin
zero_vec := simd.lanes_eq(i16, 16, [16]i16{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0})
qa_vec := simd.lanes_eq(i16, 16, [16]i16{QA,QA,QA,QA,QA,QA,QA,QA,QA,QA,QA,QA,QA,QA,QA,QA})

for i := 0; i < HIDDEN_SIZE; i += 16 {
    val_vec := simd.lanes_eq(i16, 16, input[i:i+16])
    
    // Clamp to [0, QA]
    val_vec = simd.max(val_vec, zero_vec)  // max(val, 0)
    val_vec = simd.min(val_vec, qa_vec)     // min(val, QA)
    
    // Use val_vec for computation...
}
```

---

## Dot Product with SIMD

Layer 1 computation (1024 inputs → 32 outputs):

**Scalar**:
```odin
for j in 0 ..< 32 {
    for i in 0 ..< HIDDEN_SIZE {
        l1_out[j] += i32(input[i]) * i32(weights[i * 32 + j])
    }
}
```

**SIMD** (4x faster):
```odin
for j in 0 ..< 32 {
    // Accumulate in SIMD register
    sum_vec := simd.lanes_eq(i32, 8, [8]i32{0,0,0,0,0,0,0,0})
    
    for i := 0; i < HIDDEN_SIZE; i += 8 {
        input_vec := simd.cast(i32x8, simd.lanes_eq(i16, 8, input[i:i+8]))
        weights_vec := simd.cast(i32x8, simd.lanes_eq(i8, 8, weights[i*32+j : i*32+j+8]))
        
        // Multiply and accumulate
        product := input_vec * weights_vec
        sum_vec = sum_vec + product
    }
    
    // Horizontal sum to get final result
    l1_out[j] = simd.reduce_add(sum_vec)
}
```

---

## Common Pitfalls

### 1. Unaligned Access
```odin
// ✗ BAD - might not be aligned
vec := simd.lanes_eq(i16, 16, array[5:21])

// ✓ GOOD - starts at aligned offset
vec := simd.lanes_eq(i16, 16, array[16:32])
```

### 2. Array Size Not Multiple of 16
```odin
// HIDDEN_SIZE = 2048 (perfect - divisible by 16)
// If size was 2047, would need special handling for last element
```

### 3. Type Mismatches
```odin
// ✗ BAD - mixing types
i16_vec := simd.lanes_eq(i16, 16, ...)
i32_vec := i16_vec  // Error!

// ✓ GOOD - explicit cast
i32_vec := simd.cast(i32x16, i16_vec)
```

---

## Performance Measurement

### Benchmark Template

```odin
import "core:time"

benchmark_simd :: proc() {
    iterations := 10000
    
    // Scalar version
    start := time.now()
    for _ in 0 ..< iterations {
        scalar_accumulator_update()
    }
    scalar_time := time.since(start)
    
    // SIMD version
    start = time.now()
    for _ in 0 ..< iterations {
        simd_accumulator_update()
    }
    simd_time := time.since(start)
    
    speedup := f64(time.duration_nanoseconds(scalar_time)) / 
               f64(time.duration_nanoseconds(simd_time))
    
    fmt.printf("Scalar: %v\n", scalar_time)
    fmt.printf("SIMD:   %v\n", simd_time)
    fmt.printf("Speedup: %.2fx\n", speedup)
}
```

---

## Practical Exercise

### Exercise 1: Vector Addition

Create `test_simd.odin`:

```odin
package main

import "core:fmt"
import "core:simd"

main :: proc() {
    // Create two arrays
    a: [16]i16 = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}
    b: [16]i16 = {16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1}
    result: [16]i16
    
    // Load into SIMD vectors
    a_vec := simd.lanes_eq(i16, 16, a[:])
    b_vec := simd.lanes_eq(i16, 16, b[:])
    
    // Add
    sum_vec := a_vec + b_vec
    
    // Store result
    simd.lanes_store(sum_vec, result[:])
    
    // Print
    fmt.println("Result:", result)
    // Expected: [17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17]
}
```

Run:
```bash
odin run test_simd.odin
```

### Exercise 2: Dot Product

```odin
package main

import "core:fmt"
import "core:simd"

dot_product_scalar :: proc(a, b: []i16) -> i32 {
    sum: i32 = 0
    for i in 0 ..< len(a) {
        sum += i32(a[i]) * i32(b[i])
    }
    return sum
}

dot_product_simd :: proc(a, b: []i16) -> i32 {
    sum_vec := simd.lanes_eq(i32, 8, [8]i32{0,0,0,0,0,0,0,0})
    
    for i := 0; i < len(a); i += 8 {
        a_i16 := simd.lanes_eq(i16, 8, a[i:i+8])
        b_i16 := simd.lanes_eq(i16, 8, b[i:i+8])
        
        // Widen to i32 for multiplication
        a_i32 := simd.widen_low(a_i16)
        b_i32 := simd.widen_low(b_i16)
        
        product := a_i32 * b_i32
        sum_vec = sum_vec + product
    }
    
    return simd.reduce_add(sum_vec)
}

main :: proc() {
    a: [16]i16 = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}
    b: [16]i16 = {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}
    
    scalar_result := dot_product_scalar(a[:], b[:])
    simd_result := dot_product_simd(a[:], b[:])
    
    fmt.printf("Scalar: %d\n", scalar_result)
    fmt.printf("SIMD:   %d\n", simd_result)
    fmt.printf("Match:  %v\n", scalar_result == simd_result)
}
```

---

## Next Steps for Mantis NNUE

### Phase 1: Accumulator Update (Week 1)
- [ ] Add SIMD imports to `nnue/nnue.odin`
- [ ] Align accumulator arrays
- [ ] Implement SIMD `update_single_accumulator`
- [ ] Implement SIMD `remove_feature`
- [ ] Benchmark: Should see 10-15x speedup

### Phase 2: Forward Pass (Week 2)
- [ ] Implement SIMD Layer 1 (1024→32)
- [ ] Implement SIMD Layer 2 (32→32)
- [ ] Implement SIMD Output Layer
- [ ] Benchmark full evaluation

### Phase 3: Testing & Integration (Week 3)
- [ ] Run Perft to verify correctness
- [ ] Test search with SIMD NNUE
- [ ] Measure overall NPS improvement
- [ ] Target: 3-5x faster than current

---

## Resources

**Odin Documentation**:
- `core:simd` package reference
- Check `/path/to/odin/core/simd/simd.odin` for available functions

**Intel Intrinsics**:
- https://www.intel.com/content/www/us/en/docs/intrinsics-guide/
- Search for AVX2 instructions (_mm256_*)

**Stockfish Reference**:
- https://github.com/official-stockfish/Stockfish/blob/master/src/nnue/layers/affine_transform.h
- See `_mm256_add_epi16`, `_mm256_sub_epi16` usage

**Chess Programming Wiki**:
- https://www.chessprogramming.org/SIMD_and_SWAR_Techniques

---

## Summary

**Key Concepts**:
1. SIMD processes multiple values simultaneously
2. Use `i16x16` for accumulator (16 values at once)
3. Align memory to 32 bytes for best performance
4. Start with accumulator updates (easiest, biggest gain)

**Expected Gains**:
- Accumulator update: 10-15x faster
- Full evaluation: 3-5x faster
- Overall engine: 150-200 Elo gain

**Ready to implement?** Start with Exercise 1 to get familiar, then we'll modify the actual NNUE code!
