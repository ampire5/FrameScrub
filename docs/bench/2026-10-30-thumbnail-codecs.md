# Thumbnail encoding: common photo/video policy

Decision: **JPEG through ImageIO, quality 0.80**, for both applications. Keep SQLite blob storage; codec and database layout are independent. HEIC/AVIF remain optional system-encoder overrides. The native default prioritizes cheap decoding and predictable grid/strip scrolling over retaining the largest possible number of thumbnails.

## Method

Apple Silicon developer Mac, macOS 27.2, optimized Swift/C benchmark on 2026-10-30. Six public Kodak photographic test images (01, 03, 05, 13, 19, 23), from https://r0k.us/graphics/kodak/. No personal pictures are included in the repository. Additional initial checks used system wallpapers, but the table below uses only the photographic corpus.

All encoders receive the same opaque 8-bit sRGB RGBA pixels, resized once to a maximum long side of 256, 480 or 1280. The Kodak sources are 768px maximum, so the 1280 case does not upscale them. JPEG, HEIC and AVIF use ImageIO. Benchmark-only adapters call libjpeg-turbo (4:2:0 and 4:4:4), libwebp, libjxl (effort 3 and 7), and libavif with AOM (speed 6 and 8) directly in the same process. This excludes CLI startup overhead. Third-party codecs use one thread; system codec implementations control their own internal threading. Versions installed for this run: libwebp 1.6, libjxl 0.12, libavif 1.4.2 with AOM 3.15.2. No new third-party production dependency was added.

Quality grid: 0.50, 0.65, 0.80, 0.90, 0.95, 0.98, refined at 480px with 0.84, 0.88, 0.92 and 0.94. Numeric quality is not comparable across codecs. PSNR uses RGB error; SSIM averages non-overlapping native-resolution 8×8 luminance windows. For each implementation, choose the smallest tested output meeting both corpus-mean SSIM ≥ JPEG80 mean − 0.001 and corpus-mean PSNR ≥ JPEG80 mean − 0.5 dB. These are engineering comparison thresholds, not a claim of perceptual equivalence. Report individual-photo deltas as well: averages can hide a regression.

Decode timing includes decompression and a forced sRGB raster, not just creating a lazy CGImage. The extra cell timing is a **synthetic 128px ImageIO path**, with an additional raster copy. Loupe uses variable cell sizes/fill coverage; FrameScrub currently reads the stored picture at full size. Thus the full decode and synthetic cell numbers describe distinct paths, not an exact UI latency forecast.

## 480px photographic results

Means across six photographs; timings in milliseconds. Codec settings differ to meet the stated mean-quality criteria. The earlier refined full-size run supplies full encode/decode times; the synthetic-cell run supplies cell times.

| Encoder | Quality | KB/image | Encode | Full decode | Synthetic 128px ImageIO cell | Mean PSNR | Mean SSIM |
|---|---:|---:|---:|---:|---:|---:|---:|
| ImageIO JPEG | 80 | 62.8 | 0.76 | 0.77 | 0.77 | 38.44 | .9896 |
| libjpeg-turbo 4:2:0 | 94 | 68.9 | 0.33 | 0.60 | 0.65 | 38.64 | .9897 |
| libjpeg-turbo 4:4:4 | 94 | 83.7 | 0.49 | 0.73 | 0.82 | 40.67 | .9899 |
| libwebp | 92 | 51.1 | 11.61 | 2.31 | 2.58 | 39.49 | .9908 |
| libjxl, effort 3 | 94 | 56.0 | 8.30 | 6.03 | 4.30 | 38.98 | .9910 |
| libjxl, effort 7 | 92 | 49.8 | 70.05 | 3.95 | 3.89 | 38.51 | .9908 |
| ImageIO HEIC | 88 | 56.7 | 22.98 | 4.75 | 3.05 | 39.03 | .9934 |
| ImageIO AVIF | 84 | 45.7 | 37.76 | 8.70 | 4.28 | 38.61 | .9900 |
| libavif / AOM, speed 6 | 84 | 42.7 | 62.87 | 3.48 | 5.16 | 39.21 | .9889 |
| libavif / AOM, speed 8 | 88 | 51.2 | 29.17 | 3.85 | 4.80 | 40.13 | .9923 |

Per-photo PSNR delta from JPEG80 ranges: JPEG-turbo 4:2:0 +0.04…+0.44 dB; WebP +0.45…+1.70; JXL effort 3 −1.22…+1.82; JXL effort 7 −0.67…+0.72; HEIC −0.76…+1.26; native AVIF −1.02…+1.07; libavif speed 6 +0.55…+1.21. A format meeting the mean criterion is not necessarily as good on every photo.

libjpeg-turbo is faster to encode, but this quality-matched setting produces approximately 10% larger payloads and only a small absolute decoding saving. It does not justify adding and maintaining another native dependency in FrameScrub for the default. WebP saves about 19%, JXL effort 7 about 21%, and AOM speed 6 about 32%; their encode/decode costs make them poorer defaults for this workload. JXL effort 3 trades speed for a smaller compression gain. This conclusion is specific to small cached SDR previews, not original images or archival compression.

## Capacity implications

At these 480px means, excluding SQLite overhead:

| Format/encoder | 100,000 pictures | 1,000,000 pictures |
|---|---:|---:|
| JPEG80 | 6.28 GB | 62.8 GB |
| WebP92 | 5.11 GB | 51.1 GB |
| JXL effort 7, q92 | 4.98 GB | 49.8 GB |
| AOM speed 6, q84 | 4.27 GB | 42.7 GB |

These projections are not allocations or promises for arbitrary media. Loupe's current default cache budget is 2 GiB; FrameScrub's new image-payload budget is 256 MiB with per-variant caps. Eviction, rather than prebuilding a million-image library, bounds disk use. Metadata is retained separately from images. Different photographs, dimensions and codec settings will change the counts.

## Overrides and cache compatibility

Advanced per-app UserDefaults (effective after relaunch):

- `thumbnail-format`: `jpeg` (default), `heic`, `avif`; unavailable system encoders fall back to JPEG.
- `thumbnail-quality`: 10…100, default 80. This value is encoder-specific; changing format at the same numeric quality does not preserve image quality.

Key namespace includes actual chosen codec, rounded quality, dimensions and the picture reader version. Old payloads are never mistaken for the new encoding and remain subject to normal bounded eviction. WebP/JXL are benchmark candidates, not exposed production options without their encoders being integrated and packaged.

If an optional system encoder fails at runtime, writes fall back to JPEG at the configured quality. Reads check both the preferred encoding and that JPEG namespace, including after relaunch.

## Reproduction

System-only: `swift scripts/bench/thumbnail-codecs.swift /path/to/photo.png ...`

All installed encoders (adjust include/library prefixes for the local package manager):

```sh
clang -O2 -I/opt/homebrew/include -c scripts/bench/thumbnail-extra-codecs.c -o /tmp/thumbnail-extra-codecs.o
swiftc -O -D EXTRA_CODECS -import-objc-header scripts/bench/thumbnail-extra-codecs.h scripts/bench/thumbnail-codecs.swift /tmp/thumbnail-extra-codecs.o -L/opt/homebrew/lib -lwebp -ljxl -lturbojpeg -lavif -o /tmp/thumbnail-codecs
THUMB_BENCH_SIZES=480 THUMB_BENCH_QUALITIES=0.80,0.84,0.88,0.92,0.94 /tmp/thumbnail-codecs /path/to/photo.png ...
```

The final script additionally measures PSNR/SSIM of the ImageIO-decoded 128px cell against the equivalently resized source. Inspect those columns before making quality claims about cell rendering. Thread CPU columns cover the calling thread only; hardware/system worker time is represented by wall time, not fully captured by that CPU counter.

An independent reviewer checked adapters, mean-quality selection and the recommendation, and identified the cell-path and per-image caveats now documented above. Intel and perceptual tests on a larger corpus remain distinct from this measured local policy decision.

### Cell-quality cross-check

The final ImageIO cell-quality run reported corpus means: JPEG80 38.38 dB / .995 SSIM, JPEG-turbo94 38.41 / .995, WebP92 46.27 / .999, JXL effort 7 q92 29.88 / .961, HEIC88 29.85 / .960 and native AVIF84 29.82 / .960. The nearly identical HEIC/AVIF/JXL ceiling despite differing full-size quality suggests the system downsampling path is materially different from the reference resampler. Treat these as end-to-end cell-pipeline results; they do not isolate codec distortion. This reinforces the requirement to verify a replacement cell path before switching defaults. The later run occurred under contention (wall times were noisy), so its cell timings are not substituted into the earlier stable table.
