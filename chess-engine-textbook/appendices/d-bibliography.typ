== Appendix D: Bibliography and Further Reading

This bibliography collects references for every major algorithm, technique, and historical development discussed in the book.

=== Foundational Works

1. Shannon, C. E. (1950). "Programming a Computer for Playing Chess." *Philosophical Magazine*, 41(314), 256-275. The paper that launched computer chess. First to describe minimax search and evaluation functions.

2. Turing, A. M. (1953). "Digital Computers Applied to Games." In *Faster Than Thought*, ed. B. V. Bowden. Pitman Publishing. Turing's "paper machine" chess algorithm.

3. Knuth, D. E., and Moore, R. W. (1975). "An Analysis of Alpha-Beta Pruning." *Artificial Intelligence*, 6(4), 293-326. The foundational analysis proving alpha-beta is optimal and establishing the sqrt(branching) bound.

4. Newell, A., Shaw, J. C., and Simon, H. A. (1958). "Chess-Playing Programs and the Problem of Complexity." *IBM Journal of Research and Development*, 2(4), 320-335. Early AI approach using heuristic search.

=== Search Algorithms

5. Marsland, T. A., and Campbell, M. (1982). "Parallel Search of Strongly Ordered Game Trees." *Computing Surveys*, 14(4), 533-551. Principal Variation Search (PVS/NegaScout).

6. Reinefeld, A. (1983). "An Improvement to the Scout Tree-Search Algorithm." *ICCA Journal*, 6(4), 4-14. Null-window search.

7. Beal, D. F. (1990). "A Generalised Quiescence Search Algorithm." *Artificial Intelligence*, 43(1), 85-98.

8. Heinz, E. A. (1999). "Adaptive Null-Move Pruning." *ICCA Journal*, 22(3), 123-132.

9. Hyatt, R. M. (1999). "The Dynamic Tree-Splitting Parallel Search Algorithm." *ICCA Journal*, 20(1), 3-19. Crafty's DTS.

10. Feldmann, R. (1993). "Game Tree Search on Massively Parallel Systems." Ph.D. Thesis, University of Paderborn. Young Brothers Wait Concept (YBWC).

=== Evaluation and Tuning

11. Buro, M. (1999). "From Simple Features to Sophisticated Evaluation Functions." *Computers and Games*, 126-145. Tapered evaluation.

12. Österlund, P. (2011). "Texel Tuning." *TalkChess Forum*. The logistic regression approach to evaluation tuning.

13. Spall, J. C. (1992). "Multivariate Stochastic Approximation Using a Simultaneous Perturbation Gradient Approximation." *IEEE Transactions on Automatic Control*, 37(3), 332-341. SPSA algorithm.

14. Hansen, N. (2006). "The CMA Evolution Strategy: A Comparing Review." *Towards a New Evolutionary Computation*, 75-102. CMA-ES optimization.

=== Neural Networks in Chess

15. Silver, D., et al. (2018). "A General Reinforcement Learning Algorithm That Masters Chess, Shogi, and Go Through Self-Play." *Science*, 362(6419), 1140-1144. AlphaZero.

16. Nasu, Y. (2018). "Efficiently Updatable Neural-Network-based Evaluation Functions for Computer Shogi." The original NNUE paper from YaneuraOu.

17. Stockfish NNUE Documentation and Developer Discussions (2020-2024). The adaptation of NNUE to chess. Ongoing work at `github.com/official-stockfish/Stockfish`.

18. Schrittwieser, J., et al. (2020). "Mastering Atari, Go, Chess and Shogi by Planning with a Learned Model." *Nature*, 588, 604-609. MuZero.

=== Tablebases

19. Thompson, K. (1986). "Retrograde Analysis of Certain Endgames." *ICCA Journal*, 9(3), 131-139. First endgame tablebases.

20. Nalimov, E. V., et al. (2000). "Computer Analysis of Chess Endgames." *ICCA Journal*, 23(3), 145-153.

21. de Man, R. (2013). "Syzygy Endgame Tablebases." `github.com/syzygy1/tb`. The modern standard for tablebases.

22. Guo, B., et al. (2018). "Lomonosov Tablebases." Moscow State University. 7-piece tablebases.

=== Board Representation

23. Hyatt, R. M. (2009). "Rotated Bitboards." *Crafty Documentation*.

24. Pradu Kannan (2007). "Magic Bitboards." *Chess Programming Wiki*. The technique that made bitboard attack generation fast.

25. Robert Purves (2017). "BMI2 PEXT Bitboards." *Chess Programming Wiki*. Using the PEXT instruction for faster slider attacks.

=== Parallel Search

26. Hyatt, R. M. (1997). "Dynamic Tree Splitting Revisited." *ICCA Journal*, 20(1).

27. Ablett, D. (2011). "Lazy SMP." *TalkChess Forum*. The algorithm that replaced YBWC.

=== Testing and Statistics

28. Silver, D. (2010). "Using SPRT for Chess Engine Testing." Sequential Probability Ratio Test applied to engine matches.

29. Fishtest Framework. `tests.stockfishchess.org`. Distributed testing for Stockfish.

30. OpenBench. `github.com/AndyGrant/OpenBench`. Generalized distributed testing framework.

=== Implementation and Engineering

31. Hyatt, R. M. (2004). "Chess Program Architecture." *Crafty Documentation*. Classic reference for engine structure.

32. Romstad, T., Costalba, M., and Kiiski, J. (2008-2024). Stockfish Source Code. `github.com/official-stockfish/Stockfish`. The most studied chess engine codebase.

33. Pascutto, G.-C. (2017-2024). Leela Chess Zero Source Code. `github.com/LeelaChessZero/lc0`.

34. Grant, A. (2017-2024). Ethereal Source Code. `github.com/AndyGrant/Ethereal`.

=== Online References

35. Chess Programming Wiki. `www.chessprogramming.org`. Comprehensive reference for all chess engine topics.

36. Computer Chess Club (TalkChess). `www.talkchess.com`. Active forum since 1997.

37. CCRL Rating List. `ccrl.chessdom.com`.

38. CEGT Rating List. `www.cegt.net`.

39. UCI Protocol Specification. `wbec-ridderkerk.nl/html/UCIProtocol.html`.

=== Books on Chess and Computing

40. Frey, P. W. (1977). *Chess Skill in Man and Machine*. Springer-Verlag.

41. Hsu, F.-H. (2002). *Behind Deep Blue: Building the Computer That Defeated the World Chess Champion*. Princeton University Press.

42. Newborn, M. (1997). *Kasparov versus Deep Blue: Computer Chess Comes of Age*. Springer-Verlag.

43. Sadler, M., and Regan, N. (2019). *Game Changer: AlphaZero's Groundbreaking Chess Strategies and the Promise of AI*. New in Chess.
