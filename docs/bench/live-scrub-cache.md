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

## HLS VOD

2026-11-20 · Apple M4 Max, macOS 27.2.1 · arm64 release · 60 Hz display.
The same window harness opened the numbered 640×360, 25 fps AVC/AAC fixture
through loopback HTTP, once as MPEG-TS and once as fMP4. Each run opened the
audio engine at volume zero, advanced through at least 12 playback frames, then
paused for the ack-paced scrub trace. The ready cache limit was 16 MiB so the
48-frame legs would cross the cached boundary. These runs measure the physical
presentation of each requested picture on this Mac.

| Segments | Direction | Presented / requests | Ready at dispatch | Ready p99 | Overall p99 |
|---|---|---:|---:|---:|---:|
| MPEG-TS | Forward | 144 / 144 | 144 | 49.45 ms | 49.45 ms |
| MPEG-TS | Backward | 144 / 144 | 48 | 49.45 ms | 66.23 ms |
| fMP4 | Forward | 144 / 144 | 144 | 49.45 ms | 49.45 ms |
| fMP4 | Backward | 144 / 144 | 48 | 49.45 ms | 49.58 ms |

Both runs ended at 15.82 MiB of decoded frames. The 96 backward misses per run
needed demux/decode and used localhost. They give no WAN latency estimate.
The HLS tests independently check decoded AAC timing after a cold seek.

Reproduce with the normal release build and fixtures from
`scripts/make-fixtures.sh`. Run this loopback server in a separate terminal.

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Fixtures
```

```sh
.build/release/FrameScrub --bench-cache-scrub http://127.0.0.1:8765/hls-mpegts/media.m3u8 plain ack
.build/release/FrameScrub --bench-cache-scrub http://127.0.0.1:8765/hls-fmp4/media.m3u8 plain ack
```

The Apple Bip Bop gear 2 VOD also opened over HTTPS in the debug window
harness and presented 288 / 288 scrub requests. With the same 16 MiB cap,
p99 for backward cache misses was 416 ms on that connection. FFmpeg reported
timestamp warnings on the sample's MPEG-TS video. These figures describe one
public stream and run, not the local release measurements above.
[Apple HLS examples](https://developer.apple.com/streaming/examples/)

### HLS fMP4 on FFmpeg master

The arm64 release harness with FFmpeg `master-7ddf7bc8a482` repeated the
same 16 MiB, 288-step ack trace. One loopback run added 80 ms before serving
each init or media segment GET. Playlist responses had no added delay.

| Delay per asset response | P99 on backward ready hits | P99 on backward misses | Init GETs | Segment 01 GETs |
|---|---:|---:|---:|---:|
| 0 ms | 49.46 ms | 49.57 ms | 100 | 90 |
| 80 ms | 49.46 ms | 316.16 ms | 100 | 91 |

Both runs presented all 288 requests. Each backward leg outgrew the test
cache, yielding 96 backward misses over three rounds. The HTTP counts include
startup and audio. The delay and repeated requests isolate a network cost
for cold backward scrubbing. This trace does not time complete cache refill
after a timeline jump.

### Distant fMP4 jumps and segment reuse

2026-11-20 · M4 Max · Edge FFmpeg `master-7ddf7bc8a482`. The
`HLSVODTests.distantJumpsReuseDownloadedSegmentsAndKeepPreroll` test runs the
production PlayerCore and decoder against numbered 640×360, 25 fps fMP4,
with a 4 MiB decoded-frame cache and an 80 ms loopback delay on the init
resource and the two measured media segments. The paused trace goes
38 → 88 → 38. All three targets are missing from the decoded cache at dispatch.

| Frame on return | Before | With segment reuse and pre-roll |
|---|---:|---:|
| Exact frame 38 reported by PlayerCore | 169–174 ms | 6.0–6.3 ms |
| Target through target + 3 ready | 169–174 ms | 6.0–6.3 ms |
| Frames 35–37 ready by that point | 0/3 | 3/3 |
| Init GETs, including open | 3–5 | 1 |
| Segment 01 GETs | 2 | 1 |

In isolated runs the first visits to 38 and 88 took around 90–103 ms. This test polls
PlayerCore and the frame cache every 5 ms. The table therefore measures
decoder/cache readiness well enough to separate network waits from cache
reuse. Display timing is measured by the window harness above.

The same two Edge builds also ran the 16 MiB, 288-input trace in the
60 Hz window harness. Python's loopback HTTP server held every fMP4 asset
response for 80 ms. Audio attached and played before both scrub traces.

| Window trace | Before | With segment reuse and pre-roll |
|---|---:|---:|
| Exact frames presented | 288/288 | 288/288 |
| Backward requests missing a decoded frame | 96 | 30 |
| P99 actual presentation on those misses | 315.95 ms | 49.52 ms |
| P99 on ready backward frames | 49.45 ms | 49.41 ms |
| Init GETs | 100 | 1 |
| Segment 01 GETs | 91 | 1 |

Each build ran once, with the same four-segment fixture. Both ended at
15.82 MiB of decoded frames. The new run downloaded each of the four
media segments once across playback and scrubbing.

The fixture's four media segments are 94–103 KiB each and the init is
1.34 KiB. The session limits whole resources individually to 8 MiB and
holds up to 32 MiB or 64 completed resources. Up to eight open wrappers
share a 16 MiB reservation for recording and replay. Large and byte-range
objects use native reads. Incomplete responses are discarded. The cache holds no data across
opens. The measured test used less than 0.4 MiB of completed media bytes.

## Timeline jumps on HTTP Range and SMB

2026-11-20 · Apple M4 Max, macOS 27.2.1 · arm64 debug · bundled Edge FFmpeg.
The real VideoView and PlayerCore seek and start playback on each jump, with
audio attached and volume zero. The fixture is a 60-second copy of the numbered
1080p30 AVC test clip with 250-frame GOPs and a generated AAC track. The same
72 MiB MP4 runs over HTTP Range and from a temporary file on the mounted SMB
share. Each HTTP response adds 90 ms and each response body caps at 8 MiB/s.
The SMB run follows a local copy to the share, so it measures FrameScrub's
cold caches on a recently touched file.

| Transport and cache state | Time to target in PlayerCore | Time to the next playback picture |
|---|---:|---:|
| HTTP first cold jump, two runs | 1,244–1,609 ms | 1,359–1,696 ms |
| HTTP second cold jump, two runs | 538–553 ms | 637 ms |
| HTTP after the byte range was read but with a decoded-frame miss | 59–61 ms | 151 ms |
| HTTP revisit with a packed frame | 5.6–6.3 ms | 94–109 ms |
| SMB first cold jump, one run | 103 ms | 196 ms |

A five-second `sample` at 3 ms intervals spent most forward decoder worker
samples under `VideoDecoder.nextFrame` waiting on `ReadCache.copy` for data.
The first cold target needs pre-roll from the prior keyframe. At 13.2 s that
is nearly five seconds of encoded video. A cache hit can share a block that
is still arriving. The diagnostics now show the number of consumer requests
that had to wait, including those counted as cache hits. The elapsed time to
the next playback picture includes audio startup and the next frame interval.
The opt-in playback pipeline report also separates the audio request to the
first decoded buffer, to engine start, and to the first usable audio clock
sample. This can distinguish a cold audio seek from output scheduling.

A follow-up on the same HTTP fixture drove PlayerCore without a visible
window and kept the real muted audio output. Over six jumps, the time
from asking audio to play to the first buffer was 0.34 ms p50 and 8.51 ms
max. Engine scheduling was 10.81 ms p50 and 13.91 ms max. The first usable
audio clock sample was 36.09 ms p50 and 43.87 ms max. The next playback
picture followed the target by 93–107 ms. Most of this interval occurred
after decoding the first audio buffer. This run measured the playback
clock and display delegate, without physical presentation.

A trial scheduled one adjacent range at the start of a cold HTTP read. The
first jump took 1,333 and 1,412 ms, but a later miss reached 2,414 ms. Earlier
background fill changed which later positions were warm. The variation and
the slower tail do not justify adopting this prefetch change. The shipping
read-ahead policy is unchanged for HTTP and SMB.

Preview reuse is a separate result. The regression test presents a decoded
frame at a known nominal PTS to a hover provider, then evicts the decoded
frame and requests the same time from a filmstrip provider. Before the
change, the hover provider reported no reusable frame. After the change,
both requests use the same image with zero new decoder reads. Normal page
opens now give both providers the same resolved URL for the pool identity.

Reproduce the transport trace with the existing app build and a local
FFmpeg installation. The runner reports target landing, physical presentation
when observed, motion resumption, the time for eight following frames to be
cached, and read-cache deltas. A value of `-1` marks a stage that was not
observed. Timeline animation and cold thumbnail latency are outside this
transport benchmark.

```sh
BENCH_DIR=$(mktemp -d)
ffmpeg -nostdin -threads 2 -stream_loop 2 -i Tests/Fixtures/h264_cfr_gop250.mp4 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a aac -shortest -movflags +faststart "$BENCH_DIR/av.mp4"
python3 scripts/bench/network-jumps.py "$BENCH_DIR/av.mp4" 0.09
```

Pass the assigned port from the server in another terminal.

```sh
FRAMESCRUB_PIPELINE_REPORT="$BENCH_DIR/pipeline.json" \
  .build/debug/FrameScrub --bench-cache-scrub "http://127.0.0.1:$PORT/av.mp4" compressed jump
```

For SMB, use a mounted path to a copy of the same fixture in place of the
HTTP URL. The jump mode uses the app's automatic network policy on both
transports.

### Ready filmstrip cells and superseded network seeks

2026-11-20 · Apple M4 Max · macOS 27.2.1 · arm64 debug · Edge FFmpeg.
The click bench sends mouse down/up to the actual `SeekBarView`, which asks
the actual `FilmstripPreviewLoader` for a destination neighborhood. Only the
destination keyframe is resident in the decoded cache. The window visibility
check is overridden for this run because WindowServer reports the test window
occluded. The result measures delivery to the view, without measuring the
monitor's presentation time.

| Time from click to ready thumbnail | Before | After |
|---|---:|---:|
| Five rounds, no extra decoder opens | 427–468 ms | 13–20 ms |

The signed release delivered all five thumbnails before the transition
ended, in 25–104 ms with 0.08–0.43 ms of main-thread CPU per mouse down/up
pair. A debug repeat during compilation measured 17–112 ms. Elapsed time
includes worker queueing and thumbnail rendering.

The old path waited about 180 ms for the click animation and another 250 ms
for network thumbnail dwell. The new request can use the shared image pool
or an already decoded frame during the transition. The cold request still
waits for the settled neighborhood. It is permitted to read only once the
foreground picture is ready.

The jump-burst bench gives two obsolete positions 120 ms each before
requesting the measured destination. The stopwatch starts at the last
click. Source reads include the whole burst. The initial HTTP comparison
used the same 90 ms response delay and the same clip as above.

| Destination | HTTP before, two runs | HTTP after both changes, two runs | Source reads before → after |
|---|---:|---:|---:|
| 48.6 s | 895–913 ms | 747–750 ms | 10–12 → 10 MiB |
| 13.2 s | 688–768 ms | 340–341 ms | 14–16 → 6 MiB |
| 28.2 s | 2,012–2,347 ms | 2,040 ms | 18–30 → 24 MiB |

In the signed release's single-click HTTP run, the three cold targets
took 1,230/530/2,067 ms in seek order. Packed-frame revisits took 9 ms to
land and 82–90 ms more to show the next picture in PlayerCore.

On the mounted SMB copy, the baseline was 45/45/89 ms. The two changed
variants yielded 18/46/72 ms with only pre-roll cancellation, and
28/36/118 ms with both changes. The file had just been copied to the share
and the OS cache could remain warm. These samples show the behavior on SMB
but are insufficient to establish a disk-cold speedup.

The forward worker stops pre-roll between packets after a newer distant cold
seek outside the active GOP. Reads already shared by the session can finish.
A gated source test also confirms that a read which spans a seek cannot
enqueue more prefetch for the old generation. It failed on the old path and
passes with the generation check. Neither change increases read-ahead
parallelism.

Turning off `AVAudioUnitTimePitch` at 1× did not shorten the pause. Over six
packed-frame revisits per variant, the delay from target to next picture was
80–90 ms (median 81 ms) with time-pitch processing and 79–90 ms (median
84 ms) with bypass. The first audio clock sample was available after 35–36 ms
p50 in the comparison runs. It can refer to a future render timestamp, and
the next picture still has to reach its media time. The audio clock and
signal path were kept as-is.

Run the app benchmarks with the debug build linked to Edge FFmpeg.

```sh
.build/debug/FrameScrub --bench-timeline --bench-film-click-cache \
  --expect-before-settle --fixture Tests/Fixtures/h264_cfr_gop250.mp4
.build/debug/FrameScrub --bench-cache-scrub "http://127.0.0.1:$PORT/av.mp4" compressed jump-burst
```

For a window reported as occluded, the filmstrip bench accepts
`--simulate-visible`. The transport bench accepts `jump-headless` for normal
jumps without physical presentation. `jump-burst` uses the same headless
playback tick and the actual audio output.

## Edge A/B on HTTP Range, HLS and SMB

2026-11-23 · M4 Max · macOS 27.2.1 · native arm64 debug. Both
binaries used the same FrameScrub sources. The older FFmpeg was
`master-7ddf7bc8a482` and the newer was `master-05c674c9132e`.
The `jump-burst` harness used real PlayerCore and muted audio. Each run
issued two superseded seeks for each of the three measured targets.
Two runs per binary per transport were ordered old, new, new, old.
The endpoints are delivery of the exact target to PlayerCore and delivery
of the next playback picture. With six observations per cell, the maximum
is reported alongside the median.

| Transport | Target p50 / max, old → new | Next playback picture p50 / max, old → new |
|---|---:|---:|
| HTTP Range, 90 ms per request, 8 MiB/s | 847 / 2,263 → 856 / 2,259 ms | 932 / 2,351 → 946 / 2,347 ms |
| fMP4 HLS, 80 ms per init or segment request | 309 / 438 → 302 / 430 ms | 484 / 627 → 471 / 615 ms |
| SMB, same newly copied MP4 | 40 / 121 → 39 / 121 ms | 119 / 198 → 123 / 201 ms |

HTTP Range used the 60-second AVC/AAC fixture described above. In each
burst the three jumps read 10, 6 and 24 MiB on either revision, including
bytes from the superseded seeks. Each revision recorded 288 read waits
across all six measured jumps. These counters do not isolate cancelled
work from useful work. The HLS input was a stream copy of the same file
segmented as fMP4 VOD. A second pair per revision counted response
bodies at the HLS server, including startup and superseded seeks. The old
pin used 33–36 GETs and 178–182 MiB per run, and the new pin used 35 GETs
and 180–188 MiB. The first segment alone accounted for 80–90 MiB. At
roughly 10 MiB it exceeds the existing 8 MiB per-segment recording cap.
Server totals include bytes buffered by the transport before cancellation.
SMB reused a copy on the same mount, so its
reads reflect a warm OS/SMB cache after the initial run. SMB byte counts
between revisions cannot establish a version effect. The timings do not
show a repeatable reduction from the FFmpeg pin alone. The long-GOP HTTP
tail is still the largest measured seek cost.

## Stop packing NV12 when an exact clip fits the ready cache

2026-11-23 · M4 Max · native arm64 release with Edge
`master-05c674c9132e`. `burst-headless` runs the 288-request scrub at
approximately 59 inputs/s and records arrival of the exact frame at the
PlayerCore delegate. There was no online display. This mode also accepts
a fully warm trace with no decoder work. Both clips use VideoToolbox
NV12 and contain 96 frames. The 720p input is a downscale of the 4K
Bosphorus fixture. The same 256 MiB cache and trace ran twice before and
twice after, in before/after/after/before order. CPU is a percentage of
one core and covers the entire process during the trace.

| Clip | Policy | Frames delivered | CPU, % of one core | Packed / restored during trace | End frames / MiB |
|---|---|---:|---:|---:|---:|
| 720p | Eager packing | 288/288 both runs | 19.6–20.5 | 277 / 276–277 | 96 / 70.9 |
| 720p | Skip packing if clip fits | 288/288 both runs | 2.4–2.8 | 0 / 0 | 96 / 126.6 |
| 720p | Plain control | 288/288 | 2.2 | 0 / 0 | 96 / 126.6 |
| 4K | Eager packing | 288/288 both runs | 48.1 | 612 / 265–266 | 36 / 242.1–244.7 |
| 4K | Skip packing if clip fits | 288/288 both runs | 47.8–47.9 | 612–613 / 264–266 | 36 / 242.2–244.8 |
| 4K | Plain control | 286/288 | 12.0 | 0 / 0 | 21 / 249.2 |

For 720p, the p99 across directions and repeats was 0.07–0.10 ms before
and 0.07–0.08 ms after. A separate three-second sample at 5 ms intervals
showed `pack_block` at the top of 11 stacks during eager packing. The
counters reveal that the same 96 frames were demoted and restored repeatedly
while all ready surfaces fit the budget. The new policy stops work in that
case, trading about 56 MiB of additional ready surfaces within the existing
limit. In the pressure case, the 4K cache still holds 36 frames versus 21
without packing. Its CPU cost remains material.

Reproduce with the release build and the original 4K fixture from above.

```sh
ffmpeg -nostdin -threads 2 -filter_threads 1 -i Bosphorus-h264.mp4 \
  -vf scale=1280:720 -an -c:v libx264 -threads 2 -preset fast -g 30 \
  -pix_fmt yuv420p Bosphorus-720.mp4
.build/release/FrameScrub --bench-cache-scrub Bosphorus-720.mp4 compressed burst-headless
.build/release/FrameScrub --bench-cache-scrub Bosphorus-h264.mp4 compressed burst-headless
```

## Local long-GOP seeks and immediate backward steps

2026-11-24 · M4 Max · internal SSD · macOS 27.2.1 · arm64 release · VideoToolbox.
Re-encoded 750 frames of the local Bosphorus 4K60 fixture as H.264 with three
250-frame GOPs. Each run alternates across GOPs for 24 cold paused seeks.
Half supersede a different cold seek after 3 ms. Each landing is followed by
eight acknowledged backward steps. The benchmark measures delivery of the
requested frame number to the PlayerCore delegate. It uses a 256 MiB plain
decoded-frame cache. It does not measure physical presentation or disk-cold
reads. Each row shows two runs. All 216 requested frames arrived in each run.

| Policy | Single cold seek p95, ms | Superseding seek p95, ms | Backward step p99, ms |
|---|---:|---:|---:|
| Previous | 600–601 | 908–909 | 312.7–313.5 |
| Keep three predecessors | 597 | 904–905 | 306.0 |
| Cancel stale forward preroll | 601 | 606–607 | 312.9 |
| Keep three and cancel stale forward preroll | 596 | 600–601 | 305.4–306.1 |
| Cancel stale preroll in both workers | 312–313 | 319 | 313.1–313.2 |
| Keep eight predecessors | 603–604 | 926–927 | 0.06–0.20 |
| Keep eight and cancel stale preroll in both workers | 326–328 | 320–321 | 0.06–1.69 |

In the original policy the forward decoder finished superseded seeks, and
the reverse decoder could seek and decode from the start of the old GOP
before its first window-validity check. In a separate three-second
`sample` at 3 ms intervals, the VideoToolbox submission semaphore accounted
for 294 of 319 forward and 356 of 379 reverse decode stacks.
The reverse worker can now yield
between packets as soon as the old chunk leaves its window. The forward
worker retains at most eight predecessors within the active window and
half of the planned frame slots. It publishes the target before inserting
the predecessors. Eight covered the measured sweep. Three still incurred a
second GOP pass. Keeping predecessors alone adds a small landing cost on
this fixture.

The original policy passed approximately 7,300 forward and 8,850 reverse
packets to decoder backends during seek preroll per run. The combined policy
passed 4,872–4,889 forward packets and three reverse packets during seek
preroll. These counts include submitted packets
the backend may skip and exclude normal sequential fill. The charged cache
ended at 249.17 MiB in both cases.

The final release build delivered all 216 targets. Single and superseding
seek p95 were 314.76 and 318.76 ms. Step p99 was 0.38 ms. The two workers
passed 4,864 and three packets during seek preroll.

Use a 4K60 input with at least 750 frames. The 96-frame clip used earlier
in this document is too short for this trace.

```sh
ffmpeg -nostdin -threads 2 -i /path/to/bosphorus-4k60.mp4 -frames:v 750 -an \
  -c:v h264_videotoolbox -realtime 0 -b:v 28M -g 250 -movflags +faststart /tmp/ssd-4k-gop250.mp4
FRAMESCRUB_PIPELINE_REPORT=/tmp/ssd-4k-gop250.json \
  .build/release/FrameScrub --bench-cache-scrub /tmp/ssd-4k-gop250.mp4 plain local-seek
```

### Keep restored NV12 surfaces ready for longer

Same machine and release configuration. The short traversal uses
`compressed burst-headless` at about 59 requests/s on the 4K60 Bosphorus
input. The long-GOP trace uses `compressed local-seek` with the combined
seek policy above. Each comparison ran before, after, after, before.

| Short traversal | Process CPU, % of one core | Packed / restored frames | Exact frames | End frames |
|---|---:|---:|---:|---:|
| Pack any ready surface five frames from focus | 46.9–48.6 | 614 / 266 | 288/288 | 36 |
| Keep restored surfaces ready until ten frames from focus | 41.4–42.8 | 518 / 228–229 | 288/288 | 31 |

Short-traversal p99 stayed at 0.04–0.05 ms to the delegate. With the same
256 MiB byte cap the after runs held fewer frames at the end because more
were ready surfaces. On the long-GOP trace all 216 targets arrived in
each run. Step p99 was 0.02–0.21 ms before and 0.02–0.41 ms after. Process
CPU changed from 7.5–8.2% to 6.8–7.1% of one core. Results cover these
fixtures and traces on Apple Silicon.

The final release build repeated the short NV12 trace at 43.4% of one core,
with 288/288 exact frames and 31 frames resident at the end. A separate
release smoke trace on the repository's 4K HEVC Main10 HLG fixture delivered
144/144 forward and 141/144 backward requests during the 59 Hz burst.

## Local scrub audio and presentation profiles

MacBook Pro M4 Max, arm64 release with Edge FFmpeg, local SSD. The picture
input is the 4K60, 250-frame GOP fixture above. Repeat it twice and add a
48 kHz stereo AAC track for a 25-second audio/picture trace:

```sh
ffmpeg -nostdin -stream_loop 1 -i /tmp/ssd-4k-gop250.mp4 \
  -f lavfi -i sine=frequency=997:sample_rate=48000 -map 0:v -map 1:a \
  -c:v copy -c:a aac -ac 2 -shortest -movflags +faststart /tmp/ssd-4k-aac.mp4
```

Run with `FRAMESCRUB_PIPELINE_REPORT=/tmp/trace.json` and use `sample PID 5 1`
on a separate run. Substitute the appropriate file for each mode.

| Trace passed to `--bench-cache-scrub FILE` | What is measured |
|---|---|
| `plain scrub-audio` | 480 picture notifications at 60/s with four cold targets and changes of direction. Real demux, decode and snapshot production, with a PCM probe in place of output. |
| `plain burst-headless` | 288 forward/back steps on a 640×360 H.264 proxy made from the Bosphorus source with 60-frame GOPs. Ready frames and a growing cache, delivery to the delegate. |
| `compressed local-seek` | 24 cold or superseding jumps plus 192 exact backward steps on the long-GOP file. |
| `compressed burst-audio-headless` | 288 steps from frame 20 at about 59/s, audio engine attached, delegate delivery while video fills and packs. Compare with `plain`. |
| `compressed burst-audio` | Same motion through a real window and the drawable's presented timestamp. The observed screen ran at 60 Hz and the output was 1280×720. |
| `compressed jump-headless` | Six jumps from pause into playback, read-cache counters and time from the playback-audio request to first PCM, engine scheduling and first clock sample. |

### Audio worker

Two non-profiled runs per variant. CPU is accumulated process time over 8.35
seconds. The worker's snapshot measurement includes publication to the probe
and excludes the default audio device. A snapshot contains four seconds of
PCM around the current target.

| Variant | Audio demux seeks | Snapshot p95 | Process CPU seconds |
|---|---:|---:|---:|
| Original | 348–349 | 2.43–2.44 ms | 0.75–0.80 |
| Contiguous PCM copies and off-lock snapshots | 344–349 | 0.20–0.25 ms | 0.17–0.28 |
| Also continue adjacent reads and batch local tape extensions | 4 | 0.15–0.27 ms | 0.08–0.11 |

The last variant extended the existing decoder 23 times and published 86
snapshots per run. The original published over 360. It resolved readiness by
materializing a snippet, copied the snippet again when playing it, and held
the state lock while allocating two PCM planes, a mask and a gain array for
each tape snapshot. The original five-second sample had 103 worker stacks
making a post-decode snapshot plus 31 in the demux/decode call. In the final
trace the worker was usually asleep on its wake semaphore. Runs of adjacent
PCM now share fades at their outer edges and older PCM wins overlaps, including
after reversing. The 0.5 s local extension margin reuses the eager core's
existing length. Network reads keep the original requested horizon.

The final release verification also counted four seeks, 23 continuations
and 86 snapshots. That run had a 0.59 ms snapshot p95 and used 0.19 CPU
seconds, showing variance beyond the two runs in the table.

### Picture cache and playback clock

The warm 360p sweep delivered all 288 exact requests. Baseline exact-frame
delegate p95 was 0.03 ms in each direction against 0.02 ms after the ready
frame and resident-range changes. The baseline sample caught both the
nearest-frame scan and seek-bar sorting on the main thread. The final sample
showed the direct lookup (384 entries at the end in both runs). The delegate
timestamp precedes drawable submission. The screen trace below measures scanout.

The long-GOP profile delivered all 216 requests. Single/superseding seek p95
was 314/323 ms with packing and 321/318 ms with plain storage. Immediate
backward step p99 was 0.42/0.21 ms. The expensive seek stacks wait in
`VTBackend.send` for a VideoToolbox slot while feeding reference packets.
Keeping or removing the software packing tier barely changes this cold seek.
The existing async decoder already has four submissions in flight per
session. Increasing that bound would also increase live surfaces and work
a newer seek has to drain.

The rapid 4K reversal missed 11 of 144 backward requests with packing and
29 without it, with all 144 forward requests delivered in both passes.
Every backward request already ready at input arrived. The 256 MiB cache
ended with 32 packed/ready entries together versus 21 without packing. The
packing and restore paths accounted for substantial CPU in the sample and
the packed run performed over 500 demotions and about 195 promotions.
Plain storage used less CPU and ran out of history sooner. The reverse
worker can then be seen waiting on VideoToolbox during GOP preroll.

On six jump-and-play trials, the first playback buffer was available in
0.16 ms median after the audio request and the first clock sample in 38 ms
median (47 ms worst). The comparison build was 0.17 ms and 37 ms median.
The exact picture is a prerequisite to the audio request. The cold picture
cost 136–339 ms, and once requested the playback clock waits for the engine
render timestamp and the 10 ms sampler. Faster PCM preparation for the
scrub tape has little bearing on either part of this playback handoff.

### Presentation and decoder queue experiments

In the two instrumented screen runs, the p95 from arrival in `VideoView`
to the drawable's physical presentation was 48.5–49.0 ms. Arrival-to-render
p95 was 15.7–15.9 ms, render encoding 0.57–0.69 ms and GPU execution
0.77–0.87 ms. End-of-encoding to presentation was 32.4–32.5 ms p95.
These are stage percentiles, so they need not add up. A separate profiled
run had 70.5 ms p95. It caught the main thread in drawable acquisition,
including 19 samples waiting on QuartzCore's semaphore. The same profile
had encoder and pack/restore work. The completion timestamps expose the
remaining latency after the CPU has finished encoding the image.

Reducing the Metal swap queue from three drawables to two in an A/B/B/A
experiment left screen p95 nearly flat (48.7–48.8 vs. 48.1–48.5 ms).
Drawable acquisition p95 rose from 0.03–0.04 ms to 0.55–0.86 ms. The
application retains the three-drawable queue.
The final release recheck on that queue gave 48.8 ms arrival-to-present
p95 and 32.4 ms from end of encoding to presentation.

Changing the number of VideoToolbox submissions in flight per decoder on
the exact long-GOP trace gave the following results. Two release runs per
setting, in 4/8/12 and then 12/8/4 order.

| Submissions | Single cold seek p95 | Superseding seek p95 | Exact requests |
|---|---:|---:|---:|
| 4 | 314–320 ms | 317–325 ms | 216/216 |
| 8 | 320–327 ms | 315–325 ms | 216/216 |
| 12 | 314–320 ms | 317–323 ms | 216/216 |

The application retains four submissions. The latency ranges overlap across
all three settings. Reverse misses in the paced 4K
trace still come primarily from leaving the resident history and paying
that GOP's preroll. Physical latency for frames already ready comes
primarily after delivery, across the display-link boundary and the
presentation stage. These observations are for the local M4 Max traces.

## Paused presentation, reverse scrubbing, and cold forward previews

2026-11-24 · M4 Max · arm64 release · 256 MiB cache · local 4K60
H.264 with 250-frame GOPs. Screen runs used a 1280×720 drawable on a 60 Hz
screen. Paced input runs at 59 requests per second to vary its phase relative
to the display. Pre-existing benches and the following modes use the same
`--bench-cache-scrub VIDEO compressed MODE` entry point.

| Mode | What it measures |
|---|---|
| `burst-audio` | Three forward/backward passes of 48 steps each with real scrub audio. Input to physical Metal presentation, plus the number of newer inputs by the time a requested picture appears. |
| `burst-audio-headless` | The same cache and audio trace measured at exact frame delivery to the view. |
| `burst-dense` | 119 requests per second on the same 60 Hz screen. Allows intermediate replacement and checks that the last request appears. |
| `forward-headless`, `fast-forward-headless`, `reverse-headless` | 288 steps without a turn, at +1, +4, and −1 source frames per input. |
| `local-seek-screen` | The same 24 cold jumps and 192 backward steps as `local-seek`, measured at presentation. Also reports the first approximation closer to the target and the first within 48 frames. |

### Screen scheduling

The comparison kept the same Core Image and Metal rendering path. The
candidate queues a single paused render after the input turn when no picture
has been submitted in the current display interval. The next tick can
submit the latest state even when an earlier picture was already sent.
Playback, animated filmstrip previews, moving zoom, and timed colour and
focus transitions use the existing display tick. If the view is covered,
the queued callback yields.

| Scheduler | Arrival → render p95 | Arrival → screen p95 |
|---|---:|---:|
| Existing view display tick, A/B/B/A | 15.9 ms | 48.6–48.7 ms |
| Immediate submission without per-tick bound | 0.07–0.08 ms | 40.9–43.5 ms |
| Dedicated Metal display link, latency hint 1 | 15.8–16.0 ms | 65.7–66.0 ms |
| Bounded early submission | 0.08 ms | 48.1–50.6 ms |
| Existing view display tick, comparison for bounded run | 16.0–16.1 ms | 59.3–64.3 ms |

During the bounded comparisons the median input-to-screen time in each
direction was about 30 ms. Drawable acquisition still occasionally waited on
the compositor. The Metal display link eliminated that acquisition wait but
added another presentation interval in this test. The final scheduler keeps
the three-drawable pool and submits from the same view and command queue.

The final A/B/B/A compares the original scheduler and cache policy with both
selected changes. The physical timings are from the original input, and the
counts include both directions of each 288-request trial.

| Release | Input → screen p95 | Exact pictures | Newer inputs at presentation p95 |
|---|---:|---:|---:|
| Before | 48.3–48.8 ms | 276–277 / 288 | 2 |
| After | 33.1–33.6 ms | 288 / 288 | 1 |

The final view-arrival-to-render p95 was 0.070–0.073 ms. The render-to-screen
stage still took about 33 ms p95, while drawable acquisition took 0.024–0.026 ms.
At 119 inputs per second the 60 Hz display coalesced the burst and presented
147 of 288 requests, including its final exact picture.

### Cache and reverse decode

Keeping a larger share behind the playhead during unit forward steps removed
the first misses at each turn. A constant 60% allocation lost 10 extra
requests at +4 source frames per input on the packed cache. The selected rule
reserves history after +1 movement and keeps the original forward bias for
larger steps. The reserve keeps up to 16 frames, capped at 60% of the usable
window. Larger windows resume their normal allocation as their 25% history
share catches up. The normal backward share remains 75%.

At +4 source frames per input, existing packing demoted decoded lookahead and
restored it almost immediately. Keeping lookahead ready reduced restores from
1,108–1,142 to 7 and process CPU from 94.7–97.4% to 52.2–53.0% of one core.
The delegate p95 fell from 2.19–2.20 to 0.04 ms among delivered requests.
The baseline delivered 286–288 of 288 and the candidate delivered 286 in
both passes. The byte cap is unchanged. Other playback and pause modes
resume normal neighborhood packing.

The sustained backwards trace crosses a GOP boundary. The original
backward chunks fit only 40% of the decoded window. Larger chunks reuse each
GOP preroll for more wanted pictures without enlarging the frame cache.
Two runs per ratio, first ascending then descending, with forward history
unchanged.

| Paused backward chunk share | Exact requests out of 288 |
|---|---:|
| 40% | 87–89 |
| 60% | 117–118 |
| 75% | 134–136 |
| 90% | 124–129 |

The selected 75% extension is capped at 48 frames and applies to local exact
paused scrubbing. Explicitly suspending the forward worker over a backward
gap produced essentially the same result as changing chunk size alone. The
75% runs used roughly 25–27% of one core versus about 18–20% for 40% while
delivering roughly 50% more exact pictures. The remaining long-GOP misses
still pay reference decoding from a keyframe. A native 8-bit VideoToolbox
compressed-format probe did produce `&8v0` on this machine, but its IOSurface
allocation was 13,193,344 bytes versus 12,450,304 bytes for `420v`. The app
keeps the normal output format for 8-bit H.264.

In matched four-second `sample` captures, baseline and final reverse
delivered 89 and 136 exact requests. The backward decoder reported 46 and
45 seeks, with 10 and 5 cancelled prerolls. Its active stacks still spend
most of the long preroll waiting for a VideoToolbox submission slot.
Packing and unpacking remain visible CPU work. A final screen sample
caught four stacks in `CAMetalLayer.nextDrawable` and still showed all 288
requests. Sampling runs are kept outside the screen A/B latency ranges.

### Cold jumps

Before the preroll preview, the first approximation was often up to 254
frames away from the target. None of the 24 jumps showed an intermediate
picture within 48 frames. On a long forward jump the decoder can publish one
preview from four consecutive preroll outputs, starting 48 frames before
the target. It uses the active exact decode, never starts another decoder,
and leaves the preview outside the frame cache and the scrub sound path.
The preview is skipped on a short GOP, when the target is resolved, or if
the visible picture has already moved closer. Locked segments and virtual
cuts keep their own presentation behavior.

In the paired prototype, a near preview appeared on 13 of 24 jumps. In the
final release the direction is measured from the picture actually shown,
which also permits near previews when a pending jump was superseded. There
were 17 near previews in 24 jumps. Their medians were 266 ms on single and
279 ms on superseding jumps, about 67 ms before the exact-frame medians (333
and 345 ms). The exact target was shown on all 24 jumps and all 192 following
single steps. Rearward jumps still rely on ready frames until the exact
decode arrives, because earlier frames of that GOP lie beyond the target in
the direction of the jump.

The final headless sample delivered all 216 exact requests. Cold-seek
p95 was 321 ms for single jumps and 319 ms for superseding jumps. The
forward seek processed up to 205 video packets at p95, and the hottest
decoder wait in the sample was the VideoToolbox submission semaphore in
`VTBackend.send`. Early preview improves perceived progress during the
same preroll. Six visible jump-and-play trials also landed and resumed.

## Sustained reverse, sound transitions, and 120 Hz

2026-11-24 · M4 Max · arm64 release. The local video was 4K60 H.264
with 250-frame GOPs and AAC audio. The cache cap was 256 MiB. The reverse
trace issues 288 one-frame steps at 59 inputs/s. Exact counts measure
delivery through PlayerCore; screen runs use Metal's presentation timestamp.

### Reverse and cold seeks

Two sequential passes per share, with the already-selected backward chunk
size unchanged. The share governs both the paused window and cache eviction.

| Share behind the focus | Exact frames out of 288 | Process CPU, % of one core |
|---|---:|---:|
| 75% | 131–135 | 23.7–27.6 |
| 82% | 144–147 | 25.1–26.6 |
| 88% | 189–192 | 29.4–32.6 |
| 90% | 154–193 | 27.4–29.9 |
| 93% | 190–193 | 29.5–30.2 |

The selected 88% share leaves more cached runway before the next backward
gap. The 93% share yielded similar coverage with less room for the first
steps after a turn forward. At 88% there were 47 reverse seeks, 2,882–2,887
packets traversed in seek, and one cancelled preroll per trial. At 75%
there were 45–46 seeks, 2,939–2,953 packets and five cancellations.
The forward worker started only three seeks in the initial profile. The
gain comes from finishing useful work while the focus is still in range.
Delaying short chunks reduced reverse seeks to 38–41, but maintained
roughly the baseline coverage at 75% and reduced coverage at 88%.
The final release A/B/B/A delivered 189 and 191 exact requests with
the new policy, versus 134 in both control runs. CPU went from
23.4–24.6% to 30.7–31.2% of one core. The final short
reversal trace delivered all 288 requests. Fast forward at +4
delivered 286 out of 288 with seven restores, matching the preceding
release. In separate four-second `sample` captures both reverse
builds delivered 131 requests. The captures still show the backward
worker spending most of its active time waiting in `VTBackend.send`.

Keeping four pre-target pictures instead of eight reduced the median of
single cold jumps from 313.6–314.5 ms to 309.8 ms. The next 192 backward
steps went from 0.03–0.05 ms to 304 ms p95 because the cache ran out of
history and had to traverse the GOP again. With no history one early
run similarly measured 313 ms for the following steps. The eight-frame
retention stays in place. On the two serial baseline runs, exact cold
and superseding jumps took 319–328 ms p95. The final build measured
317 and 319 ms p95 for single and superseding jumps, all 24 exact, with
all 192 following backward steps delivered at 0.01 ms p95.

### Sound

A deterministic 48 kHz tape-motion probe replayed 24 forward inputs
at each cadence and then turned back. The waveform is a half-scale
440 Hz tone sampled at the production tape's calculated position
and gain. Delay starts at the first reversed picture and ends at
the first sample with negative tape velocity.

| Picture updates/s | Tape changes direction before | After |
|---|---:|---:|
| 30 | 28.4 ms | 28.4 ms |
| 59 | 44.7 ms | 33.9 ms |
| 60 | 44.5 ms | 34.0 ms |
| 119 | 52.6 ms | 40.5 ms |

The first reversed step now seeds a bounded estimate while the normal
30 ms averaging span accumulates. The motion slew and fade are the same.
There were no silent samples on reversal. At 60 updates/s the largest
adjacent sample change after reversal was 0.0387 before and 0.0371 after
on a full scale of 1. This probe measures the tape signal before the
audio device.

Six visible cold jump-and-play trials with the default output measured
0.37 ms p95 from the playback audio request to first PCM, 10.56 ms to
engine scheduling, and 39.21 ms to the first usable audio clock sample.
Those intervals start once playback can use the target video picture.
The playback clock is measured in software before speaker or headphone
latency.

Two live route-change cycles switched between the original Bluetooth
output and a virtual output and returned to the original route. At a
matching 48 kHz there was no engine restart. The largest clock plateaus
were 222–233 ms into the virtual route and 371–382 ms back. Changing
between 48 and 44.1 kHz did stop the engine. Usable clock samples returned
573–585 ms after the route request. In the timestamped cycle the HAL
setter returned in 2–7 ms, the configuration change reached the engine
queue at 495–499 ms, and the engine restart callback followed 33–46 ms
later. First audio clock samples followed roughly 41 ms after the callback.
The measurement endpoints were PCM and the playback clock before device output.

### Presentation at 60 and 120 Hz

A/B/B/A on the same external display, 3840×2160 signal and 1280×720
drawable at both refresh rates. Stepped the same ready 4K frames with
scrub audio at 59 inputs/s. All four runs presented 288/288 exact frames.

| Display | Frame arrival → present p95 | Encode end → present p95 | GPU work p95 |
|---|---:|---:|---:|
| 60 Hz | 41.1–43.9 ms | 40.6–43.4 ms | 0.42–0.50 ms |
| 120 Hz | 18.0–20.8 ms | 17.4–20.3 ms | 0.37–0.53 ms |

Arrival-to-render was 0.07 ms p95 at both rates. At presentation,
two newer inputs had already arrived at p95 at 60 Hz, versus one at
120 Hz. The remaining screen delay tracks the refresh interval much
more closely than GPU work. The monitor exposed a 4K 120 Hz mode and
returned to 6K 60 Hz after the runs. A physical Intel Mac was unavailable.

## Contended scrubbing, idle decoder waits, and cached backward previews

2026-11-24 · M4 Max · arm64 release · local 4K60 H.264 and AAC on SSD,
250-frame GOPs, 256 MiB frame cache. The reverse traces use 288 requests
at 59 inputs/s and count exact delivery through the player delegate.
Physical presentation runs use a 1280×720 drawable at 60 Hz.

### Competing preview and analysis work

Use `--bench-cache-scrub FILE compressed reverse-headless` for the control.
Use `reverse-preview-ungated-headless` and `reverse-preview-headless` for
a matched stress test, and `reverse-mask-headless` for Subject Focus.
The stress trace requests a cold exact thumbnail near the end of a
different GOP every fourth input. It uses the real utility preview
decoder and one replaceable pending request. The test pool holds one
entry to keep exercising cold work throughout the short trace. The
ordinary filmstrip can reuse a larger pool and typically asks for a
keyframe, which costs less than this test.

| Reverse trace | Exact delivery out of 288 | Completed side decodes |
|---|---:|---:|
| No side work | 188 | 0 |
| Utility preview without foreground yielding, A/B/B/A | 91–93 | 7 |
| Utility preview yielding to an unresolved focus, A/B/B/A | 138–141 | 1–2 |
| Subject Focus mask analysis | 191 | 0 |

The local filmstrip already gated new reads on foreground readiness.
Its in-flight cold decode now checks during packet processing, before
opening and before rendering a thumbnail. It leaves deferred visible
and warm times in their current bounded batch so a foreground-ready
callback can resume them. Cached results still bypass the check.
Hover still follows its own interactive request policy. Exact counts
cover all inputs, while delivery latency percentiles cover only inputs
that reached the delegate.

The guarded stress runs deferred 34–36 cold preview attempts. Subject
Focus processed 192 masks at about 13 ms p95 in the final trace and did
not show the coverage loss seen with the competing video decoder.
In separate four-second `sample` captures the preview worker's stacks
waiting for a VideoToolbox slot went from 1,548 to 422. Exact delivery
was 92 and 141 respectively. The primary decoder still spends much of
its active time in the corresponding wait.

### Idle waits

`idle-headless` opens the video, allows the cache to settle for a second,
then measures process CPU over three seconds without input. It checks
that the cache has stopped filling and sends one step after the idle
period. The baseline's two 100 ms polls recorded 76–78 expired waits
across a complete run, including the settling second. Event-driven
workers now sleep until a relevant state change. The backward worker
keeps its existing seek-settle deadline, and each resting decoder
can arm one notification to return a surplus pool.

| Idle trace | Process CPU over three seconds | First cached step, delegate |
|---|---:|---:|
| Polling, two runs | 1.46–1.97 ms | 0.05–0.08 ms |
| Event-driven, two final runs | 0.46–0.53 ms | 0.11 ms |

First-step differences are below a tenth of a millisecond in this
sample. Both baseline workers showed `NSCondition.waitUntilDate` under
`sample`. The resting workers in the final build showed untimed
condition waits. Separate tests exercise waking on a larger cache budget with
no input, and returning a VideoToolbox pool after its frames move to
the other worker.

### Cold backward jumps with a warm thumbnail pool

`local-seek-cached-screen` primes up to six adjacent keyframe pictures in
the shared preview pool before timing. The 24-jump trace alternates distant
GOPs, includes 12 backward jumps and includes superseding jumps. Run
`FRAMESCRUB_BENCH_HIDE_CACHED_SEEK=1` with the same mode for the control.
Both runs warm the same pool. No extra thumbnail work enters the timed
trace.

| Screen result | Overlay disabled | Cached overlay |
|---|---:|---:|
| Backward preview coverage | 0 / 12 | 12 / 12 |
| Backward preview p95 | — | 29.9 ms |
| Exact cold single / superseding p95 | 333.8 / 346.3 ms | 337.5 / 346.6 ms |
| Following backward steps | 192 / 192 | 192 / 192 |

The window uses the existing thumbnail composition. Only a ready
picture on the incoming side of the target and closer than the visible
frame is eligible. The lookup requires exact PTS and the same file and
rotation. It is limited to one second and 60 frames from the target
after a jump of more than 48 frames, and leaves ordinary clips with a
cold thumbnail pool on the same exact-decode path. The actual coverage
depends on which thumbnails have accumulated during use.

## Latest paused seek inside one GOP

2026-11-24 · M4 Max · internal SSD · arm64 release · VideoToolbox. The local
4K60 H.264/AAC fixture has six 250-frame GOPs. The compressed cache budget is
256 MiB. Each run makes 36 pairs of cold paused requests. In each pair the
second request arrives 3 ms after the first, 75 frames away in the same GOP.
Half the replacements are earlier and half are later. The next pair uses a
different GOP. The timer stops when the PlayerCore delegate receives the
requested picture. This excludes physical presentation.

```sh
FRAMESCRUB_PIPELINE_REPORT=/tmp/same-gop.json .build/release/FrameScrub \
  --bench-cache-scrub ssd-4k-aac.mp4 compressed local-seek-same-gop-headless
```

The baseline made two passes from the keyframe for nearly every pair. In a
separate five-second `sample` at 2 ms intervals, 993 samples in forward
packet submission were waiting on the VideoToolbox slot semaphore. The
contention appeared in the decode path, after the packet had been read.

For later targets, the worker continues from the existing decoder position
and filters preroll up to the new target. For earlier targets, it can stop
the old preroll at the next packet boundary and seek for the new picture.
The existing 48-frame cutoff limits this change to distant replacements.
A continued cursor that ends or passes the target retries from the
target's keyframe. Both paths still publish the exact picture before its
retained history.

Two runs per configuration in A/B/B/A order, without another benchmark or
profiler running during the measurements. All 36 final requests arrived in
each run.

| Measurement | Baseline | Latest seek first |
|---|---:|---:|
| Later target p50, ms | 519–520 | 309–310 |
| Later target p95, ms | 527 | 312 |
| Earlier target p50, ms | 509–514 | 206–207 |
| Earlier target p95, ms | 526–528 | 213–214 |
| Forward preroll packets per run | 12,064 | 6,028 |
| Wall time for 36 pairs, s | 18.74–18.75 | 9.39–9.41 |
| App process CPU time for 36 pairs, s | 2.09–2.18 | 1.19–1.23 |

Both variants recorded 74 forward exact landing attempts, including the
initial open. The new variant recorded 19 continuations without starting
from a keyframe and 19 interrupted prerolls, versus one interruption in the
baseline. The reduction is in packets processed, even when the forward
worker starts an operation for each request.

A second five-second sample on the new decoder still shows the submission
semaphore as the largest wait in the forward worker (860 samples). This
profile covers about half the new trace and about a quarter of the old
trace, so the packet counts over the complete traces are the better
comparison.

Controls, one run per variant on the same clip. The last two rows count
exact delegate deliveries before the next input; each had 288 inputs at
59 Hz.

| Control | Baseline | Latest seek first |
|---|---:|---:|
| Single cold seek across GOPs p95, ms | 317 | 319 |
| Replacement across GOPs p95, ms | 330 | 325 |
| Immediate back steps after cold seeks, delivered | 192/192 | 192/192 |
| Sustained reverse scrub, delivered | 174/288 | 175/288 |
| Sustained reverse scrub with utility previews, delivered | 138/288 | 135/288 |

Unit-step reverse scrubbing uses the existing backward worker path.
Both reverse controls recorded zero same-GOP continuations and the same
83 forward preroll packets. The same-GOP speedup applies to absolute
paused seeks. The video benchmark runs with audio output disabled.
