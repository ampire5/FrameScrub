# UVG Lips and Flower: 4K 10/12 Mbit/s stress examples

2026-11-07, M4 Max 32GPU-core /36GB, macOS27.2. Follow-up to
[target H264 profiles](target-h264-profiles.md). Offline experiment using the current real
DisplayScaler/filter sources; no app code, defaults or package changes.

## Sources and preparation

[Official UVG dataset](https://ultravideo.fi/dataset.html), Mercat/Viitanen/Vanne,
ACM MMSys2020. Digiturk, CC BY-NC3.0; original copyright files retained beside sources outside
repository. Lips: closeup of lips, skin, gloss and applicator, source120fps. FlowerFocus:
petals/droplets and soft background, source50fps. FlowerKids: faces, backlight and fine flower
texture, source50fps. FlowerPan's official thumbnail was inspected; not downloaded in this batch.

Only the first two seconds of each RAW8bit420 3840x2160 sequence were extracted: Lips240
source frames, FlowerFocus100 and FlowerKids100. Lips selects uniformly spaced frames to60fps;
Flower cadence stays50fps. No spatial resize or synthesized frames before compression.
Unlike the earlier compact Beauty/Bosphorus downloads, these sources have no intermediate HEVC
codec. They are still the distributed8bit420 conversion, not original16bit camera capture.

HTTP Range retrieves the original7z metadata and sequential LZMA2 prefix, stopping after an
exact whole-frame count. Lips has a self-extracting MZ wrapper; its archive offset is205824bytes;
only data were decoded, the executable wrapper was never run. Independent7-Zip extraction
matches the first full4K frame of each excerpt. Full-archive data CRC is not checked because
remaining bodies were not downloaded. Raw excerpt SHA256, source URLs and exact byte/frame
counts are retained. Decoder prefix logic was additionally verified against the first full
SunBath frame from a previously complete CRC-checked archive.

Common explicit setparams limited-range BT709 matrix/primaries/transfer precedes target and
lossless control encoding. It prevents the implicit colour transform encountered in the earlier
untagged-source experiment. QP0 controls match ALL320 selected source frames exactly by frame
MD5 (120 Lips,100+100 Flower). ffprobe confirms BT709 matrix/primaries/transfer on targets.

Targets: libx264 veryfast two-pass ABR, threads2, maxrate1.5x target, buffer2x target, GOP2seconds,
scenecut0. These short two-second examples expose spatial damage; they are not a long-motion,
steady-state rate-control or playback benchmark. Actual rate differs slightly from the nominal.

| Scene | fps | Frames | Nominal Mbit/s | Actual Mbit/s |
|---|---:|---:|---:|---:|
| Lips | 60 | 120 | 10 | 9.823 |
| Lips | 60 | 120 | 12 | 11.937 |
| FlowerFocus | 50 | 100 | 10 | 9.652 |
| FlowerFocus | 50 | 100 | 12 | 11.577 |
| FlowerKids | 50 | 100 | 10 | 9.926 |
| FlowerKids | 50 | 100 | 12 | 11.895 |

## Filters and quality

All comparisons scale to6144x3456 using the same MetalFX perceptual path, sharpening0/LLoff.
Deband/chroma precede MetalFX, AR follows it. Profiles:

- window: strength.5, threshold9RGB8 codes, radius24input pixels, protection1, one iteration.
- chroma: bilateral3 strength.35; AR: coherent-edge strength1.
- combined: window + chroma + AR above; not the older menu Combined Mild preset.
- aggressive: combined with window strength.9, threshold12, radius32, protection.75,
  chroma strength.6. Only parameter tuning of current spatial kernels, no learned restoration.
- reference-strong: libplacebo-style adaptation, threshold9RGB8 codes, radius16, iterations2,
  strength1, no grain. This is MUCH stronger than the upstream-default reference preset
  (threshold.765RGB8, one iteration). Adapted deterministic PRNG differs from upstream.

First/middle/last full6K PNGs are compared with MetalFX of the matched source reference.
Numbers are mean relative RGB-MAE reductions over three frames, positive closer to reference.
Global MAE is not a perceptual score, cannot distinguish desirable denoising from destroyed
texture and does not evaluate temporal stability. The reference also contains MetalFX artifacts.

| Scene/rate | Input RGB8 MAE | Window | Combined | Aggressive | Reference-strong |
|---|---:|---:|---:|---:|---:|
| Lips/10M | 5.8983 | +0.36% | +0.39% | +0.41% | -5.90% |
| Lips/12M | 5.8332 | +0.31% | +0.34% | +0.29% | -6.87% |
| FlowerFocus/10M | 3.5016 | +0.77% | +0.82% | +0.19% | -17.13% |
| FlowerFocus/12M | 3.4811 | +0.72% | +0.77% | +0.12% | -17.91% |
| FlowerKids/10M | 3.1527 | +0.53% | +0.75% | +0.15% | -24.66% |
| FlowerKids/12M | 3.0378 | +0.53% | +0.76% | +0.12% | -26.41% |

Lips source fine grain/texture becomes coarser patches after H264; the current spatial filters
only slightly smooth this. FlowerFocus shows the tradeoff particularly well: aggressive helps
the sampled soft-background ROI more, while worsening its sampled petal ROI versus reference.
In FlowerFocus10M, background ROI MAE reduction is1.38% combined /1.95% aggressive; petal ROI
is+0.73% /-0.32%. Aggressive lowers petal ROI gradient energy to91.6% of compressed input,
versus94.3% combined. This is intervention, not proof of lost true detail: grain and detail mix.

Reference-strong worsens global error by~6–26% here and raises gradient energy in these ROIs;
it is not adequately described as merely smoother. The experiment does not establish whether
all added variation is undesirable or make a claim about upstream libplacebo default output.
These findings argue against increasing spatial strength globally or selecting it by bitrate.
The mild combined profile has the better numerical tradeoff in most of these cases. Neither
version restores the original fine texture. A normal-distance motion A/B on6K is still required.

## Clean GPU run

A separate AVAssetReader changing-frame run AFTER all encodes/readbacks finished uses100/100/120
frames, first10 warmup, six serial scalers and one command buffer in flight. No PNG, CPU readback
or preview encode. Timings include CI conversion + MetalFX + filter GPU work; exclude decode,
drawable composition and physical presentation. Not realtime paced or a full-player fps claim.
Median/P95 milliseconds at4K to6144x3456, nominal10M inputs:

| Scene | MetalFX only | Window | Combined | Aggressive |
|---|---:|---:|---:|---:|
| Lips | 1.80/1.84 | 3.27/3.34 | 4.97/5.04 | 5.03/5.10 |
| FlowerFocus | 1.79/2.15 | 3.22/4.01 | 4.94/5.50 | 5.02/5.48 |
| FlowerKids | 1.77/1.81 | 3.26/3.31 | 4.99/5.06 | 5.12/5.18 |

Strengthening costs little additional GPU time in these scenes but does not yield a consistent
quality improvement. Source/output scratch allocations are the same as the earlier pipeline
bench; the offline multivariant runner holds several scalers and uses more memory than one
presentation path. Underlying shaders and data flow are unchanged.

## Deliverables and checks

The test set contains six full4K encoded
inputs for the player. Each scene has 10 and 12 Mbit/s result sets containing comparison.mp4 plus24
full6K PNGs (control+7profiles times3frames), report.json and a preview-only rerun report.
comparison.mp4 has three columns: before H264 / compressed input / aggressive filtered output;
two rows are512x512 native6K pixel regions. It is a CRF12 diagnostic preview, so additional
preview compression and sRGB conversion exist. Numerical metrics use PNGs, never preview video.
All six videos were checked for correct frame counts/fps/dimensions and upright orientation
against the PNG ROIs. They illustrate local defects, not normal-distance full-frame appearance.

quality.json includes378 global/ROI rows with MAE, correction magnitude and ROI gradient energy.
source-verification.json records320 exact control frames and independent first-frame checks.
Source metadata, copyrights, prep/decoder/probe scripts, compile/run logs and actual encoder
settings remain external. No media/private file names or runtime feature added to repository.
Product tests/build not rerun for this external experiment and bench-document-only change.
