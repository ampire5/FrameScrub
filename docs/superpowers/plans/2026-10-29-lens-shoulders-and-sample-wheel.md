# Smooth lens shoulders and sample-wheel navigation

Remove the narrow-then-wide waist at magnifier boundaries. Use a strictly positive, smoothly decaying local
magnification profile, uniformly normalised to the viewport; preserve fixed thumbnail identities and inverse input.
Mouse wheel selects adjacent loaded, displayed sample times exactly like clicks, preserving inverted direction.
Keep Option adjustment and continuous horizontal trackpad movement. Transition only the geometry with a finite,
cancelable animation; do not regenerate thumbnails during wheel browsing.

- [x] Reproduce shoulder undershoot and add sample-navigation/rounding/cache-availability regression tests.
- [x] Replace compensating displacement with a positive magnification integral and verify extremes/inversion.
- [x] Route mouse wheel through visible loaded samples, pause once per gesture and add bounded finite motion.
- [x] Verify pictures/cache reuse, boundaries, interruption/hide, actual input/CPU/snapshots, review, suite and build.
