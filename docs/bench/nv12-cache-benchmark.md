# Lossless NV12 cache benchmark

2026-11-19 · M4 Max, 36 GB · macOS 27.2.1 · release arm64. The inputs are
96 decoded 3840×2160 NV12 frames each from Bosphorus, Jockey, and HoneyBee.
The 8-bit HEVC sources are the compact 120 fps variants from UVG.
[UVG dataset and attribution](https://ultravideo.fi/dataset.html) · [Prior research](nv12-research.md)

## Codec screen

Each run fills an identical 256 MiB cache budget, then scrubs over the same first
eight frames in both directions at 60 requests per second. There are 56 samples
per direction. This screen times the request up to a usable pixel buffer.
Compressed modes include one reusable restore IOSurface in the allocation budget.
Staging memory used for fill and the timed decoder's scratch are initialized before the
process-footprint baseline. The retained frame counts use allocation sizes.
The footprint column is the observed process delta, including accounting and allocator
overhead. CPU time during fill includes the copy into owned storage. Every retained
compressed frame was compared byte for byte with its source in both planes.

B/J/H are Bosphorus, Jockey, and HoneyBee. Each latency and CPU range spans the
three clips and both directions when direction is applicable.

| Mode | Retained frames B/J/H | Physical footprint delta, MiB | Restore p95, ms | Restore p99, ms | Restore CPU, ms/request | Fill CPU, ms/frame |
|---|---:|---:|---:|---:|---:|---:|
| Current NV12 | 21 / 21 / 21 | 249.64–249.66 | 0.02–0.04 | 0.02–0.06 | <0.02 | — |
| Apple LZ4 (framed) | 39 / 35 / 29 | 253.36–255.92 | 5.71–6.51 | 5.94–6.83 | 4.97–6.06 | 15.99–20.86 |
| Apple LZ4 raw | 39 / 35 / 29 | 252.94–255.39 | 5.88–6.63 | 5.97–7.09 | 4.81–5.75 | 15.87–20.82 |
| liblz4 1.11.1 | 42 / 38 / 29 | 250.25–255.38 | 5.92–6.77 | 6.16–6.91 | 4.40–4.97 | 17.55–19.32 |
| Apple LZBITMAP | 49 / 45 / 37 | 251.70–256.38 | 4.55–5.99 | 4.93–6.59 | 3.14–4.01 | 29.74–31.14 |
| Zstd 1.5.7 −1 | 52 / 48 / 32 | 252.11–255.39 | 8.82–9.88 | 9.03–9.94 | 7.16–9.24 | 20.86–22.84 |
| Vertical delta + liblz4 | 48 / 44 / 40 | 251.05–254.78 | 5.68–6.88 | 6.19–8.32 | 5.26–6.41 | 15.29–17.62 |
| 32-sample bitpack (NEON) | 43 / 40 / 31 | 251.72–256.56 | 1.31–4.73 | 1.41–5.17 | 1.23–2.78 | 1.70–1.81 |

The bitpack prototype stores the minimum plus unsigned 0-, 2-, 4-, or 6-bit
offsets in each block of 32 samples, or stores a tagged raw block. It processes UV
as independent U and V blocks and restores the original interleaving. It is
inspired by the range coding of reconstructed HEVC reference frames in Tikekar
et al. The CPU bit layout and group size are specific to this benchmark.
Vertical delta + LZ4 subtracts the preceding row modulo 256, applies liblz4, then
restores rows in place with vectorized additions. All tested formats store each
frame independently. [Tikekar et al., §III-A](https://eems.mit.edu/wp-content/uploads/2018/05/2018_jssc_wearable_hevc.pdf) ·
[High Speed Lossless Image Compression](https://www.visus.uni-stuttgart.de/documentcenter/forschung/Publikationen_Zusatzmaterialien/High-Speed-Lossless-Impression/gcpr2015submission.pdf)

At 4K the measured NV12 IOSurface used 12,450,304 bytes. Allocating a native
lossless `&8v0` or `&8f0` surface used 13,193,344 bytes for either range on this M4 Max.
This probe measures allocation size. Core Video's bandwidth optimization reserves
room for an uncompressed block in each slot. [Core Video](https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput)

## Visible scrub

The window benchmark uses a 1280×720 Metal drawable on a 60 Hz display and
requests frames at 59 Hz. It reverses every seven steps over the same eight
frame numbers. All modes, including current NV12, use the same serial worker
handoff. Restores run on that worker. The two reusable restore IOSurfaces are
charged to the 256 MiB budget, and each slot is released after its GPU command
completes. The mixed trace retains frames 2–5 as NV12 and restores the other
four on demand. The cache is filled and verified before timing. The endpoints
are benchmark request dispatch and `MTLDrawable.presentedTime`; the harness
does not replay AppKit mouse events, prefetch, refill, or run the optional
FrameScrub display filters.
[Metal presentation timing](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)

There are three rotated runs per mode for Bosphorus, and one validation run
per mode for HoneyBee. Each run supplies 182 observations per direction. The
paired values are forward / backward. Bosphorus numbers are medians of run-level
statistics. Process RAM shows the change around fill and includes transient
framework and allocator accounting. The charged budget uses retained payloads
and surfaces. CPU for fill is measured separately in the codec screen.

### Bosphorus

| Mode | Frames | Charged MiB | Process RAM delta MiB | Display p95 ms | Display p99 ms | Main CPU ms | Fetch CPU ms | Process CPU, % of one core | Drops |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Current NV12 | 21 | 249.34 | 249.61 | 35.67 / 37.34 | 39.89 / 41.66 | 0.68 / 0.68 | 0.00 / 0.00 | 14.9 | 0 |
| Apple LZ4 (framed) | 37 | 255.18 | 256.95 | 49.99 / 48.41 | 54.35 / 52.63 | 0.31 / 0.32 | 5.36 / 5.33 | 38.2 | 0 |
| Bitpack | 41 | 251.97 | 252.28 | 37.18 / 36.58 | 39.39 / 39.09 | 0.57 / 0.59 | 2.51 / 2.50 | 26.3 | 0 |
| Mixed NV12 + bitpack | 37 | 254.79 | 254.99 | 37.32 / 38.09 | 39.91 / 39.01 | 0.61 / 0.56 | 1.15 / 1.14 | 19.0 | 0 |

### HoneyBee

| Mode | Frames | Charged MiB | Process RAM delta MiB | Display p95 ms | Display p99 ms | Main CPU ms | Fetch CPU ms | Process CPU, % of one core | Drops |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Current NV12 | 21 | 249.34 | 261.49 | 34.28 / 33.44 | 35.14 / 34.80 | 0.32 / 0.32 | 0.00 / 0.00 | 6.5 | 0 |
| Apple LZ4 (framed) | 27 | 249.59 | 256.25 | 46.51 / 45.77 | 50.47 / 49.93 | 0.34 / 0.34 | 4.19 / 4.09 | 31.3 | 0 |
| Bitpack | 29 | 250.43 | 266.99 | 35.15 / 35.17 | 35.77 / 35.78 | 0.33 / 0.32 | 1.28 / 1.29 | 13.6 | 0 |
| Mixed NV12 + bitpack | 27 | 251.19 | 255.78 | 34.52 / 34.80 | 36.59 / 35.66 | 0.42 / 0.41 | 0.60 / 0.60 | 11.9 | 0 |

Bitpack had the fastest measured restore and fill among the compressed modes.
LZBITMAP and vertical-delta LZ4 can retain more frames on this content with
higher fill and restore CPU. On Bosphorus the mixed bitpack cache kept 37
frames, the same as all-compressed Apple LZ4, with 39.91 / 39.01 ms p99
to presentation versus 54.35 / 52.63 ms. It reduced fetch CPU versus restoring
every bitpacked frame. The HoneyBee validation run showed the same ordering
between bitpack and LZ4, with a smaller capacity gain on the more detailed
footage. All 5,824 requests in the visible runs reached presentation.

The next implementation candidate is a ready NV12 window with distant
bitpacked frames. A production check should exercise moving cache boundaries
and simultaneous filling, with a bounded restore worker, before selecting a
default ready-window size.

## Reproduce

Build from the checkout root with the existing P010 packer and the bench-only
liblz4 and libzstd dependencies. Local inputs and binaries live outside the
checkout.

```sh
BENCH_DIR=$(mktemp -d /private/tmp/framescrub-nv12.XXXXXX)
LZ4_DIR=$(brew --prefix lz4)
ZSTD_DIR=$(brew --prefix zstd)
xcrun clang -O3 -c scripts/bench/frame-cache-p010.c -o "$BENCH_DIR/packed.o"
xcrun clang -O3 -I Sources/CNV12Bitpack/include -c Sources/CNV12Bitpack/Bitpack.c -o "$BENCH_DIR/nv12pack.o"
xcrun clang -O3 -Wall -Wextra -Werror -I "$LZ4_DIR/include" -I "$ZSTD_DIR/include" \
  -c scripts/bench/nv12-codecs.c -o "$BENCH_DIR/nv12.o"
xcrun swiftc -O -D NV12_CODECS -module-cache-path "$BENCH_DIR/modules" \
  -import-objc-header scripts/bench/nv12-codecs.h scripts/bench/frame-cache{,-formats}.swift \
  -I Sources/CNV12Bitpack/include \
  Sources/FrameScrubCore/{DecodedFrame,FrameCache,PackedNV12Frame,TimelineClickMotion,TimelineProjection}.swift \
  "$BENCH_DIR/packed.o" "$BENCH_DIR/nv12.o" "$BENCH_DIR/nv12pack.o" -L "$LZ4_DIR/lib" -L "$ZSTD_DIR/lib" \
  -llz4 -lzstd -o "$BENCH_DIR/frame-cache"
xcrun swiftc -parse-as-library -O -D NV12_CODECS -module-cache-path "$BENCH_DIR/modules" \
  -import-objc-header scripts/bench/nv12-codecs.h scripts/bench/frame-cache-display/*.swift \
  scripts/bench/{frame-cache-formats,nv12-display-source}.swift \
  -I Sources/CNV12Bitpack/include \
  Sources/FrameScrubCore/{DecodedFrame,FrameCache,PackedNV12Frame,TimelineClickMotion,TimelineProjection}.swift \
  "$BENCH_DIR/packed.o" "$BENCH_DIR/nv12.o" "$BENCH_DIR/nv12pack.o" -L "$LZ4_DIR/lib" -L "$ZSTD_DIR/lib" \
  -llz4 -lzstd -o "$BENCH_DIR/frame-cache-display"

for clip in Bosphorus Jockey HoneyBee; do
  curl -fLsS -o "$BENCH_DIR/$clip.hevc" \
    "https://ultravideo.fi/video/${clip}_3840x2160_120fps_420_8bit_HEVC_RAW.hevc"
  ffmpeg -nostdin -hide_banner -loglevel error -threads 2 -i "$BENCH_DIR/$clip.hevc" \
    -map 0:v:0 -frames:v 96 -filter_threads 1 -c:v rawvideo -threads 1 \
    -pix_fmt nv12 -f rawvideo "$BENCH_DIR/$clip.nv12"
  for mode in current lz4 apple-raw liblz4 bitmap zstd row-delta bitpack; do
    "$BENCH_DIR/frame-cache" "$mode" 3840 2160 8 256 8 8 < "$BENCH_DIR/$clip.nv12"
  done
done

# Run with a visible desktop for presentation latency.
for mode in current lz4 bitpack mixed-bitpack; do
  "$BENCH_DIR/frame-cache-display" "nv12-$mode" "$BENCH_DIR/Bosphorus.nv12" 59
done
```
