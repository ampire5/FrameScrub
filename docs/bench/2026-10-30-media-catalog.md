# Media catalog: SQLite and image payloads

Machine: Apple Silicon developer Mac, macOS 27.2. Debug build, local SSD, 2026-10-30.

Run: `FRAMESCRUB_CATALOG_BENCH=1 swift test --filter MediaCatalogBench`.

The input is a real 480 px JPEG from the H.264 fixture (17,749 bytes) and its extracted metadata (1,017 bytes), copied to 256 distinct source identities. The same payloads are used for SQLite and atomic JPEG file writes. The connection is reopened before the first read. Thread CPU is measured with CLOCK_THREAD_CPUTIME_ID; numbers below are wall milliseconds. This is a local warm-filesystem measurement, not a cold physical disk or SMB benchmark.

| Operation | ms |
|---|---:|
| One metadata transaction, 256 records | 4.97 |
| 256 JPEG blob writes | 28.64 |
| 256 atomic JPEG file writes | 39.05 |
| First metadata + JPEG addressed lookup, reopened connection | 0.35 |
| Repeated metadata + JPEG lookup, 256 identities, five rounds | 3.30 / 2.58 / 2.59 / 2.68 / 2.63 |
| JPEG files alone, 256 reads, five rounds | 5.84 / 4.93 / 4.93 / 5.10 / 4.92 |

Chosen storage: JPEG blobs, with separate namespaces for last frames and posters. It was faster here and makes eviction/replacement atomic without orphan-file cleanup. Images are never decoded inside the SQL lock. Missing-image checks use SELECT 1 without fetching the blob.

Limits: at most 50,000 metadata records, 256 KiB per metadata snapshot and 64 MiB aggregate metadata; 256 MiB image payloads total and 4 MiB per image, with existing per-variant limits (200 last frames, 2,000 posters). These are explicit disk caps, not allocations. One transaction accepts at most 256 metadata records; addressed facade reads use batches of 128. Reusable SQLite pages are retained; explicit cleanup checkpoints WAL and reclaims pages incrementally. The budgets can be adjusted independently of background worker parallelism.

Coverage: reopening, changed mtime, same-size atomic replacement, rejecting a stale writer, reader-version invalidation, verified absent metadata, total/individual payload caps, transaction rollback, corrupt cache recovery, lazy creation and preservation of old JSON. Metadata extraction uses bounded streams/chapters and a shared 32 KiB tag budget.

User data remains in positions.json. lastViewedAt is optional for legacy records and updated only when the player submits a frame for display. Colour changes retain it. The cache is under Library/Caches/FrameScrub; deleting it cannot remove positions, marks, loops or colour settings. No JSON migration or startup media scan.

Follow-up machine coverage: Intel hardware and SMB latency are not represented by this local SSD measurement.

## Review-driven checks

An independent reviewer found an unnecessary retention scan on every metadata write. Entry and byte totals now use transaction-maintained counters; eviction only runs when a cap is exceeded. Production writes coalesce for 20 ms into at most 128 snapshots on one utility worker. Each pending/in-flight buffer is bounded to 128 entries; evicting a pending cache entry never affects user state.

A second benchmark seeds a catalog at its 50,000-entry cap, then performs five rounds of 100 isolated production-facade writes, explicitly flushing each to prevent coalescing: 16.51 / 10.17 / 12.20 / 11.69 / 12.84 ms wall per round. This exercises the expensive isolated-write case; it does not grow round by round. The paired image benchmark repeated at 31.39 ms for blob writes versus 41.13 ms for JPEG files, with a 0.38 ms first addressed read.

The inspector is latest-request-only: one active probe and one replaceable pending request. Closing or switching cancels the active ReadCache; foreground playback cancels inspector work. A regression test pins peak concurrency to one and verifies superseded requests do not probe or update the UI. Last-frame saves carry the identity captured by the playback open, just as poster writes carry their pre-decode identity.

Final independent re-review found no remaining actionable SQL/HDR findings. The reviewed in-flight filesystem read limitation is explicit: cancellation stops further reads but cannot interrupt an OS pread already executing. Main-thread UI/foreground playback never waits on that worker.

## Cache controls (same machine)

The real Settings window, `FrameScrubBench settings --start performance --rounds 3 --settle 300`,
with the encoding/quality/limit controls and lazy cache statistics: Performance returns 8 ms first,
12 ms median/max main-thread CPU; longest return turn 8/11/11 ms. Round totals 107/32/42 ms.
Idle: 3 ms main-thread CPU in 2 seconds. One setting change: 12/15/8/8 ms.
Opening directly on Performance costs 383 ms, above the ~300 ms goal (prior whole-window baseline
297–489 ms); this is not a claim that the existing window opening meets budget. Intel remains unmeasured.
The screenshot was inspected: controls, statistics and all four cache actions fit the page width.

Final controls (including separate poster and last-frame sizes), start on Colour and first enter Performance:
opening 433 ms; Performance first visit 122 ms total main-thread CPU, longest uninterrupted turn 41 ms;
returns 11 ms median / 13 ms maximum (longest turn 10/12 ms). Round totals 219/71/61 ms; idle 3 ms in 2 s.
The cold total exceeds the ~100 ms screen target, although no single turn exceeds it; returns are within budget.
These numbers preserve the limitation rather than claiming the existing settings-window opening is fixed.

History persistence uses worker read–merge–atomic-replace transactions under a stable sidecar lock. Foreground snapshots never own disk locks; tests interleave a stale in-process snapshot with independent disk transactions under the same lock protocol, and cover view-only updates preserving external position/colour, failed writes, delayed writers, cleared colour and monotonic recency. Actual-view tests cover resume disabled, unshown preparations, hidden frames and revealing a paused picture. Final full regression run: 1784 core and 35 settings tests passed.
