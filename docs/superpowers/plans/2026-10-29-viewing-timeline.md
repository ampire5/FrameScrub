# Viewing Timeline Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in this session. Track steps below.

**Goal:** Implement the selected viewing timeline with a nonlinear filmstrip, linear overview and floating controls.

**Architecture:** Keep window actions in PlayerWindowController. Put the reversible time scale in FrameScrubCore,
view geometry and interaction in SeekBarView, and floating buttons in TransportControls. A separate sequential
PreviewProvider supplies bounded visible keyframes at utility QoS, while foreground hover previews retain priority.

**Tech Stack:** Swift 6.2, AppKit, Core Animation, existing FFmpeg/PreviewProvider pipeline, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-29-viewing-timeline-design.md`

## Global Constraints

- macOS 26, including Intel; newer SDK APIs must be gated.
- No main-thread I/O or decoding, no worker per cell, no work at rest or hidden.
- Preserve existing marks, configured seek precision, hover preview and keyboard commands.
- No installation, push or merge in this task. Keep the user's untracked AGENTS.md untouched.

## Review Focus

- Beginning/end, very short files: monotonic mapping, finite math and no duplicated out-of-file thumbnails.
- Variable frame rate: times map through FrameIndex rather than assuming uniform frame spacing.
- Rapid seeks/file switches: stale thumbnail callbacks never populate another file.
- Hidden window/playing: no chain of thumbnail work continues.
- Narrow layout and menus: controls never seek through to the overview, and a menu keeps its capsule visible.

### Task 1: Time scale

Files: `Sources/FrameScrubCore/TimelineLens.swift`, `Tests/FrameScrubCoreTests/TimelineLensTests.swift`.
Produces `TimelineLens(duration:center:halfWidth:secondsPerPoint:)`, `time(at:)`, `offset(for:)`.

- [x] Write tests for monotonic mapping, local seconds, inverse, boundaries, empty input and a frozen gesture.
- [x] Run `scripts/test.sh --filter TimelineLensTests`: expect missing type before implementation.
- [x] Implement bounded analytic mapping/inverse and run the focused tests: expect all pass.

### Task 2: Viewing UI and data source

Files: `SeekBarView.swift`, new `TransportControls.swift`, `PlayerWindowController.swift`,
`LatestOnlyWorker.swift`, `PreviewProvider.swift`.
Consumes TimelineLens; produces the same bar callbacks plus a visible-times thumbnail request and direct film seek.

- [x] Replace permanent controls with two floating capsules, add playback/speed/full-screen callbacks.
- [x] Add film geometry, frozen gesture, context options, overview-only hover and bounded thumbnail cache.
- [x] Add optional worker QoS to PreviewProvider; controller serializes visible requests, gates on pause/visibility,
      and invalidates provider/image state on file changes. Keep the exact index updated.
- [x] Build and run focused tests, then `scripts/test.sh`: expect all existing tests still pass.

### Task 3: Verification and bench

Files: new `Sources/FrameScrub/SeekBarBench.swift`, app `main.swift`, `docs/bench/2026-10-29-viewing-timeline.md`.

- [x] Run a real-window bench for first visit, return, updates, reveal and 320 pt width, five rounds.
- [x] Review first/end, zero duration and rapid provider replacement, then obtain a fresh code review.
- [x] Fix material findings, re-run relevant tests/build, document measurements and remaining Intel validation.

### Follow-up: proportions, pointer response and loading

- [x] Reproduce per-thumbnail network dwell in the actual loader; capture first/last-image elapsed times.
- [x] Fit pictures with the player's rotation/aspect/crop and use their aspect when choosing cells.
- [x] Highlight and enlarge the cached frame under the pointer, pass seeking through, hide on exit/drag.
- [x] Settle once per batch according to the network policy; retain serial utility decoding and foreground gating.
- [x] Verify portrait/wide rendering and hover in AppKit cached display; run tests and document before/after results.
- [x] Obtain focused review; refresh the paused timeline when automatic crop detection finishes.

### Follow-up: delivery, visibility and input

- [x] Paint each thumbnail on delivery; reuse existing progress-preview images in the film cache.
- [x] Separate playback chrome reveal from film zone reveal, collapse unused height, and cancel hidden-film work.
- [x] Add explicit fold/pin menu actions and shortcuts; test saved-pin layout and release-outside hiding.
- [x] Accumulate horizontal scrubbing, step keyframes vertically, and scale the lens with Option-scroll.
- [x] Preserve clicks through small jitter and route the entire visible enlarged thumbnail to film seeking.
- [x] Clear windowed/fullscreen titlebars for top overlays; hold film through open context menus.
- [x] Run the full suite, focused follow-up checks, actual-view input bench and final app build.

### Follow-up: autoplay and viewing decode budget

- [x] Reproduce deferred queue loss and forbidden film loading during playback; allow bounded visible work.
- [x] Retain pending work while foreground is busy and resume on decoded playback frames, without polling.
- [x] Coalesce moving sample requests without repeatedly postponing the batch dwell; retain completed pictures.
- [x] Invert vertical mouse-wheel steps and pause playback when film scrubbing begins.
- [x] Measure eager distant-region filling (212 frames / 3 seeks), defer it until pause (21 / 1), preserve next-start prefetch.
- [x] Start filler workers after selecting resume/autoplay state; run autoplay, region and full-suite regressions.
- [x] Run actual PlayerCore + film-loader autoplay bench without mouse/pause events, and obtain focused review.
