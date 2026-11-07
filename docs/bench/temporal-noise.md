# Native 4K Temporal Noise experiment

2026-11-07, M4 Max, macOS27.2, release. Native SDR4K and10bit HLG processing succeeded with Apple's
VTTemporalNoiseFilter; no source downscale. Runtime capability query reports160x64..16384x8192, one previous and
two next references. These limits do not establish speed. All sources are public Apple sample footage or neutral
repo fixtures; working media/logs/PNG artifacts remain outside the repo.

## Original continuous mode: negative playback result

Separate visible app runs used3840x2160 inputs/drawables, no masks, strength0.5, previews disabled, bounded GPU
patch probe. Existing bounded hover sweep also ran in playing4K profiles. Worker durations include source/reference
format transfer, session handling and TNF; accepted-result percentiles exclude discarded jobs. Refinement metrics
add waiting/reference/prep time for the same source. Physical display latency is not measured.

| Run | Result |
|---|---|
| Baseline |293source presentations, GPU median0.675ms/P951.167ms |
| TNF continuous SDR |114accepted TNF results; worker median31.08ms/P9532.29ms;293original presentations; **zero processed playback renders**, one final paused processed render |
| Paused first frame |one TNF result, worker34.45ms;119.41ms from request through reference/prep; two GPU renders over8.30s |
| Fast scrub60steps/s for5s |301original presentations; two accepted TNF results (before/after gesture); refinement64.57/99.11ms |
| Continuous HLG |21accepted results, worker31.45ms/P9533.06ms;120original presentations; zero processed playback renders, one paused processed render |

No GPU failure was reported, original-frame patch hashes changed while playing/scrubbing. This disproves useful
continuous4K denoising in the current original-first pipeline at30fps: filtering is too close to the source interval
and the next source replaces the result before its display tick. Accepted-result counts alone would hide this.

## Resulting policy

Default `temporal-noise-mode=paused`: do not run TNF during playback; delay its single replaceable pending request
120ms while paused frames change. Timer closures retain no old input buffers; invalidate/hide/resume cancel delivery.
After stopping, the last frame refines once using cached references. `always` remains an explicit expensive experiment,
not a real-time claim. FI is bypassed while TNF is active; LL SR is independent when TNF is inactive and may follow TNF
on supported SDR inputs. A paused noise-mode hint explains the playback bypass.

Tests exercise delayed replacement/invalidation, playback policy, reference validation, zero/missing-reference
bypass, native4K ownership and native10bit HLG format/metadata. Final policy and debounce were reviewed independently.

## Image quality

Matched frame90 (3seconds), public4K FRC scene. Noise example adds uniform temporally varying noise of strength12,
then H.264 QP18; compression example uses H.264 QP42. Standalone probe uses the same processor with one past/two
future originals, strength0.5/1.0; no additional sharpening/scaling. PNG before/after crops use identical native pixels.

TNF reduced noise in flat sky; adjacent-pixel luma-difference RMS in a fixed256x256 sky crop fell from5.117 to2.336
atstrength0.5 and2.142 atstrength1. This is only a high-frequency noise proxy, not a texture/overall-quality score.
Large compression block structures remained in the QP42 example. The filter is useful for noise reduction after
stopping, but it has not demonstrated strong video deblocking.

Settings bench before the final mode choice: open236ms mainCPU; Display first20ms/return20ms; setting19-21ms;
rounds276/130/116ms; rest4ms mainCPU per2s. No physical Intel measurement. Final controls get a separate final bench.

## Final settled-mode checks

Final release, modepaused, same native4K public footage/fixtures, original-first output:
- Paused noisy4K: one accepted TNF result,251.56ms request-to-refinement including120ms settle/reference/prep; twoGPU renders over8.30s.
- Five seconds of60steps/s scrubbing:301original plus twoprocessed renders (initial/final); accepted refinement185.84/198.47ms; noGPU failures. Obsolete gesture frames did not start continuous noise processing.
- Default-mode playback:240GPU renders over8.18s, zeroTNF worker results; the on-pause hint explains this intentional bypass.
- Final full test suite:1827tests/156suites passed52.969s. An earlier cancellation test used nominal20ms sleeps under a saturated suite, which actually resumed after22s and legitimately allowed80ms timers to run; the test now submits/replaces/invalidates in one actor turn without assuming scheduler speed.
- Final Settings bench: open272ms mainCPU; Display first15ms/return19ms; setting17-19ms; rounds276/117/118ms; rest4ms/2s.

TNF remains a paused-frame noise experiment. The user's next question concerns genuinely fast dedicated deblocking;
see [ready-made candidate measurements](deblock-candidates.md). No claim of strong4K deblocking or realtimeTNF is made.
