== C++ Implementation: Modern Chess Engine Design

C++ offers powerful abstractions—templates, constexpr, RAII, and the Standard Template Library—that can make a chess engine more maintainable without sacrificing performance. This chapter presents "ModernChess," a C++17 engine that achieves the same ~2000 ELO strength as the C engine in Chapter 20 while being significantly more readable and type-safe.

=== Philosophy: Zero-Cost Abstractions

The key principle of chess engine C++ is "zero-cost abstractions": use C++ features that compile to the same machine code as the equivalent C, but with better type safety and code organization. Templates instantiated with compile-time constants become direct code; `constexpr` tables are computed at compile time; RAII eliminates manual cleanup.

What we avoid: exceptions (unpredictable performance), virtual functions in hot paths (vtable overhead), dynamic allocation during search (use stack or preallocated pools), RTTI (not needed).

=== Core Types with Strong Typing

```cpp
// types.hpp — Type-safe chess primitives
#pragma once

#include <cstdint>
#include <array>
#include <string>
#include <cassert>

using Bitboard = uint64_t;

enum class Square : int {
    A1, B1, C1, D1, E1, F1, G1, H1,
    A2, B2, C2, D2, E2, F2, G2, H2,
    A3, B3, C3, D3, E3, F3, G3, H3,
    A4, B4, C4, D4, E4, F4, G4, H4,
    A5, B5, C5, D5, E5, F5, G5, H5,
    A6, B6, C6, D6, E6, F6, G6, H6,
    A7, B7, C7, D7, E7, F7, G7, H7,
    A8, B8, C8, D8, E8, F8, G8, H8,
    None = 64
};

enum class PieceType : int { Pawn, Knight, Bishop, Rook, Queen, King };
enum class Color : int { White, Black };

constexpr Color operator~(Color c) { return c == Color::White ? Color::Black : Color::White; }

// A Move is a value type (cheap to copy)
class Move {
public:
    constexpr Move() : data_(0) {}
    constexpr Move(Square from, Square to, int flags = 0, PieceType promo = PieceType::Knight)
        : data_(static_cast<uint16_t>(
            static_cast<int>(from) | (static_cast<int>(to) << 6) |
            (static_cast<int>(promo) << 12) | (flags << 14)
          )) {}

    constexpr Square from() const { return Square(data_ & 0x3F); }
    constexpr Square to() const { return Square((data_ >> 6) & 0x3F); }
    constexpr int flags() const { return data_ >> 14; }
    constexpr PieceType promotion() const { return PieceType((data_ >> 12) & 0x3); }
    constexpr bool is_capture() const { return flags() == 0 || flags() == 3; } // approx
    constexpr bool is_promotion() const { return flags() == 3; }

    constexpr explicit operator bool() const { return data_ != 0; }
    constexpr bool operator==(Move other) const { return data_ == other.data_; }

private:
    uint16_t data_;
};
constexpr Move NO_MOVE{};
```

=== Compile-Time Attack Tables

C++17 `constexpr` enables computing all attack tables at compile time:

```cpp
// attacks.hpp — Compile-time attack tables
#pragma once

#include "types.hpp"

namespace attacks {

// Knight attack table, computed at compile time
consteval std::array<Bitboard, 64> compute_knight_table() {
    std::array<Bitboard, 64> table{};
    for (int sq = 0; sq < 64; ++sq) {
        Bitboard bb = 1ULL << sq;
        int r = sq / 8, f = sq % 8;
        Bitboard attacks = 0;
        for (auto [dr, df] : {std::pair{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}}) {
            int nr = r + dr, nf = f + df;
            if (nr >= 0 && nr < 8 && nf >= 0 && nf < 8)
                attacks |= 1ULL << (nr * 8 + nf);
        }
        table[sq] = attacks;
    }
    return table;
}

inline constexpr auto KnightAttacks = compute_knight_table();
static_assert(KnightAttacks[0] != 0);  // verify at compile time

// Similarly for King, Pawn attacks — all consteval
// ...

// Magic bitboard initialization
// Magics are precomputed and stored as constexpr arrays
inline constexpr std::array<uint64_t, 64> RookMagics = {
    0x0080001020400080ULL, 0x0040001000200040ULL, /* ... 62 more entries ... */
};

} // namespace attacks
```

=== Position Class with RAII

```cpp
// position.hpp — Position management with RAII
#pragma once

#include "types.hpp"
#include "attacks.hpp"
#include <vector>
#include <string>

class Position {
public:
    Position() = default;
    explicit Position(const std::string& fen);

    // Copyable
    Position(const Position&) = default;
    Position& operator=(const Position&) = default;

    // State stack for make/unmake
    struct StateInfo {
        Move move;
        int captured_piece;
        Square en_passant;
        int castling_rights;
        int rule50;
        uint64_t hash;
    };

    bool make_move(Move move, StateInfo& state);
    void unmake_move(const StateInfo& state);

    // Accessors
    Color side_to_move() const { return side_; }
    Bitboard pieces(Color c, PieceType pt) const { return by_color_[c] & by_type_[pt]; }
    Bitboard all_pieces(Color c) const { return by_color_[c]; }
    Bitboard occupied() const { return by_color_[White] | by_color_[Black]; }
    Square king_square(Color c) const { return king_sq_[c]; }
    uint64_t hash() const { return hash_; }

    bool is_in_check() const;

private:
    std::array<Bitboard, 2> by_color_{};          // pieces per color
    std::array<Bitboard, 6> by_type_{};           // pieces per type
    std::array<int, 64> piece_on_{};              // piece on each square

    Color side_ = Color::White;
    Square ep_square_ = Square::None;
    int castling_ = 0;
    int rule50_ = 0;
    int game_ply_ = 0;
    std::array<Square, 2> king_sq_{Square::E1, Square::E8};
    uint64_t hash_ = 0;
    int material_[2] = {};
};

// Make/unmake implementation
bool Position::make_move(Move move, StateInfo& state) {
    state.move = move;
    state.captured_piece = piece_on_[static_cast<int>(move.to())];
    state.en_passant = ep_square_;
    state.castling = castling_;
    state.rule50 = rule50_;
    state.hash = hash_;

    // ... (move logic similar to C version, using RAII guarantees)

    // Toggle side
    side_ = ~side_;
    hash_ ^= ZobristSide;

    // Legality check
    if (is_attacked(king_sq_[~side_], side_)) {
        unmake_move(state);
        return false;
    }
    return true;
}
```

=== Template-Driven Search

Templates eliminate runtime branching in the hot search path:

```cpp
// search.hpp — Template-driven PVS
#pragma once

#include "position.hpp"
#include "eval.hpp"
#include "movegen.hpp"
#include "tt.hpp"

class Search {
public:
    Search(Position& pos, TranspositionTable& tt, int thread_id);

    // Main search entry: iterative deepening
    Move search(int max_depth, int time_ms);

private:
    // PVS: templated on node type for compile-time specialization
    template<bool PvNode>
    int pvs(Position& pos, int depth, int alpha, int beta, int ply);

    int quiesce(Position& pos, int alpha, int beta, int ply);

    Position& root_pos_;
    TranspositionTable& tt_;
    int thread_id_;
    bool stop_;
};

template<bool PvNode>
int Search::pvs(Position& pos, int depth, int alpha, int beta, int ply) {
    // TT probe
    TTEntry* tte = tt_.probe(pos.hash());
    if (tte && tte->depth >= depth) {
        if (tte->flag == TTFlag::Exact) return tte->score;
        if constexpr (!PvNode) {
            if (tte->flag == TTFlag::Alpha && tte->score <= alpha) return tte->score;
            if (tte->flag == TTFlag::Beta  && tte->score >= beta)  return tte->score;
        }
    }

    if (depth <= 0) return quiesce(pos, alpha, beta, ply);

    // Null-move pruning (only in non-PV nodes)
    if constexpr (!PvNode) {
        if (depth >= 3 && !pos.is_in_check() && pos.occupied() != (pos.all_pieces(White) | pos.all_pieces(Black) | ...)) {
            // Null move observation
            // ...
        }
    }

    MoveList moves = generate_moves(pos);
    if (moves.empty()) {
        return pos.is_in_check() ? -MATE_SCORE + ply : 0;
    }

    int best_score = -INFINITY;
    Move best_move = NO_MOVE;
    int moves_made = 0;

    for (Move move : moves) {
        Position::StateInfo state;
        if (!pos.make_move(move, state)) continue;
        ++moves_made;

        int score;
        if (moves_made == 1) {
            score = -pvs<PvNode>(pos, depth - 1, -beta, -alpha, ply + 1);
        } else {
            // Late move reductions (only in non-PV)
            int reduction = 0;
            if constexpr (!PvNode) {
                if (depth >= 3 && moves_made >= 4)
                    reduction = 1;  // LMR table lookup in production engine
            }

            score = -pvs<false>(pos, depth - 1 - reduction, -alpha - 1, -alpha, ply + 1);

            if (score > alpha && reduction > 0) {
                score = -pvs<false>(pos, depth - 1, -alpha - 1, -alpha, ply + 1);
            }
            if (score > alpha && score < beta) {
                score = -pvs<PvNode>(pos, depth - 1, -beta, -alpha, ply + 1);
            }
        }

        pos.unmake_move(state);

        if (score > best_score) {
            best_score = score;
            best_move = move;
            if (score > alpha) alpha = score;
        }
        if (alpha >= beta) break;
    }

    // TT store
    tt_.store(pos.hash(), best_score, depth, best_move,
              best_score >= beta ? TTFlag::Beta : (best_move != NO_MOVE ? TTFlag::Exact : TTFlag::Alpha));

    return best_score;
}
```

=== Move Generation with Iterators

C++ iterators make move generation more elegant:

```cpp
// movegen.hpp
class MoveList {
public:
    MoveList() = default;

    void add(Move m) { moves_[count_++] = m; }
    void add_promotions(Square from, Square to) {
        for (auto pt : {PieceType::Queen, PieceType::Knight, PieceType::Rook, PieceType::Bishop})
            add(Move(from, to, 3, pt));
    }

    // STL-compatible iteration
    Move* begin() { return moves_; }
    Move* end()   { return moves_ + count_; }
    const Move* begin() const { return moves_; }
    const Move* end()   const { return moves_ + count_; }

    [[nodiscard]] bool empty() const { return count_ == 0; }
    [[nodiscard]] int size()  const { return count_; }

private:
    std::array<Move, 256> moves_{};
    int count_ = 0;
};

// Usage:
MoveList moves = generate_moves(pos);
for (Move move : moves) {
    // Process each move
}

// Or with algorithms:
auto capture = std::find_if(moves.begin(), moves.end(),
    [](Move m) { return m.is_capture(); });
```

=== UCI Adapter with std::thread

```cpp
class UCIEngine {
public:
    void run() {
        std::cout << "id name ModernChess 1.0\n";
        std::cout << "id author Chess Engine Textbook\n";
        std::cout << "uciok\n";

        std::string line;
        while (std::getline(std::cin, line)) {
            std::istringstream iss(line);
            std::string cmd;
            iss >> cmd;

            if (cmd == "uci")        handle_uci();
            else if (cmd == "isready")    handle_isready();
            else if (cmd == "position")   handle_position(iss);
            else if (cmd == "go")         handle_go(iss);
            else if (cmd == "stop")       handle_stop();
            else if (cmd == "quit")       break;
        }
    }

private:
    void handle_go(std::istringstream& iss) {
        // Parse go parameters into GoParams struct
        GoParams params = parse_go_params(iss);
        stop_ = false;

        // Launch search in a separate thread
        search_thread_ = std::thread([this, params]() {
            Search search(pos_, tt_, 0);
            Move best = search.search(params.max_depth, params.time_ms);
            std::lock_guard<std::mutex> lock(output_mutex_);
            std::cout << "bestmove " << to_uci(best) << "\n";
        });
    }

    void handle_stop() {
        stop_ = true;
        if (search_thread_.joinable())
            search_thread_.join();
    }

    Position pos_;
    TranspositionTable tt_;
    std::atomic<bool> stop_{false};
    std::thread search_thread_;
    std::mutex output_mutex_;
};
```

=== C++-Specific Optimizations

1. *`[[likely]]` and `[[unlikely]]` attributes*: Guide the branch predictor.

```cpp
if (score >= beta) [[unlikely]] break;
if (moves_made == 1) [[likely]] { /* PV node */ }
```

2. *`std::hardware_destructive_interference_size`*: Align per-thread data to avoid false sharing.

```cpp
struct alignas(std::hardware_destructive_interference_size) ThreadData {
    // ...
};
```

3. *`if constexpr`*: Compile-time branch elimination in template code.

4. *`noexcept` specifications*: Enable compiler optimizations for non-throwing functions.

```cpp
constexpr Move(Square f, Square t) noexcept : data_(...) {}
```

=== Summary

The C++ engine demonstrates how modern language features can improve code organization without performance penalties:

- *`enum class`* provides type-safe enumerations that catch errors at compile time.
- *`consteval`/`constexpr`* computes all tables at compile time, eliminating runtime initialization.
- *Templates with `if constexpr`* generate specialized search code for PV vs non-PV nodes.
- *RAII* ensures proper cleanup in make/unmake.
- *STL algorithms* make move generation and ordering more expressive.
- *`std::thread` and `std::atomic`* provide portable threading.
