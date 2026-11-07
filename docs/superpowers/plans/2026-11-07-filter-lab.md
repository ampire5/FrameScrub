# Experimental player filter lab

User requested faster comparison of established approaches inside the experimental player,
retaining MetalFX, with additional sharpening already disabled. Proceed inline in the existing
compression-filters worktree; no merge/commit or permanent production-default change requested.

Architecture: display-only SDR GPU postprocessing owned by DisplayScaler; shared immutable
pipelines prepared off-main; bounded private scratch textures per scaler; original scaled
texture retained for processed/bypass/split comparison. No decoder/cache/export changes.

Approaches: avoid heavy offline models/CPU PP7; implement independent Metal kernels using
general published algorithm principles, not a bundled libplacebo/VapourSynth dependency.
Anti-ringing: local luma limit and coherent-edge-gated limit after MetalFX. Deband: thresholded
four-neighbor stochastic smoothing, one/two passes, deterministic spatial sampling. Chroma:
luma-guided bilateral3/5 and median3, luminance retained. Optional small output dither off by
default. All effects individually off by default, with strength controls and quick global A/B.

- [x] Test config parsing/validation and bypass/HDR routing; add typed settings.
- [x] Implement asynchronous immutable GPU pipelines and bounded scratch encoding.
- [x] Test actual GPU behavior on controlled edges, chroma, gradient and comparison fixtures.
- [x] Wire normal/zoomed original/LL display paths; refresh paused frames on settings/readiness.
- [x] Add existing Settings display section and View menu presets/A/B/split controls.
- [x] Run focused/full checks, GPU latency/real settings benchmarks and release build.
- [x] Package isolated Filter Lab app preserving the existing LL experiment/config; document
      source attribution, pipeline/ownership, measured limits and user controls.

No new panel/sidebar. SDR only initially; status explicitly reports preparation/failure/HDR
bypass. Repeated work only on normal render events, with no new polling/display link.

Results and remaining perceptual/UI limitations: `docs/bench/player-filter-lab.md`.
Full tests passed (1,832); release app packaged. Final split/shortcut UI verification
was incomplete when the Mac locked; manual menu A/B works, shortcut is unverified.
