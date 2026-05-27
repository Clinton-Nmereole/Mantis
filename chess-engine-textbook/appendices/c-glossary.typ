== Appendix C: Glossary of Terms

This glossary defines every technical term used in this book.

*Alpha*: The lower bound in alpha-beta search. The best score the maximizing player can achieve so far. If a move scores below alpha, it is not worth pursuing.

*Alpha-Beta Pruning*: A search algorithm that eliminates branches provably irrelevant to the final decision. Reduces the effective branching factor from b to approximately sqrt(b).

*Aspiration Window*: A narrow search window (alpha, beta) centered on the previous iteration's score. Causes more cutoffs, speeding up the search. If the window fails (score outside), re-search with a wider window.

*Beta*: The upper bound in alpha-beta search. The best score the minimizing player (opponent) can achieve from an alternative line.

*Beta Cutoff*: When a move scores at or above beta, indicating the opponent will not allow this line. The remaining moves at this node are pruned.

*Bitboard*: A 64-bit integer where each bit represents one square of the chess board. Fundamental data structure for modern engines.

*Branching Factor*: The average number of legal moves per position. In chess, approximately 35. Alpha-beta reduces this to about sqrt(35) ≈ 6.

*Capture*: A move that removes an enemy piece.

*Castling*: A special move involving the king and a rook. Kingside castling (O-O) moves the king two squares toward the h-file. Queenside castling (O-O-O) moves toward the a-file.

*Centipawn (cp)*: 1/100 of a pawn. The standard unit of evaluation. +100 cp = one pawn advantage.

*Check*: A position where the king is attacked. The player must resolve check on the next move.

*Checkmate*: A position where the king is in check and has no legal escape. The game ends.

*Cut Node*: In alpha-beta, a node where a beta cutoff occurs. The first (or early) move proves the line is too good for the opponent to allow.

*Depth*: The number of half-moves (plies) into the future that the search explores. Higher depth = stronger play but exponentially more computation.

*Double Check*: A situation where two pieces simultaneously give check. The only legal response is to move the king.

*DTZ (Distance to Zeroing)*: In Syzygy tablebases, the number of half-moves until a capture or pawn move (a "zeroing move") that transitions to a simpler endgame.

*ELO Rating*: A measure of playing strength. 100 ELO difference = the stronger player scores ~64%. Named after Arpad Elo.

*En Passant*: A special pawn capture available immediately after an opponent's double pawn push. The capturing pawn moves to the square the opponent's pawn passed through.

*Endgame*: The phase of the game with few pieces remaining. Characterized by king activity and passed pawn importance.

*Evaluation Function*: A heuristic that estimates the value of a position from the perspective of the side to move. Returns a score in centipawns.

*Fail-High*: When a search returns a score >= beta, indicating the move is "too good" for the opponent to allow. Requires a re-search with wider bounds.

*Fail-Low*: When a search returns a score <= alpha, indicating no move is good enough to improve on the current best line.

*FEN (Forsyth-Edwards Notation)*: A standard string representation of a chess position. Example: `rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1`.

*Fifty-Move Rule*: A game is drawn if 50 consecutive moves are made without a capture or pawn push. Relevant for tablebase probing.

*Futility Pruning*: Skipping moves near the leaves of the search tree when the static evaluation is so poor that no plausible move could raise it above alpha.

*Hash/TT Move*: The best move stored in the transposition table. The single most important move ordering heuristic.

*History Heuristic*: A move ordering technique that tracks, per (piece, target square), how often a move caused a beta cutoff. Moves with high history scores are searched earlier.

*Horizon Effect*: Search artifacts caused by fixed depth. The engine cannot see beyond the search horizon and may make moves that delay an unavoidable loss just beyond the horizon.

*Incremental Evaluation*: Updating the evaluation score by only the changes caused by a move, rather than recomputing from scratch. Essential for performance.

*Iterative Deepening*: Searching to depth 1, then 2, 3, ..., rather than directly to the target depth. The results of shallower searches inform move ordering for deeper searches.

*Killer Move*: A quiet (non-capture) move that caused a beta cutoff at a sibling node. Tried early in the current node.

*Late Move Reductions (LMR)*: Searching later moves (in move ordering) to reduced depth, on the heuristic that they are less likely to be best.

*Lazy SMP*: A parallel search algorithm where all threads independently search the full tree, sharing only the transposition table. The dominant technique in modern engines.

*Magic Bitboards*: A technique for fast sliding piece attack generation using precomputed "magic numbers" that map blocker configurations to compact table indices.

*Middlegame*: The phase between the opening and endgame, characterized by many pieces and complex tactics.

*Minimax*: The fundamental game-theoretic algorithm for two-player zero-sum games. Assumes perfect play from both sides.

*Move Ordering*: Sorting moves so that the best ones are searched first. Good move ordering is critical for alpha-beta efficiency.

*Negamax*: A simplified version of minimax that uses score negation to handle alternating perspectives. More elegant to implement.

*NNUE (Efficiently Updatable Neural Network)*: A neural network architecture for chess evaluation that runs efficiently on CPUs. Revolutionized engine strength in the 2020s.

*Null-Move Pruning*: Skipping a turn (making a "null move") to test if the position is so good that even giving the opponent two moves in a row would not make it bad. If so, prune.

*Null-Window Search*: A search with alpha and beta differing by 1 (zero-width window). Used to cheaply test whether a move improves alpha.

*Opening*: The initial phase of the game, characterized by development and king safety.

*Passed Pawn*: A pawn with no enemy pawns blocking its path to promotion. Highly valuable in the endgame.

*Perft (Performance Test)*: A debugging tool that counts legal move sequences to a given depth without evaluation. Used to verify move generation correctness.

*PEXT (Parallel Bits Extract)*: A hardware instruction (BMI2 on x86) that extracts bits specified by a mask. Used as an alternative to magic bitboards and is faster on supporting hardware.

*Ply*: One half-move. Depth is measured in plies.

*Ponder*: Searching during the opponent's thinking time, anticipating their likely response.

*Principal Variation (PV)*: The best sequence of moves found so far by the search.

*Principal Variation Search (PVS)*: An alpha-beta enhancement that uses null-window searches for non-first moves and re-searches only when the null-window indicates a better move.

*Promotion*: When a pawn reaches the 8th rank, it must be replaced by a queen, rook, bishop, or knight.

*Pruning*: Reducing the search tree by eliminating moves or nodes that are unlikely to affect the result.

*Pseudo-Legal Move*: A move that follows the piece movement rules but does not account for leaving the king in check.

*Quiescence Search*: A search at depth 0 that considers only captures (and sometimes checks) to ensure the static evaluation is applied to a "quiet" position.

*Repetition Draw*: If the same position occurs three times (with the same side to move and same castling/en passant rights), the game is drawn.

*Retrograde Analysis*: Solving endgames by working backward from terminal positions (checkmate, stalemate) to all reachable positions. Used to generate tablebases.

*SEE (Static Exchange Evaluation)*: A simplified search that evaluates a sequence of captures on a single square to determine who gains material.

*Stalemate*: A position where the side to move is not in check but has no legal moves. The game is drawn.

*Tablebase*: A database of perfect play for endgames with a limited number of pieces. Syzygy is the standard format.

*Tapered Evaluation*: Interpolating between middlegame and endgame evaluation values based on remaining material. Allows correct evaluation across all game phases.

*Transposition*: Reaching the same position via different move sequences. The transposition table (TT) caches search results indexed by Zobrist hash.

*UCI (Universal Chess Interface)*: The standard protocol for communication between chess engines and GUIs. Text-based, over stdin/stdout.

*WDL (Win/Draw/Loss)*: The outcome stored in Syzygy tablebases. Used during search to prune or evaluate.

*Zobrist Hashing*: A technique for computing a unique hash of a chess position using XOR of precomputed random numbers for each (piece, square) combination.

*Zero-Window Search*: Synonym for null-window search.
