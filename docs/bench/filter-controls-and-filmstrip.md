# Filter controls and independent filmstrip

2026-11-08. M4 Max, macOS 27.2. New controls; no filtering kernel or GPU-pass change.

## Empty ribbon reproduction

Candidate player had preview=no in Display settings. configurePreview returned before
constructing FilmstripPreviewLoader. Turning hover preview on and revealing the filmstrip
restored all ribbon images on the same paused local 4K/60 clip. Thus disabling a hover
picture incorrectly disabled an independent UI feature. The hover provider is now optional;
the filmstrip retains its own utility worker, bounds, foreground readiness and visibility gates.

## Native panel CPU bench

Compiled the actual ArtifactFilterPanelView source (only its module import removed for the
standalone compilation) and ArtifactFilterSettings with swiftc -O. A real 360x800 AppKit
window, autorecalculatesKeyViewLoop=true. CLOCK_THREAD_CPUTIME_ID includes layout/display
and CATransaction.flush. Prepared once, four hide/show returns; each edit batch selects all
algorithm and grain options and changes all four sliders through their actual actions.
The bench verifies resulting settings. No renderer or settings-file writes in this bench.

| Action | CPU ms |
|---|---:|
| First preparation / attach / layout | 41.889 |
| Return, four rounds | 1.104 / 0.682 / 0.529 / 0.800 |
| Whole control batch, four rounds | 4.140 / 1.453 / 1.328 / 1.410 |

Temporary harness/log: /tmp/filter-panel-bench. These measure this Mac, not Intel, and
exclude the shared host's animation, GPU work and PreferencesStore persistence.
No increasing cost across returns. Sliders commit on release; no new timer or polling.

## Final player verification

Release app: FrameScrub Filter Controls. Current candidate preferences copied into an
isolated config; prior app and config retained. preview=no explicitly confirmed in the
new config. Native UI: N toggled checkbox and bypass OSD; Option-N opened/closed the
shared Filters tab. Selecting Window updated its explanation; starting-settings button
persisted strength .5, threshold9, radius24, protection1 without resetting chroma/grain.
After restart those values remained. Filmstrip pictures filled across the ribbon on
pause with hover preview disabled, including after restart. Final visual check fixed the
first switch overlapping the slot capsule by reserving 60pt at the top of the scroll content.

Core:1855 tests/159 suites passed. The first full run caught one new Settings description
missing the default word; fixed and all35 Settings tests/4 suites passed on rerun.
InputMap regression was observed red before implementation; existing default-count
expectation was updated from135 to137 for N/Option-N. No duplicated bindings.
Release and strict codesign verification passed; independent scoped review found no
correctness issues. No new filtering passes, quality comparison or thermal claim here.

Final padded layout repeat: first45.446ms CPU; returns .957/.741/.459/.415ms;
control batches4.029/1.359/1.175/1.106ms. Same settings assertions passed.
