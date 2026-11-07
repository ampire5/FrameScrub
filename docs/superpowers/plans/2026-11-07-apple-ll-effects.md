# Apple LL effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Native Apple LL SR and interpolation for display, replacing the unsuccessful deblock and image SR paths.
**Architecture:** Bounded main-actor coordinator, worker-owned VideoToolbox sessions, original-first presentation and clock-selected intermediates. Existing display fitting remains separate.
**Tech Stack:** Swift 6, VideoToolbox, CoreVideo, Core Image, MetalFX, SettingsKit.
**Spec:** docs/superpowers/specs/2026-11-07-apple-ll-effects-design.md

## Global Constraints

No blocking processing/session load on main; one active/one pending request; SDR only; do not reduce unsupported source resolution; original-first fallback. Use existing isolated worktree. Preserve unrelated pending edits.

## Review Focus

- Stale results after seek/file/settings changes must be rejected.
- Unsupported factors/dimensions/HDR preserve native originals and explain fallback.
- Interpolation uses actual timeline timestamps and only consecutive frames at forward 1x.
- Paused changes process once and stop; hidden windows release work.
- Exports remain sized/coloured correctly after removing image SR.

### Task 1: Selection and processing
- [x] Add failing tests in Tests/FrameScrubCoreTests/LowLatencyVideoTests.swift for adaptive/manual selection, source-size bypass, timed intermediate selection and actual processing.
- [x] Implement LowLatencyVideoSettings / LLScaleChoice and LowLatencyVideoProcessor in separate Core files; session buffers honor all configuration attributes and propagate attachments.
- [x] Run the new tests; verify actual LL output dimensions and changing pixels.

### Task 2: Integrate and remove old paths
- [x] Implement one-active/one-pending coordinator with generation invalidation; add tests for replacement and reset.
- [x] Connect VideoView and PlayerWindowController, including pause/visibility/media reset and existing clock.
- [x] Replace display controls, menus and U bindings; persist settings through Config.
- [x] Remove deblocking and image SR, neural export UI/estimates and obsolete tests; retain config migration and Lanczos exports.
- [x] Update architecture/reference and run full swift test --jobs 4 plus release build.

### Task 3: Validate actual app
- [x] Run real display settings bench and public-video playback diagnostics for SR, interpolation and both, plus unsupported/HDR behavior.
- [x] Record measurements/limits, obtain focused review and address material findings.
- [x] Package an isolated test application; report supported modes and measured limitations without claiming unsupported 4K support.

Execution ruling: continue inline under the user's integration request; no extra approval/commit gate, since the requested direction and removal are explicit. Existing uncommitted experiment is not committed piecemeal.
