== Leela Chess Zero: The Neural Network Revolution

Leela Chess Zero (LC0) represents a fundamentally different approach to chess engine design. While Stockfish and its ilk follow the "search + hand-crafted (or NNUE) evaluation" paradigm descended from Shannon's 1950 paper, LC0 is a direct descendant of DeepMind's AlphaZero—a system that learned chess from scratch through self-play, using a Monte Carlo Tree Search (MCTS) guided by a deep convolutional neural network. This chapter examines LC0's architecture, training methodology, unique playing style, and the lessons its approach offers.

=== The AlphaZero Influence

In December 2017, DeepMind published a bombshell paper: "Mastering Chess and Shogi by Self-Play with a General Reinforcement Learning Algorithm." Their system, AlphaZero, achieved superhuman performance in chess after just 4 hours of self-play training—starting from *tabula rasa*, knowing only the rules of the game.

The AlphaZero architecture was revolutionary:

1. **Neural Network (dual-head)**: A deep convolutional neural network with a shared "body" (ResNet-based) and two "heads":
   - *Policy head*: A probability distribution over legal moves (which moves to consider).
   - *Value head*: A scalar evaluation of the position (how good it is).

2. **Monte Carlo Tree Search (MCTS)**: Instead of the alpha-beta minimax tree used by every chess engine since the 1960s, AlphaZero used MCTS—a probabilistic, best-first search that selectively explores promising lines.

3. **Self-Play training**: The network improved by playing against itself, generating training data, and then learning from that data. No human chess knowledge, no opening books, no endgame tablebases—just the rules and self-play.

AlphaZero proved two things: (1) neural networks could master chess without any human knowledge, and (2) MCTS could compete with alpha-beta search at the highest level. The open-source community immediately set out to replicate AlphaZero—resulting in Leela Chess Zero.

=== LC0 Architecture

LC0 is an open-source reimplementation of AlphaZero's ideas, with several practical improvements developed over years of experimentation.

==== The Neural Network

The LC0 network is a deep convolutional neural network with residual connections (ResNet):

```text
Input: 112-channel binary feature plane (8×8 grid)
  │   Channels encode:
  │   - Piece positions (6 piece types × 2 colors = 12 planes)
  │   - Piece positions for previous 7 half-moves (84 planes for history)
  │   - Side to move, castling rights, en passant, rule50 (16 metadata planes)
  │
  ├── Convolutional Block (112 → 256 channels, 3×3 kernel, ReLU)
  ├── Residual Tower (N blocks, each: Conv → BatchNorm → ReLU → Conv → BatchNorm → Add)
  │     "Bottleneck" variant: 256 → 64 → 256 channels (3×3, 1×1, 3×3)
  │     N = 10 (T40), 15 (T60), 20 (T78), 32 (BT3), 40+ (larger nets)
  │
  ├── Policy Head
  │     Conv 256→80, 1×1 kernel
  │     FC 5120→1858 (all possible moves from all squares)
  │     Softmax → probability distribution over legal moves
  │
  └── Value Head
        Conv 256→32, 1×1 kernel
        FC 2048→128, ReLU
        FC 128→1, Tanh → scalar in [-1, +1] (WDL expected outcome)
```

The input representation is purely spatial: the board is an 8×8 grid, and each "channel" is a binary plane indicating some fact about the board. This is the computer vision approach: treat the chessboard as an image and let the network learn spatial patterns.

The policy head output is 1,858 values: for every square, there is a probability for moving in each of 73 possible directions/distances (56 queen moves + 8 knight moves + 3 pawn moves + 3 underpromotions + 3 promotions). The softmax over *legal* moves produces a probability distribution.

The value head output is a scalar from -1 (certain loss for the side to move) to +1 (certain win), representing the expected game outcome (WDL).

==== Network Sizes and Their Evolution

LC0 networks are identified by their "T" generation and the number of residual blocks:

```text
Network   Blocks   Parameters   Training Data     Approx. Elo
────────  ──────   ──────────   ──────────────    ───────────
T40        10       ~4 million   ~100M positions     ~2800
T60        15       ~7 million   ~200M positions     ~3100
T78        20      ~12 million   ~500M positions     ~3400
BT2        20      ~12 million   T78 + targeted       ~3450
BT3        32      ~20 million   BT2 + more data      ~3500
BT4        32      ~20 million   improved training    ~3550
Lc0 0.30   40+     ~30 million+  billions of pos.     ~3600+
```

The "T" networks were trained by the community (distributed computing, much like Fishtest for Stockfish). "BT" (Big Transformer) and later networks have been trained with more computational resources, larger architectures, and improved training methodologies.

Crucially, network size directly impacts playing strength—AND search speed. A larger network evaluates positions more accurately but processes fewer positions per second. The optimal trade-off is a function of the hardware:

- **GPU users** (RTX 3080, 4090): Run larger networks (BT3/BT4) at 10,000-50,000 NPS. The GPU's massive parallelism makes inference fast even for large networks.
- **CPU users**: Run smaller networks (T40/T60) at 1,000-5,000 NPS. CPU inference is dramatically slower for convolutional networks (vs. NNUE, which is optimized for CPU).

This hardware-dependence means LC0's playing style varies with the user's GPU. A powerful GPU enables a "deep thinking" style (few nodes evaluated, but each evaluation is highly accurate), while a CPU forces a "fast and shallow" style (many nodes evaluated with a weaker network, approximating the traditional engine approach).

==== MCTS Search

LC0's search is fundamentally different from alpha-beta. The Monte Carlo Tree Search algorithm:

```text
function MCTS(root_position):
    root_node = create_node(root_position)
    for i in 1..max_nodes:
        node = root_node
        path = []
        
        // 1. SELECT: Descend tree using PUCT formula
        while node is fully expanded and not terminal:
            node = select_child(node)  // using PUCT
            path.append(node)
        
        // 2. EXPAND: Create one new child node
        if not terminal:
            evaluate_position_with_network(node.position)
            // → policy (move probabilities) and value (position score)
            expand_node(node, policy)
        
        // 3. BACKUP: Propagate value up the tree
        for node in reverse(path):
            node.visit_count += 1
            node.total_value += value  // from perspective of node's player
            node.mean_value = total_value / visit_count
    
    // Return best move (highest visit count, or best Q-value)
    return root_node.most_visited_child()
```

The key differences from alpha-beta:

1. **Best-first, not depth-first**: MCTS explores the most promising lines first, regardless of depth. It can search a line 30 plies deep while leaving other lines at 2 plies. This is ideal for positions with a few critical variations.

2. **No alpha-beta bounds**: MCTS does not use alpha-beta pruning. Instead, it balances exploration and exploitation using the PUCT (Predictor + Upper Confidence Bounds for Trees) formula.

3. **Probabilistic over deterministic**: MCTS doesn't guarantee finding the minimax value. Instead, it converges probabilistically to the best move as the number of simulations increases. In practice, with thousands of simulations, it is extremely reliable.

==== PUCT: The Selection Formula

At each step, MCTS selects the child that maximizes:

```
PUCT(s, a) = Q(s, a) + cpuct * P(s, a) * sqrt(visit_count(parent)) / (1 + visit_count(s, a))
```

Where:
- `Q(s, a)` is the mean value from all visits to this child (exploitation).
- `P(s, a)` is the policy network's prior probability for this move (exploration guidance).
- `cpuct` is the exploration constant (typically 2.5-3.0). Higher values increase exploration.
- The denominator `(1 + visit_count)` biases toward less-visited nodes early on.

The `P(s, a)` term is critical: it's the neural network's opinion about which moves are worth considering. This "prior knowledge" dramatically improves MCTS efficiency compared to naive random rollouts. Without the policy prior, MCTS would waste time exploring terrible moves. With it, MCTS focuses almost exclusively on plausible moves.

==== Virtual Loss

To parallelize MCTS, LC0 uses *virtual loss*: when a thread begins exploring a node, it temporarily subtracts a "virtual loss" from the node's value. This discourages other threads from exploring the same path, spreading the parallelism across the tree. When the thread finishes and backs up the true value, the virtual loss is removed.

```cpp
// Virtual loss in parallel MCTS
void select_path(Node *node, float virtual_loss) {
    node->virtual_loss_count++;  // discourage other threads
    if (node->is_expanded) {
        Node *child = select_best_child(node);
        select_path(child, virtual_loss);
    }
}

void backup_value(Node *node, float value) {
    node->virtual_loss_count--;
    node->visit_count++;
    node->total_value += value;
    value = -value;  // flip perspective
    if (node->parent) backup_value(node->parent, value);
}

// Actual Q-value: (total_value - virtual_loss * 2) / (visit_count + virtual_loss_count)
float effective_q(Node *node) {
    return (node->total_value - 2.0 * node->virtual_loss_count) /
           (node->visit_count + node->virtual_loss_count);
}
```

==== GPU vs. CPU Inference

LC0's Achilles heel is inference speed on CPU. A typical convolutional network inference (BT3, 20 blocks, 256 channels) requires:

- ~10 million multiply-accumulate operations per position.
- On GPU (RTX 4090): ~0.5 milliseconds (20,000 NPS).
- On CPU (16 cores, modern x86): ~5-10 milliseconds (100-200 NPS).

This 100x difference means that GPU is effectively mandatory for strong LC0 play. CPU LC0 can barely reach 2,500 Elo, while GPU LC0 with a strong network reaches 3,500+ Elo.

NNUE (Chapter 13) was specifically designed to address this: by using a sparse, efficiently-updatable architecture, NNUE achieves GPU-like evaluation quality on CPU. The irony: NNUE's success grew out of the Shogi community's response to the same GPU dependency problem.

=== The Training Pipeline

LC0's training is a continuous, distributed process:

```text
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Self-Play    │────▶│ Training     │────▶│ Validation   │
│ (Volunteers) │     │ (Server)     │     │              │
└──────────────┘     └──────────────┘     └──────────────┘
        │                    │                    │
        │  Games (.gz)       │  Weights (.pb)      │  Elo check
        ▼                    ▼                    ▼
   Positions + WDL      Updated Network       New Network
   + Policy Targets     (TensorFlow/PyTorch)  (if stronger)
```

1. **Self-play**: Volunteers run LC0 clients that play games against the current best network. Each game generates training data: for each position, the search's final move probabilities (policy target) and the game outcome (value target, as -1/0/+1 for loss/draw/win).

2. **Training**: The server collects self-play games, samples mini-batches, and trains the neural network to predict both the policy and the value. The loss function is:

```
Loss = Policy_Loss + lambda * Value_Loss
     = -sum(p_target * log(p_predicted)) + lambda * (v_target - v_predicted)^2
```

Where `lambda` balances the two objectives (typically 0.01-0.1, emphasizing policy accuracy over value accuracy).

3. **Validation**: The new network plays a match against the current best network. If it wins (SPRT or fixed-game test), it becomes the new "best" network. This is an evolutionary process: networks that win more often survive.

4. **Client-Server Protocol**: LC0 uses a lightweight binary protocol for self-play work units. A client requests work, plays games (using the current network for MCTS), and uploads the results. This is conceptually identical to Fishtest's distributed testing model, but for training data generation rather than testing.

==== Training Data Volume

The scale of LC0's training is staggering:

```text
Training Run    Self-Play Games   Positions     Training Time
──────────────  ────────────────   ───────────   ──────────────
T40 (initial)    ~10 million       ~500 million   ~3 months
T60             ~30 million       ~1.5 billion   ~6 months  
T78             ~80 million       ~4 billion     ~12 months
BT3             ~200 million      ~10 billion    ~18 months
Current         Billions+         Tens of bil.   Continuous
```

Each self-play game generates ~50-100 positions (one per move), and each position has two training targets (policy and value). The total training data for a modern LC0 network exceeds 10 billion training examples—a scale that would be impossible without distributed computing.

=== LC0's Unique Playing Style

LC0 plays chess that is recognizably different from traditional engines. Its style has been described as "alien," "intuitive," "positional," and "human-like"—though each of these descriptors captures only part of the truth.

==== Characteristics of LC0's Play

1. **Long-term positional understanding**: LC0 will sacrifice material for positional compensation in ways that Stockfish occasionally misses. The neural network has learned that certain pawn structures, piece configurations, and king positions yield practical winning chances even when materially down. This is the classic "AlphaZero style" that so impressed the chess world in 2017.

2. **Active piece play**: LC0 strongly prefers active piece placement over passive defense. It will often give up a pawn for bishop mobility or a rook lift to an active square.

3. **Different move preferences**: For many standard positions, LC0 prefers different opening moves and middlegame plans than traditional engines. Its evaluations align more closely with human grandmaster assessments than with traditional computer evaluations.

4. **Endgame weaknesses**: Historically, LC0 has struggled with certain endgames, particularly those requiring deep tactical calculation rather than positional understanding. The neural network's spatial reasoning is strong in middlegames but sometimes mis-evaluates simplified endgame positions. (This gap has narrowed significantly with larger networks and better training.)

5. **Search efficiency**: LC0 evaluates far fewer positions than Stockfish (1,000-50,000 NPS vs. 1-5 million NPS), but each evaluation is dramatically more accurate. This "quality over quantity" approach is the essence of neural-network-driven search.

==== The WDL Scoring System

LC0's value head doesn't output a centipawn score. It outputs a WDL (Win-Draw-Loss) probability vector: `(p_win, p_draw, p_loss)`. The expected score is:

```
expected_score = p_win + 0.5 * p_draw
```

This WDL representation has important implications:

1. It explicitly models draw probability—a critical quantity in chess that centipawn-based evaluations can only approximate.
2. It provides a natural contempt mechanism: by weighting win more heavily than losses, the engine can avoid draws against weaker opponents.
3. It enables principled "resignation" decisions: if `p_loss > 0.999` and no reasonable move changes that, the engine can resign.

The conversion between WDL and centipawns is non-trivial and depends on the position. A crude approximation:

```
cp_advantage ≈ 400 * log10(((p_win + 0.5 * p_draw)) / (p_loss + 0.5 * p_draw))
```

But this is unreliable for extreme values (near-certain wins or losses), which is why LC0 retains WDL internally.

=== Hybrid Approaches

LC0's strengths (positional understanding) and Stockfish's strengths (tactical precision in endgames) are complementary. This has led to several hybrid approaches:

1. **LC0 + Stockfish Ensemble**: Run both engines and combine their evaluations. The simplest approach: vote on the best move (both engines analyze, pick the move with the highest combined score). More sophisticated: a linear combination of the evaluation scores.

2. **Stockfish with LC0's Opening Book**: Use LC0 at ultra-fast time control to generate a deep opening book, then let Stockfish play the middlegame and endgame. This captures LC0's superior opening understanding while retaining Stockfish's middlegame tactics and endgame precision.

3. **NNUE (the ultimate hybrid)**: Stockfish's NNUE evaluation can be seen as a hybrid between classical search and neural evaluation—inspired by the same principles as LC0 but optimized for CPU and alpha-beta search.

=== Training Your Own Chess Network

For developers inspired by LC0 but working at a smaller scale, the open-source tools are available:

```python
# Train a small chess network with PyTorch
import torch
import torch.nn as nn

class ChessNet(nn.Module):
    def __init__(self, num_blocks=5, channels=128):
        super().__init__()
        self.conv_in = nn.Conv2d(112, channels, 3, padding=1)
        
        # Residual blocks
        self.res_blocks = nn.ModuleList([
            ResidualBlock(channels) for _ in range(num_blocks)
        ])
        
        # Policy head (73 possible moves per square)
        self.policy_conv = nn.Conv2d(channels, 80, 1)
        self.policy_fc = nn.Linear(80 * 64, 1858)
        
        # Value head
        self.value_conv = nn.Conv2d(channels, 32, 1)
        self.value_fc1 = nn.Linear(32 * 64, 128)
        self.value_fc2 = nn.Linear(128, 1)
    
    def forward(self, x):
        x = torch.relu(self.conv_in(x))
        for block in self.res_blocks:
            x = block(x)
        
        # Policy
        p = torch.relu(self.policy_conv(x))
        p = self.policy_fc(p.view(p.size(0), -1))
        
        # Value
        v = torch.relu(self.value_conv(x))
        v = v.view(v.size(0), -1)
        v = torch.relu(self.value_fc1(v))
        v = torch.tanh(self.value_fc2(v))
        
        return p, v

# Training loop
model = ChessNet(num_blocks=5)
optimizer = torch.optim.Adam(model.parameters(), lr=0.001)

for positions, policy_targets, value_targets in dataloader:
    policy_pred, value_pred = model(positions)
    policy_loss = -(policy_targets * torch.log_softmax(policy_pred, dim=1)).sum(dim=1).mean()
    value_loss = ((value_targets - value_pred.squeeze()) ** 2).mean()
    loss = policy_loss + 0.01 * value_loss
    loss.backward()
    optimizer.step()
```

This can be trained on data from existing engines (use Stockfish evaluations as targets) or through self-play (like LC0). Even a 5-block network with 128 channels (~500K parameters) can reach ~2,000 Elo—stronger than most amateur engines, despite being tiny.

=== Lessons from LC0

1. **Search and evaluation are complementary, not orthogonal**. LC0 proves that MCTS + neural evaluation can match alpha-beta + neural evaluation. The "right" search algorithm depends on the evaluation function's characteristics (neural networks favor best-first search; hand-crafted evaluations favor depth-first search).

2. **Hardware matters for architecture**. LC0's convolutional network is ideal for GPU inference; NNUE is ideal for CPU inference. An engine's architecture should be designed for its target hardware.

3. **Self-play learning works, at massive scale**. LC0's training pipeline demonstrates that reinforcement learning can produce superhuman chess play—but the scale required (billions of positions) is beyond individual developers. Distributed computing is a practical necessity.

4. **Different is not worse**. LC0's playing style—so different from traditional engines—is a feature, not a bug. The chess world is richer for having engines that play differently, and the combination of multiple engine perspectives can overcome the blind spots of any single approach.

5. **The gap is narrowing**. While LC0 was revolutionary in 2018, NNUE has brought neural evaluation to the alpha-beta paradigm, significantly narrowing LC0's advantage. The future of chess engines may be a synthesis of both approaches.
