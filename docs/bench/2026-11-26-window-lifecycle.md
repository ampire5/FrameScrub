# Player window lifecycle and hover

Measured on an Apple M4 Max, macOS 27.2.1, with the native arm64 debug build, a visible desktop window and neutral
repository fixtures. The baseline was local HEAD 15a9a81 with the existing working copy changes. An Intel Mac was
unavailable. The CPU figures are main-thread CPU time, and RSS is the whole process high-water mark.

## Close Video and Recent

The benchmark opens ten local clips with different frame geometries, then sends the regular ⌘W menu shortcut.
It times the first displayed Home, focus acceptance and the visible Recent card receiving the last playback picture.
Three rounds in one process distinguish first construction from subsequent returns. The delay is per playback save
and is injected on the utility queue before encoding and write.

| Configuration | Home first / later, ms wall | ⌘W first / later, ms CPU | Current card first / later, ms wall | Max pending frames | Peak RSS, MiB |
|---|---:|---:|---:|---:|---:|
| Before, normal write | 184 / 54–56 | 171 / 14–15 | 250 / 56–60 | 1 | 255 |
| Before, 500 ms delay | 4,823 / 4,785–4,837 | 167 / 49–57 | 4,843 / 4,787–4,841 | 9 | 260 |
| After, normal write with startup traces | 167 / 48–54 | 153 / 34–38 | 166 / 48–54 | 0 | 271 |
| After, 500 ms delay | 237 / 51–54 | 167 / 13–14 | 1,388 / 1,474–1,553 | 2 | 266 |

The baseline main-thread profile showed `closeFile → saveThumbnail(wait:) → _dispatch_sync_f_slow` waiting on the
serial queue. After moving saving off the close path, input reaches Home before even one artificially delayed write
can finish. The benchmark checks that the card updates through the same listing, the latest save wins when reopening
the same file, and a write can finish after Home is left without delivering a picture to the hidden view.
The final visibility check measured 169 ms for the first Home and 55–58 ms for later returns with the 500 ms delay.
It verified that both of the last two distinct files retained their playback frames.

The normal baseline needed one pending frame. With slow writes, keeping two pending identities preserves the last
two different files and a single worker caps total captured frames at three. Older cards can use a saved image or
generate a fallback. Process RSS in this small-clip run did not decrease. The frame bound prevents the queue from
growing proportionally to file switches.

A separate cold profile attributed 53 of 109 sampled `closeFile` stacks to AppKit layout during `keepingFrame`
and 27 to `makeHome`. In that run the first display was 342 ms and the two later displays were 52 and 49 ms.
First construction and toolbar layout still exceed the 100 ms screen-switch target on this machine.

## Cancelled opens

The benchmark holds preparation A at a gate, submits B through J, then either keeps J active or closes the window.
B through I have a 150 ms injected delay if started. The gate releases after 600 ms. Every scenario checks exactly
one completion for each request, superseded delivery for A before releasing it, and no stale open after close.

| Configuration | Peak running | Started | Cancelled metadata warmups | J | J completion from request |
|---|---:|---:|---:|---|---:|
| Before, local | 10 | 10 | 9 | Opened before A released | 36 ms |
| After, one slot, local | 1 | 2 | 0 | Opened after A released | 658 ms |
| After, two slots, local | 2 | 3 | 0 | Opened before A released | 182 ms |
| After, two slots, local window close | 2 | 2 | 0 | Superseded | 12 ms |
| After, two slots, mounted SMB | 2 | 3 | 0 | Opened before A released | 246 ms |
| After, two slots, mounted SMB window close | 2 | 2 | 0 | Superseded | 13 ms |

Two slots cost a short wait behind B in this burst and leave a route past one slow call. When both workers are stuck
in synchronous filesystem calls, the latest waiting request starts when either call returns. Cancellation cannot
interrupt a filesystem call already in progress.

## Cached hover preview

The same timeline sweep repeats after warmup, with no additional decoder calls in either measured pass. The second
pass applies both crop and pixel-aspect correction. `sample` located `DisplayGeometry.thumbnail` inside Core Image
on the main thread before the change and on the serial hover worker afterward.

| Configuration | Main callback p95, ms | Request to UI ready p95, ms | Sweep main CPU, ms |
|---|---:|---:|---:|
| Before, identity | 3.4 | 5.0 | 196 |
| Before, crop/SAR | 13.2 | 15.1 | 228 |
| After, identity | 2.5 | 9.9 | 156 |
| After, crop/SAR | 3.8 | 16.2 | 214 |

After the change the cropped provider callback schedules rendering and UI presentation runs on a later main-queue
turn. Request-to-ready includes that turn. The benchmark also changes geometry while hovering and verifies that
leaving hover invalidates a pending result.

## Run

Build a debug executable with the project's FFmpeg dependency, then run from a desktop session. Pass an existing
empty state directory and distinct fixture paths. Use three or more videos for `home`, ten for `open` or `close`,
and one GOP-25 fixture for `hover`.

```sh
FRAMESCRUB_BENCH_WRITE_DELAY=0.5 .build/debug/FrameScrub --bench-window-lifecycle home "$state_dir" "$media_dir"/*.mp4
FRAMESCRUB_BENCH_OPEN_LIMIT=1 .build/debug/FrameScrub --bench-window-lifecycle open "$state_dir" "$media_dir"/*.mp4
.build/debug/FrameScrub --bench-window-lifecycle open "$state_dir" "$media_dir"/*.mp4
.build/debug/FrameScrub --bench-window-lifecycle close "$state_dir" "$media_dir"/*.mp4
FRAMESCRUB_PIPELINE_REPORT="$state_dir/hover.json" .build/debug/FrameScrub --bench-window-lifecycle hover "$state_dir" Tests/Fixtures/withaudio_gop25.mp4
```

Use a fresh state directory for each run. To repeat on SMB, pass paths to copies of the fixtures on the mounted
volume and keep the state directory on the local disk.
