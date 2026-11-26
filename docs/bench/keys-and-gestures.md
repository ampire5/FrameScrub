# Keys and Gestures HUD

Run `FrameScrub --bench-key-help` from an isolated config directory with `single-instance=no`. The benchmark opens
the HUD through the player command in the real window, lays it out, and verifies that the search keeps focus
when the video requests it. It routes Escape through the window key handler and verifies that focus returns.
Opening and closing include layout and use `CLOCK_THREAD_CPUTIME_ID` on the main thread.

Apple M4 Max, macOS 27.2.1, arm64 debug build, Home with the default bindings:

| Round | Open (ms) | Close (ms) |
| --- | ---: | ---: |
| 1 | 22.20 | 0.95 |
| 2 | 1.28 | 0.29 |
| 3 | 1.04 | 0.26 |
| 4 | 1.01 | 0.24 |
| 5 | 0.98 | 0.22 |
| 6 | 0.96 | 0.23 |

The first open creates the controls and lays out the sections. Return visits reuse them. This run measured
Apple Silicon. Timing on Intel hardware is unmeasured.
