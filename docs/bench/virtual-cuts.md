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

## Cache and concurrency audit

Set `FRAMESCRUB_CUT_CACHE_BENCH=playback` for settled cross-source seeks
and twenty alternating seeks at 12 ms intervals. The playback bench
captures the first Metal presentation of the requested frame, and samples
the active read cache at that time. Byte counts are reads through the
source interface, including any bytes served by the operating system
cache. They are not measurements of SMB wire traffic.

On the same Apple Silicon Mac, a repeat run against two files in the
network library measured:

- A → B automatically: source ready in 44 ms, first B frame presented
  in 83 ms. Four of five speculative preparations were reused across
  the entire run.
- Settled returns to A presented in 81–103 ms. Each reopened session
  reported 88.2 MB of source reads at first presentation even though
  approximately 98% of cached requests were hits. Returns to B reported
  4.3 MB and 49–63 ms. The test does not separate byte reads for indexing,
  seeking, audio, and playback.
- The rapid burst initiated twenty opens, eighteen superseded in one
  run and nine in the synthetic 4K run. Both ended on the requested
  source. Cancelled reads could emit demux diagnostics.
- A read-only provider check through the tunnel, six requests per URL,
  gave repeated medians of 13 and 17 ms for cached analysis in two
  scenes without saved drafts and 2 ms for an existing mosaic.

For catalog testing set `FRAMESCRUB_CUT_CACHE_BENCH=catalog` and supply
a configured provider with at least 128 cards. The test fills three batches of 32 IDs through the actual thumbnail
loader and checks immediate image-cache hits in the first and last batch.
The first batch is revisited without refilling before checking the last.

In a synthetic 128-card catalog, all 96 previews in the three requested
batches arrived. Revisiting the first batch gave 0/32 immediate hits,
while the most recent batch gave 32/32. The current 64-image limit
clears the entire image map when a new image arrives at capacity.
This result exercises the thumbnail loader directly, independent of
grid scroll timing, and confirms that the earlier images were evicted.
