package main

import "nnue"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		fmt.println("Usage: sfnnv14_loader <network_file>")
		os.exit(1)
	}

	filename := os.args[1]
	fmt.printf("Loading SFNNv14 network: %s\n", filename)
	fmt.println("========================================")

	if nnue.init_sfnnv14(filename) {
		fmt.println("========================================")
		fmt.println("SUCCESS: Network loaded successfully!")
		fmt.println("========================================")

		// Print summary
		fmt.printf("Transformer biases: %d loaded\n", nnue.HALF_DIMENSIONS)
		fmt.printf("Threat weights: %d loaded\n", nnue.THREAT_DIMENSIONS * nnue.HALF_DIMENSIONS)
		fmt.printf("PSQ weights: %d loaded\n", nnue.PSQ_DIMENSIONS * nnue.HALF_DIMENSIONS)
		fmt.printf("PSQT combined: %d loaded\n", nnue.PSQT_COMBINED_SIZE)
		fmt.printf("Layer stacks: %d loaded\n", nnue.LAYER_STACKS)
		fmt.println()

		// Sanity checks
		network := nnue.network
		fmt.println("--- Sanity Checks ---")
		fmt.printf("Transformer biases[0]: %d\n", network.transformer_biases[0])
		fmt.printf("Transformer biases[511]: %d\n", network.transformer_biases[511])
		fmt.printf("Transformer biases[1023]: %d\n", network.transformer_biases[1023])
		fmt.printf("Transformer weights[0]: %d\n", network.transformer_weights[0])
		fmt.printf("Threat weights[0]: %d\n", network.transformer_threat_wts[0])
		fmt.printf("PSQT[0]: %d\n", network.transformer_psqt[0])
		fmt.printf("Stack 0 fc0_bias[0]: %d\n", network.stacks[0].fc0_biases[0])
		fmt.printf("Stack 0 fc2_bias: %d\n", network.stacks[0].fc2_bias)
		fmt.printf("Stack 7 fc0_bias[31]: %d\n", network.stacks[7].fc0_biases[31])
	} else {
		fmt.println("========================================")
		fmt.println("FAILED: Network load failed!")
		os.exit(1)
	}
}
