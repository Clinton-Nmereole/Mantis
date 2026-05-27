#!/bin/bash
# Build Mantis with all optimizations (AVX2 auto-vectorized)
# For portable builds (SSE2 baseline), change -microarch:native to -microarch:x86-64-v2

MARCH="${1:-native}"

echo "Building Mantis (Full Optimizations, microarch=$MARCH)..."
echo ""

# Clean old binary
if [ -f mantis ]; then
	echo "Removing old binary..."
	rm -f mantis
fi

# Build with full optimizations
echo "Compiling with -o:speed -no-bounds-check -disable-assert -microarch:$MARCH..."
odin build . -out:mantis -o:speed -no-bounds-check -disable-assert -microarch:$MARCH -extra-linker-flags:"-Ltb -lsyzygy"

if [ $? -eq 0 ]; then
	echo ""
	echo "✓ Build successful!"
	echo ""
	ls -lh mantis
else
	echo ""
	echo "✗ Build failed!"
	exit 1
fi
