# Full grouped controls and stronger cleanup

2026-11-08, M4 Max32GPU/36GB, macOS27.2. User requested complete controls in the slot
and a stronger cleanup option. No shader/kernel changes: stronger settings use existing
source-resolution Window/chroma filters and existing post-MetalFX edge cleanup.

## Profiles

Both: enabled, overall1, processed comparison, texture protection1, coherent-edge AR1.
Grain and output dither are deliberately preserved. Mild: Window .5/9/24, bilateral3x3 .35.
Strong: Window .95/12/32, bilateral5x5 1. Labels keep all detailed controls accessible,
including algorithm-specific threshold/radius/iterations and grain structure protection.

## GPU experiment

Actual DisplayScaler, changing decoded UVG H2644K frames, MetalFX6144x3456, sharpen0,
no grain/dither. Three profiles rotated on each frame;60frames with10warmup excluded.
One run with PNG export on the middle Lips frame followed by a no-PNG repeat, after
compilation stopped. Final median/P95 ms, complete GPU conversion+filter+scale workload:

| Scene | Original | Mild | Strong |
|---|---:|---:|---:|
| Lips | 1.826 / 2.787 | 5.442 / 6.298 | 6.127 / 7.297 |
| FlowerFocus | 1.903 / 2.593 | 5.402 / 6.569 | 6.261 / 7.642 |
| FlowerKids | 1.768 / 2.481 | 5.133 / 6.396 | 5.842 / 7.349 |

Excludes decoder, PNG readback/encoding, drawable composition and physical presentation.
Short samples do not establish sustained60fps or thermal behaviour. Existing grain adds
its own work. No extra stage/history/worker was added by these profiles.

Lips PNGs exported at native6K plus900x650 crops, with grain off to expose actual cleanup.
Visual inspection: strong smooths colour mottling more than mild; luminance scratches/grid
remain. This is not evidence that strong recovers detail or is uniformly better. There is
no ground-truth/subjective-rating quality metric in this experiment. Texture guards can
also preserve compression noise. Full files, exact probe, logs and both runs' JSON reports
are outside the public repo under the user's filter-lab/grouped-cleanup artifact directory.

## Panel verification

Actual panel source compiled in a standalone real AppKit window360x800, with only module
import removed. CLOCK_THREAD_CPUTIME_ID including layout/display and CATransaction.flush.
Final: first68.465ms; four returns1.424/1.084/.771/.711ms; whole control batches9.503/2.912/
2.657/2.607ms. Five popups,13sliders,13numeric fields exercised. NaN,Inf,out-of-range and
nonnumeric values cannot change settings. Actual AppKit field-editor focus verifies the
slot typing predicate, then ending editing clears it. Not an Intel measurement; excludes
PreferencesStore disk writes, shared host animation and GPU redraw.

Native release app: complete expanded groups visible in6K screenshot; Strong button sets
Window .95/12/32, chroma5x5 1 while keeping grain values; exact threshold14 commits and
invalid NaN restores14. Final threshold12 restored, frame focused and panel reopened.
Filmstrip remains populated with preview=no. KeysN/Option-N unchanged; keys entered into
an editing text field remain text. Shared slot typing predicate prevents auto-hide during
editing, as required by the common panel guide.

Core1856 tests/159suites and Settings35tests/4suites passed. New cleanup-profile regression
was observed failing before implementation. Final release and strict codesign passed.
Scoped independent review found missing typing protection; fixed using the existing
SubjectFocus field-editor pattern and verified in the real-window harness.
