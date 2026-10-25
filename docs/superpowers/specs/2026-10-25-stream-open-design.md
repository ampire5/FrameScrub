# Streams open off the main thread and play from the first bytes

Date: 2026-10-25. Status: implemented.

## Problem

Opening an `http(s)` stream (a plugin page's or Stash's) blocks the main thread for 2.5–4 s on a slow server. Measured
with pbxd's trailers (PornBox CDN, ~0.8 MB/s per connection, 0.35–0.5 s to the first byte of every request):

- `HTTPByteSource` asks for `bytes=0-0` (the size): ~0.4 s, plus whatever the server needs to find the file;
- the demuxer's first read takes `ReadCache` block 0, a 2 MiB ranged GET that is waited for whole: ~3 s;
- `avformat_open_input` and `avformat_find_stream_info` need only ~410 KB of it (`ffprobe -v debug` on the same
  trailer: 114 KB before `find_stream_info`, 409 KB after; 0.98 s for the whole open over one connection).

All of it happens inside `PlayerCore.open`, called from `PlayerWindowController.openFile` on the main thread.

## Design

### Bytes as they arrive

- `ByteSource` gains `read(at:count:into:progress:)`: the same read, calling `progress(n)` whenever the first `n`
  bytes are in the buffer. The default implementation reads, then reports once (files are unchanged).
  `HTTPByteSource` reports as the response body arrives (a per-task `URLSession` delegate).
- `ReadCache` keeps a block being loaded as a partial block: the buffer it is filled into and how many bytes are in.
  A reader whose offset is already in returns what is there (a short read; AVIO asks again for the rest), instead of
  waiting for the whole block. A reader beyond what has arrived waits for more or for the end. A failed load fails
  the readers still waiting; bytes already handed out stay valid.
- Block size, eviction, read-ahead and the number of requests stay as they are: one ranged GET per 2 MiB block.
  (Smaller blocks would pay the first-byte wait more often: at 0.4 s per request and 0.8 MB/s a 256 KiB block runs
  at a third of the link.)

### The open in the background

- `PlayerCore.open` is split: `PlayerCore.prepare(url, …)` makes the byte source, the read cache and the first
  `MediaSource` (everything that reads the file) and touches no player state; `open(_ prepared:, fallbackPosition:)`
  does the rest on the main thread. `open(url)` stays as `open(prepare(url))` for callers that wait.
- `openFile` keeps its synchronous path for files on this Mac (unchanged behaviour). For a stream it leaves the file
  on screen at once (the player stops), shows "Opening <name>…", runs `prepare` on a `.userInitiated` queue and
  finishes the open on the main thread.
- Every open and every close counts (`fileOpens`): an answer that arrives after another open, ⌘W or a failure
  shown in between is dropped and its read cache closed. Superseded opens report nothing to the user.
- `openFile` reports its outcome to a closure: `.opened`, `.failed` or `.superseded`. A file's open calls it before
  returning; a stream's when `prepare` comes back. Callers that acted on its `Bool` (a plugin's `open`, a list item,
  autoadvance, a Stash scene, a failed delete) act in the closure; a plugin request that was superseded is answered
  `open: replaced by another open`.
- While a stream is opening, ⌘W abandons it and goes back like a close; `hasOpenFile` is true.

## Out of scope

Files on network volumes still open on the main thread (an SMB open is ~0.1–0.4 s; the same split can take them
later). No change to read-ahead depth, parallel requests or pbxd.

## Tests

- `HTTPByteSourceTests`: progress reports arrive in order, end at the read's length, and the bytes up to each report
  are the file's.
- `ReadCacheTests`: with a source that delivers a block in steps, a read at the block's start returns before the
  block is complete; a read beyond the delivered bytes waits; a failure mid-block fails the waiting reader.
- `PlayerCore`: `prepare` then `open(prepared)` opens like `open(url)`.
- Bench: `docs/bench.md`-style numbers for ▶ → playing with pbxd before and after, and the main thread's longest
  block during an open.

## Measured

2026-10-25, M4 MacBook Pro, pbxd trailers (1080p, PornBox CDN), each trailer opened once (pbxd asks PornBox for its
address on the first request), the two ways alternating. `HTTPByteSource` + `ReadCache` + the first `MediaSource`,
i.e. `PlayerCore.preparation`, on a test thread:

| | size (`0-0`) | probe | open |
|---|---|---|---|
| before (whole 2 MiB block) | 309–966 ms | 1 542–2 394 ms | 1 877–2 713 ms |
| after (bytes as they arrive) | 314–509 ms | 185–1 141 ms | 541–1 533 ms (3 of 4 under 750 ms) |

Before, all of the open ran on the main thread; after, the main thread does only `open(prepared)` and the window.
