# Plan: streams open off the main thread and play from the first bytes

Spec: `docs/superpowers/specs/2026-10-25-stream-open-design.md`. Branch `experiments`. Tests: `swift test`.

## 1. Bytes as they arrive (FrameScrubCore)

- `ByteSource.swift`: `read(at:count:into:progress:)` in the protocol, default in an extension (read, then
  `progress(n)` once when `n > 0`).
- `HTTPByteSource.swift`: `perform` takes an optional sink; with one, the task's delegate (`URLSessionDataDelegate`
  set as `task.delegate`) copies each chunk into the buffer at its place and calls `progress(total)`; the status is
  checked on the response before any byte is copied (a 4xx body is never handed out). The waiting stays on the
  calling thread.
- Tests (`HTTPByteSourceTests`): reports rise, end at the read's length; bytes up to each report match the file;
  a 416/404 reports nothing.

## 2. Partial blocks (ReadCache)

- A loading block is a `PartialBlock` (class: buffer, length, `filled`, `failed`). `block(_:)` → `bytes(in:from:)`:
  returns as soon as at least one byte at the reader's offset is in (or the block is done), copying what is there.
- `fetch` fills the partial block through `readFile(…, progress:)`; each report updates `filled` under the lock and
  broadcasts. Done: the block becomes a whole `Data` in `blocks`; failed: readers still waiting throw.
- Prefetch keeps calling the same path (`countHit: false`).
- Tests (`ReadCacheTests`): a gated source that delivers block 0 in two halves — a read at offset 0 returns after
  the first half, a read in the second half waits for it; a source that fails after the first half fails the reader
  waiting in the second half and the next read retries.

## 3. Prepare and open (PlayerCore)

- `PreparedOpen` (`@unchecked Sendable`: url, policy, read cache, media source). `static func prepare(_ url:,
  config:, budget:, byteSource:)` and `open(_ prepared:, fallbackPosition:)`; `open(url)` = both.
- `prepareInputs(for url:)` on the instance gives what `prepare` needs (config, the budget for the url's policy,
  the byte source factory) so the controller does not reach into the core.
- Test (`PlayerCoreTests`): open through `prepare` lands on frame 0 like `open(url)`.

## 4. The controller

- `OpenOutcome { opened, failed, superseded }`; `openFile(…, then:)`.
- `fileOpens` bumped by `openFile`, `closeFile`, `showFailure`, `showStashFailure`; `openingURL` while a stream
  prepares (`hasOpenFile` true; ⌘W abandons it).
- The stream path: pre-steps as today, `closeCore()`, OSD "Opening <name>…", `prepare` on a `.userInitiated` queue,
  back on main: stale → close the read cache, `then(.superseded)`; error → `showFailure`, `then(.failed)`; else the
  rest of today's `do` block with `openCore(prepared)`, `then(.opened)`.
- Callers: `open(_ url:)` gets `then:`; plugin `.open(.stream)`, `openListItem`, `openStashScene`,
  `playerDidReachEnd`, the failed delete move their result code into the closure.

## 5. Check and hand over

- `swift test`; build and install (`scripts/` as usual).
- Bench with pbxd: the slot bench page (▶ → playing) before/after; main thread blocked during open (sample the
  process while opening). Numbers into `docs/bench.md`'s network section or the spec.
- `docs/reference.md`: streams open in the background; ⌘W while opening.
