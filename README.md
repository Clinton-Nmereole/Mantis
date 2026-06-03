# Mantis Chess Engine

A **tournament-ready chess engine** written in Odin with NNUE evaluation and world-class search optimizations.

**Estimated Strength**: 2400-2650 Elo

## Features

### Evaluation
- ✅ **NNUE** (Efficiently Updatable Neural Network)
- ✅ HalfKAv2 architecture
- ✅ Incremental updates
- ✅ Compatible with standard NNUE files

### Search
- ✅ **Negamax** with Alpha-Beta Pruning
- ✅ **Principal Variation Search** (PVS)
- ✅ **Iterative Deepening**
- ✅ **Quiescence Search**
- ✅ **Aspiration Windows**
- ✅ **Check Extensions**

### Pruning & Reductions
- ✅ **Transposition Table** (configurable 1-1024 MB)
- ✅ **Late Move Reductions** (Logarithmic formula)
- ✅ **Null Move Pruning** (R=2)

### Move Ordering
1. Hash Move (from TT)
2. MVV-LVA Captures
3. Killer Heuristic (2 per ply)
4. History Heuristic (piece-to-square)
5. Other moves

### Time Management
- ✅ Smart time allocation
- ✅ Handles all UCI time controls
- ✅ Periodic time checks
- ✅ Iterative deepening control

### UCI Protocol
- ✅ Full UCI support
- ✅ Configurable Hash size
- ✅ Custom NNUE network loading

## Build

### Quick Build (Optimized for Speed)
```bash
./build_optimized.sh
```

### Manual Build

**For maximum performance** (recommended):
```bash
odin build . -out:mantis -o:speed -microarch:native
```

**For portability** (works on any x86-64 CPU):
```bash
odin build . -out:mantis -o:speed
```

**Debug build** (not recommended for play):
```bash
odin build . -out:mantis
```

> **⚠️ Important**: Always use `-o:speed` for competitive play! Debug builds are 10-30x slower.

## Usage

### Interactive Mode
```bash
./mantis
```

### UCI Commands
```
uci
setoption name Hash value 128
setoption name EvalFile value nn-c0ae49f08b40.nnue
position startpos
go depth 10
quit
```

### With Time Control
```
position startpos moves e2e4 e7e5
go wtime 60000 btime 60000 winc 1000 binc 1000
```

## UCI Options

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| Hash | spin | 64 | 1-1024 | Transposition table size (MB) |
| EvalFile | string | nn-c0ae49f08b40.nnue | - | NNUE network file path |
| OwnBook | check | true | - | Enable internal opening book |
| BookFile | string | 2moves_v1.epd | - | Opening book EPD file |
| Move Overhead | spin | 10 | 0-5000 | Network latency compensation (ms) |
| MultiPV | spin | 1 | 1-500 | Number of principal variations |
| Ponder | check | false | - | Enable pondering (background thinking) |
| SyzygyPath | string | empty | - | Syzygy tablebase directory |
| SyzygyProbeLimit | spin | 7 | 0-7 | Maximum tablebase pieces to probe |
| Threads | spin | 1 | 1-512 | Number of search threads |
| Contempt | spin | 12 | -100-100 | Root eval bias against draws |
| SearchStats | check | false | - | Print detailed search counters |
| RootDebugTrace | check | false | - | Print root search diagnostics |
| StagedMovePicker | check | false | - | Enable staged move picker experiment |

### UCI Tuning Options

These options expose bounded search constants for SPSA, cutechess, and local
self-play tuning without recompiling:

| Option | Default | Range |
|--------|---------|-------|
| AspirationWindow | 35 | 5-200 |
| NmpMinDepth | 3 | 2-6 |
| NmpReductionBase | 2 | 0-4 |
| NmpReductionDiv | 6 | 3-10 |
| RfpMargin | 25 | 10-150 |
| RfpDepth | 8 | 5-10 |
| ProbcutDepth | 5 | 3-8 |
| ProbcutMargin | 40 | 0-300 |
| ProbcutReduce | 4 | 1-6 |
| IirMinDepth | 4 | 3-8 |
| SeDepth | 8 | 5-12 |
| SeMargin | 2 | 0-8 |
| SeReducedDiv | 2 | 1-4 |
| LmrMinDepth | 3 | 2-5 |
| LmrImprovingAdj | -1 | -4 to 4 |
| LmrHistoryGoodAdj | -1 | -4 to 4 |
| LmrHistoryBadAdj | 1 | -4 to 4 |
| LmrHistoryGoodThresh | 2000 | 0-10000 |
| LmrHistoryBadThresh | -2000 | -10000 to 0 |
| FutilityMargin | 65 | 30-400 |
| FutilityMaxDepth | 3 | 1-6 |
| LmpBase | 2 | 1-4 |
| LmpDiv | 2 | 1-4 |
| LmpMaxDepth | 8 | 3-12 |
| RazorMargin | 80 | 0-300 |
| RazorMaxDepth | 3 | 1-5 |
| DeltaPruningMargin | 250 | 0-1200 |
| SeePruneThreshold | -50 | -300 to 0 |
| ContinuationScoreDiv | 12 | 1-64 |

For dependency-free paired SPSA tuning, build a current engine binary and run:

```bash
python3 nevergrad_tuner.py --engine ./mantis --optimizer spsa \
  --budget 80 --games 20 --movetime 200 --concurrency 4
```

## Testing

### Fixed Depth Search
```
position startpos
go depth 10
```

### Time-Controlled Search
```
position startpos
go wtime 60000 btime 60000
```

### Perft (Move Generation Verification)
```
perft 5
```

## Compatible GUIs

- **Cute Chess CLI** - Automated testing
- **Arena Chess** - GUI play
- Any UCI-compatible interface

## Performance

- **Node Reduction**: 80-90% vs naive alpha-beta
- **NPS**: 900k+ nodes per second (unoptimized build)
- **Effective Depth**: 2-3 ply deeper per second vs basic search

## Architecture

```
Mantis/
├── board/          # Board representation, move making
├── constants/      # Chess constants
├── eval/           # Evaluation (PST, piece values)
├── moves/          # Move generation
├── nnue/           # NNUE evaluation
├── search/         # Search algorithms
│   ├── search.odin      # Negamax, PVS, extensions
│   ├── sort.odin        # Move ordering
│   ├── tt.odin          # Transposition table
│   └── time_manager.odin # Time management
├── uci/            # UCI protocol
├── utils/          # Utility functions
└── zobrist/        # Zobrist hashing
```

## Development Roadmap

### Completed ✅
- NNUE Evaluation
- Full search optimizations (TT, LMR, NMP)
- Advanced move ordering (Hash, MVV-LVA, Killers, History)
- Time management
- UCI protocol

### Future Enhancements
- Singular Extensions (+40-60 Elo)
- Multi-PV support
- Lazy SMP (parallel search, +150-200 Elo)
- Syzygy Tablebases
- Large-scale automated tuning runs

## Documentation

- `DEVELOPMENT_SUMMARY.md` - Complete development history
- `NEXT_STEPS.md` - Future optimization roadmap
- `FINAL_SUMMARY.md` - Comprehensive feature summary


## Author 

Built with Odin
