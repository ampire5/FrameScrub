# Filmstrip readiness, reuse and height

Apple M4 Max (14 physical cores, 36 GB), macOS 27.2, debug build. Local
`Tests/Fixtures/h264_cfr_gop250.mp4`: 1920×1080, 30 fps, 600 frames, three keyframes. Network-policy runs impose
the existing 250 ms scheduling dwell; they do not measure real NAS bandwidth. Intel remains unmeasured.

## Baseline and cause

The film already selected preceding keyframes, but its provider had an independent thumbnail cache and did not
consult the playback frame cache. Serial centre-first scheduling could decode a miss while reusable samples
waited behind it. The paused foreground gate also allowed film work before the requested paused picture was ready.

Existing native UI checks passed before the change. A two-second `sample` of the native UI bench showed the
main thread mostly waiting for events; sampled active film work was AppKit painting/layout. Per-action CPU
measurements below were comfortably within budget. No painting/animation rewrite was justified or performed.

## Keyframes versus exact frames

`--bench-keyframe-cost` uses a utility worker and two already-open decoders, alternates their order over five
rounds and seeks to frames 125, 375 and 575. Keyframe mode returns the preceding keyframe; exact mode decodes
through to each requested frame. Wall time for the three seeks/frames:

| Mode | Round 1 | Median of five rounds |
|---|---:|---:|
| Keyframe | 11.048 ms | 10.909 ms |
| Exact | 80.765 ms | 80.850 ms |

This fixture supports keeping keyframe-only film sampling. It is not a codec-independent speed claim.

## Reuse and scheduling

The shared `PreviewImagePool` is per preview configuration (file and rotation), records actual decoded PTS and
requested resolution, and replaces smaller entries with larger ones. Preview workers render matching playback
keyframes before opening a decoder. Pool hits are delivered directly without rendering. Approximate indexes
only populate actual-PTS entries after decoding; they cannot treat an estimated frame number as a keyframe.

A regression bench preloads keyframe 500 into the real playback cache, requests `[250, 0, 500]`, and blocks the
foreground gate for 50 ms. It verifies zero arrivals while blocked, then keyframe 500 first and only two decodes
for the three pictures. With old FIFO scheduling and the same real index, its ready-first assertion fails.
After the change, arrivals were 92.808 / 103.139 / 107.264 ms from submission, including the blocked 50 ms.
Core integration tests also verify zero decoding when a second provider reuses a larger thumbnail, and zero
decoding when the matching playback frame supplies the picture even though the preview URL cannot decode.

Actual PlayerCore/autoplay, no pause or pointer input:

| Picture | Before | After |
|---|---:|---:|
| First | 286.3 ms | 266.5 ms |
| Second | 298.8 ms | 274.6 ms |
| Third | 304.9 ms | 281.0 ms |

These individual runs include the 250 ms dwell; the demonstrated benefit is avoided decoding, not a guaranteed
latency percentage. Existing sample-wheel navigation, no-repeat delivery, changing lens geometry without new
images and refill while settings stay open all passed.

## Native UI CPU time

Actual AppKit views, `CLOCK_THREAD_CPUTIME_ID`, cached display with native event pumping. p50 / p99 unless a
single action is specified. Five update/narrow/return rounds showed no accumulating growth.

| Action | Before | After |
|---|---:|---:|
| Position update, round 5 | 0.828 / 1.054 ms | 0.946 / 1.082 ms |
| Maximum 65-cell update | 1.998 / 3.167 ms | 2.206 / 3.514 ms |
| Live lens settings, 65 cells | 2.089 / 3.148 ms | 2.300 / 3.358 ms |
| First panel construction | 10.998 ms | 13.337 ms |
| First dropdown open | 24.644 ms | 25.684 ms |
| Nine return opens, range | 4.439–16.193 ms | 4.011–5.432 ms |
| Live height, 65-cell setup | — | 2.916 / 3.067 ms |

Native assertions exercise the actual height slider at 36, 96 and 57 pt, immediate geometry, persisted restore,
48 pt reset and the retained popover callback while it stays open. Existing edge-button hit testing, hover,
hidden late delivery/no redraw, no hidden requests/timer, visibility and dropdown-close checks also pass.
The six-row panel PNG was visually inspected. These are controlled native/cached-display checks, not physical
mouse, VoiceOver, real NAS or Intel verification.

## Resource bounds

One utility film decoder remains; the pending batch stays capped at 65. There is no extra full-frame collection,
cache scan, decoder per cell, polling or idle timer. A reused full-size frame is retained only while its single
worker renders the thumbnail. Foreground current readiness is required even while paused; while playing, the
next picture is also required before starting another film job. Readiness means cached **or** terminally
undecodable: after review, a real PlayerCore test exposed the paused missing-frame case. A stale/damaged table
advertises frame 600 beyond the fixture's 600 real frames; the test waits for its terminal result and a state
notification without displaying frame 600. The regression failed before the event-driven fix and passed after:
the filler reports a newly unavailable focus, Core validates session/position, and the host resumes pending film
work from its state callback. No polling was added. Existing in-flight work may finish.

The former two 200-entry provider caches become one pool with at most 200 entries **and** 32 MiB of image pixels.
At tightly packed 320×180 RGBA this budget holds 145 pictures; actual Core Graphics row stride is charged.
The byte bound also covers larger hover pictures. Tests verify both entry eviction and byte-budget eviction,
oversized-image rejection, source/rotation mismatch, resolution upgrades, approximate-to-exact reuse and stop
suppression. The view retains its existing 130-picture display cache; a pool eviction cannot revoke a displayed
image, so the pool budget is not a whole-process memory ceiling. No increase in decode parallelism or cache
entry limits was introduced.

## Reproduction

```sh
FrameScrub --bench-timeline --bench-keyframe-cost --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
FrameScrub --bench-timeline --bench-film-loader --expect-resume --expect-batch --expect-ready-first \
  --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
FrameScrub --bench-timeline --bench-playing-film --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
FrameScrub --bench-timeline --offscreen --shots /tmp/filmstrip-shots
```

The loader bench now builds the real file index: its former synthetic 1/30 timestamp units were unsuitable for
matching real cached frame PTS. Kit pins are unchanged.

## Review and remaining checks

Independent read-only review found the terminal paused-frame issue above; it was corrected and regression-tested.
Final full suite after the fix: 1792 Core tests and 35 settings tests passed (1827 total); the Core run took
49.807 s. Focused missing-frame regression passed in 0.435 s. `git diff --check` and `scripts/kits-check.py` passed.
One minor optimisation remains deferred: a hover request checks reusable pictures before its network dwell;
if the film produces that picture during the dwell, hover can still decode it once more afterwards. Rechecking
at that boundary would avoid this race. It does not change displayed frame identity or increase worker concurrency.
Physical continuous mouse dragging while the popover anchor resizes, VoiceOver, Intel and real NAS remain unmeasured.

## Follow-up: preparation before reveal

On the same M4 Max/local H.264 fixture, `--bench-film-prewarm` uses the actual view folded in a controlled visible
window. One sampled keyframe is already decoded in the playback cache; other sampled keyframes are deliberately
missing. The foreground gate blocks all work for 50 ms. After explicit resume, the prepared picture enters the
folded view cache at 67.079 ms from submission, with **zero film decodes and no redraw invalidation**. Waiting
another 150 ms produces no missing-picture decoding. Reveal then reuses that picture and decodes the other two
at 237.386 / 257.391 ms from initial submission. This is controlled native event/cache testing, not physical UI
or NAS timing.

The existing worker handles both request classes. Prewarm keeps a bounded snapshot of currently reusable
candidates, drops misses, and yields to visible work. A ready-only worker request cannot open/seek its decoder,
even if eviction made the earlier readiness check stale. Tests cover both ready-only success from the playback
cache and a ready-only miss on an undecodable source, followed by an ordinary request that still reports the
normal decode failure. This guards against speculative work poisoning the provider's failure state.

Planning is triggered by exact-index/configuration availability and when a displayed frame belongs to the
bounded missing sample set. A movie whose every frame is intra-coded therefore does not plan once per frame.
While folded, only cached pictures/full frames are reused: no extra file/network reader or decode concurrency.
Active hover preview, interactions, export, Home, occlusion and unresolved foreground work defer the pass.
No speculative miss queue or repeating wakeup is added.

Follow-up full suite: 1793 Core + 35 settings tests passed (1828 total), Core50.641s; ordinary autoplay passed.
Read-only follow-up review found no Important/Critical issue. One Minor opportunity remains: if prewarm is
skipped/deferred by occlusion or hover while paused, it may wait for the next real frame/state/index event after
that gate clears. Explicit restoration/hover-exit retry could capture more opportunities; visible film loading
and foreground correctness are unaffected. Intel, actual NAS and physical restoration/hover interaction remain
unmeasured. The standalone reset bench sends the button's real action directly: its animated test-only click
could pump an unrelated auto-hide timer because that standalone content view has no native popover hold.

```sh
FrameScrub --bench-timeline --bench-film-prewarm --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
```

## Higher density limit

The density maximum is now 8× (formerly 4×), with one shared limit for layout, slider restoration, programmatic
updates and Option-scroll. Default/reset remain 2.75×. The regression failed at the former clamp because 8×
produced the same count as 4×; it passes now in all three projections and checks the 65-cell bound at 8192 pt
and clamping of oversized inputs. Full suite: 1794 Core + 35 settings tests passed (1829 total), Core47.364s.
The native bench includes 8× density and restoring 8× into the actual slider. Existing pending/cache/concurrency
limits remain unchanged; higher selected density can request more samples within those limits.

## Local integration, 2026-11-02

Integrated with Home refresh/failed-poster handling and the network-preview rate limiter. The shared pool's ready
images bypass a busy hover worker; generations keep late cold results from replacing newer cached deliveries.
Ready-only film requests still cannot open/seek a decoder. Repeated requests after an unavailable preview still
report completion, preserving serial-consumer progress (a merge regression test first timed out before the fix).

Merged validation: 1802 Core + 35 settings tests passed. Native hidden-film preparation completed its first reuse
at 67.563 ms, without decoding/redrawing the folded strip; reveal filled the misses at 239.278 / 267.962 ms.
The ready-first foreground-resume loader delivered three images at 96.968 / 109.298 / 113.253 ms with two decodes.
The Home empty-file/refresh/pause/return scenario and the menu ⌘R/window-close scenario also passed.
