== Evaluation Tuning: Automating Chess Knowledge

The evaluation function is the heart of a chess engine—it encodes everything the engine "knows" about which positions are good and which are bad. In the early days of computer chess, evaluation functions were hand-crafted by experts who encoded their chess knowledge as weighted features: pawn structure, king safety, piece activity, and so on. Modern engines have moved beyond hand-tuning to *automated optimization*: using statistical methods to derive optimal evaluation weights from millions of positions.

This chapter covers the theory and practice of evaluation tuning: the texel tuning method (logistic regression for evaluation parameters), SPSA (gradient-free optimization), the relationship to NNUE training, and the critical question of preventing overfitting.

=== Why Tune Automatically?

Hand-tuning an evaluation function is challenging for several reasons:

1. *Combinatorial explosion*: A typical HCE (Hand-Crafted Evaluation) might have 1,000-5,000 tunable parameters (piece-square tables, material weights, positional bonuses, and their interactions). Manually adjusting these parameters is an exercise in frustration—changing one value ripples through all others.

2. *Non-intuitive interactions*: A bonus for a knight on e5 is worth more if the opponent cannot challenge it with a pawn. This interaction is hard to anticipate manually but emerges naturally from statistical tuning.

3. *Human bias*: Hand-tuned evaluations reflect the author's chess understanding, which may be flawed or incomplete. Automated tuning learns from *objective* outcomes (game results, tablebase results) rather than human intuition.

4. *Incremental improvement*: Automated tuning can squeeze out the last 5-10 ELO from a hand-tuned evaluation by finding non-obvious parameter adjustments that collectively add up.

The result: an automated tuning pipeline can improve an engine by 50-150 ELO over a carefully hand-tuned evaluation, purely by optimizing the same set of features.

=== The Texel Tuning Method

*Texel tuning* (named after the Texel chess engine by Peter Österlund, though the method is general) is the most widely used approach for tuning HCE parameters. It frames evaluation tuning as a *logistic regression* problem: given a set of positions with known outcomes, find the parameter weights that maximize the likelihood of predicting the correct outcome.

==== Problem Formulation

Given:

- A set of `N` training positions `x_i`, each labeled with a game outcome `y_i` (where `y_i = 1` for a White win, `y_i = 0` for a draw, `y_i = -1` for a Black win).
- An evaluation function `E(x, w)` that computes a score in centipawns for position `x` given parameter vector `w`.
- A sigmoid function that maps evaluation to winning probability:

`P(win | score) = 1 / (1 + exp(-score / K))`

where `K` is a scaling constant (typically around 1.0-1.5) that controls the "steepness" of the sigmoid. Larger `K` makes the sigmoid flatter (more draws at moderate scores); smaller `K` makes it steeper (more decisive).

The goal: find `w` that maximizes the *likelihood* of the observed outcomes, or equivalently, minimizes the *negative log-likelihood* (cross-entropy loss):

`L(w) = -sum_i [y_i * log(P_i) + (1 - y_i) * log(1 - P_i)]`

where `P_i = sigmoid(E(x_i, w))` and `y_i` is mapped to the range [0, 1].

==== The Training Data

The quality of tuning depends critically on the training data. Good training data should be:

1. *Representative*: Covers all phases of the game (opening, middlegame, endgame) and all types of positions (quiet, tactical, imbalanced).

2. *Accurately labeled*: Outcomes are known with high confidence. Sources include:
   - *Self-play games*: The engine plays against itself at a fixed depth or time control. The final game result (win/draw/loss) labels every position in the game. This is the most common approach.
   - *Tablebase positions*: For endgames with ≤7 pieces, the exact WDL outcome is known. These provide perfect labels for the endgame phase.
   - *Human games*: Datasets like CCRL and CEGT contain millions of engine games with known results.

3. *Large*: Typically 1-10 million positions. More data reduces variance in the parameter estimates. For N parameters, a rule of thumb is `N * 1000` training positions.

4. *Filtered*: Positions near checkmate, with extreme material imbalances, or where the outcome is obvious should be filtered out (they add noise without signal). Quiet positions (quiescence search score = static evaluation) are the most informative.

A typical filtering pipeline:

```python
def filter_position(pos, score, static_eval):
    # Skip positions with extreme eval (already decided)
    if abs(static_eval) > 500:  # more than +5 pawns
        return False
    # Skip positions where qsearch score differs from static eval
    # (these are tactically volatile and not informative for static eval)
    if abs(score - static_eval) > 50:
        return False
    return True
```

==== Optimization: Local Search with K-Beam

The texel tuning objective is non-convex and high-dimensional (thousands of parameters), making global optimization intractable. The standard approach is *local search*: start from a reasonable initial point (hand-tuned weights) and iteratively improve.

The most common algorithm is *coordinate descent with K-beam*:

1. For each parameter in turn, try `K` candidate values (the current value and small perturbations: `current ± delta`, `current ± 2*delta`).
2. For each candidate, compute the loss over a subset of the training data (a "mini-batch" of 100K-500K positions).
3. Keep the candidate that minimizes the loss.
4. Move to the next parameter.
5. After a full pass over all parameters, reduce the step size `delta`.
6. Repeat until convergence (3-5 full passes).

```python
def texel_tune(params, positions, results, epochs=5, k=3):
    K = 1.0  # sigmoid scaling
    delta = 5.0  # initial step size

    for epoch in range(epochs):
        for i in range(len(params)):
            best_loss = float('inf')
            best_val = params[i]

            # Try K candidate values
            candidates = [params[i] + j*delta for j in range(-k, k+1)]
            for val in candidates:
                params[i] = val
                loss = compute_loss(params, positions, results, K)
                if loss < best_loss:
                    best_loss = loss
                    best_val = val

            params[i] = best_val

        delta *= 0.5  # reduce step size
        print(f"Epoch {epoch}, delta={delta}, loss={best_loss}")

    return params

def compute_loss(params, positions, results, K):
    total_loss = 0.0
    for pos, result in zip(positions, results):
        eval = evaluate(pos, params)
        p = 1.0 / (1.0 + math.exp(-eval / K))
        # Map result to [0,1]: WIN→1, DRAW→0.5, LOSS→0
        y = (result + 1) / 2  # WIN=1, DRAW=0, LOSS=-1 → y=1, 0.5, 0
        total_loss += -(y * math.log(p + 1e-10) + (1-y) * math.log(1-p + 1e-10))
    return total_loss / len(positions)
```

==== Piece-Square Table Tuning

Piece-square tables (PSTs) are the most obvious target for texel tuning. A PST for a piece type has 64 values (one per square). For each square, the value represents the centipawn bonus/penalty for having that piece on that square. PSTs also encode piece values indirectly: the total material value of a piece is its average PST value plus any explicit material weights.

When tuning PSTs, it is common to enforce symmetry:

```python
def symmetrize_pst(pst, piece_type):
    # Mirror left-right: file f ↔ file 7-f
    for rank in range(8):
        for f in range(4):
            avg = (pst[rank][f] + pst[rank][7-f]) / 2
            pst[rank][f] = avg
            pst[rank][7-f] = avg
    return pst

def flip_for_black(pst_white):
    # Black's PST is White's PST flipped vertically
    pst_black = [[0]*8 for _ in range(8)]
    for r in range(8):
        for f in range(8):
            pst_black[r][f] = -pst_white[7-r][f]  # negated and mirrored
    return pst_black
```

After tuning, verify that PSTs make positional sense:
- Knights should prefer central squares (e4, d4, e5, d5).
- Rooks should prefer open files and the 7th rank.
- Kings should prefer safety (castled position) in the middlegame and centralization in the endgame.

==== Validation and Overfitting Prevention

The cardinal sin of tuning is *overfitting*: the tuned parameters perform well on the training data but poorly on unseen positions. Prevention strategies:

1. *Train/Validation Split*: Divide the data into 80% training, 20% validation. Tune on training; monitor loss on validation. If validation loss stops improving, stop tuning (early stopping).

2. *Time Control Generalization*: Tune on games played at fast time controls (e.g., 10s + 0.1s) but validate at longer time controls (60s + 1s). Parameters that overfit to fast games may not generalize to tournament time controls.

3. *Opponent Diversity*: If training on self-play, include positions from games against other engines in the validation set. This prevents the evaluation from becoming "self-referential" (optimized only for how the engine plays against itself).

4. *Parameter Regularization*: Add an L2 penalty to the loss function to discourage extreme parameter values:

`L_reg(w) = L(w) + lambda * sum(w_i^2)`

A small `lambda` (e.g., 0.0001) pushes parameters toward zero, preventing them from becoming excessively large.

=== SPSA: Simultaneous Perturbation Stochastic Approximation

SPSA (pronounced "spuh-sah") is a gradient-free optimization algorithm that is particularly effective for tuning chess evaluation functions. Unlike texel tuning (which evaluates the loss over the entire dataset for each candidate), SPSA estimates the gradient using only two function evaluations per iteration, making it suitable for very high-dimensional parameter spaces.

==== How SPSA Works

For a parameter vector `w` of dimension `p`:

1. Generate a random perturbation vector `delta` of dimension `p`, where each component is ±1 with equal probability.

2. Evaluate the loss at `w + c*delta` and `w - c*delta`, where `c` is a small perturbation size.

3. Estimate the gradient: `g = (L(w + c*delta) - L(w - c*delta)) / (2 * c * delta)`

4. Update: `w = w - a * g`, where `a` is the learning rate.

5. Decrease `a` and `c` over time according to a schedule.

The beauty of SPSA: it estimates the full p-dimensional gradient using only 2 function evaluations, regardless of p. For a chess engine with 2,000 parameters, texel tuning would need to evaluate the loss 2,000K times per epoch (for K candidates per parameter), while SPSA needs only 2 evaluations per iteration.

```python
def spsa_tune(params, train_data, epochs=10000):
    a = 1.0   # learning rate
    A = 100   # stability constant
    c = 5.0   # perturbation size
    alpha = 0.602  # learning rate decay
    gamma = 0.101  # perturbation decay

    best_params = params.copy()
    best_loss = compute_loss(params, train_data)

    for k in range(epochs):
        # Decay rates
        ak = a / (k + 1 + A)**alpha
        ck = c / (k + 1)**gamma

        # Random perturbation (+1 or -1 for each parameter)
        delta = np.random.choice([-1, 1], size=len(params))

        # Evaluate loss at w + c*delta and w - c*delta
        params_plus = params + ck * delta
        params_minus = params - ck * delta

        loss_plus = compute_loss(params_plus, train_data)
        loss_minus = compute_loss(params_minus, train_data)

        # Estimate gradient
        grad = (loss_plus - loss_minus) / (2 * ck * delta)

        # Update
        params = params - ak * grad

        # Track best
        current_loss = compute_loss(params, train_data)
        if current_loss < best_loss:
            best_loss = current_loss
            best_params = params.copy()

    return best_params
```

==== SPSA vs. Texel Tuning

| Aspect | Texel Tuning (Coordinate Descent) | SPSA |
|--------|-----------------------------------|------|
| Gradient required | No (enumerate candidates) | No (perturbation estimate) |
| Evaluations per parameter | O(K) per iteration | O(1) total per iteration |
| Effect with many params | Linear in param count | Constant |
| Convergence | Fast for small param count | Better for high-dim spaces |
| Noise robustness | Good | Excellent (averages over perturbations) |
| Implementation | Simple | Simple |
| Wall-clock time | Can be very slow (K·N evaluations) | Fixed time per iteration |

SPSA is preferred for engines with many parameters (>500) because its constant evaluation cost per iteration scales better. Texel tuning (or its batched variant) is preferred for smaller parameter counts where the exhaustive approach converges faster.

=== Nevergrad and Black-Box Optimization

*Nevergrad* is a Facebook/Meta open-source library for gradient-free optimization. It provides a collection of algorithms suitable for chess evaluation tuning, including:

- *CMA-ES* (Covariance Matrix Adaptation Evolution Strategy): A population-based method that maintains a distribution over the parameter space and adaptively updates it.
- *PSO* (Particle Swarm Optimization): Maintains a population of "particles" that explore the parameter space, sharing information about good regions.
- *OnePlusOne*: A simple evolutionary algorithm that mutates a single candidate and keeps it if it improves.

Integration with a chess engine:

```python
import nevergrad as ng

def tune_with_nevergrad(initial_params, num_iterations=1000):
    # Define the search space
    parametrization = ng.p.Array(shape=(len(initial_params),))
    parametrization.set_standardized_data(initial_params)

    # Define the loss function
    def loss_fn(params):
        return compute_loss(params, train_positions, train_results)

    # Create optimizer
    optimizer = ng.optimizers.CMA(parametrization, budget=num_iterations)

    # Run optimization
    recommendation = optimizer.minimize(loss_fn)
    return recommendation.value
```

The advantage of using Nevergrad is that you get access to state-of-the-art optimization algorithms without implementing them yourself. The trade-off is that each evaluation runs the full chess engine evaluation on all training positions, which is slow.

=== NNUE Training Overview

While NNUE (Efficiently Updatable Neural Network, covered in depth in Chapter 13) replaces the HCE entirely, its training follows principles similar to texel tuning—just at a much larger scale.

The NNUE training pipeline:

1. *Data Generation*: The engine plays millions of self-play games at moderate depth (depth 5-8) to generate training positions. Each position is labeled with the game outcome (win/draw/loss) and optionally with the search score (from a deeper search, to provide a more accurate target).

2. *Feature Extraction*: Each position is converted to a sparse binary feature vector (typically 40,960 features for the "HalfKP" architecture: 64 king squares × 64 piece squares × 10 piece types).

3. *Network Architecture*: A shallow network (2-3 layers) with a large input layer, a hidden layer (256-512 neurons), and a single output neuron producing the evaluation score.

4. *Training Algorithm*: Stochastic gradient descent (SGD) or Adam optimizer, minimizing the same cross-entropy loss as texel tuning.

5. *Quantization*: Post-training, the floating-point weights are quantized to integers (typically 16-bit or 8-bit) for efficient inference on CPUs.

```python
# Simplified NNUE training loop (conceptual)
import torch

model = NNUE(input_dim=40960, hidden_dim=256)
optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
criterion = torch.nn.BCEWithLogitsLoss()

for epoch in range(100):
    for batch in dataloader:
        features, results = batch  # results: 1=win, 0=draw, -1=loss
        optimizer.zero_grad()
        predictions = model(features)
        loss = criterion(predictions, results)
        loss.backward()
        optimizer.step()
```

The key difference from HCE tuning: NNUE training involves millions of parameters (compared to thousands for HCE), requiring deep learning frameworks (PyTorch, TensorFlow) and GPU acceleration.

=== The Tuning Pipeline: End-to-End

A complete tuning pipeline for a chess engine looks like this:

```
┌────────────────────────────────────────────────────────────┐
│                    TUNING PIPELINE                          │
│                                                             │
│  1. Generate Games                                          │
│     ├─ Self-play at fixed depth (5-8 ply)                   │
│     ├─ Collect positions + outcomes: 10M-50M positions      │
│     └─ Filter: quiet positions, balanced material          │
│                                                             │
│  2. Split Data                                              │
│     ├─ Training set: 80%                                    │
│     └─ Validation set: 20%                                  │
│                                                             │
│  3. Tune Parameters                                          │
│     ├─ Choose algorithm (Texel/SPSA/CMA-ES)                 │
│     ├─ Set initial weights (hand-tuned baseline)            │
│     └─ Run optimization for N epochs                        │
│                                                             │
│  4. Validate                                                 │
│     ├─ Compute validation loss                              │
│     ├─ Run engine-engine matches (new vs old params)        │
│     └─ Measure ELO difference at multiple time controls     │
│                                                             │
│  5. Deploy                                                   │
│     ├─ If ELO gain > threshold: accept new parameters       │
│     └─ Otherwise: investigate, adjust, retry               │
└────────────────────────────────────────────────────────────┘
```

==== Data Generation Code

```c
// Inside the engine: write training data during self-play
void write_training_data(Position *pos, int static_eval, int qsearch_score, float result) {
    // Format: FEN | static_eval | qsearch_score | result
    // FEN uniquely identifies the position
    // static_eval = HCE before search
    // qsearch_score = score after quiescence search
    // result = 1.0 (White win), 0.5 (draw), 0.0 (Black win)

    if (abs(static_eval) > 500) return;  // skip decided positions
    if (abs(qsearch_score - static_eval) > 50) return;  // skip tactical positions

    fprintf(training_file, "%s | %d | %d | %.1f\n",
            fen(pos), static_eval, qsearch_score, result);
}
```

==== Integration with the Engine

```c
// After tuning, the optimized parameters are embedded in the engine
typedef struct {
    // Material values (tuned)
    int piece_value[PIECE_NB];

    // Piece-square tables (tuned)
    int pst[PIECE_NB][SQUARE_NB];

    // Positional bonuses (tuned)
    int bishop_pair_bonus;
    int rook_open_file;
    int rook_semi_open_file;
    int knight_outpost;
    int passed_pawn_rank[8];
    int king_shield_bonus;
    int mobility_bonus[PIECE_NB];

    // ... hundreds more parameters
} EvalParams;

// Load tuned parameters from file or embed as constants
void load_tuned_params(EvalParams *params, const char *path) {
    FILE *f = fopen(path, "r");
    // Read each parameter from the file
    // ... (format: param_name value)
    fclose(f);
}
```

=== Practical Tuning Tips

1. *Start simple, then add complexity*: Tune PSTs first (6 × 64 = 384 parameters). Once those converge, add positional parameters. Tuning all parameters simultaneously from a random start rarely converges well.

2. *Use mini-batches for speed*: Computing the full loss over 10 million positions for each candidate is slow. Instead, evaluate over a random subset (mini-batch) of 100K-500K positions. The gradient estimate is noisier but much faster, and stochasticity can help escape local minima.

3. *Parallelize*: Tuning is embarrassingly parallel—evaluate candidates across multiple cores. With 16 cores, a 10M-position evaluation takes ~10 seconds instead of 3 minutes.

4. *Tune at multiple time controls*: Parameters that work at bullet (1s + 0.1s) may not work at classical (120min + 30s). Tune at the fastest time control for speed, but validate at longer controls.

5. *Track parameter drift*: If a parameter drifts far from its initial value, investigate. Sometimes the tuning algorithm finds a genuine improvement; sometimes it signals a bug in the loss computation.

6. *Deterministic evaluation*: Ensure the evaluation function is deterministic (no random noise, no time-dependent behavior). Non-deterministic evaluation makes tuning impossible because the loss is noisy.

=== Case Study: Tuning a Simple Evaluation

Consider a minimalist engine with 3 parameters: `PAWN_VALUE`, `KNIGHT_VALUE`, and `BISHOP_VALUE`. Hand-tuned initial values: `PAWN=100`, `KNIGHT=320`, `BISHOP=330`.

After texel tuning on 1M positions:

```text
Parameter      Initial    Tuned     Change
PAWN_VALUE     100        98        -2
KNIGHT_VALUE   320        335       +15
BISHOP_VALUE   330        345       +15
```

The tuning slightly devalues pawns and increases the value of minor pieces. This ~15 centipawn adjustment to knight and bishop values adds ~10 ELO in engine-vs-engine testing. Small changes, measurable impact.

For a full HCE with 2,000 parameters, typical ELO gains from tuning are 50-150 ELO over a hand-tuned baseline. For NNUE (millions of parameters), the gain is 200-400 ELO—which is why NNUE has largely replaced HCE in top engines.

=== Summary

Automated evaluation tuning transforms chess engine development from an art into a science:

- *Texel tuning*: Logistic regression on game outcomes, optimized via coordinate descent or local search. Best for small-to-medium parameter counts (under 500).
- *SPSA*: Gradient-free optimization using random perturbations. Best for high-dimensional parameter spaces (over 500 params). Two evaluations per iteration regardless of parameter count.
- *Nevergrad/CMA-ES*: Modern black-box optimizers available as libraries. Good for medium-scale tuning with flexible search spaces.
- *NNUE training*: Deep learning approach for neural network evaluation. Millions of parameters trained on GPU with SGD/Adam.
- *Validation*: Train/validation split, multi-time-control testing, and regularization prevent overfitting.

The tuning pipeline—generate data, tune, validate, deploy—is a continuous feedback loop that every competitive engine runs repeatedly. Each cycle squeezes out incremental ELO, and over dozens of cycles, the cumulative gain is substantial.
