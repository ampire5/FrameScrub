# Native packed P010 cache and display

2026-11-18 · M4 Max, 36 GB · macOS 27.2.1 · Apple GPU with unified memory.
Input is the same real 3840×2160 120 Mbit/s Jellyfish HEVC Main10 clip as in the
[decoded-frame cache benchmark](decoded-frame-cache.md). FFmpeg copies the video bitstream from
the partial Matroska input to MP4 with the `hvc1` tag.

## Native format probe

A `VTDecompressionSession` with hardware acceleration required and Metal-compatible IOSurface
output returned the requested FourCC for all 16 decoded frames in each probe. Both sessions
reported hardware acceleration. The packed format passed `CVIsCompressedPixelFormatAvailable`.
After matching PTS, Core Image rendered three entire frames of each format to linear RGBA16F.
Every rendered channel value matched across the three pairs. A separate
`VTPixelTransferSession` conversion to conventional P010 changed chroma samples on the first
frame. CPU consumers of the decoded planes need their own validation before adopting the
packed format. [VideoToolbox](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessioncreate(allocator:formatdescription:decoderspecification:imagebufferattributes:outputcallback:decompressionsessionout:)) ·
[Core Video pixel formats](https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput)

| VideoToolbox output | Bytes per frame | MiB per frame | Frames at 256 MiB | Retained IOSurface MiB |
|---|---:|---:|---:|---:|
| Standard P010 `x420` | 24,891,904 | 23.739 | 10 | 237.388 |
| Native packed `&xv0` | 16,329,664 | 15.573 | 16 | 249.171 |

The sum counts distinct retained IOSurface IDs at `IOSurfaceGetAllocSize`, including plane
padding and metadata, after the decoder session is invalidated. Packed allocation is 34.4%
smaller per surface. At 10 frames it uses 155.7 MiB of surface storage. These figures describe
the live cache surfaces and exclude renderer resources and the decoder's temporary pool.
The app's `phys_footprint` delta is logged separately and does not reflect every shared
decoder-owned allocation. [IOSurface allocation size](https://developer.apple.com/documentation/iosurface/iosurfacegetallocsize%28_%3A%29)

## Scrub workload

The display harness uses the production `FrameCache`, Core Image's `CIImage(cvPixelBuffer:)`
entry point and an identical scale to 1280×720 in each mode. It drives eight already-cached
frames, reverses after seven steps, and requests 182 frames per direction in each run.
Frames are decoded before the trace. Main-thread CPU includes cache lookup, rendering submission
and command commit. Process CPU averages all benchmark process threads. The endpoint for the
window mode is `MTLDrawable.presentedTime`. Occlusion invalidates the window run.
[Metal Drawable presentation timing](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)

### Offscreen results

Medians of three runs per format at 60 Hz with order rotated. The paired numbers are forward / backward.
Latency runs from the input tick to the Metal command completion callback.

| Format | p95 ms | p99 ms | Main CPU ms / request | GPU p95 ms | Process CPU, % of one core |
|---|---:|---:|---:|---:|---:|
| `x420` | 4.64 / 4.67 | 5.11 / 5.07 | 0.71 / 0.72 | 0.574 / 0.575 | 18.7 |
| `&xv0` | 4.01 / 3.92 | 4.55 / 4.95 | 0.73 / 0.75 | 0.342 / 0.353 | 17.0 |

The final series completed all 182 requests per direction in every run. An earlier
exploratory series had wider tails. One packed reverse request was dropped at the
two-command limit and the worst packed reverse p99 in that series was 29.35 ms.

### Onscreen results

2026-11-19 · 60 Hz display · 59 Hz scrub requests · 1280×720 drawable. The table reports
medians of three runs per format, with order rotated. Paired values are forward / backward.
Latency includes the presentation wait and ends at `MTLDrawable.presentedTime`.
All 2,184 requests reached the display, with no occlusion or drops.

| Format | p95 to display, ms | p99 to display, ms | Main CPU ms / request | GPU p95 ms | Process CPU, % of one core |
|---|---:|---:|---:|---:|---:|
| `x420` | 35.93 / 35.60 | 37.05 / 37.35 | 0.768 / 0.726 | 1.180 / 1.110 | 17.6 |
| `&xv0` | 35.20 / 35.23 | 36.29 / 36.12 | 0.742 / 0.721 | 0.868 / 0.934 | 15.4 |

The retained IOSurface sizes repeated in all six runs. Packed output kept 16 frames
instead of 10 without a measured presentation latency penalty. The median latency
differences of 0.37–1.22 ms are small relative to the variation across individual
runs. Both formats used less than 0.8 ms of main-thread CPU per request.

## Reproduce

Use the partial Jellyfish download from the earlier bench and build from the checkout root.

```sh
BENCH_DIR=/path/to/benchmark-inputs
ffmpeg -nostdin -hide_banner -loglevel error -i "$BENCH_DIR/Jellyfish.mkv" \
  -map 0:v:0 -t 3.25 -c:v copy -tag:v hvc1 "$BENCH_DIR/Jellyfish.mp4"
xcrun clang -O3 -I Sources/CNV12Bitpack/include -c Sources/CNV12Bitpack/Bitpack.c -o "$BENCH_DIR/nv12pack.o"
xcrun swiftc -parse-as-library -O -module-cache-path "$BENCH_DIR/module-cache" \
  scripts/bench/frame-cache-display/*.swift \
  -I Sources/CNV12Bitpack/include \
  Sources/FrameScrubCore/{DecodedFrame,FrameCache,PackedNV12Frame,TimelineClickMotion,TimelineProjection}.swift \
  "$BENCH_DIR/nv12pack.o" -o "$BENCH_DIR/frame-cache-display"
"$BENCH_DIR/frame-cache-display" probe "$BENCH_DIR/Jellyfish.mp4"
for mode in x420 packed; do
  "$BENCH_DIR/frame-cache-display" "$mode" "$BENCH_DIR/Jellyfish.mp4" 59
done
```

Run with a visible desktop for presentation timing. A 59 Hz request rate on the 60 Hz
display sweeps the request phase through the refresh period. Use `60 --offscreen` in place
of `59` to time GPU completion.
