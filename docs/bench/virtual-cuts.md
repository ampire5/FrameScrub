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

### Coalescing a continuous cross-source scrub

The playback mode now drives two bursts, at 12 ms between requests.
One ends on the already open source. The other ends on the alternate
source and flushes on simulated pointer release. The delay between
pulses in this test is smaller than the 33 ms idle wait. The idle
wait covers two 60 Hz display periods, and pointer release, direct
seeks and automatic joins do not wait for it.

On the M4 Max, both the real library cut and the synthetic 4K25/4K60
SMB cut went from 20 opens in the original alternating burst to zero
opens when the final target was on the loaded source. The alternate
ending started one open and displayed the requested target. The
scope is continuous moves. An overview mouse-down is still an
immediate seek, even if the pointer subsequently starts dragging.

Both cuts crossed the automatic join and presented the next frame
after their plugin catalog was unregistered. They also accepted
native seeks across the join while the catalog remained unregistered.
The player received the cut once at card open. In the repeated 4K run,
the automatic join presented in 81 ms, the same-source burst's final
frame in 34 ms, and the alternate source presented in 191 ms from
release. The last case includes preparing and decoding the new source.

### First picture, filmstrip and fitted window

The presentation mode opens a card in the real File View window. Before
the fix, it failed because the catalog disappeared while the first
source was still opening. On the M4 Max, the revised mode kept File View
until the first picture, presented the next source in the same window
frame at Fit, and retained thumbnails for both fragments. It also
checked frame timestamps against the saved spans and that playback
stopped at the end without looping.

| Fixture | First picture after selecting the source | First picture at the join |
| --- | ---: | ---: |
| Two saved library fragments | 342 ms | 66 ms |
| 4K25 SMB to 720×1280 local | 241 ms | 64 ms |
| 4K25 H.264 SMB to 4K60 HEVC SMB | 216 ms | 113 ms |

The timing includes source preparation and first-picture submission to
the display. These are real-window checks on Apple Silicon.

### Repeated joins across four sources

A saved 49.75-second cut alternated four sources across 20 spans. Before
the fix its seventeenth span stopped at a frame number from the
approximate index. The corrected run delivered a frame for every span
and stopped at the last frame. The exact index was reused on all
16 repeat opens.

On this M4 Max, the 19 joins took 58–286 ms to deliver a decoded frame
to the renderer (69 ms median). The heaviest join still read roughly
120 MB through the player’s read-cache interface. This is not a count
of bytes transmitted over SMB. The whole-cut run did not show an early
poster at any join, and the separate scrub run could not confirm a Metal
presentation. Those two measurements do not establish a preview or
scrubbing latency improvement.

### Editing a source boundary

The real-window `fragment-edge` scenario opened the second authored
fragment of a cut from 4K sources over SMB on the M4 Max. A drag moved
the source seek position. Cancelling it and releasing sent no edit.
Repeating the drag and releasing sent one event for the expected range
and edge. Returning loaded the revised cut at its new boundary because
the previously selected source frame had been trimmed.

### Live analysis layer

The real-window `analysis-timeline` scenario runs with a configured
loopback page and a local 4K source. It exercises stale source and
wrong-origin rejection, shared fingerprint reads, both marker states
with the filmstrip folded and open, unchanged playback segments, and
cleanup on page replacement and source close.

On the M4 Max, parsing and publishing the synthetic snapshot followed
by layout and display took 0.085–0.643 ms of main-thread CPU in three
rounds. A synthetic snapshot at the input limit of 2,000 coverage
intervals and 2,000 findings took 4.11 ms. The measurement includes the
native update and drawing. It excludes inference and HTTP polling.

The `analysis-provider` scenario used an isolated Windows provider
and a 3840×2160, 50 fps file over SMB outside the scene catalog.
With the plugin panel hidden, it waited for a provisional marker,
sent a real mouse event to the filmstrip, and checked the displayed
source frame and the later refined publication.

### Filmstrip input with the native seek transitions

The real-window `film-join` scenario dragged the cut strip across a
4K25 H.264 to 4K60 HEVC join over SMB. While the mouse was held the
target was queued. Releasing it flushed the seek and displayed the
target frame from the next source. The timeline input probe also
dragged coincident native and authored boundary handles. Each gesture
committed once through its own callback.
