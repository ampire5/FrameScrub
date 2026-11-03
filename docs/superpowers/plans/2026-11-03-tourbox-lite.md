# TourBox Lite implementation plan

The fixed Tall coarse scale below is superseded by
[progressive acceleration](2026-11-03-tourbox-acceleration.md): bare Knob accelerated, Tall linear at base sensitivity.

**Goal:** Console Max/MSP event input with the agreed right-hand layout and independent linear Knob sensitivity.
**Design:** Top tap plays/pauses on release; holding Top for 0.4 s uses the existing `hold-speed`
and restores previous playback on release. Hold Top+Tour together for 0.6 s to switch the existing
Viewing/Editing profile, consuming both taps. Tour saves a frame on release with no double-tap delay.
Tall+Knob scrubs at 8× the configured linear sensitivity; Tall+Scroll seeks 60 s; bare Scroll moves the filmstrip
at the existing horizontal trackpad scale, with inverted direction and fractional target time. Scroll click toggles
the filmstrip; Knob click or unused Short tap resets 1×. Short+Knob changes speed. No Short+Scroll, zoom, scenes, playlist panel,
fullscreen, information, double presses or revert-seek bindings.

Tall+C1 toggles auto colour; Tall+C2 toggles Vibrance, in either mode and either press order. In Viewing, C1/C2 taps
navigate files on release; held with Knob they adjust auto-colour/Vibrance strength by 0.05, suppressing navigation.
In Editing, C1/C2 set mark in/out on release; held with Knob they edit the corresponding boundary one frame/pulse
as one undo operation. Two hands may be used in Editing. The thumb uses Tall/Short/Tour; index uses Top/Knob;
Scroll with Tall uses the middle finger; C buttons may use index or middle.

**Approaches:** Keep the keyboard preset as fallback. Use Console's single-byte event output rather than owning USB.
No vendor database or preset changes are required for follow-up layout changes. FrameScrub interprets the events.
**Architecture:** Pure Core router with bounded held state, fractional scrubbing and one pending hold deadline;
app loopback TCP50500 receiver with one 32-byte read in flight. No idle polling. Player commands on main thread.
Colour strength edits use ColorMemory's per-file persistence; toggles and inherited defaults stay separate.
**Tech:** Swift, Network.framework, Python stdlib preset generator.

## Constraints

- Preserve existing Package.resolved changes and keyboard fallback; no dependency updates or private content.
- Every TCP byte is an event; sample arrival time once per batch.
- Duplicate presses/orphan releases are harmless. Unsupported chords consume taps and never fire unrelated actions.
- Focus loss, Home, sheets, file/profile changes, disconnect and shutdown clear deadlines and restore held speed;
  unfinished edge edits cancel. Keyboard and TourBox speed holds must not end each other's hold.
- Knob defaults to 1 frame/pulse, `tourbox-accel=no`. Optional acceleration is gentler (24 pulses/s entry, 16× cap).
  Pulse/rotation calibration belongs to the user's actual device/preset; do not claim absolute angle or higher hardware resolution.

## Tasks

- [x] Existing loopback bridge, event-preset generator and opt-in configuration, initial automated/hardware trial.
- [x] RED→GREEN: Top hold/tap, Top+Tour both orders and early abort/late join, cancellation, Short reset, coarse linear
      Knob, release-time file navigation, colour toggle/strength chords, unchanged Editing boundaries.
- [x] Wire one-shot hold deadlines, speed ownership and colour strength persistence into player; update reference/map.
- [x] Full Swift suite, release app build/signature, focused review. Install with backup, restart and verify listener.

## Prior evidence

Initial 1856 Swift tests and production receiver smoke (200 bytes in order) passed. User imported/bound the event
preset and confirmed hardware works after the prepared build was installed with `tourbox=yes`. Follow-up tuning
suite (1860 tests) passed before the final button/colour changes above. Final verification: 1834 Core tests and
35 Settings tests passed; release built, locally signed, installed with app/config backup, and the installed
binary matched the build. Review's Tall multiplier=1 acceleration edge case has a reproducing regression test
and an explicit linear path. Real-device feel remains user feedback.
