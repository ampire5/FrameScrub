# Stable film and view modes

Confirmed by user: whole-file lens moves over a stationary timeline; segment mode moves a stable film through a
fixed central lens. Restore the sketch's on-film three-way selector: lens / segment / whole-file overview.

- [x] Separate fixed absolute sample identities from time-dependent geometry. Whole-file modes share one stable
      grid, with a compact magnification region whose outer boundaries remain unchanged; segment uses an absolute
      time grid moving smoothly through the central magnifier. Keep bounded cells, crop and existing settings.
- [x] Use the projection for drawing, head position, click, drag and scroll; preserve sampled frames while playing.
- [x] Add a quiet on-film segmented switch and matching context actions, persist mode, preserve selected time.
- [x] Test stable IDs, unchanged far geometry, monotonic inverse mapping, segment motion and request stability.
- [x] Run autoplay integration, screenshots/CPU benches, focused review, full suite and app build.
