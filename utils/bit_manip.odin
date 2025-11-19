package utils

import "core:math/bits"

// Get the index of the Least Significant Bit (LSB)
get_lsb_index :: proc(bitboard: u64) -> int {
	if bitboard == 0 {
		return -1
	}
	return int(bits.count_trailing_zeros(bitboard))
}

// Pop the Least Significant Bit and return its index
pop_lsb :: proc(bitboard: ^u64) -> int {
	if bitboard^ == 0 {
		return -1
	}
	index := int(bits.count_trailing_zeros(bitboard^))
	bitboard^ &= bitboard^ - 1 // Clear the LSB
	return index
}

// Count bits
count_bits :: proc(bitboard: u64) -> int {
	return int(bits.count_ones(bitboard))
}
