== Putting It All Together

This chapter is the capstone of the textbook. We have journeyed through every component of a chess engine—board representation, move generation, search, evaluation, transposition tables, move ordering, NNUE, parallel search, testing, and optimization—each in isolation. Now we step back and see how these pieces connect into a coherent, working whole. We will trace the complete engine pipeline from the moment it receives a UCI command to the moment it returns a move. Then we will discuss how to design and build a new engine from scratch, using everything you have learned.

=== The Complete Engine Pipeline

When your engine receives the UCI command `go wtime 60000 btime 58000 movestogo 30`, here is what happens, from start to finish:

```text
Time (ms)   Component                Action
──────────  ───────────────────────  ──────────────────────────────────
0.0        UCI Parser               Parse "go" parameters, set time limits
0.1        Time Manager             Calculate time budget (e.g., 2.5s for this move)
0.2        Position Setup           Position already set by "position" command
0.3        ┌─ Iterative Deepening ──────────────────────────────────────┐
0.5        │ Depth 1:                                                │
           │   generate_moves()        Generate all pseudolegal moves    │
           │   for each move:                                         │
           │     make_move()            Update position state           │
           │     evaluate()             Static evaluation (NNUE/classical)│
           │     unmake_move()          Restore position state          │
           │   Best move stored in TT                                │
           │                                                          │
1.0        │ Depth 2:                                                │
           │   PVS search with null-window, LMR, TT lookups          │
           │   ~400 nodes visited                                      │
           │                                                          │
5.0        │ Depth 5:                                                │
           │   Killers, countermoves, history heuristics active       │
           │   ~50,000 nodes visited                                   │
           │                                                          │
50.0       │ Depth 8:                                                │
           │   Singular extensions, ProbCut active                    │
           │   ~2 million nodes visited                                │
           │                                                          │
250.0      │ Depth 10:                                               │
           │   Full search enhancements in effect                     │
           │   ~20 million nodes visited                               │
           │                                                          │
1,200.0    │ Depth 12:                                               │
           │   Time check: budget used? → Yes, stop iterating          │
           └──────────────────────────────────────────────────────────┘
1,200.1    Root Decision           Select best move from iterative deepening:
                                   → Highest-scored move from last complete depth
                                   → OR: TT move from incomplete depth
1,200.2    UCI Output              "bestmove e2e4 ponder e7e5"
1,200.3    Cleanup                 Store TT, prepare for next position
```

This pipeline runs every time the engine needs to move. Every component we have discussed in this book plays a role:

1. **Board Representation (Ch. 3)**: The `Position` struct holds all state. `make_move` and `unmake_move` update it.
2. **Move Generation (Ch. 4)**: `generate_moves` produces the candidate moves. Magic bitboards (or PEXT) compute slider attacks.
3. **Search (Ch. 5-8, 14)**: The iterative deepening loop calls PVS which calls null-window search which calls quiescence search. Alpha-beta bounds prune irrelevant branches.
4. **Move Ordering (Ch. 9)**: Before search, moves are scored using TT move, captures (MVV-LVA), killers, countermoves, and history heuristics.
5. **Transposition Table (Ch. 10)**: Before searching any position, probe the TT. If found with sufficient depth, used stored score. After searching, store the result.
6. **Evaluation (Ch. 11-13)**: At leaves (and during quiescence search), evaluate the position. NNUE inference or classical evaluation.
7. **Time Management**: The iterative deepening loop checks elapsed time after each depth and stops when the budget is exhausted (or a mate is found).
8. **UCI Protocol (Ch. 16)**: The external interface—parses commands, formats output.

==== Data Flow Diagram

```text
                         ┌──────────────┐
                         │ UCI "go ..." │
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │ Time Manager │ ──→ time_budget, max_depth
                         └──────┬───────┘
                                │
                    ┌───────────▼───────────┐
                    │ Iterative Deepening   │
                    │ for depth = 1..max:   │
                    └───────────┬───────────┘
                                │
              ┌─────────────────▼─────────────────┐
              │         Root Search (PVS)          │
              │                                    │
              │  ┌──────────────────────────────┐ │
              │  │   for each move in movelist:  │ │
              │  │     make_move(pos, move)      │ │
              │  │     ┌──────────────────────┐  │ │
              │  │     │   TT probe            │  │ │
              │  │     │   if TT hit & depth   │  │ │
              │  │     │   ok: return score    │  │ │
              │  │     └──────────────────────┘  │ │
              │  │     ┌──────────────────────┐  │ │
              │  │     │   Move Generation     │  │ │
              │  │     │   Move Ordering       │  │ │
              │  │     └──────────────────────┘  │ │
              │  │     ┌──────────────────────┐  │ │
              │  │     │   Recursive PVS call  │──┼─┼──→ (repeat at depth-1)
              │  │     │   (with null-window,  │  │ │
              │  │     │    LMR, extensions)   │  │ │
              │  │     └──────────────────────┘  │ │
              │  │     ┌──────────────────────┐  │ │
              │  │     │   QSearch (if depth   │  │ │
              │  │     │   reaches 0)          │  │ │
              │  │     │     evaluate(pos)     │  │ │
              │  │     │     (NNUE or classical)│  │ │
              │  │     └──────────────────────┘  │ │
              │  │     ┌──────────────────────┐  │ │
              │  │     │   TT store            │  │ │
              │  │     │   Killer/History upd  │  │ │
              │  │     └──────────────────────┘  │ │
              │  │     unmake_move(pos)          │ │
              │  │     update alpha/beta/best    │ │
              │  └──────────────────────────────┘ │
              └──────────────────────────────────┘
                                │
                         ┌──────▼───────┐
                         │ "bestmove M" │
                         └──────────────┘
```

=== Designing an Engine from Scratch

If this textbook has inspired you to write your own engine, here is a practical roadmap—informed by the experiences of successful engine developers.

==== Step 0: Choose Your Language and Philosophy

Before writing a single line, decide:

- **Language**: C (maximum performance, maximum effort), C++ (maximum performance, templates), Rust (safety, modern tooling), Zig (comptime, explicit control), Odin (clean syntax, joy of programming). All five are viable. Your choice affects not just performance but development speed and code maintainability.

- **Architecture Philosophy**: Will you optimize for strength, readability, or experimentation? A readable engine can become a strong engine through iteration; an unreadable engine is stuck at its current strength.

- **Scope**: Decide what you *won't* implement (at least initially). UCI only? No tablebase support? Single-threaded only? Every feature you postpone accelerates development of the core.

==== Step 1: The Minimum Viable Engine

Your first milestone: an engine that can play a legal game of chess. This requires:

1. **Board representation**: The simplest viable option is a mailbox (8×8 array) with piece lists. Bitboards are better but more complex. Start simple.

2. **Move generation**: Generate all pseudolegal moves using simple piece patterns. Test with perft—this is non-negotiable. If your perft numbers don't match, nothing else will work.

3. **Make/Unmake**: Correctly update the position when a move is made and unmade. This is surprisingly error-prone; bugs here manifest as subtle evaluation errors.

4. **Evaluation**: Start with material counting only (piece values: P=100, N=320, B=330, R=500, Q=900). Add a piece-square table for basic positional play.

5. **Search**: Minimax to depth 4 with alpha-beta pruning. No enhancements needed. This will play at approximately 1,200-1,400 Elo—weak but functional.

6. **UCI Protocol**: Implement the minimum set: `uci`, `isready`, `position`, `go`, `stop`, `quit`. Use standard input/output. This enables testing with cutechess-cli.

Congratulations—you now have a working chess engine. Compile it, run perft, fix bugs, and watch it play its first game against itself.

```bash
# The first game of a new engine:
./myengine << EOF
uci
isready
position startpos
go depth 4
EOF
# Expected: a legal move, probably not terrible
```

==== Step 2: Strengthen the Core (1,400 → 2,200 Elo)

With a working baseline, add the standard enhancements:

1. **Quiescence Search** (Chapter 8): Search captures beyond the nominal depth to prevent the horizon effect from missing recaptures.
2. **Move Ordering** (Chapter 9): MVV-LVA for captures, killer moves, history heuristic. Good move ordering doubles the effective search depth.
3. **Transposition Table** (Chapter 10): Store evaluated positions and reuse. This is the single most impactful enhancement after alpha-beta itself.
4. **Iterative Deepening**: Search depth 1, 2, 3, ... with time management. Essential for competitive play.
5. **Bitboard Move Generation** (Chapters 3-4): If you started with mailbox, now is the time to switch. The performance gain is 2-3x.
6. **PVS + Null-Window Search** (Chapter 6): More efficient search with minimal implementation complexity.
7. **Late Move Reductions** (Chapter 7): Search later moves less deeply. This is complex to tune but provides 50-100 Elo.
8. **Improved Evaluation** (Chapters 11-12): Add pawn structure, king safety, mobility, passed pawns, piece-square tables tuned to game data.

At this stage, your engine should approach 2,200-2,400 Elo—stronger than most club players.

==== Step 3: Reach Competitiveness (2,200 → 3,000 Elo)

1. **NNUE Evaluation** (Chapter 13): Train or adopt a small NNUE network. This alone can add 100-200 Elo.
2. **Search Extensions** (Chapter 6): Singular extensions, check extensions, recapture extensions.
3. **Advanced Move Ordering** (Chapter 9): Counter-move history, follow-up history, capture history.
4. **Parallel Search** (Chapter 14): Lazy SMP for multi-threading. Near-linear speedup to 4-8 cores.
5. **Automated Testing** (Chapter 18): Set up an SPRT pipeline with cutechess-cli and an opening book. Test every change.
6. **Performance Profiling** (Chapter 19): Profile, optimize, repeat. Target 1M+ NPS single-threaded.

At this stage, you are competing with serious engines. Your engine may reach 2,800-3,000 Elo.

==== Step 4: Polish and Climb (3,000 → 3,400+ Elo)

1. **Larger/Better NNUE networks**: Train on more data, experiment with architectures.
2. **Syzygy Tablebases** (Chapter 15): Perfect play in 7-piece or fewer positions.
3. **Fine-Tuned Search**: Exhaustive testing of reduction formulas, extension triggers, pruning margins. Each parameter optimized for 1-3 Elo.
4. **Distributed Testing**: Scale testing beyond your own hardware.

At this level, you are in the top 20-30 engines in the world. Further progress requires thousands of hours of experimentation and testing.

=== The Development Loop

The engine development cycle is:

```text
Code → Test → Analyze → Refine → Repeat
```

Each iteration should be rapid—ideally, less than 24 hours from idea to SPRT result. This requires:

- Fast compilation (use incremental builds, ccache).
- Automated testing (cutechess-cli script that runs with one command).
- Disciplined version control (every change is a git commit with a clear description).
- Patience (most ideas fail; the ones that succeed make it all worthwhile).

=== Preparing for Tournament Play

When your engine is ready to compete:

1. **Opening book**: Generate a small, solid book from high-quality games. Alternatively, use an existing polyglot book. An engine without a book is at a significant disadvantage (it will play suboptimal openings from game one).

2. **Time management calibration**: Test your time management at tournament time controls. An engine that flags (runs out of time) loses instantly.

3. **Ponder support**: If allowed, implement ponder (thinking during the opponent's turn). This can provide a 20-40 Elo boost in tournament play.

4. **Resilience**: Test for crashes, infinite loops, and pathological behavior. An engine that crashes in 0.1% of games loses those games—and tournaments are often decided by a half-point.

5. **Personality**: Decide whether your engine has "contempt" (preferring to play for a win rather than a draw against weaker opponents) or is purely objective. Contempt can increase the engine's score against a field of weaker opponents.

=== Final Thoughts

Building a chess engine is one of the most rewarding projects in computer science. It combines algorithms, data structures, machine learning, systems programming, and a touch of chess artistry. The journey from "it crashes on en passant" to "it beat a grandmaster" is long, but each milestone—the first working perft, the first game, the first tournament win—is deeply satisfying.

This textbook has given you the tools. The rest is up to you.

The chess engine community is open, collaborative, and welcomes newcomers. Share your code, ask questions, contribute to other engines, and help the next generation of developers. Chess programming is not a zero-sum game: we all get stronger when knowledge is shared.

Now go build something amazing.
