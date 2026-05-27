= Appendix A: Math Reference

This appendix collects the mathematical formulas, identities, and statistical tools used throughout the textbook. It is designed as a quick reference—each entry is brief, with cross-references to the chapters where the concept is applied.

== Bitwise Operations

=== Basic Operators

```text
a & b     Bitwise AND                                      Ch. 3
a | b     Bitwise OR                                       Ch. 3
a ^ b     Bitwise XOR (exclusive OR)                        Ch. 3
~a        Bitwise NOT (complement)                          Ch. 3
a << n    Left shift: a × 2^n                               Ch. 3
a >> n    Right shift: a / 2^n (logical, for unsigned)     Ch. 3
```

=== Common Bit-Twiddling Idioms

```text
Isolate LSB:           lsb = x & -x                        Ch. 4
Clear LSB:             x = x & (x - 1)                     Ch. 4
Isolate bit at position n:  bit = x & (1ULL << n)          Ch. 3
Test if power of two:  (x != 0) && !(x & (x - 1))          Ch. 5
Population count:      __builtin_popcountll(x)              Ch. 4, 19
Count trailing zeros:  __builtin_ctzll(x)                   Ch. 4
Count leading zeros:   __builtin_clzll(x)                   Ch. 19
Bit scan forward:      __builtin_ffsll(x) - 1               Ch. 4
Byte swap:             __builtin_bswap64(x)                 Ch. 3 (hash)
Rotate left:           (x << n) | (x >> (64 - n))           Ch. 3
```

=== Square Index Operations

```text
Square from rank,file:  sq = rank * 8 + file               Ch. 2
Rank from square:        rank = sq >> 3                     Ch. 2
File from square:        file = sq & 7                      Ch. 2
Mirror square (rank):    sq ^ 56  (flip 0↔7, 1↔6, ...)    Ch. 3
Mirror square (file):    sq ^ 7   (flip a↔h, b↔g, ...)    Ch. 3
```

== Probability and Statistics

=== SPRT (Sequential Probability Ratio Test)

Used for engine testing (Chapter 18).

```text
LLR = Σ log(P(X_i | H1) / P(X_i | H0))
Accept H1 if LLR ≥ log((1-β) / α)
Accept H0 if LLR ≤ log(β / (1-α))
```

Where α = Type I error rate (false positive, typically 0.05), β = Type II error rate (false negative, typically 0.05).

=== Elo Rating System

The logistic Elo model (Chapter 18):

```text
Expected score E = 1 / (1 + 10^(-Δ/400))
Elo difference Δ = -400 × log10(1/E - 1)
```

Standard error for a match of N games with win rate w, loss rate l, draw rate d:

```text
Var(score) ≈ (w(1-E)² + l(0-E)² + d(0.5-E)²) / N
SE(Elo) ≈ 400 × sqrt(Var(score)) / (E(1-E) × ln(10))
95% CI: Δ ± 1.96 × SE
```

=== Logistic Regression for Tuning

The Texel tuning method (Chapter 17) uses logistic regression:

```text
P(win | position) = 1 / (1 + e^(-eval(position)))
Sigmoid: σ(x) = 1 / (1 + e^(-x))
Derivative: σ'(x) = σ(x)(1 - σ(x))
```

Loss function (cross-entropy):

```text
L = -[y × log(σ(eval)) + (1-y) × log(1-σ(eval))]
```

== Search Complexity

=== Branching Factor and Node Counts

For a search tree with branching factor b and depth d:

```text
Minimax nodes:        b^d                               Ch. 5
Alpha-beta (perfect ordering):  b^(d/2)                 Ch. 5
Alpha-beta (expected):          b^(3d/4)                Ch. 5
```

Effective branching factor (EBF): the d-th root of the node count. A strong engine achieves EBF ≈ 2.0-3.0 (vs. b ≈ 35 without pruning).

=== Transposition Table Mathematics

Probability of a type-1 collision (index match): P(collision) = (useful TT probes) / (2^N_bits). For a 64-bit hash key with 32-bit index, collisions are extremely rare for practical TT sizes.

== Combinatorics

=== Number of Chess Positions

```text
Shannon's estimate:  ~10^43 positions
Improved estimate:   ~10^44 positions (counting promotions)
Number of games:     ~10^120 (Shannon number)
Unique legal positions: unknown, ~10^40 - 10^50
```

=== Perft Results (Initial Position)

```text
Depth   Nodes
1       20
2       400
3       8,902
4       197,281
5       4,865,609
6       119,060,324
7       3,195,901,860
```

== Information Theory

=== Zobrist Hashing Collision Probability

Probability of a false TT match across G game states: P(collision) ≈ G² / (2 × 2^64). For G = 10^9 positions searched: P ≈ 2.7 × 10^(-2)—approximately 2.7%.

=== Move Encoding

```text
Compact 16-bit move format (Stockfish-like):
  Bits 0-5:    from square (6 bits)
  Bits 6-11:   to square (6 bits)  
  Bits 12-13:  promotion piece (2 bits: 0=Knight, 1=Bishop, 2=Rook, 3=Queen)
  Bits 14-15:  special flags (2 bits: 0=normal, 1=promotion, 2=en passant, 3=castling)
```

== Numerical Constants

```text
Piece Values (centipawns, approximate):
  Pawn: 100, Knight: 320, Bishop: 330, Rook: 500, Queen: 900

MATE_SCORE:   ~32,000 (or ~1,000,000 in some engines)
INFINITY:     MATE_SCORE

Typical Phase Values (for tapered eval):
  Total phase = 24, Knight=1, Bishop=1, Rook=2, Queen=4, Pawn=0, King=0
  
MVV-LVA Values (for capture move ordering, Chapter 9):
  Pawn: 100, Knight: 200, Bishop: 300, Rook: 400, Queen: 500, King: 600
  MVV_LVA = victim_value * 64 - attacker_value
```

== Magic Bitboard Formula

```text
index = (blockers × magic) >> shift
attack = magic_table[square][index]

Where:
  blockers = occupied_squares & mask
  mask = squares a slider attacks on an empty board
  magic = found by trial-and-error search
  shift = 64 - popcount(mask)
```

== NNUE Mathematics

```text
HalfKP input features: 64 × 64 × 5 × 2 = 40,960
Accumulator size: 512 (int16)
Feature Transformer: 40,960 × 1 (sparse) → 512

Affine layer: output = Clip(weights × input + bias, 0, MAX)
ClippedReLU: min(max(x, 0), MAX) where MAX = 127 for int8

Quantized inference:
  weights: int16 → int8 (with scale factor)
  activation: int8 → int8
  output: int32 → centipawns
```

== Gradient Descent

Used for NNUE training (Chapters 13, 17):

```text
Gradient descent:  θ_new = θ_old - η × ∇L(θ)
Adam optimizer:    adaptive learning rate per parameter
Backpropagation:   chain rule applied recursively through network layers
```

== Cache Mathematics

```text
Cache line size:      64 bytes (typical x86/ARM)
L1 cache:             32 KB data + 32 KB instruction
L2 cache:             256 KB - 1 MB per core

TT entry size:        16 bytes (8 key + 2 move + 2 score + 2 depth + 1 flag + 1 padding)
Entries per 64-byte cache line: 4
TT miss penalty:      ~100 cycles (main memory access)
TT hit:               ~4-12 cycles (L1 hit)
```

=== Amdahl's Law

For parallel search (Chapter 14): Speedup = 1 / (s + (1-s)/p). For chess engines with Lazy SMP, s ≈ 0.03-0.05, yielding near-linear speedup to ~16 threads.
