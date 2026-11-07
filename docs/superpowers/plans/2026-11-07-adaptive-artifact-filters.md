# Adaptive artifact filters implementation plan

> Execute inline using superpowers:executing-plans; final fresh review.

Goal: add texture-protected adaptive debanding and a directional constrained filter to
existing SDR Filter Lab for comparison within the measured 4K budget.
Architecture: independent, research-inspired spatial Metal implementations, not ports
or claims of reproducing AdaDeband/CDEF. Keep old modes as baselines. Two existing
scratch textures, same command buffer, asynchronous pipeline preparation; HDR bypass.
User approved continuing the proposed research experiments with “Go”. No new confirmation,
commit, merge or changes to production defaults. Existing worktree and user edits retained.

Design: adaptive deband estimates local high-frequency activity from second differences
(plane gradients have none), uses a larger directional neighborhood to average only
small color variations, and rejects real edges. Separate threshold (RGB8 code units),
radius (output pixels), texture protection and strength. Directional mode chooses a
low-variation axis and applies bounded nonlinear neighbor differences, skipping large
contrasts. Treat this as a new cleanup alternative, not a MetalFX source-range limiter.
No temporal history or automatic codec-grid assumptions. Dither remains opt-in.

- [x] Add failing GPU tests for banded gradients, fine luma/chroma texture, real edges,
  smooth ramps, tiny inputs, constant fields, deterministic frames, zero-strength and HDR.
  Settings round-trip and invalid ranges included.
- [x] Implement adaptive/directional kernels and route via renderer; keep old presets.
- [x] Add config, Settings controls and explicit menu presets; document defaults.
- [x] Run core/settings tests, full suite, release and bounded GPU/settings benches.
- [x] Review, package separate experiment, document measured results and limitations.

Review focus: low-contrast real texture; chroma-only edges; brightness slopes mistaken
for noise; borders/tiny images; source=nil and bypass; no shader full-frame readbacks.
No claim that synthetic improvement proves subjective video quality.

Execution: baseline five GPU/settings tests passed. New tests failed on absent modes/keys,
then passed on real GPU; full suite 1,837 tests passed. Release build succeeded. Extra
fixture command is bench-only and provides reproducible PNGs/error measurements. Author
AdaDeband source found at google/bband-adaband (Apache-2.0); libplacebo sampling.c (LGPL2.1+)
and AOM CDEF sources inspected, no source copied into the app. Lightweight modes remain
explicitly independent approximations, not exact implementations.

Final: review found no important issues. Minor (deferred): independent isoluminant
chroma fixture and explicit planar-border equality test; existing RGB texture, strong
edge, interior plane and tiny/constant cases pass. Bench docs updated in this task.
All 1,837 tests pass; release/bench/packaging verified; UI launch attempt blocked by
Mac locking. No commits or merges requested. Results: docs/bench/player-filter-lab.md.
