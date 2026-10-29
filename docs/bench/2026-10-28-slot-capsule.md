# Slot capsule and tabs: the main thread per action

Date: 2026-10-28. Branch `strip-slots` (spec `docs/superpowers/specs/2026-10-28-slot-capsule-design.md`).

**Machine.** Apple M4 Max, 14 physical cores, macOS 27.0.1. Release build.

**How.** `FrameScrubBench slots [--rounds N]` (`Sources/FrameScrubBench/SlotsBench.swift`):
- `SlotCapsuleView` (target `SlotChrome`, the view the app uses) over three tab views in a real window on screen,
  400 × 900 pt: the playlist strip (`FilmstripRowsView`, 500 rows) and two blank pages (`WKWebView`, `about:blank`).
  A tab is shown and the others hidden as `SlotView.setViews` does (`isHidden`, out of VoiceOver).
- Main-thread CPU (`CLOCK_THREAD_CPUTIME_ID`) per action, each ending with `CATransaction.flush()`.
- Five rounds, each from a new panel: the capsule shown and hidden 100 times; the first visit of each page tab (the
  page made, loaded and shown); 60 returns across the three tabs; the filter field opened and closed 20 times.
- Not in it: `SlotView` and `SlotsController` (app target): on a switch they walk the slot's few views and set a few
  properties.

## Result

| Action | Budget | p50 | p99 | max | Rounds 1 → 5 |
|---|---|---|---|---|---|
| Capsule shown or hidden | ≤ 2 ms | 0.06–0.17 ms | 0.15–0.69 ms | 0.70 ms (round 1) | flat |
| Tab, first visit (a page made and loaded) | ≤ 100 ms | 17–19 ms | | 40 ms (round 1, cold WebKit) | flat |
| Tab, return | ≤ 16 ms | 0.05–0.10 ms | 0.11–0.19 ms | 0.45 ms | flat |
| Filter field open or close | ≤ 50 ms | 0.43–0.58 ms | 0.57–1.07 ms | 16 ms (round 1: the field made), then 3.6–5.6 ms | flat |

Everything is inside its budget and no round is slower than the one before it, so nothing accumulates. A return to a
tab builds nothing: it is two `isHidden` flips and the capsule's tab chips. Most of a first visit is `WKWebView`'s
creation. A page is made only when its tab is first shown, and making it cannot be cut into pieces, so pages are not
made ahead (`CLAUDE.md`).

At rest, the bench's own run loop costs 4.1 ms per second with two web views alive. That is the bench polling for
events every 50 ms plus WebKit's own housekeeping. The capsule adds nothing: it has no timer, and its fade-out is a
single scheduled block.

**Strip review, minor 18** (the strip bench drives the kit's view, not `PlaylistStripView`). It stays that way. The
glue needs the app's stores and timers, and its main-thread part is lookups. The capsule bench drives the real
`SlotCapsuleView`, which was moved into its own target for that reason.
