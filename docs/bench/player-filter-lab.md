# Player Filter Lab — 2026-11-07

Experimental SDR display filters, retaining MetalFX. The immediate quality target is
banding in large smooth gradients, followed by ringing and chroma noise. This build
provides alternatives for comparison; it does not establish restoration quality on
the user's source video, which is not available.

## Approaches and provenance

These are independent Metal implementations, not literal ports or dependencies.
[libplacebo's options](https://libplacebo.org/options/) provide established precedents
for threshold/radius/iteration-controlled debanding, optional grain and anti-ringing.
The lab uses four opposed, spatially randomized samples, rejecting high-contrast
neighborhoods, with one or two passes. Sampling is fixed between frames to avoid
introducing animated random noise. In the single/double baseline modes, strength controls threshold, radius
and blending together. Adaptive mode separates these controls. Optional fixed dither defaults off.

Anti-ringing limits output luma to the source 2×2 range with a 2/255 tolerance;
the alternative additionally gates correction by a larger coherent-edge neighborhood.
It requires the MetalFX source texture. Chroma alternatives are luma-guided bilateral
3×3/5×5 and component median 3×3, retaining luma. No skin/subject classifier is used.

Debanding's contrast rejection is a local heuristic, not a validated large-region or
artifact detector. Fine low-contrast texture can still be smoothed. Residual grid
patterns, temporal edge crawl and motion stability require real-video evaluation.
No temporal accumulation, motion estimation, ML model or CPU PP7 is included.

## Pipeline and bounds

`DisplayScaler` applies filters after scaling, before existing sharpening. Fit/zoom
and original/Apple-LL settled display paths share asynchronously prepared immutable
compute pipelines. Encoding remains in the existing command buffer with no per-frame
CPU readback. Paused setting changes request a new render. Moving zoom retains the
existing cheap path and refines after settling. HDR bypasses the lab.

Each active scaler owns at most two RGBA16Float scratch textures: 132,710,400 bytes
at 3840×2160, 235,929,600 at 5120×2880. These are scratch costs, not total app memory.
Non-MetalFX paths can also require a baseline render texture. No background polling
or additional frame queue is introduced. Failed pipeline creation falls back and
reports status; it does not retry continuously.

## GPU measurement

Mac M4 Max, 36 GB, macOS 27.2, Xcode 27.2, release `FrameScrubBench filters`.
Three warm-ups and twenty measured submissions per profile on synthetic gradients,
edges and chroma noise. Times are GPU command-buffer time for **MetalFX plus filters**,
excluding CPU upload/readback, decoding, presentation and other application work.
Consequently these numbers are not end-to-end playback or frame-rate guarantees.

| Profile | 1920×1080 → 3840×2160 median / P95 ms | 3840×2160 → 5120×2880 median / P95 ms |
| --- | --- | --- |
| MetalFX only | 0.95 / 2.40 | 1.22 / 1.25 |
| Anti-ring coherent edges | 1.22 / 1.31 | 2.43 / 2.43 |
| Anti-ring local luma | 1.25 / 1.30 | 1.95 / 2.01 |
| Deband single | 1.43 / 1.56 | 2.04 / 2.05 |
| Deband double | 2.28 / 2.65 | 3.18 / 3.18 |
| Chroma bilateral 3×3 | 1.64 / 1.87 | 2.24 / 2.24 |
| Chroma bilateral 5×5 | 2.14 / 2.56 | 3.47 / 3.48 |
| Chroma median 3×3 | 3.34 / 3.34 | 5.97 / 5.98 |
| Combined Mild | 2.05 / 2.05 | 4.13 / 4.14 |
| Combined Mild + split | 2.47 / 2.52 | 4.75 / 4.77 |

Small sample counts and repeated GPU timer values limit precision. The initial baseline
has an outlier; compare repeated runs before interpreting sub-millisecond differences.
Median is the most expensive chroma option here. Begin with single-pass deband alone.

## Checks and controls

Actual GPU tests verify luma bounds, bypass/HDR identity, chroma impulse suppression
with retained luma, split output, constant-image preservation and intermediate gradient
levels. Full suite: 1,832 tests in 158 suites passed. The final menu-only startup fix
was release-built and verified by launching the app; core tests preceded that fix.
Review caught and corrected status selection for zoom. Startup testing caught and
corrected premature preference access while constructing the menu.

Real settings window bench, three rounds: opening on Display 255 ms; Display first
visit 10 ms CPU, return median 9 ms. Filter control changes: 9/7/8/7 ms main-thread
CPU. Round totals 219/59/59 ms, idle 1 ms CPU over two seconds. Screenshot capture
failed in this bench; window/control measurements completed. Intel is unmeasured.

The isolated `FrameScrub Filter Lab.app` has its own bundle identifier and configuration.
View → Experimental Filters offers presets, individual modes, master A/B and split;
Settings → Display has strengths and dither. Manual menu A/B was observed updating
the paused frame's filter status. The assigned Option-Command-B shortcut did not
toggle during automation and remains unverified; use the menu. Split is covered by
GPU tests but its final UI check was interrupted by the Mac locking. No real-video
perceptual quality or freeze-free playback claim follows from the synthetic bench.

For large gradients start with **Preset: Smooth Gradients**, then compare one versus
two passes and reduce strength if texture disappears. Split compares the unfiltered
scaled image on the left with the processed image on the right. Sharpening is zero
in this isolated experiment. Adaptive mode now separates threshold/radius controls; larger-region confidence and
motion behavior remain to be validated before increasing aggression.

## Adaptive/directional iteration

Added `adaptive` deband and `directional` edge cleanup without removing baseline modes.
Adaptive uses cancellation of opposing local RGB gradients to reject alternating texture,
then eight symmetric cardinal samples at two radii with a maximum color-deviation gate.
Borders use symmetric distances, avoiding clamp-induced gradient bending. It has independent
threshold 1–32 RGB8 code units (default 9), radius 1–64 output pixels (default 24), texture
protection 0–1 (default 1) and existing blend 0–1 (default 0.5). These defaults are exploratory,
not values established by a subjective study. A local monotone real detail can still be
mistaken for a band. This is not yet segmentation of large smooth regions.

Directional mode selects one of four local axes and applies constrained primary/secondary
neighbor differences. It runs without a MetalFX source, has a fixed 8/255 contrast threshold,
and uses existing edge strength. No automatic block-grid assumptions or temporal state.

### Source implementations inspected

- [Google BBAND/AdaDeband](https://github.com/google/bband-adaband), Apache-2.0;
  `src/BBAD_I.m`, `src/deband_filter_yuv420p.m`, `src/video_postproc_deband_get_mask.m`,
  `src/video_postproc_deband_frame.m`. The reference uses guided prefiltering, band edge
  linking, connected components, integral images, adaptive window sizes and a temporal
  change constraint. That full MATLAB implementation is **not** ported into this build.
- [libplacebo sampling.c](https://github.com/haasn/libplacebo/blob/master/src/shaders/sampling.c),
  LGPL-2.1-or-later. Its deband compares the center against the sampled average per component;
  the original lab instead rejected large individual-neighbor differences with an RGB
  distance. These algorithms should not be presented as equivalent implementations.
- [AOM CDEF reference](https://aomedia.googlesource.com/aom/+/c9be2a55f8d2de3e1ca3c760eddacc2ad4d7a5cf/av1/common/cdef.h),
  BSD-2-Clause with AOM patent-license notice; constrain function inspected. The lab uses
  independent float math and four per-pixel directions, not AV1's normative integer filter,
  block direction search, codec-signaled strengths or clipping rules.

At the adaptive/directional iteration no source from these implementations had been copied
into the app. The subsequent reference iteration adapts libplacebo code with notices retained. A complete reference implementation remains
valuable as an offline quality baseline.

### Updated measurements

Same machine/setup as above, fresh serial GPU bench (3 warm-ups + 20 samples). Whole
MetalFX + filter command buffer, decode/presentation excluded:

| Profile | 1080p → 4K median / P95 ms | 4K → 5K median / P95 ms |
| --- | --- | --- |
| MetalFX only | 0.947 / 2.394 | 1.110 / 1.112 |
| Adaptive | 1.819 / 2.141 | 2.236 / 2.241 |
| Adaptive, protection disabled | 1.505 / 1.831 | 2.463 / 2.466 |
| Directional | 1.132 / 1.149 | 2.048 / 2.051 |

Protected mode can skip samples on textured pixels; the unprotected profile also exercises
the full sampling path. Noise and the first baseline outlier preclude inferring precise
incremental costs from individual runs. Existing two scratch textures are unchanged.

`FrameScrubBench filter-fixtures <directory>` exports input/single/adaptive/unprotected/
directional PNGs from actual Metal outputs. The 1280×720 fixture has a 6-bit quantized
ramp in its top third, alternating fine color detail in the middle and a large true edge
at the bottom. It is synthetic, not a video or codec reconstruction benchmark.

| Profile | Smooth gradient MAE | Textured region mean change |
| --- | --- | --- |
| Input | 0.003903 | 0 |
| Single baseline | 0.003118 | 0.001606 |
| Adaptive | 0.002503 | 0 |
| Adaptive, protection disabled | 0.002501 | 0.001712 |
| Directional | 0.003708 | 0.002197 |

Adaptive reduces gradient MAE by 35.9% on this fixture while leaving its fine alternating
texture unchanged. This establishes a controlled tradeoff, not general perceptual superiority.
The top/middle region boundary is itself low contrast: maximum changes in the bottom third
include that boundary (adaptive 0.001953), not just the central high-contrast edge. A separate
GPU strong-edge fixture is unchanged. Both new modes pass constant/tiny-input and HDR/zero
master-strength bypass tests. Full suite: 1,837 tests in 158 suites passed, 54.712 seconds.

Real settings bench: Display opening 287 ms CPU; first visit 14 ms, return median 24 ms;
filter controls 24/24/21/24 ms; rounds 248/149/150 ms; idle 3 ms over 2 seconds. This was a
new run, not an isolated before/after attribution. Physical Intel hardware remains unmeasured.

Release built and separate `FrameScrub Filter Lab 2.app` signed/verified, independent config,
MetalFX with sharpening zero and adaptive preset selected. Final interactive launch checking
was blocked by the Mac lock screen; no claim of a verified new-build UI session or motion
quality. Fresh code review found no important issues. Deferred test refinements: isoluminant
chroma-only fixtures and explicit whole-border planar assertions (current plane test covers
interior; constant/tiny-image tests cover boundary safety).

## Reference comparison and corrected pre-scale pipeline

The sections above record earlier experiments. **The current app runs deband/chroma
BEFORE display upscaling, at its input resolution. AR and output dither run AFTER it.**
On Apple LL inputs this means before final screen fitting, after LL processing. Source
cleanup reuses MetalFX's original input texture and feeds its output directly into MetalFX.
Post-scale luma limiting references this cleaned input. Non-MetalFX paths preserve the same
order. A/B bypass skips both stages. Split/changes retain a separately upscaled original;
this extra upscale is only performed when source cleanup and comparison are both active.

Reference mode now adapts the actual `pl_shader_deband` sampling/selection logic, with
LGPL notice, pinned revision and modifications in `third_party/libplacebo`. The app bundle
includes LICENSE/SOURCE and the adapted kernel source; `scripts/make-app.sh` copies notices
before signing. This supersedes the earlier no-source-adaptation statement. Deterministic
lab PRNG reuses an angle/distance factor across iterations and differs from upstream PRNG;
output is not bit-exact libplacebo. Grain is intentionally disabled in the reference preset.
Upstream defaults checked in pinned `sampling.h`: threshold 3/1000, radius16, iterations1,
grain4/1000. Lab reference preset converts the threshold to 0.765 RGB8 codes, strength1,
radius16, one iteration. General threshold range is now 0.1–32; other mode defaults remain9.

Window mode adds a bounded search for a smaller safe radius (max7 halvings for radius64),
then a symmetric 4×4 sample reconstruction with the RGB texture guard. It is an independent
approximation, not the full AdaDeband connected-component algorithm. `Show Changed Pixels`
shows output differences as red heat (saturates at4 RGB8 codes); it is not an artifact mask.

### Quality controls

The same controlled fixture gives gradient MAE0.001617 for window vs0.003903 input: 58.6%
reduction, with zero change to its alternating fine color texture. At the deliberately coarse
6-bit band step, upstream-default reference has almost no effect (MAE0.003908); its threshold
is small relative to this stress case. Strong lab reference (threshold9, blend0.5) reduces
MAE to0.002650 with one iteration and0.002400 with three, but changes textured-region pixels
by0.002655/0.002850 on average. More iterations are not a free quality improvement.

Offline `filter-images` also processed native4K middle frames from OldTownCross/ParkJoy,
clean and H.264 QP34/QP42, using existing public SVT lab material described in
[the 4K bench](algorithmic-deblock-4k.md). All comparisons use the same CI/P3 conversion and
actual GPU outputs. On compressed cases, window reduces global RGB MAE against clean by
0.14–0.69%; adaptive0.08–0.47%; directional0.30–0.88%. Strong lab reference sometimes worsens
error (down to−1.56% for three iterations). Upstream-default reference changes error only
−0.01…+0.10%. On clean frames window mean change is0.000…0.039 RGB8 codes, vs1.035/0.843
codes for strong reference in town/park. These small global changes do not establish local
perceptual effectiveness; no universal deblocking/restoration claim is supported. Input and
window PNGs were inspected; differences are subtle at whole-frame viewing scale.

`filter-order` cross-checks a ParkJoy QP34 frame against clean after the same MetalFX upscale
to6144×3456. Window before scaling reduced output MAE0.695%, after0.617%; median GPU time
was3.13ms before vs5.10ms after. Adaptive before2.46ms vs3.66ms after; chroma2.34ms vs3.26ms.
This is one frame, not a codec/scene-wide conclusion. The primary pipeline benchmark below
is the current budget reference; order cross-check timings are approximate and not an
isolated CPU/system-load study.

### Physical 6K display and actual pipeline budget

System display information confirms Kuycon G32P6144×3456@60Hz (logical3072×1728).
`FrameScrubBench filters-pipeline` calls the actual DisplayScaler (including CI source
render, prefilters, MetalFX and postfilters), serially with3 warm-ups and20 GPU samples.
Final drawable composition/presentation, decode, uploads and other player work are excluded.
Additional sharpening and Apple LL are off. Figures are total GPU time, not filter overhead.

| Profile | 1080p →6K median/P95 ms | 4K →6K median/P95 ms |
| --- | --- | --- |
| MetalFX only |1.69 /3.47 |1.94 /2.48 |
| Reference preset |1.77 /2.29 |2.33 /2.87 |
| Adaptive |1.80 /1.95 |2.50 /2.51 |
| Window |1.81 /1.95 |2.51 /2.53 |
| Window, protection disabled |1.99 /2.54 |3.24 /3.80 |
| Chroma bilateral3 |1.85 /2.03 |2.59 /3.16 |
| Post-scale coherent-edge AR |2.62 /2.79 |3.41 /3.94 |
| Window + bilateral0.35 + AR |2.93 /3.19 |4.67 /5.25 |
| Same + split |5.32 /5.90 |7.37 /7.73 |
| Same + changes heat |5.73 /6.33 |7.72 /8.16 |

The combined row is a custom combination, not the older Combined Mild menu preset (which
retains single-pass deband). The protected synthetic input can skip work; unprotected row
exercises the full sampling path. Baseline warm-up outlier and small timer differences limit
sub-millisecond interpretations. These results support a60Hz experiment, not a guaranteed
end-to-end frame rate or slowest-machine budget.

Source/output renderers each retain at most two stage-size RGBA16Float scratch textures.
Measured pre-only filter scratch at4K is133,693,440bytes vs339,738,624 for6K post scratch;
combined uses473,432,064bytes. **This excludes MetalFX input/output, comparison baseline and
fallback CI input/output textures.** In split/changes with source cleanup a separate6K
baseline adds about169,869,312bytes. It is released when comparison is off. All sizes and
queue counts are bounded; the figures are not total app memory.

### Verification and handoff

Full suite:1,843 tests in158 suites passed (57.355s). After final status propagation/UI-copy
adjustments,75 focused tests in7 suites passed. Functional GPU test first failed with the
post-scale order, then passed for MetalFX/Lanczos/bilinear; it checks pre-scale equality,
unfiltered left split and changed-pixel output. Separate tests now cover isoluminant chroma
texture and planar borders. Fresh review found no ordering, aliasing or lifetime blocker;
pre-stage failure status propagation and architecture/notice updates were completed.

Real Settings bench: opening258ms; Display first23ms, return23ms; filter-control updates
26/28/25/26ms CPU; round totals284/128/137ms, idle5ms over2s. No accumulating slowdown.
Physical Intel is unmeasured. The previous unverified A/B shortcut diagnosis was incorrect:
Option-Command-B works; the stats panel refreshes periodically and can show the previous
render briefly. Current interactive run observed the corrected build on the full6K screen,
3840×2160 H.264 FRC sample, visible split and changes heat on the same paused frame, and
moving playback. This is a smoke test, not a sustained frame-presentation benchmark.

`FrameScrub Filter Lab 2.app` is updated in place with separate config, window preset,
MetalFX/sharpen0, LL off; left open on the public4K sample paused for user testing. All
external fixture outputs/JSON/logs stay in the external research workspace.

## Target input profiles and perceptual reference material

Primary inputs specified for subsequent evaluation: UHD H.264,10–20Mbit/s at50fps;
second profile around32Mbit/s at23–60fps. These are evaluation targets, not datasets already
tested here. Prior QP34/QP42 scenes are stress cases and do not establish these bitrate/fps
profiles. Prepare10/15/20Mbit/s at50fps and32Mbit/s at representative24/30/50/60fps, plus
23fps if present in source material. Keep true source cadence; duplicated/interpolated frames
must not stand in for native50/60fps motion. Include gradients, natural skin with texture,
slow motion of contours and complex texture. Display target remains6144×3456@60Hz.

Bitrate is not an artifact classifier or a valid automatic strength selector: source defects,
encoder decisions, previous generations, scaling and chroma reconstruction must be separated.
Compare decoded source1:1, software/hardware decode when a mismatch is suspected, and final
MetalFX output to locate the stage creating a visible defect. Measure whole-pipeline budget
at50/60fps; frame periods20/16.67ms are not budgets solely for filtering.

Primary visual references:
- [Characterizing Perceptual Artifacts in Compressed Video Streams](https://eceweb.uwaterloo.ca/~z70wang/publications/HVEI14.pdf):
  ringing, transform-basis patterns, color bleeding, temporal flicker/floating with illustrations.
- [CFVQA face-video study](https://arxiv.org/html/2304.07056v3): spatial/temporal face distortions,
  including examples and scene-dependent preference for appropriate facial smoothness. Its
  dataset is512×512 and includes codecs unlike target H.264; use as perceptual illustration,
  not evidence of4K filter performance or universal preference for smoothing.

Actual bitrate-targeted changing-frame results now available: [4K H.264 profiles to 6K](target-h264-profiles.md).

Raw-source Lips/Flower examples at10/12Mbit/s, aggressive controls and preview videos: [UVG low-bitrate stress](uvg-low-bitrate-stress.md).

Temporal chroma accumulation follow-up (not integrated): [measured spike and rejection](temporal-chroma-spike.md).

Local gradient debanding follow-up (not integrated): [regional masks, detail negatives and 4K measurements](local-gradient-deband.md).

Optional post-scale perceptual grain (integrated experimentally): [structure protection, controls and 4K→6K measurements](perceptual-grain.md).
