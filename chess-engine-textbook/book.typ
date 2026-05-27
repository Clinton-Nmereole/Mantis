// Chess Engine Textbook: From Zero to TCEC
// A Complete Guide to Building World-Class Chess Engines

#set page(
  paper: "a4",
  margin: (left: 2.5cm, right: 2.5cm, top: 2.5cm, bottom: 2.5cm),
  numbering: "1",
)

#set text(
  font: "Libertinus Serif",
  size: 11pt,
  lang: "en",
)

#set heading(numbering: "1.")
#set par(justify: true, leading: 0.7em)

// Custom styling
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  set text(size: 22pt, weight: "bold")
  v(0.5cm)
  it
  v(0.3cm)
}

#show heading.where(level: 2): it => {
  set text(size: 16pt, weight: "bold")
  v(0.3cm)
  it
  v(0.15cm)
}

#show heading.where(level: 3): it => {
  set text(size: 13pt, weight: "bold")
  v(0.2cm)
  it
  v(0.1cm)
}

// Code block styling
#show raw.where(block: true): it => {
  block(
    fill: luma(240),
    inset: 10pt,
    radius: 4pt,
    width: 100%,
    it
  )
}

// ============================================================
// Title Page
// ============================================================

#align(center)[
  #v(3cm)
  #text(size: 32pt, weight: "bold")[Chess Engine Engineering]
  #v(0.5cm)
  #text(size: 18pt)[From First Principles to TCEC Competition]
  #v(1.5cm)
  #text(size: 14pt)[A Complete Textbook for Building World-Class Chess Engines]
  #v(2cm)
  #text(size: 12pt)[Featuring Code Examples in C, C++, Rust, Zig, and Odin]
  #v(1cm)
  #text(size: 11pt)[With In-Depth Case Studies of Stockfish, LCZero, and Other Top Engines]
  #v(2cm)
  #text(size: 11pt, style: "italic")[First Edition — 2026]
]

#pagebreak()

// ============================================================
// Table of Contents
// ============================================================

#outline(
  title: [Table of Contents],
  indent: 1.5em,
  depth: 3,
)

#pagebreak()

// ============================================================
// Preface
// ============================================================

= Preface

This textbook is designed to be the definitive guide to chess engine engineering. It assumes the reader has a background in computer science—familiarity with data structures, algorithms, and at least one systems programming language—but assumes *zero* prior knowledge of chess engine internals.

By the end of this book, you will be able to:

- Represent a chess position efficiently in memory using bitboards and other advanced data structures
- Generate all legal moves for any position with optimal performance
- Implement alpha-beta search with state-of-the-art enhancements
- Build a neural network-based evaluation function (NNUE)
- Parallelize your search across multiple CPU cores
- Integrate endgame tablebases for perfect play in simplified positions
- Tune your engine's parameters using automated methods
- Test your engine rigorously using statistical frameworks
- Implement your engine in C, C++, Rust, Zig, or Odin
- Submit your engine to the Top Chess Engine Championship (TCEC)

*Every term introduced in this book is explained in full context.* We make no assumptions about prior chess engine knowledge. When we introduce concepts like SIMD, NNUE, magic bitboards, or transposition tables, we explain what they are, why they exist, and how to implement them—all within these pages.

*No stone is left unturned.* This is not a survey or a high-level overview. This is a complete, rigorous, and exhaustive treatment of computer chess, spanning hundreds of pages of detailed explanations, diagrams, algorithms, and code.

Let us begin.

#pagebreak()

// ============================================================
// PART I: FOUNDATIONS
// ============================================================

= Foundations

#include "chapters/01-introduction.typ"
#include "chapters/02-chess-fundamentals.typ"
#include "chapters/03-board-representation.typ"
#include "chapters/04-move-generation.typ"

// ============================================================
// PART II: SEARCH
// ============================================================

= Search

#include "chapters/05-search-basics.typ"
#include "chapters/06-search-enhancements-1.typ"
#include "chapters/07-search-enhancements-2.typ"
#include "chapters/08-quiescence.typ"
#include "chapters/09-move-ordering.typ"
#include "chapters/10-transposition-tables.typ"

// ============================================================
// PART III: EVALUATION
// ============================================================

= Evaluation

#include "chapters/11-static-evaluation.typ"
#include "chapters/12-advanced-evaluation.typ"
#include "chapters/13-nnue.typ"

// ============================================================
// PART IV: ADVANCED SEARCH AND DATA
// ============================================================

= Advanced Search and Data

#include "chapters/14-parallel-search.typ"
#include "chapters/15-endgame-tablebases.typ"

// ============================================================
// PART V: ENGINEERING AND TUNING
// ============================================================

= Engineering and Tuning

#include "chapters/16-uci-protocol.typ"
#include "chapters/17-tuning.typ"
#include "chapters/18-testing.typ"
#include "chapters/19-performance.typ"

// ============================================================
// PART VI: MULTI-LANGUAGE IMPLEMENTATION
// ============================================================

= Multi-Language Implementation Guides

#include "chapters/20-c-implementation.typ"
#include "chapters/21-cpp-implementation.typ"
#include "chapters/22-rust-implementation.typ"
#include "chapters/23-zig-implementation.typ"
#include "chapters/24-odin-implementation.typ"

// ============================================================
// PART VII: CASE STUDIES
// ============================================================

= Case Studies: Anatomy of Top Engines

#include "chapters/25-stockfish-case-study.typ"
#include "chapters/26-lc0-case-study.typ"
#include "chapters/27-other-engines.typ"

// ============================================================
// PART VIII: PUTTING IT TOGETHER
// ============================================================

= Putting It All Together

#include "chapters/28-putting-it-together.typ"
#include "chapters/29-future-directions.typ"

// ============================================================
// APPENDICES
// ============================================================

= Appendices

#include "appendices/a-math-reference.typ"
#include "appendices/b-datasets.typ"
#include "appendices/c-glossary.typ"
#include "appendices/d-bibliography.typ"

