# Virtual Cuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Analyze, review, save and play a cut from several source ranges through File View before adding file export.

**Architecture:** FrameScrub owns the virtual clock, source switching and File View presentation. A provider owns remote analysis, drafts, catalog and revisioned writes. The provider-specific adapter is private.

**Tech Stack:** Swift 6.2, AppKit, HomeScreenKit, existing FrameScrub decoder and plugin bridge, Python provider on Windows.

**Spec:** docs/superpowers/specs/2026-11-09-virtual-cuts-design.md

## Global Constraints

- macOS 26, Apple Silicon and Intel.
- No changes to kit pins without an identified interface requirement.
- No synchronous I/O or decode on the main thread. At most one speculative source preparation at a time, yielding to foreground work.
- No private taxonomy, local addresses, paths, models, or dataset material in public code and fixtures.
- File export is a follow-up stage. A native build and real-window verification are required before delivery.

## Review Focus

- Transitive intersections, touching ranges, range order, and equivalent timestamps in different source versions.
- Superseded seek/open, switching to a missing source, and retry without losing cut position.
- Spoofed provider registration, malformed data, stale listing updates and thumbnail cancellation.
- Edits from two clients and reconnecting to a running analysis.
- Variable frame rate, skipping between sources, resume after reorder, and open-original/return.

### Task 1: Virtual timeline contract

Files: `Sources/FrameScrubCore/VirtualCut.swift` and `Tests/FrameScrubCoreTests/VirtualCutTests.swift`.

- [x] Test `VirtualCutTimeline.init(ranges:)` and `location(at:)`: ranges A 10–20, B 0–3, A 18–25 produce A 10–25 then B; the join at cut time 15 maps to B time 0. Transitive intersections merge, touching ranges and different source versions remain separate. Reject invalid times, duplicate IDs and unbounded payloads.
- [ ] Run `swift test --jobs 4 --filter VirtualCutTests` in the configured dependency environment and observe failure before implementation.
- [x] Add Codable provider DTOs (`VirtualCutRange`, `VirtualCutSource`, `VirtualCut`) and a computed `VirtualCutTimeline` with binary search and stable range anchors. Use the source media index when translating positions to frames. Keep authored ranges separate from playable spans.
- [x] Verify mapping at zero, a join, final time and reordering; verify removed anchors resolve to the beginning.

### Task 2: Native virtual playback

Files: `Sources/FrameScrub/VirtualCutSession.swift`, `PlayerWindowController.swift`, `SeekBarView.swift` and source boundary entry points in `Sources/FrameScrubCore/PlayerCore.swift`.

- [x] Test playback transitions before implementation: play across A → B → A, seek across an in-flight B open, retry B, skip B, pause at final frame, and explicit loop.
- [x] Introduce a host coordinator which owns virtual position, the active span and open generation. Reuse ordinary prepared opens and source decoder/cache ownership. Give the active source an exclusive time boundary before requesting the next source. Validate returned source identity, and keep the requested play or pause state across asynchronous opens.
- [x] Route overview, filmstrip, time entry, next/previous range and elapsed/duration through virtual coordinates in cut mode. Add open-original/return and a distinct resume record. Coalesce obsolete preview and seek work; allow one foreground-safe next-source preparation.
- [ ] Verify normal-file transport, joins with unlike frame rates, reversed or rapid scrubs across joins, retry/skip and saved resume. Profile actual app navigation with the repo's window test guidance.

### Task 3: File View provider

Files: `Sources/FrameScrub/FrameScrubHomeSource.swift`, `Sources/FrameScrub/PluginPanel.swift`, `Sources/FrameScrubCore/PluginMessage.swift`, bridge script, and a new `Sources/FrameScrub/PluginCatalogSource.swift`.

- [ ] Test trusted-origin registration, duplicate provider IDs, malformed/oversize card lists, unregistering, and a stale thumbnail or listing after moving away.
- [x] Add a generic registered provider for listing cut summaries, fetching card previews, opening a cut, and invoking edit. Route it through the existing Home source listing and image hooks. Keep provider identity scoped to configured plugins, and keep authorization and media open policy in the host.
- [x] Cache the latest bounded listing for immediate return; request visible mosaics first; stop obsolete work when hidden or provider removed. Restore selection by stable card ID.
- [ ] Verify sidebar appearance, keyboard open, edit action, thumbnail loading, and return to the previous card in the real window.

### Task 4: Private Windows provider and panel

Files: private adapter and its tests outside this public repository. Public provider contract and neutral examples belong in `docs/reference.md` and README.

- [ ] Test cached results, explicit analysis launch, cancellation, reconnect, draft edits surviving refresh, copying ranges into a cut, and conflicting saves. Use synthetic inputs; run read-only checks against installed output schemas before any live changes.
- [ ] Add a bounded job runner around the existing analysis tool and expose stable job state, optional progress counters and final ranges. Version source identities and revisioned writes; preserve original model bounds and copy selected ranges into saved cuts.
- [x] Implement the panel for finding, looping, choosing, adjusting, and ordering ranges. Register the File View source and provide cached previews. Handle failed jobs and save conflicts with retry, reload or copy as applicable.
- [ ] Verify with a real scene and then a cut using at least two sources. Use a private adapter checkout and a separate instance or explicitly authorized live deployment.

### Task 5: Release verification

- [x] Update `docs/architecture.md` for ownership, lifecycle, source authorization and cancellation.
- [ ] Run `scripts/test.sh --jobs 4` and a release build. Run real playback, seek and browse verification on actual sources. Record first open/return and navigation CPU timings on the slowest supported Intel Mac before handoff, and record the inter-source wait separately.
- [ ] Review the public diff for private names, settings and paths. Keep local integration and deployment separate from merge or publication.

## Verification record

- Swift suite: 1,878 tests, 21 skipped, no failures. The Apple Silicon release build succeeded. SwiftPM needed its video fixtures and permission to run the manifest compiler.
- A real-window M4 Max run opened a saved two-source cut from File View, crossed the join, sought back and restored its catalog. See `docs/bench/virtual-cuts.md`.
- The separate provider passed four local tests. Its live instance returned cached fragments from two scenes, saved a test cut and generated a mosaic through a tunnel. A live coarse and refined analysis completed with 682 sampled frames and two returned fragments. The physical Intel window run still needs verification. The installed inference API has no observed cancellation endpoint. Cancellation discards the result and releases the worker when the current pass returns.
