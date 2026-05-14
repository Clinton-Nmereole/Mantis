#!/bin/bash
# Build Mantis with all optimizations

echo "Building Mantis (Full Optimizations)..."
echo ""

# Clean old binary
if [ -f mantis ]; then
	echo "Removing old binary..."
	rm -f mantis
fi

# Build with full optimizations
echo "Compiling with -o:speed -no-bounds-check -disable-assert..."
odin build . -out:mantis -o:speed -no-bounds-check -disable-assert -extra-linker-flags:"-Ltb -lsyzygy"

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
