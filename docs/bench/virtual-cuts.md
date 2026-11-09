# Virtual cut browsing and playback

Run a separate FrameScrub instance with an isolated config directory, a
configured catalog plugin in a slot, and a short saved cut spanning two
source files. Set `FRAMESCRUB_VIRTUAL_CUT_BENCH_CARD` to its card ID and
launch the bundled executable with `--bench-virtual-cut`. The benchmark
opens the real File View, measures three source visits using
`CLOCK_THREAD_CPUTIME_ID`, opens the selected cut, waits for the join,
seeks back across it, and returns to its catalog.

2026-11-09, Apple M4 Max with 14 cores, two real media files from a
network library, local catalog connection through a tunnel. The cut
contains two 1.25-second ranges. One run after a debug build:

| Action | Result |
|---|---:|
| First catalog visit | 9.15 ms main-thread CPU |
| Return to catalog, round 2 | 18.70 ms main-thread CPU |
| Return to catalog, round 3 | 5.54 ms main-thread CPU |
| Open card to first source ready | 123.93 ms wall |
| Cross-source boundary to next source ready | 157.11 ms wall |
| Seek across join and return to File View | Passed |

The boundary measurement includes the benchmark's observation interval,
up to 25 ms. It measures readiness, before any additional time to
present the decoded frame. One cancelled speculative open emitted a
demux warning; foreground playback and the seek back completed.
This run does not cover a physical Intel Mac or establish a limit for
slower network libraries. The catalog worker and speculative reader
each have one request in flight; no concurrency setting was tuned from
this single run.
