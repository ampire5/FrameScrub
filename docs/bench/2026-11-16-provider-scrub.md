# Embedded FrameScrub: repeated frame scrubbing

Release build on Mac16,6 (Apple M4 Max), macOS 27.2.1, internal SSD. The existing generated test fixture
`Tests/Fixtures/h264_cfr_gop250.mp4` is 1920×1080 H.264 at 30 fps with a 250-frame keyframe interval.
The harness drives the real `EnginePlayerService` and gives each produced image to its AppKit picture view
without a visible window. At 7.5 s in the first interval it steps back 20, forward 20, and back 20 frames,
waiting for each transport reply and checking exact presentation time. These are worker-plus-main response
times. Loupe's remote compositor and input forwarding, network files and Intel hardware were not measured.

Three rounds in one process, with a separate run for profiling:

| Version | First seek | Repeat seek | Median step | p95 step | Steps > 50 ms |
|:--|--:|--:|--:|--:|--:|
| Previous/single successor only | 87.1 ms | 86.7 ms | 81.7–82.3 ms | 87.1–95.9 ms | 120 / 180 |
| Contiguous decoded frame window | 87.4 ms | 1.2 ms | 1.2–1.5 ms | 1.4–2.2 ms | 0 / 180 |

In a separate four-second `sample` at 1 ms intervals, 1,852 decode-worker stacks passed through
`OnDemandVideo.previous → bracket → VideoDecoder.nextFrame`. The relevant leaf samples included
1,281 waits on VideoToolbox's in-flight semaphore and 13 in `pread`; 69 worker stacks passed through
`CIContext.createCGImage`. Each reverse step repeated the same keyframe decode. The file was already
local; adding compressed byte cache capacity would not remove that decode.

The window keeps the last 64 MiB or 24 frames of one consecutive decoded run, whichever is smaller,
with a minimum of the two bracket frames when a single frame pair exceeds the byte budget. That is
enough for the measured 20-frame reversal and stays bounded for small frames and 4K. A separate
Core test with the generated 3840×2160 HEVC 10-bit fixture verifies that only two P010 frames are
retained at that byte budget: the first backward step hits, the next misses and refills, and changing
direction after the refill hits the correct adjacent frame. At 3.5 s in the same 4K fixture, two
provider rounds of the 20-frame sweep took 73.7–74.1 ms p95 before and 71.7–71.8 ms after
(75/120 steps over 50 ms before, 74/120 after). The two-frame 4K history can cover an adjacent
reversal, but sustained reverse still hits frequent cold misses. Distant jumps and uncached keyframe
regions still require real decoding.

To repeat with Xcode SwiftPM, run from the repository root using the same architecture and FFmpeg
dependencies as the release build. The harness performs no writes to the fixture.

```sh
. scripts/deps-env.sh
swift build -c release --product FrameScrubPlayback
products="$PWD/.build/release"
objCMap="$PWD/.build/out/Intermediates.noindex/FrameScrub.build/Release/ObjCCatch-t.build/ObjCCatch.modulemap"
provider="$PWD/Sources/FrameScrubPlaybackProvider"
xcrun swiftc -O -g -parse-as-library -swift-version 5 -target "$DEPS_TRIPLE" \
    -module-cache-path "$PWD/.build/provider-scrub-modules" \
    -I "$products" -I Sources/CFFmpeg -I Sources/CSQLite -I Sources/CNV12Bitpack/include \
    -Xcc "-I$FRAMESCRUB_DEPS/include" -Xcc "-fmodule-map-file=$objCMap" \
    "$provider"/{EnginePlayback,PlaybackPictureView,PlaybackService}.swift scripts/bench/provider-scrub.swift \
    "$products/libFrameScrubPlayback.a" -L "$FRAMESCRUB_DEPS/lib" \
    -lavformat -lavcodec -lavutil -lswscale -lswresample -ldav1d -lsqlite3 -lz -liconv -lbz2 \
    -framework CoreMedia -framework VideoToolbox -framework AudioToolbox -framework Security \
    -o "$PWD/.build/provider-scrub"
.build/provider-scrub Tests/Fixtures/h264_cfr_gop250.mp4 7.5 3 --assert
```

The optional `--assert` fails if more than four steps per round on average take over 50 ms. Omit it
on slower machines when gathering timings.

## GIF on 2026-11-19

Same arm64 Mac and provider harness. Two generated 1920×1080, 25 fps GIFs contain 112 and 168 frames.
The first packet is the only keyframe in both. The larger file used FFmpeg before this change. The
smaller file used ImageIO and repeatedly recomposited frames when stepping.

| GIF | Before median step | Before p95 | After p95 | Steps > 50 ms before → after |
|:--|--:|--:|--:|--:|
| 43 MiB | 767–770 ms | 920–1,021 ms | 1.6–2.4 ms | 135 → 0 of 180 |
| 65 MiB | 1.7 ms | 564–568 ms | 1.2–1.7 ms | 12 → 0 of 180 |

The larger fixture's peak RSS rose from 173 to 290 MiB. The smaller fixture peaked at 289 MiB
after the change. One packed 1080p BGRA frame is 7.91 MiB. The 192 MiB ceiling fits the 24-frame
window and the 20-frame reverse sweep on this Mac. The byte limit is no more than 1/128 of installed
RAM above the standard 64 MiB window. The first seek to 3 s still took 673–697 ms after the change.
Moving beyond the retained frames still requires decoding from the preceding keyframe.

Before the change, a five-second profile of the larger fixture had 2,329 worker samples through
`OnDemandVideo.previous` on a window miss, including about 1,900 at `gif_decode_frame`. The smaller
fixture's four-second profile had 2,113 worker samples in `AnimatedImagePlayback.frame(at:)` through
ImageIO and CoreGraphics. Neither sample measured the Loupe host, remote compositor, or SMB reads.

```sh
for frames in 112 168; do
    ffmpeg -nostdin -filter_threads 2 -f lavfi \
        -i 'testsrc=1920x1080:r=25,format=rgb24,noise=alls=18:allf=t+u' \
        -frames:v "$frames" -threads 2 -loop 0 ".build/gif-scrub-$frames.gif"
    /usr/bin/time -l .build/provider-scrub ".build/gif-scrub-$frames.gif" 3.0 3 25 --assert
done
```


### Verification after merging the decoded frame cache

On the 65 MiB 1080p GIF, the Release provider harness completed all 180 steps with p95
of 1.19–1.65 ms. The first seek to 3 seconds took 680 ms. In the visible Loupe window using
the provider from the combined source tree, a right click paused playback. Seven wheel
notches with the right button held moved the paused position from 0.32 s to 0.04 s. Seven
notches in the opposite direction returned to 0.32 s. Releasing the button kept playback
paused. Another right click resumed playback.
