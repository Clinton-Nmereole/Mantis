== Neural Network Updated Evaluation (NNUE)

NNUE—"Efficiently Updatable Neural Network"—is the most significant algorithmic innovation in computer chess since alpha-beta pruning. First introduced in the shogi engine YaneuraOu in 2018 and adapted to chess by Stockfish in 2020, NNUE has caused a revolution in chess engine strength. In just four years (2020-2024), Stockfish gained approximately 400-500 ELO purely from evaluation improvements, vaulting from roughly 3100 to 3600+ ELO—a margin of superiority that means the best engine beats the best human in roughly 99.9% of games and beats engines from 2019 in nearly 100% of games.

This chapter provides a complete technical understanding of NNUE: its architecture, its training pipeline, its inference algorithm, and the incremental update trick that makes it possible to evaluate a position in ~500 nanoseconds while processing a neural network with millions of weights.

=== The Problem NNUE Solves

Handcrafted evaluation functions (Chapters 11-12) rely on human chess knowledge encoded as explicit features: material, piece-square tables, pawn structure, mobility, king safety, etc. The strength of a classical engine is limited by the quality of these handcrafted features. Expert chess programmers can extract perhaps 3000-3100 ELO from handcrafted evaluation with careful tuning.

The fundamental limitation is *feature completeness*: there are chess patterns that humans cannot easily codify. What is the exact penalty for a bishop that is "slightly misplaced"? How does the evaluation adjust when both sides have pawn weaknesses but one side has the bishop pair? Handcrafted evaluation functions use linear combinations of features, but chess evaluation is non-linear—the value of one feature depends on the presence of others. A knight in the center is worth more when supported by a pawn; a passed pawn is more valuable when the opponent's king is far away.

Neural networks solve this: they can learn arbitrary non-linear functions over a rich feature space. The catch is that neural network evaluation is typically thousands of times slower than handcrafted evaluation. A standard neural network (multi-layer perceptron, convolutional network) requires millions of floating-point operations per inference, which is far too slow for a chess engine evaluating 2-10 million positions per second.

NNUE resolves this paradox through an elegant architectural trick: the network is designed so that its evaluation can be *incrementally updated* between positions that differ by a single move. Instead of recomputing the entire network from scratch for each new position, we compute only the changes caused by the move that was just made. This reduces the per-evaluation cost from O(network weights) to O(changed features), enabling NNUE evaluation at speeds comparable to (or faster than) classical evaluation.

=== History: From Shogi to Chess

NNUE was first described by Yu Nasu in 2018 for the shogi engine YaneuraOu. Shogi (Japanese chess) has a larger board (9×9), more piece types, and pieces that can drop back onto the board after capture, making it a more complex game than chess. Nasu's key insight was that a neural network designed for incremental updates could evaluate shogi positions at competitive speeds.

The Stockfish developers (particularly Hisayori Noda, known as "nodchip") adapted NNUE to chess in mid-2020. The first Stockfish NNUE release (Stockfish 12, September 2020) gained approximately 80 ELO over the classical Stockfish 11. Subsequent network generations produced rapid gains:

- *Stockfish 12* (Sep 2020): NNUE hybrid with classical evaluation. First NNUE release. +80 ELO.
- *Stockfish 13* (Feb 2021): Improved network architecture. Multiple networks for different phases. +60 ELO.
- *Stockfish 14* (Jul 2021): Pure NNUE (classical evaluation completely removed). Larger network. +40 ELO.
- *Stockfish 15* (Apr 2022): Further network scaling. Better training data. +35 ELO.
- *Stockfish 16* (Jun 2023): Deeper networks, improved feature representation. +30 ELO.
- *Stockfish 17* (Sep 2024): Continued scaling, dual-network architecture (small + big net). +25 ELO.

The ELO gains diminished over time (diminishing returns from network scaling), but the cumulative gain from NNUE was approximately 300-400 ELO over four years—an unprecedented rate of improvement for a mature engine.

=== NNUE Architecture

The standard NNUE architecture for chess (the "HalfKP" architecture, later refined to "HalfKA") consists of an input layer, two hidden layers, and an output layer. Despite its simplicity (compared to deep learning networks with dozens of layers), it achieves remarkable accuracy because the input features are carefully designed to encode chess-specific information.

==== Input Features: HalfKP and HalfKA

The input layer encodes the chess position as a set of *binary features*, each representing a specific piece-square relationship. The HalfKP (Half-King-Piece) feature set works as follows:

For each square `k` where a king could be (64 possibilities), and for each (piece_type, piece_color, piece_square) combination, we create a binary feature. Each feature answers the question: "Given that the friendly king is on square k, is there a piece of type t and color c on square s?"

The feature space is arranged as:
- 64 king squares (the perspective of the side to move)
- For each king square: 10 piece types (pawn, knight, bishop, rook, queen for each color) × 64 squares = 640 piece-square features
- Additionally: 2 "bucket" features that encode the game phase (material configuration)

Total: 64 × 640 + 2 = 40,962 features. Each feature is either 0 or 1 (binary activation).

HalfKA refines this: instead of encoding "given king on k, piece on s", it encodes "given king on k, piece on s, with piece-square relationship encoded by the kingside files." The feature count grows to 64 × 2560 + K_features, where K_features encodes the position's king-relative information.

The feature representation is *sparse*: for a typical position with 20-30 pieces on the board, only 20-30 of the 40,962 features are active (set to 1). This sparsity is the key to NNUE's efficiency.

==== Network Structure: Two Hidden Layers

The network has a simple feedforward architecture:

```
Input (40962 binary features)
  └─→ Hidden Layer 1 (40962 × 256 weights, + 256 biases)
       └─→ Clipped ReLU activation
            └─→ Hidden Layer 2 (256 × 32 weights, + 32 biases)
                 └─→ Clipped ReLU activation
                      └─→ Output (32 × 1 weights, + 1 bias)
                           └─→ Single scalar = evaluation (centipawns)
```

Wait - 40962 × 256 = 10,486,272 weights just for the first layer. That is far too many to compute per evaluation. This is where the *incremental update* trick comes in.

==== Quantization: Integer Math for Speed

NNUE networks use integer arithmetic (not floating point) for inference. The weights are stored as 16-bit signed integers (int16), and the activations use 8-bit or 16-bit integers. This enables the use of fast integer SIMD instructions (SSE2, AVX2, AVX-512) that process 8, 16, or 32 elements simultaneously.

The quantization scheme:

1. *Weights* are trained in floating point, then *quantized* to int16 by multiplying by a scale factor and rounding:

```c
int16_t quantized_weight = (int16_t)round(weight * WEIGHT_SCALE);
// WEIGHT_SCALE is typically 64 or 128, chosen so that weights fit in int16 range
```

2. *Activations* are the output of each neuron after the activation function. Since activations are produced by `ReLU(w1*a1 + w2*a2 + ... + b)` applied to quantized weights and binary inputs, the products stay in a manageable integer range.

3. *Bias terms* are stored as int32 to preserve precision.

4. During inference, the accumulator (the sum of weighted features) is stored in int32 for the first layer and int16 or int32 for subsequent layers.

==== The Clipped ReLU Activation

The activation function is *clipped ReLU* (Rectified Linear Unit with a ceiling):

```
f(x) = clamp(x, 0, MAX_ACTIVATION)
```

Where `MAX_ACTIVATION` is typically 127 (for int8 activations) or 255. The clipping prevents activation explosion from cascading through the layers. This is equivalent to the standard `ReLU(x) = max(0, x)` but with an upper bound.

=== The Incremental Update: Why NNUE Is Fast

The brilliant idea that makes NNUE practical for chess engines:

*Problem*: 40,962 input features × 256 hidden neurons = 10.5 million multiply-accumulate operations per evaluation. At even 1 billion operations per second (typical CPU), that is 10 milliseconds per evaluation—100× too slow.

*Observation*: Most features are the same between consecutive positions in a search. When we make a move on the board, only a few pieces change position. The king almost never moves (castling excepted). Therefore, only a small number of input features change between position `P` and position `P'` = `make_move(P, m)`.

*Solution*: Instead of recomputing the entire first-layer output from scratch, maintain an *accumulator* — a 256-element array (or two, for Color_US and Color_THEM) that stores the current state of the first hidden layer's weighted sum (before activation). When making a move, we:

1. Identify which input features changed (typically 2-4 features: the moving piece leaves its origin, arrives at its destination, and captured piece is removed).
2. Add or subtract only the weight vectors for those changed features.

```c
// Accumulator: sum over all active features of their weight vectors
// acc[i] = sum_{f: feature[f] active} weight[f][i]

// When feature f becomes active (piece appears on square):
for (int i = 0; i < 256; i++)
    acc[i] += weight[f][i];

// When feature f becomes inactive (piece leaves square):
for (int i = 0; i < 256; i++)
    acc[i] -= weight[f][i];
```

This reduces the per-evaluation work from 10.5 million operations to only 2-4 features × 256 neurons × 2 (add + subtract) = 1,024-2,048 operations. That is a 5,000× speedup.

==== The Accumulator Refresh

The accumulator must be correct for the position being evaluated. When entering a new position (e.g., at the start of search, or after a long sequence of make/undo moves), we cannot incrementally update from an incorrect accumulator. We must *refresh* the accumulator from scratch:

```c
void refresh_accumulator(Position *pos) {
    // Zero the accumulator
    memset(accumulator, 0, 256 * sizeof(int32_t));

    // For every piece on the board, add its feature weight vectors
    for (int sq = 0; sq < 64; sq++) {
        int piece = pos->board[sq];
        if (piece == EMPTY) continue;
        int feature_index = get_feature_index(pos, sq, piece);
        for (int i = 0; i < 256; i++)
            accumulator[i] += weights[feature_index][i];
    }
}
```

A full refresh requires evaluating all ~30 pieces × 256 neurons = 7,680 operations—still far cheaper than 10.5 million, but more than incremental update. In practice, the accumulator is refreshed once at the start of the search (or when search depth resets), and all subsequent evaluations within the search tree use incremental updates.

==== Dual Accumulator: Us and Them

A critical detail: the NNUE evaluation is computed from the perspective of the side to move (Us), but the features are defined relative to *both* kings. Therefore, we maintain two accumulators:

1. *Accumulator for White's perspective*: Features computed as if White is "Us" (the side to move).
2. *Accumulator for Black's perspective*: Features computed as if Black is "Us."

When it is White's turn, we use the White accumulator to compute the evaluation. When it is Black's turn, we use the Black accumulator. This avoids recomputing the entire input from the opponent's perspective on each ply.

The two accumulators are near-mirror images: swapping the board colors effectively swaps the accumulators (with appropriate sign changes). This means we can incrementally update only the accumulator for the side that just moved, and swap accumulators when the side to move changes.

==== Incremental Update in Practice

```c
// When making move m in position pos:
void make_move_nnue_update(Position *pos, Move m) {
    int from_sq = move_from(m);
    int to_sq   = move_to(m);
    int moving_piece = pos->board[from_sq];
    int captured_piece = pos->board[to_sq];
    int our_king_sq = king_square(pos, pos->side);
    int their_king_sq = king_square(pos, !pos->side);

    // Remove moving piece from from_sq (deactivate feature)
    int feature_f = feature_index(our_king_sq, moving_piece, from_sq);
    accumulator_sub(accumulator[US], weights[feature_f]);

    // Remove captured piece from to_sq (deactivate feature)
    if (captured_piece != EMPTY) {
        int feature_c = feature_index(our_king_sq, captured_piece, to_sq);
        accumulator_sub(accumulator[US], weights[feature_c]);
    }

    // Add moving piece at to_sq (activate feature)
    int feature_t = feature_index(our_king_sq, moving_piece, to_sq);
    accumulator_add(accumulator[US], weights[feature_t]);

    // If en passant, remove the captured pawn (which is not on to_sq)
    if (move_is_en_passant(m)) {
        int ep_capture_sq = en_passant_capture_square(m);
        int feature_ep = feature_index(our_king_sq, PAWN, ep_capture_sq);
        accumulator_sub(accumulator[US], weights[feature_ep]);
    }

    // If castling, update the rook as well

    // Actually make the move on the board (update bitboards, etc.)
    make_move_actual(pos, m);
}
```

The accumulator update is performed *before* the board state is actually changed, using the old board positions and the information about what is about to change.

==== Fold and ReLU: From Accumulator to Output

The accumulator stores `h1_pre[i]` — the pre-activation values for the first hidden layer. To compute the final evaluation:

```c
int evaluate_from_accumulator(int *accumulator_us, int *accumulator_them) {
    // Layer 1: apply ClippedReLU to the accumulator
    int16_t h1_us[256], h1_them[256];
    for (int i = 0; i < 256; i++) {
        h1_us[i]  = clamp(accumulator_us[i], 0, MAX_ACTIVATION);
        h1_them[i] = clamp(accumulator_them[i], 0, MAX_ACTIVATION);
    }

    // Layer 2: h2[j] = ReLU(sum_i h1[i] * w2[i][j] + b2[j])
    int16_t h2_us[32], h2_them[32];
    for (int j = 0; j < 32; j++) {
        int sum_us = 0, sum_them = 0;
        for (int i = 0; i < 256; i++) {
            sum_us  += h1_us[i]  * weight2[i][j];
            sum_them += h1_them[i] * weight2[i][j];
        }
        h2_us[j]  = clamp(sum_us  + bias2[j], 0, MAX_ACTIVATION);
        h2_them[j] = clamp(sum_them + bias2[j], 0, MAX_ACTIVATION);
    }

    // Output layer: eval = sum_j h2[j] * w3[j] + b3
    int eval_us = 0, eval_them = 0;
    for (int j = 0; j < 32; j++) {
        eval_us  += h2_us[j]  * weight3_us[j];
        eval_them += h2_them[j] * weight3_them[j];
    }
    eval_us  += bias3_us;
    eval_them += bias3_them;

    // Combine: evaluation from both perspectives
    return (eval_us - eval_them) / OUTPUT_SCALE;
}
```

The actual implementation in Stockfish uses SIMD intrinsics to process 16-32 elements simultaneously, making the forward pass extremely fast.

=== Feature Index Computation

The feature index for a given (king_square, piece, piece_square) tuple is:

```c
int feature_index(int king_sq, int piece, int piece_sq) {
    // piece encoding: 0=white pawn, 1=white knight, ..., 5=black pawn, ..., 9=black queen
    // Plus special "bucket" features for phase
    int piece_type = piece % 6;   // pawn=0, knight=1, ..., king=5
    int piece_color = piece / 6;  // white=0, black=1

    // Mirror piece_sq for black king perspective
    int relative_sq = piece_color == WHITE ? piece_sq : mirror_square(piece_sq);

    // King-relative square
    int relative_king_sq = king_sq;  // always from perspective of side to move

    // Feature index
    return relative_king_sq * 640 + piece_type * 128 + piece_color * 64 + relative_sq;
}
```

This produces an index in `[0, 40960)` for the HalfKP feature set, plus 2 extra indices for the bucket features (game phase indicators).

==== Feature Sparsity and Weight Sharing

The 40,962 feature space seems large, but:
- Only 64 king squares × 640 features = 40,960 features are possible.
- For a given position with king on square k, only 640 features are "addressable" (the features where the king_sq dimension matches). Of those, only 20-30 are active (the pieces on the board).
- This is a *factorized* feature space: king_sq is the "perspective" dimension and piece-on-sq is the "content" dimension.

Some newer architectures (HalfKA, HalfKP with larger feature sets) use factorized weight matrices to reduce the memory footprint while maintaining accuracy. For example, instead of 64 × 640 × 256 weights, factor into (64 × 16) × (640 × 16) = 64 × 640 × 16 weights × 2 layers, cutting the weight count by a factor of 8.

=== Network Architecture Variants

==== SFNNv1 through SFNNv9

Stockfish's NNUE architecture has evolved through several versions, known as SFNNv1 through SFNNv9 (Stockfish Neural Network version):

- *SFNNv1 (Stockfish 12)*: HalfKP feature set. 256×2×1 hidden sizes. The original. Combined with classical evaluation (hybrid).
- *SFNNv4 (Stockfish 14)*: Pure NNUE (classical eval removed). Larger hidden layer (512 or 2×256). HalfKA features.
- *SFNNv5 (Stockfish 15)*: Improved feature representation. King-bucketing for endgame/middlegame distinction.
- *SFNNv7 (Stockfish 16)*: Deeper network (3 hidden layers). Input factorization. Larger training data (billions of positions).
- *SFNNv9 (Stockfish 17)*: Dual network architecture. Small net (fast, for leaf nodes) + Big net (accurate, for root/PV nodes). The small net uses 128 hidden units, the big net uses 1024+.

Each version increases the network capacity (more weights), which improves accuracy but potentially slows inference. The dual-net approach resolves this tension by using a small, fast net at the leaves (where most evaluations happen) and a large, accurate net at the root and PV nodes (where accuracy matters most).

==== Network Size and Memory

A typical NNUE network file (`.nnue` format) is:

```text
SFNNv4 (HalfKP, 256×2×1):  ~20 MB
SFNNv5 (HalfKA, 512×2×1):  ~45 MB
SFNNv7 (512×2×32×1):       ~80 MB
SFNNv9 (big net):           ~150 MB
```

The weight matrices dominate the file size. For HalfKP with 256 hidden neurons:
- Layer 1: 40,962 × 256 = 10.49 million weights × 2 bytes/int16 = 21 MB.
- Layer 2: 256 × 32 = 8,192 weights × 2 bytes = 16 KB.
- Output: 32 weights × 2 bytes = 64 bytes.

The network is loaded into memory at engine startup. The 20-80 MB memory footprint is negligible for modern systems.

=== Training Pipeline

NNUE networks are trained from self-play data generated by the engine itself. This is a form of *reinforcement learning* where the engine generates its own training data by playing games and recording positions with their eventual outcomes.

==== Data Generation

The training data generation process (Stockfish's approach):

1. Start with a "base" version of the engine (e.g., Stockfish with the current best network).
2. Play millions of self-play games at a fixed depth or time control (typically depth 8-12 or 1+0.01 time control).
3. For each position in each game, record:
   - The FEN (or compact board encoding).
   - The game result (White win = 1.0, draw = 0.5, Black win = 0.0) from the perspective of the position's side to move.
   - Optionally, the search score (the engine's evaluation of the position at the time).
4. Discard positions that are too close to checkmate (the result is already determined by forced mate).
5. Filter positions to ensure diversity (avoid over-representation of common openings).

The training dataset typically contains 1-5 billion positions. Data generation takes days to weeks on a cluster of machines.

==== Loss Function and Optimization

The network is trained to predict the game outcome from a position. The loss function is typically *mean squared error* (MSE) between the predicted evaluation and the game result:

```
L = (1/N) * sum_i (eval(pos_i) - result_i)^2
```

Where `eval(pos_i)` is the raw network output (in some internal unit) and `result_i` is the game outcome (0, 0.5, or 1.0).

Some training pipelines use *cross-entropy loss* with a sigmoid output, which is theoretically better for probability calibration:

```
L = -sum_i [result_i * log(p(win)) + (1 - result_i) * log(1 - p(win))]
```

where `p(win) = sigmoid(eval(pos_i))`.

The optimization uses *stochastic gradient descent* with momentum (or Adam optimizer), typically with:

- *Batch size*: 10,000-100,000 positions (large batches for stable gradients).
- *Learning rate*: Starts at 0.001, decays by factor 0.3 when loss plateaus.
- *Data type*: Float32 during training, quantized to int16 after.
- *Epochs*: 1-5 passes through the training data (networks converge quickly due to the large dataset).

==== Quantization-Aware Training

Modern NNUE training uses *quantization-aware training*: the network is trained with simulated quantization noise, so it learns to be robust to the precision loss that occurs when the weights are quantized to int16.

During training:
1. Forward pass uses float32 weights.
2. Before computing the loss, simulate weight quantization by rounding float32 weights to int16-equivalent precision.
3. Backward pass uses the "straight-through estimator" — gradients flow through the rounding operation as if it were the identity function (the gradient of round(x) is treated as 1).
4. The network learns to produce correct outputs *despite* having reduced precision weights.

This typically improves quantized accuracy by 2-5 ELO compared to post-training quantization (training in float32, then rounding after).

==== Validation

After training, the new network is validated by playing matches against the previous best network:

1. Play 20,000-60,000 games at fast time control (e.g., 10+0.1 seconds).
2. Measure ELO difference using a rating program (e.g., Ordo, Bayeselo).
3. If the new network scores over 50% with statistical significance (typically p under 0.05, or +1.5 ELO with LOS over 95%), it becomes the new default network.

This *fishtest* framework (Stockfish's distributed testing infrastructure) ensures rigorous validation. A typical network improvement of +2-3 ELO passes after 50,000+ games.

=== Inference in Search: When to Evaluate

The NNUE evaluation is fast (~500 nanoseconds per call), but it is still the most expensive operation per node in the search tree. The search engine does not call NNUE at every node:

1. *Transposition table cutoffs*: If the position is found in the TT with sufficient depth, the stored score is used directly—no NNUE evaluation needed.

2. *Null-move pruning*: If the static evaluation (from the accumulator) is so good that even null-move pruning succeeds, we never need to do a full NNUE forward pass—the accumulator value alone (before ReLU and forward layers) is a cheap approximation.

3. *Evaluation at leaves only*: The search calls NNUE evaluation only at internal nodes that reach depth 0 (or when lazy eval permits). The accumulator is maintained incrementally throughout the search, and the forward pass is computed only when an actual evaluation is needed.

==== Lazy NNUE Evaluation

Some engines use *lazy evaluation*: if the accumulator's raw sum (before activation) is very high or very low, we can skip the forward pass and return a bound immediately. For example, if the accumulator sum suggests the material is overwhelmingly in one side's favor (more than a queen's worth even before positional features are applied by the hidden layers), we can return a fail-high score without the expense of the forward pass.

```c
int lazy_nnue_eval(int *accumulator) {
    int raw_sum = 0;
    for (int i = 0; i < 256; i++) raw_sum += accumulator[i];

    if (raw_sum > LAZY_THRESHOLD) return KNOWN_WIN_SCORE;
    if (raw_sum < -LAZY_THRESHOLD) return KNOWN_LOSS_SCORE;

    // Otherwise, do the full forward pass
    return nnue_forward(accumulator);
}
```

Lazy evaluation can skip the forward pass for 5-15% of evaluations, providing a minor speedup.

=== Hybridization: Classical + NNUE

Early NNUE engines (Stockfish 12-13) used a hybrid evaluation:

```
FinalScore = w * NNUE(position) + (1 - w) * Classical(position)
```

where `w` (typically 0.5-0.7) weights the NNUE score more heavily. The hybrid approach provided a safety net: if the NNUE mis-evaluated a position that the classical eval understood well (e.g., theoretical endgames, drawn positions with little data), the classical eval could "correct" it.

However, as NNUE networks improved, the classical component became unnecessary. Stockfish 14 removed classical evaluation entirely, going pure NNUE. The pure NNUE approach is simpler (one evaluation function to maintain and tune) and has higher peak strength, as the NNUE learns to recognize all the patterns the classical eval once handled.

==== Special Endgame Handling

Even pure NNUE engines retain some special-case evaluation for endgames where the NNUE might not have enough training data:

- *Theoretical drawn endgames* (KNN vs K, KB vs K): The engine's tablebase or endgame code returns a draw score regardless of NNUE.
- *Syzygy tablebase positions*: If the position is in the tablebase with a definite outcome, the tablebase score overrides NNUE.
- *Material-only scaling*: In extremely simplified endgames (e.g., KQ vs K), the engine can use a simple material evaluator to avoid any NNUE computation.

=== Inference Performance Optimization

NNUE inference is heavily optimized using SIMD (Single Instruction, Multiple Data) CPU instructions. Each CPU generation provides wider SIMD registers:

- *SSE2*: 128-bit registers, processes 8× int16 per instruction.
- *AVX2*: 256-bit registers, processes 16× int16 per instruction.
- *AVX-512*: 512-bit registers, processes 32× int16 per instruction. (Some engines, notably Stockfish, use AVX-512 via VNNI—Vector Neural Network Instructions—specifically designed for int8/int16 neural network inference.)

Typical inference times:

```text
Architecture        Time per eval    Evals per second (single core)
─────────────────   ─────────────    ─────────────────────────────
x86-64 (SSE2)       800 ns           1.25M
x86-64 (AVX2)       500 ns           2.0M
x86-64 (AVX-512)    350 ns           2.86M
Apple Silicon (NEON) 450 ns          2.2M
```

At 2 million evaluations per second, a single core of a modern CPU can evaluate every node in a 10 million node/second search in about 5 seconds—half of the search time is evaluation, the other half is move generation, make/unmake, and TT probes.

=== C Implementation: Simplified NNUE

While production NNUE implementations use heavily optimized SIMD intrinsics, a pedagogical implementation clarifies the core algorithm:

```c
// ===== Network structure =====
#define INPUT_SIZE   40960  // HalfKP features (64 * 640)
#define HIDDEN_SIZE  256
#define OUTPUT_SIZE  1

int16_t weight1[INPUT_SIZE][HIDDEN_SIZE];   // L1 weights
int32_t bias1[HIDDEN_SIZE];                  // L1 biases
int16_t weight2[HIDDEN_SIZE][32];           // L2 weights
int32_t bias2[32];                           // L2 biases
int16_t weight3[2][32];                      // Output weights (US and THEM)
int32_t bias3[2];                            // Output biases

// ===== Accumulator =====
int32_t accumulator_us[HIDDEN_SIZE];
int32_t accumulator_them[HIDDEN_SIZE];

void accumulator_add(int32_t *acc, int16_t *weights) {
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        acc[i] += weights[i];
    }
}

void accumulator_sub(int32_t *acc, int16_t *weights) {
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        acc[i] -= weights[i];
    }
}

// ===== Full refresh (called at start of search) =====
void refresh_accumulator(Position *pos) {
    memset(accumulator_us, 0, sizeof(accumulator_us));
    memset(accumulator_them, 0, sizeof(accumulator_them));

    int w_king = pos->white_king_sq;
    int b_king = pos->black_king_sq;

    for (int sq = 0; sq < 64; sq++) {
        int piece = pos->board[sq];
        if (piece == EMPTY) continue;

        int piece_type = piece % 6;
        int piece_color = piece / 6;
        int relative_sq_w = piece_color == WHITE ? sq : sq ^ 56;
        int relative_sq_b = piece_color == BLACK ? sq : sq ^ 56;

        // White perspective (Us = White)
        int feature_w = w_king * 640 + piece_type * 128 + piece_color * 64 + relative_sq_w;
        accumulator_add(accumulator_us, weight1[feature_w]);

        // Black perspective (Us = Black)
        int feature_b = b_king * 640 + piece_type * 128 + (1 - piece_color) * 64 + relative_sq_b;
        accumulator_add(accumulator_them, weight1[feature_b]);
    }
}

// ===== Forward pass =====
int evaluate_nnue(int *acc_us, int *acc_them) {
    // Layer 1: ClippedReLU
    int16_t h1_us[HIDDEN_SIZE], h1_them[HIDDEN_SIZE];
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        h1_us[i]  = clamp(acc_us[i]  + bias1[i], 0, 255);
        h1_them[i] = clamp(acc_them[i] + bias1[i], 0, 255);
    }

    // Layer 2: 256 -> 32
    int h2_us[32] = {0}, h2_them[32] = {0};
    for (int j = 0; j < 32; j++) {
        for (int i = 0; i < HIDDEN_SIZE; i++) {
            h2_us[j]  += h1_us[i]  * weight2[i][j];
            h2_them[j] += h1_them[i] * weight2[i][j];
        }
        h2_us[j]  = clamp(h2_us[j]  + bias2[j], 0, 255);
        h2_them[j] = clamp(h2_them[j] + bias2[j], 0, 255);
    }

    // Output layer
    int eval_us = bias3[0], eval_them = bias3[1];
    for (int j = 0; j < 32; j++) {
        eval_us  += h2_us[j]  * weight3[0][j];
        eval_them += h2_them[j] * weight3[1][j];
    }

    return (eval_us - eval_them) / 16;  // scale to centipawns
}
```

=== C++ Implementation: SIMD Accelerated Forward Pass

In practice, the forward pass uses SIMD intrinsics to process 16 elements at a time:

```cpp
#include <immintrin.h>  // AVX2 intrinsics

void forward_pass_avx2(int16_t *h1, int32_t *output, int16_t *w2, int32_t *b2) {
    __m256i sum = _mm256_loadu_si256((__m256i*)b2);  // load biases

    for (int i = 0; i < 256; i += 16) {
        // Load 16 h1 activations (as 16-bit values)
        __m256i h1_16 = _mm256_loadu_si256((__m256i*)&h1[i]);

        // For each output neuron j in chunks of 16:
        for (int j = 0; j < 32; j += 16) {
            __m256i w = _mm256_loadu_si256((__m256i*)&w2[i * 32 + j]);
            // Multiply h1 * w and accumulate (int16 * int16 -> int32)
            __m256i prod = _mm256_madd_epi16(h1_16, w);
            sum = _mm256_add_epi32(sum, prod);
        }
    }

    _mm256_storeu_si256((__m256i*)output, sum);
}
```

The `_mm256_madd_epi16` instruction performs 16 multiply-accumulate operations (int16 × int16 → int32 accumulation) in a single cycle. This is the workhorse of NNUE inference.

=== Pseudocode: Incremental Accumulator Management

The complete accumulator management through a search node:

```text
function search(position, depth, alpha, beta):
    if position_hash in TT and TT.depth >= depth:
        return TT.score

    if depth == 0:
        return nnue_evaluate(position.accumulator_us, position.accumulator_them)

    for move in generate_moves(position):
        # Identify which features change for this move
        (added_features, removed_features) = compute_feature_changes(position, move)

        # Update accumulator incrementally
        for f in removed_features:
            accumulator_sub(accumulator_us, weight1[f])
        for f in added_features:
            accumulator_add(accumulator_us, weight1[f])

        # Make the move on the board
        make_move(position, move)

        # Swap accumulators (Us becomes Them, and vice versa)
        swap(accumulator_us, accumulator_them)

        # Recurse
        score = -search(position, depth-1, -beta, -alpha)

        # Undo move
        unmake_move(position, move)

        # Swap back accumulators
        swap(accumulator_us, accumulator_them)

        # Restore accumulator (undo the incremental update)
        for f in added_features:
            accumulator_sub(accumulator_us, weight1[f])
        for f in removed_features:
            accumulator_add(accumulator_us, weight1[f])

        # Alpha-beta update
        ...

    return best_score
```

The key insight: the accumulator update cost is proportional to the number of changed features (typically 2-4), not the number of total features (40,962). This is what makes NNUE evaluation practical inside the search tree.

=== Feature Representation Variants

==== HalfKP (King-Piece)

As described above: 64 king squares × 640 piece-square features. Each feature answers: "Given the king is on square K, is there piece P on square S?" This captures king-relative piece positions.

Strength: Simple, effective, well-studied. 
Weakness: Does not explicitly encode piece-piece relationships (beyond both being relative to the king).

==== HalfKA (King-Attacker/Defender)

Improves on HalfKP by distinguishing whether a piece is an "attacker" or "defender" based on whether it is attacking an enemy square or defending a friendly square. This gives the network more direct information about piece interactions.

==== HalfKP with Buckets

Adds "bucket" features that encode the game phase. Instead of a single network for all phases, the feature space includes phase indicators that effectively give the network separate sub-architectures for different material configurations.

==== Full KP (King-Piece, symmetric)

Uses all 64 × 64 × 10 = 40,960 features but with explicit encoding of the absolute piece position (not just king-relative). This increases accuracy but eliminates the incremental update advantage for king moves (rare but must be handled). Most engines use HalfKP for speed.

=== Training Data Quality

The quality of training data is the most important factor in NNUE strength. Better data → stronger networks, regardless of architecture.

==== Data Generation Strategies

1. *Self-play with the best network*: The engine plays against itself using the current best network. This creates data that is "from the perspective" of a strong player.

2. *Multi-net self-play*: Multiple networks play against each other, creating more diverse data. This prevents the training from becoming too narrow (self-play with a single net can reinforce its own biases).

3. *Depth-controlled self-play*: Games are played at a controlled search depth (e.g., depth 8 for the training net, depth 12 for the opponent). This creates positions where the eval is meaningful at different search depths.

4. *Book variety*: Opening books ensure diverse starting positions so the training data covers all phases of the game and all common structures.

5. *Adjudication*: Games are adjudicated as wins/draws when the evaluation exceeds a threshold for a certain number of moves, saving computation.

==== Data Filtering

Not all positions are equally valuable for training:

- *Quiet positions*: Positions where the best move is clear (large eval gap) are good training data because the "right answer" is unambiguous.
- *Tactical positions*: Positions where the eval changes sharply between moves are less useful because the eval at a single position does not predict the outcome well.
- *Resign positions*: Positions where one side is absolutely winning (eval > +500) are filtered out because they provide trivial information.

Filtering typically reduces the raw game data by 50-70%, keeping only the most informative positions.

=== NNUE vs Classical Evaluation: A Comparison

```text
Aspect              Classical Eval        NNUE
─────────────────── ────────────────────  ───────────────────────────────
Feature Design      Handcrafted (human)   Learned from data (automatic)
Feature Count       20-50 explicit terms  40,000+ implicit features
Non-linearity       Minimal (mostly linear) 2-3 layers of learned non-linear interactions
Tuning              Manual + texel        Gradient descent + quantization
Time per evaluation  200-500 ns          350-800 ns (SIMD-optimized)
Memory footprint    < 1 KB (tables)      20-150 MB (weights)
Peak ELO            ~3100                 ~3600+
Maintenance         Requires chess expertise  Requires ML expertise + compute
```

NNUE is clearly superior for maximum playing strength, but classical evaluation remains valuable:
- For educational engines (understanding the eval logic).
- For resource-constrained environments (tiny memory footprint).
- As a fallback when NNUE networks are unavailable.
- For endgames where NNUE training data is sparse.

=== Future Directions

NNUE technology continues to evolve:

1. *Larger networks*: Current memory constraints (150 MB for the biggest nets) could rise to 500 MB or more, enabling deeper networks with more hidden units.

2. *Transformer-based evaluation*: Some experimental engines are applying transformer architectures to evaluation, treating the board as a sequence of piece features. Training is more expensive but potentially more accurate.

3. *Learned search*: Beyond evaluation, reinforcement learning is being applied to search heuristics (LMR reduction amounts, pruning decisions). Leela Chess Zero (Chapter 26) goes further, using an end-to-end neural approach for both policy and value.

4. *Hardware-specific optimization*: With the rise of dedicated AI accelerators (Apple Neural Engine, Intel AMX, NVIDIA Tensor Cores), NNUE inference could become even faster, enabling evaluation at every node of the search tree.

5. *Multi-modal evaluation*: Combining NNUE with small tablebases, opening books, or learned opening repertoires embedded in the evaluation.

=== Summary

NNUE represents the single largest leap in computer chess evaluation since Shannon's original proposal in 1950. The key ideas:

- *King-relative piece-square features*: 40,000+ binary features encode piece positions relative to the king, capturing most chess-relevant patterns.
- *Incremental accumulator update*: By maintaining a running sum of weighted features and updating only the changed features, evaluation speed approaches (or exceeds) classical evaluation.
- *Two-layer feedforward network*: Despite its simplicity, the two-hidden-layer architecture achieves remarkable accuracy because the input features are so rich.
- *Quantized integer computation*: Int16 weights and int8 activations, combined with SIMD instructions, make inference blazingly fast.
- *Self-play training*: Billions of positions generated through self-play, trained with MSE loss, quantized, and validated through rigorous fishtest matches.

NNUE has raised the ceiling of chess engine strength far beyond what classical evaluation could achieve. Understanding NNUE—both its mathematical structure and its engineering optimizations—is now an essential part of the chess engine developer's toolkit.
