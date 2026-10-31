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
