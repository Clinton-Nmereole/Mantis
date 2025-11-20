package main

import "core:fmt"
import "core:os"

main :: proc() {
	filename := "../nn-c0ae49f08b40.nnue"
	data, success := os.read_entire_file(filename)
	if !success {
		fmt.println("Failed to read file")
		return
	}
	defer delete(data)

	size := len(data)
	fmt.printf("File Size: %d\n", size)

	// Print last 64 bytes
	start := size - 64
	if start < 0 {start = 0}

	fmt.println("Last 64 bytes:")
	for i in start ..< size {
		fmt.printf("%02X ", data[i])
		if (i - start + 1) % 16 == 0 {
			fmt.println()
		}
	}
	fmt.println()

	// Interpret last 4 bytes as i32
	if size >= 4 {
		b1 := u32(data[size - 4])
		b2 := u32(data[size - 3])
		b3 := u32(data[size - 2])
		b4 := u32(data[size - 1])
		val := i32(b1 | (b2 << 8) | (b3 << 16) | (b4 << 24))
		fmt.printf("Last 4 bytes as i32: %d (0x%X)\n", val, val)
	}
}
