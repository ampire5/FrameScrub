# Live scrub with the production frame cache

2026-11-19 · Apple M4 Max, macOS 27.2.1 · native arm64 release build.
The harness runs the production `PlayerCore`, `CacheFiller` decoder workers,
`FrameCache` and `VideoView` in a visible 1280×720 AppKit window with bilinear
scaling. The screen refreshes at 60 Hz. Settings, resume state, audio,
filmstrip and optional display effects stay outside this harness. The input
endpoint is dispatch of `PlayerCore.scrub(by:)`, and the output endpoint is
`MTLDrawable.presentedTime` for the exact requested frame. Both policies use
hardware VideoToolbox in the final runs. [Metal presentation timestamp](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)

The cache limit is 256 MiB. After indexing and a brief warm start the trace
seeks back and forth over 48 frames per leg, with three legs in each direction.
This span exceeds the capacity of all four configurations and moves the cached
boundary as background decoding proceeds. Burst dispatches at a nominal
59 Hz and can replace requests that are still waiting for their frame. Ack
starts each next request when the previous requested frame appears, with a
700 ms timeout. It measures the full distribution of completed steps at a
lower effective cadence. A timeout or a replacement contributes to the
miss count. Latency percentiles are calculated from exact-frame presentations
that occurred, so burst p99 must be read alongside the shown count.

Bosphorus uses the first 96 decoded frames of the UVG 4K footage, encoded to
4K60 H.264 with a closed 30-frame GOP for a conventional hardware-decode input.
Jellyfish uses the unchanged HEVC Main10 bitstream from the earlier study.
[UVG dataset](https://ultravideo.fi/dataset.html) · [Inputs and offline codec benchmarks](nv12-cache-benchmark.md) · [Native packed P010 probe](native-packed-p010.md)

## Results

Each valid run has 144 requests in each direction. Paired values are forward /
backward. CPU is the whole benchmark process as a percentage of one core.
RAM is the cache's charged bytes at trace end. Decoded counts new decoder insertions,
and restored counts promotions from the packed tier during the trace. The boundary
counter tracks changes to the highest resident frame. The second Jellyfish ack pair
was excluded when macOS reported an occluded window.

| Input | Cadence | Run | Cache | End frames | End MiB | Shown of 144 | p99 to screen, ms | CPU, % of one core | Decoded | Restored | Boundary changes |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Bosphorus | burst | 1 | plain | 21 | 249.2 | 143 / 142 | 65.99 / 65.60 | 11.8 | 310 | 0 | 195 |
| Bosphorus | burst | 1 | compressed | 36 | 244.4 | 144 / 144 | 48.90 / 49.21 | 51.9 | 347 | 265 | 157 |
| Jellyfish | burst | 1 | plain | 10 | 237.3 | 141 / 12 | 49.34 / 82.13 | 10.0 | 235 | 0 | 146 |
| Jellyfish | burst | 1 | compressed | 16 | 249.2 | 144 / 92 | 48.98 / 58.40 | 10.3 | 303 | 0 | 162 |
| Bosphorus | ack | 1 | plain | 21 | 249.2 | 144 / 144 | 32.95 / 32.97 | 6.6 | 314 | 0 | 231 |
| Bosphorus | ack | 1 | compressed | 36 | 244.4 | 144 / 144 | 32.95 / 32.97 | 27.1 | 346 | 276 | 205 |
| Jellyfish | ack | 1 | plain | 10 | 237.3 | 144 / 144 | 49.34 / 99.57 | 7.8 | 306 | 0 | 197 |
| Jellyfish | ack | 1 | compressed | 16 | 249.2 | 144 / 144 | 40.59 / 82.90 | 7.3 | 307 | 0 | 187 |
| Bosphorus | ack | 2 | compressed | 36 | 244.5 | 144 / 144 | 32.93 / 32.97 | 28.8 | 347 | 274 | 201 |
| Bosphorus | ack | 2 | plain | 21 | 249.2 | 144 / 144 | 38.43 / 47.54 | 6.7 | 314 | 0 | 230 |

For NV12, the prefetch worker restored 265–276 packed frames during each
compressed run. On Bosphorus every requested frame was ready at dispatch
in those runs. The 59 Hz burst used 51.9% of one core versus 11.8% for plain
NV12. The ack runs used 27.1–28.8% versus 6.6–6.7%. This is the work of
packing, prefetching and decoding under a moving boundary. A ready-cache
lookup by itself does not measure that cost.

For Main10 the cache grew from 10 to 16 frames and the display acknowledged
more requests in backward burst. The Main10 p99 from acknowledged steps
improved even when every request had to reach the screen. The burst results
for Main10 are still limited by the decoder catching up after a reversal.

## Reproduce

Prepare the Bosphorus NV12 and Jellyfish MP4 files as in the linked
codec benchmarks, then run the production bench with the desktop visible.

```sh
BENCH_DIR=/path/to/benchmark-inputs
ffmpeg -nostdin -hide_banner -loglevel error \
  -f rawvideo -pixel_format nv12 -video_size 3840x2160 -framerate 60 \
  -i "$BENCH_DIR/bosphorus.nv12" -map 0:v -c:v libx264 -threads 2 \
  -preset ultrafast -crf 18 -bf 2 -g 30 -keyint_min 30 -sc_threshold 0 \
  -pix_fmt yuv420p -colorspace bt709 -color_trc bt709 -color_primaries bt709 \
  "$BENCH_DIR/Bosphorus-h264.mp4"
swift build --jobs 4 -c release --product FrameScrub
for cadence in burst ack; do
  for clip in Bosphorus-h264 Jellyfish; do
    for policy in plain compressed; do
      .build/release/FrameScrub --bench-cache-scrub "$BENCH_DIR/$clip.mp4" "$policy" "$cadence"
    done
  done
done
```
