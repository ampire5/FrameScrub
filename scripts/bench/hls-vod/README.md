# HLS VOD cache probe

Builds a standalone probe against Homebrew FFmpeg with HTTP/HTTPS enabled.
It compiles FrameScrub's decoder backends and `FrameCache` from the checkout.
Run on macOS with Xcode, Homebrew FFmpeg and Python 3.

```sh
bash scripts/bench/hls-vod/run.sh
bash scripts/bench/hls-vod/run.sh 'https://example.com/media.m3u8' 90
```

Use a finished, unencrypted VOD with one chosen variant, a constant frame rate
and continuous presentation timestamps. The probe reads the video track and
models the playback clock at its nominal frame rate. It does no window
rendering or audio playback. The application's packaged FFmpeg and open path
are outside this experiment.

The worker decodes sequentially, then sleeps when its lookahead is full.
Every decoded frame goes into the shared cache. The playhead moves at 1× and
briefly steps backwards and forwards through the same cache every 12 frames.
The probe uses a 64 MiB test budget and at most 16 frames of lookahead. It cuts
that limit for larger surfaces so that the cache has room for played frames.
It fails on a playback or scrub miss.

The smoke test generates two seven-second H.264 fixtures at 720p30, serves
single-variant master and media playlists over loopback, and delays each
segment response by 80 ms. It checks that the first 90 playback requests and
42 scrub requests are cache hits and that the probe requests only part of the
stream. The reported scrub time covers changing cache focus and fetching
the frame. It measures a cache access, with presentation outside the timed interval.

## Local run

2026-11-20, MacBook Pro with M4 Max, macOS 27.2.1, Homebrew FFmpeg 9.0.2.

| HLS segments | Decoder | Warmup | Playback misses | Scrub misses | Minimum sampled lookahead | Segments requested |
|---|---|---:|---:|---:|---:|---:|
| MPEG-TS | FFmpeg VideoToolbox | 199 ms | 0 / 90 | 0 / 42 | 15 frames | 4 / 7 |
| fMP4 | VideoToolbox | 159 ms | 0 / 90 | 0 / 42 | 15 frames | 4 / 7 |

Both ended with 63.28 MiB charged to the frame cache. Lookahead and timing
are measurements for these fixtures. The probe has yet to measure
end-to-end presentation or performance on an Intel Mac.
