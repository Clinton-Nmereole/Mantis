#!/bin/bash
# Test Mantis Chess Engine

echo "=== Mantis Chess Engine Test ==="
echo ""

echo "Test 1: Starting position, depth 6"
echo "-----------------------------------"
(
echo "uci"
sleep 0.5
echo "isready"
sleep 0.5  
echo "position startpos"
echo "go depth 6"
sleep 5
echo "quit"
) | ./mantis out+err>1 | grep -A 10 "info depth"

echo ""
echo "Test 2: After 1.e4 e5, depth 5"
echo "------------------------------"
(
echo "uci"
sleep 0.5
echo "position startpos moves e2e4 e7e5"
echo "go depth 5"
sleep 3
echo "quit"
) | ./mantis out+err>1 | grep -A 10 "info depth"

echo ""
echo "=== Tests Complete ==="
