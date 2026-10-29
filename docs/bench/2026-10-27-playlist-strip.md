# Playlist strip: the main thread per action

Date: 2026-10-27. Branch `strip-slots` (spec `docs/superpowers/specs/2026-10-27-playlist-strip-design.md`).

**Machine.** Apple M4 Max, 14 physical cores, macOS 27.0.1. Release build.

**How.** `FrameScrubBench playlist-strip [--rows N] [--rounds N]` (`Sources/FrameScrubBench/PlaylistStripBench.swift`):
- `FilmstripRowsView` (HomeScreenKit) in a real window on screen, 360 × 900 pt, 500 rows; a third with facts, three
  aspects; each row's text from `PlaylistRowFacts`; the card a stack of `NSTextField`s, as the app builds it.
- Main-thread CPU (`CLOCK_THREAD_CPUTIME_ID`) per action, each ending with `CATransaction.flush()`, so the Core
  Animation commit is counted.
- Five rounds: shown (made the first time in each round, then hidden and shown again), 2 000 scroll events of one
  sweep, 100 steps of the browsed row with the card rebuilt, 20 filter changes 500 → 40 → 500.
- Not in it: the app's glue (`PlaylistStripView`: reads off the main thread, the timers). It lives in the app target,
  which the bench cannot import; its main-thread part is what is measured here plus dictionary lookups.

## Result

| Action | Budget | p50 | p99 | max | Rounds 1 → 5 |
|---|---|---|---|---|---|
| Show the strip, first time | ≤ 100 ms | 3.2–3.6 ms (8.6 ms in round 1, cold) | | | flat |
| Show again | ≤ 30 ms | 0.35–0.71 ms | | | flat |
| One scroll event | p99 ≤ 8 ms | 0.04–0.05 ms | 0.23–0.40 ms | 1.4–3.7 ms | flat |
| Browsed row moves by one (card rebuilt) | ≤ 16 ms | 1.1–1.3 ms | 1.6–2.7 ms | 1.7–2.9 ms | flat |
| Filter 500 → 40 → 500 | ≤ 50 ms | 1.0–1.1 ms | 1.1–1.5 ms | 1.1–1.9 ms | flat |

Every action is far inside its budget, and no round is slower than the one before: nothing accumulates. The card's
rebuild (new `NSTextField`s) is most of "browse by one".

At rest the bench's own run loop costs 1.1 ms per second (it wakes every 50 ms to look for events); the strip adds
nothing there: it has no timer or animation of its own at rest.

**Intel Mac: not measured yet.** Needed before `playlist-view = strip` becomes the default.
