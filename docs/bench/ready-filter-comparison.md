# Ready-made cleanup and grain candidates

2026-11-07. M4 Max, 32-core GPU, 36GB. External experiment only; no renderer,
application binary, default or pipeline changes. The existing Filter Lab retains
`Deband: libplacebo Logic` and the corresponding Display settings choice, with
strength, RGB8 threshold, source-pixel radius and iteration controls.

## libplacebo-style Metal debanding

Three two-second public UVG H.264 10Mbit/s clips: Lips 60fps, FlowerFocus and
FlowerKids 50fps. Actual DisplayScaler, source cleanup before MetalFX, output
6144×3456. Shared settings: chroma bilateral3 strength .6, coherent-edge AR,
sharpen/dither zero. Window: strength .8, threshold12, radius32, texture protection1.
Reference mild: strength1, threshold1.02 RGB8 codes, radius16, two iterations.
Reference strong: threshold3 codes, radius24, three iterations. Grain row adds
soft grain amount2, size1.5, baseline.65, adaptation1 to reference strong.

Reference mode is the existing LGPL-noticed Metal adaptation of libplacebo, not
actual mpv execution or bit-exact upstream sampling. Its PRNG, integer texture
sampling and RGB pipeline differ; see `third_party/libplacebo/SOURCE`.
Do not enter mpv's numeric threshold directly: parameter units differ.

GPU median / P95 ms. Changing decoded frames, rotated profile order, ten warmups,
110/90/90 measured samples. No PNG readback or preview encoder during this timing.
Includes CI conversion and the complete DisplayScaler; excludes decoding and
drawable presentation. These are whole GPU pipeline times, not filter overhead.

| Scene | Window | Reference mild | Reference strong | Strong + grain |
|---|---:|---:|---:|---:|
| Lips | 5.044 / 5.164 | 4.607 / 4.696 | 5.721 / 5.806 | 6.883 / 6.969 |
| FlowerFocus | 5.012 / 5.153 | 4.581 / 4.628 | 5.708 / 5.774 | 6.881 / 7.028 |
| FlowerKids | 5.116 / 5.250 | 4.588 / 4.643 | 5.723 / 5.802 | 6.916 / 7.005 |

Visually, strong reference reduces some small irregularities but is not a clear
improvement over Window; large compression patterns remain and fine texture can
be reduced. On six fixed native512px ROIs at the middle frame, Window PSNR improves
.024–.182dB versus input; reference mild varies -.009–+.032dB, reference strong
falls .017–.537dB. This is a small diagnostic sample, not a perceptual ranking.
The pre-encode reference passes through the same MetalFX pipeline; grain is excluded
from these metrics. Keep both algorithms as choices, without replacing defaults.

## Actual FFmpeg CPU filters

Same three inputs. Native4K middle-frame PNGs compare weak deblock grid8, strong
deblock grid16, guarded deband and weak8+deband. Deband parameters: thresholds .02
on all three YUV planes, range16, blur0, coupling1. FFmpeg's planar YUV filtering
and RGB conversion are separate from the Metal experiment; no direct cross-pipeline
pixel comparison is made. Source-resolution crop sheets are explicitly separate.

Median wall ms/frame, three rotated repeats ×30 frames, two decoder and two filter
threads. Includes process startup, software decode, CPU filtering and drain to null;
excludes RGB conversion, encoding and display. Timings were repeated after sample
generation finished to remove its contention. No unbounded CPU parallelism.

| Scene | Decode/null | Weak grid8 | Strong grid16 | Deband | Weak8 + deband |
|---|---:|---:|---:|---:|---:|
| Lips | 7.303 | 8.242 | 7.636 | 57.888 | 62.332 |
| FlowerFocus | 8.614 | 9.100 | 8.744 | 59.531 | 64.027 |
| FlowerKids | 7.407 | 8.200 | 7.488 | 60.536 | 65.628 |

Deblock softens selected grid boundaries but does not repair larger structures.
Guarded deband also leaves defects; its tested CPU implementation misses the50/60fps
budget before screen fitting. These timings do not predict a future Metal port.
FFmpeg filters are not interchangeable shader files: CPU implementations must be
ported or require a CPU processing path. This test does not add either to playback.

External `ready-filter-spike` retains Swift/scripts, filters, logs, metrics,
54 native6K PNGs and320 verified preview frames. Preview uses CRF12 and may obscure
grain; PNGs are the appearance reference. Source hashes match the earlier fused
verification. No product-code change required a build or unit-test rerun.

## Grain appearance and external candidates

`grain-style-spike` compares existing White/Fine/Soft at equal amount2, size1.5,
baseline.65 and adaptation1, using strong Window cleanup. Lips and FlowerFocus:
30 verified native6K PNGs,220 preview frames. These styles are independent Gaussian
template constructions, not conformant AV1/H.274 or physical film simulations.
Fine is less spatially correlated; Soft forms broader clusters. White is a control.

Phone PNGs include native256px patches enlarged nearest-neighbor to512px, with
cleanup/no-grain, Fine and Soft stacked vertically. They are explicitly diagnostic2×,
not the physical6K viewing scale. A smooth patch with visible adaptive grain is
selected by grain-change RMS relative to image activity; the same patch is used
for every style. Native1:1 sheets are also retained. All are lossless sRGB PNGs.
Grain adds texture but does not eliminate the visible compression underneath it.

Candidates worth comparing next, not yet implemented or benchmarked here:

- **AV1/AFGS-style synthesis:** libplacebo has ready source for correlated grain,
  intensity scaling and overlapped randomized blocks. The AV1 file is dual MIT/LGPL.
  A useful next candidate for controlled styles with reusable template banks;
  do not call our current approximation a faithful AV1 reconstruction.
- **H.274:** libplacebo builds frequency-controlled grain LUTs with horizontal and
  vertical cutoff choices and intensity intervals. Useful for finer/coarser or
  directional styles; actual Metal cost and appearance remain unmeasured.
- **Procedural3D noise:** `glsl-film-grain` supplies an MIT implementation with
  animated noise and blending examples. Its author describes it as relatively
  expensive. Need to check motion character and6K cost; time-continuous noise can
  look different from independently refreshed film frames.
- **Physical grain:** Newson et al. provide a stochastic silver-grain model and
  Monte Carlo rendering source. A candidate for generating reference/template
  banks offline; realtime6K throughput or superiority is not established here.

Prefer testing correlated monochrome grain first, retaining per-region structure
protection. Color grain should be separately controllable because color noise is
one of the defects being removed. Preset names should describe appearance, without
claiming to reproduce a particular film stock without measurements.

Primary references:

- [mpv deband and shader hooks](https://mpv.io/manual/stable/)
- [libplacebo sampling source](https://github.com/haasn/libplacebo/blob/master/src/shaders/sampling.c)
- [FFmpeg deband/deblock](https://ffmpeg.org/ffmpeg-filters.html)
- [FFmpeg deblock source](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_deblock.c)
- [libplacebo AV1 grain](https://github.com/haasn/libplacebo/blob/master/src/shaders/film_grain_av1.c)
- [libplacebo H.274 grain](https://github.com/haasn/libplacebo/blob/master/src/shaders/film_grain_h274.c)
- [Procedural GLSL grain](https://github.com/mattdesl/glsl-film-grain)
- [Realistic Film Grain Rendering](https://www.ipol.im/pub/art/2017/192/)

## Follow-up: actual candidate template experiment

The user could not see the previous grain examples. Measured full-image sRGB8 RMS
change was only .75–1.08 codes for old White/Fine/Soft at nominal amount2. Local
masking and interpolated template sampling reduce the nominal amplitude. The app
config currently accepts only0…3; this spike does not silently widen that range.

External `grain-candidates` now contains actual candidate banks, rather than renamed
old styles. Upstream libplacebo source files and SHA256s are retained there:

- AV1: adapt luma-table Gaussian lookup, 16-bit PRNG and integer causal AR update;
  authored lag1 coefficients `[8,28,8,28]`, shift7, depth8. Extract64px regions.
- H.274: adapt Gaussian-LUT initialization and the integer inverse transform with
  frequency cutoff indices3…5, rotating/shifting variants. Edge attenuation uses
  floating multiplication in this adaptation, rather than upstream integer rounding.
- Particle model: independent Poisson Boolean discs on a periodic flat field,
  median radius.55px, log-spread.30,50% expected coverage,8× subpixel area integration
  and.25px optical blur. No IPOL code is copied. This is not complete image-dependent
  physical film rendering.

Each bank has16 layers of64×64 FP16 values, normalized to zero mean/unit RMS, with
an offline edge blend. Measured adjacent-pixel correlation x/y is .267/.271 for AV1,
.704/.694 for H.274 and .420/.425 for particles. Combined generation took.64s in
one recorded run; no per-frame synthesis. These are **template adaptations**, not
full conformant AV1/H.274 rendering. Application of the banks uses the same existing
Metal overlap/seed/grain-mask/fused AR compositor in a standalone source copy.

Compare working amount6, size2, baseline.8, adaptation1 against diagnostic amount12,
size2, adaptation0. Diagnostic masking is intentionally disabled to expose the
pattern. Both exceed the unchanged app config maximum3 and are not shipping defaults.
Cleanup is identical to the stronger Window profile. The old/new cleanup snapshots
agree within one RGB8 code, so changed cleanup is not responsible for the new texture.

At the fixed phone patch, measured sRGB8 RMS change versus grain-free cleanup:

| Scene | AV1 working/demo | H.274 working/demo | Particles working/demo |
|---|---:|---:|---:|
| Lips | 3.69 / 10.06 | 4.14 / 11.36 | 3.85 / 10.53 |
| FlowerFocus | 4.11 / 10.91 | 4.67 / 11.98 | 4.30 / 11.70 |

Working full-image RMS ranges2.62–3.47codes. Grain is now plainly visible in the
diagnostic PNGs; AV1 is finer, particles more clumped, and the tested H.274 cutoff
produces an undesirable wave/worm-like pattern. Do not reject every H.274 parameter
set based on this one; this coarse preset is not a preferred default. AV1 and the
particle bank are the better next appearance candidates. This is visual inspection
of PNGs, not a blind viewer study or a sustained native-player test. It does not
establish that grain restores lost source texture.

Actual DisplayScaler4K→6K GPU median/P95 ms, separate changing-frame timing after
quality generation, rotated7-profile order, ten warmups:

| Scene | Cleanup | AV1 working | H.274 working | Particles working |
|---|---:|---:|---:|---:|
| Lips | 5.023 / 5.098 | 6.170 / 6.260 | 6.164 / 6.229 | 6.159 / 6.229 |
| FlowerFocus | 5.026 / 5.150 | 6.172 / 6.267 | 6.168 / 6.263 | 6.165 / 6.307 |
| FlowerKids | 5.256 / 5.460 | 6.419 / 6.644 | 6.424 / 6.660 | 6.415 / 6.666 |

Diagnostic amount12 has similar cost; changing banks/amount introduces no extra GPU
pass. The existing mask remains1,179,648bytes; each new template bank is131,072bytes,
393,216bytes in total. Decode and final drawable presentation remain excluded.
No claim about sustained frame cadence, energy or fan behavior.

Verification:42 native6K PNGs,440 lossless RGB crop-video frames, correct orientations,
PNG-to-preview mean discrepancy<1code after P3→sRGB conversion, actual fused execution,
expected mask allocation, unchanged product source hashes. Every candidate produces
nonzero output and phone-patch RMS>1.5codes; diagnostic patches exceed5codes. The
lossless reference videos use libx264rgb CRF0, avoiding previous CRF12 grain suppression.
Additional H.264420 previews are convenience derivatives, not numerical references.
Phone PNGs use nearest-neighbor2× enlargement without amplitude amplification; compact
phone videos crop/rearrange native regions and display30fps, distinct from source50/60fps.
No product build, app-config change or unit-test rerun is claimed for this external spike.
