# MetalFX-specific anti-ringing experiment

2026-11-07, M4 Max,36GB, macOS27.2. Standalone Swift/Metal experiment; no product change.
The user confirms additional sharpening is already disabled and prefers MetalFX's overall
result. Keep MetalFX as the base scaler. Investigate its artifacts independently of
deblocking, banding and chroma cleanup. No extra sharpening is used in any test here.

## Reproduction before intervention

Native MetalFX Spatial, perceptual mode, private RGBA16Float input/output as in
`DisplayScaler`. A clean synthetic1920×1080 slanted gray step, about.2→.8, enlarged to
3840×2160 produces values.1583… .8398 near the edge. Maximum overshoot is10.61RGB8-equivalent
codes beyond the input levels. The input contains no compressed-video damage or halo.
This establishes that MetalFX itself can create the observed *class* of artifact with
additional sharpening0; it does not establish the cause of a particular user-video defect.

The fixture also contains a fine diagonal line and a sinusoidal texture panel. Natural
fixtures reuse the public-source lab from [the earlier bench](algorithmic-deblock-4k.md):
Apple frame45 downsampled to1080→4K, and native4K town clean/QP34 plus parkQP34→5120×2880.
No private illustration or video was copied into the repository or public test assets.

Source CGImages are converted to encoded DisplayP3RGBA8 by CGContext, normalized to
Float16 and uploaded. This matches the scaler's color mode/texture formats, but does not
replicate every precision/color stage of the app's Core Image pipeline. Output float16
data and DisplayP3-tagged PNGs retained. Comparison canvases preserve the same ICC profile.

## Candidates

For each output pixel, find the four source samples surrounding its mapped center.
Clamp MetalFX's output only where it exceeds their range plus a tolerance:

- `rgb1`, `rgb2`: independent encoded RGB component ranges, tolerances1/255 or2/255.
- `luma2`: encoded DisplayP3 luma proxy (weights.2289746,.6917385,.0792869), tolerance2/255;
  add the scalar correction equally to RGB. This is not physical linear luminance.
- `edge2`: same luma correction, multiplied by a source-edge gate. Sample a5×5grid at
  stride2 (9×9source-pixel footprint), measure local range and coherent signed gradients.
  Range gate smoothstep.06….14; coherence gate.55….9. Thresholds are exploratory.

No blur, neural model, temporal history or sparse dispatch. The shader still runs at every
output pixel. An earlier3×3gate missed distant ringing (max9.59codes remained) and was
rejected; extending source context covered the synthetic halo.

This preserves the MetalFX result wherever the limiter does not trigger, but does not
guarantee preservation of all useful reconstruction. Local-range constraints can clip
legitimate extrema or affect fine structures. The edge gate deliberately leaves weaker
or incoherent features alone and can therefore leave artifacts on those features too.

## Quality and timing

Synthetic fixed-step maximum halo: MetalFX10.61codes; rgb1=1.03, rgb2/luma2/edge2=2.02.
The slight excess over the nominal tolerance is Float16 rounding.10–90%edge width at one
measured row changes2.131→2.167output pixels with luma2/edge2. This is a narrow reproduction,
not a general proof of no detail loss or aliasing.

On the clean grainy town frame, ungated luma2 changes30.40% of32768 sampled pixels,
mean absolute RGB change1.329codes. Edge2 changes1.68%, mean.0183codes. Reducing
unnecessary intervention is useful, but changed-pixel fraction is not restoration accuracy.

| Workload | MetalFX median | Luma2 extra median | Edge2 extra median |
|---|---:|---:|---:|
| Synthetic1080→4K | .642ms | .506ms | 1.070ms |
| Apple1080→4K | .725ms | .494ms | 1.070ms |
| Town clean4K→5K | 1.183ms | .936ms | 1.459ms |
| TownQP34 4K→5K | 1.178ms | .892ms | 1.455ms |
| ParkQP34 4K→5K | 1.357ms | .873ms | 1.445ms |

Resident GPU command-buffer times:3warmups+20MetalFX samples;3warmups+30postpass samples.
Decode, upload, CPU submission/wait, readback, PNG and presentation excluded. Do not add
separate medians and advertise that as measured app latency. Edge2 P95 across these cases
is1.38…2.02ms. Test texture allocations are about233MB at4Koutput and488MB at5Koutput,
including lab-only upload/readback textures; these are not process peak or final app requirements.

On the four natural cases, sampled edge2 changed fractions are.41%,1.68%,1.90%,.94%
respectively (Apple, clean town, compressed town, park). Native crop inspection shows
subtle intervention relative to ungated limiters, retaining most visible MetalFX texture.
Source compression damage remains. No broad perceptual-quality improvement is established.

## Fractional-motion check

A GPU translation moves the synthetic source through32horizontal phases over one source
pixel. Then MetalFX and the limiter run in the same command buffer. This is a subpixel
phase sweep, not real video, motion compensation or a subjective flicker evaluation.

At the measured row, MetalFX halo varies2.02…9.59codes across phases. Luma2 and edge2
both constrain it to about1.99…2.02codes. Thus the halo's phase-dependent amplitude is
reduced in this fixture; other temporal artifacts, weak lines and textures are unvalidated.

The changing-phase chain (translation+MetalFX+edge2) has median2.001ms, P95=4.619ms,
excluding separate readback. Final29of32samples used. The luma2 chain median is1.080ms,
P95=2.718ms. No drawable presentation, decoder or application interaction was involved.

## Verification, limits and next step

Independent CPU reconstruction at32768deterministic output samples for each of five cases
and four profiles: largest float-component discrepancy.00048828125 (about.125RGB8code).
Raw output finite checks, full native PNG decoding, sample counts and preview frame count
are recorded with the lab. Both baseline and processed FP16 values are measured before
8bit PNG quantization; the color-profile-tagged images are presentation artifacts.

The NumPy reference initially emitted BLAS floating-point warnings even though all source
and output buffers were finite and parity passed. The final reference uses explicit
elementwise products/sums instead of matrix multiplication and runs without those warnings.

`edge2` is a plausible optional A/B candidate **after MetalFX**, not a demonstrated fix
for the user's specific moving contour. It leaves the selected scaler intact. Before
retaining it in the product, evaluate native playback/scrubbing, hidden-window behavior,
thin-line aliasing, real edge motion, color clipping, HDR and other scale factors/devices.
Banding and chroma roughness remain separate research tracks; this shader does not address them.

The external research workspace contains Swift/Metal sources,
public/synthetic fixtures, raw float16 output, timings, CPU reference and labeled comparisons.
The motion preview is400%nearest enlargement,32phases repeated4×, CRF10; it is not a metric
input. No shader/dependency/config change was added to the app. Product tests were not rerun
for this external experiment and bench-document-only change.
