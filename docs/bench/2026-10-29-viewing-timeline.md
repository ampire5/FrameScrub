# Viewing timeline — 2026-10-29

Apple M4 Max, 14 physical cores, macOS 27.0.1 (26A434), arm64 debug build.
The actual `SeekBarView` and `TransportControls` in a real AppKit window, 900 pt wide; narrow case 320 pt.
Main-thread CPU measured with `CLOCK_THREAD_CPUTIME_ID`, including layout, drawing and Core Animation flush.
Five rounds, 50 position updates / narrow boundary layouts / returns / control reveals per round.

```sh
scripts/test.sh --filter 'TimelineLensTests|PreviewTests'
.build/debug/FrameScrub --bench-timeline --shots /tmp/timeline-shots \
  --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
```

This is a new view, not a fix for measured slowness; there is no before/after speed claim. The first creation
includes the first load of symbols/materials. The film/overview plate is 80 pt at the default 48 pt film height;
the transparent hit region above it holds the capsules over the video and does not resize/inset the video.

| Action | Round 1 p50 / p99 ms | Round 2 | Round 3 | Round 4 | Round 5 |
|---|---:|---:|---:|---:|---:|
| First layout (one sample/round) | 34.368 / 34.368 | 8.404 / 8.404 | 8.282 / 8.282 | 7.758 / 7.758 | 7.926 / 7.926 |
| Position update | 0.597 / 3.030 | 0.567 / 0.931 | 0.568 / 0.732 | 0.577 / 0.653 | 0.565 / 0.930 |
| Narrow, alternating first/last frame | 0.524 / 0.893 | 0.472 / 0.700 | 0.464 / 0.764 | 0.470 / 0.734 | 0.483 / 0.725 |
| Return to 900 pt | 0.880 / 1.256 | 0.859 / 1.101 | 0.860 / 1.361 | 0.857 / 1.075 | 0.860 / 1.276 |
| Reveal | 0.421 / 2.430 | 0.413 / 0.665 | 0.412 / 0.604 | 0.411 / 0.620 | 0.410 / 0.639 |

No increasing cost across rounds. All actions fit the project's main-thread budgets on this machine. These CPU
measurements exclude background decoding and do not claim elapsed seek/network latency. Intel is **not measured**;
the slowest-supported-machine check remains required before claiming the budget verified on Intel.

## Real interaction and thumbnail checks

The bench pumps AppKit events, including popover close animations. Checks passed:

- Hiding the film cancels its queued dwell request.
- An open volume popover defers missing-thumbnail requests.
- Closing it resumes missing thumbnails and rearms capsule hiding when the pointer is outside.
- The actual utility decoder delivered all three H.264 fixture keyframes to the view.
- Cached-display images of the beginning, end and narrow layouts were inspected. A floating-point endpoint
  overshoot initially omitted the last thumbnail; `TimelineLens.visibleTime(at:)` now tolerates solver roundoff
  while keeping genuinely exhausted regions empty. The regression test covers this distinction.

An early harness used RunLoop alone and missed AppKit visibility events; the final harness uses
`NSApp.nextEvent` / `sendEvent`. It waits for popover completion rather than assuming its animation is instantaneous.

## Resource bounds

The visible pool is capped at 17 cells, one decoder at utility QoS, and at most 17 pending times. On this display
900 pt / small 36 pt cells needs fewer than that cap. The fixture integration needs only three distinct keyframes.
The view keeps at most 64 images; PreviewProvider's existing 200-entry cache remains bounded. The film gets a
160 × backing-scale pixel width and a 0.25 s dwell, following the established network preview policy. No decoder
is started per cell; after the pending screenful finishes there is no repeating thumbnail timer. Playback, active
gestures, a hidden film and an obscured window suppress new reads. An in-flight read can finish, but cannot chain
further hidden work. Stopping a file clears callbacks so old images cannot enter a new file's strip.

## Review and remaining checks

A fresh read-only review found request cancellation, abandoned-dwell bookkeeping, endpoint roundoff and popover
close notification issues; these were corrected. The proposed capsule-row finding was checked against actual
geometry: the upper region is transparent over the video. Empty parts now pass hit testing through to video.

VoiceOver traversal and Intel latency have not been exercised on their target setup. Subtitles are intentionally
absent because FrameScrub has no subtitle playback control yet. Editing commands and mouse profiles are unchanged;
the separate editing UI is a later task.

## Follow-up: picture proportions, hover and fill latency

The original cell draw stretched every thumbnail to the cell rectangle, whose count assumed 16:9. The revised
draw fits the upright picture into its cell, applying the same fractional crop and pixel aspect as the player.
Cell count now uses the picture's aspect. Cached hover enlargement passes input through and performs no decoding.
Automatic crop completion refreshes the timeline even while paused. Portrait (9:16) and wide (2.35:1) circle
fixtures retain circular shapes in both the strip and enlargement; screenshots inspected in the offscreen bench.

The sequential film loader incorrectly inherited the pointer preview's network dwell for **every** thumbnail,
although the view had already settled the entire batch. Measured on the same M4 Max with the local H.264 fixture,
320-pixel thumbnails and a forced network policy (this measures scheduling overhead, not real NAS bandwidth):

| Elapsed from loader request | Before | After |
|---|---:|---:|
| First image | 351.061 ms | 71.645 ms |
| Second image | 615.564 ms | 75.776 ms |
| Third image | 949.554 ms | 79.500 ms |

The pre-fix batch assertion failed: first-to-third exceeded 250 ms. It passes after removing the redundant dwell.
The serial utility decoder, pending cap and foreground gating are unchanged. The view now uses the existing
network policy's delay once per visible batch (250 ms on network volumes, zero locally).

```sh
.build/debug/FrameScrub --bench-timeline --bench-film-loader \
  --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4" --expect-batch
.build/debug/FrameScrub --bench-timeline --offscreen --shots /tmp/film-shots
```

Offscreen checks passed: aspect fit, cached hover enlargement, seek hit-test passthrough and hiding on exit.
Five rounds of main-thread drawing/layout measured position updates at 0.59 ms p50 in the last round; no
accumulating slowdown. The interactive window was reported occluded in this run, so these follow-up screenshot
checks use explicit cached display, not a claim of live mouse or VoiceOver testing. Intel and real NAS latency
remain unmeasured. Full suite: 1726 tests passed, 20 skipped.

## Follow-up: delivery, input and independent visibility

The viewer now treats playback chrome and film visibility independently. Motion reveals progress/controls;
only entering the stable lower film zone reveals an enabled film. Leave delay is 500 ms; Cmd-L folds/reveals,
Option-Cmd-L persists a pin. Folded and disabled films cancel pending requests. Existing hover previews feed the
film cache. Indexing remains packet/table scanning without decoding.

Offscreen AppKit regression checks passed on the actual view:

- Each delivered thumbnail clears `needsDisplay` by painting immediately, without injecting an input event.
- Playback reveal alone leaves film folded; zone entry opens it and exit folds within 600 ms.
- A pinned film stays after leaving; folding a restored persistent pin updates height immediately.
- A 2 pt drag jitter clicks the selected cell once rather than seeking relative to the centre.
- Clicking the enlarged picture above the normal film bounds still selects that picture's sample time.
- Releasing a real drag outside the film rearms hiding.
- Vertical wheel emits keyframe steps; ten horizontal wheel events accumulate distinct time targets.
- Disabling film prevents edge reveal. Existing aspect, hover and input passthrough assertions still pass.

Mouse activity and redraw checks are synthetic AppKit events/cached display, not a claim of hardware-wheel,
Intel or VoiceOver testing. Five rounds: position update p50 0.532 ms / p99 0.609 ms in the last round; no
accumulation. Full test suite passed: 1726 tests, 20 skipped. A focused review found persisted-pin layout and
release-outside hiding issues; both fixes have explicit regression assertions.

Top overlays now clear the normal window's `contentLayoutRect` as well as the floating full-screen titlebar,
subtracting any top inset already supplied by side slots. Showing a message updates its constraints immediately;
animation remains for deliberate back-button/titlebar moves. Live fullscreen visual verification remains pending.

## Autoplay starvation and ordinary viewing

User narrowed the remaining delay to opening a file with immediate playback: pausing made the film fill. The
cause was an explicit `paused` gate in the view and controller, not a failure to paint a completed image.
The earlier `needsDisplay` assertion did not exercise autoplay and therefore did not cover this condition.

Film requests are now allowed during playback. One utility decoder waits while the current/next playback frame
is missing; it retains its pending work and retries on a real display-frame callback, without polling or requiring
mouse input. Completed pictures remain in the bounded display cache even when playback moved the samples.
Updates replace the latest pending sample list without restarting its 250 ms network dwell every video frame.
Duplicate pending entries for a completed picture are removed. A hidden/disabled film still cancels its queue.

```sh
.build/debug/FrameScrub --bench-timeline --bench-playing-film \
  --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
.build/debug/FrameScrub --bench-timeline --bench-film-loader --expect-resume --expect-batch \
  --fixture "$PWD/Tests/Fixtures/h264_cfr_gop250.mp4"
```

The first command runs the actual PlayerCore with autoplay, its playback cache/filler and the actual film loader
for three seconds, advancing the playhead without mouse events or a pause. It uses a controlled visible NSWindow
for repeatability when the desktop is covered by the calling app. First thumbnail: 277.9 ms, another at 284.2 ms;
the third GOP becomes a displayed sample later in playback and arrived at 2127.9 ms. Playback advanced throughout.
This is a local H.264 fixture with forced network scheduling policy, not real NAS bandwidth or physical screen QA.
The second command verifies zero images while foreground work blocks reads, then all three after explicit resume.
The normal UI bench also verifies inverted vertical mouse direction and the scroll-began pause callback.

Forward viewing already had a bounded lookahead (at most two seconds) and no backward filler, but fitting all
marked regions in memory bypassed that restraint and eagerly filled distant scrub regions. That work now waits
for pause/scrubbing; just-in-time next-region start prefetch remains. Decoder threads start only after the restored
position and autoplay mode are selected. H.264 fixture, 1 GiB cache budget, focus frame 110, regions 100–130 and
300–330, same M4 Max, settled for 300 ms after the current playback window became ready:

| Cached work while playing | Before | After |
|---|---:|---:|
| Decoded frames retained | 212 | 21 |
| Forward seeks | 3 | 1 |

The regression failed before the change because frame 300 was already cached; it passes now and verifies that
pausing subsequently fills 250–330. Full suite: 1727 tests passed, 20 skipped. A fresh focused review found no
important issue in the changed scheduling/lifecycle paths. Intel, heavy-codec and real NAS measurements remain open.

## Adaptive density and lens controls

The lens now exposes time scale, focus width and crop strength in a lazy native three-slider popover, with reset
and persisted values. `TimelineFilmLayout` uses the local time derivative to narrow cells, preserving the full
central picture. Painting, requests, click/hover selection and captured drag all consume the same layout; hover
shows the full image. Six core tests cover actual added cells, centre preservation, stronger cropping nearer the
centre, contiguous packing/hit samples, bounds through 8192 pt, focus parameters, invalid input and empty regions.

Actual AppKit view, same M4 Max, 900 pt window / 64 pt film / 16:9 picture, 50 updates where applicable:

| Setting/action | Result / main-thread CPU p50 / p99 |
|---|---:|
| Crop 0% | 9 cells; image arrival 0.988 / 2.383 ms |
| Crop 70% | 28 cells; image arrival 1.019 / 1.479 ms |
| Crop 100% | 31 cells; image arrival 1.026 / 1.175 ms |
| 2560 pt / portrait / maximum 65 slots | update 3.480 / 4.299 ms |
| Live settings including changed-value persistence, 65 slots | 3.540 / 3.955 ms |
| First native panel creation | 14.792 ms |

Five normal/narrow/return rounds showed no accumulating cost. Portrait, ultrawide and three crop strengths were
inspected in cached-display PNGs; circle patterns distinguish cropping from aspect distortion. An independent
review found stale enlarged-hit selection after Option-scroll; the hover now updates immediately and a synthetic
input assertion checks its new time without mouse movement. Full suite: 1733 tests passed, 20 skipped.

The visible limit is 65, checked in the wide portrait case above; pending times share that cap. Display cache is
two screenfuls (130 pictures), provider cache remains 200 and decoder concurrency remains one. The layout is
cached by geometry/parameters/position, not rebuilt for each cell. There are no new idle timers or animations.
Actual PlayerCore autoplay without input delivered all three fixture GOPs at 275.7 / 283.6 / 290.1 ms under the
forced 250 ms network dwell, so adaptive density preserves progressive filling during playback. These are
controlled local fixtures / cached display, not Intel or real NAS measurements.

## Stable film and three projections

Sample selection is now independent of the moving projection. Whole File Lens and Whole File share a fixed
whole-file grid. A compact C1 polynomial lens moves over that grid; outside its interval the mapping is exactly
unchanged. Segment uses fixed absolute multiples of its time step and moves these pictures through a central
lens. No existing cell changes sampled time during playback. Gesture input captures its inverse projection;
drawing follows current geometry, so new pictures grow through the middle instead of translating an old enlarged
cell and rebuilding it on release. The on-film three-way capsule and context choices persist view without seeking.

Eight layout tests cover stable IDs/times, unchanged remote geometry, shared overview images, smooth shared-ID
movement in Segment, monotonic/inverse mapping, contiguous bounded hit targets, density and exhausted regions.
AppKit checks exercise mode selection without seeking, holding reveal over the capsule, and nine colour-coded
motion screenshots (three successive positions per mode). The whole-file pictures stay fixed as magnification
moves; Segment's same coloured pictures traverse the centre. The old aspect/hover/drag/scroll checks still pass.

Autoplay integration delivered exactly three images (0 / 8.333 / 16.667 s GOPs) at 267.4 / 282.1 / 289.5 ms,
with no repeat delivery over three seconds, no pause and no mouse input. Switching through all views at the end
left player position and playing state unchanged. This uses the local H.264 fixture and forced 250 ms network
scheduling delay, not a NAS latency claim.

Same M4 Max, actual AppKit view/cached display: five rounds did not accumulate cost; the maximum 65-slot case
measured 2.926 ms p50 / 3.715 ms p99, live settings 2.926 / 3.143 ms, first lens panel 12.476 ms. At 900 pt / 64 pt
film, crop 0 / 70 / 100% now gives 8 / 21 / 27 stable samples; this supersedes the previous adaptive per-frame
resampling counts. The 65-visible / 130-display-cache / one-decoder bounds remain. Full suite: 1735 tests passed,
20 skipped. A fresh focused read-only review found no issue. Intel, physical-screen motion and real NAS checks
remain unmeasured.

## Independent lens dropdown and edge control access

Magnification and lens-area width no longer derive from thumbnail density. Density selects the stable baseline
grid; crop controls only the source-picture crop/fit blend, and the time step applies only to Segment. Three added
core tests check independence, unchanged sample IDs/times for strength/area/crop, and inverse mapping at parameter
extremes. Full suite: 1738 tests passed, 20 skipped; focused post-review checks: 28 passed.

The sliders button is part of the on-film view capsule. It opens one retained five-slider native popover, with
compact-window layout and no current-time label overlap. Actual AppKit CPU measurements on the same M4 Max:

| Action | Main-thread CPU |
|---|---:|
| First construction of the five-row content | 18.472 ms |
| First native dropdown open | 36.894 ms |
| Nine returns (opens 2–10) | 4.904–17.120 ms, no accumulating growth |
| Live saved settings, p50 / p99, 65 cells | 3.464 / 4.339 ms |

Edge checks reveal both end pictures, assert the enlarged rectangle intersects neither transport capsule nor the
view capsule, and hit-test every actual transport button. Moving directly from each edge image into a button
hides the hover. Controls are also above the hover in subview order and checked first by hit testing, so pointer
access does not depend solely on positioning. A focused review found missing hide rearming on dropdown close;
the callback now rearms hiding before notifying the host.

The actual PlayerCore/film-loader autoplay bench changed magnification from 1 to 3.8 and area from 8 to 75%:
the initial three thumbnail deliveries stayed at three. After deliberately clearing only the view cache with the
dropdown still open, a cached picture was delivered again. Visibility holding and thumbnail-work gating are now
separate: the dropdown stays open while live density previews fill, but scrubbing and foreground starvation still
defer reads. The existing 65 visible / 130 display-cache / 200 provider-cache / one utility decoder bounds remain.
These are controlled AppKit/local-fixture checks, not Intel, physical-mouse or real NAS verification.


## Smooth shoulders and navigation through displayed samples

The old compact displacement had a negative derivative contribution in its shoulders: in the regression fixture,
cell widths fell to 7.78 pt before widening again to 18.10 and 21.83 pt outside. The replacement integrates a positive
raised-cosine magnification profile and normalises the viewport uniformly. Width falls monotonically from the
central lens to a uniform outside density. It preserves sample identities, bounded cell count and inverse seeking.

Normal mouse-wheel input now selects adjacent loaded, displayed sample times, skipping unavailable pictures and
stopping at the visible ends. Frame-duration tolerance recognises a sample after video-frame rounding. Vertical
mouse direction remains inverted; Option changes density/step and horizontal precise trackpad input remains
continuous. Sample selection pauses playback once per gesture, including when Option is released mid-gesture.
A 140 ms ease-out animates only projection geometry using existing images. Its timer stops at completion, hide,
mode/settings change, unrelated seek or cancellation; Reduce Motion skips it. Thumbnail requests wait for scroll rest.

Three added regression tests cover monotonic shoulders, loaded-sample navigation/endpoints, and frame rounding.
Full suite: **1741 tests passed, 20 skipped**. The actual AppKit bench asserts mouse targets belong to displayed
samples, no repeated endpoint seeks, inverted direction, and Option-to-seek pause. Native cached-display shots
confirm uniform shoulders. Before the release build, main-thread CPU at 65 cells was p50/p99 2.497/3.609 ms; live
lens settings 2.684/3.788 ms on the same M4 Max. Existing five-round layout/reveal checks and control hit tests pass.

The actual PlayerCore/local-fixture bench delivered all three pictures during uninterrupted playback in
267.5–280.0 ms. A synthetic wheel event then paused, selected a rendered sample and finished the transition within
300 ms, with no additional thumbnail deliveries. A focused read-only review caught the Option-to-seek pause case;
it now has an AppKit regression assertion. Hardware mouse, Intel and real NAS remain unmeasured.


## Hidden-film idle verification

A completion already in flight may arrive after folding. It now enters the bounded cache without updating hover,
invalidating the view or forcing display while the film is folded, the view is hidden/transparent or the window
is occluded. Playback updates invalidate only if the progress bar or film is shown; the visible progress bar
continues updating normally when the film is folded. Existing hidden request cancellation and decoder visibility
gates remain in force. Reveal displays the cached images normally.

A native, unobscured AppKit run asserts that late delivery leaves `needsDisplay` false, direct playback updates
leave it false with both layers hidden, no nonempty requests arrive during a 350 ms wait, and no motion timer
remains. It also passes hide/hold/popover-resume checks. Five rounds show no accumulation (round-five position
update p50/p99 0.916/1.123 ms on the same M4 Max). Focused core tests: 20 passed. A read-only review checked the
production guards and caught a test helper that consumed invalidation before asserting; the regression now calls
update directly. This is native cached-display/event verification, not hardware input or Intel measurement.
