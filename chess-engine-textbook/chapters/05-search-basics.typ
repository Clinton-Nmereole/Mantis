== Search Algorithms: The Core of Chess Intelligence

=== Why Search? Understanding the Chess Problem

Chess is fundamentally a game of perfect information. Both players can see the entire board at all times—there are no hidden cards, no dice rolls, no random elements. Every piece is visible. Every legal move is known. In principle, one could compute the optimal move from any position by analyzing every possible continuation. The problem is one of scale.

A typical chess position offers approximately 35 legal moves. This number, known as the _branching factor_ $b$, varies with the phase of the game: it can be as low as 15-20 in quiet endgame positions, and as high as 50-60 in sharp middlegame positions with many pieces and open lines. But 35 is a reasonable average across all phases of play.

After White's first move, there are roughly 35 positions. After Black responds, we have approximately $35 times 35 = 1,225$ positions at depth 2. After White's second move, approximately $35^3 approx 42,875$ positions at depth 3. This exponential growth is explosive. The game tree complexity—the total number of positions reachable over an entire game—has been estimated at approximately $10^(120)$, a number so vast that it exceeds the estimated number of atoms in the observable universe by a factor of roughly $10^(40)$.

This is the fundamental challenge: chess is too large to solve by brute force.

==== The Game Tree as an Abstraction

A _game tree_ is a directed graph where:

- _Nodes_ represent positions (states of the chess board)
- _Edges_ represent legal moves leading from one position to another
- The _root node_ is the current position we must make a move from
- _Leaf nodes_ (or _terminal nodes_) are positions at the maximum depth of our search, or positions where the game has ended (checkmate, stalemate)
- _Interior nodes_ are positions where the search has not yet reached maximum depth

The tree alternates between "our turn" (White from White's perspective, or the side to move) and "their turn" (the opponent). At each node where it is our turn, we want to select the move that leads to the best possible outcome, _assuming the opponent plays optimally against us_.

This is a _minimax_ problem: we maximize our score, while the opponent minimizes our score (equivalently, maximizes their own).

#figure(
  table(
    columns: (auto, auto, auto),
    table.header([*Depth*], [*Nodes at depth $d$*], [*Total nodes to depth $d$*]),
    [1], [$35$], [$35$],
    [2], [$1,225$], [$1,260$],
    [3], [$42,875$], [$44,135$],
    [4], [$1,500,625$], [$1,544,760$],
    [5], [$52,521,875$], [$54,066,635$],
    [6], [$1,838,265,625$], [$1,892,332,260$],
    [8], [$2.25 times 10^12$], [$2.32 times 10^12$],
    [10], [$2.76 times 10^15$], [$2.84 times 10^15$],
    [20], [$7.61 times 10^30$], [$7.83 times 10^30$],
  ),
  caption: [Growth of the chess game tree with branching factor $b = 35$],
)

The table above illustrates the explosive growth of the game tree. Even at a modest depth of 10 half-moves (plies), we would need to evaluate nearly $3 times 10^15$ positions. At one billion positions per second, this would take approximately 33 days to compute. At depth 20, the time required exceeds the age of the universe.

Clearly, we cannot visit every node. The entire field of chess engine search is about intelligently focusing computational effort on the most promising branches while safely discarding the rest. Every technique we will study—alpha-beta pruning, null-move pruning, late move reductions, futility pruning—is a strategy for _not_ searching nodes we can prove are irrelevant.

==== Ply, Depth, and Selective Depth

Before proceeding, we must define precise terminology:

- A _ply_ is one half-move. Depth 1 means searching our move only. Depth 2 means searching our move plus the opponent's response. Depth $d$ means searching $d$ consecutive half-moves.
- _Selective depth_ (or _seldepth_) is the deepest ply actually reached by the search, which may be greater than the nominal search depth due to extensions (which search deeper on forcing lines such as checks and captures).
- _Full-width search_ visits all legal moves at each interior node (subject to pruning rules). When engine authors say "depth 20," they typically mean a 20-ply full-width search with extensions pushing selective depth higher.

We will use conventional chess engine terminology throughout. The side to move at the root is called the _maximizing_ player, and the opponent is the _minimizing_ player.

=== Minimax: The Foundational Algorithm

==== The Minimax Principle

The minimax algorithm is the simplest correct algorithm for two-player zero-sum games with perfect information. "Zero-sum" means one player's gain is exactly the other's loss. In chess terms: if we are up a pawn (+1.0), the opponent is down a pawn (-1.0). The sum of both sides' evaluations is constant (typically zero, relative to a balanced starting position).

The minimax principle states:

- At our turn (max nodes), choose the move with the maximum evaluation.
- At the opponent's turn (min nodes), the opponent will choose the move that minimizes our evaluation (which maximizes theirs).

More precisely, let `f(p)` be the evaluation of position `p` from our perspective. Then for a max node:

`f(p) = max_{m in legal_moves(p)} f(make_move(p, m))`

And for a min node:

`f(p) = min_{m in legal_moves(p)} f(make_move(p, m))`

The base case occurs when we reach a leaf node (maximum search depth reached or game ended). At a leaf, we call the _static evaluation function_—a heuristic that estimates the position's value without further search.

==== Pseudocode for Minimax

```text
function minimax(position, depth, maximizingPlayer):
    if depth == 0 or game_over(position):
        return evaluate(position)

    if maximizingPlayer:
        maxEval = -INFINITY
        for each move in legal_moves(position):
            make_move(position, move)
            eval = minimax(position, depth - 1, false)
            unmake_move(position, move)
            maxEval = max(maxEval, eval)
        return maxEval
    else:
        minEval = +INFINITY
        for each move in legal_moves(position):
            make_move(position, move)
            eval = minimax(position, depth - 1, true)
            unmake_move(position, move)
            minEval = min(minEval, eval)
        return minEval
```

The root caller uses:

```text
bestMove = null
bestScore = -INFINITY
for each move in legal_moves(position):
    make_move(position, move)
    score = minimax(position, depth - 1, false)
    unmake_move(position, move)
    if score > bestScore:
        bestScore = score
        bestMove = move
return bestMove
```

This is conceptually clean but computationally expensive. For a branching factor $b$ and depth $d$, minimax visits exactly $b^d$ leaf nodes. As we saw in the table above, this becomes impractical very quickly.

==== A Concrete Walkthrough

Consider a tiny game tree with branching factor 2 and depth 2:

#figure(
  table(
    columns: (1fr, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr),
    [],[],[],
    table.hline(),
    [],[],[],[],[],[],[],
  ),
  caption: [Placeholder for minimax tree diagram],
)

Let the leaf evaluations (from our perspective) be +3, +5, +2, +9 from left to right. At depth 1 it is the opponent's turn (min nodes). The opponent will choose:
- In the left subtree: min(+3, +5) = +3
- In the right subtree: min(+2, +9) = +2

At depth 0 (the root, our turn): max(+3, +2) = +3. We choose the move leading to the position where the opponent's best response leaves us at +3.

==== Why Minimax Is Insufficient

While minimax is correct, it is far too slow for practical chess. At depth 10 with branching factor 35, it visits $35^10 approx 2.76 times 10^15$ leaf nodes. Even at one trillion (10^12) nodes per second, this would take over 45 minutes for a single 10-ply search—and modern engines routinely search to depth 30 and beyond.

The key insight that makes chess engines practical is that _most of the game tree does not need to be searched_. If we can prove, without visiting a subtree, that it cannot affect the final decision, we can prune it safely. This is the core idea behind alpha-beta pruning, which we will explore shortly.

=== Negamax: Unifying Max and Min

==== The Mathematical Simplification

Minimax uses separate cases for maximizing and minimizing players. This leads to code duplication and complexity. The negamax algorithm eliminates the distinction by exploiting a simple mathematical identity:

`max(a, b, c, ...) = -min(-a, -b, -c, ...)`

In words: the maximum of a set of numbers is the negative of the minimum of their negatives. This identity holds for any set of real numbers.

Applied to chess: instead of having the opponent _minimize_ our evaluation, we have the opponent _maximize_ their own evaluation, and then we negate it from our perspective. Since chess is a zero-sum game with symmetric evaluation (from the perspective of the side to move), we can always express the score relative to the player whose turn it is.

The negamax recurrence:

```text
f(p, d) = {
    evaluate(p)                  if d = 0 or game over
    max_{m in legal_moves(p)} ( -f(make_move(p, m), d-1) )   otherwise
}
```

Here, $f(p, d)$ returns the evaluation of position $p$ at depth $d$ from the perspective of the player whose turn it is at $p$. The critical step is the negation: we recursively call $f$ on the child position (where it is the opponent's turn), and then negate the result to flip the perspective back to the current player.

==== Negamax Pseudocode

```text
function negamax(position, depth):
    if depth == 0 or game_over(position):
        return evaluate(position)

    maxScore = -INFINITY
    for each move in legal_moves(position):
        make_move(position, move)
        score = -negamax(position, depth - 1)
        unmake_move(position, move)
        if score > maxScore:
            maxScore = score
    return maxScore
```

The root call becomes:

```text
bestMove = null
bestScore = -INFINITY
for each move in legal_moves(position):
    make_move(position, move)
    score = -negamax(position, depth - 1)
    unmake_move(position, move)
    if score > bestScore:
        bestScore = score
        bestMove = move
return bestMove
```

This is cleaner than minimax: a single recursive function handles both maximizing and minimizing nodes through the negation trick.

==== Derivation from Minimax

To see the equivalence, consider a max node in minimax:

`f_max(p, d) = max_m f_min(child, d-1)`

In negamax, we define a single evaluation function evaluated from the perspective of the side to move. The minimizer's evaluation of position `p` from our perspective is the negative of the maximizer's evaluation from their perspective:

`f_min(p) = -f_negamax(p)`

Substituting:

`f_negamax(p, d) = max_m ( -f_negamax(child, d-1) )`

Which is exactly the negamax recurrence. The key insight is that chess evaluation must be symmetric: if a position is worth +100 centipawns for White, it is worth -100 centipawns for Black. The negamax formulation relies on this property, which is trivially satisfied by any evaluation function that always returns its result from the perspective of the side whose turn it is.

==== Code Examples: Negamax in Five Languages

Here is a complete negamax implementation in each of our five target languages, using a consistent simplified API for board operations.

**C Implementation:**

```c
#include <limits.h>

#define INF 1000000
#define MATE 100000

// Board representation (simplified)
typedef struct {
    uint64_t pieces[2][6];  // color, piece_type bitboards
    uint64_t occupied[2];   // white, black occupancy
    int side_to_move;       // 0 = white, 1 = black
    // ... additional state
} Board;

int evaluate(Board *board);
void make_move(Board *board, int move);
void unmake_move(Board *board);
int generate_moves(Board *board, int *moves);

int negamax(Board *board, int depth) {
    if (depth == 0) {
        return evaluate(board);
    }

    int moves[256];
    int num_moves = generate_moves(board, moves);

    if (num_moves == 0) {
        // No legal moves: checkmate or stalemate
        if (is_in_check(board)) {
            return -MATE;  // Checkmated
        }
        return 0;  // Stalemate
    }

    int max_score = -INF;

    for (int i = 0; i < num_moves; i++) {
        make_move(board, moves[i]);
        int score = -negamax(board, depth - 1);
        unmake_move(board);

        if (score > max_score) {
            max_score = score;
        }
    }

    return max_score;
}

int search_root(Board *board, int depth, int *best_move) {
    int best_score = -INF;
    int moves[256];
    int num_moves = generate_moves(board, moves);

    for (int i = 0; i < num_moves; i++) {
        make_move(board, moves[i]);
        int score = -negamax(board, depth - 1);
        unmake_move(board);

        if (score > best_score) {
            best_score = score;
            *best_move = moves[i];
        }
    }

    return best_score;
}
```

**C++ Implementation:**

```cpp
#include <vector>
#include <algorithm>
#include <limits>

constexpr int INF = 1'000'000;
constexpr int MATE = 100'000;

class Board {
public:
    // ... board representation
    int evaluate() const;
    void makeMove(int move);
    void unmakeMove();
    std::vector<int> generateMoves() const;
    bool isInCheck() const;
};

int negamax(Board &board, int depth) {
    if (depth == 0) {
        return board.evaluate();
    }

    auto moves = board.generateMoves();

    if (moves.empty()) {
        return board.isInCheck() ? -MATE : 0;
    }

    int maxScore = -INF;

    for (int move : moves) {
        board.makeMove(move);
        int score = -negamax(board, depth - 1);
        board.unmakeMove();

        if (score > maxScore) {
            maxScore = score;
        }
    }

    return maxScore;
}

std::pair<int, int> searchRoot(Board &board, int depth) {
    int bestScore = -INF;
    int bestMove = 0;

    for (int move : board.generateMoves()) {
        board.makeMove(move);
        int score = -negamax(board, depth - 1);
        board.unmakeMove();

        if (score > bestScore) {
            bestScore = score;
            bestMove = move;
        }
    }

    return {bestScore, bestMove};
}
```

**Rust Implementation:**

```rust
const INF: i32 = 1_000_000;
const MATE: i32 = 100_000;

struct Board {
    // ... board representation
}

impl Board {
    fn evaluate(&self) -> i32 { /* ... */ 0 }
    fn make_move(&mut self, mv: u32) { /* ... */ }
    fn unmake_move(&mut self) { /* ... */ }
    fn generate_moves(&self) -> Vec<u32> { /* ... */ vec![] }
    fn is_in_check(&self) -> bool { /* ... */ false }
}

fn negamax(board: &mut Board, depth: i32) -> i32 {
    if depth == 0 {
        return board.evaluate();
    }

    let moves = board.generate_moves();

    if moves.is_empty() {
        return if board.is_in_check() { -MATE } else { 0 };
    }

    let mut max_score = -INF;

    for &mv in &moves {
        board.make_move(mv);
        let score = -negamax(board, depth - 1);
        board.unmake_move();

        if score > max_score {
            max_score = score;
        }
    }

    max_score
}

fn search_root(board: &mut Board, depth: i32) -> (i32, u32) {
    let mut best_score = -INF;
    let mut best_move = 0;

    for &mv in board.generate_moves().iter() {
        board.make_move(mv);
        let score = -negamax(board, depth - 1);
        board.unmake_move();

        if score > best_score {
            best_score = score;
            best_move = mv;
        }
    }

    (best_score, best_move)
}
```

**Zig Implementation:**

```zig
const INF: i32 = 1_000_000;
const MATE: i32 = 100_000;

const Board = struct {
    // ... board representation

    fn evaluate(self: *const Board) i32 {
        // ...
    }

    fn makeMove(self: *Board, move: u32) void {
        // ...
    }

    fn unmakeMove(self: *Board) void {
        // ...
    }

    fn generateMoves(self: *const Board, moves: *[256]u32) usize {
        // ...
    }

    fn isInCheck(self: *const Board) bool {
        // ...
    }
};

fn negamax(board: *Board, depth: i32) i32 {
    if (depth == 0) {
        return board.evaluate();
    }

    var moves: [256]u32 = undefined;
    const num_moves = board.generateMoves(&moves);

    if (num_moves == 0) {
        return if (board.isInCheck()) -MATE else 0;
    }

    var max_score: i32 = -INF;

    for (moves[0..num_moves]) |move| {
        board.makeMove(move);
        const score = -negamax(board, depth - 1);
        board.unmakeMove();

        if (score > max_score) {
            max_score = score;
        }
    }

    return max_score;
}

fn searchRoot(board: *Board, depth: i32) struct { score: i32, best_move: u32 } {
    var best_score: i32 = -INF;
    var best_move: u32 = 0;

    var moves: [256]u32 = undefined;
    const num_moves = board.generateMoves(&moves);

    for (moves[0..num_moves]) |move| {
        board.makeMove(move);
        const score = -negamax(board, depth - 1);
        board.unmakeMove();

        if (score > best_score) {
            best_score = score;
            best_move = move;
        }
    }

    return .{ .score = best_score, .best_move = best_move };
}
```

**Odin Implementation:**

```odin
package engine

INF :: 1_000_000
MATE :: 100_000

Board :: struct {
    // ... board representation
}

evaluate :: proc(board: ^Board) -> i32 {
    // ...
}

make_move :: proc(board: ^Board, move: u32) {
    // ...
}

unmake_move :: proc(board: ^Board) {
    // ...
}

generate_moves :: proc(board: ^Board) -> [dynamic]u32 {
    // ...
}

is_in_check :: proc(board: ^Board) -> bool {
    // ...
}

negamax :: proc(board: ^Board, depth: i32) -> i32 {
    if depth == 0 {
        return evaluate(board)
    }

    moves := generate_moves(board)
    defer delete(moves)

    if len(moves) == 0 {
        if is_in_check(board) {
            return -MATE
        }
        return 0
    }

    max_score := -INF

    for mv in moves {
        make_move(board, mv)
        score := -negamax(board, depth - 1)
        unmake_move(board)

        if score > max_score {
            max_score = score
        }
    }

    return max_score
}

search_root :: proc(board: ^Board, depth: i32) -> (i32, u32) {
    best_score := -INF
    best_move: u32 = 0

    moves := generate_moves(board)
    defer delete(moves)

    for mv in moves {
        make_move(board, mv)
        score := -negamax(board, depth - 1)
        unmake_move(board)

        if score > best_score {
            best_score = score
            best_move = mv
        }
    }

    return best_score, best_move
}
```

==== Performance of Negamax

Negamax visits exactly the same nodes as minimax—the transformation is purely algebraic, not algorithmic. The advantage is implementation simplicity: one function instead of two, and the negation trick means we always maximize. The complexity remains $O(b^d)$ with branching factor $b$ and depth $d$.

=== Alpha-Beta Pruning: The Fundamental Optimization

==== The Key Insight

Consider the minimax tree walkthrough from earlier. While evaluating the left subtree, we found that the opponent can force a score of +3 (from our perspective). This becomes our "best so far" at the root.

Now consider the right subtree. We start evaluating the opponent's first option and find it leads to a leaf with value +2. At this point, we know the opponent will choose the move that gives us the lowest score. Since we already have a score of +3 from the left subtree, and the opponent can force at most +2 in the right subtree (maybe even less), the right subtree cannot improve our score. The remaining leaves in the right subtree are irrelevant—we can skip them entirely.

This is the essence of alpha-beta pruning. Whenever we can prove that a subtree cannot affect the final result, we stop searching it.

==== Alpha and Beta: The Search Window

Alpha-beta maintains two bounds during search:

- _Alpha_ ($alpha$): The lower bound on the score. This is the best score that the maximizing player (at this node or above) can already achieve through a different move sequence. If we find a move that yields a score $<= alpha$, it is worse than what we already have and can be discarded.
- _Beta_ ($beta$): The upper bound on the score. This is the best score the minimizing player (opponent) can achieve from an alternative line. If we find a move that yields a score $>= beta$, the opponent would avoid this line (since it is too good for us), and we can stop searching.

At any node, the valid score range is $(alpha, beta)$. Scores $<= alpha$ are "fail-low" (not good enough). Scores $>= beta$ are "fail-high" (too good—the opponent will avoid giving us this). Scores strictly between alpha and beta represent improvements over our current best.

The initial call at the root uses $alpha = -infinity$ and $beta = +infinity$: any score is acceptable.

==== The Alpha-Beta Algorithm

The negamax formulation with alpha-beta bounds:

```text
function alphabeta(position, depth, alpha, beta):
    if depth == 0 or game_over(position):
        return evaluate(position)

    for each move in legal_moves(position):
        make_move(position, move)
        score = -alphabeta(position, depth - 1, -beta, -alpha)
        unmake_move(position, move)

        if score >= beta:
            return beta   // Fail-high: opponent would avoid this
        if score > alpha:
            alpha = score // New best score (raise alpha)

    return alpha
```

The crucial detail is the recursive call: we pass `(-beta, -alpha)` as the new bounds. This works because:

- The child is evaluated from the perspective of the player whose turn it is (which is now the opponent).
- Our beta (upper bound for us) becomes the child's alpha (lower bound) after negation: the child must find a move that gives us AT LEAST a score of -beta from their perspective, otherwise the child's move lets us achieve beta or better, which is too good for us (from the child's minimizing perspective, it's too bad).
- Our alpha (lower bound for us) becomes the child's beta (upper bound) after negation: if the child finds a move giving them -alpha or better, we would achieve at most alpha, which is already achievable elsewhere.

Let us trace through this carefully with the example from earlier.

==== Detailed Alpha-Beta Walkthrough

Consider the following tree (leaves are static evaluations from our perspective):

```
         Root (max node, depth 2)
         /          \
    Min node       Min node
    /    \         /    \
  +3    +5       +2    +9
```

We call `alphabeta(root, 2, -INF, +INF)`.

_At the root (depth 2, alpha=-INF, beta=+INF):_

1. Generate first move. Make the move, reaching the left min node.
2. Call `alphabeta(left_min, 1, -beta=+INF, -alpha=-INF)` but with bounds flipped: `alphabeta(left_min, 1, -INF, +INF)`.

Wait—let me be precise. The call is `-alphabeta(child, depth-1, -beta, -alpha)`.

At the root: alpha=-INF, beta=+INF. So the child call is `-alphabeta(left_min, 1, -(+INF), -(-INF))` = `-alphabeta(left_min, 1, -INF, +INF)`.

_At the left min node (depth 1, alpha=-INF, beta=+INF):_

1. Generate first move (leads to leaf +3). Call: `-alphabeta(leaf_3, 0, -(+INF), -(-INF))` = `-alphabeta(leaf_3, 0, -INF, +INF)`.
2. Leaf at depth 0 returns evaluate(leaf) = +3. So child call returns `-3`. Wait no: the leaf is a max node (our turn), and we evaluate from our perspective. Let me be more careful.

Actually, the evaluation function always returns the score from the perspective of the side to move. The leaf node at depth 0 represents a position where it is the opponent's turn (since depth decreases by 1 each ply from a max root). The evaluate function returns the score from the opponent's perspective. We negate it to get our perspective. So if the position is worth +3 for us, evaluate returns -3 for the opponent, and we negate to get +3.

Let me re-trace with consistent perspective:

```
Root: our turn, depth=2.

Left child (after our move): opponent's turn, depth=1.
  Evaluate(node) returns score from opponent's perspective.
  We negate to get our perspective.

  Grandchild left (after opponent's move): our turn, depth=0.
    Evaluate returns score from our perspective = +3.
    Return +3 to parent.

  Parent (opponent's turn) receives: -(+3) = -3 from opponent's perspective?
  No. Let me be more precise.
```

Let me use the exact algorithm. At a node where it is player P's turn:

```text
alphabeta(node, depth, alpha, beta):
    if depth == 0: return evaluate_from_perspective_of_player_P(node)
    for each move:
        make_move  // now it's opponent's turn
        score = -alphabeta(child, depth-1, -beta, -alpha)
        // The negative converts from opponent's perspective to P's perspective
```

At the root (our turn, depth=2):
- alpha=-INF, beta=+INF
- Make first move, child is at opponent's turn, depth=1
- Call: score = -alphabeta(child, 1, -INF, +INF)

At child (opponent's turn, depth=1):
- alpha=-INF, beta=+INF
- Make move to grandchild (our turn, depth=0)
- Call: score = -alphabeta(grandchild, 0, -INF, +INF)

At grandchild (our turn, depth=0):
- Return evaluate from our perspective. The leaf evaluation is +3 for us.
- Return +3.

Back at child (opponent's turn):
- score = -(+3) = -3. From opponent's perspective, this is worth -3 (i.e., +3 for us = -3 for them).
- -3 >= beta (+INF)? No.
- -3 > alpha (-INF)? Yes. Update alpha = -3.
- Continue to next move.

Make next move to grandchild_right (our turn, depth=0). Evaluate returns +5 for us.

Back at child:
- score = -(+5) = -5.
- -5 >= beta (+INF)? No.
- -5 > alpha (-3)? No. (alpha = -3, and -5 < -3)

All moves done. Return alpha = -3 (from opponent's perspective).

Back at root:
- score = -(-3) = +3. From our perspective, the left child gives +3.
- +3 >= beta (+INF)? No.
- +3 > alpha (-INF)? Yes. alpha = +3.

Continue to right child. Make move to right_min (opponent's turn, depth=1).
- Call: score = -alphabeta(right_min, 1, -(+INF), -(+3)) = -alphabeta(right_min, 1, -INF, -3).

At right_min (opponent's turn, depth=1):
- alpha=-INF, beta=-3.
- Make first move to grandchild (our turn, depth=0). Evaluate returns +2 for us.
- Call: score = -alphabeta(grandchild, 0, -(-3), -(-INF)) = -alphabeta(grandchild, 0, 3, +INF).

At grandchild (our turn, depth=0):
- Return evaluate = +2.
- But alpha=3, beta=+INF. +2 <= alpha? No: +2 < 3, so this is a fail-low!

Wait, at the grandchild depth=0 we just return the evaluation without bounds checking. The bound check happens at the child. Let me redo:

At grandchild (depth=0): return +2.

Back at right_min:
- score = -(+2) = -2.
- -2 >= beta (-3)? Yes! -2 >= -3. This is a fail-high (beta cutoff)!
- Return beta = -3 immediately.

The remaining grandchild (+9) is never visited—that's the pruning!

Back at root:
- score = -(-3) = +3.
- +3 >= beta (+INF)? No.
- +3 > alpha (+3)? No. (Already have +3.)

Root returns alpha = +3.

The pruning saved one leaf evaluation. In a tree with millions of leaves, the savings are enormous.

==== The Mathematical Properties of Alpha-Beta

_Optimality_: Alpha-beta returns the same result as full minimax, provided the static evaluation function is deterministic and the game has no chance elements. This is a theorem: the alpha-beta procedure never prunes a move that could affect the minimax value. The proof is by induction on the tree depth and follows from the observation that a cutoff at beta means the opponent has a better (from their perspective) alternative move higher in the tree that makes this subtree irrelevant.

_Best-case complexity_: When moves are perfectly ordered (the best move is examined first at every node), alpha-beta visits approximately $O(b^(d/2))$ nodes—the square root of the minimax tree. For branching factor 35 and depth 10, minimax visits $approx 2.76 times 10^15$ nodes, while perfectly-ordered alpha-beta visits approximately $b^(d/2) = 35^5 approx 52.5 times 10^6$ nodes—only about 52 million nodes. This is an improvement factor of over 50 million!

_Worst-case complexity_: When moves are ordered worst-first (reverse ordering), alpha-beta visits all $b^d$ nodes, matching minimax. No pruning occurs because the best move is found last.

_Expected complexity_: With random ordering, alpha-beta visits approximately $O(b^(3d/4))$ nodes, better than minimax but worse than the best case. This is why move ordering is so critically important—we will dedicate an entire chapter to it.

==== Node Types in Alpha-Beta Search

Alpha-beta search classifies each node into one of three types:

_PV Nodes (Principal Variation nodes)_: These are nodes where the score lies strictly between alpha and beta: `alpha < score < beta`. PV nodes are the "main line" nodes—they represent the best sequence of moves found so far. At PV nodes, all moves must be searched (we cannot prove any cutoff before exhausting moves), though future PV nodes deeper in the search benefit from narrower bounds.

_Cut Nodes_: These are nodes where a beta cutoff occurs: `score >= beta`. The first move (or some early move) proves that this node is "too good" for the opponent to allow, so the remaining moves are pruned. Cut nodes are where most of the computational savings come from. In the perfectly-ordered case, every second ply is a cut node (the first move causes a cutoff).

_All Nodes_: These are nodes where all moves are searched but none exceeds alpha: `score <= alpha`. The entire subtree is searched only to confirm that no move is good enough. All nodes are the most expensive type, and they occur when the position is genuinely poor for the side to move.

In a well-ordered search with $b$ moves per node, roughly:

- 1 node at the root is a PV node
- $b-1$ children of PV nodes are Cut nodes (one fails high, the rest are searched to verify they don't also fail high)
- At All nodes, all $b$ children are Cut nodes (since the parent doesn't care which move fails high)
- Children of Cut nodes are All nodes (since the opponent will search all moves to try to refute the cut)

This PV/Cut/All classification is crucial for many search heuristics, especially in how we apply pruning and reductions. We treat PV nodes with care (we want accurate scores for the principal variation), while Cut and All nodes can be searched more aggressively with speculative pruning.

==== Code Examples: Alpha-Beta in Five Languages

**C Implementation:**

```c
int alphabeta(Board *board, int depth, int alpha, int beta) {
    if (depth == 0) {
        return evaluate(board);
    }

    int moves[256];
    int num_moves = generate_moves(board, moves);

    if (num_moves == 0) {
        if (is_in_check(board)) {
            return -MATE;
        }
        return 0;  // stalemate = draw
    }

    for (int i = 0; i < num_moves; i++) {
        make_move(board, moves[i]);
        int score = -alphabeta(board, depth - 1, -beta, -alpha);
        unmake_move(board);

        if (score >= beta) {
            return beta;  // fail-high cutoff
        }
        if (score > alpha) {
            alpha = score;  // new best score, raise alpha
        }
    }

    return alpha;
}
```

**C++ Implementation:**

```cpp
int alphabeta(Board &board, int depth, int alpha, int beta) {
    if (depth == 0) {
        return board.evaluate();
    }

    auto moves = board.generateMoves();

    if (moves.empty()) {
        return board.isInCheck() ? -MATE : 0;
    }

    for (int move : moves) {
        board.makeMove(move);
        int score = -alphabeta(board, depth - 1, -beta, -alpha);
        board.unmakeMove();

        if (score >= beta) {
            return beta;  // cutoff
        }
        if (score > alpha) {
            alpha = score;
        }
    }

    return alpha;
}
```

**Rust Implementation:**

```rust
fn alphabeta(board: &mut Board, depth: i32, mut alpha: i32, beta: i32) -> i32 {
    if depth == 0 {
        return board.evaluate();
    }

    let moves = board.generate_moves();

    if moves.is_empty() {
        return if board.is_in_check() { -MATE } else { 0 };
    }

    for &mv in &moves {
        board.make_move(mv);
        let score = -alphabeta(board, depth - 1, -beta, -alpha);
        board.unmake_move();

        if score >= beta {
            return beta;  // cutoff
        }
        if score > alpha {
            alpha = score;
        }
    }

    alpha
}
```

**Zig Implementation:**

```zig
fn alphabeta(board: *Board, depth: i32, alpha: i32, beta: i32) i32 {
    if (depth == 0) {
        return board.evaluate();
    }

    var moves: [256]u32 = undefined;
    const num_moves = board.generateMoves(&moves);

    if (num_moves == 0) {
        return if (board.isInCheck()) -MATE else 0;
    }

    var a = alpha;

    for (moves[0..num_moves]) |move| {
        board.makeMove(move);
        const score = -alphabeta(board, depth - 1, -beta, -a);
        board.unmakeMove();

        if (score >= beta) {
            return beta;
        }
        if (score > a) {
            a = score;
        }
    }

    return a;
}
```

**Odin Implementation:**

```odin
alphabeta :: proc(board: ^Board, depth: i32, alpha: i32, beta: i32) -> i32 {
    if depth == 0 {
        return evaluate(board)
    }

    moves := generate_moves(board)
    defer delete(moves)

    if len(moves) == 0 {
        if is_in_check(board) {
            return -MATE
        }
        return 0
    }

    a := alpha

    for mv in moves {
        make_move(board, mv)
        score := -alphabeta(board, depth - 1, -beta, -a)
        unmake_move(board)

        if score >= beta {
            return beta
        }
        if score > a {
            a = score
        }
    }

    return a
}
```

==== Fail-Soft vs. Fail-Hard Alpha-Beta

The standard alpha-beta algorithm as presented above is called _fail-hard_: when a cutoff occurs (`score >= beta`), we return `beta` immediately. The caller only knows that the true score is _at least_ beta, but not how much better.

_Fail-soft_ alpha-beta returns the actual score on cutoff rather than beta:

```text
function alphabeta_fail_soft(position, depth, alpha, beta):
    if depth == 0 or game_over(position):
        return evaluate(position)

    bestScore = -INFINITY
    for each move in legal_moves(position):
        make_move(position, move)
        score = -alphabeta_fail_soft(position, depth - 1, -beta, -alpha)
        unmake_move(position, move)

        if score > bestScore:
            bestScore = score
        if score > alpha:
            alpha = score
        if score >= beta:
            break  // return bestScore, which may be > beta

    return bestScore
```

In fail-soft, `bestScore` can exceed `beta`. This provides more information: the caller knows that the true score is at least `bestScore`, which may be a stronger lower bound than `beta`. This additional information is valuable in several contexts:

1. _Transposition table_: When storing a fail-high entry, fail-soft stores the actual score achieved, providing a tighter lower bound for future lookups. This can lead to more cutoffs in subsequent searches.

2. _Aspiration windows_: When an aspiration window fails high, the fail-soft score tells us _how much_ to widen the window, rather than requiring an expensive re-search with a full window.

3. _Move ordering_: A fail-soft score above beta can be used to update history tables with more precision, improving move ordering for subsequent searches.

Modern engines almost universally use fail-soft alpha-beta. Stockfish, Komodo, Ethereal, and Berserk all use fail-soft formulations.

**Fail-Soft Alpha-Beta in C:**

```c
int alphabeta_fail_soft(Board *board, int depth, int alpha, int beta) {
    if (depth == 0) {
        return evaluate(board);
    }

    int moves[256];
    int num_moves = generate_moves(board, moves);

    if (num_moves == 0) {
        if (is_in_check(board)) return -MATE;
        return 0;
    }

    int best_score = -INF;

    for (int i = 0; i < num_moves; i++) {
        make_move(board, moves[i]);
        int score = -alphabeta_fail_soft(board, depth - 1, -beta, -alpha);
        unmake_move(board);

        if (score > best_score) {
            best_score = score;
            if (score > alpha) {
                alpha = score;
                if (score >= beta) {
                    break;  // return actual score, not beta
                }
            }
        }
    }

    return best_score;
}
```

==== The Importance of Move Ordering

Alpha-beta pruning is only effective when moves are examined in a good order. The ideal ordering places the best move first at every node. In chess, this is impossible to guarantee (since we don't know the best move without searching), but we can achieve impresively close approximations using heuristics we will study in Chapter 9.

To understand just how dramatic the impact of ordering is, consider this comparison:

#figure(
  table(
    columns: (1fr, 1fr, 1fr),
    table.header([*Ordering Quality*], [*Nodes Visited ($b=35, d=10$)*], [*Improvement Factor*]),
    [Perfect (best first)], [$35^5 approx 5.25 times 10^7$], [$5.25 times 10^7$ (baseline)],
    [Good (best in top 3)], [$approx 2.36 times 10^8$], [$4.5 times$ worse than perfect],
    [Random], [$approx 2.14 times 10^12$], [$4.1 times 10^4 times$ worse than perfect],
    [Worst (worst first)], [$35^10 approx 2.76 times 10^15$], [$5.25 times 10^7 times$ worse than perfect],
  ),
  caption: [Impact of move ordering on alpha-beta search efficiency],
)

Even "good" ordering (best move among the first few examined) achieves only about 4.5x worse performance than perfect ordering—still vastly better than random. This is why move ordering heuristics are among the most performance-critical components of any chess engine.

=== Principal Variation Search (PVS)

==== Motivation and Intuition

Principal Variation Search (PVS), also known as NegaScout, is a refinement of alpha-beta that exploits the observation that at most nodes, the first move examined is likely to be the best one. In a well-ordered search:

- At Cut nodes, the first move causes a cutoff—no other moves need to be searched.
- At All nodes, no move exceeds alpha—all moves must be searched, but none will improve the score.
- At PV nodes, we want to find the exact score.

PVS assumes that the first move at each node is likely the best. For all subsequent moves, it performs a _zero-window search_ (also called a _scout search_ or _null-window search_) with bounds `(alpha, alpha+1)`. If the zero-window search confirms that the move is not better than alpha (score <= alpha), we skip the full-window search. If it fails high (score >= alpha+1), the move could be better than our current best, and we re-search with the full window.

A zero-window search is simply an alpha-beta call where `beta = alpha + 1`. This is the narrowest possible window that still distinguishes between "worse than or equal to alpha" and "better than alpha." Since the window is narrow, zero-window searches generate many cutoffs and are very fast.

==== The PVS Algorithm

```text
function pvs(position, depth, alpha, beta):
    if depth == 0 or game_over(position):
        return evaluate(position)

    firstMove = true
    for each move in legal_moves(position):
        make_move(position, move)

        if firstMove:
            // Search the first move with full window
            score = -pvs(position, depth - 1, -beta, -alpha)
            firstMove = false
        else:
            // Zero-window search to test if move can beat alpha
            score = -pvs(position, depth - 1, -alpha - 1, -alpha)
            if alpha < score and score < beta:
                // Zero-window failed high: re-search with full window
                score = -pvs(position, depth - 1, -beta, -alpha)

        unmake_move(position, move)

        if score >= beta:
            return beta   // cutoff
        if score > alpha:
            alpha = score // raise alpha

    return alpha
```

Key points:

1. The first move is always searched with a full window `(alpha, beta)`.
2. Subsequent moves are first searched with a zero window `(alpha, alpha+1)`. This is a binary test: is this move better than our current best?
3. If the zero-window search returns a score strictly between alpha and beta (`alpha < score < beta`), the move is better than our previous best AND not a cutoff. We re-search with the full window to get the exact score.
4. If the zero-window search returns `score <= alpha`, the move is worse than our current best—we discard it without the expensive full-window search.
5. If the zero-window search returns `score >= beta`, we have a cutoff—return beta immediately.

The efficiency gain comes from item 4: most moves after the first are not better than alpha, and the zero-window search confirms this cheaply.

==== PVS vs. Alpha-Beta: When PVS Wins

PVS provides significant savings when move ordering is good. In the perfectly-ordered case:

- Alpha-beta searches $b$ moves at each node, each with full window.
- PVS searches the first move with full window, the remaining $b-1$ moves with zero window (fast), and none require re-search (because none are better than the first).

The reduction factor approaches $b$: instead of $b$ full-window searches, PVS does 1 full-window search and $b-1$ fast zero-window searches. Since zero-window searches generate many cutoffs, they are significantly faster.

In practice, PVS reduces nodes by 10-30% compared to plain alpha-beta even with good ordering. When ordering is imperfect and re-searches are needed, PVS is still typically faster because re-searches are rare (the first move is indeed best most of the time).

==== The Re-Search Problem

A potential issue with PVS is _search instability_: the zero-window search might give a different result than the full-window search due to search dependencies (transposition table hits, history tables modified during the zero-window search, etc.). This can cause:

- The zero-window search says "score <= alpha" but a full-window search would give "score > alpha" (missed improvement).
- The zero-window search says "score >= alpha+1" but a full-window search would give "score <= alpha" (spurious re-search).

In practice, these issues are rare and the performance benefits of PVS far outweigh the occasional wasted re-search. Modern engines accept these rare inconsistencies as a worthwhile trade-off.

==== Code Examples: PVS in Five Languages

**C Implementation:**

```c
int pvs(Board *board, int depth, int alpha, int beta) {
    if (depth == 0) {
        return evaluate(board);
    }

    int moves[256];
    int num_moves = generate_moves(board, moves);

    if (num_moves == 0) {
        if (is_in_check(board)) return -MATE;
        return 0;
    }

    int first_move = 1;

    for (int i = 0; i < num_moves; i++) {
        make_move(board, moves[i]);
        int score;

        if (first_move) {
            score = -pvs(board, depth - 1, -beta, -alpha);
            first_move = 0;
        } else {
            // Zero-window search
            score = -pvs(board, depth - 1, -alpha - 1, -alpha);
            if (score > alpha && score < beta) {
                // Re-search with full window
                score = -pvs(board, depth - 1, -beta, -alpha);
            }
        }

        unmake_move(board);

        if (score >= beta) {
            return beta;  // cutoff
        }
        if (score > alpha) {
            alpha = score;
        }
    }

    return alpha;
}
```

**C++ Implementation:**

```cpp
int pvs(Board &board, int depth, int alpha, int beta) {
    if (depth == 0) {
        return board.evaluate();
    }

    auto moves = board.generateMoves();

    if (moves.empty()) {
        return board.isInCheck() ? -MATE : 0;
    }

    bool firstMove = true;

    for (int move : moves) {
        board.makeMove(move);
        int score;

        if (firstMove) {
            score = -pvs(board, depth - 1, -beta, -alpha);
            firstMove = false;
        } else {
            score = -pvs(board, depth - 1, -alpha - 1, -alpha);
            if (score > alpha && score < beta) {
                score = -pvs(board, depth - 1, -beta, -alpha);
            }
        }

        board.unmakeMove();

        if (score >= beta) return beta;
        if (score > alpha) alpha = score;
    }

    return alpha;
}
```

**Rust Implementation:**

```rust
fn pvs(board: &mut Board, depth: i32, mut alpha: i32, beta: i32) -> i32 {
    if depth == 0 {
        return board.evaluate();
    }

    let moves = board.generate_moves();

    if moves.is_empty() {
        return if board.is_in_check() { -MATE } else { 0 };
    }

    let mut first_move = true;

    for &mv in &moves {
        board.make_move(mv);
        let score;

        if first_move {
            score = -pvs(board, depth - 1, -beta, -alpha);
            first_move = false;
        } else {
            score = -pvs(board, depth - 1, -alpha - 1, -alpha);
            if score > alpha && score < beta {
                score = -pvs(board, depth - 1, -beta, -alpha);
            }
        }

        board.unmake_move();

        if score >= beta {
            return beta;
        }
        if score > alpha {
            alpha = score;
        }
    }

    alpha
}
```

**Zig Implementation:**

```zig
fn pvs(board: *Board, depth: i32, alpha: i32, beta: i32) i32 {
    if (depth == 0) {
        return board.evaluate();
    }

    var moves: [256]u32 = undefined;
    const num_moves = board.generateMoves(&moves);

    if (num_moves == 0) {
        return if (board.isInCheck()) -MATE else 0;
    }

    var a: i32 = alpha;
    var first_move: bool = true;

    for (moves[0..num_moves]) |move| {
        board.makeMove(move);
        const score = blk: {
            if (first_move) {
                first_move = false;
                break :blk -pvs(board, depth - 1, -beta, -a);
            } else {
                const zw_score = -pvs(board, depth - 1, -a - 1, -a);
                if (zw_score > a and zw_score < beta) {
                    break :blk -pvs(board, depth - 1, -beta, -a);
                }
                break :blk zw_score;
            }
        };
        board.unmakeMove();

        if (score >= beta) return beta;
        if (score > a) a = score;
    }

    return a;
}
```

**Odin Implementation:**

```odin
pvs :: proc(board: ^Board, depth: i32, alpha: i32, beta: i32) -> i32 {
    if depth == 0 {
        return evaluate(board)
    }

    moves := generate_moves(board)
    defer delete(moves)

    if len(moves) == 0 {
        if is_in_check(board) {
            return -MATE
        }
        return 0
    }

    a := alpha
    first_move := true

    for mv in moves {
        make_move(board, mv)
        score: i32

        if first_move {
            score = -pvs(board, depth - 1, -beta, -a)
            first_move = false
        } else {
            score = -pvs(board, depth - 1, -a - 1, -a)
            if score > a && score < beta {
                score = -pvs(board, depth - 1, -beta, -a)
            }
        }

        unmake_move(board)

        if score >= beta {
            return beta
        }
        if score > a {
            a = score
        }
    }

    return a
}
```

=== Score Representation and Mate Distance

==== Centipawn Scores

Chess engines conventionally express evaluation scores in _centipawns_ (cp). One centipawn is 1/100th of a pawn's value. A position worth +100 cp is one pawn up for the side to move. +50 cp represents roughly a half-pawn advantage (a slight edge).

Typical score ranges:

- 0: equal position
- +30 to +70: slight advantage (better piece placement, space)
- +70 to +150: clear advantage (a pawn up, or equivalent positional edge)
- +150 to +300: winning advantage
- +300 or more: decisively winning

Scores are always from the perspective of the side to move: +100 means the side to move is up a pawn.

==== Mate Scores

A mate score must be distinguishable from a large material advantage. The convention is to use a value above a threshold:

$ "MATE_SCORE" = 100000 $

A mate in $N$ plies (half-moves) gives a score of:

$ "mate_score" = "MATE_SCORE" - N $

So mate in 1 (our next move checkmates) = 99999. Mate in 2 = 99998. And being mated in 1 = -99999, mated in 2 = -99998.

The key property is that a mate in fewer moves is preferred:

- Mate in 1 (99999) > Mate in 2 (99998) > Mate in 3 (99997)
- Being mated in 3 (-99997) > Being mated in 2 (-99998) > Being mated in 1 (-99999)

This ensures the engine prefers faster mates and delays being mated.

**Encoding and decoding mate scores:**

```c
#define MATE_SCORE  100000
#define MATE_IN_MAX 255

// Check if a score is a mate score
static inline bool is_mate_score(int score) {
    int abs_score = score < 0 ? -score : score;
    return abs_score >= MATE_SCORE - MATE_IN_MAX;
}

// Encode mate in N plies
static inline int mate_in(int plies) {
    return MATE_SCORE - plies;
}

// Encode mated in N plies
static inline int mated_in(int plies) {
    return -MATE_SCORE + plies;
}

// Decode: how many plies to mate
static inline int plies_to_mate(int score) {
    if (score > 0) {
        return MATE_SCORE - score;
    } else {
        return MATE_SCORE + score;
    }
}
```

==== Draw Score

A draw (stalemate, insufficient material, threefold repetition, fifty-move rule) is scored as 0. In contempt settings (where the engine wants to avoid draws), a small non-zero draw score may be used, but this is engine-specific and typically configurable.

==== Encoding Scores for the Transposition Table

When storing scores in the transposition table (Chapter 10), we need to distinguish between exact scores, lower bounds, and upper bounds. We use the TT bound type alongside the score:

```c
enum TT_Bound {
    TT_EXACT,     // exact score, can be used directly
    TT_LOWER,     // score is a lower bound (fail-high at this node)
    TT_UPPER      // score is an upper bound (fail-low at this node)
};
```

When we retrieve a score from the TT:

- If bound is EXACT and stored depth >= current depth: use the stored score.
- If bound is LOWER and stored depth >= current depth and stored score >= beta: cutoff (score is at least beta).
- If bound is UPPER and stored depth >= current depth and stored score <= alpha: fail-low (score is at most alpha).
- Otherwise: cannot use TT score, need to search.

This integration with alpha-beta is seamless and provides enormous savings.

=== Checkmate Distance Pruning

When the search discovers that a position leads to forced mate, we can often prune moves that lead to longer mates. This is called _checkmate distance pruning_ or _mate distance pruning_.

The basic idea: if we have found a forced mate in $N$ plies, any move that cannot force mate in $< N$ plies can be pruned. This is implemented by tracking the best mate distance found at each node and using it to tighten alpha.

In practice, this is often handled implicitly by the mate score encoding: since mate in 1 (99999) > mate in 2 (99998), the standard alpha-beta comparisons automatically prefer faster mates.

=== Summary

We have covered the foundational search algorithms for chess engines:

1. _Minimax_ — the theoretical foundation, visiting all nodes
2. _Negamax_ — a cleaner formulation using the negation trick
3. _Alpha-Beta_ — the fundamental optimization, pruning provably irrelevant branches, reducing complexity from $O(b^d)$ to $O(b^(d/2))$ in the best case
4. _PVS_ — a refinement of alpha-beta that uses zero-window searches to test non-first moves cheaply

These algorithms form the backbone of every competitive chess engine. In the next chapters, we will explore the dozens of enhancements that bridge the gap between these basic algorithms and the state-of-the-art search of engines like Stockfish.
