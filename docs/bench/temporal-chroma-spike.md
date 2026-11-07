# Temporal chroma spike: 4K before MetalFX

2026-11-07, M4 Max32GPU-core/36GB, macOS27.2. Outcome: **do not integrate this prototype in
the player**. Extra correction of the tested compression damage is too small for the history,
GPU work and motion tradeoff. This rejects this unwarped accumulator, not temporal restoration
in general. Existing player/build/defaults remain unchanged.

## Approach and references

Independent Metal prototype, source-resolution SDR encoded DisplayP3. Luminance is always
from the current frame; only R-Y/B-Y chroma is accumulated. Two RGBA16F history textures store
current luminance, accumulated chroma and effective age; a third texture stores RGB output.
History is at most8 effective samples. One serial command buffer in flight, no future frame,
optical flow, neural model or extra decoder. No imported implementation code.

The recursive-low-pass idea can be seen in [FFmpeg HQDN3D source](https://ffmpeg.org/doxygen/trunk/vf__hqdn3d_8c_source.html).
[GPUOpen FSR2 documentation](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-temporal/)
discusses history rectification/rejection with motion information. These are background
references, not equivalence claims: this video experiment has no motion-vector reprojection.

Mild: max history weight.75, luma mismatch gate3..10 RGB8 codes averaged over3x3, chroma mismatch
gate4..12 codes, current-neighborhood variance clipping (floor3codes, sigma multiplier1.5),
per-C-channel correction bounded2codes. RGB gamut constrains the correction along a vector
with zero encoded luminance change. FP16 storage introduces sub-code rounding. Strong raises
history cap to.85, chroma gate8..20, clipping floor6 and correction cap4codes.

A seven-pixel vertical/horizontal coherence test on current-minus-history chroma rejects
consistent colour changes above1..3codes. An initial spatial3x3 coherence detector rejected
almost all random noise (only~0.8% MSE reduction); it was replaced after the fixture failed.
The external host option is still named edgeGuard, and fixture label no-edge-guard means
without the final temporal coherence guard. It is not an artifact classifier.

A separate2304-point GPU gate rejects broadly changing frames (mean luma + half max chroma
change>.04 or >60% samples above.08). This is conservative history rejection, not validated
scene-cut classification: it also resets on motion/lighting in FlowerKids (31 of99 transitions),
while Lips/FlowerFocus have no global rejections. Local gates still run independently.

Prototype host resets on source epoch, dimensions, settings, non-consecutive/reverse indices,
non-increasing timestamps or source-time gaps>60ms. Repeated same-frame redraw reuses the last
output and does not accumulate again. HDR/disabled bypass and release history. The class has a
serial submit/complete contract; app integration would additionally need actual source/crop/
colour identity and GPU-failure lifecycle handling. It was intentionally kept out of the app.

## Controlled checks

26 GPU/host checks pass: static signal, seeded random chroma noise, moving luma edge, moving
isoluminant colour edge, weak one-pixel moving colour line, isoluminant cut, repeated frame,
seek/source reset,1x1 texture and HDR release. At256x144,80frames per case:

- Independent random chroma-noise MSE falls45.18% mild /69.71% strong after10warmup frames.
- Ungated EMA achieves85.76% noise reduction but leaves~3.09code chroma error on the moving
  weak line and~30.54codes immediately after the cut. The test detects the failure mode.
- Guarded weak-line chroma error is~0.115code (FP16 rounding); first post-cut error is0.
- Mild maximum RGB correction2.117codes, maximum encoded luminance change~0.125code.
- Disabling the coherence guard reduces noise54.58% but leaves~2.06codes on the weak line.

These fixtures establish basic behavior, not perceptual ghost-freedom on arbitrary footage.

## Real-video quality

The [verified RAW-source UVG stress clips](uvg-low-bitrate-stress.md): first2seconds of Lips
4K60, FlowerFocus/FlowerKids4K50, nominal10Mbit/s H264. Matched lossless controls,320frames total.
All paths share MetalFX perceptual6144x3456, sharpen0/LLoff. Spatial is window strength.5,
threshold9/radius24/protection1 plus chroma bilateral.35 before upscale and edge AR after.
Temporal+spatial feeds the temporal result into that same pipeline.

Every frame has two512x512 final6K ROIs reduced by Lanczos to128x128 RGBAhalf DisplayP3 for
coarse-colour metrics. First10frames excluded. Percentages below are reductions of mean
chroma absolute error versus matched-reference MetalFX, averaged across both ROIs/frames.
These are not whole-frame scores or perceptual quality percentages. Reference still contains
camera grain and MetalFX behavior. No causal claim that all removed variation is an artifact.

| Scene | Spatial | Temporal guarded | Temporal + spatial | Extra over spatial | Temporal without coherence guard |
|---|---:|---:|---:|---:|---:|
| Lips | +1.093% | +0.062% | +1.137% | +0.044% | -0.073% |
| FlowerFocus | +2.938% | +0.519% | +3.040% | +0.104% | -2.115% |
| FlowerKids | +1.542% | +0.329% | +1.670% | +0.130% | -0.730% |

The stronger guarded settings do not improve these results consistently. Removing the guard
makes MAE worse in all three scenes, especially FlowerFocus; lower change of residual over
time does not imply better reconstruction. The temporal-change diagnostic is change of
matched-reference error at fixed coordinates, affected by motion and spatial errors; it is
NOT a flicker or ghosting score. No blinded normal-distance6K viewing test was performed.

Native512x512 ROI checks on middle/last RGBA8 PNGs also show only small guarded temporal
MAE gains (~0.09/0.45/0.34% Lips/Focus/Kids). Full first-frame images of the temporal path are
pixel-identical to baseline MetalFX for all three scenes, ruling out a first-frame colour/
extra-copy confound. Later corrections are real but insufficient to establish useful cleanup.
No grain/skin texture reconstruction is demonstrated. Unaligned history cannot be assumed to
correspond to the same moving content; random static-noise success does not transfer directly.

## Clean temporal-stage GPU timing

Separate changing-frame run, CI upload completed BEFORE timing, one command buffer in flight,
rotated profile order,10warmup frames. Scene-gate + temporal shader only: excludes decoding,
CI conversion, scaling, presentation and readback. The video/metric run is not a speed test.

| Scene | Guarded median/P95 ms | Strong median/P95 ms | Without coherence guard median/P95 ms |
|---|---:|---:|---:|
| Lips | 1.985/4.743 | 2.012/4.754 | 1.061/2.170 |
| FlowerFocus | 1.475/1.566 | 1.477/1.507 | 0.840/0.893 |
| FlowerKids | 1.466/1.504 | 1.466/1.500 | 0.831/0.896 |

One active profile allocates200,540,176bytes (~191MiB) for two history textures + RGB output +
small scene buffer; input/scaler/caches additional. Median~1.47–1.99ms is close to the proposed
1–2ms allowance, but Lips P95~4.74ms prevents a guaranteed budget claim. The experiment does
not isolate the timing variability. Additional CI copies in the offline quality wrapper are
not included in this shader-only timing; any integration would reuse the existing source-size
MetalFX input rather than reproduce that wrapper.

## Artifacts and decision

The external research workspace contains current shaders/Swift/scripts,
fixtures.json, three guarded and three loose comparison videos,108full6K PNGs,6400coarse ROI
metric rows,90native snapshot rows, scene-gate traces, clean GPU logs and verification.json.
Videos are CRF12 diagnostic crops: reference / H264 / spatial / temporal / temporal+spatial,
five columns and two ROI rows. They are not normal-distance full-frame comparisons; numerical
metrics use independent P3 half-float patches or PNGs, never encoded preview pixels. All six
videos have verified frames/fps/size/orientation. No extra download, app change, commit or build.

Recommendation: keep this as a rejected measured baseline. A next temporal candidate needs
reliable matching of moving content and a quality win, before history is added to the player.
The approved separate gradient-localization experiment remains useful and does not depend on
this prototype. Do not infer that a faster accumulator alone solves H264 blocking/patchiness.
Product tests were not rerun for this external experiment and bench-document-only change.
