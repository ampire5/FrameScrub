# Algorithmic deblocking: detailed 4K video follow-up

2026-11-07. Standalone external experiment on M4 Max, 36 GB, macOS 27.2.
No application code or behavior changed. Follows [the first Metal spike](algorithmic-deblock.md).

## Test material and method

- SVT OldTownCross and ParkJoy, native 3840×2160p50, first 16 frames each (0.32 s).
  Architecture, sky, foliage, bark and grass; original grain is present. Source:
  [Xiph test collection](https://media.xiph.org/video/derf/). The accompanying
  [SVT document](https://media.xiph.org/video/derf/vqeg.its.bldrdoc.gov/HDTV/SVT_MultiFormat/SVT_MultiFormat_v10.pdf)
  is retained with the lab assets and governs their use. The first town range request timed
  out with more than 16 complete frames downloaded; its partial tail was removed. Both
  retained Y4M files contain exactly the 16 complete frames used here.
- H.264 libx264 veryfast QP34 and QP42, yuv420p, two encoder threads. QP34 retains
  recognizable fine structures alongside compression damage; QP42 is a severe stress case.
  Both clean sequences are processed too, to expose unnecessary smoothing.
- Existing public Apple FRC sample, first 90 frames at native 3840×2160p30, H.264 QP34:
  a three-second temporal smoke test. This is not broad motion/flicker validation.
- Four profiles: identity, boundary8, adaptive8-fast, and adaptive-safe. Apple sequence
  tests identity and the two adaptive profiles. 654 full-resolution frame operations total:
  6 SVT cases × 4 profiles × 16 frames + 1 Apple case × 3 profiles × 90 frames.
- One command buffer in flight, serial processing, bounded source/output buffers, codecs
  limited to two threads. No main/UI thread or app playback is involved.
- Native 4K PNGs for first/middle/last frames; exact RGB crop sequences in NPZ. Metrics
  use these lossless samples. Labeled comparison MP4s are CRF12 previews, not metric inputs.
  SVT previews explicitly repeat the short excerpt four times; Apple preview is three seconds.

## Conservative experimental variant

The previous quarter-resolution median3 and 16×16 MAD mask remain the starting point.
`adaptive-safe` changes three things together; this is a combined candidate, not an ablation
that identifies the separate benefit of each change:

1. Continuous keep weight `smoothstep(1/255, 8/255, MAD)` replaces quantized levels.
2. Full-resolution 3×3 maximum luma difference protects edges. The blend multiplier falls
   smoothly from one at 3/255 to zero at 12/255.
3. Target RGB correction is capped to ±3/255 per component, then blended at at most 0.65.
   Final RGB8 correction is therefore at most two code values in these tests.

These thresholds are exploratory choices, not measured optimal constants or product defaults.
The mask still identifies smooth content, not compression damage. The variant is not a guided
filter, CDEF implementation, learned detector, temporal filter or true sparse/ROI execution.

## Performance

GPU command-buffer execution, excluding decoding, CPU transfer and presentation:

| Workload | Boundary8 | Adaptive original | Adaptive protected |
|---|---:|---:|---:|
| Resident town frame, median | 0.54 ms | 1.31 ms | 1.36 ms |
| Resident shifted town frame, median | 0.54 ms | 0.97 ms | 1.14 ms |
| Changing SVT frames, median range across cases | 1.68–1.80 ms | 3.28–3.43 ms | 4.12–4.31 ms |
| Changing Apple frames, median / P95 | — | 3.25 / 5.09 ms | 4.16 / 5.85 ms |

Resident workload: three warmups and 30 repeats, no source replacement/readback in timed
region. Changing-frame workload: first three frames excluded; 13 samples per SVT case and
87 per Apple profile. SVT protected P95 ranges 5.25–6.13 ms. These workloads differ in
resource access, CPU gaps and GPU scheduling; the test does not isolate the reason for
their timing difference. The resident ~1 ms result alone is insufficient for a playback claim.

In the Apple loop, CPU texture replacement + submit/wait + readback median was 8.85 ms for
identity, 12.01 ms for adaptive original and 12.92 ms for protected. This excludes pipe I/O,
decode, PNG/preview encode and presentation. It is neither an app benchmark nor a claim
that the same overhead is needed with GPU-resident decoded textures.

## Image quality and temporal observations

- Sky: adaptive smoothing visibly reduces small block structure and residual noise. Large
  low-frequency patches/steps at QP42 remain. Boundary8 is less effective and grid dependent.
- Architecture and grass: destroyed texture is not reconstructed. Original adaptive can
  remove additional weak structure; protected modifies these regions less and leaves more damage.
- Clean inputs: original adaptive also suppresses grain/weak texture. On the two ParkJoy crop
  regions its mean spatial absolute-gradient energy falls by about 32%; protected by about 10%.
  This measures intervention, not a perceptual detail score: grain and real texture are mixed.
- Across the two SVT measurement ROIs, PSNR changes against the pre-encode reference are
  small: original adaptive approximately +0.005…+0.139 dB; protected +0.009…+0.052 dB.
  These gains do not demonstrate major restoration, and a noisy/grainy reference limits PSNR's meaning.
- On the three-second Apple sequence, mean frame-to-frame change of the correction is
  0.050 RGB8 codes for original adaptive and 0.019 for protected, across the two ROIs.
  This is a non-motion-compensated diagnostic, not a flicker score. A smaller correction
  naturally changes less; this does not prove temporal stability or eliminate pumping.
- Shift test: translate the same frame right3/down5 pixels without scaling, filter it, then
  align outputs and compare their interior. Identity MAE is zero; boundary8 1.151 RGB8 codes,
  original adaptive 0.253, protected 0.088. Maximum discrepancies are 32/27/3 respectively.
  This exposes fixed-grid/downsampling-phase dependence; no grid-phase detector was added.

The broadened test supports optional localized cosmetic suppression, not a universal 4K
restoration filter. It weakens the earlier suggestion to integrate the original adaptive
profile immediately: improving selectivity should come first.

## Development priorities on current hardware

These are proposals, not implemented or benchmarked features:

1. **Artifact confidence rather than low detail alone.** Compute full-resolution boundary
   discontinuities relative to nearby within-region gradients, aggregate line coherence and
   periodic evidence over 8/16/32 scales into a small confidence map. Permit arbitrary grid
   phase and an uncertain/no-filter result. Protect natural architecture/texture explicitly.
   Neither regular spacing nor a large gradient alone proves blocking. Evaluate precision
   on clean detailed images before increasing smoothing strength.
2. **Directional, bounded correction.** Treat narrow seams separately from large patchiness
   and ringing. Work mainly in luma, tune chroma separately, smooth along legitimate edges,
   and limit the residual added to the original. [CDEF](https://arxiv.org/abs/1602.05975)
   supplies useful constrained directional-filter principles; AV1's in-loop filter is not a
   ready arbitrary-video postprocessor, and its encoder-selected strengths are unavailable here.
3. **Refine and stabilize the mask.** Test edge-aware upsampling instead of ordinary bilinear
   interpolation. Apple's [MPSImageGuidedFilter](https://developer.apple.com/documentation/metalperformanceshaders/mpsimageguidedfilter)
   is present in the installed SDK; its header explicitly separates regression/reconstruction
   to permit temporal coefficient filtering. The [fast guided-filter paper](https://arxiv.org/abs/1505.00996)
   supports inexpensive low-resolution coefficient estimation. This makes it a candidate mask
   tool, not an Apple deblocking filter or a demonstrated quality improvement in this experiment.
   For playback, stabilize confidence with motion-consistent history; reset on cuts/seeks and
   use a spatial-only path for isolated scrubbing. Do not average unaligned frames or await future frames.
4. **Optimize after selectivity is useful.** Keep input/intermediates on GPU, avoid this lab's
   CPU round trips, use bounded reusable textures, FP16 where verified and tiled/shared-memory
   kernels where profiling justifies them. Sparse processing helps only if a cheap detector
   rejects enough tiles to repay classification, halo and dispatch costs. Masked blending
   by itself does not skip processing. A small learned confidence detector is a later comparison;
   ANE use or a quarter-size map does not automatically make it faster or more accurate.

Next useful experiment: compare artifact-confidence + bounded directional correction against
the existing original/protected profiles on the same material, including clean negative
examples and longer motion. Avoid merely increasing median radius/strength or adding global sharpening.
Keep the original external prototype source/licensing caveat from the first bench: this is
source-informed research code, not a distribution-ready product implementation.

## Verification and artifacts

Native Swift runner compiled successfully; all 654 frame operations completed. Exact first-frame
RGB identity checked for all seven source cases. Protected correction bounded to two RGB8
codes across all 21 saved full4K frames. Translation identity check is exactly zero. The original
algorithms' independent CPU parity is documented in the first bench; the new protected profile
has invariant/output checks here, not an independent CPU numeric-parity implementation.

The external research workspace contains source,
input clips, SVT companion document, logs, raw timing samples, `metrics.json`, `verification.json`,
native PNG comparisons and labeled previews. No model, shader, dependency, private clip or
runtime feature was added to the repository. Product tests were not rerun for this external
experiment and bench-document-only change.

The [artifact-confidence follow-up](artifact-confidence-deblock.md) implements and tests
the proposed local seam detector and bounded directional correction. It finds insufficient
real-image improvement for the GPU cost and recommends keeping that candidate out of the app.
