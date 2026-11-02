# Filmstrip Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Reuse prepared pictures before decoding and expose live filmstrip height.

**Architecture:** A per-open-file PreviewImagePool is shared by hover and film providers. PreviewProvider looks up
matching playback keyframes and renders on its worker. FilmstripPreviewLoader schedules reusable samples before
misses while preserving foreground gating and one utility decoder.

**Tech Stack:** Swift, AppKit, Core Image, FFmpeg, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-31-filmstrip-readiness-design.md`

## Global Constraints

- Keep existing keyframe sampling/navigation and kit pins.
- One utility film decoder, bounded pending work, no polling or idle timer.
- Render thumbnails off the main thread; no extra full-frame collection.
- Live height 36–96 pt, default/reset 48 pt, existing persisted height.
- Source/rotation/frame/resolution identity must hold; obsolete-file callbacks are suppressed.

## Review Focus

- Approximate-to-exact index transition must not label an unrelated picture as the exact keyframe.
- Pausing during an outstanding foreground seek must not start extra film decoding.
- A smaller film thumbnail must not degrade a larger hover preview.
- Replacing a pending batch must not repeat an already running sample or continue hidden reads.
- Changing height with the popover open must preserve hit testing and close/hide behaviour.

### Task 1: Shared pool and playback-frame reuse

**Files:** Create `Sources/FrameScrubCore/PreviewImagePool.swift`; modify `PreviewProvider.swift`,
`Tests/FrameScrubCoreTests/PreviewTests.swift`.

**Interfaces:** Pool constructed with source URL/rotation and bounded capacity; get/set by PTS and requested box
size. PreviewProvider accepts optional shared pool and FrameCache, exposes `canReuse(seconds:)` for scheduling.

- [x] Measure existing loader/autoplay/UI benches; profile native film drawing.
- [x] Add failing tests: two providers share a keyframe without decoding twice; playback cached keyframe avoids
  decoder opening; a nearby non-keyframe cannot substitute; size/rotation/source mismatches cannot hit; stop
  suppresses queued delivery; pool capacity evicts.
- [x] Run `swift test --jobs 4 --filter PreviewTests` with native dependency environment; observe RED.
- [x] Implement bounded pool and off-thread reuse, preserving existing fallback and callbacks.
- [x] Run focused tests; expect PASS.

### Task 2: Film scheduling and controller wiring

**Files:** `FilmstripPreviewLoader.swift`, `PlayerWindowController.swift`, `PlayingFilmBench.swift`, `SeekBarBench.swift`.

**Interfaces:** Loader accepts pool and playback FrameCache; providers share one pool per preview configuration.

- [x] Extend native bench to put a ready sample behind a miss and assert it arrives first; blocked foreground
  permits no new decoding, resume completes the visible batch; replacement/hide do not chain stale work.
- [x] Run bench and observe RED before loader changes.
- [x] Wire shared pool/playback cache and ready-first bounded scheduling; preserve centre-first misses.
- [x] Run native loader/autoplay benches; expect PASS with fewer decodes for prefilled samples.

### Task 3: Height control and verification

**Files:** `TimelineLensControls.swift`, `SeekBarView.swift`, `SeekBarBench.swift`, `docs/architecture.md`,
`docs/reference.md`, new `docs/bench/2026-10-31-filmstrip-readiness.md`.

**Interfaces:** Retained popover adds height callback/value; SeekBarView applies a common height-setting path.

- [x] Add native interaction assertions for live resize, persistence, reset and control hit testing; observe RED.
- [x] Add the sixth slider, share height application with context menu, preserve separate hide/pin behaviour.
- [x] Run real-window first/return popover and maximum-cell latency checks, native film benches and full suite.
- [x] Compare baseline/final latency and decode counts; document hardware and unmeasured environments.
- [x] Update architecture/reference; inspect diff for private specifics and unchanged kit pins.
- [x] Obtain fresh whole-change review, fix important findings, and retain reviewable branch without merging.

### Task 4: User-requested preparation before reveal

**Files:** `PreviewProvider.swift`, `FilmstripPreviewLoader.swift`, `SeekBarView.swift`,
`PlayerWindowController.swift`, `PreviewTests.swift`, `SeekBarBench.swift`, architecture/reference/bench.

**Interfaces:** `PreviewProvider.request(seconds:readyOnly:)` prohibits decoder fallback for speculative work;
`FilmstripPreviewLoader.prewarm(_:)` holds only currently reusable candidates and a separate `mayPrewarm` gate;
`SeekBarView.prewarmFilmstripTimes(center:)` returns missing exact-index samples without reveal/invalidation.

- [x] Add failing ready-only miss regression; verify missing API RED, then no decoder/unavailable side effects GREEN.
- [x] Share one serial worker, prioritize visible work, bound/filter the warm snapshot, and retain no speculative misses.
- [x] Wire exact-index and missing-sample-frame triggers; exclude interactions, hover, export, Home and occlusion.
- [x] Native prewarm bench: blocked foreground prevents work; hidden ready image arrives without decode/redraw;
  reveal reuses it and decodes only remaining misses. Existing cached-frame test also covers ready-only success.
- [x] Run full suite and ordinary autoplay/UI regressions; review follow-up and record results.
