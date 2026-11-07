# Reference deband comparison implementation plan

User authorized all proposed experiments and computer testing. Continue inline in existing
isolated compression-filters worktree, preserving earlier work and builds. No merge/commit.

Goal: comparable reference-style debanding, bounded adaptive-window alternative and changed
pixel visualization, measured in a standalone Metal bench before user evaluation.
Architecture unchanged: display-only SDR, immutable asynchronously prepared Metal pipelines,
two reusable scratch textures, same command buffer. No temporal buffers or background work.
Reference mode adapts libplacebo shader logic with attribution/license preserved in a separate
kernel source file; deterministic lab PRNG differs, so no bit-exact reproduction claim.
Adaptive-window mode locally reduces radius before reconstructing smooth patches. Changes
comparison visualizes actual output differences, not a validated artifact-detector mask.

- [x] Failing tests: reference channel thresholds/iterations, adaptive window near real edges,
  changes visualization, config round trips/ranges, isoluminant chroma and planar borders.
- [x] Implement kernels, settings/routing/UI/presets, separate source notices.
- [x] Extend standalone image/fixture/GPU comparisons; measure 4K/5K and settings budget.
- [x] Full tests, release, final fresh review, package updated isolated experiment and results.

UI validation of Lab2 completed before changes: visible white split divider, image movement
with filters enabled, keyboard A/B updates config and picture. Stats text refresh lags a render;
previous shortcut failure inference was incorrect. Avoid attributing synthetic MAE to general
video quality. Keep caffeinate detached for test duration; do not change lock/security settings.

User correction: deband/chroma MUST precede final upscaling; MetalFX artifact suppression
MUST follow it. Actual display verified: Kuycon G32P 6144×3456 @60 Hz (logical3072×1728).
Extend current task: source-size preprocessing, post-scale AR/dither, unfiltered comparison
baseline only when requested. Integration GPU tests must verify order and split baseline;
benchmark real DisplayScaler at1080p/4K→6144×3456. Existing post-only timings are historical.

Final results: docs/bench/player-filter-lab.md. Full1,843 tests pass; final75 focused
checks pass; release built,6K actual pipeline measured, app updated and UI smoke checked.
Review: notice packaging fixed and bundled files verified; pre-stage failure now reported;
architecture corrected. No deferred review findings remain. Correlated deterministic
reference sampling disclosed. Order integration tests RED→GREEN on all three scalers.
User correction supersedes initial post-only architecture: separate bounded pre/post renderers.
