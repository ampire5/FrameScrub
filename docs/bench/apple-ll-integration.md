# Apple LL display integration

2026-11-07, M4 Max, macOS 27.2, release build. This is an experimental display path, not an export effect.

## Current behavior

The custom deblock and Apple image SR implementations, settings/menu choices and obsolete tests are removed.
Saved/copied frames use Lanczos. Removed config options are accepted for migration and cannot enable an old model.
Apple LL SR supports off/automatic/1.5/2/4; LL temporal interpolation supports off/2x/4x source frame rate.
The standalone comparison remains in [the earlier report](apple-low-latency-sr.md).

One active processing request and one replaceable pending request; stale deliveries are rejected. Original decoded
frames remain immediately available; late processing does not stop the playback clock. Interpolation uses the next
consecutive cached frame, forward 1x playback and actual index timestamps. Session loading, conversion and processing
are off-main. The existing screen fitter uses separate caches for native originals and LL results. Only actual SR
output bypasses extra sharpening. HDR/unprocessed fallbacks do not replace the normal tone-mapped image.

## Tests and review

Policy tests cover adaptive and explicit factor selection, time phases, playback eligibility, config migration and
invalid values. A queue test holds one operation and verifies pending replacement plus rejection after invalidation.
Real VideoToolbox tests verify retained output dimensions/pixels, both interpolation counts, HDR bypass and native
4K SR fallback. Hardware-dependent processing tests are conditional on Apple API support.

Review found and corrected HDR bypass replacing tone mapping, and fallback unintentionally disabling sharpening.
The follow-up review found no further actionable issue. Final full verification passed 1820 tests in 154 suites (56.707 seconds). The focused hardware/policy/queue
run passed eight tests after adding conditional execution for hardware-dependent processing.

## Real-window measurements

Public footage only: six seconds from Apple's FRC sample, reduced to 960x540 and encoded H.264 QP 34, repeated to
24 seconds. Separate roughly 12-second application runs, SDR, 1920x1080 drawable, original screen sharpening 0.3,
no masks, seek previews disabled. One request at a time. An opt-in five-patch GPU readback confirmed output changes.
Each run exits through normal asynchronous app termination. GPU probe work is included, so this is not a zero-probe
performance claim. First hidden terminal launches had decoding but no presentation; those reports were rejected.
The valid runs explicitly raised the window with `FRAMESCRUB_DIAGNOSTIC_FOREGROUND=1`.

| Mode | Accepted LL results | Worker median / P95 | Intermediates selected |
|---|---:|---:|---:|
| SR x2 | 356 | 5.20 / 5.93 ms | n/a |
| FI x2 | 355 | 8.02 / 9.76 ms | 341 |
| SR x2 + FI x2 | 355 | 15.99 / 17.83 ms | 188 |
| FI x4 | 355 | 17.91 / 20.13 ms | 129 |

Worker times include configuration lookup, buffer acquisition/transfer and all effects for that request, but exclude
screen rendering and discarded requests (including cold session loads). These are accepted-result measurements,
not whole-stream or cold-start percentiles. Intermediates selected counts actual clock-selected images, not guaranteed
physical display refreshes. The source-frame presentation counter remains a source-frame counter.

The baseline submitted/presented 362 distinct source frames; SR x2 presented 356 source frames plus additional LL
renders. No GPU failure was reported in any visible run. Successive patch hashes changed in about 99-100% of the
SR/FI output render samples. This detects frozen output; it does not prove restoration quality or motion accuracy.

FI x2 alone usually supplied one intermediate per source interval. Combined processing and FI x4 missed many phase
deadlines on this setup. These settings are available experimentally; they do not promise a complete 60/120 fps
output. Interpolation is off by default. Frame-scrub accuracy and source clock behavior are unchanged.

### Larger drawable and fallback

With a 3840x2160 drawable: SR x2 takes 960x540 to 1920x1080, then MetalFX fits it to 3840x2160. Accepted worker
median/P95: 3.61/5.48 ms; LL-output screen GPU median/P95: 5.21/6.08 ms. The bounded existing diagnostic hover
sweep also ran in this test (previews disabled), so do not compare its timings directly with the 1080p runs.
344 LL output renders plus 356 native fallback renders changed output without GPU failure.

A paused SR test produced exactly one accepted effect result and two GPU renders over 7.33 seconds: no endless
processing on pause. An unsupported 1920x1080 SR request retained the native source and reported the size/scale
fallback. A separate isolated 4K HLG fixture run reported HDR bypass and rendered through the normal tone-map path.

Runtime capability query: SR factors are [1.5,2,4] at 272x480, [1.5,2] at 960x540, [1.5] at 1280x720, none at
1920x1080 or 3840x2160. Temporal-only FI x2 configurations were accepted at all those sizes, including 4K; this
configuration result alone is not a real-time 4K performance claim. An actual isolated 4K SDR/FI x2 run subsequently
failed processing with VideoToolbox error -12911 ("Processor is not initialized"). The session failure is cached,
original frames keep rendering, and no retry/model-load loop or GPU failure occurred. Thus 4K FI is not advertised
as working on this host despite accepting the configuration. No source is reduced to satisfy model limits.

## Settings-window bench

Real Display page first, three rounds, 150 ms settling between navigation actions:

| Action | Result |
|---|---:|
| Open settings | 238 ms main-thread CPU |
| Display first visit | 22 ms |
| Display returns median/max | 18 / 18 ms |
| Change a setting | 17-19 ms |
| Round totals | 278, 137, 131 ms |
| Rest | 3 ms main CPU / 2 s |

No accumulating navigation cost was observed. This is an Apple Silicon measurement, not a physical Intel Mac bench.
Local logs, lossless comparison outputs and the isolated test app are kept outside the repository.
