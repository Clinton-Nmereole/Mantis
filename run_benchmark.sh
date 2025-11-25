#!/bin/bash
# Run NNUE performance benchmarks

echo "Building NNUE benchmark..."
odin build benchmark -out:benchmark/nnue_bench -o:speed -no-bounds-check -disable-assert

if [ $? -eq 0 ]; then
    echo ""
    echo "Running benchmark..."
    echo "================================"
    ./benchmark/nnue_bench
    echo "================================"
    echo ""
    echo "Benchmark complete!"
    echo ""
    echo "Save these results to compare after SIMD implementation."
else
    echo "Build failed!"
    exit 1
fi
