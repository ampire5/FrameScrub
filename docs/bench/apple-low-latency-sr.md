# Apple low-latency super resolution: standalone verification

Historical experiment report. The current branch has removed custom deblocking and image SR and is integrating Apple LL display effects; integration status below describes the earlier standalone verification.

Date: 2026-11-07. Machine: M4 Max, macOS 27.2, Xcode 27.2.

## What is actually integrated

Source inspection found no Apple low-latency SR or temporal noise filter in
FrameScrub's playback display path. `MLUpscaler` does already use `VTFrameProcessor` with the
different `VTSuperResolutionScalerConfiguration(inputType: .image, scaleFactor: 4)` for
optional paused-frame enhancement and saving; it is not the low-latency video scaler.
The experiment called Deblocking is the custom `DeblockFilter`,
followed by `DisplayScaler` (MetalFX spatial scaling or Lanczos) and optional luminance
sharpening. Apple effects were previously tested in Apple's separate VideoProcessor sample.
Consequently, there is no observed conflict between Apple's LL SR and MetalFX in FrameScrub:
the former has not been connected. The reported freeze of the custom filter remains unresolved.

Apple explicitly describes low-latency SR as reducing coding artifacts and sharpening edges:
[WWDC25 session 300](https://developer.apple.com/videos/play/wwdc2025/300/).
This supports testing it for compression cleanup; it does not establish removal of every
kind or severity of blocking. Temporal noise filtering is a separate effect.

## Method

A standalone Swift command processes one frame at a time through the real
`VTLowLatencySuperResolutionScalerConfiguration` / `VTFrameProcessor` API, without FrameScrub's
renderer, custom deblocking, masks or still enhancement. It uses configuration-provided source
and destination buffer pools and `VTPixelTransferSession` to satisfy format and extended-pixel
requirements. In particular, 960×540 requests four extended bottom source rows and eight
extended bottom destination rows on this machine. Attachments and timestamps are propagated.

The baselines compile FrameScrub's existing `DisplayScaler`, `ImageScaling` and `ScalerChoice`
sources into the standalone executable: actual MetalFX, not a similarly named FFmpeg filter.
All branches use the same transferred source buffers, ×2 output size, SDR sRGB readback, and
zero additional sharpening. FrameScrub's normal `sharpen` default is 0.3, so the MetalFX branch
here isolates the scaler rather than reproducing every default display setting.

Outputs are saved as lossless FFV1 RGB videos and PNGs. Shareable side-by-side MP4s use H.264
CRF 12, which introduces additional encoding loss; use PNGs/lossless outputs for close inspection.
No user media is used. Sources and generated artifacts are kept outside this repository.

## Clips and observations

| Input | Frames | LL SR output | Observation |
|---|---:|---|---|
| First approximately six seconds of Apple's bundled LLSRS video, 272×480 | 182 | 544×960 | Visible change from Lanczos and MetalFX: cleaner and sharper facial/hair edges, with smoothing of fine skin texture. No pristine reference is available for this clip. |
| Six seconds of Apple's FRC video, reduced to 960×540 and H.264 QP 34 | 180 | 1920×1080 | Different edge/texture reconstruction from MetalFX; residual artifacts remain. This comparison alone does not establish a general quality winner. |
| Same public scene, severe QP 46 with encoder deblocking disabled | 180 | 1920×1080 | Large block structures remain after LL SR. It does not restore this heavily damaged input. |

Every successive output frame differed in all three LL SR runs (181/181, 179/179, 179/179
successive comparisons). MetalFX and Lanczos baselines also produced changing frames. Processing
completed without an API error. This verifies changing output outside the application, not the
resolution of the application's separate presentation freeze.

The frame-90 PNGs use identical crops and native output pixels. The moderate-compression video
uses identical 960×540 crops of each 1920×1080 result; the Apple portrait comparison uses the
complete outputs. Labels identify each column.

## Capabilities observed on this machine

`isSupported = true`; reported min/max input dimensions: 96×96 / 1280×1280.
The dimension-specific query is still required:

| Input size | Reported scale factors |
|---|---|
| 272×480 | 1.5, 2, 4 |
| 960×540 | 1.5, 2 |
| 1280×720 | 1.5 |
| 1920×1080 | none |
| 3840×2160 | none |

These are runtime results for this machine/OS, not universal limits or permission to pre-downscale
1080p/4K footage and discard its detail. They prevent a universal replacement of MetalFX today.

## Timing limits

One sequential effect request in flight; optimized Swift build; first five frames excluded from
warm percentiles. `process(parameters:)` duration only (destination allocation included), excluding
decode, input transfer, RGB readback, file output and physical presentation:

| LL SR input | Session start | Warm median | Warm P95 |
|---|---:|---:|---:|
| Apple 272×480 | 287 ms | 0.50 ms | 0.82 ms |
| Severe 960×540 | 1107 ms | 1.61 ms | 2.76 ms |
| Moderate 960×540 | separate run | 2.68 ms | 2.76 ms |

These short quality runs are not an isolated latency benchmark or sustained playback test; some
runs overlapped other comparison work. MetalFX timings in the raw logs include encoding and an
additional GPU render/wait and therefore must not be ranked against the LL SR timings above.
Session loading must remain off the main thread, as Apple's configuration documentation warns.

## Integration implications

For supported sources, LL SR is a candidate alternative upscaling path, rather than an additional
upscaler before MetalFX. Its discrete output sizes may still require final fitting/downsampling
to the viewport. The current MetalFX/Lanczos path remains necessary for unsupported dimensions,
hardware and formats. LL SR requires only source and destination frames, unlike temporal noise
filtering's neighboring-frame inputs, so its API does not inherently prohibit a single paused
frame or seek result. FrameScrub still needs bounded asynchronous processing, stale-result
rejection on seeks, off-main session startup, and an explicit loading/fallback status before an
integration can be considered verified. No LL SR integration or freeze fix is claimed here.
