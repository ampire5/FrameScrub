# Experimental SDR deblocking

Historical experiment report. The current branch has removed custom deblocking and image SR and is integrating Apple LL display effects; integration status below describes the earlier standalone verification.

This is a disposable experiment on `compression-filters`, not a general restoration pipeline.
View > Deblocking (Experimental) toggles cleanup (Control-Option-D) and a left-original/right-processed comparison.
Settings > Display contains strength, edge threshold, texture protection, block grid and bounded detail sharpening.
Defaults: disabled, strength 0.6, threshold 16/255 perceptual SDR, protection 0.8, 8-pixel grid, sharpening 0.

Two Metal/Core Image directional passes affect only the two pixels on either side of aligned grid boundaries.
A local activity gate protects texture; a jump threshold excludes strong edges. This intentionally cannot distinguish
all weak real edges from compression. Resized/cropped encoded content and variable transform blocks may not match the
selected grid. Four grids (4, 8, 16, 32 native pixels) are exposed for visual experimentation; no codec-grid inference.
It is not debanding, temporal denoising or recovery of detail already removed by compression.

The lazy graph runs before Subject Focus, colour and scaling, without a new decoder or frame queue. Masks retain
original inputs. A utility task creates and warms both Metal render variants before publishing them. The original
remains visible while loading. HDR display and GPUs without dynamic-library support bypass it. Only effective
ready SDR processing bypasses neural paused-frame display and suppresses otherwise discarded still enhancement;
turning it off restores the normal still path. Saved/exported frames remain unchanged. On pause, only setting changes
or the one readiness delivery request another render; no filter timer is introduced.

## GPU measurements

2026-11-06, Apple M4 Max, macOS 27.2, release standalone Swift helper. Deterministic resident SDR input with an
8-pixel block pattern and smooth ramp. Same output size, rgba16Float texture, CI output in extended linear Display P3.
One command buffer in flight, 8 warmups then 30 renders per configuration. No decoder, mask, scaler, drawable,
presentation or audio. These are GPU execution times, not end-to-end playback guarantees. Other applications were
running; ordering, pipeline fusion and GPU clocks can affect comparisons. A physical Intel Mac was not measured.

| Input/output | Mode | GPU median ms | GPU P95 ms | CI graph median ms |
|---|---|---:|---:|---:|
| 1920×1080 | bypass | 0.119 | 0.124 | 0.000 |
| 1920×1080 | cleanup | 0.537 | 1.185 | 0.010 |
| 1920×1080 | cleanup + detail 0.3 | 0.561 | 0.812 | 0.011 |
| 3840×2160 | bypass | 0.276 | 0.593 | 0.000 |
| 3840×2160 | cleanup | 0.851 | 2.059 | 0.018 |
| 3840×2160 | cleanup + detail 0.3 | 0.914 | 1.039 | 0.021 |

First render after worker preparation was measured separately: CI encoding wall time at 1080p was 0.551 ms for
cleanup / 0.539 ms with detail; at 4K 0.329 / 1.565 ms. First GPU execution was 5.159 / 0.539 ms at 1080p and
0.885 / 0.895 ms at 4K. The worker preparation took 24 ms with driver compilation caches already populated;
the first earlier prototype compilation took 332 ms. The worker timing is not a fresh-install cold-start claim.

Reproduce (choose an output path outside the repository):

```sh
swiftc -O -num-threads 4 -parse-as-library Sources/FrameScrubCore/DeblockFilter.swift scripts/bench/deblocking.swift -o /absolute/path/deblock-bench
/absolute/path/deblock-bench
```

The helper waits for GPU completion only in its standalone process; playback adds no wait. Existing pipeline
reports now separate deblock configurations, including pending/unavailable and HDR bypass. For real playback compare
fixed source/output dimensions, original versus processed, mask off/on and presentation cadence separately.

## Controls and verification

Real-window debug `FrameScrubBench settings --rounds 3 --settle 150 --start display`, same M4 Max:
window opened on Display in 234 ms main-thread CPU; Display first switch 21 ms, later median/max 19/19 ms.
Round CPU totals 267, 156, 148 ms (no accumulation); one existing setting change 17–19 ms; rest 4 ms over 2 s.
This measures the expanded real page, not each new control individually, and is not a physical Intel measurement.

Six filter tests cover disabled identity, weak horizontal/vertical boundaries, strong edges, flat fields,
texture protection, comparison/nonzero extent and config validation/round-trip. Related config/settings tests
also check reference completeness, store round-trips, choice validity and page metadata.

`FRAMESCRUB_CONFIG_DIR` can select a separate absolute configuration directory for an experimental app launch.
Normal launches keep the standard directory. No models or user media are shipped by this change.

## Follow-up quality check: initial filter is insufficient

2026-11-06: the user reported no visible cleanup and a frozen displayed image while frame counters continued.
The initial synthetic edge tests were insufficient evidence of useful compression restoration.

A public test clip from Apple's WWDC25 VideoToolbox sample (`FRC.mov`) was reduced to 960×540, six seconds, and
compressed with H.264 QP 46, AQ/psy and in-loop deblocking disabled. All variants were decoded and rendered through
the same Core Image RGB path and stored losslessly for full-sequence RGB PSNR/SSIM against the clean reference.
No sharpening was used. The strong profiles used strength 1, threshold 64/255 and protection 0.

| Variant | RGB PSNR dB | RGB SSIM |
|---|---:|---:|
| Compressed, unfiltered | 24.871280 | 0.594446 |
| Default filter | 24.880772 | 0.595321 |
| Strong, 4-pixel grid | 25.067701 | 0.604168 |
| Strong, 8-pixel grid | 24.976128 | 0.599101 |
| Strong, 16-pixel grid | 24.933880 | 0.597355 |
| Strong, 32-pixel grid | 24.902503 | 0.595937 |

The default improvement is only 0.009492 dB; even the strongest selected variant adds 0.196421 dB. Block structure
remains clearly visible. This does not demonstrate useful general deblocking and does not justify retaining the
initial algorithm as a finished feature. These metrics are evidence from one controlled degradation, not universal
perceptual quality measures. The reference's system-decodable ProRes copy adds a minor preparation error.

Presentation was investigated separately. Serial same-command-buffer MetalFX output and multiple IOSurface-backed
NV12 frames in flight pass readback tests. Bounded live diagnostics at a 6144×3172 drawable recorded continued
presentation with the filter, including three toggles. GPU output-patch hashes also changed, so callbacks alone were
not the only evidence. The user's live frozen-image state has not been reproduced or fixed by these fresh launches.

Optional diagnostic switches (both require `FRAMESCRUB_PIPELINE_REPORT`):
- `FRAMESCRUB_DIAGNOSTIC_DEBLOCK_TOGGLE=1`: toggle at 3, 6 and 9 seconds only.
- `FRAMESCRUB_DIAGNOSTIC_OUTPUT_PROBE=1`: blit five 8×8 rgba16Float patches into a 10 KiB shared buffer per drawable,
  hash only initialized bytes after completion and record hash/change metrics. It saves no images; it is off normally.
Use the existing bounded diagnostic duration and an isolated config directory for these experiments.
