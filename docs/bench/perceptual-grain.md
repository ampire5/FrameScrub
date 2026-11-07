# Adaptive perceptual grain

2026-11-07, M4 Max 32 GPU cores / 36GB, macOS 27.2. Experimental player implementation,
default off. Goal: pleasant perceived texture without hiding well-preserved structure.
This is synthetic texture, not recovery of missing image detail or a codec artifact detector.

## Pipeline and controls

Source cleanup (window deband/chroma) → upscale → edge cleanup/dither → existing sharpening
→ perceptual grain → final comparison. Grain-only also works without source cleanup.
HDR and A/B bypass release grain buffers and skip synthesis. Export/decoder/cache ownership
is unchanged. VideoView supplies decoded frame numbers; same-frame redraw/seek reproduces
the same pattern, without timers, frame history, optical flow or additional decoding.

Types: off, white (uncorrelated control), fine and soft. Independent implementation:
Gaussian samples, circular spatial convolution for fine/soft, normalized small template banks,
deterministic random-offset 64px blocks and 4px overlap. Overlap weights are normalized by
their sum of squares to avoid lowering noise variance at seams. This is inspired by the
template/scaling/overlap approach in [AV1 film grain](https://norkin.org/research/film_grain/index.html)
and [AFGS1](https://aomediacodec.github.io/afgs1-spec/); it is not their causal AR generator,
bit-exact algorithm or metadata parser. No reference implementation code was copied.

The quarter-source-resolution R16F mask examines all 4x4 source-pixel phases. Original and
cleaned input contribute opposing-gradient texture activity and edge strength in all RGB
channels, protecting isoluminant colour detail too. Preserved texture/edges reduce grain;
removed weak high-frequency activity increases coverage. Initially smooth input gets a
weaker baseline. This can confuse original fine texture with compression variation; it
does not validate aggressive cleanup or guarantee preservation of every low-contrast detail.

The luminance response fades near black/white. An achromatic correction preserves RGB
channel differences before FP16 rounding; symmetric gamut limits avoid one-sided clipping.
The preset curves are authoring choices, not estimates from an unavailable clean original.

Config defaults:

| Key | Default | Range / meaning |
|---|---:|---|
| artifact-grain | off | off / white / fine / soft |
| artifact-grain-amount | .65 | 0..3 approximate RGB8 RMS before masking/response |
| artifact-grain-size | 1 | .5..4 output pixels |
| artifact-grain-base | .25 | 0..1 baseline in originally smooth input |
| artifact-grain-adaptation | 1 | 0..1; zero is uniform-grain comparison |

View → Experimental Filters has separate type choices and Fine Grain Only / Cleanup + Fine
Grain presets. Presets use amount1, size1.25, baseline.4, adaptation1. The cleanup preset uses
window .5/threshold9/radius24/protection1, bilateral chroma.35 and coherent-edge AR1.
Settings → Display exposes all grain parameters. Existing Option-Command-B bypasses all lab
filters; selecting Grain Off isolates the added grain while retaining cleanup.

## Verification and review

Full tests passed: 1850 Core tests in159 suites, 35 Settings tests in4 suites. Release build
passed in48.88s. Final targeted grain run passed7 tests (including three scaler cases) in3.90s
after adding explicit post-sharpen/changed-pixel assertions; no product changes after full tests.

Checks include flat-region mean/variance, achromatic output and alpha preservation, same/different
seed behavior, source luma/chroma texture protection, all source-pixel parity phases, greater
coverage after removing weak texture, 1x1 input, off release, HDR bypass, MetalFX/Lanczos/bilinear,
split originals and reproducible paused redraw. Constant-interior grain residual is compared
with/without sharpening; transparent finite-image borders are excluded from that order check.

Read-only independent review found two issues; both were reproduced with failing tests and fixed:

- Sparse initial mask sampling missed even/even detail. Final mask checks every source phase.
- Grain-only comparisons cleared/reallocated output scratch each frame. Final path skips an
  inactive post renderer and retains comparison staging. Allocation-counter regression checks
  verify no new allocation on repeated same-size split renders, with/without sharpening.

The packaged app was opened with Lips4K60. Fullscreen stats reported MetalFX + window/chroma/
edge cleanup + fine grain. Menu Grain Off/Fine updated the paused frame's configuration;
seeks to the last frame/back remained responsive. This is not a sustained playback/presentation
benchmark or a blinded assessment of pleasantness. Grain remains deliberately subtle.

## Real-video artifacts

External `perceptual-grain` directory under the existing filter-lab artifact root contains:
three2s RAW-derived UVG nominal10Mbit/s clips' results (Lips60fps, FlowerFocus/FlowerKids50fps),
63 full6144x3456 DisplayP3 PNGs, three verified320-frame-total comparison videos and native crop
sheets. Video columns: reference / H264 / cleanup / cleanup+fine / cleanup+soft. White and
grain-only controls are saved separately as PNGs. See [RAW source provenance](uvg-low-bitrate-stress.md).

All320 frames pass through the exact current DisplayScaler. PNGs at first/middle/last include
the lossless reference passed through MetalFX. Previews are CRF12 diagnostic native6K crops,
not pixel-error measurement inputs; compression can attenuate the deliberately subtle grain.
Use the native app/PNGs when judging subtle grain appearance. Independent checks verify dimensions, frame counts, ICC
profiles and upright orientation against colour-managed reference PNGs. Source hashes and
reproduction scripts accompany `verification.json`.

For example, Lips frame0 cleanup+fine changes14.3% of RGB8 output pixels, with mean absolute
channel change ~.059codes and maximum2codes. Soft changes17.0%, mean~.074codes, maximum2codes.
These rounded snapshot differences confirm a real but subtle effect; they do not score
perceived restoration. FP16 working images contain changes below an RGB8 rounding step.
No MAE/MSE improvement claim is made for intentionally added noise. Normal-distance viewing
and motion preference are still needed to select a default appearance.

## GPU performance

Serial changing-frame AVAssetReader input; rotate profile order, ten warmup frames, no PNG
readback or preview encoder during timing. Full DisplayScaler4K→6144x3456, MetalFX perceptual,
sharpen0, LLoff. GPU time includes CI conversion, cleanup and grain; excludes decode, final
drawable composition and physical presentation. Median / P95, ms:

| Scene | Off | Cleanup | Cleanup + fine | Cleanup + soft | Grain only |
|---|---:|---:|---:|---:|---:|
| Lips |1.80 /1.84 |5.00 /5.58 |7.04 /7.70 |7.03 /7.70 |3.82 /4.45 |
| FlowerFocus |1.79 /1.84 |4.96 /5.59 |7.01 /7.66 |7.00 /7.65 |3.81 /3.89 |
| FlowerKids |1.77 /1.98 |5.02 /5.64 |7.07 /7.19 |7.05 /7.14 |3.79 /3.80 |

Added median GPU work is ~2.0ms. This does not prove sustained50/60fps for the entire player.
These initial figures use a separate full-output grain pass. The common AR+grain path has
since been fused in the player; see the integrated measurements below. Other paths still
use the separate pass.

One scaler adds171,048,960bytes (~163.125MiB): reusable6K output plus quarter-source mask.
Combined cleanup+grain scratch644,481,024bytes (~614.625MiB), excluding scaler input/output,
Core Image, templates and drawable buffers. Nonzero sharpening adds a staging texture; final
comparison may add baseline/sharpened-baseline staging. Those paths are diagnostic/optional
and are not included in the sharpen0 processed-view figures above. Buffers are bounded,
reused and released when grain is bypassed/disabled. Shared template banks are prepared once
off-main with immutable pipelines, not synthesized/uploaded per displayed frame.

## Settings responsiveness

Real release settings window, M4 Max, three rounds with80ms settling, CLOCK_THREAD_CPUTIME_ID:
open on Display201ms; Display first visit15ms, return median/max21ms; group filter edits
including grain28/25/23/28ms. At rest3ms main-thread CPU in2s. Separate Colour first visit155ms
(return median13ms) exceeds the100ms navigation target; this bench does not establish its
cause or fix it. No physical Intel Mac measurement was available.

## Continuing work

Keep the previous filter roadmap: pre-scale artifact cleanup, stronger-but-safe post-MetalFX
halo suppression, then perceptual texture. Off/Auto/On and Shift-save-default remain a separate
unimplemented control/activation task. The new grain adaptation mask is not an automatic
artifact detector and must not be presented as one. Pre-scale grain comparison, perceptual
default selection and sustained-player frame timing also remain experiments.

## Isolated stage profiling and fusion spike

Follow-up on the cost of grain itself. External throwaway profiler, unchanged player/build.
120 Lips4K60 and100 FlowerFocus4K50 frames; ten warmup frames per source. Existing source
cleanup, MetalFX and CI conversion complete before stage timing. Serial completed buffers,
rotated stage order, no simultaneous build/preview encoder. GPU median / P95 ms:

| Stage | Lips | FlowerFocus |
|---|---:|---:|
| Plain6K RGBA16F copy | .909 / .941 | .907 / .943 |
| Copy + simple hash noise | .908 / .939 | .908 / .934 |
| Current correlated grain application | .910 / .940 | .910 / .960 |
| Current adaptive source mask alone | 1.148 /1.369 | 1.154 /1.337 |
| Mask + grain application | 2.059 /2.284 | 2.065 /2.176 |
| Coherent-edge AR alone | 1.089 /1.127 | 1.090 /1.134 |
| Separate AR then grain | 1.990 /2.066 | 1.994 /2.039 |
| Fused AR + grain | 1.092 /1.119 | 1.094 /1.154 |

Grain arithmetic adds no practically significant duration over the copy control in this
experiment. Fusion saves about .90ms versus separate AR/grain and closely matches AR alone.
The current +2ms therefore consists of an avoidable additional full-output pass plus the
adaptive mask. A separate6K RGBA16F read+write has ~340MB logical traffic per frame, ~20.4GB/s
at60fps; this is not a measured physical DRAM rate (caches/compression affect it).

The fused shader uses the same AR and grain operations with explicit intermediate half
rounding. Full6K comparison on the final frame of each clip finds22,784 /26,635 changed FP16
components out of84,934,656, maximum difference .124512 RGB8 codes. It is not bit-identical;
the observed differences are within a half-float rounding step. This only checks two final
frames and does not certify arbitrary-image equality.

This is a sharpen0/dither0 fusion prototype, not a replacement for the player's general path.
Nonzero sharpening still needs grain after sharpening. Further mask optimization should reuse
existing cleanup statistics where possible, retaining every-pixel-phase structure protection;
the achievable saving has not been measured. Fusion may also remove the separate162MiB6K
grain output allocation by reusing an existing post-filter target. No full-player power or
energy measurement was performed, and no new low-overhead build is claimed here.

External `stages` artifacts retain exact instrumented source, timings and comparison counts.
Instrumentation only exposes the existing renderer mask to the standalone fused shader;
the player source and previously delivered app were unchanged by this profiling spike.


## Integrated common-path fusion

The measured AR/grain fusion is now in DisplayScaler for MetalFX + luma/coherent-edge AR,
nonzero grain, sharpen0 and dither0. The shared shader helpers preserve ordering and an
explicit FP16 intermediate boundary. The result uses an existing post-filter target; the
separate grain output/staging is released. Grain-only, non-MetalFX, directional AR, nonzero
sharpening and dither retain the general path, so no blanket all-modes speedup is claimed.

Same changing-frame4K→6K procedure, rotated order, ten warmups, no concurrent build or preview
encoding. GPU median / P95 ms, current integrated path:

| Scene | Cleanup | Cleanup + fine | Cleanup + soft |
|---|---:|---:|---:|
| Lips |4.986 /5.062 |6.121 /6.224 |6.117 /6.194 |
| FlowerFocus |4.949 /5.068 |6.085 /6.182 |6.077 /6.116 |
| FlowerKids |5.019 /5.149 |6.171 /6.296 |6.155 /6.234 |

Every combined-grain profile reports actual fused execution; grain-only reports false and
remains~3.8ms total. Added grain-specific allocation falls from171,048,960 to1,179,648bytes:
162MiB less, with~1.125MiB mask retained. Combined scratch is474,611,712bytes (~452.625MiB),
excluding MetalFX/CI/drawable storage and shared template banks. Compared with cleanup alone,
remaining~1.14ms primarily reflects mask generation. Mask-statistic reuse is still follow-up.

All1851 Core tests /159 suites and35 Settings tests /4 suites passed; release build45.03s.
The new test covers nonconstant RGB edges for both AR modes, fused/separate agreement within
.001 float units, reduced grain allocation and sharpen/dither fallback. Existing tests cover
paused determinism, split/changes, source-pixel phases, HDR and release. Independent read-only
review found no actionable code issue. UI controls did not change; the prior settings bench
remains the UI measurement, not a new run.

Updated external `perceptual-grain-fused` artifacts include63 native6K PNGs and320 verified
preview frames. Eighteen full native RGB8 snapshots compare old/new fine/soft output: maximum
channel difference1code; largest changed-pixel fraction~.107%. These are rounding differences,
not bit-exact equality or a subjective perceptual score. Updated crop sheets show the actual
optimized output; source and parameters match the earlier sample set.

A separate signed optimized lab preserves previous apps/configs. Native UI testing reached
its Open panel with a verified30s4K60 stream-copy loop selected, then the computer-use service
repeatedly timed out, including screenshot/rebind after session reset. Therefore playback and
mouse-wheel scrubbing were **not** verified in the optimized native build. A two-second native
process sample found the main thread predominantly waiting in the normal AppKit run loop;
it does not show a main-thread compute stall, and does not establish the cause of the UI failure.
The existing display path/source and GPU tests support ordinary source-frame scrubbing, but
this UI check remains outstanding. Source-frame scrubbing is distinct from moving zoom/pan's
cheap-transform path and separate hover/filmstrip previews. Temporal-history effects need
separate handling and are not covered by the spatial-grain claim.

Pipeline overlap may reduce latency by decoding a next useful frame while the GPU processes
the current one. It does not remove work or guarantee lower energy use. No extra queues were
added; power, fan behavior and sustained presentation timing remain unmeasured. Optimize
passes, reuse buffers/statistics and bound obsolete scrub work before increasing concurrency.

## Stronger cleanup and grain comparison (2026-11-07)

Parameter-only follow-up; renderer sources and app binaries are unchanged. The previous mild
configuration is backed up outside the repository. Window deband strength increases .5→.8,
threshold 9→12 and radius 24→32; bilateral chroma strength .35→.6. Texture protection stays 1.
Grain changes fine→soft, amount 1→2 RGB8 RMS, size 1.25→1.5 output pixels and baseline .4→.65;
adaptation remains 1, sharpening and dither remain zero. Cleanup stays before MetalFX and
AR/grain after it. This is an experimental comparison, not a new shipping default.

Native checks succeeded in the previous unfused Grain Lab: settings read back, frame steps
forward/back, paused bypass/restore and brief playback advancing frame 3→42 with visible
image change. The optimized app still times out through computer use; its stronger config
is saved but live reload/presentation is unverified. No sustained playback, timeline drag,
energy or thermal claim follows from these checks.

The current fused DisplayScaler was separately measured on changing decoded 4K frames,
output 6144×3456 on M4 Max 32-core GPU. Each frame rotates five profiles; ten warmups excluded.
GPU time includes CI conversion and scaler/filter work, excluding decode, readback/encoding
and final drawable presentation. Median / P95 milliseconds in this same run:

| Scene | Previous mild | Strong cleanup, no grain | Strong cleanup + grain |
|---|---:|---:|---:|
| Lips | 6.719 / 9.501 | 5.572 / 7.615 | 6.769 / 9.613 |
| FlowerFocus | 7.155 / 9.689 | 5.824 / 8.112 | 7.232 / 9.735 |
| FlowerKids | 6.328 / 6.740 | 5.173 / 5.663 | 6.436 / 6.889 |

Stronger combined settings cost .05–.11ms median over mild in this run. Run-to-run variation
precludes treating the difference from earlier tables as a regression. All combined grain
profiles used fusion and retained 1,179,648 grain-specific bytes; total filter scratch stayed
474,611,712 bytes. There is no new pass or allocation from the parameter increase.

External `perceptual-grain-strong` artifacts contain 54 verified native 6K PNGs, 320 preview
frames and four-column native-pixel crop sheets. Profiles separately isolate stronger
cleanup and stronger grain. All change actual rendered pixels; that check is not a quality
score. Visually cleanup reduces small chroma irregularities and grain restores surface
variation, while coarse compression patterns remain. Stronger cleanup can remove genuine
low-contrast detail despite full texture protection. CRF12 preview compression can attenuate
grain; native PNGs and the app are the appearance reference. Source hashes match the prior
fused verification. No product-code change required another build or unit-test run.

Follow-up: [ready-made cleanup and grain candidates](ready-filter-comparison.md) compares
libplacebo-style debanding, actual FFmpeg CPU filters and equal-strength grain styles,
with lossless enlarged phone PNGs and a shortlist of external grain implementations.

## Integrated AV1-style and particle candidates

The two evaluated banks are now selectable in the player as `av1` and `particles`.
Old Off/White/Fine/Soft and global defaults are unchanged. Amount range is0…12.
Explicit Cleanup+AV1/Particles menu presets use Window .8/threshold12/radius32,
bilateral chroma.6, edge AR, grain amount6/size2/base.8/adaptation1. H.274 is not
included. These are authored template adaptations, not full film reconstruction.
Core bundles the exact two131072-byte FP16 banks with provenance/license and a
reproducible offline generator. No synthesis or file reads occur per video frame.

The common fused encoder and general path share explicit bank selection and
dimension-aware sampling. Old128px×4-layer sampling preserves its bit shifts/masks;
new64px×16-layer banks use the evaluated6/12bit shift scheme. Tests cover new config
round-trips/range, visibly nonzero distinct grain, deterministic seeds, texture
protection, all three scalers, HDR/bypass/split and both fused AR modes. Full suite:
1854 Core tests/159 suites and35 Settings tests/4 suites passed. Release42.87s;
fresh read-only review found no actionable issue. Generator reproduces both bank
SHA256s exactly. Standalone signed app includes its Core resource bundle; its loader
has no absolute build-directory fallback and throws if required files are absent.
Standalone preparation of all artifact pipelines and five banks took7.24ms on the
first invocation in one recorded process, then3.28/3.73/3.12ms. This is a warm system/
Metal-cache measurement, not uncached installation startup; preparation remains off-main.

Integrated changing4K→6144×3456 DisplayScaler GPU median/P95 ms, no preview encode
or readback, ten warmups and110/90/90 samples. Decode/presentation excluded:

| Scene | Cleanup | AV1-style | Particles |
|---|---:|---:|---:|
| Lips | 5.019 / 5.150 | 6.166 / 6.332 | 6.166 / 6.340 |
| FlowerFocus | 5.019 / 5.052 | 6.157 / 6.375 | 6.159 / 6.197 |
| FlowerKids | 5.111 / 5.171 | 6.272 / 6.500 | 6.272 / 6.334 |

Both modes actually fuse, retaining the existing1,179,648-byte mask. Six native6K
snapshots (three frames per style) exactly match the earlier external candidate
experiment in saved RGB8 pixels. This does not certify arbitrary input equality.

Native interactive checks on the real6K monitor succeeded: new presets, MetalFX
in fullscreen, paused bypass/restore, forward/back frame steps, seek±10s, particles
playback frame3→73 and AV1 playback73→146 with visibly changing images. The Settings
page shows new choices, accepts amount12 and persists the restored working amount6.
The final app is paused on frame121 with AV1 and Fit to Screen/MetalFX, without a
fullscreen Space. User perception at normal viewing distance remains a taste test.

Initial automation repeatedly timed out in a file panel; the main-thread sample
was predominantly idle in the AppKit event loop. Old lab fullscreen was then exited,
and access/open/menu/playback checks immediately worked. Space/visibility interference
is the practical inference, not an established AppKit/rendering deadlock. Initial
diagnostic runs had zero presentation and are retained as failed/occluded evidence.

Four repeated native diagnostic runs use the real packaged executable, request a
3840×2160 drawable, record output patch hashes and perform100 hover-preview requests.
They are **not** the isolated6K MetalFX timing above. At1:1 the normal scaler can use
Lanczos rather than MetalFX, retaining the general grain path. Startup/previews included:

| Native run | Unique presentations | GPU median/P95 ms | Presentation interval median/P95 ms |
|---|---:|---:|---:|
| AV1 playback,~12s | 699 | 12.012 / 14.474 | 16.667 / 16.667 |
| Particles playback,~12s | 694 | 11.628 / 15.185 | 16.667 / 16.667 |
| AV1 scrub,5s@30 steps/s | 150 | 15.121 / 19.889 | not playback cadence |
| Particles scrub,5s@30 steps/s | 151 | 14.647 / 19.478 | not playback cadence |

Output patches change on every recorded render in these groups. Playback has16/22
intervals above20ms and maxima50/66.7ms; do not call this drop-free sustained60fps.
The source-frame scrub path presents changing results rather than a frozen image.
Moving zoom/pan and separate thumbnails retain the earlier documented exceptions.
No power, fan or sustained thermal measurement was performed.

Updated real Settings bench (M4 Max): opening Display240ms; Display first12ms,
return median11ms; new filter-control batches18/19/19/20ms main-thread CPU. Rounds
406/67/64ms; idle2ms CPU over2s. Unchanged Colour/Performance first visits were163/137ms
total CPU (largest blocks93/38ms); no new accumulating slowdown. Intel unmeasured.

External `grain-integrated` retains exact probes/configs, byte-parity checks,
signed-package manifest, native telemetry, invalid initial runs, review outcome and logs.
Previous experimental applications/configs are retained. No commit or merge performed.
