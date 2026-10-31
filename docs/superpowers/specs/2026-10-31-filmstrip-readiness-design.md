# Filmstrip readiness and size control

## Intent

Make the filmstrip ready sooner and keep interaction smooth without competing with foreground frame preparation
or increasing decode concurrency. Keep the existing keyframe sampling and navigation semantics.

## Approaches

1. Reuse ready thumbnails and matching decoded keyframes before decoding missing keyframes. Selected by the user.
   This avoids redundant work without introducing a second refinement pass.
2. Show keyframes first, then refine to arbitrary frames. Rejected: extra decoding and image replacement have no
   demonstrated benefit for this task.

## Proposed change

- Let hover previews and the filmstrip reuse a bounded, per-file thumbnail pool. Reuse must respect source,
  rotation, actual frame identity and sufficient image resolution; obsolete-file work cannot enter the new pool.
- Before opening/seeking the film decoder, look for the matching decoded keyframe in the playback frame cache.
  Render its small thumbnail off the main thread. Do not retain an extra collection of full-resolution frames,
  change playback eviction, or substitute an unrelated nearby frame.
- Serve reusable pictures before spending time decoding missing ones; keep centre-first priority among misses.
  Retain one utility film worker and a bounded latest-visible pending batch. Foreground readiness, gestures,
  visibility and file-close cancellation continue to govern background decoding. No polling or idle timer.
- Measure the current fill and redraw paths before changing scheduling or painting. Apply only improvements
  supported by those measurements, preserving progressive delivery while paused and during playback.
- Add a continuous filmstrip-height slider (36–96 pt; existing default remains 48 pt) to the retained settings
  popover. Reuse the existing persisted height and update layout live. Keep hiding/pinning separate and preserve
  the existing context-menu sizes. Reset restores 48 pt together with the existing lens defaults.

## Verification and limits

### Follow-up: preparation before reveal

User requested early preparation with harmonious resource priorities. While the strip is folded, take a bounded
snapshot of its missing samples after the exact index arrives and when a keyframe is displayed. Reuse only shared
images or already decoded playback keyframes; a worker must not fall back to opening/seeking a decoder if such
a frame disappears. Use the existing serial utility worker, yield to visible requests and foreground work, stop
when no reusable candidate remains, and do not redraw the folded strip. Disable during gestures, hover preview,
export, Home and occlusion. There is no full-file pre-generation, new reader or repeating timer. The upcoming
reveal consumes these same cached pictures; ordinary missing-keyframe decoding remains demand-driven.

Use existing native filmstrip/PlayerCore benches for first image, visible-batch completion, playback progression,
foreground deferral/resume, cached reuse, hidden idle behaviour, live resizing and first/return popover CPU time.
Add focused regression coverage for cache identity, no-decode reuse, bounded work and old-file cancellation.
Compare decoding counts and memory bounds as well as latency. Record machine, fixture and before/after results
in the bench document; do not claim Intel or real NAS results without measuring those environments.

Update the architecture map for shared-pool ownership/data flow. Keep kit pins unchanged. Cache implementation,
coalescing details and any painting changes remain implementation decisions constrained by measurements.

The referenced user glass/sidebar guide was unavailable at its supplied path during investigation. Preserve
the existing native dark popover and current reveal/hide behaviour; this change does not redesign panel motion.
