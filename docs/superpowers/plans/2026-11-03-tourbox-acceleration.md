# TourBox progressive acceleration

User delegated the transition/curve choice after real-device pulse calibration. Keep two behaviours:
bare Knob progressively accelerated, Tall+Knob linear at the same base frames/pulse. Remove the fixed coarse boost.
Other button and Scroll mappings stay as implemented.

Use a continuous quadratic gain above configurable `tourbox-accel-start` (initial 12 pulses/s),
with a 64× ceiling. Rise is smoothed over approximately 100 ms; slowing follows the measured rate immediately,
so precise positioning does not inherit a fast gain. Reverse, idle, modifiers and cancellation reset velocity.
Equal-timestamp input must not manufacture speed. Count pulses in the previous arrival timestamp group when
estimating its sustained rate over the next interval; keep only a bounded scalar, no input history or idle timer.
This corrects steady batching without asserting unavailable intra-batch hardware timestamps.
Base sensitivity remains `tourbox-frames-per-pulse`;
`tourbox-accel=no` disables the curve. Legacy `tourbox-fast-multiplier` is accepted and ignored.
Thresholds/gain are initial feel choices, not an assertion of extra encoder resolution.

- [x] Behaviour tests: slow precision, progressive moderate/fast/very-fast response, bounded extremes,
      immediate deceleration, reversal/rest, Tall linear with no coarse boost, configuration validation.
- [x] Update Core router and configuration, controller wiring, reference and architecture.
- [x] Full suite, focused review, release build/sign, backup/install and verify active configuration.

Verification: 1836 Core + 35 Settings tests passed (1871 total). Focused review found and then verified the
batch-count fix; no remaining important issues. Release builds and packaging completed. Installed after a clean
app quit, with fresh application/configuration backups; installed binary hash matched the signed build.
Restart verified the loopback receiver and enabled acceleration configuration. Physical feel remains user validation.
