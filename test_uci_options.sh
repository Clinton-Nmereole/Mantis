#!/bin/bash
# Test UCI Options Output

echo "=== Testing UCI Options ==="
echo ""

echo "Sending 'uci' command to Mantis:"
echo "uci" | ./mantis | grep -E "(option name|uciok)"

echo ""
echo "=== Expected Options ==="
echo "- Hash (spin, 64, 1-1024)"
echo "- EvalFile (string)"
echo "- Move Overhead (spin, 10, 0-5000)"
echo "- MultiPV (spin, 1, 1-500)"
echo "- Ponder (check, false)"
echo "- Threads (spin, 1, 1-512)"
