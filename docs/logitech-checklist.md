# FrameScrub + MX Master 4: what to try

The Logitech mouse through LogiHIDPP: buttons, press kinds, the live edge drag, haptics, Mac Mouse Fix, Loupe next
door. Needs the mouse on its receiver
and a video with a few cut marks, keyframes and a long enough file. The defaults of `~/.config/framescrub/input.conf`
and `framescrub.conf` apply unless a row says otherwise (a clean `input.conf` is the easiest: move yours aside).

Keys that matter in `framescrub.conf` (defaults):

```
mouse-long-press = 400               # ms, 150…2000
mouse-haptics = yes
haptic-strength = keep               # 0…100 or keep
haptic-strong-strength = 80
mx-panel-force = 0                   # 0…100, default, keep
mx-side-buttons = watch              # watch, take, system
wheel-precision = no                 # free spin and Precision Scroll in the player (yes), the ratchet by SmartShift
```

Before starting: `cd ../LogiHIDPP && swift run logi-probe release` so every row begins from a mouse nobody holds.
In FrameScrub's log (`local.framescrub` / `Mouse`) the divert / watch sets and any refused force write show up.

## 1. Default mouse layout (spec 4.2)

Wheels and the right button:

- [ ] Wheel: `scrub`, a frame per notch (with Precision Scroll off); paused and playing both behave as before.
- [ ] Right button + wheel (either direction): `scrub fast`.
- [ ] Gesture button + wheel up / down: volume +2 / -2, OSD shows it; plain wheel does not change the volume.
- [ ] Alt + wheel up / down: volume +2 / -2.
- [ ] Side wheel left / right (under the thumb): `seek -10` / `seek 10`, one jump per click (the wheel is not diverted).
- [ ] Right button + side wheel left / right: `step-speed` down / up on the `speed-step` grid; playback does not start
      and does not reverse; paused: the speed is set for later and the OSD shows it.
- [ ] Shift + side wheel: `scrub`; Shift + Alt + side wheel: `scrub fast`.
- [ ] Right click (no scroll): play / pause on release; after Right + wheel it does not toggle.

Panel:

- [ ] Panel tap: `toggle-auto-color`.
- [ ] Panel held 0.4 s or longer: `toggle-vibrance` **on release** (the panel also has wheel chords); a tick
      (`haptic-long-armed`) at the threshold; release before it does the tap instead.
- [ ] Panel + wheel up / down: auto colour strength +0.05 / -0.05, OSD `Auto colour strength 0.65`, with ` (off)` when
      auto colour is off; saved to `framescrub.conf`; Settings → Display shows the same value if it has the slider. Tap and long press do
      not fire afterwards.
- [ ] Hold the panel past 0.4 s, then turn the wheel: strength changes, vibrance does not toggle on release.
- [ ] Release the panel in the middle of a smooth wheel run: the tail does not scrub; a new run after 0.25 s or more
      scrubs.

Gesture button:

- [ ] Tap: `screenshot` (flash, file written).
- [ ] Held 0.4 s or longer: `save-clip` (the sheet, or none with `clip-confirm=no`); a tick at the threshold.
- [ ] Gesture button + wheel: volume (above); tap and long press do not fire after it.

Back / forward and marks (a file with several cut marks):

- [ ] Back tap: `mark-in`; with the position inside a mark it moves that mark's start to the current frame.
- [ ] Back held 0.4 s or longer: `mark-snap`; a tick at the threshold.
- [ ] Forward tap: `mark-out` (same, for the end).
- [ ] Forward held 0.4 s or longer: `mark-delete` of the mark under the position.
- [ ] Back + wheel (position inside a mark): the mark's start follows the video live, the seek bar strip updates while
      turning; release commits (OSD `Start 01:23.456 · f1234`); one ⌘Z undoes the whole drag.
- [ ] Forward + wheel: the same for the end.
- [ ] The edge stops against its pair (start no further than the end, end no earlier than the start) and against the
      neighbouring mark (a frame short of it); one `haptic-limit` per stop, not one per click.
- [ ] A keyframe passed during the drag: `haptic-keyframe`.
- [ ] Back + wheel with no mark under the position: just scrubs; release = `mark-in` on the final frame.
- [ ] Esc during the drag, or ⌘-Tab away, or losing focus, or opening another file: the edge goes back, ⌘Z has
      nothing new.
- [ ] Back or forward tap does nothing visible after a drag (no mark on release of a chord).
- [ ] Middle button and `MX_SHIFT` (the button behind the wheel) do nothing by default; SmartShift still switches the
      ratchet.
- [ ] A press with a pointer move of 8 pt or more is not a press; a tremble below it is.

## 1a. Back / forward next to Mac Mouse Fix

With Mac Mouse Fix running and `mx-side-buttons=watch`:

- [ ] Back / Forward tap in FrameScrub: `mark-in` / `mark-out` once each, never twice (no double mark, no double OSD);
      MMF's own action for the button does not show anything visible.
- [ ] Back + drag (MMF's swipe): MMF switches the Space, FrameScrub marks nothing — in Editing and in Viewing (Back
      with only a tap: no info panel), with MMF's "lock pointer during drag" on, the pointer over the video, a slot or
      the seek bar.
- [ ] First click after returning to FrameScrub from another app counts too.
- [ ] FrameScrub in front, pointer over the Finder window: Back does nothing in FrameScrub (it is Finder's business);
      over a FrameScrub window it marks.
- [ ] `mx-side-buttons=take`, then back to FrameScrub: Back / Forward are FrameScrub's alone (MMF does not get them);
      in the background MMF has them again (`logi-probe list` agrees).
- [ ] `mx-side-buttons=system`: with MMF FrameScrub sees nothing from Back / Forward; without MMF AppKit's events work.
- [ ] Without MMF, `watch`: each press once.

## 2. Haptics (spec 6)

- [ ] `haptic-step`: a step of speed (Right + side wheel), volume (gesture + wheel), auto colour strength (panel +
      wheel), a side-wheel jump of 10 s.
- [ ] `haptic-detent`: speed landing on 1× or passing through it; strength landing on or crossing 0.25 / 0.5 / 0.75 (a
      deeper, duller tick than the step).
- [ ] `haptic-limit`: volume at 0 and 100, strength at 0 and 1, speed at the ends of the grid, an edge drag at its pair
      or neighbour.
- [ ] `haptic-long-armed`: gesture button, panel, Back, Forward each tick at 0.4 s; a button without wheel chords has no
      tick (its long press acts on the threshold; check `MBTN_MID_LONG` bound by hand with `MBTN_MID+WHEEL_UP` and
      `_DOWN` set to `ignore`, if wanted).
- [ ] `haptic-toggle`: panel tap (auto colour), panel long (vibrance), a keyboard `toggle-*` / `cycle-*` such as mute or loop, only when
      something changed; a pause toggle (right click, `Space`) does not buzz it.
- [ ] `haptic-end`: wheel scrub, a frame step and a seek into the first / last frame: one hard bump per push; more
      pushing is silent; a step the other way and back, or a pause of 0.3 s and a click, bumps again. `playlist-next`
      on the last file, `playlist-prev` on the first.
- [ ] `haptic-keyframe`: slow plain wheel scrub across a keyframe; not with Right + wheel (fast), not on the trackpad,
      not while playing.
- [ ] `haptic-mark`: scrub across the edge of a mark or an A / B point; mark wins when a keyframe is in the same step;
      no more than one tick per 40 ms.
- [ ] `haptic-done`: after `screenshot`, once the file is on disk; after `save-clip`, when the clip is finished (not
      when it is queued).
- [ ] `haptic-error`: Back-hold `mark-snap` on a file with no exact index; `mark-in` stays quiet, but a command that
      says `No mark before` / `after` buzzes.
- [ ] Silent: menu items, trackpad scrubs and swipes, pressing and releasing a button by itself.
- [ ] `mouse-haptics=no`; `haptic-step=none`; `haptic-step=0x1b`; `haptic-end=sharp-collision` (no strong) — each takes
      effect the next time without restarting.
- [ ] `haptic-strength=35`: ordinary patterns weaker; `haptic-end` (strong, 80) clearly stronger, and the next ordinary
      one back at 35. Settings → Scrolling → Logitech mouse: "Leave haptic strength as it is" off, slider moves it; on
      again, the mouse's own value stays.
- [ ] `mx-panel-force=0` presses easiest, `100` stiffest, `default` the factory value (`logi-probe force`); survives
      reconnecting the receiver; `keep` never written. Settings: Leave as it is / Factory / Custom with a slider.

## 3. As before, nothing broken

- [ ] Without `input.conf`: every key and menu item as before, KeyHelp (`?`) shows the new mouse lines
      (Panel, Panel (hold), Gesture button, Back + wheel...).
- [ ] Settings → Mouse & Trackpad: wheel rows show the new defaults (wheel scrub, Alt volume, side wheel seek); the
      panel / Back / Forward chords are not in the table; "Reset gestures" leaves a hand-written
      `MX_PANEL+WHEEL_UP ...` or `MBTN_BACK+WHEEL_UP ...` line in `input.conf`.
- [ ] Trackpad: scrub, volume, pinch, three-finger swipes as before.
- [ ] Precision Scroll (`wheel-precision=yes`): about 6 events a notch over the video, normal wheel over the seek bar
      and outside, restored on quit; if LinearMouse had it on, it stays on.
- [ ] Startup: file launch time unchanged (`scripts/measure-startup.sh`, log in `docs/performance/startup.md`).

## 3a. Free spin

With `wheel-precision=yes`, a clean `input.conf` (no `MX_SHIFT` line) and
`defaults delete local.framescrub wheelFreeSpin` (a first launch). Note the mouse's own mode before
starting (by the feel of the wheel).

- [ ] First launch: the player in front, a video open, the wheel spins freely and Precision Scroll scrubs over the
      video; Settings → Scrolling → Logitech mouse → "Wheel in the player" says "Free spin + Precision Scroll".
- [ ] SmartShift button in the window: the wheel clicks (ratchet), the OSD says `Ratchet`, and over the video a notch is
      one plain scrub step, no Precision Scroll; press again: free spin and Precision Scroll are back, the OSD says
      `Free spin · Precision Scroll`.
- [ ] The picker in Settings follows the button (and the button the picker, when the player comes back in front).
- [ ] Over the seek bar and the playlist in free spin: the wheel is free, without Precision Scroll.
- [ ] Quit on ratchet and relaunch: the player starts on ratchet; the same for free spin (the choice is remembered).
- [ ] ⌘-Tab to another app: the wheel is in the mode it had before FrameScrub; ⌘-Tab back: the chosen mode
      again. The same for the start screen (no file open) and a sheet over the player.
- [ ] `wheel-precision=no`: the mode never changes, the SmartShift button works as the mouse's own.
- [ ] `MX_SHIFT screenshot` in `input.conf`: the button no longer switches, it takes the screenshot; the wheel stays in
      the chosen mode.
- [ ] `kill -9` the player in the zone: the wheel may stay in FrameScrub's mode.
      `cd ../LogiHIDPP && swift run logi-probe release` frees the buttons but not the wheel mode (the saved mode
      lives in FrameScrub's defaults), so the wheel is unchanged. Launch FrameScrub: it gives the mouse's own mode back
      (before taking the player's mode); quit it: the mouse is left in its own mode.
- [ ] Quit (⌘Q) in the zone: the wheel is back in its own mode at once. In another app press SmartShift (the other
      mode), then launch FrameScrub to the start screen: the wheel keeps the mode just picked (the quit gave the mode
      back and forgot it, so nothing stale is written at launch).
- [ ] Loupe in front: its wheel is untouched in either mode, SmartShift switches the mouse as usual.

## 4. Foreground and failures

- [ ] ⌘-Tab to Loupe and back with the panel held: nothing fires afterwards; in Loupe the panel does Loupe's thing;
      back in FrameScrub the panel works at once (the 300 ms retry).
- [ ] FrameScrub in the background: `logi-probe list` shows nothing diverted by it; in front again, it is back.
- [ ] Release the right button over another app, come back, press the middle button: a plain middle press, not a chord.
- [ ] Quit FrameScrub (⌘Q): `logi-probe list` shows nothing diverted, and `logi-probe hires` says off.
- [ ] Quit with the panel held and mid-edge-drag: same.
- [ ] Sleep and wake with FrameScrub open: panel, gesture button and Back / Forward work again; Precision Scroll wanted
      again over the video.
- [ ] Unplug and re-plug the receiver (or turn the mouse off and on): the same; haptics and force come back.
- [ ] After a force-quit (`kill -9`): the next launch gives everything back (`logi-probe list` while the new copy runs
      shows only the current divert set; Precision Scroll off after quitting it).
- [ ] Crash cure by hand: `cd ../LogiHIDPP && swift run logi-probe release` and `swift run logi-probe hires off`.
      `logi-probe release` does not give the wheel mode back: it comes back with a SmartShift press,
      `swift run logi-probe smartshift free|ratchet`, or the next FrameScrub launch.
- [ ] Another mouse without HID++ (a plain USB or Bluetooth one): no `MX_*` presses, side wheel and Back / Forward via
      AppKit work (`mx-side-buttons=system` or `watch`), no haptics, no errors; the Settings section is harmless.
- [ ] FrameScrub and Loupe both running: switching between them in either direction does not lose the buttons in
      either (known limit: another app leaving can end the watch until the next activation).

## 5. `input.conf`

- [ ] `MX_SHIFT screenshot`, relaunch or return to the app: the button behind the wheel takes the screenshot (binding
      it is what diverts it; `logi-probe list` shows it).
- [ ] `MX_PANEL_DBL ab-loop` with `MX_PANEL toggle-auto-color`: the tap waits out the double-click interval.
- [ ] `MBTN_FORWARD ignore`: Forward returns to the system (`logi-probe list`).
- [ ] A typo in a line: the notice `input.conf:N: ...`, the rest of the lines work.
- [ ] `mouse-long-press=600`: the new threshold after returning to the app.
- [ ] A user line `MX_PANEL+WHEEL_UP add volume 2` survives "Reset gestures" in Settings.

## Not checked automatically

The bridge (`LogiMouseBridge`), the AppKit side of the button filter, haptics on the real panel and everything with
Mac Mouse Fix, Loupe and sleep — no unit tests; only this list and a session with the mouse. The logic (press kinds,
edge drag, haptic events, side-button filter, config keys, README guard, default layout) is covered by `swift test`.
