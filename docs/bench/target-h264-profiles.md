# Target H.264 profiles: changing 4K frames to 6K

2026-11-07, M4 Max 32-GPU-core / 36 GB, macOS 27.2. External standalone experiment using
current DisplayScaler and ArtifactFilterRenderer sources. No player runtime or default changes.
Companion to [Filter Lab](player-filter-lab.md).

## Inputs and controls

[UVG dataset](https://ultravideo.fi/dataset.html), Mercat, Viitanen, Vanne, ACM MMSys 2020:
Beauty (face, skin and moving hair), Bosphorus (vessel, water and panning), SunBath (moving
foliage, bright soft background and gradients). Digiturk copyright / CC BY-NC; retain notices.
Research media remain outside the repository and app bundle.

Beauty/Bosphorus use the downloadable 8-bit 4:2:0 HEVC variants, already compressed, not camera
truth. Their stated 120-fps cadence is supplied explicitly because the raw elementary stream
has no useful container timing. Select uniformly spaced frames to 24/30/60 fps using FFmpeg fps;
no synthesized or repeated frames. SunBath uses the uncompressed 8-bit 4:2:0 raw member of the
archive, all 300 native 50-fps frames. Extract only *.yuv: the archive also contains a copyright
file, so blindly concatenating all members to stdout adds 249 invalid trailing bytes.

libx264 veryfast, two-pass target ABR, threads2, maxrate1.5x target, buffer2x target, GOP2s,
scenecut0, BT709 output options, no scaling. ffprobe reports limited range and BT709 matrix;
primaries/transfer are unspecified in these streams despite the requested options. These settings are one controlled encoder configuration,
not a model of every downloaded file. The paired reference uses QP0 lossless storage of the
same decoded/selected YUV frames AFTER the common FFmpeg output colour normalization. The
BT709 output options caused an automatic transform for untagged sources; merely decoding
the original without those options does not match. Frame-MD5 verification must reproduce
that normalization before comparing Beauty HEVC or SunBath raw frames with their controls. SunBath is the
stronger reference for compression restoration; Beauty retains the initial HEVC damage.

| Clip | Frames | Actual fps | Video Mbit/s |
|---|---:|---:|---:|
| beauty-24fps-32M | 120 | 24/1 | 31.976 |
| beauty-30fps-32M | 150 | 30/1 | 31.898 |
| beauty-60fps-32M | 300 | 60/1 | 32.025 |
| bosphorus-60fps-32M | 300 | 60/1 | 31.959 |
| sunbath-50fps-10M | 300 | 50/1 | 10.104 |
| sunbath-50fps-15M | 300 | 50/1 | 14.997 |
| sunbath-50fps-20M | 300 | 50/1 | 19.890 |
| sunbath-50fps-32M | 300 | 50/1 | 31.702 |

## GPU method and results

AVAssetReader provides changing 4K bi-planar decoded buffers. Each frame is converted by CI
and processed through the actual DisplayScaler, MetalFX perceptual output 6144x3456,
sharpen0, LL off. Five independent scalers are reused, one GPU command buffer in flight,
fixed profile order per frame. Deband/chroma precede MetalFX; AR follows it. First10 frames
per clip are warmup, all remaining frames timed. Reported time is GPU execution, including CI
conversion and the scaler/filter stages, excluding decode, PNG readback/encoding, drawable
composition and physical presentation. CPU submit/wait times are retained separately in JSON.
Three PNG frames (first/middle/last) per profile are saved outside the timed region.

Window: strength.5, threshold9 RGB8 codes, radius24 input pixels, one iteration, texture
protection1. Chroma: bilateral3 strength.35. AR: coherent-edge strength1. Combined enables
these three together; it is not the menu's older Combined Mild preset. Dither off.

Codecs/preparation finished before the final target runs. Early 24/30/60 reports were replaced
by later serial runs; earlier 30/60 JSON is retained for audit. No controlled thermal/frequency
state or realtime pacing. The bench processes all five alternatives per input frame, so it
is not a wall-clock playback-speed test. P95 includes scheduling variability; do not infer a
cause from these data alone.

Values are median / P95 milliseconds for the whole CI + scale + filter GPU command buffer.

| Clip | Off | Window | Chroma3 | Post AR | Combined |
|---|---:|---:|---:|---:|---:|
| beauty-24fps-32M | 1.79 / 1.88 | 3.23 / 3.52 | 2.43 / 2.59 | 2.89 / 3.19 | 4.97 / 5.33 |
| beauty-30fps-32M | 1.79 / 2.34 | 3.23 / 4.37 | 2.44 / 3.20 | 2.90 / 3.57 | 4.96 / 6.17 |
| beauty-60fps-32M | 1.80 / 3.24 | 3.27 / 5.98 | 2.45 / 4.27 | 2.91 / 4.27 | 5.03 / 8.24 |
| bosphorus-60fps-32M | 1.78 / 1.84 | 3.33 / 3.42 | 2.42 / 2.50 | 2.89 / 2.98 | 5.08 / 5.19 |
| sunbath-50fps-10M | 1.76 / 1.82 | 3.25 / 3.39 | 2.40 / 2.49 | 2.86 / 3.04 | 4.98 / 5.17 |
| sunbath-50fps-15M | 1.76 / 2.10 | 3.25 / 4.10 | 2.40 / 2.83 | 2.87 / 3.20 | 5.00 / 5.91 |
| sunbath-50fps-20M | 1.77 / 2.00 | 3.27 / 3.70 | 2.41 / 2.79 | 2.87 / 3.20 | 5.01 / 5.77 |
| sunbath-50fps-32M | 1.77 / 1.83 | 3.27 / 3.43 | 2.41 / 2.51 | 2.88 / 3.01 | 5.02 / 5.17 |

Across these scenes combined median is about5ms, versus about1.8ms baseline. The 50/60-fps
frame periods (20/16.67ms) belong to the whole player pipeline. These results establish a
plausible GPU allowance, not sustained playback deadlines or absence of dropped frames.
Filter scratch alone is 133,693,440bytes for pre-only profiles, 339,738,624bytes for post-only,
473,432,064bytes combined; source/MetalFX output allocations and other caches are additional.
The five-scaler offline bench uses more memory than one presentation path in the app.

## Spatial quality checks

Compare three matched 6K PNG frames against MetalFX of the paired reference, same pipeline,
same source timestamps and colour handling. This tests how filtering affects distance from
the pre-H264 reference after scaling. It does not provide an ideal artifact-free 6K image:
MetalFX artifacts can also exist in the reference. In particular this error is insufficient
for judging AR quality. Global MAE mixes noise, desired detail and structured artifacts and
is not a perceptual or temporal score. Percentages below are mean relative MAE reductions
across the three saved frames; positive is closer to the reference.

| Case | Baseline RGB8 MAE | Window improvement | Chroma3 improvement | Combined improvement |
|---|---:|---:|---:|---:|
| beauty60 | 2.0096 | -0.10% | +0.15% | +0.04% |
| sunbath10 | 2.3981 | +2.33% | +0.15% | +2.50% |
| sunbath15 | 1.9979 | +2.19% | +0.17% | +2.34% |
| sunbath20 | 1.8024 | +1.83% | +0.22% | +1.99% |
| sunbath32 | 1.6055 | +1.30% | +0.42% | +1.51% |

Native output crops of Beauty cheek/hair boundary and SunBath foliage/background were inspected.
Window softens small patchiness/steps; the intervention is subtle, and source blur/missing
texture remain. Chroma and AR effects at these mild settings are smaller. Global Beauty MAE
is essentially unchanged. SunBath gains are modest, larger at lower rates. No blinded normal-
distance viewer test, motion-compensated flicker score or skin-detail restoration claim.
Three still frames cannot rule out pumping or moving-edge artifacts.

Recommendation: retain independent optional controls. Window is a useful gradient candidate;
these data do not justify a universal combined enhancement default or stronger global blur.
The next quality decision needs normal-distance motion A/B on the user's 6K screen. Distinguish
source patchiness from MetalFX overshoot before changing the post filter. A bitrate alone does
not select strength. The ready test set contains only the eight target clips, excluding
QP0 controls (~1Gbit/s) and raw media so automatic folder playback cannot accidentally benchmark
those as the target workload.

## Reproduction and artifacts

The external research workspace holds sources.json, source-verification.json,
quality.json, per-clip ffprobe JSON, encoder logs, report.json per result directory, full6K PNGs,
TargetProfileProbe.swift and preparation/quality scripts. Probe compiles with the current seven
core display/filter source files plus its local ScaleMode declaration; no substitute shader.
Source copyright is retained separately. The test set contains filesystem hard links to the eight
encoded targets without duplicate media storage.

Lab2 UI smoke: Beauty H264 3840x2160 60fps 32Mbit/s opened through VideoToolbox, window filtering
and A/B status verified paused. Playback started and advanced to the next short clip before
pause; this is not a sustained-rate measurement. Player auto-crop can change fitted dimensions;
the standalone measurements deliberately use full6144x3456. No product code changed for this
experiment, so product tests/build were not rerun. No commit or package change.
