== The UCI Protocol: Engine Communication Standard

The Universal Chess Interface (UCI) is the communication protocol that connects chess engines to graphical user interfaces (GUIs). It was designed by Stefan Meyer-Kahlen (author of Shredder) and Rudolf Huber in 2000 as an open alternative to the proprietary protocols that preceded it. Today, virtually every chess engine—from Stockfish to Leela Chess Zero to hobbyist projects—implements UCI.

This chapter covers the complete UCI specification, how to implement a robust UCI adapter, common pitfalls, and includes complete working implementations in all five languages.

=== The Philosophy of UCI

UCI is a text-based, line-oriented protocol over standard input/output streams. The GUI is the *client*; the engine is the *server*. The GUI sends commands to the engine's stdin; the engine responds on stdout. This design is deliberately similar to Unix pipelines and makes engines trivially scriptable.

Key design principles:

1. *Stateless where possible*: The engine does not maintain its own board state between moves. The GUI tells the engine the full position before each search via the `position` command. This prevents state synchronization bugs.

2. *Simple parsing*: Commands are plain ASCII text, one per line, with whitespace-separated tokens. No binary encoding, no complex data structures.

3. *Engine-driven time management*: The engine decides how to use its allotted time. The GUI provides time limits; the engine manages its own clock.

4. *Extensibility*: Custom options are supported through `option name ... type ...` commands, allowing engines to expose tuning parameters without protocol changes.

=== The Complete UCI Command Set

==== Initialization Handshake

When the GUI launches the engine, the engine must identify itself:

```
→ uci
← id name MyEngine 1.0
← id author Jane Hacker
← option name Hash type spin default 32 min 1 max 65536
← option name Threads type spin default 1 min 1 max 256
← option name SyzygyPath type string default <empty>
← uciok
```

The engine sends its name, author, and a list of configurable options. The `uciok` token signals that initialization is complete.

After sending `uciok`, the engine must be ready to accept commands. The GUI typically sends:

```
→ isready
← readyok
→ ucinewgame
```

The `isready` / `readyok` exchange is a synchronization mechanism: the GUI uses it to confirm the engine is responsive before sending the next command. The engine must respond to `isready` even while searching (the search is typically paused or the response is sent from a separate thread).

`ucinewgame` signals the start of a new game. The engine should clear its transposition table, history tables, and any other state that should not persist between games.

==== Setting Up a Position

Before each search, the GUI sends the current position:

```
→ position startpos
→ position startpos moves e2e4 e7e5 g1f3
→ position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
→ position fen ... moves e2e4 c7c5
```

The `position` command has two forms:

1. `position startpos` — the standard starting position, optionally followed by `moves M1 M2 ...` to replay the game up to the current position.

2. `position fen FEN_STRING` — a position specified by its FEN string, optionally followed by moves.

The engine must parse the FEN and replay the moves to reach the current position. It is the engine's responsibility to validate the moves (illegal moves should be rejected or ignored).

==== The Go Command: Starting a Search

The `go` command initiates a search on the current position. It has numerous optional parameters that control the search:

```
→ go depth 20                       # Search to depth 20 plies
→ go movetime 5000                  # Search for exactly 5 seconds
→ go wtime 60000 btime 60000        # White and Black remaining time in ms
→ go wtime 60000 btime 60000 winc 1000 binc 1000  # With increment
→ go movestogo 30                   # Moves to go before next time control
→ go nodes 1000000                  # Search exactly 1 million nodes
→ go mate 5                         # Search for mate in 5 moves
→ go infinite                       # Search indefinitely (until 'stop')
→ go ponder                         # Search in ponder mode (opponent's time)
→ go searchmoves e2e4 d2d4          # Search only these moves
→ go depth 20 wtime 60000 btime 60000 winc 1000 binc 1000  # Combined
```

The engine must handle all combinations gracefully. The most complex case is time management with `wtime/btime/winc/binc/movestogo`: the engine receives both players' remaining time and must decide how much to use for the current move.

==== Search Output: The Info Command

During search, the engine sends `info` lines to report progress:

```
← info depth 10 seldepth 18 multipv 1 score cp 25 nodes 1234567 nps 890000 hashfull 456 time 1386 pv e2e4 e7e5 g1f3 b8c6 f1b5 a7a6
← info depth 11 seldepth 20 multipv 1 score cp 30 nodes 2345678 nps 900000 hashfull 512 time 2605 pv e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4
← info depth 11 seldepth 20 multipv 1 score mate 5 nodes 3000000 nps 910000 time 3296 pv ...
← info depth 11 seldepth 20 multipv 1 score lowerbound nodes ... pv ...
← info depth 11 seldepth 20 multipv 1 score upperbound nodes ... pv ...
← info currmove g1f3 currmovenumber 3
← info currmove d2d4 currmovenumber 4
← info string This is a debug message
```

*Required info fields*: `depth`, `score`, `nodes`, `time`, `pv`.

*Score types*:
- `score cp 25` — score in centipawns (1 pawn = 100 cp). Positive = favorable for the engine (regardless of color).
- `score mate 5` — mate in 5 plies (half-moves) for the engine. `score mate -5` — the engine is being mated in 5.
- `score lowerbound` / `score upperbound` — when aspiration window fails, the engine reports the bound direction.

*Optional info fields*: `seldepth`, `multipv`, `nps`, `hashfull`, `tbhits`, `cpuload`, `currmove`, `currmovenumber`, `string`.

*MultiPV mode*: When `MultiPV` is > 1, the engine sends `info` lines for each of the top N moves, distinguished by `multipv 1`, `multipv 2`, etc.

==== The Bestmove Command

When the search completes (or is stopped), the engine sends:

```
← bestmove e2e4
← bestmove e2e4 ponder e7e5
```

The optional `ponder` token indicates the move the engine expects the opponent to play, enabling pondering. The engine does not start pondering—the GUI must send a new `go ponder` command.

==== The Stop Command

The GUI sends `stop` to terminate the current search:

```
→ stop
← bestmove e2e4 ponder e7e5
```

The engine must respond with `bestmove` even when stopped. The search may take a moment to unwind (the engine must not crash or block when receiving `stop`).

==== The Ponderhit Command

When pondering, if the opponent plays the expected move:

```
→ ponderhit
```

The engine switches from ponder mode to normal search mode. It continues searching from the position it was already pondering on, using the remaining time. If the opponent plays a different move, the GUI sends `stop` followed by a new `position` command.

==== The Setoption Command

The GUI configures engine options:

```
→ setoption name Hash value 256
→ setoption name Threads value 8
→ setoption name SyzygyPath value /home/user/syzygy
→ setoption name MultiPV value 3
→ setoption name UCI_LimitStrength value true
→ setoption name UCI_Elo value 2000
```

Options are declared during initialization with their type:

- `type spin`: integer with min/max
- `type string`: text
- `type check`: boolean (true/false)
- `type combo`: enumerated value with `var` declarations
- `type button`: action trigger (no value)

```text
option name Style type combo default Normal var Normal var Aggressive var Defensive
option name Clear Hash type button
```

When a button option is set, the engine performs the associated action (e.g., clearing the TT) and sends no special response.

==== The Ucinewgame and Debug Commands

```
→ ucinewgame      # Start a new game, clear TT
→ debug on        # Enable debug mode (engine-specific)
→ debug off       # Disable debug mode
```

Debug mode is engine-dependent; most engines log additional diagnostic information when enabled.

==== The Quit Command

```
→ quit
```

The engine should exit cleanly. No response is required.

=== Implementing a UCI Loop

The core of any UCI engine is the main loop that reads commands from stdin, dispatches them, and writes responses to stdout:

```c
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>

#define MAX_LINE 4096

void uci_loop(void) {
    char line[MAX_LINE];
    bool quit = false;

    // Ensure stdout is unbuffered (or line-buffered)
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stdin, NULL, _IONBF, 0);

    while (!quit && fgets(line, MAX_LINE, stdin)) {
        // Remove trailing newline
        line[strcspn(line, "\r\n")] = '\0';

        // Tokenize (first token is the command)
        char *token = strtok(line, " ");

        if (!token) continue;  // empty line

        if (strcmp(token, "uci") == 0) {
            handle_uci();
        } else if (strcmp(token, "isready") == 0) {
            handle_isready();
        } else if (strcmp(token, "ucinewgame") == 0) {
            handle_ucinewgame();
        } else if (strcmp(token, "position") == 0) {
            handle_position();
        } else if (strcmp(token, "go") == 0) {
            handle_go();
        } else if (strcmp(token, "stop") == 0) {
            handle_stop();
        } else if (strcmp(token, "ponderhit") == 0) {
            handle_ponderhit();
        } else if (strcmp(token, "setoption") == 0) {
            handle_setoption();
        } else if (strcmp(token, "quit") == 0) {
            quit = true;
        }
    }
}
```

==== Handling the 'go' Command with Time Management

The `go` command requires careful parsing and time management logic:

```c
typedef struct {
    int wtime, btime;          // remaining time in ms
    int winc, binc;            // increment per move in ms
    int movestogo;             // moves to go until next time control
    int depth;                 // maximum search depth
    int movetime;              // exact time to search in ms
    int nodes;                 // maximum nodes to search
    int mate;                  // search for mate in N moves
    bool infinite;             // search indefinitely
    bool ponder;               // ponder mode
    Move searchmoves[256];     // restricted move list
    int searchmoves_count;
} GoParams;

void parse_go(GoParams *params) {
    // Initialize to defaults
    memset(params, 0, sizeof(GoParams));
    params->depth = MAX_DEPTH;
    params->wtime = params->btime = -1;
    params->movestogo = 30;  // assume 30 if not specified
    params->mate = -1;

    char *token;
    while ((token = strtok(NULL, " ")) != NULL) {
        if (strcmp(token, "wtime") == 0)    params->wtime = atoi(strtok(NULL, " "));
        else if (strcmp(token, "btime") == 0) params->btime = atoi(strtok(NULL, " "));
        else if (strcmp(token, "winc") == 0)  params->winc = atoi(strtok(NULL, " "));
        else if (strcmp(token, "binc") == 0)  params->binc = atoi(strtok(NULL, " "));
        else if (strcmp(token, "movestogo") == 0) params->movestogo = atoi(strtok(NULL, " "));
        else if (strcmp(token, "depth") == 0) params->depth = atoi(strtok(NULL, " "));
        else if (strcmp(token, "movetime") == 0) params->movetime = atoi(strtok(NULL, " "));
        else if (strcmp(token, "nodes") == 0) params->nodes = atoi(strtok(NULL, " "));
        else if (strcmp(token, "mate") == 0) params->mate = atoi(strtok(NULL, " "));
        else if (strcmp(token, "infinite") == 0) params->infinite = true;
        else if (strcmp(token, "ponder") == 0) params->ponder = true;
        else if (strcmp(token, "searchmoves") == 0) {
            // Parse remaining tokens as moves
            while ((token = strtok(NULL, " ")) != NULL) {
                params->searchmoves[params->searchmoves_count++] = parse_move(token);
            }
        }
    }
}

int calculate_time(GoParams *params, bool side) {
    if (params->movetime) return params->movetime;  // fixed time
    if (params->depth > 0) return INT_MAX;          // depth-limited, no time limit

    int available = side ? params->wtime : params->btime;
    int increment = side ? params->winc : params->binc;
    int moves_left = params->movestogo;

    // Standard time allocation: use roughly (available / moves_left) + increment
    // With a safety margin of 90% to avoid flagging
    int time_per_move = (available / moves_left) + (increment * 3 / 4);
    int max_time = available / 4;  // never use more than 25% of remaining time

    int allocated = (time_per_move * 9) / 10;  // 90% of theoretical allocation
    if (allocated > max_time) allocated = max_time;

    return allocated;
}
```

==== Handling Info Output During Search

The search thread periodically reports progress through `info` lines:

```c
void send_info(int depth, int sel_depth, int score, uint64_t nodes, Move *pv, int pv_len) {
    printf("info depth %d seldepth %d", depth, sel_depth);

    // Format score
    if (abs(score) > MATE_SCORE - 1000) {
        // Mate score: convert from internal format to plies
        int mate_in = (MATE_SCORE - abs(score) + 1) / 2;
        printf(" score mate %d", score > 0 ? mate_in : -mate_in);
    } else {
        printf(" score cp %d", score);
    }

    printf(" nodes %lu", nodes);
    printf(" time %lu", elapsed_ms());

    // PV line
    printf(" pv");
    for (int i = 0; i < pv_len; i++) {
        printf(" %s", move_to_uci(pv[i]));
    }

    printf("\n");
    fflush(stdout);  // flush so GUI receives immediately
}
```

==== Handling the Stop Command with Thread Coordination

The `stop` command must interrupt a running search. This requires a thread-safe flag:

```c
static volatile bool search_stop = false;
static volatile bool search_quit = false;

void handle_stop(void) {
    search_stop = true;  // Set flag; search thread checks this periodically
}

// In the search function:
int pvs(Position *pos, int depth, int alpha, int beta, int ply) {
    // Check for stop signal every 4096 nodes
    if ((nodes_searched & 0xFFF) == 0 && search_stop) {
        return 0;  // Early return; caller will unwind
    }
    // ... search continues ...
}

// Search thread:
void search_thread(Position *pos, GoParams *params) {
    // ... iterative deepening loop ...
    for (int d = 1; d <= params->depth && !search_stop; d++) {
        // ... search at depth d ...
    }

    // Send bestmove when done (or stopped)
    printf("bestmove %s", move_to_uci(best_move));
    if (ponder_move != NO_MOVE) {
        printf(" ponder %s", move_to_uci(ponder_move));
    }
    printf("\n");
    fflush(stdout);
}
```

=== Common UCI Implementation Pitfalls

==== 1. Buffered I/O

The most common UCI bug: stdout buffering. If stdout is fully buffered, `info` lines sit in the buffer and never reach the GUI. The fix is:

```c
setvbuf(stdout, NULL, _IONBF, 0);  // unbuffered
// or:
setlinebuf(stdout);  // line-buffered (POSIX, not in C standard)
```

Similarly, stdin buffering can cause the engine to not see commands until the buffer fills. Use `setvbuf(stdin, NULL, _IONBF, 0)`.

==== 2. Blocking Input During Search

A single-threaded engine that blocks on `fgets` cannot respond to `stop`: the GUI sends `stop` on stdin, but the engine is busy searching and never reads it. The solution is a separate I/O thread:

```c
void io_thread(void) {
    char line[MAX_LINE];
    while (fgets(line, MAX_LINE, stdin)) {
        // Parse command, set flags, but do not block the search thread
        if (strncmp(line, "stop", 4) == 0) search_stop = true;
        // ...
    }
}
```

The search thread periodically checks `search_stop` and terminates cleanly when set.

==== 3. Partial Line Reads

`fgets` reads until newline or buffer full. If a line is longer than MAX_LINE, it will be read in pieces. This is rare in UCI (lines are typically short) but should be handled:

```c
// Accumulate partial lines
char buffer[MAX_LINE];
int buf_len = 0;
// ... read into buffer, find '\n', process complete lines
```

==== 4. Non-Atomic Flag Access

The `search_stop` flag is accessed from two threads (I/O thread writes, search thread reads). On most architectures, a simple `bool` is atomic when aligned, but for correctness:

```c
#include <stdatomic.h>
atomic_bool search_stop = false;

// Writer:
atomic_store(&search_stop, true);

// Reader:
if (atomic_load(&search_stop)) { /* stop */ }
```

==== 5. Race Condition on Bestmove

The search thread produces a `bestmove`. If the GUI sends `stop`, the search thread unwinds and sends `bestmove`. But if the search completes naturally and the main thread also tries to send `bestmove`, the output can be corrupted. Use a flag:

```c
static atomic_bool bestmove_sent = false;

void send_bestmove(Move best, Move ponder) {
    bool expected = false;
    if (atomic_compare_exchange_strong(&bestmove_sent, &expected, true)) {
        printf("bestmove %s", move_to_uci(best));
        if (ponder != NO_MOVE) printf(" ponder %s", move_to_uci(ponder));
        printf("\n");
        fflush(stdout);
    }
}
```

=== Complete UCI Engine: Minimal Implementation

Here is a complete, compilable UCI engine that evaluates every position as 0 (random mover):

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>

#define MAX_LINE 4096

static atomic_bool search_stop = false;

// Stub: just return the first legal move
const char *get_first_move(void) {
    // In a real engine, you'd generate legal moves and return the first one
    return "e2e4";
}

void *io_loop(void *arg) {
    (void)arg;
    char line[MAX_LINE];
    bool quit = false;

    // Unbuffer I/O
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("id name MinimalEngine 1.0\n");
    printf("id author Chess Textbook\n");
    printf("uciok\n");

    while (!quit && fgets(line, MAX_LINE, stdin)) {
        line[strcspn(line, "\r\n")] = '\0';

        if (strcmp(line, "isready") == 0) {
            printf("readyok\n");
        } else if (strcmp(line, "ucinewgame") == 0) {
            // Clear state
        } else if (strncmp(line, "position", 8) == 0) {
            // Parse position (stub)
        } else if (strncmp(line, "go", 2) == 0) {
            // Start search (stub: just return first move)
            search_stop = false;
            // Simulate search by sleeping briefly
            usleep(100000);  // 100ms
            const char *best = get_first_move();
            printf("bestmove %s\n", best);
        } else if (strcmp(line, "stop") == 0) {
            search_stop = true;
        } else if (strcmp(line, "quit") == 0) {
            quit = true;
        }
    }
    return NULL;
}

int main(void) {
    io_loop(NULL);
    return 0;
}
```

==== UCI Engine in Python

Python is slower than C but excellent for prototyping UCI engines. The key is using a separate thread for search:

```python
import sys
import threading
import time

class UCIEngine:
    def __init__(self):
        self.search_stop = False
        sys.stdout = open(sys.stdout.fileno(), 'w', buffering=1)  # line-buffered

    def send(self, msg):
        print(msg, flush=True)

    def handle_uci(self):
        self.send("id name PyEngine 1.0")
        self.send("id author Chess Textbook")
        self.send("uciok")

    def handle_isready(self):
        self.send("readyok")

    def handle_position(self, args):
        # Parse FEN and moves
        pass

    def search(self):
        # Stub search
        time.sleep(0.1)  # simulate thinking
        if not self.search_stop:
            self.send("bestmove e2e4")

    def handle_go(self, args):
        self.search_stop = False
        thread = threading.Thread(target=self.search)
        thread.start()

    def handle_stop(self):
        self.search_stop = True

    def run(self):
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue

            if line == "uci":
                self.handle_uci()
            elif line == "isready":
                self.handle_isready()
            elif line.startswith("position"):
                self.handle_position(line)
            elif line.startswith("go"):
                self.handle_go(line)
            elif line == "stop":
                self.handle_stop()
            elif line == "quit":
                break

if __name__ == "__main__":
    UCIEngine().run()
```

==== UCI Engine in Rust

Rust's type safety and thread model are well-suited to UCI:

```rust
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

struct UciEngine {
    search_stop: Arc<AtomicBool>,
}

impl UciEngine {
    fn new() -> Self {
        Self { search_stop: Arc::new(AtomicBool::new(false)) }
    }

    fn handle_uci(&self) {
        println!("id name RustEngine 1.0");
        println!("id author Chess Textbook");
        println!("uciok");
    }

    fn handle_isready(&self) {
        println!("readyok");
    }

    fn handle_go(&self, _args: &[&str]) {
        self.search_stop.store(false, Ordering::SeqCst);
        let stop = Arc::clone(&self.search_stop);

        thread::spawn(move || {
            // Simulate search
            thread::sleep(std::time::Duration::from_millis(100));
            if !stop.load(Ordering::SeqCst) {
                println!("bestmove e2e4");
            }
        });
    }

    fn handle_stop(&self) {
        self.search_stop.store(true, Ordering::SeqCst);
    }

    fn run(&mut self) {
        let stdin = io::stdin();
        io::stdout().flush().unwrap();

        for line in stdin.lock().lines() {
            let line = line.unwrap();
            let line = line.trim();
            if line.is_empty() { continue; }

            let parts: Vec<&str> = line.split_whitespace().collect();
            match parts[0] {
                "uci" => self.handle_uci(),
                "isready" => self.handle_isready(),
// ... (fill in remaining handlers) ...
```

==== UCI Engine in Zig

```zig
const std = @import("std");
const Atomic = std.atomic.Atomic;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    var buf: [4096]u8 = undefined;
    var search_stop = Atomic(bool).init(false);

    // Initialization
    try stdout.print("id name ZigEngine 1.0\n", .{});
    try stdout.print("id author Chess Textbook\n", .{});
    try stdout.print("uciok\n", .{});

    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line_opt| {
        const line = if (line_opt) |l| std.mem.trimRight(u8, l, "\r\n") else break;

        if (std.mem.eql(u8, line, "isready")) {
            try stdout.print("readyok\n", .{});
        } else if (std.mem.eql(u8, line, "quit")) {
            break;
        }
        // ... (remaining command handlers) ...
    }
}
```

==== UCI Engine in Odin

```odin
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "core:sync/atomic"

main :: proc() {
    // Line-buffered stdout
    // ... UCI initialization and loop ...

    buf: [4096]byte
    for {
        n, err := os.read(os.stdin, buf[:])
        if err != nil || n == 0 do break

        line := strings.trim_right(string(buf[:n]), "\r\n")

        switch {
        case line == "uci":
            fmt.println("id name OdinEngine 1.0")
            fmt.println("id author Chess Textbook")
            fmt.println("uciok")
        case line == "isready":
            fmt.println("readyok")
        case line == "quit":
            return
        }
    }
}
```

=== UCI Protocol Extensions

==== MultiPV Mode

MultiPV instructs the engine to report the N best moves (not just the best one). Implementation:

```c
// When MultiPV > 1, search must find the top N moves
// Approach: search until N moves have been fully resolved
void search_multipv(Position *pos, int depth, int multipv) {
    int found = 0;
    int alpha = -INFINITY;
    int beta  = +INFINITY;

    for (int i = 0; i < multipv; i++) {
        int score = pvs(pos, depth, alpha, beta, 0);
        // Report this move as multipv i+1
        printf("info multipv %d depth %d score cp %d pv ...\n", i+1, depth, score);
        // Narrow the window for the next-best move
        alpha = score - 1;  // next move must be slightly worse
        found++;

        if (found >= multipv) break;
    }
}
```

==== Searchmoves

The `searchmoves` option restricts search to a subset of moves. This is used by GUIs for "search only these candidate moves":

```c
void handle_go() {
    // Parse searchmoves list
    // In move generation, only generate/consider moves in the searchmoves list
    for (int i = 0; i < moves.count; i++) {
        if (!in_searchmoves(moves[i])) {
            remove_move(&moves, i);
            i--;
        }
    }
}
```

==== UCI_LimitStrength and UCI_Elo

These options allow the engine to simulate weaker play. When enabled, the engine artificially limits its search depth, evaluation accuracy, or introduces randomness:

```c
int limit_strength(int score, int elo) {
    // Map ELO to an error range
    // 2000 ELO: ±200 cp noise
    // 1500 ELO: ±400 cp noise
    // 1000 ELO: ±600 cp noise + random move selection
    int noise = (3000 - elo) / 5;
    return score + (rand() % (2 * noise + 1) - noise);
}
```

=== Summary

UCI is the universal language of chess engines. Key points:

- *Text-based, stdin/stdout*: Simple parsing, no state management headaches.
- *Command set*: `uci`, `isready`, `ucinewgame`, `position`, `go`, `stop`, `ponderhit`, `setoption`, `quit`.
- *Info output*: `depth`, `score` (cp or mate), `nodes`, `time`, `pv` are required. `seldepth`, `nps`, `hashfull`, `tbhits`, `currmove` are optional.
- *I/O thread*: Essential for responsive `stop` handling. The search must be interruptible.
- *Unbuffered I/O*: The most common UCI bug. `setvbuf(stdout, NULL, _IONBF, 0)` or `line_buffered`.
- *Time management*: The engine uses `wtime/btime/winc/binc/movestogo` to allocate search time. Typically `(remaining / moves_left) + (increment * 0.75)`.

Implementing a correct UCI adapter is a rite of passage for every engine developer. The protocol's simplicity hides subtle edge cases, but once mastered, it provides a rock-solid foundation for connecting your engine to the world.
