# Apple low-latency display effects

User-approved direction: integrate Apple's LL effects with optional further screen scaling; remove the custom deblocking experiment and image super resolution entirely. Builder decisions below implement that direction in this experimental branch.

## Approach

Use LL SR as an asynchronous pre-scaler of native SDR decoded buffers; preserve the existing MetalFX/Lanczos fitting path. A universal replacement is excluded by observed unsupported 1080p/4K inputs. Do not downsample source footage to meet model limits. Interpolation is a separate, temporal-only LL session followed by the same optional SR and screen fitting. Combined spatial/temporal LL interpolation is unnecessary because independent controls are clearer.

SR choices: off (default), automatic, 1.5, 2, 4. Automatic chooses the smallest supported factor covering the screen enlargement, otherwise the largest supported factor. Explicit unsupported factors fall back visibly rather than silently selecting a different factor. Interpolation: off (default), 2x or 4x frame rate. Only actual consecutive cached frames in forward 1x playback may generate intermediates; no extra decoder or clock changes. Intermediates follow the player's existing clock and never change the exact scrubbed frame.

One processing request in flight and one replaceable pending request per window; generation/frame/buffer identity reject old results. Session startup and processing stay off-main. Missing, slow or unsupported processing shows the original immediately. All buffers and sessions have bounded ownership and stop/reset on disabling, hiding, changing media, seeking or shutdown. No background polling. SDR only initially, with explicit HDR bypass.

Remove custom deblock code, settings, menus, tests and probe-specific toggle. Remove image SR sessions, paused enhancement and neural export options; saved/copied frames resize with Lanczos. Keep legacy config keys readable as no-ops for migration, without advertising removed choices. Existing U shortcut toggles LL SR; Shift-U cycles its factor.

## Temporal noise experiment (user-requested extension)

Add Apple's Temporal Noise Filter at native resolution, primarily for 4K, with an independent enable and 0..1 strength
(default off / 0.5). Reuse the same bounded worker. Supply at most one preceding and two subsequent consecutive
cached originals (runtime query on M4 Max/macOS27.2 reports these counts); use fewer if available, but Apple requires
at least one reference. Cache insertion events wake a waiting paused result without polling or new decoding.
Session and recurrent discontinuity state reset on jumps, config/media changes and hidden windows. Support 8/10-bit
buffers through API-required lossless formats and propagate HDR metadata; processed HDR must use the normal display
headroom/tone-map path. TNF runs before optional LL SR. FI is explicitly bypassed while TNF is active in this first
experiment, avoiding alternation of denoised originals and unfiltered generated frames. Exports remain untouched.
Measure actual 4K noise suppression, blocking behavior and accepted-result/presentation costs before any speed claim.

Measured TNF result: ~31 ms/native4K plus presentation cadence meant processed playback frames did not reach the
screen reliably. Default TNF mode is therefore paused/settled: defer the sole pending request120ms and replace it
while scrubbing; do not run TNF during playback. An explicit `always` mode remains for experiments. Measure actual
refinement delay from source request, including reference waits/discarded prep, not just accepted worker duration.
