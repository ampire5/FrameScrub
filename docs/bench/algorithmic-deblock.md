# Algorithmic Metal deblocking spike

2026-11-07, M4 Max,36GB, macOS27.2. Standalone throwaway Swift/Metal executable, not
FrameScrub integration. The question is whether useful native4K SDR deblocking can fit
a2–5ms filter budget. No app runtime dependency or shader added to the repository.

## Algorithms

1. Boundary filtering inspired by the strong local FFmpeg deblock formula. At grid8 or16,
   inspect the discontinuity and adjacent gradients in full-range BT.709 Y/Cb/Cr. For each
   eligible component, distribute the discontinuity across six samples with weights
   +1/8,+1/4,+1/2,−1/2,−1/4,−1/8. Thresholds alpha=.098,beta/gamma/delta=.05. Vertical
   then horizontal whole-image passes. This is not a bit-exact FFmpeg port: input isRGB8,
   chroma is full resolution, intermediateRGBA16F and arithmetic is floating point; FFmpeg
   processes original planar formats with integer arithmetic and a different pass order.
   No decoder block metadata used; phase0 grids8/16 are hypotheses, not inferred partitions.

2. Adaptive smoothing following the LiveVisionKit DeblockingFilter design. Average4×4
   input pixels to quarter dimensions, channel-wise median5×5, bilinear upscale. A16×16
   block mean-absolute-luma-deviation mask protects textured areas. Quantized detection
   levels3 (conservative) or8 (more aggressive), following the reference's threshold ladder,
   determine blending weight. Third profile uses median3×3 for speed. A1e−5 normalized
   luma floor avoids numerical error classifying constant blocks as slightly textured.
   This is a local-detail heuristic, not a reliable detector of compression damage.

Sources:
https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_deblock.c
https://github.com/Crowsinc/LiveVisionKit/blob/main/LiveVisionKit/Filters/DeblockingFilter.cpp

The latter reference is GPLv3; source-informed prototype files remain outside the repo.
Any retained/distributed implementation needs the corresponding license review rather
than assuming the experimental code is an unrestricted drop-in product component.

## Inputs and measurement

Same frame90 at3s from Apple's public3840×2160 FRC.mov: H.264 QP42 andQP32, HEVC QP38,
plus the frame before additional re-encoding. This is one scene/person/dog/park; not broad
content or temporal-stability coverage. No private media. The reference itself is encoded.

ImageIO preserves the original RGB profile. An initial loader erroneously rendered BT.709
PNG into sRGB, shifting RGB8 values (MAE~8.7/max13). The problem was isolated to load/render,
fixed by preserving cgImage.colorSpace, and all final benchmarks/images regenerated. Final
load→save RGB8 is bit-exact on all four inputs. Unsharpened before/after panels use identical
native crops and color tags. A separate sky panel is explicitly2× nearest-neighbor.

One command buffer/task in flight. All textures/pipelines allocated before timing; full-frame
input already resident. Every profile performs3 warm-ups and30 timed iterations on the same
frame, sequentially. GPU duration uses command-buffer gpuStartTime/gpuEndTime; wall duration
includes encoder setup, submit and wait. No source decode, upload/readback, PNG encoding,
pipeline compilation, display or app responsiveness in those times. No claim of an app-level
30/60fps result. Threads per group16×8. No CPU parallel workers used by the runner.

## Final timings across four inputs

| Profile | GPU median range, ms | Largest measured P95, ms | Wall median range, ms |
|---|---:|---:|---:|
| Boundary8 | .544–.586 | 1.783 | .733–.799 |
| Boundary16 | .527–.773 | 1.755 | .693–1.344 |
| Adaptive, levels3, median5 | 1.892–2.081 | 2.849 | 2.084–2.222 |
| Adaptive, levels8, median5 | 1.893–2.609 | 3.097 | 2.081–2.833 |
| Adaptive, levels8, median3 | .961–1.086 | 2.193 | 1.123–1.252 |

Common resident textures total175.47MB as reported by MTLTexture.allocatedSize; add one
small mask (up to~0.26MB), pipelines/runtime and CPU image buffers. This is resource allocation,
not a sampled process/GPU peak. Buffers reused and bounded, no queue of decoded frames.

## Verification

Independent NumPy CPU reference uses a synthetic256×128 fixture with low-contrast block
steps, a strong edge, a constant field and fine checker texture. All five outputs agree with
GPU to max1 RGB8 code value. Mean absolute errors: boundary8/16=.03888; adaptive5=.00775;
adaptive3=.00772. The zero-threshold floating-point corner was first reproduced by dumping
mask/low-resolution/smoothed GPU buffers, then fixed with the small floor in both mathematical
references; the floor is below one hundredth of an8-bit luma step. No other algorithm changes
were bundled with the color-loader fix. All final command buffers completed without errors.

## Quality and decision

Boundary filtering is fast but visually modest and depends on grid alignment. The adaptive
method visibly smooths the sky's block grid without the neural model's invented fine pattern.
Face/fur degradation remains. Stronger levels select low-contrast foliage/skin/fur as well as
damaged flat areas: the full blend-weight overlay makes that limitation visible. Conservative
levels preserve more texture but leave more artifacts. Applying the filter to the pre-reencode
reference also changes some low-contrast detail; the mask does not know what damage is.

H.264 QP42 face/fur/sky RGB PSNR against the pre-reencode frame:

| Profile | Face | Fur | Sky |
|---|---:|---:|---:|
| Input | 28.84 | 27.68 | 37.37 |
| Boundary8 | 28.74 | 27.63 | 37.47 |
| Adaptive3 | 28.90 | 27.69 | 37.45 |
| Adaptive8 | 28.91 | 27.67 | 37.46 |

These tiny changes are not evidence of major restoration or a broad perceptual-quality win.
They support the inspected result: modest localized suppression, not recovered texture.

The standalone compute budget is satisfied on this machine. If pursued, adaptive smoothing
deserves controlled optional A/B in the display pipeline with strength and mask visualization;
integration still requires real playback, scrub/pause, flicker, color/HDR and slower-device
checks. HDR/10-bit, arbitrary rescaling/cropping/grid phase and temporal stabilization were
not implemented or tested. No product behavior changed in this spike.

Final Swift/Metal source, CPU parity script/fixture, raw JSON/logs, full4K images and comparisons
are stored in the external research workspace.

The [detailed 4K follow-up](algorithmic-deblock-4k.md) adds architecture/foliage, clean-input
controls, changing-frame timings, translation sensitivity and a conservative variant. Its
results favor improving artifact selectivity before integrating the original adaptive profile.
