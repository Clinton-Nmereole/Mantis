== Other Notable Engines

While Stockfish and LC0 dominate the headlines, the chess engine ecosystem is far richer than a two-horse race. Dozens of strong engines—many of them open source—push the frontier in their own ways, experimenting with novel architectures, evaluation techniques, and search innovations. This chapter surveys the most notable engines beyond the "Big Two," focusing on what makes each unique and what lessons their developers' choices offer.

=== Komodo: The MCTS Hybrid

Komodo, developed by Don Dailey (until his passing in 2013) and continued by Mark Lefler and Larry Kaufman, was the dominant engine of the early 2010s and remained a top-3 engine through the late 2010s. Komodo is notable for two key innovations: its Monte Carlo Tree Search implementation and its human-like evaluation designed by GM Larry Kaufman.

==== Monte Carlo Tree Search in an Alpha-Beta World

While LC0 made MCTS famous in chess, Komodo was experimenting with MCTS years earlier—but in a hybrid context. Komodo uses MCTS as a *supplementary* search, not a replacement for alpha-beta:

```text
Komodo Search Architecture:
  ├── Main search: Alpha-Beta with PVS (traditional)
  └── MCTS "scout": Explores alternative plans using random playouts
        → If MCTS finds a promising plan missed by alpha-beta,
          the main search incorporates it via search extensions
```

The MCTS scout is particularly valuable in closed positions where alpha-beta's horizon effect can be severe. By randomly sampling continuations, MCTS can "see" through quiet maneuvers that alpha-beta might prune too aggressively.

==== GM Kaufman's Evaluation

Larry Kaufman, a grandmaster and the primary author of Komodo's evaluation, brought genuine human chess understanding to the engine. Komodo's evaluation terms are remarkably intuitive:

- **Piece values that depend on phase and piece configuration**: The value of a bishop is not constant; it depends on the pawn structure (open diagonals, friendly pawns on the same color). This is computed analytically rather than through machine learning.
- **Bishop pair bonus**: Komodo's bishop pair evaluation was the most sophisticated of its era, distinguishing between "active" bishop pairs (attacking the opponent's position) and "passive" pairs (merely existing).
- **Initiative**: A dynamic bonus for the side with active threats, even when materially behind. Komodo would often sacrifice a pawn for the initiative and evaluate the resulting position as favorable—a very "human" assessment.

Komodo's evaluation was primarily hand-tuned with GM expertise, later augmented by automated tuning (Texel's method). This hybrid of human insight and statistical tuning produced an evaluation that felt more "natural" than the purely statistical evaluations of other engines.

=== Ethereal: Classical Eval Pushed to Its Limits

Ethereal, by Andrew Grant, is the engine that proved classical evaluation could still compete in the NNUE era. While most engines abandoned classical evaluation after Stockfish 12's NNUE success, Ethereal continued to refine its hand-crafted evaluation, reaching 3,400+ Elo on classical evaluation alone.

Ethereal's key innovations:

1. **ProbCut on Steroids**: Ethereal's ProbCut implementation is far more aggressive than Stockfish's, pruning up to 90% of moves at certain depths while maintaining near-perfect accuracy.

2. **Aggressive LMR**: Ethereal uses larger reduction factors than most engines (up to `depth/2 + 6` for late moves), justified by its excellent move ordering.

3. **Evaluation Precision**: Ethereal's evaluation terms are tuned with extreme precision, using billions of positions from self-play for automated tuning. Each term has been optimized to maximize correlation with game outcomes.

4. **The "Ethereal Style"**: Ethereal is known for aggressive, tactical play—it prefers complications to simplification, and its evaluation is calibrated to reflect practical winning chances rather than theoretical evaluations.

Andrew Grant has documented Ethereal's development extensively in his blog, providing a rare window into the decision-making process of a world-class engine developer. His key lesson: *don't overcomplicate*. Ethereal's evaluation has fewer terms than Stockfish's classical evaluation but each term is more precisely tuned and more carefully validated.

=== Berserk: The Newcomer That Broke Through

Berserk, by Jay Honnold, is a relative newcomer that rapidly ascended to the top tier. Berserk is an open-source engine built from scratch in C, notable for its clean, well-documented code and its rapid improvement rate.

Berserk's innovations:

1. **Pure C implementation**: Unlike most modern engines (which use C++ for templates and abstractions), Berserk uses plain C. This reduces compilation time, simplifies debugging, and forces a disciplined coding style. The code is considered one of the best-documented open-source engines.

2. **History Heuristic Aggressiveness**: Berserk maintains unusually large history tables (covering more contexts than Stockfish's history) and updates them more aggressively, achieving exceptional move ordering at the cost of occasional overfitting.

3. **Simple NNUE Integration**: Berserk adopted NNUE but kept the integration extremely simple—minimal changes to the search, minimal glue code. This proves that NNUE can be added to an engine without rewriting the architecture.

4. **Berserk's "Personality"**: The engine is known for speculative sacrifices and aggressive king attacks, a style that emerged from its tuning and history heuristic rather than explicit design.

The key lesson from Berserk: *simplicity and clarity enable rapid iteration*. Berserk reached 3,400 Elo in less than two years of development because the codebase was clean enough to experiment quickly.

=== Koivisto: The Pushing-the-Boundary Engine

Koivisto, by Finnish developers Kim Kåhre and Finn Eggers, is an open-source engine that has rapidly climbed the rankings through aggressive experimentation.

Koivisto's distinguishing features:

1. **Dense NNUE Architecture**: Koivisto has experimented with larger NNUE networks than Stockfish, using 1,024-neuron hidden layers (vs. Stockfish's 512), and has found that the larger networks provide enough additional accuracy to justify the computational cost on modern hardware.

2. **Novel Search Techniques**: Koivisto has experimented with "dynamic contempt" (adjusting the engine's draw-avoidance based on the opponent's strength), "multi-PV analysis in search" (maintaining multiple principal variations simultaneously), and "time management that adapts to position complexity" (spending more time in complex positions, less in forcing ones).

3. **Academic Rigor**: The Koivisto developers publish their findings in academic-style papers, providing statistical validation for each claimed improvement. This transparency has made Koivisto a valuable reference for the engine development community.

=== RubiChess: The Didactic Engine

RubiChess, by Andreas Matthies, combines competitive strength with exceptional educational value. The code is specifically designed to be readable and understandable.

RubiChess's contributions:

1. **Educational Code**: RubiChess's source code is heavily commented and organized for clarity. Functions are named descriptively, algorithms are explained in comments, and the architecture follows a textbook-like structure. For a developer learning chess engine programming, RubiChess is possibly the best reference.

2. **NNUE Without the Complexity**: RubiChess was one of the first engines outside Stockfish to adopt NNUE, and its implementation is deliberately simplified—fewer template specializations, less SIMD optimization, more straightforward data flow.

3. **Analysis Features**: RubiChess excels as an analysis tool, providing detailed position explanations, multiple PV lines, and annotated evaluations that help human players understand positions.

=== Igel: The Experimental Platform

Igel, by Volodymyr Shcherbyna, is explicitly designed as a testing ground for new ideas. It has implemented and evaluated dozens of techniques that other engines later adopted. Igel's willingness to try unconventional approaches makes it a valuable bellwether for the community.

=== Seer: The Data-Driven Engine

Seer, by Connor McMonigle, takes data-driven development to an extreme. Seer's evaluation is almost entirely learned from data—not just the NNUE weights, but the selection of evaluation features, the architecture of the network, and the training methodology itself are optimized through automated experimentation.

Seer's approach:

1. **Automated Feature Selection**: Rather than hand-designing the NNUE input features, Seer trained networks with various feature configurations and selected the best-performing automatically.

2. **Novel Training Targets**: Seer experiments with training against Stockfish evaluations, LC0 evaluations, game outcomes, and combinations thereof—using the target that maximizes playing strength in validation.

3. **Small-Net Specialization**: Seer focuses on making small networks very strong, enabling CPU play at high NPS with reasonable accuracy.

=== Viridithas: The Bitboard Purist

Viridithas, by Cosmo Zhang, is a Rust engine that has achieved competitive strength while maintaining a strict commitment to bitboard purity. Every evaluation term is computed using bitboard operations—no piece lists, no incremental updates, just bitboards.

Viridithas proves that:
1. Rust is viable for world-class chess engines (matching C/C++ for performance).
2. Pure bitboard evaluation can reach 3,000+ Elo.
3. Elegant code and competitive strength are not mutually exclusive.

=== What Makes an Engine Unique: A Taxonomy

Reflecting on these engines, we can categorize engines by their primary distinguishing characteristics:

```text
Dimension               Spectrum
───────────────────────  ──────────────────────────────────
Evaluation Source       Hand-crafted ←→ Statistical ←→ Learned (NNUE/NN)
Search Paradigm         Alpha-Beta ←→ MCTS ←→ Hybrid
Code Philosophy         Optimized ←→ Readable ←→ Experimental
Development Style       Incremental (SF) ←→ Aggressive (Berserk) ←→ Academic (Koivisto)
Hardware Target         CPU-optimized ←→ GPU-accelerated ←→ Portable
Evaluation Richness     Sparse terms ←→ Dense terms ←→ Neural
Openness               Open source ←→ Closed source ←→ Open source + community
```

No engine is "best" on all dimensions. Stockfish optimizes for raw strength; RubiChess optimizes for readability; Igel optimizes for experimentation. The choice of what to optimize is as important as how well you optimize.

=== Lessons for Engine Developers

1. **You don't need to be Stockfish**. Most engines will never match Stockfish's strength, and that's fine. An engine that is 90% as strong but 10x more readable, or that explores novel techniques, or that serves as an analysis tool, is valuable in its own right.

2. **Specialization wins**. Komodo's hybrid MCTS, Ethereal's aggressive LMR, Seer's data-driven approach—each engine found a niche and optimized it. Trying to be "Stockfish but slightly different" is a losing strategy.

3. **The community matters**. Berserk and Koivisto rose rapidly because they engaged with the chess programming community, shared their code, and benefited from collective knowledge. Open source isn't just about licensing—it's about participating in a community of practice.

4. **Clean code enables fast iteration**. The engines that improve fastest are those with the cleanest codebases. Every hour spent debugging a messy architecture is an hour not spent improving the engine.

5. **Document your journey**. Andrew Grant's blog, the Koivisto papers, the RubiChess code comments—these are gifts to the community. Your engine's development story is valuable even if your engine never reaches #1.
