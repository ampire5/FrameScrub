# Closing the player window

Machine: Mac16,6 (Apple Silicon), macOS 27.2 (26B123), native debug build, 2026-11-02.

`swift build --jobs 4`, then `.build/debug/FrameScrub --bench-close-window` in a desktop session. The benchmark
launches the real application, closes its main window after launch, and gives the real async user-state flush ten
seconds to finish. An independent utility-queue watchdog exits with status 1 if the process stays alive.

| Version | Result |
|---|---|
| Main-queue block calls `NSApp.terminate` | Window closes; process remains alive; watchdog exits 1 after 10 s |
| Run-loop deferred selector calls `NSApp.terminate` | Window closes; async persistence completes; process exits 0 |

A two-second `sample` of the affected application showed the main thread inside
`_dispatch_main_queue_drain` → `NSApplication.terminate` → `_shouldTerminate` → a nested event loop, waiting for
the `.terminateLater` reply. The main-actor task providing that reply could not run while the outer dispatch block
was still active. Scheduling termination as a deferred selector lets the main queue drain inside AppKit's wait.

This checks termination, not restoring multiple windows or saved sessions. Intel timing has not been measured.

## Metadata updates and returning to Home

`.build/debug/FrameScrub --bench-home-updates` copies five neutral `withaudio_gop25.mp4` fixtures to a fresh temporary
folder. It enters that folder while its parent's cover work can still be finishing, observes the first video card,
and waits for the real thumbnail worker to learn all five durations. Hiding the card during that update is a failure.
It then hides/parks Home, stops its source, adds a sixth video, and returns to the same folder with the previous
video selected, as a return from playback does. All six cards must appear. Temporary fixture files are removed.

| Version/scenario | Result |
|---|---|
| Duration callback uses `browser.reload()` (initial one-video reproduction) | Duration learned; card hidden once; exit 1 |
| Metadata sent through existing listing stream | Duration learned; card never hidden; exit 0 |
| Open stream retained while Home is hidden | Five durations learned; return still shows five cards instead of six; exit 1 |
| Stream finished on hide, retained across navigation | Five durations learned; card never hidden; return shows six cards; exit 0 |

The previous duration callback reset the whole browser after a burst: cards went back to the pool, images were
cleared, and image requests restarted. Metadata now goes through the listing already subscribed by the browser.
The source keeps one subscription with a generation token; navigation preserves the new one, and Home hide/shutdown
finishes it so returning re-reads both the folder and playback progress. No new filesystem read is needed per metadata
update. The benchmark's reported CPU time is aggregate main-thread work across the whole scenario, not click latency.

## Thumbnail crash investigation

The supplied crash and matching system log identify an uncaught `NSGenericException` from
`NSWindow._postWindowNeedsLayout`: the window requested more than 1,600 layout passes in one display cycle.
Thumbnail generation was active on a utility worker; the crashing thread was the main thread's layout observer.

The crash did not reproduce while opening a folder with 721 videos, including at the reported window frame
(3072 × 1618 pt). A two-second profile showed the main thread mostly waiting for events, with intermittent card
layout and image presentation. This does not establish which view caused the original cycle. The confirmed full-grid
resets described above were removed; the exact layout-feedback crash has not been reproduced or proven fixed.
Source folder names and crash artifacts remain outside the repository.
