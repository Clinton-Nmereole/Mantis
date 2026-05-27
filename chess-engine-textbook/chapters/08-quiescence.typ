== Quiescence Search and the Horizon Effect

=== The Fundamental Problem: Why Fixed-Depth Search Fails

Imagine you are a chess engine searching to a fixed depth of 4 plies (half-moves). You are evaluating a position where White has a queen that is under attack. At depth 4, your engine might see a sequence where White sacrifices a pawn to delay the queen's capture, and at the horizon (the end of the 4-ply search), the queen is still on the board. The engine evaluates this as "queen still present" and gives a favorable score—completely unaware that on the very next ply, Black will capture the queen.

This is the *Horizon Effect*, first described by Hans Berliner in 1973. It is arguably the single most destructive problem in computer chess, and understanding it is the gateway to understanding why modern chess engines search the way they do.

==== The Horizon Effect, Formally Defined

The Horizon Effect occurs when a fixed-depth search cannot see beyond its search horizon (the maximum depth of the current iteration). When an engine detects that a disadvantageous outcome is inevitable—but just barely beyond the horizon—it may play "delaying" moves that push the problem past the search depth. These delaying moves are often detrimental in themselves, but because the engine cannot see the eventual outcome, it incorrectly believes it is avoiding the loss.

We must distinguish between two variants of the horizon effect:

*Negative Horizon Effect* (bad news delayed): The engine plays suboptimal moves to push an inevitable loss beyond the search horizon. The classic example is repeatedly sacrificing pawns to delay the loss of a queen. Each pawn sacrifice is a small material loss, but by the time all delaying pawns are exhausted, the search horizon has been reached, and the queen loss is never seen.

*Positive Horizon Effect* (good news delayed): The engine fails to see that it can achieve a winning outcome if it searches just one ply deeper. A forced mate in 5 might be completely invisible at depth 4, leading the engine to choose a materially-equal but drawn continuation instead.

==== Concrete Example of the Negative Horizon Effect

Consider this simplified position (White to move):

#figure(
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    [r], [n], [b], [q], [k], [b], [n], [r],
    [p], [p], [p], [p], [-], [p], [p], [p],
    [-], [-], [-], [-], [-], [-], [-], [-],
    [-], [-], [-], [-], [p], [-], [-], [-],
    [-], [-], [-], [-], [P], [Q], [-], [-],
    [-], [-], [-], [-], [-], [-], [-], [-],
    [P], [P], [P], [P], [-], [P], [P], [P],
    [R], [N], [B], [-], [K], [B], [N], [R],
  ),
  caption: [White's queen on f4 is attacked by Black's pawn on e5. White can delay capture by checking with the queen.]
)

In this position, Black's pawn on e5 attacks White's queen on f4. If White does nothing, Black will capture the queen on the next move. White has no way to save the queen through retreat (all safe squares are controlled). However, White can play a series of checks:

1. Qf4-f7+ Kh8-h7
2. Qf7-f5+ Kh7-g8
3. Qf5-g6+ Kg8-h8

A search to depth 4 sees three checks, and at the horizon the queen is still on the board. The engine reports an equal material score. What it *does not* see is that after the third check, Black's king retreats to h8, and White runs out of checks—the queen is captured on the next move regardless.

If White has pawns available, the engine might instead sacrifice them:

1. Qf4-f7+ Kh8-h7
2. b3-b4 (sacrificing a pawn to give the queen a flight square)
3. ...b5xb4
4. Qf7-e8 (the queen escapes—but only because the search ended before Black's recapture)

At depth 4, the engine sees the queen escape and evaluates the position as only down a pawn. In reality, Black's position is crushing, and White's material deficit is far greater.

This example illustrates why quiescence search is *not optional*. Without it, every fixed-depth engine makes catastrophic tactical blunders.

==== The Mathematical Cost of the Horizon Effect

We can quantify the severity. In a typical middlegame position, there are approximately 30-40 legal moves per side. A depth-10 search examines roughly $40^10 approx 1.05 times 10^16$ nodes. But if 30% of those positions are "noisy"—containing unresolved tactical sequences—then approximately $3 times 10^15$ terminal positions are evaluated incorrectly. This is not a minor error; it is a systematic failure of the entire evaluation function.

The horizon effect is not solved by simply searching deeper. Doubling the search depth reduces the number of positions with unresolved tactics, but it does not eliminate them. A queen that can be captured in 2 plies at depth 10 is still invisible at depth 10 (if the capture happens on ply 11 or 12). The only solution is to *change the nature of the search itself* when tactical sequences are unresolved.

=== The Solution: Quiescence Search

Quiescence Search (QS) is a search extension that runs at the leaves of the main search tree. Instead of evaluating a position immediately when the nominal search depth reaches zero, the engine continues searching—but only a subset of moves that are "noisy" or "unstable." The goal is to reach a *quiescent* position: one where no immediate tactical sequence can dramatically alter the evaluation.

The word "quiescent" means "quiet" or "at rest." A quiescent position has no hanging pieces, no pending captures, and no immediate checkmating threats. Once a quiescent position is reached, the static evaluation function can be trusted, because no immediate tactical operation will drastically change the material balance.

==== The Standing Pat Principle

Quiescence search is built upon the *standing pat* principle, introduced with the alpha-beta algorithm. The idea is profound in its simplicity: at any point during quiescence search, the side to move can choose to *do nothing*—to "stand pat"—and accept the static evaluation of the current position.

Why can we allow standing pat? Because the player is not forced to capture. If the static evaluation is already favorable (say, +2.00 pawns), the player can simply decline to make any further captures and keep their advantage. Conversely, if the evaluation is poor, the player will eagerly search captures to try to improve their position.

In minimax terms, standing pat means that the player can always achieve at least the static evaluation of the current position. Formally, for a maximizing player with static evaluation eval, the quiescence search returns `max(eval, max_{m in captures} -QS(child, m))`.

==== The Core Quiescence Search Algorithm

The algorithm is remarkably compact. Here is the complete pseudocode:

```
function quiescence(alpha, beta):
    stand_pat = evaluate(position)
    if stand_pat >= beta:
        return beta  // fail-high: position is too good for opponent
    if stand_pat > alpha:
        alpha = stand_pat  // raise alpha

    for each capture move (ordered by MVV-LVA or SEE):
        if !SEE_prune(capture, alpha, beta):
            make_move(capture)
            score = -quiescence(-beta, -alpha)
            unmake_move(capture)
            if score >= beta:
                return beta
            if score > alpha:
                alpha = score

    return alpha
```

Let us analyze this line by line.

*Step 1 — Standing Pat Evaluation:* The static evaluation of the current position is computed. If the position is already "good enough" for the side to move (evaluation exceeds beta), we return immediately. The opponent would never allow this position to be reached because they have a better alternative earlier in the tree. This is a *standing pat cutoff*.

*Step 2 — Alpha Update:* If the standing pat score is better than alpha (the best score found so far in this subtree), we raise alpha. This means the side to move can at least achieve the standing pat score.

*Step 3 — Capture Loop:* We iterate through capture moves. Not all captures are searched—we filter using SEE pruning (discussed below). For each capture that passes the filter, we make the move, recursively call quiescence search (negated, with swapped alpha-beta bounds), and then unmake the move.

*Step 4 — Beta Cutoff:* If any capture produces a score exceeding beta, we prune immediately. This is the standard alpha-beta cutoff applied to quiescence.

*Step 5 — Return Best Score:* After searching all captures, we return alpha, which represents the best score achievable from this position (either the standing pat score or a better score found through captures).

==== Complete Implementation in C

```c
// Quiescence search implementation in C
// Assumes bitboard board representation and standard types

#define INF 30000
#define MATE 29000

// Static exchange evaluation (forward declaration)
int see(int move);

int quiescence(Board *board, int alpha, int beta) {
    // Standing pat
    int stand_pat = evaluate(board);
    if (stand_pat >= beta) {
        return beta;  // Fail-high cutoff
    }
    if (stand_pat > alpha) {
        alpha = stand_pat;  // Raise alpha floor
    }

    // Generate captures
    MoveList captures;
    generate_captures(board, &captures);
    score_captures(board, &captures);  // MVV-LVA or SEE ordering

    for (int i = 0; i < captures.count; i++) {
        // Sort captures inline or pick best
        int best_idx = i;
        int best_score = captures.moves[i].score;
        for (int j = i + 1; j < captures.count; j++) {
            if (captures.moves[j].score > best_score) {
                best_score = captures.moves[j].score;
                best_idx = j;
            }
        }
        // Swap
        Move tmp = captures.moves[i];
        captures.moves[i] = captures.moves[best_idx];
        captures.moves[best_idx] = tmp;

        Move move = captures.moves[i];

        // SEE pruning: skip losing captures
        if (see(board, move) < 0) {
            continue;
        }

        // Delta pruning: skip captures that can't raise alpha
        if (stand_pat + get_piece_value(board->squares[GET_TO(move)]) + 200 < alpha) {
            continue;
        }

        make_move(board, move);
        int score = -quiescence(board, -beta, -alpha);
        unmake_move(board, move);

        if (score >= beta) {
            return beta;  // Fail-high
        }
        if (score > alpha) {
            alpha = score;  // New best score
        }
    }

    return alpha;
}
```

==== Complete Implementation in C++

```cpp
// Quiescence search implementation in C++ (modern, C++20)
// Uses std::vector and lambda-based move generation

#include <vector>
#include <algorithm>
#include <cstdint>

constexpr int INF = 30000;
constexpr int MATE = 29000;

class Engine {
public:
    // SEE pruning threshold check
    bool see_ge(Move move, int threshold) const;

    // Static evaluation
    int evaluate() const;

    // Piece value lookup
    int piece_value(PieceType pt) const;

    int quiescence(int alpha, int beta) {
        // Standing pat
        const int stand_pat = evaluate();
        if (stand_pat >= beta) {
            return beta;
        }
        if (stand_pat > alpha) {
            alpha = stand_pat;
        }

        // Generate and score captures
        std::vector<ScoredMove> captures;
        generate_captures([&](Move m) {
            int score = mvvlva_score(m);
            captures.push_back({m, score});
        });

        // Sort by score descending
        std::sort(captures.begin(), captures.end(),
            [](const ScoredMove &a, const ScoredMove &b) {
                return a.score > b.score;
            });

        for (const auto &[move, _] : captures) {
            // SEE pruning
            if (!see_ge(move, 0)) {
                continue;
            }

            // Delta pruning
            const PieceType captured = piece_on(to_sq(move));
            if (stand_pat + piece_value(captured) + 200 < alpha) {
                continue;
            }

            make_move(move);
            const int score = -quiescence(-beta, -alpha);
            unmake_move(move);

            if (score >= beta) {
                return beta;
            }
            if (score > alpha) {
                alpha = score;
            }
        }

        return alpha;
    }
};
```

==== Complete Implementation in Rust

```rust
// Quiescence search implementation in Rust
// Uses type-safe enums and pattern matching

use std::cmp::max;

const INF: i32 = 30000;
const MATE: i32 = 29000;

impl Engine {
    /// Quiescence search: resolve captures until a quiet position is reached.
    /// Returns a score in centipawns from the perspective of the side to move.
    fn quiescence(&mut self, alpha: i32, beta: i32) -> i32 {
        // Standing pat
        let stand_pat = self.evaluate();
        if stand_pat >= beta {
            return beta;
        }
        let mut alpha = max(alpha, stand_pat);

        // Generate and score captures
        let mut captures: Vec<ScoredMove> = self
            .generate_captures()
            .into_iter()
            .map(|mv| {
                let score = self.mvvlva_score(&mv);
                ScoredMove { mv, score }
            })
            .collect();

        // Sort by score descending
        captures.sort_by(|a, b| b.score.cmp(&a.score));

        for scored in &captures {
            let mv = &scored.mv;

            // SEE pruning: skip losing captures
            if self.see(mv) < 0 {
                continue;
            }

            // Delta pruning: skip captures that cannot reach alpha
            let captured_val = self.piece_value(self.piece_on(mv.to_sq()));
            if stand_pat + captured_val + 200 < alpha {
                continue;
            }

            self.make_move(mv);
            let score = -self.quiescence(-beta, -alpha);
            self.unmake_move(mv);

            if score >= beta {
                return beta;
            }
            if score > alpha {
                alpha = score;
            }
        }

        alpha
    }
}
```

==== Complete Implementation in Zig

```zig
// Quiescence search implementation in Zig
// Leverages compile-time safety and explicit allocators

const std = @import("std");

const INF: i32 = 30000;
const MATE: i32 = 29000;

pub fn quiescence(engine: *Engine, alpha: i32, beta: i32) i32 {
    // Standing pat
    const stand_pat = engine.evaluate();
    if (stand_pat >= beta) {
        return beta;
    }
    var alpha_mut = @max(alpha, stand_pat);

    // Generate captures into a stack-allocated buffer
    var capture_buf: [256]Move = undefined;
    const captures = engine.generateCaptures(&capture_buf);

    // Score and sort captures by MVV-LVA
    var scored: [256]ScoredMove = undefined;
    for (captures, 0..) |mv, i| {
        scored[i] = .{ .mv = mv, .score = engine.mvvlvaScore(mv) };
    }
    const scored_slice = scored[0..captures.len];
    std.sort.insertion(ScoredMove, scored_slice, {}, ScoredMove.descByScore);

    for (scored_slice) |sc| {
        const mv = sc.mv;

        // SEE pruning: skip losing captures
        if (engine.see(mv) < 0) {
            continue;
        }

        // Delta pruning
        const captured_val = engine.pieceValue(engine.pieceOn(mv.to()));
        if (stand_pat + captured_val + 200 < alpha_mut) {
            continue;
        }

        engine.makeMove(mv);
        const score = -quiescence(engine, -beta, -alpha_mut);
        engine.unmakeMove(mv);

        if (score >= beta) {
            return beta;
        }
        if (score > alpha_mut) {
            alpha_mut = score;
        }
    }

    return alpha_mut;
}
```

==== Complete Implementation in Odin

```odin
// Quiescence search implementation in Odin
// Uses distinct types and array-based procedures

package chess_engine

import "core:sort"

INF  :: 30000
MATE :: 29000

quiescence :: proc(engine: ^Engine, alpha: i32, beta: i32) -> i32 {
    // Standing pat
    stand_pat := evaluate(engine)
    if stand_pat >= beta {
        return beta
    }
    alpha_mut := max(alpha, stand_pat)

    // Generate captures
    captures: [256]Move
    capture_count := generate_captures(engine, captures[:])

    // Score and sort
    ScoredMove :: struct {
        mv:    Move,
        score: i32,
    }
    scored: [256]ScoredMove
    for i in 0..<capture_count {
        scored[i] = ScoredMove{
            mv    = captures[i],
            score = mvvlva_score(engine, captures[i]),
        }
    }
    slice := scored[:capture_count]
    sort.quick_sort(slice[:], proc(a, b: ScoredMove) -> bool {
        return a.score > b.score
    })

    for sc in slice {
        mv := sc.mv

        // SEE pruning
        if see(engine, mv) < 0 {
            continue
        }

        // Delta pruning
        captured_val := piece_value(piece_on(engine, mv_to(mv)))
        if stand_pat + captured_val + 200 < alpha_mut {
            continue
        }

        make_move(engine, mv)
        score := -quiescence(engine, -beta, -alpha_mut)
        unmake_move(engine, mv)

        if score >= beta {
            return beta
        }
        if score > alpha_mut {
            alpha_mut = score
        }
    }

    return alpha_mut
}
```

==== Delta Pruning in Detail

Delta pruning is a simple but effective technique that prunes capture moves in quiescence search that cannot possibly raise alpha, even under the most optimistic assumptions. The intuition is: if the current standing pat score is so far below alpha that even capturing the opponent's queen (the most valuable capturable piece) cannot bring the score up to alpha, then there is no need to search this capture.

The mathematical condition for delta pruning is:

$ "stand_pat" + "victim_value" + "margin" < alpha $

Where:
- $"stand_pat"$ is the static evaluation of the current position
- $"victim_value"$ is the material value of the piece being captured (in centipawns)
- $"margin"$ is a safety margin (typically 200-300 centipawns, or about 2-3 pawns worth) to account for positional factors

The margin is necessary because captures can have positional side effects beyond pure material gain. Capturing a piece might expose the opponent's king or win additional material through forks. The margin provides a buffer for these cases.

Typical piece values used in delta pruning:
- Pawn: 100 cp
- Knight: 320 cp
- Bishop: 330 cp
- Rook: 500 cp
- Queen: 900 cp
- King: 10000 cp (but king captures never actually occur)

Delta pruning works best when combined with SEE pruning. SEE pruning eliminates *losing* captures (where the opponent recaptures favorably), while delta pruning eliminates captures that simply cannot reach the target even if they were winning.

==== The Standing Pat Cutoff: A Deeper Understanding

The standing pat cutoff (`stand_pat >= beta`) deserves special attention because it is the mechanism that prevents quiescence search from exploding into a full-width search. Without it, quiescence search would have to search all captures in every position, leading to combinatorial explosion.

The logic works as follows: during alpha-beta search, beta represents the best score that the *opponent* can achieve in a sibling branch. If the current position's static evaluation already exceeds beta, it means: "This position is so good for the side to move that the opponent, who has the choice of avoiding this position entirely by playing a different move earlier in the tree, will never allow it to be reached."

Consequently, we can return beta immediately and prune all remaining capture searches. The precise value returned does not matter—only that it exceeds beta (a "fail-high"). The actual value is somewhere above beta, but we do not need to know it exactly because the opponent will avoid this branch.

The standing pat cutoff is the primary mechanism that keeps quiescence search tractable. In practice, most quiescence nodes terminate immediately because the standing pat evaluation is already high enough. Only in positions where the side to move is in trouble (low standing pat) or where a favorable capture sequence can improve the score does the search continue.

=== Static Exchange Evaluation (SEE)

Static Exchange Evaluation (SEE) is a technique for evaluating whether a capture sequence on a single square is winning or losing, without actually searching the move in the full game tree. SEE is used for two critical purposes in a modern engine:

1. *Pruning in quiescence search*: If SEE says a capture is losing (i.e., the opponent recaptures favorably), we can skip searching that capture in quiescence. This dramatically reduces the quiescence search tree.

2. *Move ordering*: Captures with positive SEE scores ("winning captures") are searched before captures with negative SEE scores ("losing captures"). Within winning captures, the captures with the largest SEE scores are searched first.

Note the distinction: SEE differs from MVV-LVA in that SEE accounts for the *full exchange sequence* rather than just the first capture. MVV-LVA says "queen takes rook" is better than "pawn takes knight." But SEE might reveal that "queen takes rook" loses the queen to a recapture while "pawn takes knight" wins a knight cleanly because the knight is undefended.

==== The SEE Swap Algorithm

The core SEE algorithm works by simulating the capture sequence on a single square. The key insight is that captures on a single square are largely independent of the rest of the board—only pieces that can reach that square matter.

The algorithm:

1. Identify all pieces (from both sides) that attack the target square.
2. Sort attackers by piece value, lowest first (because in an exchange, the weakest attacker captures first).
3. Simulate the exchange: the first capturer takes the piece on the square, then the opponent captures the capturer, and so on.
4. After each capture, the "gain" for the side that initiated the exchange is computed. The net result is determined by stepping through the sequence.

Let us formalize this with the *swap* algorithm. Let `att[0..n]` be the sorted list of attacker piece values for the target square, where `att[0]` is the weakest attacker. Let `victim` be the value of the piece currently on the square.

We compute an array `gain[0..n]` where:
- `gain[n] = 0` (no more attackers)
- `gain[i] = max(0, att[i+1] - gain[i+1])` for `i` from `n-1` down to 0

The SEE value is then `victim - gain[0]`.

Let us trace through an example. Suppose a square contains an enemy rook (value 500) and is attacked by:
- Our pawn (value 100)
- Our knight (value 320)
- Enemy bishop (value 330) — defending the rook
- Our rook (value 500)

Sorted attackers (by value, lowest first): pawn(100), knight(320), bishop(330), rook(500).
victim = 500 (the rook on the target square).

Compute gain:
- gain[3] = 0
- gain[2] = max(0, att[3] - gain[3]) = max(0, 500 - 0) = 500
- gain[1] = max(0, att[2] - gain[2]) = max(0, 330 - 500) = 0
- gain[0] = max(0, att[1] - gain[1]) = max(0, 320 - 0) = 320

SEE = victim - gain[0] = 500 - 320 = +180.

Interpretation: We win 180 centipawns in the exchange (we lose our pawn and knight, but win the rook). The exchange is winning for us.

Let us trace through a losing example. Same square with an enemy bishop (value 330), attacked by:
- Our queen (value 900)
- Enemy pawn (value 100) — defending the bishop

Sorted: pawn(100), queen(900). victim = 330.

- gain[1] = 0
- gain[0] = max(0, att[1] - gain[1]) = max(0, 900 - 0) = 900

SEE = 330 - 900 = -570.

Interpretation: We lose 570 centipawns (we lose our queen to win only a bishop). Bad capture—should be pruned.

==== SEE Implementation in C

```c
// Static Exchange Evaluation (SEE)
// Returns the net material gain from the exchange on the target square
// Uses the swap algorithm

static const int piece_values[7] = {
    0, 100, 320, 330, 500, 900, 10000
};

// Get the smallest attacker of 'target_sq' for 'side', return the piece type
// and remove that attacker from the board state (for simulation)
int get_smallest_attacker(Board *board, int target_sq, int side) {
    // Check pawn attacks
    // Check knight attacks
    // Check bishop attacks (including queen diagonals)
    // Check rook attacks (including queen orthogonals)
    // Check king attacks
    // Return the piece value of the smallest attacker, and 0 if none
    // ... (actual implementation depends on board representation)
    // This is a simplified version using bitboards
    uint64_t attackers = get_attackers_to(board, target_sq, side);

    if (attackers == 0) return 0;

    // Find smallest valued piece among attackers
    for (int pt = PAWN; pt <= KING; pt++) {
        uint64_t pieces = board->bitboards[side][pt] & attackers;
        if (pieces) {
            int from_sq = get_lsb(pieces);
            // Remove this piece from the board
            board->bitboards[side][pt] ^= (1ULL << from_sq);
            return piece_values[pt];
        }
    }
    return 0;
}

int see(Board *board, Move move) {
    int to_sq = GET_TO(move);
    int from_sq = GET_FROM(move);
    int moving_piece = board->squares[from_sq];
    int captured_piece = board->squares[to_sq];

    // Special case: en passant capture
    if (move_is_en_passant(move)) {
        // For simplicity, treat en passant as pawn captures pawn
        captured_piece = PAWN;
    }

    // Start with the value of the captured piece (or 0 if no capture)
    int gain[32];   // Stack of gains
    int depth = 0;
    gain[0] = piece_values[captured_piece];

    // The side to move initially is the moving side
    int side = board->side_to_move;

    // Remove the moving piece from the board (it's now on the target square)
    board->squares[from_sq] = EMPTY;
    // Note: The captured piece is also removed, but we account for that in gain

    // The piece currently on the target square is the moving piece
    int piece_on_sq = moving_piece;

    // Simulate the exchange
    while (1) {
        // The other side gets to capture
        side = 1 - side;

        // Find the smallest attacker of the target square
        int attacker_val = get_smallest_attacker(board, to_sq, side);

        if (attacker_val == 0) {
            break;  // No more attackers
        }

        depth++;
        // The gain for this capture: attacker captures the current piece on the square
        // minus what the opponent gains from the next capture
        gain[depth] = piece_values[piece_on_sq] - gain[depth - 1];

        // Now this attacker becomes the piece on the target square
        piece_on_sq = GET_PIECE_TYPE_FROM_VALUE(attacker_val);

        // If the current gain is too negative, stop (side can choose
        // not to capture)
        if (max(-gain[depth - 1], gain[depth]) < 0) {
            break;
        }
    }

    // Unwind: compute the net gain
    while (depth > 0) {
        if (gain[depth] > -gain[depth - 1]) {
            gain[depth - 1] = -gain[depth];
        }
        depth--;
    }

    // Restore the board state (handled by make_move/unmake_move in practice)
    return gain[0];
}

// Simplified SEE threshold check for pruning
int see_ge(Board *board, Move move, int threshold) {
    int value = see(board, move);
    return value >= threshold;
}
```

==== SEE Implementation in C++ (Modern)

```cpp
// SEE implementation in C++20 with concepts and ranges

#include <array>
#include <algorithm>
#include <bit>

class SEE {
    static constexpr std::array<int, 7> PIECE_VALUES = {
        0, 100, 320, 330, 500, 900, 10000
    };

public:
    // Check if SEE value >= threshold without computing the full value
    // This is more efficient for pruning decisions
    [[nodiscard]] static bool see_ge(
        const Board &board,
        Move move,
        int threshold
    ) noexcept {
        const Square to = move.to();
        const Square from = move.from();
        const PieceType moving = board.piece_on(from).type();
        const PieceType captured = move.is_en_passant()
            ? PieceType::Pawn
            : board.piece_on(to).type();

        int balance = PIECE_VALUES[static_cast<int>(captured)] - threshold;

        // If balance is still negative after the first capture,
        // the exchange is losing
        if (balance < 0) return false;

        balance -= PIECE_VALUES[static_cast<int>(moving)];

        // If balance is now non-negative, the exchange is winning
        // (we captured a sufficiently valuable piece)
        if (balance >= 0) return true;

        // Need to continue the exchange
        // Compute all attackers of the target square
        uint64_t occupied = board.occupied() ^ (1ULL << from);
        // ... (continue with swap algorithm as in C version)
        // For brevity, the full implementation follows the same pattern

        return false;  // Placeholder
    }

    // Full SEE computation
    [[nodiscard]] static int compute(const Board &board, Move move) noexcept;
};
```

==== SEE Implementation in Rust

```rust
// Static Exchange Evaluation in Rust
// Uses idiomatic Rust with explicit ownership

#[derive(Clone, Copy, PartialEq, Eq)]
enum PieceType { Pawn, Knight, Bishop, Rook, Queen, King }

const PIECE_VALUES: [i32; 7] = [0, 100, 320, 330, 500, 900, 10000];

impl Board {
    /// Compute the Static Exchange Evaluation for a capture move.
    /// Returns the net material gain in centipawns.
    pub fn see(&self, mv: &Move) -> i32 {
        let to = mv.to();
        let from = mv.from();
        let moving = self.piece_on(from).piece_type();
        let captured = if mv.is_en_passant() {
            PieceType::Pawn
        } else {
            self.piece_on(to).piece_type()
        };

        let mut gain = [0i32; 32];
        gain[0] = PIECE_VALUES[captured as usize];
        let mut depth = 0;

        // Simulate by temporarily making the move
        let mut occupied = self.occupied() ^ (1u64 << from as u64);

        // Recurse through attackers
        let mut side = self.side_to_move().opponent();

        loop {
            if let Some((attacker_pt, _)) =
                self.smallest_attacker(to, side, occupied)
            {
                depth += 1;
                // The current piece on the square gets captured
                let current_on_sq = if depth == 1 { moving }
                    else { /* the previous attacker */ unreachable!() };
                gain[depth] = PIECE_VALUES[current_on_sq as usize]
                    - gain[depth - 1];

                // Stop if standing pat is better
                if gain[depth].max(-gain[depth - 1]) < 0 {
                    break;
                }

                side = side.opponent();
            } else {
                break;
            }
        }

        // Unwind
        while depth > 0 {
            gain[depth - 1] = (-gain[depth]).min(gain[depth - 1]);
            depth -= 1;
        }

        gain[0]
    }

    /// Check if SEE >= threshold (for pruning decisions)
    pub fn see_ge(&self, mv: &Move, threshold: i32) -> bool {
        self.see(mv) >= threshold
    }
}
```

==== Edge Cases in SEE

*X-Ray Attacks:* When a piece moves away from a square between the attacker and the target, previously blocked sliders (bishops, rooks, queens) can now attack the target square. The SEE must account for x-ray attacks by recalculating attack sets after each capture in the simulation.

For example, if a white rook on a1 attacks a black queen on a8, but a white pawn on a4 blocks the attack. If the pawn captures something on b5 (moving off the a-file), the rook now attacks a8. A correct SEE must detect this.

*Pinned Pieces:* A piece that is pinned to the king cannot legally move off the pin line. However, SEE is a *static* analysis—it does not consider legality in the same way as full move generation. Most implementations ignore pin restrictions in SEE, which is a safe approximation (it may overestimate attacker availability, which errs on the side of caution).

*En Passant:* When evaluating an en passant capture, the captured pawn is not on the target square (it is adjacent). The SEE must account for the pawn being removed from the adjacent square, and the target square becoming empty before the capturing pawn occupies it.

*Promotions:* A pawn capture that promotes to a queen is worth significantly more than a normal pawn capture. SEE must account for the promotion bonus. Typically, if a pawn promotes during the exchange, the piece value used is that of the promoted piece (usually queen, value 900) minus the pawn value (100), giving a net bonus of 800.

==== SEE-MVV-LVA Ordering in Practice

Stockfish and most top engines use a hybrid ordering for captures in quiescence search:

1. First, compute MVV-LVA for each capture: $"score" = "victim_value" times 64 - "attacker_value"$
2. For captures where $ "SEE" >= 0 $, keep the MVV-LVA score as-is (these are "good captures").
3. For captures where $ "SEE" < 0 $, assign a negative score so they are searched after all good captures: $"score" = -10000 + "MVV-LVA"$ (these are "bad captures").

This ensures that winning captures are explored first, maximizing the chance of a quick beta cutoff and minimizing the quiescence tree size.

=== Advanced Quiescence Search Enhancements

==== Check Evasion in Quiescence

When the side to move is in check, we cannot stand pat—the king is under direct attack, and the static evaluation is not reliable (it would report a large negative score for the side in check, but they may have a way to escape). Therefore, when in check, quiescence search must:

1. Skip the standing pat evaluation entirely.
2. Generate ALL legal moves (not just captures), because only moves that resolve the check are legal.
3. Search all check-evasion moves with the same alpha-beta window.

This is critical: if we only searched captures while in check, we would miss king moves that evade the check (which are quiet moves). A king move to safety may be the only way to resolve the check.

```c
int quiescence(Board *board, int alpha, int beta) {
    // Check evasion: cannot stand pat
    if (is_in_check(board)) {
        MoveList evasions;
        generate_legal_moves(board, &evasions);  // All legal moves
        score_moves(board, &evasions);

        for (int i = 0; i < evasions.count; i++) {
            // Pick best move
            pick_best(&evasions, i);
            Move move = evasions.moves[i];

            make_move(board, move);
            int score = -quiescence(board, -beta, -alpha);
            unmake_move(board, move);

            if (score >= beta) return beta;
            if (score > alpha) alpha = score;
        }
        // If no legal moves, it's checkmate
        if (evasions.count == 0) {
            return -MATE + board->ply;
        }
        return alpha;
    }

    // Normal quiescence with standing pat...
    // (rest of the function as above)
}
```

==== Recapture-Only Extensions

A common optimization is to extend the quiescence search only on recaptures. When a piece is captured, the natural response is to recapture. By searching one additional ply beyond normal quiescence for recaptures, the engine can resolve tactical sequences that involve simple exchanges.

The implementation typically checks if the previous move was a capture on the same square as the current move's target, and if so, extends the search depth by one:

```
if move.to_sq == previous_move.to_sq:
    score = -quiescence(-beta, -alpha)  // no depth limit change
else:
    score = -quiescence(-beta, -alpha, depth - 1)
```

==== Quiescence Search Depth Limits

While quiescence search is theoretically unbounded (it keeps searching until the position is quiet), in practice we must impose a maximum depth to prevent search explosion in pathological positions. Positions with many consecutive captures (e.g., a complex trade on a single square involving many pieces) can lead to quiescence search trees of hundreds of plies.

A typical maximum quiescence depth is 16-32 plies. Beyond this depth, the engine simply returns the standing pat evaluation without searching further captures. This is rarely triggered in practice but prevents theoretical runaway.

```c
#define MAX_QS_DEPTH 24

int quiescence(Board *board, int alpha, int beta, int qs_depth) {
    if (qs_depth > MAX_QS_DEPTH) {
        return evaluate(board);  // Forced cutoff
    }
    // ... rest of function, passing qs_depth + 1 to recursive calls
}
```

==== Quiescence and the PV (Principal Variation)

When searching the Principal Variation, quiescence search must collect the best moves to form the full PV. This is achieved by maintaining a PV table for quiescence nodes:

```c
int quiescence_pv(Board *board, int alpha, int beta, Move *pv, int *pv_len) {
    int stand_pat = evaluate(board);
    if (stand_pat >= beta) return beta;
    if (stand_pat > alpha) {
        alpha = stand_pat;
        *pv_len = 0;  // Standing pat is the PV
    }

    MoveList captures;
    generate_captures(board, &captures);

    for (int i = 0; i < captures.count; i++) {
        pick_best(&captures, i);
        Move move = captures.moves[i];

        if (see(board, move) < 0) continue;

        make_move(board, move);
        Move child_pv[MAX_PLY];
        int child_len;
        int score = -quiescence_pv(board, -beta, -alpha, child_pv, &child_len);
        unmake_move(board, move);

        if (score > alpha) {
            alpha = score;
            pv[0] = move;
            memcpy(pv + 1, child_pv, child_len * sizeof(Move));
            *pv_len = 1 + child_len;
            if (score >= beta) return beta;
        }
    }

    return alpha;
}
```

=== When to Enter Quiescence: Integration with Main Search

Quiescence search is called at the leaves of the main search tree. In a standard alpha-beta search with iterative deepening, the call looks like:

```c
int alpha_beta(Board *board, int depth, int alpha, int beta) {
    if (depth <= 0) {
        // At the horizon: switch to quiescence search
        return quiescence(board, alpha, beta);
    }

    // Transposition table probe
    // Null move pruning
    // ... rest of alpha-beta search
}
```

The key decision point is `depth <= 0`. This is the horizon. When the nominal search depth is exhausted, the engine does not evaluate the position statically. Instead, it enters quiescence to resolve any pending captures.

In engines that use *fractional depth* (depths expressed in fractions of a ply for reduction purposes), quiescence is typically entered when `depth <= 0` in integer arithmetic, or after all fractional extensions have been applied.

Some engines use a *futility margin* at the frontier: if the position is so clearly bad that even quiescence cannot save it, they skip quiescence entirely and return a fail-low immediately. This is an advanced optimization discussed in the chapter on pruning.

=== Quiescence vs. Full-Width Search: Performance Analysis

To understand the performance characteristics of quiescence search, we must examine node counts. Consider a search to depth 10 in a typical middlegame position:

#table(
  columns: (auto, auto, auto),
  table.header([*Metric*], [*Without QS*], [*With QS*]),
  [Main search nodes], [~40^10 ≈ 10^16], [~40^10 ≈ 10^16],
  [Quiescence nodes], [0], [~5-15% of total],
  [Evaluation calls], [~10^16 (inaccurate)], [~1% (accurate)],
  [Tactical blunders], [Common], [Rare],
  [Total time], [Faster but wrong], [Slightly slower but correct],
)

The table reveals a crucial insight: quiescence search adds a modest overhead (5-15% additional nodes) but eliminates the vast majority of tactical blunders. The alternative—searching deeper without quiescence—would require exponentially more nodes and still leave tactical holes at the new horizon.

In modern engines, quiescence search nodes typically account for 10-30% of total nodes searched, depending on the position. In highly tactical positions (e.g., positions with many hanging pieces), the fraction can rise to 50% or more. In quiet positions (e.g., blocked pawn structures), quiescence search may account for less than 5% of nodes because most captures are immediately pruned by SEE or delta pruning.

=== Common Implementation Pitfalls

*Pitfall 1: Not handling check evasion.* If quiescence search does not detect check, it will stand pat and evaluate a position where the king is attacked. The static evaluation will give a large negative score, but the side in check may have a simple king move or capture to escape. Always generate all legal moves when in check.

*Pitfall 2: Infinite recursion.* Captures that lead to the same position (e.g., two rooks repeatedly capturing each other on the same square) could cause infinite recursion. SEE pruning prevents most such cases, but a maximum depth limit is still necessary.

*Pitfall 3: Over-pruning with SEE.* SEE is a static approximation that does not account for pins, discovered attacks, or positional factors. Aggressively pruning all SEE < 0 captures can miss tactical sequences where a "losing" capture enables a winning fork or discovered attack. In practice, Stockfish still searches some SEE < 0 captures (those with very high MVV-LVA scores) for safety.

*Pitfall 4: Stalemate in quiescence.* A position with no legal moves (but not in check) is stalemate, which is a draw. The quiescence search must detect this and return a draw score (typically 0) rather than the static evaluation.

*Pitfall 5: Ignoring promotions.* A pawn capture that promotes to a queen is fundamentally different from a simple capture. The quiescence search must handle promotions correctly, including the option to underpromote (to a knight for a fork, for instance).

=== Summary

Quiescence search is the essential complement to fixed-depth alpha-beta search. Without it, engines are tactically blind, making catastrophic blunders at the horizon. With it, engines can evaluate positions accurately, trusting that all immediate captures have been resolved before the static evaluation is applied.

The key components of a production-quality quiescence search are:
1. Standing pat with cutoff (prevent explosion)
2. SEE pruning (eliminate losing captures)
3. Delta pruning (eliminate captures that cannot reach alpha)
4. Check evasion (search all moves when in check)
5. MVV-LVA / SEE-based move ordering (maximize cutoffs)
6. Depth limit (prevent runaway recursion)
7. PV collection (for accurate principal variation reporting)

With these components, quiescence search transforms a tactically-blind static evaluator into a position that can navigate even the most complex tactical sequences.

=== Exercises for the Reader

1. Implement quiescence search for a simple chess engine without SEE pruning. Measure the node count on a set of tactical test positions. Then add SEE pruning and compare the node counts.

2. The horizon effect can be demonstrated with a simple position: White's queen is attacked, and White can delay capture with a series of checks. Set up such a position and verify that your engine without quiescence blunders, while your engine with quiescence plays correctly.

3. Experiment with different delta margins (0, 100, 200, 300, 500). How does the node count and tactical accuracy change?

4. Implement MVV-LVA ordering and compare it with SEE-based ordering for captures in quiescence. Which produces fewer nodes while maintaining the same accuracy?

5. Measure the percentage of nodes spent in quiescence search across a diverse set of positions (opening, middlegame, endgame). How does the percentage correlate with position type?
