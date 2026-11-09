# Playback pipeline diagnostics (experimental)

Set `FRAMESCRUB_PIPELINE_REPORT` to an absolute JSON file path before launching the app. Diagnostics are off when
unset. A utility writer replaces the report atomically after five seconds of activity and flushes on ordinary quit.
No frame images, media names, media paths or user preset names are recorded. Source media are unchanged.

Samples are bounded: the most recent 2048 values per metric in the last 16 configuration groups. Count, mean,
maximum and over20 cover all observations for each retained group; P50/P95 describe the retained recent samples.
`over20` is meaningful as a 50 FPS work-budget check only for metrics in milliseconds, not counters or frame lag.
Startup, compilation, seeks, fades and setting changes are included; use separate warmed runs for steady-state claims.

## Measurements

- `decoder.forward.hardware/ software`, `decoder.reverse.*`, `decoder.preview.*`, `decoder.other.*`:
  `next_frame_work_ms` includes demux/read/decode and any seek pre-roll inside `nextFrame`. Decoding can run ahead
  into the cache; this is not synchronous work performed for every displayed frame. Seek calls outside `nextFrame`
  are excluded (the preview's `seek_decode_ms` includes its seek).
- Rendering groups identify play/pause, effect, clean-edge setting, actual mask type/width, source dimensions and
  drawable dimensions. Source 4K does not imply a 4K drawable. Groups can combine files with the same configuration.
- `mask_work_ms` is the complete mask worker operation (including optional subject selection), `mask_queue_ms`
  is queue/coalescing wait. `mask_lag_frames` is zero for the frame's own mask. A mask from a higher frame number
  is counted separately, not clamped into an apparent own-frame mask.
- `effect_graph_build_ms` measures wall time constructing lazy Core Image graphs, **not** effect execution. `render_gpu_ms`
  includes the complete GPU composition, scaling and effects; it does not isolate one filter. `render_encode_wall_ms`
  includes drawable acquisition and command encoding. No extra GPU waits or intermediate renders are inserted.
- `arrival_to_present_ms` runs from delivery to `VideoView` to `MTLDrawable.presentedTime`, not command submission.
  It includes scheduling/vsync and is a latency, not a per-frame work cost. These values must not be added to decoder,
  mask and GPU times: those stages overlap. `presentation_interval_ms` counts first presentations of distinct
  delivered frames; repeated redraws and late callbacks are excluded. Pause/resume resets the interval boundary.
- `replaced_before_submit` counts delivered frames overwritten before command submission. `source_gap_frames`
  reports gaps before the view: seeks and speed changes can cause them, so they are not automatically render drops.
- Preview groups separate request queue, read throttle, decoder open, seek/decode, thumbnail render, main-queue
  delivery and UI update. `request_to_ui_ready_ms` ends at view layout, **not** physical screen presentation.

There is no automatic pass/fail for sustained 4K50. Check presentation cadence and missing frames with fixed playback
speed on a display whose refresh rate is recorded separately. A 60 Hz display has alternating 16.7/33.3 ms intervals
for 50 FPS content. A long paused/hidden interval is not a slow filter.

## Reproducible diagnostic controls

- `FRAMESCRUB_FOCUS=black|lens` enables an existing effect on the first frame; omit it for the baseline.
- `FRAMESCRUB_FOCUS_CLEAN_EDGE=0|1` overrides clean edge for this launch without changing its saved setting.
- `FRAMESCRUB_DIAGNOSTIC_SWEEP=1` starts playback and makes 100 hover requests, 50 ms apart, after the first frame.
  It exercises the real request/UI path but does not simulate window-server pointer events. It stops after the sweep.
- `FRAMESCRUB_DIAGNOSTIC_4K=1` requests a 3840×2160 backing drawable at the sweep start; verify actual output dimensions in the report.
- `FRAMESCRUB_DIAGNOSTIC_FOREGROUND=1` brings the test window forward once so an unattended terminal launch measures actual presentation rather than an occluded decoder. Use only during a dedicated GUI bench.
- `FRAMESCRUB_DIAGNOSTIC_SECONDS=15` quits after the bounded duration (5–3600 seconds), only with a report enabled.

The experimental branch uses its normal live mask resolution. This change does not switch models adaptively.

## Hover scheduling

On a network volume `previewSettle` retains its API name but now specifies a **minimum interval between cold reads**.
The first image and cache hits do not wait. A newer queued request after the interval takes the elapsed slot instead
of restarting a debounce. This keeps one worker and limits random reads while allowing images during pointer motion.

For bounded scrub-and-stop experiments, `FRAMESCRUB_FOCUS=none` with
`FRAMESCRUB_FOCUS_SCRUB=4,60` runs the existing wheel-like scrub bench without a subject effect.
`FRAMESCRUB_FOCUS_SCRUB_SECONDS=5` stops it after five seconds (validated 1–60, default 60),
allowing the final paused-frame effect to settle before the diagnostic launch exits.

## 4K source over SMB and audio clock

2026-11-09, MacBook Pro M4 Max, PC adapter negotiated at 2.5 Gb/s.
Two 18-second generated 3840×2160 files, with AAC audio, played directly
from the Windows SMB share. The measured drawable was 1920×1080 and
display presentation intervals showed 60 Hz cadence. Effects were off.
Bit rates below are measured video rates.

| Source | Configuration | Presented frames/s | P95 interval |
|---|---|---:|---:|
| H.264 25 fps, 12.18 Mb/s | SMB, audio | 24.89 | 50.00 ms |
| HEVC 10-bit 60 fps, 32.27 Mb/s | SMB, audio, before clock fix | 51.07 | 33.33 ms |
| Same HEVC source | Local copy with audio, before fix, sampled | 38.61 | 33.33 ms |
| Same HEVC video track | Local, audio removed, before fix | 59.18 | 16.67 ms |
| HEVC 10-bit 60 fps, 32.27 Mb/s | SMB, audio, after clock fix, two debug runs | 58.57–58.78 | 16.67 ms |
| Same HEVC source | SMB, audio, release build | 58.68 | 16.67 ms |
| Separate copy on the PC, first open on the Mac | SMB, audio, release build | 59.08 | 16.67 ms |

On an instrumented run before the fix the display callbacks averaged
16.66 ms. The media clock stepped 21.33 ms on 335 of 590 ticks, while
the video target was already cached. Audio render timestamps led host
time by a median of 11.72 ms. Projecting those samples back to the
current host time removed the buffer-sized jumps. The two corrected
runs still had five and nine source frame gaps over about ten seconds
each. The two release runs had six and four source frame gaps. Hardware
decode P95 was 5.86 ms in the original SMB 60 fps run. The first-open
run used a newly copied file on the share. No global OS cache was flushed.

A real virtual cut then played from the 25 fps file into the 60 fps
file, presented the first frame of the new source in 81 ms, and
accepted twenty rapid seeks across the join. The run does not measure
4K output, effects, sustained playback on Intel, or simultaneous
analysis and playback load.
