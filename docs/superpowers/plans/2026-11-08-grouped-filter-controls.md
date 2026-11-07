# Full grouped controls and stronger cleanup

User correction: keep access to detailed settings in the player slot; group logically,
rather than reduce controls to only a few sliders. Stronger cleanup is requested.

- [x] Expose all artifact parameters in expanded Comparison, Deband, Chroma, Edges, Grain groups.
- [x] Keep one shared preferences store; bounded validation and commit-on-release controls; build once.
- [x] Add explicit Mild/Strong cleanup profiles preserving grain, with texture guard1 and source-size filtering.
- [x] Strong uses window .95/12/32 and luma-guided chroma5x5 strength1; no new passes/history.
- [x] Verify actual stronger changes/structure and timing on public4K clips at6K output; keep honest limits.
- [x] Check tests, panel CPU/visual layout, package and hand over with samples.

Auto activation remains deferred. No source-resolution luminance denoiser is claimed.
