# TourBox press actions and mode toggle

Approved layout: Knob click toggles the persisted `tourbox-accel` flag on press and shows its new mode.
Tall+Knob changes volume; Tall+Top toggles mute; Short+Top reverses playback. Short tap still resets speed.
Tall+C1/C2 toggle corrections on each new target press while Tall remains held. Modifier releases never repeat
the actions; duplicate down messages are ignored. Existing Top hold and Top+Tour profile chord stay intact.
No correction resets or bindings for Short+C1/C2 are added.

- [x] RED/GREEN router tests for immediate/repeated toggles, suppression of taps and Top hold, volume,
      Knob click suppression under modifiers and unchanged acceleration curve.
- [x] Wire Knob mode action to PreferencesStore, preserve held state on its own mode change while clearing
      motion, update reference/architecture. Start from accelerated default and remember the user's choice.
- [x] Full suite, focused review, signed release, backup/install/restart and verify config/listener.

Focused verification: 28 router tests plus a PlayerCore test cover the new mappings and reversal state;
all 29 pass. Reviewer found no important issues. Knob's own config update preserves its held/consumed state
while resetting motion, preventing duplicate down messages from toggling twice.

Full verification: 1839 Core tests (22 skipped) and 35 Settings tests completed without failures. Signed release
installed after clean app quit, with fresh app/config backups and matching built/installed binary hashes.
Restart verified loopback TCP50500 listener; existing config was preserved. Hardware feel/repeated target
presses remain the user's final device check.
