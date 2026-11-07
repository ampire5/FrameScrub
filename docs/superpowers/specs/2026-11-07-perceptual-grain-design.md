# Adaptive perceptual grain

Approved direction: pleasant perceived texture while retaining existing structure, especially
well-preserved parts. Grain complements artifact cleanup and does not reconstruct lost detail.

## Approach

Use independent spatially correlated, zero-mean monochrome templates, a luminance response,
and a soft source-resolution mask. Add grain after scaling, following cleanup and sharpening.
Source mask combines existing texture protection, local edges, and detail removed by cleanup;
already smooth areas receive a weaker baseline. Protect structure in both original and cleaned
inputs. This is a texture-deficit heuristic, not semantic skin or artifact detection.

Compare fine and soft correlated grain with off. Plain independent white noise is a control;
source-resolution grain is a later comparison, not the initial pipeline. No full AV1 conformance,
codec metadata parser, neural model or extra decoder. Independent code, no copied implementation.
Use a small bank of normalized templates, deterministic per-frame offsets, and random-offset
blocks with variance-preserving overlap; the independent generator differs from AV1's AR model.

Default off. Expose type, RGB8 RMS amount, size in output pixels, flat-area baseline and mask
adaptation. Seed follows decoded-frame identity, stable on pause/redraw and reversible seeking.
No timer or frame history. Bypass HDR and release allocations when disabled.

## Validation

GPU checks: zero mean, bounded amplitude, monochrome correction, deterministic same seed,
different frame seed, protection of edges/luma/chroma texture, baseline in smooth input,
stronger coverage where cleanup removes detail, tiny images and HDR/off bypass.
Test real DisplayScaler paths, comparison views and settings round trips. Measure changing
4K to 6K frames and report added GPU work and memory; do not infer perceived quality from MAE.
Keep public code generic and media external. Preserve previous experimental changes.

## Continuing filter roadmap

1. Pre-scale deband/chroma cleanup: existing mild window/bilateral are retained. Temporal
   unwarped chroma and regional gradient spikes are documented; neither replaces the baseline.
2. Post-MetalFX halo cleanup: existing range/edge limiter retained; improved suppression and
   structure preservation still require comparison on moving edges.
3. Adaptive perceptual grain: current task, integrated experimentally only with verification.
4. Off/Auto/On controls and Shift-save-default: separate follow-up; reliable activation
   heuristics, hysteresis, session versus default persistence and shortcut scope remain work.
   No unvalidated smoothness mask is advertised as automatic artifact detection.
