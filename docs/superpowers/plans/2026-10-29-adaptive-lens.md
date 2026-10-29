# Adaptive time lens implementation plan

Goal: expose central time scale, focus width and crop strength; fill dense regions with genuinely more thumbnails.
Use the existing AppKit timeline, utility preview decoder and frozen-drag model. No extra decode concurrency.

- [x] Add a tested core layout: density-driven variable widths, central picture intact, bounded visible cells,
      contiguous packing, per-cell sample/hit testing and exhausted regions left empty.
- [x] Expose lens focus width and density; keep inverse mapping and selected time stable.
- [x] Integrate the same layout for drawing, requests, hover, clicks and captured drag; centre-crop dense cells,
      show complete picture on hover. Expand the bounded request/display pools for the new maximum visible count.
- [x] Add a compact native lens popover with three live sliders, numerical values, reset and persisted values.
- [x] Run focused/core tests, actual-view benchmarks and portrait/wide screenshots; review, full suite and app build.
