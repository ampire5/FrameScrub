# Lossless decoded-frame cache

2026-11-18 · M4 Max, 36 GB · macOS 27.2.1 · native arm64 release build with Apple Clang 21.
All inputs were 3840×2160 filmed footage. Bosphorus and Jockey are the UVG 8-bit HEVC elementary
streams. Jellyfish is the first 96 frames of the 120 Mbit/s HEVC Main10 clip, decoded from the
first 64 MiB of the container. In a check of 65,536 Jellyfish luma samples, 48,740 used at least
one of the two low sample bits. [UVG dataset and attribution](https://ultravideo.fi/dataset.html) ·
[Jellyfish mirror](https://larmoire.org/jellyfish/)

## Method

- Current uses the production `FrameCache` holding app-owned IOSurface-backed NV12 or P010 buffers.
  LZ4 uses Apple's Compression framework with independent Y and UV payloads per frame and a raw
  fallback for incompressible input. Packed P010 stores four 10-bit samples per five bytes
  and uses NEON for 16-sample groups on arm64.
  Each alternative restores directly into one reusable IOSurface-backed output buffer for these 4K
  strides. Before timing, the bench checks every retained compressed frame against the source with
  byte-for-byte comparison of the active pixels in both planes.
- Every mode has a 256 MiB cap. The harness charges the actual IOSurface allocation or malloc
  allocation for each retained frame and charges the restoration buffer to LZ4 and packed P010.
  The table also gives the process's measured physical footprint increase over the pre-cache
  baseline (`TASK_VM_INFO.phys_footprint`). Whole frames leave different amounts of budget unused.
  Source staging and fill scratch are common to all modes and are allocated before the baseline.
- Three fresh processes per row with mode order rotated. The NEON version of packed P010 was
  measured in a separate three-run series. In each run one thread receives requests
  at 60 Hz. A trace traverses the same eight contiguous frames, changing direction every seven
  steps, for 182 cache hits in each direction. Wall time runs from beginning of the request to a
  ready pixel buffer. CPU uses the thread CPU clock. Core percentage is mean CPU per hit multiplied
  by 60 hits per second. A separate 32-frame span measures coverage from the start of the prefilled
  window in either direction. The trace holds the cache window fixed.
- The test isolates cached frame access. Source video decoding runs before timing. Rendering,
  input dispatch, filling during motion, miss recovery and the production VideoToolbox service
  footprint are outside the timed workload. The baseline therefore represents the production cache
  data structure and buffer format with the decoder out of the measurement. Holding multiple
  restored buffers through GPU completion in the app would spend more of the cache budget.

## Results

Each p95, p99, and CPU value is the median of the corresponding values in the three runs.
In the paired columns the first number is forward and the second is backward.

| 4K clip | Cache | Frames | Physical MiB | Hits in 32-frame span | p95 ms F / B | p99 ms F / B | % of one core F / B |
|---|---|---:|---:|---:|---:|---:|---:|
| Bosphorus NV12 | Current | 21 | 249.72 | 21 | 0.004 / 0.005 | 0.008 / 0.008 | 0.008 / 0.008 |
| Bosphorus NV12 | LZ4 | 39 | 255.94 | 32 | 4.811 / 4.719 | 5.114 / 5.022 | 27.8 / 27.6 |
| Jockey NV12 | Current | 21 | 249.70 | 21 | 0.007 / 0.007 | 0.013 / 0.010 | 0.018 / 0.017 |
| Jockey NV12 | LZ4 | 35 | 253.38 | 32 | 5.059 / 4.989 | 5.295 / 5.193 | 29.1 / 28.5 |
| Jellyfish P010 | Current | 10 | 237.61 | 10 | 0.022 / 0.021 | 0.143 / 0.096 | 0.060 / 0.056 |
| Jellyfish P010 | LZ4 | 13 | 246.45 | 13 | 9.868 / 9.783 | 9.924 / 9.916 | 57.4 / 56.5 |
| Jellyfish P010 | Packed, NEON | 15 | 246.81 | 15 | 3.911 / 4.215 | 5.116 / 5.128 | 16.0 / 15.8 |

The worst p99 of any individual run was 9.06 ms on Jockey LZ4, 10.43 ms on
Jellyfish LZ4 and 6.65 ms on Jellyfish packed NEON. Request completion after the next
16.67 ms deadline happened on both current and compressed paths. This counter includes scheduler
wake-up delays and is available in the command output.

Without the explicit NEON implementation, the compiler-autovectorized P010 loop used
32.7% / 33.1% of one core with 6.02 / 6.01 ms p95. The NEON implementation kept the same
format and frame count. Retained-frame encoding used 1.78 ms CPU per frame for packed P010
and 41.35 ms for LZ4 on Jellyfish, including the copy into owned storage. LZ4 used
16.99–18.34 ms per frame on the NV12 clips.

LZ4 retained 67–86% more NV12 frames under the cap. Packed P010 retained 50% more
Jellyfish frames and used about one quarter to one third of the LZ4 restore CPU.
Keep ready buffers around the playhead, with compact storage for more distant frames.
The measured LZ4 fill cost makes it a candidate for selective background compression.

## Reproduce

From the checkout root, build the benchmark and prepare its inputs with local paths in
`BENCH_DIR`. Keep raw files outside the checkout.

```sh
BENCH_DIR=$(mktemp -d /private/tmp/framescrub-frame-cache.XXXXXX)
xcrun clang -O3 -c scripts/bench/frame-cache-p010.c -o "$BENCH_DIR/packed.o"
xcrun clang -O3 -I Sources/CNV12Bitpack/include -c Sources/CNV12Bitpack/Bitpack.c -o "$BENCH_DIR/nv12pack.o"
xcrun swiftc -O -module-cache-path "$BENCH_DIR/module-cache" \
  -import-objc-header scripts/bench/frame-cache-p010.h \
  scripts/bench/frame-cache{,-formats}.swift \
  -I Sources/CNV12Bitpack/include \
  Sources/FrameScrubCore/{DecodedFrame,FrameCache,PackedNV12Frame,TimelineClickMotion,TimelineProjection}.swift \
  "$BENCH_DIR/packed.o" "$BENCH_DIR/nv12pack.o" -o "$BENCH_DIR/frame-cache"

for clip in Bosphorus Jockey; do
  curl -fLsS -o "$BENCH_DIR/$clip.hevc" \
    "https://ultravideo.fi/video/${clip}_3840x2160_120fps_420_8bit_HEVC_RAW.hevc"
  ffmpeg -nostdin -hide_banner -loglevel error -threads 2 -i "$BENCH_DIR/$clip.hevc" \
    -map 0:v:0 -frames:v 96 -filter_threads 1 -c:v rawvideo -threads 1 \
    -pix_fmt nv12 -f rawvideo "$BENCH_DIR/$clip.nv12"
done
curl -fLsS --max-filesize 67108864 --range 0-67108863 -o "$BENCH_DIR/Jellyfish.mkv" \
  'https://larmoire.org/jellyfish/media/jellyfish-120-mbps-4k-uhd-hevc-10bit.mkv'
ffmpeg -nostdin -hide_banner -loglevel error -threads 2 -i "$BENCH_DIR/Jellyfish.mkv" \
  -map 0:v:0 -frames:v 96 -filter_threads 1 -c:v rawvideo -threads 1 \
  -pix_fmt p010le -f rawvideo "$BENCH_DIR/Jellyfish.p010"

for clip in Bosphorus Jockey; do
  for mode in current lz4; do
    "$BENCH_DIR/frame-cache" "$mode" 3840 2160 8 256 8 < "$BENCH_DIR/$clip.nv12"
  done
done
for mode in current lz4 packed; do
  "$BENCH_DIR/frame-cache" "$mode" 3840 2160 10 256 8 < "$BENCH_DIR/Jellyfish.p010"
done
```
