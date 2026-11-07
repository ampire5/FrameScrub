# Temporal Noise Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Try native Apple temporal denoising for 4K playback and paused frames.
**Architecture:** Extend the existing original-first bounded effect worker with API-compliant temporal references and native SDR/HDR output. Cache events resume paused work without polling.
**Tech Stack:** Swift6, VideoToolbox, CoreVideo, CoreImage, existing SettingsKit/AppKit display.
**Spec:** docs/superpowers/specs/2026-11-07-apple-ll-effects-design.md (Temporal noise extension)

## Global Constraints
No extra decoder, source downscale or main-thread processing; one active/one pending request; references bounded to one past/two future; settings default off; no export effect. Preserve existing uncommitted work and branch.

## Review Focus
HDR tone mapping; wrong/missing references; seeking/pause cache events; output ownership; cached failures/no reload loops.

### Task 1: Processor and contracts
- [x] Write failing config/reference/real-output tests in LowLatencyVideoTests.swift.
- [x] Implement TemporalNoiseFilter.swift with native bit-depth buffers and bounded references; extend request/output/settings.
- [x] Run targeted tests, including no-reference and zero-strength fallback plus HDR.

### Task 2: App integration
- [x] Add cache-reference event, request identity/context, processed-HDR display mapping, config/menu/settings controls.
- [x] Update architecture/reference; run full tests and settings bench; review.

### Task 3: Real 4K experiment
- [x] Build isolated release app, run visible SDR/HDR/paused/noisy4K cases; verify pixel output and measure.
- [x] Create matched before/after samples, document results and performance limitations; keep branch uncommitted.

Execution: inline, as the requested experiment; no new approval/merge/commit gate.
