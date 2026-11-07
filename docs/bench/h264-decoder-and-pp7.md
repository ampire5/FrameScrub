# H.264 decoder access, PP7 and compact restoration models

2026-11-07, M4 Max,36GB, macOS27.2. Standalone research; no product changes.
Source material/provenance follows [the 4K bench](algorithmic-deblock-4k.md).

## Access before and during decoding

FrameScrub's primary H.264/HEVC backend sends compressed packets to its own asynchronous
hardware VideoToolbox session (`VTBackend.makeSession/send`). Its software fallback
(`FFmpegBackend.open/send`) does not configure `skip_loop_filter`; only frame skipping
is changed for permitted non-reference-frame dropping. There is no application switch
currently disabling the normative H.264 loop filter.

A native standalone probe created a real H.264 hardware session: creation, supported-property
copy and hardware-property queries all returned0; hardware=true. No deblock-strength or
loop-filter override appeared among its supported keys. The installed public
`VTDecompressionProperties.h` also has no such control. `RealTime` is a scheduling hint,
not restoration strength. Some runtime property names are undocumented and are not adopted
or recommended as product interfaces.

Four16-frame H.264 test streams: FFmpeg default decoding exactly matches explicit
`skip_loop_filter=none` by per-frame raw-YUV hashes. Explicit `all` differs on all16 frames
of every stream. This confirms the software baseline already performs signaled deblocking;
it is not a VideoToolbox output-parity test.

`-c:v copy -bsf:v trace_headers` successfully read PPS initial QP, slice QP deltas and
deblocking flags/offsets without pixel decoding. On the townQP34 fixture, PPS initial QP
offset is8, slice deltas vary, disable_deblocking_filter_idc=0, alpha/beta offsets=0.
The existing `ParameterSets` parser does not yet expose these H.264 facts. A bounded
read-only packet/header parser is a plausible addition if a tested downstream filter
can use that information. Slice QP is not a complete per-macroblock QP map; entropy-coded
macroblock changes/motion data require more work and are not extracted by this demo.

Rewriting filter/QP headers is not a free enhancement: it changes interpretation of the
encoded reconstruction and potentially its reference pictures. No stream rewriting or
decoder fork was implemented. Standards/source references:
[H.264 specification](https://www.itu.int/rec/T-REC-H.264),
[FFmpeg slice decoding](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/h264_slice.c).
The [bitstream-metadata restoration paper](https://arxiv.org/abs/2202.00011) is relevant
research support for using existing compression/motion information in postprocessing,
not evidence of an immediately usable Apple implementation.

## Ready-made PP7

FFmpeg CPU PP7, forced qp4/hard, qp8/medium, qp16/soft. Seven cases: town/park
clean+QP34+QP42,16frames each, and AppleQP34,90frames.558 quality frames processed;
first/middle/last native4K PNGs and exact two512×512 crop sequences retained. Separate
16-frame timings include software decode+filter+null output, two decoder/filter threads;
one run per case/profile, excluding RGB conversion/PNG/display.448 timing frames processed.

| Apple4K case | Wall ms/frame |
|---|---:|
| Decode/null | 5.31 |
| PP7 hard/qp4 | 216.25 |
| PP7 medium/qp8 | 208.69 |
| PP7 soft/qp16 | 187.69 |

Hard mode preserves more small structure but can emphasize residual texture. Soft mode
smooths sky/noise more, also softens roofs/foliage and leaves large patch boundaries.
On townQP34 ROIs: input PSNR28.096dB; hard28.182, medium28.146, soft27.763. On parkQP34,
all tested modes reduce PSNR against the pre-encode reference. Grain/texture complicates
interpretation; native crops do not establish a major restoration gain. The existing CPU
implementation misses the budget substantially. These timings do not predict Metal performance.

Reference: [DeblockPP7 description](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DeblockPP7).
The external research workspace holds scripts, logs, raw metric data,
full-resolution images and lossless crop sequences. No PP7 port/dependency added to the app.

## H.264-specific compact models

Found and tested the1× models from
[Super-Video-Decompression](https://github.com/Fransferdy/Super-Video-Decompression),
commit `67ed9a7a971fd1ea5c91592dfd4b1c11e476a1f4`. Author describes H.264-degraded training
using Blender animations, not JPEG-only training. Natural-video generalization is not assured.
This is a different candidate from the previously tested DeH264 RealPLKSR model.

Weights loaded with `weights_only=True`, `strict=True`; actual1× parameter counts below.
Reviewed architecture: ten3×3 convolutions with featurewise PReLU between them and RGB
residual addition. Local equivalent omits only identity PixelShuffle1/nearest-scale1.
RGB0…1 input agrees with the author's production RGBA wrapper. No unreviewed training code run.

| Model | Actual parameters | MPS FP16 median | CoreML CPU+GPU median | CoreML ALL median |
|---|---:|---:|---:|---:|
| Super | 43,203 | 111.34ms | 119.22ms | 270.45ms |
| Mega | 90,723 | 266.74ms | 297.06ms | 415.63ms |
| Ultra | 299,523 | 430.68ms | 463.24ms | 784.86ms |

Native3840×2160, batch1. MPS:2warmups+5timed resident-input runs with synchronization,
two CPU threads, inference mode. CoreML FP16 MLProgram, fixed1×3×2160×3840, macOS15 target:
first call recorded separately, four warm predictions/unit choice. Decode/PNG excluded.
ALL permits Neural Engine; actual operator placement was not profiled, so these are not
ANE-only measurements. No memory cap was raised; reported driver allocations after MPS
runs are about1.09/1.67/3.22GB, not whole-process or peak memory measurements.

Seven natural-source cases ×3models evaluated as single full4K images, not temporal video.
Outputs can add contour-like/fine synthetic texture in smooth sky and alter foliage/grass.
Small PSNR gains on the measured compressed ROIs do not establish visually faithful
restoration. These models are not recommended for the requested few-ms4K playback budget.

FP32/FP16 native256×256 crop checks: mean discrepancy about0.042 RGB8 codes, max<0.263.
CoreML/MPS full-frame RGB8 comparison: CPU+GPU mean<0.0023, ALL<0.045, P99≤1 code.
The unwanted structure is therefore not plausibly explained by a large FP16/conversion error.
The external research workspace retains source pin, weight hashes,
scripts, safe-loaded weights, trace/CoreML packages, timing/parity data and public-image comparisons.

## Updated quality target

The requested improvement includes unstable edge noise during motion, banding and unnatural
chroma roughness on smooth textures. A single annotated still cannot establish their temporal
cause, and the supplied private illustration is not copied into repository artifacts.

Future comparisons should separate edge ringing/mosquito-like noise, gradient banding and
chroma cleanup; evaluate real motion, protect luminance detail, keep intermediate precision,
and test final-output dithering where quantization would reintroduce banding. A denoiser is
not automatically a debander/deblocker. Avoid judging by global sharpness alone. Compare
with additional display sharpening disabled (`sharpen=0`; current default0.3), because it
can accentuate defects; this is an experiment setting, not a claim that sharpening caused
the source damage. Existing TNF playback deadline limitations still apply.

The next source-specific temporal evaluation needs an original clip/time range; no diagnosis
or successful correction of the illustrated motion artifact is claimed from the screenshot.
Product tests were not rerun for external experiments and bench-document-only changes.
