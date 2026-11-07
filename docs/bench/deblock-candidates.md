# Ready-made 4K deblocking candidates

2026-11-07, M4 Max, macOS27.2. Separate FFmpeg CPU experiment, not FrameScrub integration or a Metal benchmark.
The source is four seconds of Apple's public FRC4K sample, re-encoded H.264 QP42 (veryfast), 3840x2160/30fps.

Each timing processes24frames with two decoder threads and filter_threads2, output null. Wall time includes software
decode, filter and drain; excludes display. Baseline is the same command with null filter. A single initial run was
followed by three repeats for the fast candidates; file/driver caches are warm. This is a short clip, not proof of
sustained playback or cross-content performance. A direct Apple TNF worker time is not the same measurement stage.

| Branch | Wall ms/frame | Scope |
|---|---:|---|
| Decode/null | 3.42 | median of3 runs |
| deblock weak, grid8 | 6.17 | median of3 runs |
| deblock strong, grid8 | 8.13 | median of3 runs |
| deblock strong, grid16 | 4.71 | median of3 runs |
| spp quality2, qp16 | 65.83 | one run |
| fspp quality4, qp16 | 178.71 | one run |

`deblock` is the only tested ready-made candidate with a comfortable raw4K CPU timing on this machine. Its quality
in the inspected crop is modest: block edges are softened, large residual structures/lost texture remain. SPP/FSPP
smooth more of the ringing but also more detail, and their tested CPU configurations are too expensive for real-time
4K here. Do not infer that "Fast" in FSPP promises ARM/Apple throughput. Other settings/content may differ.

PNG comparisons use matching frame90 at3seconds, same conversion pipeline and identical native512x288 crop. They
are saved outside the repo together with exact filter strings, scripts, logs and repeat-results.json. No user media
or model-specific private setup is included. There is no new app filter integration in this comparison.

For neural compression cleanup, the author's DeH264 RealPLKSR model explicitly targets H.264 photography at1x:
https://github.com/Phhofm/models/releases/tag/1xDeH264_realplksr . It is a quality candidate, not a measured real-time
4K solution on Apple silicon. JPEG-only models cannot be assumed to repair H.264/HEVC equally well.

Follow-up: [standalone DeH264 experiment](deh264.md) measured Metal and direct Core ML.
It changes the image visibly but adds artificial texture, and the tested full4K tiled pass
took28seconds. It was not integrated into the app.

FFmpeg deblock/fspp/spp reference: https://ffmpeg.org/ffmpeg-filters.html . Any future native implementation needs
its own quality and end-to-end latency verification; these numbers are not a Metal-port speed promise.
