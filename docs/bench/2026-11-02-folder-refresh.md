# Folder refresh and failed posters

2026-11-02, Mac16,6 (Apple Silicon), macOS 27.2 (26B123), native debug build. Intel timing was not measured.

## Failure reproduction

A zero-byte MP4 and a file containing arbitrary text both made the thumbnail worker return no facts. It continued
to the next video but never reported completion of the failed job. `PictureQueue` consequently kept that job
pending, and neither marked it unreadable nor removed its card. This was a missing failure callback, not a decoder
thread stuck on the reported empty file.

`KeyframeThumbnailTests.aDamagedFileReportsFailureAndDoesNotBlockTheNextPoster` first failed because the failure
semaphore timed out while the next valid poster completed. With explicit failure delivery, both empty/text cases
pass and the valid poster still follows. Empty files are rejected before opening a decoder. Known filesystem/read
failures retain their error classification, rather than being treated as damaged videos. Failed identity dates
are reconstructed at Foundation's reference epoch; a filesystem comparison test checks their exact precision.

## Directory notifications

`FolderChangeMonitorTests.changesAreDeliveredAndStopSuppressesFurtherDelivery` failed with no callbacks before the
monitor was implemented. It now passes for creation, rename, and no delivery after stop. The monitor uses native
directory vnode events; no periodic polling. One callback after arming covers the descriptor-open race, and a
300 ms window from the first event coalesces copy/rename bursts without indefinitely postponing a reread.

The test passed locally in 1.17 s and on an existing SMB mount in 1.50 s, including a 500 ms no-callback check after
stop. The SMB test uses a new uniquely named neutral test directory and removes only that directory afterward.
Server-originated notifications depend on the server's SMB change-notify support; ⌘R is always available. In-place
rewrites that do not raise directory events can also be refreshed explicitly.

Directory opens and enumeration run on utility workers. Each has one running operation and one replaceable pending
request; navigation invalidates old results. Events and explicit Refresh publish into the existing listing stream,
preserving visible cards, pictures, selection and scroll. Monitoring stops when Home/window is invisible and
reconciles when it resumes. A user thumbnail pause remains in effect while file listings continue to update.

## Real window regression

`.build/debug/FrameScrub --bench-home-updates` now checks fresh neutral video fixtures, one empty file, directory
events, explicit refresh with event watching paused, pause/resume, replacement of the empty file with a valid video,
and return from hidden Home. Three consecutive processes passed all direct-video scenarios:

| Check | Result |
|---|---|
| Five valid videos plus empty MP4 | Five durations learned, empty marked/skipped, no valid card hidden |
| Add/remove a video while visible | Card count follows automatically |
| Explicit source Refresh while watching paused | New video appears |
| Add while thumbnail generation paused | Listing updates; no facts/decoding until Resume |
| Replace empty file with a valid video | Repaired version appears |
| Hide Home, add a file, return to same folder | Fresh seven-video listing |

Aggregate main-thread CPU across the full scenario was 322, 351 and 353 ms. These totals include presentation and
multiple asynchronous waits; they are not click latency measurements. The benchmark additionally checks a new
subfolder's cover is not generated while paused and is generated after Resume. A utility watchdog bounds the test
to 30 s. `--bench-close-window` also sends a real ⌘R key equivalent through the application's menu before closing.
The extended subfolder-cover scenario passed with 410 ms aggregate main-thread CPU.

`swift test --jobs 4 --disable-sandbox` in a desktop-capable session: 35 settings tests and 1792 core tests passed.
Core Image tests require access to the system graphics context.
