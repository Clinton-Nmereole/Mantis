package nnue

// SFNNv14 Feature Transformer + FullThreats Implementation
//
// This module implements the SFNNv14 feature extraction and accumulator logic.
// Based on Stockfish master (April 2026) with architecture SFNNv14.
//
// Key components:
//   - HalfKAv2_hm: Horizontally mirrored king-relative piece features (22528 dims)
//   - FullThreats: Attack/defend relationship features (30360 dims for this network)
//   - Dual accumulators with PSQT values
//   - Incremental updates for PSQ, refresh-on-dirty for Threats
//
// References to Stockfish source files and line numbers are included throughout.

import "../board"
import "../constants"
import "../moves"
import "../utils"
import "base:intrinsics"
import "core:fmt"
import "core:math/bits"

// ============================================================================
// SFNNv14 Architecture Constants
// ============================================================================

// From Stockfish src/nnue/nnue_architecture.h:43
SFNNV14_L1 :: 1024  // Accumulator half-dimensions

// From Stockfish src/nnue/nnue_architecture.h:47
SFNNV14_PSQT_BUCKETS :: 8

// From Stockfish src/nnue/nnue_architecture.h:48
SFNNV14_LAYER_STACKS :: 8

// From Stockfish src/nnue/features/half_ka_v2_hm.h:45
// Dimensions = 64 squares * 704 piece-square values / 2 (mirroring) = 22528
SFNNV14_HALFKA_DIMENSIONS :: 22528

// FullThreats dimensions for the SFNNv14 network.
// Stockfish full_threats.h declares 60720. Raw i8 LE, 62,177,280 bytes.
SFNNV14_THREAT_DIMENSIONS :: 60720

// Total input dimensions = PSQ features + Threat features
SFNNV14_TOTAL_INPUT_DIMENSIONS :: SFNNV14_HALFKA_DIMENSIONS + SFNNV14_THREAT_DIMENSIONS

// Quantization constants from Stockfish src/nnue/nnue_common.h:63-64
SFNNV14_OUTPUT_SCALE :: 16
SFNNV14_WEIGHT_SCALE_BITS :: 6

// ============================================================================
// HalfKAv2_hm Lookup Tables
// ============================================================================
// Reference: Stockfish src/nnue/features/half_ka_v2_hm.h

// Piece-square index values. Each piece type has 64 squares.
// From half_ka_v2_hm.h lines 35-43:
//   PS_NONE=0, PS_W_PAWN=0, PS_B_PAWN=64, PS_W_KNIGHT=128, PS_B_KNIGHT=192,
//   PS_W_BISHOP=256, PS_B_BISHOP=320, PS_W_ROOK=384, PS_B_ROOK=448,
//   PS_W_QUEEN=512, PS_B_QUEEN=576, PS_KING=640, PS_NB=704
HalfKA_PieceSquareIndex := [2][16]int {
	// White perspective (perspective=WHITE=0)
	// Convention: W - us, B - them
	{0, 0, 128, 256, 384, 512, 640, 0, 0, 64, 192, 320, 448, 576, 640, 0},
	// Black perspective (perspective=BLACK=1)
	// Viewed from other side, W and B are reversed
	{0, 64, 192, 320, 448, 576, 640, 0, 0, 0, 128, 256, 384, 512, 640, 0},
}

// King buckets for grouping king positions.
// Mantis and Stockfish both use a1=0..h8=63 square order.
HalfKA_KingBuckets := [64]int {
	19712, 20416, 21120, 21824, 21824, 21120, 20416, 19712, // Rank 1: B(28)..B(31)
	16896, 17600, 18304, 19008, 19008, 18304, 17600, 16896, // Rank 2: B(24)..B(27)
	14080, 14784, 15488, 16192, 16192, 15488, 14784, 14080, // Rank 3: B(20)..B(23)
	11264, 11968, 12672, 13376, 13376, 12672, 11968, 11264, // Rank 4: B(16)..B(19)
	8448,  9152,  9856, 10560, 10560,  9856,  9152,  8448,  // Rank 5: B(12)..B(15)
	5632,  6336,  7040,  7744,  7744,  7040,  6336,  5632,  // Rank 6: B( 8)..B(11)
	2816,  3520,  4224,  4928,  4928,  4224,  3520,  2816,  // Rank 7: B( 4)..B( 7)
	   0,   704,  1408,  2112,  2112,  1408,   704,     0,  // Rank 8: B( 0)..B( 3)
}

// Orientation table for horizontal mirroring.
// From half_ka_v2_hm.h lines 77-86.
// If king is on files a-d, square is XORed with 7 (SQ_H1 = file index 7) to mirror to e-h side.
HalfKA_OrientTBL := [64]int {
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 1
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 2
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 3
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 4
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 5
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 6
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 7
	 7,  7,  7,  7,  0,  0,  0,  0,  // Rank 8
}

// ============================================================================
// FullThreats Lookup Tables
// ============================================================================
// Reference: Stockfish src/nnue/features/full_threats.h and full_threats.cpp

// Number of valid target piece types per attacker piece.
// From full_threats.h:43
// Pawn=6 (3 per color), Knight=10 (5 per color), Bishop=8 (4 per color),
// Rook=8 (4 per color), Queen=10 (5 per color), King=0
Threat_numValidTargets := [16]int {
	0, 6, 10, 8, 8, 10, 0, 0,
	0, 6, 10, 8, 8, 10, 0, 0,
}

// Map from attacker piece type to attacked piece type.
// From full_threats.h lines 66-73.
// -1 means excluded.
Threat_map := [6][6]int {
	{ 0,  1, -1,  2, -1, -1},  // Pawn attacking
	{ 0,  1,  2,  3,  4, -1},  // Knight attacking
	{ 0,  1,  2,  3, -1, -1},  // Bishop attacking
	{ 0,  1,  2,  3, -1, -1},  // Rook attacking
	{ 0,  1,  2,  3,  4, -1},  // Queen attacking
	{-1, -1, -1, -1, -1, -1},  // King attacking (all excluded)
}

// Orientation table for FullThreats.
// From full_threats.h lines 55-64.
// Unlike HalfKAv2_hm, this ORIENTs a-d files to 0 and e-h files to 7.
Threat_OrientTBL := [64]int {
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 1
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 2
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 3
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 4
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 5
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 6
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 7
	 0,  0,  0,  0,  7,  7,  7,  7,  // Rank 8
}

// ============================================================================
// FullThreats Runtime-Initialized Lookup Tables
// ============================================================================

// index_lut1[attacker][attacked][from < to] -> base feature offset
threat_index_lut1: [16][16][2]int

// offsets[attacker][from] -> per-piece, per-from-square offset
threat_offsets: [16][64]int

// index_lut2[attacker][from][to] -> attack index within the from-square's attack set
threat_index_lut2: [16][64][64]u8

// Helper offsets computed during LUT initialization
Threat_HelperOffsets :: struct {
	cumulative_piece_offset: int,
	cumulative_offset: int,
}
threat_helper_offsets: [16]Threat_HelperOffsets

// Pseudo-attacks lookup tables (computed at init)
threat_pseudo_attacks: [7][64]u64

// Pawn push or attacks: squares a pawn can attack OR push to
threat_pawn_push_or_attacks: [2][64]u64

// ============================================================================
// LUT Initialization
// ============================================================================

// Convert Mantis piece (0-11) to Stockfish piece encoding (1,2,3,4,5,6,9,10,11,12,13,14)
mantis_to_sf_piece :: proc(mantis_piece: int) -> int {
	color := mantis_piece / 6
	type_ := mantis_piece % 6 + 1
	return color * 8 + type_
}

// Convert Stockfish piece to Mantis piece
sf_to_mantis_piece :: proc(sf_piece: int) -> int {
	color := sf_piece / 8
	type_ := sf_piece % 8 - 1
	return color * 6 + type_
}

// Get color of a Stockfish piece (0=white, 1=black)
sf_piece_color :: proc(sf_piece: int) -> int {
	return sf_piece / 8
}

// Get type of a Stockfish piece (1=pawn, 2=knight, 3=bishop, 4=rook, 5=queen, 6=king)
sf_piece_type :: proc(sf_piece: int) -> int {
	return sf_piece % 8
}

// Count bits in a bitboard
popcount :: proc(bb: u64) -> int {
	return int(bits.count_ones(bb))
}

// Initialize pseudo-attack tables for threat feature computation
init_threat_pseudo_attacks :: proc() {
	for sq in 0 ..< 64 {
		threat_pseudo_attacks[2][sq] = moves.get_knight_attacks_bitboard(sq)
	}
	for sq in 0 ..< 64 {
		threat_pseudo_attacks[3][sq] = moves.get_bishop_attacks(sq, 0)
	}
	for sq in 0 ..< 64 {
		threat_pseudo_attacks[4][sq] = moves.get_rook_attacks(sq, 0)
	}
	for sq in 0 ..< 64 {
		threat_pseudo_attacks[5][sq] = moves.get_queen_attacks(sq, 0)
	}
	for sq in 0 ..< 64 {
		threat_pseudo_attacks[6][sq] = moves.get_king_attacks_bitboard(sq)
	}
}

// Initialize pawn push/attack tables for threat features
init_threat_pawn_tables :: proc() {
	for sq in 0 ..< 64 {
		file := sq % 8
		rank := sq / 8

		// White pawn push+attacks
		white_attacks: u64 = 0
		if rank < 7 {
			white_attacks |= u64(1) << u64(sq + 8)
		}
		if rank < 7 && file > 0 {
			white_attacks |= u64(1) << u64(sq + 7)
		}
		if rank < 7 && file < 7 {
			white_attacks |= u64(1) << u64(sq + 9)
		}
		threat_pawn_push_or_attacks[constants.WHITE][sq] = white_attacks

		// Black pawn push+attacks
		black_attacks: u64 = 0
		if rank > 0 {
			black_attacks |= u64(1) << u64(sq - 8)
		}
		if rank > 0 && file > 0 {
			black_attacks |= u64(1) << u64(sq - 9)
		}
		if rank > 0 && file < 7 {
			black_attacks |= u64(1) << u64(sq - 7)
		}
		threat_pawn_push_or_attacks[constants.BLACK][sq] = black_attacks
	}
}

// Initialize all FullThreats lookup tables.
// Reference: Stockfish full_threats.cpp lines 88-153
init_threat_luts :: proc() {
	all_sf_pieces := [12]int{1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14}

	// Step 1: Compute helper_offsets and threat_offsets
	cumulative_offset := 0
	for sf_piece in all_sf_pieces {
		piece_idx := sf_piece
		cumulative_piece_offset := 0
		pt := sf_piece_type(piece_idx)

		for from in 0 ..< 64 {
			threat_offsets[piece_idx][from] = cumulative_piece_offset

			if pt != 1 {  // Not pawn
				attacks := threat_pseudo_attacks[pt][from]
				cumulative_piece_offset += popcount(attacks)
			} else if from >= 8 && from <= 55 {
				color := sf_piece_color(piece_idx)
				attacks := threat_pawn_push_or_attacks[color][from]
				cumulative_piece_offset += popcount(attacks)
			}
		}

		threat_helper_offsets[piece_idx].cumulative_piece_offset = cumulative_piece_offset
		threat_helper_offsets[piece_idx].cumulative_offset = cumulative_offset
		cumulative_offset += Threat_numValidTargets[piece_idx] * cumulative_piece_offset
	}

	// Step 2: Compute index_lut1
	for attacker in all_sf_pieces {
		for attacked in all_sf_pieces {
			enemy := (attacker ~ attacked) == 8
			attacker_type := sf_piece_type(attacker)
			attacked_type := sf_piece_type(attacked)

			map_val := Threat_map[attacker_type - 1][attacked_type - 1]
			semi_excluded := attacker_type == attacked_type && (enemy || attacker_type != 1)

			feature := threat_helper_offsets[attacker].cumulative_offset +
				(sf_piece_color(attacked) * (Threat_numValidTargets[attacker] / 2) + map_val) *
					threat_helper_offsets[attacker].cumulative_piece_offset

			excluded := map_val < 0
			threat_index_lut1[attacker][attacked][0] = excluded ? SFNNV14_THREAT_DIMENSIONS : feature
			threat_index_lut1[attacker][attacked][1] = (excluded || semi_excluded) ? SFNNV14_THREAT_DIMENSIONS : feature
		}
	}

	// Step 3: Compute index_lut2 for non-pawn pieces
	for pt in 2 ..= 6 {
		for from in 0 ..< 64 {
			attacks := threat_pseudo_attacks[pt][from]
			for to in 0 ..< 64 {
				mask := (u64(1) << u64(to)) - 1
				index := u8(popcount(mask & attacks))
				threat_index_lut2[pt][from][to] = index
				threat_index_lut2[pt + 8][from][to] = index
			}
		}
	}

	// White pawn
	for from in 0 ..< 64 {
		attacks := threat_pawn_push_or_attacks[constants.WHITE][from]
		for to in 0 ..< 64 {
			mask := (u64(1) << u64(to)) - 1
			threat_index_lut2[1][from][to] = u8(popcount(mask & attacks))
		}
	}

	// Black pawn (piece type 9 in Stockfish encoding)
	for from in 0 ..< 64 {
		attacks := threat_pawn_push_or_attacks[constants.BLACK][from]
		for to in 0 ..< 64 {
			mask := (u64(1) << u64(to)) - 1
			threat_index_lut2[9][from][to] = u8(popcount(mask & attacks))
		}
	}
}

// ============================================================================
// Feature Indexing Functions
// ============================================================================

// HalfKAv2_hm feature index.
// Reference: Stockfish half_ka_v2_hm.cpp:88-91
//
// Formula: (sq ^ OrientTBL[ksq] ^ flip) + PieceSquareIndex[perspective][pc] + KingBuckets[ksq ^ flip]
get_halfka_feature_index :: proc(perspective: int, sq: int, piece: int, ksq: int) -> int {
	flip := 56 * perspective
	sf_pc := mantis_to_sf_piece(piece)
	oriented_sq := sq ~ HalfKA_OrientTBL[ksq] ~ flip
	ps_index := HalfKA_PieceSquareIndex[perspective][sf_pc]
	bucket := HalfKA_KingBuckets[ksq ~ flip]
	return oriented_sq + ps_index + bucket
}

// FullThreats feature index.
// Reference: Stockfish full_threats.cpp:158-169
//
// Returns an index in [0, SFNNV14_THREAT_DIMENSIONS) or SFNNV14_THREAT_DIMENSIONS if excluded.
get_threat_feature_index :: proc(
	perspective: int,
	attacker: int,   // Mantis piece (0-11)
	from: int,
	to: int,
	attacked: int,   // Mantis piece (0-11)
	ksq: int,
) -> int {
	orientation := Threat_OrientTBL[ksq] ~ (56 * perspective)
	from_oriented := from ~ orientation
	to_oriented := to ~ orientation

	swap := 8 * perspective
	attacker_sf := mantis_to_sf_piece(attacker) ~ swap
	attacked_sf := mantis_to_sf_piece(attacked) ~ swap

	lt_idx := 0
	if from_oriented < to_oriented {
		lt_idx = 1
	}

	idx1 := threat_index_lut1[attacker_sf][attacked_sf][lt_idx]
	idx2 := threat_offsets[attacker_sf][from_oriented]
	idx3 := int(threat_index_lut2[attacker_sf][from_oriented][to_oriented])

	return idx1 + idx2 + idx3
}

// ============================================================================
// Threat Feature Update Types
// ============================================================================
// Reference: Viridithas src/nnue/network.rs:1183 (ThreatFeatureUpdate)
//
// Compact representation of a single threat relationship change.
// Stored as 4 packed bytes (attacker, from, victim, to) so that
// size_of(ThreatFeatureUpdate) == 4, matching Viridithas's assert!
ThreatFeatureUpdate :: struct #packed {
	attacker: u8,
	from:     u8,
	victim:   u8,
	to:       u8,
}

// PSQT feature update — a piece moving to or from a square.
PsqtFeatureUpdate :: struct {
	sq:    int,
	piece: int,
}

// Buffer for threat adds/subs collected during move execution.
// Reference: Viridithas src/nnue/network.rs:1237 (ThreatUpdateBuffer)
SFNNv14_ThreatUpdateBuffer :: struct {
	add:       [128]ThreatFeatureUpdate,
	sub:       [128]ThreatFeatureUpdate,
	add_count: int,
	sub_count: int,
}

// Buffer for PSQT adds/subs collected during move execution.
// Reference: Viridithas src/nnue/network.rs:1257 (PsqtUpdateBuffer)
SFNNv14_PsqtUpdateBuffer :: struct {
	add:       [4]PsqtFeatureUpdate,
	sub:       [4]PsqtFeatureUpdate,
	add_count: int,
	sub_count: int,
}

// Combined PSQT + threat update buffer, filled during move execution.
// Reference: Viridithas src/nnue/network.rs:1257 (UpdateBuffer)
SFNNv14_UpdateBuffer :: struct {
	psqt:   SFNNv14_PsqtUpdateBuffer,
	threat: SFNNv14_ThreatUpdateBuffer,
}

// Clear all entries in the update buffer.
sfnnv14_buffer_clear :: proc(buf: ^SFNNv14_UpdateBuffer) {
	buf.psqt.add_count = 0
	buf.psqt.sub_count = 0
	buf.threat.add_count = 0
	buf.threat.sub_count = 0
}

// ============================================================================
// SFNNv14 Network Transformer Structure
// ============================================================================
// Reference: Stockfish nnue_feature_transformer.h

// The feature transformer holds weights and biases for both feature sets.
// Threat weights are i16 (matching Stockfish ThreatWeightType).
SFNNv14_Transformer :: struct {
	// HalfKAv2_hm biases: 1024 i16 values (LEB128)
	biases: [SFNNV14_L1]i16,

	// HalfKAv2_hm weights: 22528 * 1024 i16 (LEB128)
	// Row-major: weights[feature_idx * 1024 + neuron_idx]
	weights: []i16,

	// HalfKAv2_hm PSQT weights: 22528 * 8 i32 (LEB128)
	psqt_weights: []i32,

	// FullThreats weights: 30360 * 1024 i16 (raw little-endian)
	threat_weights: []i16,

	// FullThreats PSQT weights: 30360 * 8 i32 (LEB128)
	threat_psqt_weights: []i32,
}

// Global transformer instance
sfnnv14_transformer: SFNNv14_Transformer

// ============================================================================
// Accumulator Refresh Functions
// ============================================================================

// Refresh the PSQ accumulator (HalfKAv2_hm features) from scratch.
// Reference: Stockfish accumulator refresh logic
refresh_psq_accumulator :: proc(b: ^board.Board, perspective: int) {
	state := &b.sfnnv14_accumulators.psq

	// Start with biases
	state.accumulation[perspective] = sfnnv14_transformer.biases

	// Zero out PSQT accumulation
	for i in 0 ..< SFNNV14_PSQT_BUCKETS {
		state.psqt_accumulation[perspective][i] = 0
	}

	ksq := board.get_king_square(b, perspective)

	// Iterate over all pieces on the board (including kings — SFNNv14 includes them)
	for sq in 0 ..< 64 {
		piece := int(b.mailbox[sq])
		if piece == -1 {
			continue
		}

		feature_idx := get_halfka_feature_index(perspective, sq, piece, ksq)

		// Bounds check
		if feature_idx < 0 || feature_idx >= SFNNV14_HALFKA_DIMENSIONS {
			fmt.printf("ERROR: Invalid HalfKAv2 feature index: %d\n", feature_idx)
			continue
		}

		// Skip if transformer not loaded
		if len(sfnnv14_transformer.weights) == 0 {
			continue
		}

		// Add weights to accumulator
		weight_offset := feature_idx * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] += sfnnv14_transformer.weights[weight_offset + i]
		}

		// Add PSQT weights
		psqt_offset := feature_idx * SFNNV14_PSQT_BUCKETS
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] += sfnnv14_transformer.psqt_weights[psqt_offset + i]
		}
	}

	state.computed[perspective] = true
}

// Refresh the Threat accumulator (FullThreats features) from scratch.
// Reference: Stockfish full_threats.cpp:171-228
refresh_threat_accumulator :: proc(b: ^board.Board, perspective: int) {
	state := &b.sfnnv14_accumulators.threat

	// Threat accumulators start at zero (no biases)
	for i in 0 ..< SFNNV14_L1 {
		state.accumulation[perspective][i] = 0
	}
	for i in 0 ..< SFNNV14_PSQT_BUCKETS {
		state.psqt_accumulation[perspective][i] = 0
	}

	ksq := board.get_king_square(b, perspective)
	occupied := b.occupancies[constants.BOTH]
	all_pawns := b.bitboards[constants.PAWN] | b.bitboards[constants.PAWN + 6]

	// Process both colors
	for color in 0 ..= 1 {
		c := perspective ~ color

		// --- Pawns ---
		attacker := c * 6 + constants.PAWN
		c_pawns := b.bitboards[c * 6 + constants.PAWN]

		// Compute pushers: pawns blocked by any pawn in front
		pushers: u64 = 0
		if c == constants.WHITE {
			pushers = ((all_pawns & ~constants.RANK_1) >> 8) & c_pawns
		} else {
			pushers = ((all_pawns & ~constants.RANK_8) << 8) & c_pawns
		}

		// White pawn attacks
		if c == constants.WHITE {
			// NE attacks
			attacks := (c_pawns & ~constants.FILE_H) << 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 9
				attacked_piece := int(b.mailbox[to])
				if attacked_piece != -1 {
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					if idx < SFNNV14_THREAT_DIMENSIONS {
						add_threat_feature(state, perspective, idx)
					}
				}
			}

			// NW attacks
			attacks = (c_pawns & ~constants.FILE_A) << 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 7
				attacked_piece := int(b.mailbox[to])
				if attacked_piece != -1 {
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					if idx < SFNNV14_THREAT_DIMENSIONS {
						add_threat_feature(state, perspective, idx)
					}
				}
			}

			// Pushes
			attacks = pushers << 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 8
				attacked_piece := int(b.mailbox[to])
				if attacked_piece != -1 {
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					if idx < SFNNV14_THREAT_DIMENSIONS {
						add_threat_feature(state, perspective, idx)
					}
				}
			}
		} else {
			// Black pawn attacks
			// SW attacks
			attacks := (c_pawns & ~constants.FILE_A) >> 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 9
				attacked_piece := int(b.mailbox[to])
				if attacked_piece != -1 {
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					if idx < SFNNV14_THREAT_DIMENSIONS {
						add_threat_feature(state, perspective, idx)
					}
				}
			}

			// SE attacks
			attacks = (c_pawns & ~constants.FILE_H) >> 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 7
				attacked_piece := int(b.mailbox[to])
				if attacked_piece != -1 {
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					if idx < SFNNV14_THREAT_DIMENSIONS {
						add_threat_feature(state, perspective, idx)
					}
				}
			}

			// Pushes
			attacks = pushers >> 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 8
				attacked_piece := int(b.mailbox[to])
				if attacked_piece != -1 {
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					if idx < SFNNV14_THREAT_DIMENSIONS {
						add_threat_feature(state, perspective, idx)
					}
				}
			}
		}

		// --- Non-pawn pieces ---
		for pt in constants.KNIGHT ..< constants.KING {
			attacker = c * 6 + pt
			bb := b.bitboards[attacker]

			for bb != 0 {
				from := utils.pop_lsb(&bb)

				attacks: u64 = 0
				switch pt {
				case constants.KNIGHT:
					attacks = moves.get_knight_attacks_bitboard(from)
				case constants.BISHOP:
					attacks = moves.get_bishop_attacks(from, occupied)
				case constants.ROOK:
					attacks = moves.get_rook_attacks(from, occupied)
				case constants.QUEEN:
					attacks = moves.get_queen_attacks(from, occupied)
				}

				attacks &= occupied
				for attacks != 0 {
					to := utils.pop_lsb(&attacks)
					attacked_piece := int(b.mailbox[to])
					if attacked_piece != -1 {
						idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
						if idx < SFNNV14_THREAT_DIMENSIONS {
							add_threat_feature(state, perspective, idx)
						}
					}
				}
			}
		}
	}

	state.computed[perspective] = true
}

// Helper: Add a single threat feature to the accumulator state
add_threat_feature :: proc(state: ^board.SFNNv14_AccumulatorState, perspective: int, feature_idx: int) {
	if len(sfnnv14_transformer.threat_weights) == 0 {
		return
	}
	weight_offset := feature_idx * SFNNV14_L1
	for i in 0 ..< SFNNV14_L1 {
		state.accumulation[perspective][i] += sfnnv14_transformer.threat_weights[weight_offset + i]
	}

	psqt_offset := feature_idx * SFNNV14_PSQT_BUCKETS
	for i in 0 ..< SFNNV14_PSQT_BUCKETS {
		state.psqt_accumulation[perspective][i] += sfnnv14_transformer.threat_psqt_weights[psqt_offset + i]
	}
}

apply_threat_feature_delta :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	perspective: int,
	feature_idx: int,
	add: bool,
) {
	if len(sfnnv14_transformer.threat_weights) == 0 {
		return
	}
	if feature_idx < 0 || feature_idx >= SFNNV14_THREAT_DIMENSIONS {
		return
	}

	weight_offset := feature_idx * SFNNV14_L1
	if add {
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] += sfnnv14_transformer.threat_weights[weight_offset + i]
		}
	} else {
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] -= sfnnv14_transformer.threat_weights[weight_offset + i]
		}
	}

	psqt_offset := feature_idx * SFNNV14_PSQT_BUCKETS
	if add {
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] += sfnnv14_transformer.threat_psqt_weights[psqt_offset + i]
		}
	} else {
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] -= sfnnv14_transformer.threat_psqt_weights[psqt_offset + i]
		}
	}
}

// ============================================================================
// Incremental Update Functions
// ============================================================================

// Update PSQ accumulator incrementally for a piece move.
update_psq_accumulator_move :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	b: ^board.Board,
	perspective: int,
	from: int,
	to: int,
	piece: int,
) {
	ksq := board.get_king_square(b, perspective)

	// Remove feature from source
	idx_rem := get_halfka_feature_index(perspective, from, piece, ksq)
	if idx_rem >= 0 && idx_rem < SFNNV14_HALFKA_DIMENSIONS {
		weight_offset := idx_rem * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] -= sfnnv14_transformer.weights[weight_offset + i]
		}
		psqt_offset := idx_rem * SFNNV14_PSQT_BUCKETS
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] -= sfnnv14_transformer.psqt_weights[psqt_offset + i]
		}
	}

	// Add feature at target
	idx_add := get_halfka_feature_index(perspective, to, piece, ksq)
	if idx_add >= 0 && idx_add < SFNNV14_HALFKA_DIMENSIONS {
		weight_offset := idx_add * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] += sfnnv14_transformer.weights[weight_offset + i]
		}
		psqt_offset := idx_add * SFNNV14_PSQT_BUCKETS
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] += sfnnv14_transformer.psqt_weights[psqt_offset + i]
		}
	}
}

// Update PSQ accumulator for a piece removal (capture)
update_psq_accumulator_remove :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	b: ^board.Board,
	perspective: int,
	sq: int,
	piece: int,
) {
	ksq := board.get_king_square(b, perspective)
	idx := get_halfka_feature_index(perspective, sq, piece, ksq)
	if idx >= 0 && idx < SFNNV14_HALFKA_DIMENSIONS {
		weight_offset := idx * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] -= sfnnv14_transformer.weights[weight_offset + i]
		}
		psqt_offset := idx * SFNNV14_PSQT_BUCKETS
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] -= sfnnv14_transformer.psqt_weights[psqt_offset + i]
		}
	}
}

// ============================================================================
// Delta Application Functions
// ============================================================================
// Reference: Viridithas accumulator.rs: vector_update_threats (line 89),
//            vector_update_inplace_psqt (line 33)

// Apply threat feature deltas to a single-perspective accumulator.
// For each add: acc[i] += threat_weights[feature_idx * L1 + i]
// For each sub: acc[i] -= threat_weights[feature_idx * L1 + i]
apply_threat_deltas :: proc(
	acc: ^[SFNNV14_L1]i16,
	adds: []ThreatFeatureUpdate,
	subs: []ThreatFeatureUpdate,
	perspective: int,
	ksq: int,
) {
	if len(sfnnv14_transformer.threat_weights) == 0 { return }

	// Apply subtractions first (preserves ordering); then adds.
	for sub in subs {
		idx := get_threat_feature_index(
			perspective,
			int(sub.attacker),
			int(sub.from),
			int(sub.to),
			int(sub.victim),
			ksq,
		)
		if idx >= SFNNV14_THREAT_DIMENSIONS { continue }
		weight_offset := idx * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			acc[i] -= sfnnv14_transformer.threat_weights[weight_offset + i]
		}
	}
	for add_ in adds {
		idx := get_threat_feature_index(
			perspective,
			int(add_.attacker),
			int(add_.from),
			int(add_.to),
			int(add_.victim),
			ksq,
		)
		if idx >= SFNNV14_THREAT_DIMENSIONS { continue }
		weight_offset := idx * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			acc[i] += sfnnv14_transformer.threat_weights[weight_offset + i]
		}
	}
}

// Apply threat deltas (with PSQT) to a full SFNNv14_AccumulatorState.
apply_threat_deltas_full :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	adds: []ThreatFeatureUpdate,
	subs: []ThreatFeatureUpdate,
	perspective: int,
	ksq: int,
) {
	if len(sfnnv14_transformer.threat_weights) == 0 { return }

	for sub in subs {
		idx := get_threat_feature_index(
			perspective,
			int(sub.attacker),
			int(sub.from),
			int(sub.to),
			int(sub.victim),
			ksq,
		)
		if idx >= SFNNV14_THREAT_DIMENSIONS { continue }
		weight_offset := idx * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] -= sfnnv14_transformer.threat_weights[weight_offset + i]
		}
		psqt_offset := idx * SFNNV14_PSQT_BUCKETS
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] -= sfnnv14_transformer.threat_psqt_weights[psqt_offset + i]
		}
	}
	for add_ in adds {
		idx := get_threat_feature_index(
			perspective,
			int(add_.attacker),
			int(add_.from),
			int(add_.to),
			int(add_.victim),
			ksq,
		)
		if idx >= SFNNV14_THREAT_DIMENSIONS { continue }
		weight_offset := idx * SFNNV14_L1
		for i in 0 ..< SFNNV14_L1 {
			state.accumulation[perspective][i] += sfnnv14_transformer.threat_weights[weight_offset + i]
		}
		psqt_offset := idx * SFNNV14_PSQT_BUCKETS
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			state.psqt_accumulation[perspective][i] += sfnnv14_transformer.threat_psqt_weights[psqt_offset + i]
		}
	}
}

// Apply PSQT feature deltas to a single-perspective accumulator.
apply_psqt_deltas :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	adds: []PsqtFeatureUpdate,
	subs: []PsqtFeatureUpdate,
	perspective: int,
	ksq: int,
) {
	if len(sfnnv14_transformer.weights) == 0 { return }

	for sub in subs {
		idx := get_halfka_feature_index(perspective, sub.sq, sub.piece, ksq)
		if idx >= 0 && idx < SFNNV14_HALFKA_DIMENSIONS {
			weight_offset := idx * SFNNV14_L1
			for i in 0 ..< SFNNV14_L1 {
				state.accumulation[perspective][i] -= sfnnv14_transformer.weights[weight_offset + i]
			}
			psqt_offset := idx * SFNNV14_PSQT_BUCKETS
			for i in 0 ..< SFNNV14_PSQT_BUCKETS {
				state.psqt_accumulation[perspective][i] -= sfnnv14_transformer.psqt_weights[psqt_offset + i]
			}
		}
	}
	for add_ in adds {
		idx := get_halfka_feature_index(perspective, add_.sq, add_.piece, ksq)
		if idx >= 0 && idx < SFNNV14_HALFKA_DIMENSIONS {
			weight_offset := idx * SFNNV14_L1
			for i in 0 ..< SFNNV14_L1 {
				state.accumulation[perspective][i] += sfnnv14_transformer.weights[weight_offset + i]
			}
			psqt_offset := idx * SFNNV14_PSQT_BUCKETS
			for i in 0 ..< SFNNV14_PSQT_BUCKETS {
				state.psqt_accumulation[perspective][i] += sfnnv14_transformer.psqt_weights[psqt_offset + i]
			}
		}
	}
}

// Materialise a new threat accumulator by copying from the source
// and applying the collected threat deltas (Viridithas pattern).
// Reference: Viridithas network.rs:1734 (materialise_new_threat_acc_from)
materialise_threat_acc_from :: proc(
	src_acc: ^board.SFNNv14_AccumulatorState,
	tgt_acc: ^board.SFNNv14_AccumulatorState,
	updates: ^SFNNv14_ThreatUpdateBuffer,
	perspective: int,
	ksq: int,
) {
	// Copy source accumulator wholesale
	tgt_acc.accumulation[perspective] = src_acc.accumulation[perspective]
	tgt_acc.psqt_accumulation[perspective] = src_acc.psqt_accumulation[perspective]

	// Apply deltas in place
	adds := updates.add[:updates.add_count]
	subs := updates.sub[:updates.sub_count]
	apply_threat_deltas_full(tgt_acc, adds, subs, perspective, ksq)
	tgt_acc.computed[perspective] = true
}

// ============================================================================
// Simple Threat Delta Computation
// ============================================================================
// These functions compute which threats change when a piece is added,
// removed, or moved. They serve as the fallback implementation until
// the optimized Viridithas-style geometry helpers (in
// nnue/sfnnv14_threat_updates.odin) are available.

// Get attack bitboard for a given piece type from a square.
// Returns squares attacked by piece_type at 'from' given 'occupied' blockers.
threat_get_attacks :: proc(b: ^board.Board, piece: int, from: int) -> u64 {
	color := piece / 6
	pt := piece % 6
	occupied := b.occupancies[constants.BOTH]

	switch pt {
	case constants.PAWN:
		// Compute pawn attacks directly (no get_pawn_attacks_bitboard helper exists)
		src_bit := u64(1) << u64(from)
		if color == constants.WHITE {
			return ((src_bit & ~constants.FILE_A) << 7) | ((src_bit & ~constants.FILE_H) << 9)
		} else {
			return ((src_bit & ~constants.FILE_H) >> 7) | ((src_bit & ~constants.FILE_A) >> 9)
		}
	case constants.KNIGHT:
		return moves.get_knight_attacks_bitboard(from)
	case constants.BISHOP:
		return moves.get_bishop_attacks(from, occupied)
	case constants.ROOK:
		return moves.get_rook_attacks(from, occupied)
	case constants.QUEEN:
		return moves.get_queen_attacks(from, occupied)
	case:
		return 0  // Kings don't participate in threats
	}
}

// Push outgoing threats from a piece on 'sq' to the threat buffer.
// Only include threats where attacker and victim have different types
// OR are enemies (kings excluded per SFNNv12 convention).
threat_push_outgoing :: proc(
	buf: ^SFNNv14_ThreatUpdateBuffer,
	b: ^board.Board,
	is_add: bool,
	piece: int,
	sq: int,
) {
	if piece % 6 == constants.KING { return }  // kings excluded from threats

	attacks := threat_get_attacks(b, piece, sq)
	occupied := b.occupancies[constants.BOTH]
	// Only attack squares that are occupied (by non-king pieces)
	non_king_occ := occupied & ~(b.bitboards[constants.KING] | b.bitboards[constants.KING + 6])
	attacks &= non_king_occ

	for attacks != 0 {
		to := utils.pop_lsb(&attacks)
		victim := int(b.mailbox[to])
		if victim == -1 { continue }
		if victim % 6 == constants.KING { continue }

		uf: ThreatFeatureUpdate = {
			attacker = u8(piece),
			from     = u8(sq),
			victim   = u8(victim),
			to       = u8(to),
		}
		if is_add {
			buf.add[buf.add_count] = uf
			buf.add_count += 1
		} else {
			buf.sub[buf.sub_count] = uf
			buf.sub_count += 1
		}
	}
}

// Push incoming threats TO a piece on 'sq' from all other pieces.
threat_push_incoming :: proc(
	buf: ^SFNNv14_ThreatUpdateBuffer,
	b: ^board.Board,
	is_add: bool,
	piece: int,
	sq: int,
) {
	if piece % 6 == constants.KING { return }

	// For each non-king piece on the board, check if it attacks sq
	colors := [2]int{constants.WHITE, constants.BLACK}
	for color in colors {
		for pt in 0 ..= 5 {
			if pt == constants.KING { continue }
			cpiece := color * 6 + pt
			bb := b.bitboards[cpiece]
			for bb != 0 {
				from := utils.pop_lsb(&bb)
				attacks := threat_get_attacks(b, cpiece, from)
				if (attacks & (u64(1) << u64(sq))) != 0 {
					uf: ThreatFeatureUpdate = {
						attacker = u8(cpiece),
						from     = u8(from),
						victim   = u8(piece),
						to       = u8(sq),
					}
					if is_add {
						buf.add[buf.add_count] = uf
						buf.add_count += 1
					} else {
						buf.sub[buf.sub_count] = uf
						buf.sub_count += 1
					}
				}
			}
		}
	}
}

// Compute threat deltas for adding or removing a single piece on a square.
// "add" means the piece is appearing on sq (e.g., a piece moved to sq or was promoted).
// "sub" means the piece is disappearing from sq (e.g., a capture or moved away).
// NOTE: This is a simplified version. When nnue/sfnnv14_threat_updates.odin
// is merged, the optimized on_change/on_move/on_mutate from Viridithas will
// replace this.
threat_compute_change_deltas :: proc(
	buf: ^SFNNv14_ThreatUpdateBuffer,
	b: ^board.Board,
	piece: int,
	sq: int,
	is_add: bool,
) {
	threat_push_outgoing(buf, b, is_add, piece, sq)
	threat_push_incoming(buf, b, is_add, piece, sq)
}

// ============================================================================
// Combined Update Entry Point
// ============================================================================

// Update SFNNv14 accumulators after a move.
// This is the main entry point called after make_move.
//
// For PSQT: incremental updates using deltas.
// For Threats: delta-based incremental using simplified threat detection
//              (will be upgraded to Viridithas-style optimized geometry).
// For King moves: full refresh (bucket change invalidates incremental path).
update_sfnnv14_accumulators :: proc(old_board: ^board.Board, new_board: ^board.Board, move: moves.Move) {
	// Copy old accumulators
	new_board.sfnnv14_accumulators = old_board.sfnnv14_accumulators

	// If transformer not initialized, skip
	if sfnnv14_transformer.weights == nil {
		return
	}

	side := old_board.side
	piece_type := move.piece
	mantis_piece := piece_type
	if side == constants.BLACK {
		mantis_piece += 6
	}

	// Allocated on stack — buffer populated with exact threat deltas during this call
	buf: SFNNv14_UpdateBuffer

	// --- PSQ Accumulator Updates ---
	// PSQT: we use the existing direct incremental approach (proven correct).
	// The UpdateBuffer for PSQT is populated for compatibility with the
	// Viridithas-style lazy-update architecture.
	if piece_type == constants.KING {
		refresh_psq_accumulator(new_board, side)
	} else {
		// Populate PSQ buffer
		buf.psqt.add[0] = PsqtFeatureUpdate{sq = move.target, piece = mantis_piece}
		buf.psqt.sub[0] = PsqtFeatureUpdate{sq = move.source, piece = mantis_piece}
		buf.psqt.add_count = 1
		buf.psqt.sub_count = 1

		// Apply PSQ deltas directly (proven correct incremental path)
		update_psq_accumulator_move(
			&new_board.sfnnv14_accumulators.psq,
			old_board,
			constants.WHITE,
			move.source,
			move.target,
			mantis_piece,
		)
		update_psq_accumulator_move(
			&new_board.sfnnv14_accumulators.psq,
			old_board,
			constants.BLACK,
			move.source,
			move.target,
			mantis_piece,
		)
	}

	// Handle captures
	if move.capture {
		captured_piece := int(old_board.mailbox[move.target])
		if captured_piece != -1 {
			// PSQT buffer: capture
			buf.psqt.sub[buf.psqt.sub_count] = PsqtFeatureUpdate{sq = move.target, piece = captured_piece}
			buf.psqt.sub_count += 1

			if piece_type == constants.KING {
				update_psq_accumulator_remove(
					&new_board.sfnnv14_accumulators.psq,
					old_board,
					1 - side,
					move.target,
					captured_piece,
				)
			} else {
				update_psq_accumulator_remove(
					&new_board.sfnnv14_accumulators.psq,
					old_board,
					constants.WHITE,
					move.target,
					captured_piece,
				)
				update_psq_accumulator_remove(
					&new_board.sfnnv14_accumulators.psq,
					old_board,
					constants.BLACK,
					move.target,
					captured_piece,
				)
			}
		}
	}

	// Handle promotion for PSQ
	if move.promoted != -1 {
		final_piece := move.promoted
		if side == constants.BLACK {
			final_piece += 6
		}

		// PSQT buffer: promotion (remove pawn, add promoted piece)
		buf.psqt.sub[buf.psqt.sub_count] = PsqtFeatureUpdate{sq = move.target, piece = mantis_piece}
		buf.psqt.sub_count += 1
		buf.psqt.add[buf.psqt.add_count] = PsqtFeatureUpdate{sq = move.target, piece = final_piece}
		buf.psqt.add_count += 1

		update_psq_accumulator_remove(
			&new_board.sfnnv14_accumulators.psq,
			new_board,
			constants.WHITE,
			move.target,
			mantis_piece,
		)
		update_psq_accumulator_move(
			&new_board.sfnnv14_accumulators.psq,
			new_board,
			constants.WHITE,
			move.source,
			move.target,
			final_piece,
		)

		update_psq_accumulator_remove(
			&new_board.sfnnv14_accumulators.psq,
			new_board,
			constants.BLACK,
			move.target,
			mantis_piece,
		)
		update_psq_accumulator_move(
			&new_board.sfnnv14_accumulators.psq,
			new_board,
			constants.BLACK,
			move.source,
			move.target,
			final_piece,
		)
	}

	// --- Threat Accumulator Updates ---
	// Build the exact old/new FullThreats index sets and apply only the row
	// differences. This keeps the source of truth identical to full refresh
	// while avoiding work for unchanged threat features.
	update_threat_accumulators_by_index_diff(old_board, new_board)
}

// ============================================================================
// PSQT Bucket Selection
// ============================================================================

// Select the PSQT bucket based on total piece count.
// Reference: Stockfish network.cpp:157
//   const int bucket = (pos.count<ALL_PIECES>() - 1) / 4;
get_psqt_bucket :: proc(b: ^board.Board) -> int {
	piece_count := utils.count_bits(b.occupancies[constants.BOTH])
	bucket := (piece_count - 1) / 4
	if bucket < 0 { bucket = 0 }
	if bucket > 7 { bucket = 7 }
	return bucket
}

// ============================================================================
// Combined Evaluation Preparation
// ============================================================================

// Ensure both accumulators are computed and return combined accumulator + PSQT.
// This is called before the network forward pass.
//
// The combined accumulator is simply the sum of PSQ and Threat accumulations
// for the side to move. The 1024 values are passed directly to fc_0.
// Reference: Stockfish nnue_feature_transformer.h:226-280
prepare_sfnnv14_evaluation :: proc(b: ^board.Board) -> (acc: [SFNNV14_L1]u8, psqt: i32, bucket: int) {
	// Ensure PSQ accumulators are computed
	for perspective in 0 ..= 1 {
		if !b.sfnnv14_accumulators.psq.computed[perspective] {
			refresh_psq_accumulator(b, perspective)
		}
	}

	// Ensure Threat accumulators are computed
	for perspective in 0 ..= 1 {
		if !b.sfnnv14_accumulators.threat.computed[perspective] {
			refresh_threat_accumulator(b, perspective)
		}
	}

	bucket = get_psqt_bucket(b)
	stm := b.side
	nstm := 1 - stm

	// Compute PSQT:
	// psqt = (psq_psqt[stm][bucket] - psq_psqt[nstm][bucket]
	//       + threat_psqt[stm][bucket] - threat_psqt[nstm][bucket]) / 2
	psqt = b.sfnnv14_accumulators.psq.psqt_accumulation[stm][bucket] -
		b.sfnnv14_accumulators.psq.psqt_accumulation[nstm][bucket]
	psqt += b.sfnnv14_accumulators.threat.psqt_accumulation[stm][bucket] -
		b.sfnnv14_accumulators.threat.psqt_accumulation[nstm][bucket]
	psqt /= 2

	// HalfKAv2 pair transform: combine PSQ+Threat then clamp-multiply-divide.
	// For each perspective p, for each j in 0..511:
	//   acc[p*512+j] = clamp(psq[p][j]+threat[p][j]) * clamp(psq[p][j+512]+threat[p][j+512]) / 512
	// Stockfish: nnue_feature_transformer.h:420-430, divisor=512 (SIMD-scaled weights)
	for p in 0 ..= 1 {
		perspective := p == 0 ? stm : nstm
		base := p * (SFNNV14_L1 / 2)
		for j in 0 ..< SFNNV14_L1 / 2 {
			s0 := b.sfnnv14_accumulators.psq.accumulation[perspective][j] +
				b.sfnnv14_accumulators.threat.accumulation[perspective][j]
			s1 := b.sfnnv14_accumulators.psq.accumulation[perspective][j + SFNNV14_L1 / 2] +
				b.sfnnv14_accumulators.threat.accumulation[perspective][j + SFNNV14_L1 / 2]
			c0 := s0; if c0 < 0 { c0 = 0 }; if c0 > 255 { c0 = 255 }
			c1 := s1; if c1 < 0 { c1 = 0 }; if c1 > 255 { c1 = 255 }
			acc[base + j] = u8((i32(c0) * i32(c1)) / 512)
		}
	}

	return
}

// ============================================================================
// Refresh All Accumulators (for initial board setup)
// ============================================================================

// Refresh both PSQ and Threat accumulators for both perspectives.
// Call this when setting up a new position (e.g., after parsing FEN).
refresh_sfnnv14_accumulators :: proc(b: ^board.Board) {
	for perspective in 0 ..= 1 {
		refresh_psq_accumulator(b, perspective)
		refresh_threat_accumulator(b, perspective)
	}
}

collect_threat_indices :: proc(b: ^board.Board, perspective: int, out: ^[128]int) -> int {
	count := 0
	ksq := board.get_king_square(b, perspective)
	occupied := b.occupancies[constants.BOTH]
	all_pawns := b.bitboards[constants.PAWN] | b.bitboards[constants.PAWN + 6]

	add_idx :: proc(out: ^[128]int, count: ^int, idx: int) {
		if idx < SFNNV14_THREAT_DIMENSIONS && count^ < len(out^) {
			out[count^] = idx
			count^ += 1
		}
	}

	for color in 0 ..= 1 {
		c := perspective ~ color

		attacker := c * 6 + constants.PAWN
		c_pawns := b.bitboards[c * 6 + constants.PAWN]

		pushers: u64 = 0
		if c == constants.WHITE {
			pushers = ((all_pawns & ~constants.RANK_1) >> 8) & c_pawns
		} else {
			pushers = ((all_pawns & ~constants.RANK_8) << 8) & c_pawns
		}

		if c == constants.WHITE {
			attacks := (c_pawns & ~constants.FILE_H) << 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 9
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(out, &count, idx)
			}

			attacks = (c_pawns & ~constants.FILE_A) << 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 7
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(out, &count, idx)
			}

			attacks = pushers << 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 8
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(out, &count, idx)
			}
		} else {
			attacks := (c_pawns & ~constants.FILE_A) >> 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 9
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(out, &count, idx)
			}

			attacks = (c_pawns & ~constants.FILE_H) >> 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 7
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(out, &count, idx)
			}

			attacks = pushers >> 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 8
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(out, &count, idx)
			}
		}

		for pt in constants.KNIGHT ..< constants.KING {
			attacker = c * 6 + pt
			bb := b.bitboards[attacker]

			for bb != 0 {
				from := utils.pop_lsb(&bb)

				attacks: u64 = 0
				switch pt {
				case constants.KNIGHT:
					attacks = moves.get_knight_attacks_bitboard(from)
				case constants.BISHOP:
					attacks = moves.get_bishop_attacks(from, occupied)
				case constants.ROOK:
					attacks = moves.get_rook_attacks(from, occupied)
				case constants.QUEEN:
					attacks = moves.get_queen_attacks(from, occupied)
				}

				attacks &= occupied
				for attacks != 0 {
					to := utils.pop_lsb(&attacks)
					attacked_piece := int(b.mailbox[to])
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					add_idx(out, &count, idx)
				}
			}
		}
	}

	return count
}

apply_threat_index_diff :: proc(
	state: ^board.SFNNv14_AccumulatorState,
	perspective: int,
	old_indices: ^[128]int,
	old_count: int,
	new_indices: ^[128]int,
	new_count: int,
) {
	used_new: [128]bool

	for i in 0 ..< old_count {
		found := false
		for j in 0 ..< new_count {
			if !used_new[j] && old_indices[i] == new_indices[j] {
				used_new[j] = true
				found = true
				break
			}
		}
		if !found {
			apply_threat_feature_delta(state, perspective, old_indices[i], false)
		}
	}

	for j in 0 ..< new_count {
		if !used_new[j] {
			apply_threat_feature_delta(state, perspective, new_indices[j], true)
		}
	}
}

update_threat_accumulators_by_index_diff :: proc(old_board: ^board.Board, new_board: ^board.Board) {
	for perspective in 0 ..= 1 {
		old_indices: [128]int
		new_indices: [128]int
		old_count := collect_threat_indices(old_board, perspective, &old_indices)
		new_count := collect_threat_indices(new_board, perspective, &new_indices)

		apply_threat_index_diff(
			&new_board.sfnnv14_accumulators.threat,
			perspective,
			&old_indices,
			old_count,
			&new_indices,
			new_count,
		)
		new_board.sfnnv14_accumulators.threat.computed[perspective] = true
	}
}

compare_threat_accumulators :: proc(a: ^board.Board, b: ^board.Board) -> (bool, string) {
	for perspective in 0 ..= 1 {
		for i in 0 ..< SFNNV14_L1 {
			if a.sfnnv14_accumulators.threat.accumulation[perspective][i] !=
			   b.sfnnv14_accumulators.threat.accumulation[perspective][i] {
				return false, fmt.tprintf(
					"threat accumulation mismatch perspective=%d index=%d incremental=%d refresh=%d",
					perspective,
					i,
					a.sfnnv14_accumulators.threat.accumulation[perspective][i],
					b.sfnnv14_accumulators.threat.accumulation[perspective][i],
				)
			}
		}
		for i in 0 ..< SFNNV14_PSQT_BUCKETS {
			if a.sfnnv14_accumulators.threat.psqt_accumulation[perspective][i] !=
			   b.sfnnv14_accumulators.threat.psqt_accumulation[perspective][i] {
				return false, fmt.tprintf(
					"threat psqt mismatch perspective=%d bucket=%d incremental=%d refresh=%d",
					perspective,
					i,
					a.sfnnv14_accumulators.threat.psqt_accumulation[perspective][i],
					b.sfnnv14_accumulators.threat.psqt_accumulation[perspective][i],
				)
			}
		}
	}

	return true, ""
}

validate_threat_incremental :: proc(b: ^board.Board, depth: int) -> (nodes: u64, ok: bool, msg: string) {
	if depth == 0 {
		return 1, true, ""
	}

	move_list: moves.MoveList
	board.generate_all_moves(b, &move_list)

	for i in 0 ..< move_list.count {
		state: board.StateInfo
		board.make_move_fast(b, move_list.moves[i], &state)

		king_sq := board.get_king_square(b, 1 - b.side)
		if board.is_square_attacked(b, king_sq, b.side) {
			board.unmake_move(b, &state)
			continue
		}

		update_accumulators(&state, b, move_list.moves[i])

		refreshed := b^
		for perspective in 0 ..= 1 {
			refresh_threat_accumulator(&refreshed, perspective)
		}

		match, compare_msg := compare_threat_accumulators(b, &refreshed)
		if !match {
			board.unmake_move(b, &state)
			return nodes, false, fmt.tprintf(
				"after move source=%d target=%d promoted=%d: %s",
				move_list.moves[i].source,
				move_list.moves[i].target,
				move_list.moves[i].promoted,
				compare_msg,
			)
		}

		child_nodes, child_ok, child_msg := validate_threat_incremental(b, depth - 1)
		if !child_ok {
			board.unmake_move(b, &state)
			return nodes, false, child_msg
		}
		nodes += child_nodes
		board.unmake_move(b, &state)
	}

	return nodes, true, ""
}

validate_threat_incremental_test :: proc(fen: string, depth: int) {
	game_board := board.parse_fen(fen)
	refresh_sfnnv14_accumulators(&game_board)
	nodes, ok, msg := validate_threat_incremental(&game_board, depth)
	if ok {
		fmt.printf("Threat incremental validation OK: nodes=%d depth=%d\n", nodes, depth)
	} else {
		fmt.printf("Threat incremental validation FAILED: depth=%d nodes_before_failure=%d error=%s\n", depth, nodes, msg)
	}
}

trace_psq_feature_hash :: proc(b: ^board.Board, perspective: int) -> (count: int, hash: u64) {
	ksq := board.get_king_square(b, perspective)
	for sq in 0 ..< 64 {
		piece := int(b.mailbox[sq])
		if piece == -1 {
			continue
		}
		idx := get_halfka_feature_index(perspective, sq, piece, ksq)
		count += 1
		hash = hash * 131 + u64(idx)
	}
	return
}

trace_threat_feature_hash :: proc(b: ^board.Board, perspective: int) -> (count: int, sum: u64, hash: u64) {
	ksq := board.get_king_square(b, perspective)
	occupied := b.occupancies[constants.BOTH]
	all_pawns := b.bitboards[constants.PAWN] | b.bitboards[constants.PAWN + 6]

	add_idx :: proc(count: ^int, sum: ^u64, hash: ^u64, idx: int) {
		if idx < SFNNV14_THREAT_DIMENSIONS {
			count^ += 1
			sum^ += u64(idx)
			hash^ = hash^ * 131 + u64(idx)
		}
	}

	for color in 0 ..= 1 {
		c := perspective ~ color

		attacker := c * 6 + constants.PAWN
		c_pawns := b.bitboards[c * 6 + constants.PAWN]

		pushers: u64 = 0
		if c == constants.WHITE {
			pushers = ((all_pawns & ~constants.RANK_1) >> 8) & c_pawns
		} else {
			pushers = ((all_pawns & ~constants.RANK_8) << 8) & c_pawns
		}

		if c == constants.WHITE {
			attacks := (c_pawns & ~constants.FILE_H) << 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 9
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(&count, &sum, &hash, idx)
			}

			attacks = (c_pawns & ~constants.FILE_A) << 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 7
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(&count, &sum, &hash, idx)
			}

			attacks = pushers << 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to - 8
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(&count, &sum, &hash, idx)
			}
		} else {
			attacks := (c_pawns & ~constants.FILE_A) >> 9
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 9
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(&count, &sum, &hash, idx)
			}

			attacks = (c_pawns & ~constants.FILE_H) >> 7
			attacks &= occupied
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 7
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(&count, &sum, &hash, idx)
			}

			attacks = pushers >> 8
			for attacks != 0 {
				to := utils.pop_lsb(&attacks)
				from := to + 8
				attacked_piece := int(b.mailbox[to])
				idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
				add_idx(&count, &sum, &hash, idx)
			}
		}

		for pt in constants.KNIGHT ..< constants.KING {
			attacker = c * 6 + pt
			bb := b.bitboards[attacker]

			for bb != 0 {
				from := utils.pop_lsb(&bb)

				attacks: u64 = 0
				switch pt {
				case constants.KNIGHT:
					attacks = moves.get_knight_attacks_bitboard(from)
				case constants.BISHOP:
					attacks = moves.get_bishop_attacks(from, occupied)
				case constants.ROOK:
					attacks = moves.get_rook_attacks(from, occupied)
				case constants.QUEEN:
					attacks = moves.get_queen_attacks(from, occupied)
				}

				attacks &= occupied
				for attacks != 0 {
					to := utils.pop_lsb(&attacks)
					attacked_piece := int(b.mailbox[to])
					idx := get_threat_feature_index(perspective, attacker, from, to, attacked_piece, ksq)
					add_idx(&count, &sum, &hash, idx)
				}
			}
		}
	}
	return
}

// ============================================================================
// Initialization
// ============================================================================

// Initialize all SFNNv14 feature lookup tables.
init_sfnnv14_features :: proc() {
	init_threat_pseudo_attacks()
	init_threat_pawn_tables()
	init_threat_luts()
	init_threat_geometry()
}
