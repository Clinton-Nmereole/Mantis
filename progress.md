# Progress

## Status

In Progress — Viridithas-style delta-based incremental threat updates

## Tasks

- [x] Phase 2: Accumulator integration (delta application, buffer types, modified update_sfnnv14_accumulators)
- [ ] Phase 1: Geometry/threat detection (other subagent — pending)
- [ ] Phase 3: Merge both parts + test suite
- [ ] Phase 4: Validation (cutechess self-play)

## Files Changed

- `nnue/sfnnv14_features.odin` — Added ~250 lines:
  - `ThreatFeatureUpdate`, `PsqtFeatureUpdate`, buffer types
  - `apply_threat_deltas`, `apply_threat_deltas_full`, `apply_psqt_deltas`
  - `materialise_threat_acc_from` (Viridithas pattern)
  - `threat_get_attacks`, `threat_push_outgoing`, `threat_push_incoming`
  - `threat_compute_change_deltas` (simplified — to be replaced by optimized geometry)
  - Modified `update_sfnnv14_accumulators` to compute + apply threat deltas instead of marking dirty

## Notes

- Build passes clean: `odin check .` and `odin build .` both succeed
- SFNNv14 network loads and plays correctly with incremental threat updates
- Simplified threat delta computation is O(n_pieces²) — will be replaced by optimized Viridithas geometry
- No crashes, no illegal moves in smoke tests
- Performance: ~69k nps with SFNNv14 (expected to increase significantly with optimized geometry)
