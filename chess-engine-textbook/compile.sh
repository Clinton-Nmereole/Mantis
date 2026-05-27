#!/bin/bash
# Compile the Chess Engine Textbook
# Usage: ./compile.sh [--watch]

set -e
cd "$(dirname "$0")"

echo "=== Compiling Chess Engine Textbook ==="
echo ""

if [ "$1" = "--watch" ]; then
	echo "Watching for changes..."
	typst watch book.typ "Chess_Engine_Engineering.pdf"
else
	typst compile book.typ "Chess_Engine_Engineering.pdf"
	if [ $? -eq 0 ]; then
		echo ""
		echo "=== Compilation successful! ==="
		ls -lh "Chess_Engine_Engineering.pdf"
		echo ""
		# Count pages (approximate)
		PAGES=$(pdfinfo "Chess_Engine_Engineering.pdf" 2>/dev/null | grep Pages | awk '{print $2}')
		if [ -n "$PAGES" ]; then
			echo "Pages: $PAGES"
		fi
	else
		echo ""
		echo "=== Compilation FAILED ==="
		exit 1
	fi
fi
