# Local-gradient deband spike

2026-11-07, M4 Max (32 GPU cores, 36 GB), macOS 27.2. Standalone experiment;
no new player mode or product source changes. All cleanup runs at source resolution,
before MetalFX. Sharpening and Apple LL effects are disabled.

## Decision

Keep the current mild window filter as the player baseline. A regional smoothness mask
can preserve some texture that the window filter removes, and can allow stronger
debanding on synthetic gradients. These candidates do not establish a better overall
quality/performance tradeoff on the real clips. The stronger variant still modifies
legitimate shallow texture. Do not enable it by default or label its mask as artifact
detection.

## Candidates and iterations

Independent Metal code, using the existing window kernel as the comparison and as the
reconstruction step of the masked candidate. No additional third-party implementation.
External experiment directories, relative to the existing filter-lab artifact root:

- `gradient-deband`: strict smoothness mask, strength .5.
- `gradient-deband-relaxed`: relaxed mask, early bypass, additional texture negatives,
  plus a stronger masked-window variant.
- `gradient-deband-multiscale`: relaxed mask plus coarse texture rejection; final variant.

The mask is RGBA16F at one sixteenth of input width/height: 240x135 for 4K.
Each cell fits an RGB plane to a 9x9 lattice, spaced four source pixels apart,
covering a 32px span. Confidence combines plane-fit residual, slope, and adjacent-pixel
texture probes at nine locations. The final variant also measures opposing-gradient
cancellation across horizontal/vertical 32px spans. This rejects oscillating detail that
the existing 3x3 texture test misses. It is a smoothness heuristic, not proof of banding.

Final gates, expressed in encoded RGB8 code units:

- Plane residual: fade confidence from .9 to 3 codes.
- Adjacent texture activity: fade from .6 to 2 codes.
- Coarse opposing-gradient cancellation: fade from .15 to .75 codes.
- Fitted slope: fade from 2 to 5 codes per lattice step (4px).

Mask sampling is bilinear. Both full-resolution candidates retain the existing per-pixel
texture guard. Masked window bypasses before that guard where regional confidence is zero.

| Profile | Reconstruction | Strength / threshold / radius |
|---|---|---|
| Existing window | Current bounded radius-halving window | .5 / 9 codes / 24px |
| Masked window | Same window, weighted by regional confidence | .5 / 9 / 24 |
| Directional | Centre plus 8 symmetric pairs with triangular weights, along fitted luma gradient | .5 / 9 / 24 |
| Masked window strong | Same masked window | .9 / 12 / 32 |

Directional samples have a local difference gate and symmetric border limits. With no
fitted luma direction, the experiment falls back to the horizontal axis; it does not
estimate arbitrary isoluminant colour-gradient orientation. No temporal state, motion
estimation or future frames. SDR encoded DisplayP3 only; HDR is outside this spike.

## Controlled behavior

512x256 FP16 inputs. Banded fixtures quantize a known smooth signal in 3-code steps.
Percentages are reductions in RGB squared error against the known unquantized signal,
not perceptual quality percentages.

| Fixture | Existing window MSE reduction | Final masked window strong |
|---|---:|---:|
| Horizontal luma gradient | 74.58% | 82.09% |
| Diagonal luma gradient | 67.41% | 91.73% |
| Horizontal isoluminant colour gradient | 66.77% | 91.40% |

The constant field, hard edge and alternating fine texture are unchanged for all
profiles/iterations. A clean plane changes by at most .0623 codes, consistent with the
experiment's FP16 arithmetic/storage rounding.

The additional negatives matter:

- A legitimate 16px-period, low-contrast grid has RGB MSE .8763 codes² after the current
  window. The final strong masked variant reduces that damage to .000584 codes².
  The relaxed mask without coarse rejection did not protect this grid.
- A legitimate 32px-period, 2-code sinusoid on a gradient is still altered: current
  window MSE .4863, final mild masked window .2542, final strong masked window .5252
  codes². Strong maximum change is 1.494 codes. The final candidate therefore does
  **not** satisfy a general texture-preservation claim.
- For a thin weak colour line, final directional maximum change is .0623 codes in the
  synthetic test, versus .4980 for the current window. This does not establish general
  moving-edge safety.

`fixture-comparison.png` shows input/current window/final strong candidate. These small
fixtures demonstrate behavior; they are not a normal-distance 6K viewing test.

## Paired real clips

Use the [verified RAW-derived UVG clips](uvg-low-bitrate-stress.md): two seconds each
of Lips 4K60, FlowerFocus and FlowerKids 4K50, nominal 10Mbit/s H.264, with aligned
lossless controls. Every decoded frame is processed; quality is sampled every tenth
frame plus the last frame. No history warmup is needed.

Metrics use two 640x640 input-resolution DisplayP3 regions per scene, reduced by Lanczos
to 256x256 RGBAhalf. The regions start at these Core Image bottom-left coordinates:

| Scene | Region 0 | Region 1 |
|---|---|---|
| Lips | 2125,1114 | 1750,344 |
| FlowerFocus | 1812,645 | 3062,1145 |
| FlowerKids | 1625,895 | 2500,82 |

Reduction in regional RGB MAE against the aligned control, before MetalFX:

| Scene / region | Current window | Final masked mild | Final directional | Final masked strong |
|---|---:|---:|---:|---:|
| Lips 0 | 1.469% | .076% | .073% | .131% |
| Lips 1 | .942% | .011% | .012% | .018% |
| FlowerFocus 0, petal | 1.031% | .116% | .117% | .147% |
| FlowerFocus 1, soft background | 3.967% | 1.361% | 1.268% | 2.195% |
| FlowerKids 0 | 1.507% | .536% | .535% | .628% |
| FlowerKids 1 | .321% | .024% | .018% | .042% |

Average final mask confidence is .038 / .106 / .308 for Lips / FlowerFocus /
FlowerKids. These are mean weights, not fractions of pixels classified as artifacts.
The intermediate relaxed strong mask improves FlowerFocus background MAE by 4.927%,
but damages the legitimate synthetic textures more. Better preservation costs coverage.

Reference footage includes camera texture/grain; MAE rewards matching that texture, and
does not directly score contour visibility. These clips do not prove that the masked
variant is perceptually worse on a specifically banded background. They also do not
establish a practical advantage sufficient to replace the current filter.

Full 6144x3456 MetalFX PNGs are saved at first/middle/last frame, including matched
controls. Colour-managed comparison sheets use native 512px crops from those outputs.
No new temporal flicker score or blinded normal-distance 6K assessment was performed.
Frame-to-frame mask stability remains unvalidated.

## Performance and memory

Changing decoded frames, serial completed command buffers. CI upload completes before
timing. Rotate profile order per frame, discard ten warmup frames. Times include mask
generation for candidates, but exclude decode, CI conversion, MetalFX, readback and
presentation. The standalone textures use shared storage; these are not full-player
or production private-texture measurements.

Final variant GPU median / P95 ms, first run and a separate repeat without the spike's
image-generation work running:

| Scene / run | Window | Masked mild | Directional | Masked strong |
|---|---:|---:|---:|---:|
| Lips first | 1.46 / 1.51 | 1.39 / 1.56 | 1.60 / 1.71 | 1.45 / 1.56 |
| Lips repeat | 2.30 / 2.70 | 1.63 / 2.31 | 1.90 / 2.33 | 1.60 / 2.03 |
| FlowerFocus first | 1.43 / 1.48 | 1.57 / 1.69 | 1.68 / 1.82 | 1.63 / 1.78 |
| FlowerFocus repeat | 3.16 / 5.98 | 2.84 / 4.79 | 2.88 / 5.07 | 2.81 / 4.53 |
| FlowerKids first | 2.32 / 3.19 | 1.82 / 2.80 | 2.01 / 2.91 | 1.91 / 2.80 |
| FlowerKids repeat | 1.48 / 1.53 | 1.44 / 1.58 | 1.59 / 1.71 | 1.51 / 1.63 |

There is substantial run-to-run scheduling variability; its cause was not isolated.
Do not select the fastest row as a guaranteed budget or claim a stable speedup. Some
regions bypass useful work, while generating the mask adds work. The directional variant
does not establish a clear performance advantage.

One 4K output texture allocates 66,846,720 bytes (~63.75MiB), mask 327,680 bytes
(~.313MiB). Input, decoder, Core Image and MetalFX allocations are additional. No history
buffers. Application integration would need reuse of the actual scaler input/output;
the prototype's CI wrapper must not be treated as a free path.

## Verification and reproducibility

External directories retain shader/Swift sources, driver scripts, JSON quality rows,
timing reports, logs, fixtures and images. Final `verification.json` records:

- 71 checks passed, including negative fixtures and synthetic band improvement.
- 153 full6K PNG dimensions/ICC checks, 128 fixture PNG dimension checks.
- 980 sampled regional quality rows across the three iterations, all finite.
- Expected frame/timing counts and successful GPU command completion.
- Repeated baseline MAE differs by at most .00000406 RGB8 codes across iterations.

The known sinusoidal-texture loss is explicitly retained as a limitation, not counted
as a passed texture-safety requirement. No product build/test claim is made: the
application source and installed experimental build were not changed by this spike.

Final shader SHA256:
`f26082df9b7ff86a2957c55bb55980a1180901fda6786502b0016df735098412`

Next separate investigation: MetalFX-generated halos at output resolution, retaining
the existing pre-scale filters. This spike does not address those halos.
