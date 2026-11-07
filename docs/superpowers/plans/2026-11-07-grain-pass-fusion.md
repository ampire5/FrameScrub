# Grain Pass Fusion Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in the existing isolated workspace.

**Goal:** Remove the extra grain pass for the measured common MetalFX+AR path, retaining image structure and scrub behavior.
**Architecture:** Shared AR/grain value helpers, one compiled Metal library, fused encoder writing an existing post-filter target.
**Tech Stack:** Swift, Metal, existing DisplayScaler and Swift Testing.
**Spec:** `docs/superpowers/specs/2026-11-07-perceptual-grain-design.md` and the user's explicit pass-optimization requirement.

## Global Constraints

Keep cleanup before scaling; grain follows all cleanup/sharpening. Fuse only MetalFX+luma/edge AR
with sharpen0/dither0. Preserve the existing general fallback, SDR/HDR policy, comparisons,
deterministic decoded-frame seeds and bounded/reusable buffers. No new queue or frame history.

## Review Focus

- Same math within FP16 rounding, including nonconstant edges and colour texture.
- Sharpen/dither/directional/non-MetalFX paths retain correct ordering.
- Split/changes preserve baseline and target alias safety.
- Fused path releases the separate grain output, repeated renders allocate nothing new.
- Normal timeline scrubbing sees filters; moving zoom remains the documented cheap-path exception.

### Task 1: Fused behavior

- [x] Add failing fused-versus-separate GPU and fallback/memory assertions.
- [x] Factor shared AR/grain functions; compile immutable pipelines once; add fused encoder and reusable target access.
- [x] Integrate into DisplayScaler and pass grain/filter/scaler tests.

### Task 2: Evidence and reviewable build

- [x] Re-measure changing4K→6K full pipeline, save samples and explicit image-difference limits.
- [x] Run full tests/release/settings checks as appropriate, obtain read-only review, fix findings.
- [x] Package a separate optimized lab and present updated samples.
- [x] Native playback and source-frame scrub verification completed in the later candidate build (see perceptual-grain bench): changing rendered hashes, 150/151 paused scrub outputs. Rechecked native playback/frame stepping before integration. Physical mouse-wheel device acceptance remains a manual check: the CUA scroll API emits the volume/trackpad path, so it is not reported as a physical wheel test.
- [x] Update architecture/bench/roadmap with performance scope and outstanding energy measurements.

Pipeline overlap can hide latency but is not an energy-saving claim. Keep only bounded useful
work, pause background work and skip obsolete scrub requests. Actual power/thermal behavior
requires a separate sustained player measurement, not stage-time extrapolation.

## Evidence

Full1851 Core +35 Settings tests passed; release build45.03s. Three changing4K→6K sources now measure~6.08–6.17ms for combined cleanup+grain; every combined grain mode reports fusion. Grain-specific allocation is reduced by162MiB in the fused path. All18 old/new native snapshots differ by at most1RGB8code. Review found no actionable issue. Native UI check is incomplete: repeated CUA timeouts persisted after rebind/reset; process sample shows an idle AppKit main loop, not a demonstrated rendering deadlock. No commits, app/config overwrite, new queues or power claims.

Integration audit 2026-11-08: the earlier UI connection blocker was resolved in the later
candidate app. Native playback advanced frame38→110, paused stepping updated the frame;
source-frame scrubbing has separate native diagnostic evidence in the grain bench.
User accepted the final grouped panel and strong cleanup build for integration. Auto
activation is explicitly deferred; more restoration research and sustained thermal
measurement are future iterations, not incomplete delivery requirements. No physical
mouse-wheel input claim is made from CUA's trackpad/volume scroll event.
