# Adaptive Perceptual Grain Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in this existing isolated worktree.

**Goal:** Add an optional, structure-protected grain experiment to the existing filter player.
**Architecture:** Dedicated grain pipelines, source mask and reusable output, driven by DisplayScaler.
**Tech Stack:** Swift, Metal, Core Image, existing settings/config/menu and Swift Testing.
**Spec:** `docs/superpowers/specs/2026-11-07-perceptual-grain-design.md`.

## Global Constraints

Default off, SDR only, bounded buffers, no new decoder/timer/history/main-thread compilation.
Keep existing pre/post cleanup order and comparison semantics. No unrelated commits or changes.

## Review Focus

- Preserved source texture and high-contrast edges must reject grain.
- Repeated paused render and reverse seek must reproduce the same pattern.
- Grain-only mode must work with MetalFX and other scalers, including native size.
- Split/bypass/HDR must not accidentally add grain to the original side.
- Disable/reconfigure must release state and never create continuous work.

### Task 1: Grain model, settings and GPU behavior

- [x] Add failing settings and GPU tests in `Tests/FrameScrubCoreTests/PerceptualGrainTests.swift`.
- [x] Implement `PerceptualGrain.swift`: template bank, immutable pipelines, mask/output encoder.
- [x] Add grain settings/config keys and pass the focused tests.

### Task 2: Player integration

- [x] Add DisplayScaler integration tests before changing its path.
- [x] Integrate source mask and final grain, frame seed from VideoView; preserve final comparisons.
- [x] Add type/parameters to settings and experimental menu, update architecture/reference.
- [x] Pass filter/scaler/config/settings tests; check real settings action budgets.

### Task 3: Real data and reviewable build

- [x] Compare off/fine/soft on external 4K Lips/Flower with 6K MetalFX and record stage/full-path timing.
- [x] Verify texture negatives, pause determinism and allocation bounds; generate motion comparisons.
- [x] Run appropriate full tests/release build, review current diff and package a separate grain lab
  without overwriting the user's existing lab/config. Record evidence and remaining roadmap work.

## Execution record

TDD: initial model/API absence, source-phase hole and repeated-comparison allocations were observed failing before their implementations/fixes. Full Core/Settings tests and release build passed. A final targeted run adds post-sharpen order and changed-pixel assertions. Read-only review rechecked both fixes with no remaining grain findings. Experimental standalone and packaged app checks are recorded in `docs/bench/perceptual-grain.md`. No commits or changes to the existing lab/config. Subjective normal-distance preference and the previous roadmap remain follow-up work.
