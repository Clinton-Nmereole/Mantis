#!/bin/bash
# Build Mantis with full optimizations

echo "Building Mantis (Optimized for Speed)..."
echo ""

# Clean old binary
if [ -f mantis ]; then
    echo "Removing old binary..."
    rm -f mantis
fi

# Build with speed optimizations
echo "Compiling with -o:speed -microarch:native..."
odin build . -out:mantis -o:speed -microarch:native

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo ""
    echo "Binary info:"
    ls -lh mantis
    echo ""
    echo "Quick performance test:"
    echo "  echo -e \"uci\\nsetoption name Threads value 8\\nsetoption name Hash value 256\\nposition startpos\\ngo depth 15\\nquit\" | ./mantis | grep -E \"(nps|depth)\""
    echo ""
    echo "Expected NPS with 8 threads: 8-15 million nodes/second"
else
    echo ""
    echo "✗ Build failed!"
    exit 1
fi
