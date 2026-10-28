# FrameScrub reference

Every key, gesture and setting. The [README](../README.md) has the overview.

## Controls

Two keyboard layouts: **classic** (default) is the original mpv-style one; **left-hand** keeps everything frequent under the left hand while the right one is on
the mouse or a TourBox (in each pair the left key goes back, the right one forward). Choose in Settings → General → Keyboard layout (`key-layout`); `input.conf` applies on top of either.
The mouse and trackpad work the same in both.

### Mouse and trackpad

| Input | Action |
|---|---|
| Two-finger horizontal swipe (trackpad) | Pause and step frames (faster swipe = bigger steps) |
| … with Shift (trackpad) | Fast frame scrubbing (×`scrub-fast-multiplier`) |
| Wheel (vertical) | Pause and step frames (`scrub`) |
| Hold right mouse button + wheel or scroll | Fast frame scrubbing (`MBTN_RIGHT+` bindings) |
| Side wheel (`WHEEL_LEFT` / `WHEEL_RIGHT`) | Seek ∓10 s |
| Hold right mouse button + side wheel | Playback speed down / up (`step-speed`: only changes the speed, never starts or reverses playback) |
| Shift+side wheel, Shift+⌥+side wheel | Step frames, fast (what Shift turns a plain mouse's wheel into) |
| Trackpad vertical swipe, ⌥+wheel | Volume |
| Pinch | Zoom about the fingers; halts at Fill (black bars gone) and 100 %, stretches past the limits and springs back. Never smaller than Fit |
| ⌘+scroll, ⌘= / ⌘− | Zoom in / out (√√2 a step; about the pointer for ⌘+scroll), animated; ⌘0 back to Fit |
| Two-finger double tap (Smart zoom) | Fit ↔ 100 % at the fingers (twice Fit where 100 % is not much larger) |
| Drag on a zoomed picture | Pan: the picture follows the cursor, glides on after release, rubber band at the edges (otherwise a drag moves the window) |
| Right-button drag up / down | Zoom in / out about the press point (a right click without moving stays play / pause) |
| Right click | Play / pause (acts on release, and not after a scroll or a zoom) |
| Double click | Show the video in its folder (Home's Folders, the video selected; as ↩ and ⌘↑) |
| Middle click | Full screen |
| Logitech MX Master 4: panel tap / hold | Auto colour on / off / vibrance on / off (this file) |
| … panel + wheel | Auto colour strength ±0.05 (this file) |
| … gesture button tap / hold | Save a frame / save the clips |
| … gesture button + wheel | Volume ±2 |
| … Back tap / hold | Cut mark: start here (`mark-in`) / snap the marked piece to its keyframes (`mark-snap`) |
| … Forward tap / hold | Cut mark: end here (`mark-out`) / delete the mark under the position (`mark-delete`) |
| … Back or Forward held + wheel | Drag the start / end of the piece under the position, live |

The Logitech rows need an MX Master and are described below; the rest of the table works with any mouse.

### Left-hand layout (`key-layout=left-hand`)

What each action does in detail is in the classic table below.

| Keys | Action | Also (right half) |
|---|---|---|
| `Space` | Play / pause | |
| `a` `s` `d` | Shuttle: back / stop / forward. Each press the same way goes faster (1, 2, 4, 8×); the other way starts at 1×. `Space` after it plays on at 1× the last way | `j` `k` `l` |
| `q` / `e` | One frame back / forward | `,` `.` |
| `⇧q` / `⇧e` | Previous / next keyframe | `⌥←` `⌥→`, `Ctrl+←` `Ctrl+→` |
| Hold `w` | Play at `hold-speed` while held | hold `/` |
| `z` / `c` | Seek ∓5 s | `←` `→` |
| `⇧z` / `⇧c` | Seek ∓60 s | `↓` `↑` |
| `⌥z` / `⌥c` | Exact seek ∓1 s | `Shift+←` `Shift+→` |
| `⌥⇧z` / `⌥⇧c` | Start of this (or the previous) scene / next scene | `Shift+↓` `Shift+↑` |
| `x` | Back to where the last seek started | `Shift+Backspace` |
| `g` | Go to a time or frame | ⌘G |
| `f` / `⇧f` | A-B range: start, end, clear / at B: loop, pause, or back and forth | |
| `r` / `t` | Mark in / mark out | |
| `⇧r` / `⇧t` | Previous / next mark edge | |
| `⌥r` | Mark start to the nearest keyframe | |
| `⌥f` | Add the A-B loop as a mark | |
| `⇧x` / `⌥x` | Delete the mark here / all marks (⌘Z undoes) | |
| `⇧b` | Play only the marks | |
| `b` | Save the marks as clips | |
| `v` / `⇧v` | Save frame / export the A-B range | |
| ⌘C / ⇧⌘O | Copy frame / show saved frames | |
| `1` / `2` | Previous / next video in the folder | PgUp / PgDn, `<` / `>` |
| `3` / `4` / `5` | Speed −/+ `speed-step`, reset | `[` `]` `Backspace` |
| `Tab` / F9 / ⌘F | Playlist panel / folder order / filter | F8 |
| `` ` `` | Full screen (Esc leaves it) | middle click |
| ↩ / ⌘↑ | Show the video in its folder | double click |
| ⌘T | Float on top | |
| `⌥a` / `⌥v` / `⌥⇧v` | Aspect / vibrance / auto colour (this file; saving for the folder or as default: Playback > Colour) | |
| `u` / `U` | Still-frame upscaling on / off / upscaler for saved frames | |
| `9` `0` `m` | Volume down, up, mute | |
| `⌥m` | Scrub audio on / off: in pause a step plays a short piece of sound, scrubbing plays it like tape — pitch follows the speed, backward is reversed (`scrub-audio`) | |
| `⇧⌥m` | Scrub pitch: tape (follows the speed) / natural (the sound's own pitch from 0.5× up, reversed backward) (`scrub-audio-pitch`) | |
| `i` / `o` / `?` | Stats panel / progress / these keys | |
| ⌘⌫ / ⌘Q | Move the video to the Trash / quit | |
| ⌘W | Close the video: back to Recent or Stash (no video: close the window) | |

**Playing backward** (the shuttle's back key): no sound; the frames come from the frame cache, decoded in chunks from
their keyframes below the playhead, so everything stays within `cache-size`. When a speed asks for more frames than the
decoder manages (often −4× and −8× on 4K), the speed is kept and frames are skipped — only reference frames, or only
keyframes; stats (`i`) show `shown N fps` and which. Playing backward stops at the first frame; the A-B loop, its
modes and Play Marks Only work mirrored.

### Classic layout (default)

| Input | Action |
|---|---|
| `,` / `.` | One frame back / forward (the message shows the frame type: `K` keyframe, else `I` / `P` / `B`) |
| `Space`, `p` | Play / pause (right click acts on release, and not after a scroll) |
| ⌘1 ⌘2 ⌘3 ⌘4 | Window 50 % / 100 % / 200 % / fit to screen (a file opens at 100 % when that fits the screen, else at 85 % of it; the window keeps its place across files, and its size and place across launches) |
| ⌘C | Copy the frame to the clipboard (size follows `save-scale`); in a text field it copies the text |
| ⇧⌘O | Show the saved frames in Finder (also: click the "Saved: …" message) |
| F8 | Playlist panel (a click on a row opens that file) |
| ⌘F | Filter the playlist by name (part of the name, any case); Return opens the first match, Esc clears it. While a filter is on, PgUp / PgDn move through the matches and the title shows `3 / 7 (48)` |
| F9 | Folder order: name → newest first → largest first (also the menu at the top of the playlist; saved as `playlist-sort`) |
| ⌘⌫ | Move the video to the Trash and open the next one. On a volume without a Trash (most SMB shares) it asks first, then deletes for good |
| ↩, ⌘↑, double click | Show the video in its folder: Home's Folders on it, the video selected, wherever it was opened from (`show-in-folder`; also File › Show in Folder). ⌘[ / Esc come back to it, and from then on Back goes to that folder |
| ⌘W | Close the video and go back to where it was opened from — Home's Recent or Stash (`close-file`; also the ‹ Recent / ‹ Stash button in the top left corner). With no video open it closes the window |
| ⌘, | Settings |
| `←` `→` / `↑` `↓` | Seek ∓5 s / ±60 s (keyframes when `seek-mode=keyframe`) |
| `Shift+←` `Shift+→` | Exact seek ∓1 s |
| `⌥←` `⌥→` (also `Ctrl+←` `Ctrl+→`) | Previous / next keyframe (`Ctrl+arrows` reach the player only when macOS's "Move left/right a space" shortcuts are turned off) |
| ⌘G | Go to a time or frame: `1:23`, `1:02:03.5`, `83.4` (seconds) or `f1234` / `#1234` (frame, numbered from 0 as in the OSD); Enter jumps exactly, Esc closes. Shift+Backspace comes back |
| Shift+↑ / Shift+↓ | Next scene / start of this scene (again within 1 s: the previous one). Keyframes are compared, then the frames between them, so the jump lands on the first frame of the new scene; presses during a search add up; Shift+Backspace comes back |
| `Shift+Backspace` | Back to where the last seek started (seeks less than a second apart count as one); again to undo that. Frame steps are not seeks |
| `<` / `>`, PgUp / PgDn | Previous / next video in the folder |
| `[` `]` `Backspace` | Speed −/+ `speed-step` (0.25 by default: 1 → 1.25 → 1.5, never below one step), reset to 1× (also Playback → Normal Speed). The speed stays for the next video opened in the window and is shown when that video opens (`keep-speed`) |
| Hold `/` | Play at `hold-speed` (2× by default) while held, also from pause; on release the speed and pause come back |
| `9` `0` `m` | Volume down, up, mute |
| `⌥m` | Scrub audio on / off: in pause a step plays a short piece of sound, scrubbing plays it like tape — pitch follows the speed, backward is reversed (`scrub-audio`) |
| `⇧⌥m` | Scrub pitch: tape (follows the speed) / natural (the sound's own pitch from 0.5× up, reversed backward) (`scrub-audio-pitch`) |
| `l` | Set range start, then end, then clear (loops playback). While A is set, the frame line counts from it (`A+37 f (1.23 s)`); setting B shows the range's length |
| `L` | At B: loop back to A, pause on B (playing on from B starts at A again), or back and forth (turns around at B and at A). Backward the same mirrored. Also Playback > At B; saved as `ab-loop` |
| `⌥l` | Segments: lock playback to the segment under the position / unlock (`⇧⌥f` in left-hand) |
| `Ctrl+j` `Ctrl+k` `Ctrl+l` | Shuttle: back / stop / forward (see the left-hand table) |
| `s` | Save current frame (the picture flashes faintly, as it does for ⌘C) |
| `S` | Export the A-B range (a sheet asks which frames and what size; press again or `Esc` to cancel a running export) |
| `I` / `O` | Cut marks: mark in / mark out. `I` opens a mark here (or moves the start of the mark you are in or the open one), `O` closes it here (or moves the end of the mark you are in, or of the nearest one to the left). Marks are green on the seek bar, kept with the file's position, and never touch the A-B loop |
| `{` / `}` | Previous / next mark edge |
| `k` | Move the start of the mark here to the nearest keyframe, so its clip has no lead-in |
| `M` / `x` / `X` | Add the A-B loop as a mark / delete the mark here (or the open one) / delete all marks |
| `P` | Play only the marks: playback jumps over the rest and pauses after the last mark |
| ⌘Z / ⇧⌘Z | Undo / redo mark changes (also the clearing by ⌘⇧C) |
| ⌘⇧C | Save the marks as video clips without re-encoding: separate files, joined into one, or everything except the marked (a sheet asks when there are several marks; `clip-mode`, `clip-confirm`). Each clip starts on the keyframe at or before its mark; clips are written one at a time in the background, and the marks are cleared |
| `f` | Full screen |
| `v` | Vibrance on / off for this file: livelier dull colours, saturated colours and skin tones nearly untouched (also Playback > Colour; strength `vibrance`; see [Colour memory](#colour-memory)) |
| `c` | Auto colour (tone curve, shadows and highlights, vibrance; strength and parts in `auto-color-strength` / `auto-color-filters`): analysed again after every scene cut and applied only to scenes it changes by at least `auto-color-threshold`; again to turn it off (press twice to recompute). Remembered for this file (see [Colour memory](#colour-memory)). SDR only |
| ⇧C / ⇧V | Save the auto colour (`auto-color`, `auto-color-strength`) / vibrance (`vibrance-on`, `vibrance`) in effect as the default in `framescrub.conf`; the picture does not change |
| ⌥C / ⌥V | Save the auto colour / vibrance in effect for the file's folder and its subfolders; the picture does not change |
| `a` | Aspect: auto (the file's pixel aspect, black bars found on keyframes across the file and cut off) → no crop → 16:9 → 4:3 → 2.35:1 → square pixels. The window keeps its height and changes width; saved and copied frames and the seek-bar previews look like the screen, and auto colour analyses the picture without the bars. Every file starts at auto |
| `T` | Keep the window above other apps (also View > Float on Top; saved as `ontop`) |
| `o` / `i` | Show progress / toggle the stats panel (also View > Show Stats): File, Stash (for a file from Stash), Video, Audio, Playback, Picture and Diagnostics — codecs with profile and level, bit rates, container, decoder, cache… Drag a section's header to reorder, its triangle collapses it; drag the panel to move it (it keeps the nearest corner), its edges to resize it; a double click on a section title (or Reset Position) puts it back top right at its default size. Values can be selected and copied (⌘C; with nothing selected ⌘C copies the frame, and other keys still go to the player); the right-click menu has Copy All, Reset Section Order and Reset Position. Place, size, order, collapsed sections and whether it is open are remembered; it shows only while a video is open |
| `?` | Key cheat sheet: the bindings in effect (`input.conf` included), by section; `?` or Esc closes it (also Help > Keyboard Shortcuts) |
| `q` | Quit |

Rebind keys in `~/.config/framescrub/input.conf` using mpv syntax (`KEY command`), e.g.
`Ctrl+e export-range` or `s ignore`. In both config files `#` starts a comment only at the
start of a line or after whitespace.

A page's actions can be bound too: `Alt+9 plugin-action mark` runs the plugin page's action `mark`; the key help (`?`)
lists the actions a page declares under "Plugin".

Menu items own their ⌘ keys: ⌘1–⌘4, ⌘C, ⌘F, ⌘⌫, ⇧⌘O and ⌘, cannot be rebound in `input.conf`. The Playlist item in
the menu has no key of its own; `F8` comes from the default `input.conf`.

Scrolls and pinches are bound like keys, with separate names for trackpad and mouse:
`TRACKPAD_LEFT/RIGHT/UP/DOWN`, `WHEEL_UP/DOWN/LEFT/RIGHT`, `PINCH_IN/OUT`, with `Shift+ Alt+ Meta+ Ctrl+`.
Actions: `scrub`, `scrub fast`, `scrub invert`, `seek N [exact|keyframes]`, `add volume N`, `zoom N`,
`multiply speed N`, `step-speed up/down`, `playlist-prev`, `playlist-next`, `ignore`. Example: `TRACKPAD_UP seek 5` /
`TRACKPAD_DOWN seek -5` makes vertical swipes seek instead of changing volume. A regular wheel fires a command once
per notch.

`MBTN_RIGHT+` holds the right mouse button: by default `MBTN_RIGHT+WHEEL_…` and `MBTN_RIGHT+TRACKPAD_…` are
`scrub fast`. The middle button is `MBTN_MID`: by default a click is `cycle fullscreen` (`MBTN_LEFT_DBL` is `show-in-folder`), and the
wheel turned while the wheel is held down (`MBTN_MID+WHEEL_UP` / `_DOWN`) is `add volume 5` / `-5`; with that chord
bound, the click acts on the release, and not at all after a scroll. A button with a `_DBL` binding runs its single
action only after the double-click interval. The right button released after it served as a modifier does not play /
pause. Example:

```
MBTN_RIGHT+WHEEL_LEFT   step-speed down
MBTN_RIGHT+WHEEL_RIGHT  step-speed up
MBTN_MID                cycle ontop
MBTN_FORWARD_DBL        ab-loop
MBTN_RIGHT+MBTN_MID     set speed 1.0
```

Utilities that act on the right button (BetterTouchTool's "Right Click + …" triggers and the like) hold its press
back to tell a click from a chord, and FrameScrub then sees the button only some of the time: turn them off for
FrameScrub.

#### Logitech mouse

An MX Master 4 (any Logitech mouse that speaks HID++ through its receiver) gets more than the system gives: FrameScrub
talks to it through the sibling package `../LogiHIDPP`, only while FrameScrub is the active app, and hands every
button back when it goes to the background or quits. Without such a mouse nothing below happens and everything else works
as before.

Buttons you can bind in `input.conf`: `MX_PANEL` (the haptic panel under the thumb), `MX_GESTURE` (the button above it),
`MX_SHIFT` (the button behind the wheel; unbound by default: binding it diverts its control `0x00C4`, and while
FrameScrub is in front that button then no longer toggles the SmartShift ratchet), plus `MBTN_BACK`, `MBTN_FORWARD` and
`MBTN_MID`. Each has four kinds of press:

| Name | Press |
|---|---|
| `MX_PANEL` | tap (acts on release when the button also has a `_LONG` line or wheel chords) |
| `MX_PANEL_DBL` | double tap (the single tap waits out the double-click interval) |
| `MX_PANEL_LONG` | held for `mouse-long-press` (400 ms). A button that also has wheel chords acts on release, and plays `haptic-long-armed` at the threshold |
| `MX_PANEL+WHEEL_UP` | wheel turned while the button is held (`MX_GESTURE+`, `MBTN_BACK+`, `MBTN_FORWARD+`, `MBTN_MID+` too) |

A wheel turn with a button held cancels its tap and long press; moving the pointer 8 pt or more with a button down
makes it a drag, not a press (so Mac Mouse Fix drags and a trembling hand do nothing). The movement counts wherever the
pointer is, over a slot or another app's window, and when another app freezes it (Mac Mouse Fix's "lock pointer during
drag"). Back and forward are clicks: their tap acts on the release even when nothing else is bound to them, so a drag
with one (Mac Mouse Fix switching the Space) never runs its binding. The defaults:

```
MX_PANEL                    toggle-auto-color
MX_PANEL_LONG               toggle-vibrance
MX_PANEL+WHEEL_UP / _DOWN   add auto-color-strength 0.05 / -0.05
MX_GESTURE                  screenshot
MX_GESTURE_LONG             save-clip
MX_GESTURE+WHEEL_UP / _DOWN add volume 2 / -2
MBTN_BACK                   mark-in
MBTN_BACK_LONG              mark-snap
MBTN_BACK+WHEEL_UP / _DOWN  scrub-edge start
MBTN_FORWARD                mark-out
MBTN_FORWARD_LONG           mark-delete
MBTN_FORWARD+WHEEL_UP/_DOWN scrub-edge end
MBTN_MID                    cycle fullscreen
MBTN_MID+WHEEL_UP / _DOWN   add volume 5 / -5
```

`add auto-color-strength ±d` steps the open file's auto colour strength (0…1, the Settings slider's scale; remembered
for the file). `scrub-edge start|end` is the live edge drag: hold Back (or Forward) and turn the wheel, and the start
(end) of the cut mark under the position follows the video frame by frame — with the usual scrub sensitivity, Precision
Scroll and acceleration. The edge stops against the other end of its mark and against the neighbouring mark, and ticks
on keyframes (the real start of a future clip). Releasing the button commits the move as one ⌘Z step; leaving the app,
losing focus or Esc puts the edge back. With no mark under the position the drag just scrubs and the release is a plain
`mark-in` / `mark-out` on the frame it ended on. The side wheel under the thumb is not taken from the system: it arrives
as `WHEEL_LEFT` / `WHEEL_RIGHT`, one event a notch.

**Haptics.** The MX Master 4's panel clicks on events of the player. Each event has its own key (a Logitech pattern name
in any case with `_` or space for `-`, a number such as `0x1b`, or `none`; add ` strong` to play it at
`haptic-strong-strength`); `mouse-haptics=no` silences all. The mouse buzzes for keyboard and mouse actions only, not for
the trackpad or menu items.

| Key | Default | When |
|---|---|---|
| `haptic-step` | whisper-collision | a step of speed, volume or auto colour strength; a ±10 s jump from the mouse (side wheel or a button; a key's seek is silent) |
| `haptic-detent` | damp-collision | speed at or through 1×; strength at or through 25 / 50 / 75 % |
| `haptic-limit` | sharp-collision | a control hits its end; an edge drag stops against its limit |
| `haptic-long-armed` | damp-state-change | the long-press threshold of a button that also has wheel chords |
| `haptic-toggle` | sharp-state-change | a `toggle-*` / `cycle-*` switched something |
| `haptic-end` | sharp-collision strong | the first / last frame, the end of the playlist (once per push) |
| `haptic-keyframe` | whisper-collision | a plain wheel scrub or an edge drag passed a keyframe |
| `haptic-mark` | subtle-collision | a plain wheel scrub passed the edge of a mark or an A / B point |
| `haptic-done` | completed | a frame or clip is written to disk |
| `haptic-error` | angry-alert | a command refused (no mark before / after, no exact index) or a write failed |

The mouse reaches FrameScrub through MouseService, which must be running; without it the mouse works as an ordinary
one. The mouse's own settings, the normal haptic strength and how hard the panel must be pressed, are MouseService's
(its Settings…); `haptic-strength` and `mx-panel-force` in this file are ignored with a warning. Pressing and releasing
a button never buzzes by itself. Settings → Mouse & Trackpad has the toggle, a pattern per event, the strong strength
and the side buttons.

**Back / forward and Mac Mouse Fix.** `mx-side-buttons=watch` (default) listens to the buttons over HID++ without taking
them from the system, so Mac Mouse Fix keeps its own Back / Forward actions (a swipe with Back held, say) and FrameScrub
still sees every tap; presses that the system reports as well (within 100 ms) are counted once, and a press while the
pointer is not over a FrameScrub window is ignored. `take` diverts the buttons while FrameScrub is in front, so they are
FrameScrub's alone. `system` reads AppKit's events only (no HID++ for those two buttons: with Mac Mouse Fix running,
FrameScrub sees nothing). On Home back / forward run no binding: they go back and forward in Home's history, over the
Stash page in its own (with `take` too).

**Precision Scroll.** Logitech mice with a high-resolution wheel and SmartShift get free spin and Precision Scroll in
FrameScrub only, as one choice: with `wheel-precision=yes` (Settings → Scrolling → Logitech wheel) FrameScrub follows
the wheel mode you pick while its window is in front. Free spin goes with Precision Scroll, the ratchet without it, and
the SmartShift button switches between them (the OSD says `Free spin · Precision Scroll` or `Ratchet`). The choice is
remembered between launches and starts as free spin; Settings has the same picker. The zones: the player window with a
file open (no sheet) sets the mode, the video in it adds Precision Scroll on free spin; over the seek bar and playlist
the wheel is free spin or ratchet without Precision Scroll. On Home, in other apps and after quit the mouse
has its own mode back (a quit gives it back at once, so a mode you pick later in another app is kept at the next
launch), and after a crash the next launch gives it back. Binding `MX_SHIFT` in `input.conf` diverts the
SmartShift button, so the mouse no longer switches by itself: the button is yours then. `wheel-precision=no` turns both
off, the mode and Precision Scroll.
A notch of Precision Scroll sends about 6 wheel events: `scrub` moves `wheel-precision-frames` a notch (6 by default, a frame per event,
so a light touch moves one frame; 3 moves a frame every second event, 1 a frame a notch, 0.5 a frame every two notches).
With `wheel-precision-mode=fps` a notch instead covers `wheel-precision-time` of video at the file's frame rate (100 ms:
2.4 frames at 24 fps, 3 at 30, 6 at 60) — still a scrub through every frame, so never more than 6 frames a notch.
Settings has the mode and a slider; `scrub fast` and the other wheel commands keep their speed per notch. Only the vertical wheel has the mode.
If LinearMouse (or Logi Options+) turns the high-resolution wheel on for the whole system, FrameScrub leaves it on.

**If the mouse stays strange after a crash.** The next launch gives back what a crashed FrameScrub held, the wheel mode too, and turns
Precision Scroll off again. To do it by hand:

```
cd ../LogiHIDPP && swift run logi-probe release     # un-divert every control
cd ../LogiHIDPP && swift run logi-probe hires off   # high-resolution wheel off
cd ../LogiHIDPP && swift run logi-probe smartshift free   # or ratchet: the wheel mode (a SmartShift press too)
swift run logi-probe list                                # shows what is diverted (nothing after a clean quit)
```

`logi-probe release` does not touch the wheel mode: a press of the SmartShift button or `logi-probe smartshift
free|ratchet` sets it by hand.

Seeks flash a frameless icon on their side of the video (back on the left, forward on the right); play/pause,
speed, volume, mute, revert-seek, the previous/next file and the end of the file flash one in the centre. Frame
steps show only the frame line in the top-left corner. The OSD and the stats panel sit on Liquid Glass.

### Menus and windows

- The **Playback** menu lists frame and keyframe steps, speed, the A-B range, saving, the previous/next video and
  **Colour** (auto colour and vibrance for the file, saving them for the folder or as default, resetting the file's
  or the folder's own colour).
  Menu items show the key bound to them in `input.conf` next to the title; those keys stay `input.conf`
  bindings (the menu does not take them), so rebinding a key changes the hint.
- The title shows the file's place in its folder (`name.mp4 — 12 / 48`), and opening a file flashes the same in
  the OSD; a file from Stash shows `Title — Studio · date` instead (no folder position). The title's file icon
  works as in other apps: ⌘-click shows the path, dragging it moves the file.
- A file that cannot be opened leaves its reason on screen (missing, no permission, network drive not responding,
  read error, not a video or damaged, no video track) with the technical message underneath; Return tries again
  (handy once a sleeping NAS wakes up), PgUp / PgDn go on to the neighbours.
- The pointer hides when it rests on the video for 2 s (with the seek bar), on a key press and while scrubbing;
  moving the mouse brings it back. The seek bar stays while the pointer rests on it.
- The seek bar shows cut marks in green, with the lead-in each clip gets from the keyframe before its mark in a
  fainter green, and an open mark from its start to the playhead.
- The seek bar shades the A-B range and grows thicker while you point at it. The preview then shows the frame number
  next to the time and, under the picture, a lens of ±20 s around that point: keyframes as ticks, the point as a line
  in the middle, the playhead as a dot. The label says `K` on a keyframe, else how far the keyframes either side are
  (`K −0.80 s / +2.20 s`).
- Scrolling over the seek bar (wheel notch, or swipe like a scrub) moves the preview from keyframe to keyframe without
  touching playback; a click then goes to the keyframe shown. Moving the pointer lets the preview follow it again.
- **Slots.** The window has three, left, right and bottom (View › Slots, ⌃⌘← / ⌃⌘→ / ⌃⌘↓); each holds the playlist,
  a plugin page (`plugin=Name | URL`, repeatable; the `plugin=` page of a
  `framescrub://open` link is listed as `Plugin`) or nothing, whose **+** menu fills it. A slot is pinned (takes room from the video) or lies
  over it on a dark, glass or clear backdrop, hides on its own when the pointer leaves, after a choice or only when
  asked, and slides in when the pointer comes near its edge (`slot-reveal-distance`, 12 pt by default; the bottom slot at the very edge) (or on a click on its tongue). Each is kept in `slot-left` / `slot-right` / `slot-bottom`.
  A page drives the player through `window.framescrub` (bridge version 2, documented at the top of
  `Sources/FrameScrub/PluginPanel.swift`), and may hand it a playlist. ⌥⌘P shows the first slot holding a page; **Focus
  Plugin Panel** (⌃⌥⌘P) gives the page the keyboard, and the page's `focusPlayer()` returns it. A page may open local
  videos only after you allow its origin once (`plugin-open-allowed`).
  What the page knows about an item it opens or lists (`info: {title, studio, performers, date, code, url}`) titles the
  window and the OSD as a Stash scene's details do, and names a stream's exported frames and clips:
  `%{video-name}` becomes `<date> [<code>] <title> (<performers>)` (a local file keeps its own name). `frames:
  "/folder"` on the same items sends their saved frames and clips there (one consent, as for local files). The mouse's
  back / forward over a page go through its history; **Reload Page** (slot ▾) or ⌘R in the page reloads it. Keys a page
  declares for its actions work while it is in a slot, shown or hidden, where your own keys leave them free.
- **Settings** (⌘,) has six tabs: General, Scrolling, Saving, Display, Mouse & Trackpad, and Stash. Changes apply
  at once. Edits keep the comments in `framescrub.conf` / `input.conf`; default values that are not in the
  file are not added.
- **View → Preview Size** (Off / Small 160 / Medium 240 / Large 360 / Extra Large 480 pt) sets `preview` /
  `preview-width`: a small picture above the seek bar while you point at it.
- **Home** (View → Home, ⇧⌘H) is HomeScreenKit's view, shared with Loupe: a sidebar (⌃⌘S hides it,
  `home-sidebar`) with Recent and, with `stash-url` set, the Stash library. It is what the window shows when no
  video is open; over an open video ⇧⌘H or ⌘[ shows it with the video paused, and Esc goes back to the video
  where it was (⌘[ on Home is Home's own Back). **Recent** (also File → Open Recent) lists the last `recent-count` videos (50) by the day they were
  last left (Today, Yesterday, This Week, Earlier; the toolbar sorts by name too), each with the last picture seen
  in it, a bar for how far it was watched and "12:34 / 45:10". A file that cannot be reached now (a share not
  mounted) shows faint. The arrows move the selection, typing a name selects it, Return opens it; a right click
  offers Show in Finder, Copy Path and Remove from Recent (the file comes back when opened again; Open Recent →
  Clear Menu clears both). The cards' size: ⌘= / ⌘− (also ⌘ + wheel, a pinch, or the MX side wheel) one column
  more or fewer, ⌘0 the default, saved as `home-card-size` (File → Larger Cards / Smaller Cards / Default Card
  Size). The mouse's back and forward go through Home's history. File → Copy Path (⌥⌘C) copies the open video's
  path. The pictures are JPEGs of up to 1280 pixels in `~/Library/Application Support/FrameScrub/thumbnails` (the
  newest 200), saved when you leave a file; a file without one gets the keyframe at the place it was left, read in
  the background while Recent is up.
- **Places** in Home's sidebar are the home folder and the mounted volumes; each opens as a tree, and a folder shows
  its subfolders and its videos (the other files are left out) as cards with a keyframe from a tenth of the way in,
  the length and how far it was watched. The keyframes are made in the background, one file at a time, and kept in
  `~/Library/Application Support/FrameScrub/thumbnails/posters` (480 pixels, the newest 2000), with the lengths found
  while making them (`durations.json`). F2 renames,
  ⌘⌫ moves to the Trash, ⌘↑ goes up, ⌘[ / ⌘] go back and forward, typing a name selects it. A video opened from a
  folder goes back to that folder with it selected (⌘W, the ‹ button with the folder's name, ⇧⌘H); the folder's
  videos are the playlist, in `playlist-sort`'s order.
- A file that does not open leaves its reason in the window (Return tries again, ⌘W goes to Home).
- The window opens with the size and place it had when the app last ran; a file still sizes it on open. The start
  screen keeps a size of its own: closing a video (⌘W, File → Close Video, or the ‹ Recent / ‹ Stash button that
  comes with the seek bar) gives the window back Home's size and place.
- The window can be dragged by any point of the picture (not in full screen).
- `i` also shows "Saved this session: N".

### TourBox Lite

`extras/tourbox/FrameScrub.tb` is a TourBox Console preset for the classic key layout, made for the TourBox Lite in
the right hand. Import it in TourBox Console and assign it to FrameScrub.app. It is generated by
`scripts/make-tourbox-preset.py` (edit the table there and run it again) from `FrameScrub-2026-10-07.tb`, the first
preset, kept as the template.

A button held for a combination also sends its own action, so the buttons are split: **Tall, Short and Top are
modifiers** — held while turning, pressed in pairs or double-pressed, and a single press does nothing; **Scroll click,
Tour, C1 and C2 act on a press** and are never held for a combination.

| Control | Alone | + Tall | + Short | + Top |
|---|---|---|---|---|
| Knob | Frame ∓1 | Exact ∓1 s | Speed −/+ `speed-step` | Previous / next video (slow) |
| Scroll | Seek ∓5 s | Seek ∓60 s | Volume −/+ | Shuttle back / forward (slow) |

| Button | Press | Double press |
|---|---|---|
| Scroll click | Play / pause | |
| Tour | Save frame | |
| C1 | Set A-B point | Copy frame |
| C2 | Back to before the last seek | |
| Tall | — | Export the A-B range |
| Short | — | Speed 1× |
| Top | — | Full screen |
| Tall + Short | Reveal saved frames | |
| Top + Tall | Still-frame upscaling on / off | |
| Top + Short | Stats | |

## Settings

`~/.config/framescrub/framescrub.conf`:

```ini
cache-size=2048                 # MiB of decoded frames kept around the playhead
read-cache=256                  # MiB of file data kept in 2 MiB blocks for all decoders; 0 = off (next file)
network-mode=auto               # auto | yes | no — read files on network volumes gently (see Network files); auto asks the volume
scrub-px-per-frame=8            # trackpad points per frame at slow speed
scrub-accel-from=20             # 5…120 frames/s: a scrub faster than this takes bigger steps (twice as fast, twice the steps)
scrub-accel-max=240             # 30…2000 frames/s: acceleration takes the scrub to at most this (fast scrub multiplies on top)
scrub-invert=no                 # yes: swipe the other way to go forward
scrub-fast-multiplier=10        # 1…100: fast scrubbing (Shift, or Shift+⌥+wheel) moves this many times faster
scrub-accel=yes                 # no: no acceleration — one frame per wheel notch / scrub-px-per-frame, however fast
wheel-precision=no              # yes: Logitech mice get free spin and Precision Scroll (or the ratchet, by SmartShift) in the player
wheel-precision-mode=frames     # frames | fps — Precision Scroll scrubs wheel-precision-frames a notch, or wheel-precision-time of video
wheel-precision-frames=6        # 0.5…6: frames a notch of Precision Scroll moves a plain scrub (6 = a frame per wheel event)
wheel-precision-time=100        # 20…250 ms of video a notch scrubs through with wheel-precision-mode=fps (at most 6 frames, at least 0.5)
mouse-long-press=400            # 150…2000 ms a Logitech mouse button is held before it counts as a long press
mouse-haptics=yes               # no: the MX Master 4's haptic panel stays quiet
haptic-step=whisper-collision   # pattern for a step of speed, volume or auto colour strength, a ±10 s jump from the mouse; a name, a number or none, + " strong" for the strong strength
haptic-detent=damp-collision    # pattern for speed at / through 1×, strength at / through 25 / 50 / 75 %
haptic-limit=sharp-collision    # pattern for a control at its end, an edge drag stopped by its limit
haptic-long-armed=damp-state-change # pattern for the long-press threshold of a button that also has wheel chords
haptic-toggle=sharp-state-change # pattern for a toggle-* / cycle-* that switched something
haptic-end=sharp-collision strong # pattern for pushing against the first / last frame or the end of the playlist
haptic-keyframe=whisper-collision # pattern for a plain wheel scrub or an edge drag passing a keyframe
haptic-mark=subtle-collision    # pattern for a plain wheel scrub passing the edge of a mark or A / B
haptic-done=completed           # pattern for a frame or clip written to disk
haptic-error=angry-alert        # pattern for a refused command or a failed write
haptic-strong-strength=80       # 0…100: the strength patterns marked "strong" play at
mx-side-buttons=watch           # watch | take | system — back / forward: listen to the mouse, divert them while in front, or AppKit's events only
frame-format=jpeg               # jpeg | png | heic | tiff
jpeg-quality=95                 # 1…100, JPEG quality of saved frames
heic-quality=95                 # 1…100, HEIC quality of saved frames
frame-dir=%{video-dir}/%{video-name} # where frames go; %{video-dir}, %{video-name}
frame-template=%{video-name}_f%{frame:06}_%{time:hh-mm-ss.mmm} # frame file name; %{video-name}, %{frame:06} (zero-padded), %{time:hh-mm-ss.mmm}
export-threads=4                # 1…64, frames the A-B export encodes at once
volume=100                      # 0…100
seek-mode=keyframe              # keyframe | exact (relative seeks and seek-bar clicks)
scene-threshold=45             # 0…255 — how different two keyframes must be to check for a scene cut between them (Shift+↑ / Shift+↓)
scene-lookahead=30             # keyframes searched ahead for the next scene after a jump (0 = none)
scene-check-time=1             # seconds a press may check candidates frame by frame; then keyframes alone decide (0 = keyframes only)
scene-search-time=4            # seconds a press may search; then it stops and says how far it looked (press again to go on)
hwdec=auto                      # auto | yes | no — VideoToolbox (H.264/HEVC through an own async session) or software
resume-playback=yes             # reopen files where you left them (and their A-B range)
playlist-autoadvance=yes        # open the next video in the folder at the end
autoplay=no                     # yes: start playing every file as it opens
activate-on-open=yes            # bring the window to the front when a file is opened from Finder or the Dock
playlist-sort=name              # name | date | size — the folder's order (date: newest first, size: largest first)
playlist-font-size=14           # 9…32 points, text size of the playlist panel (F8)
playlist-view=list              # list | strip: the playlist as names, or as a vertical strip of pictures
playlist-strip-return=3         # 0…30 seconds: the strip goes back to the playing video after browsing; 0 never
home-card-size=220              # 60…480 points, width of Home's cards (⌘= / ⌘− / ⌘0 on Home)
recent-count=50                 # 1…200, recent videos Home's Recent shows
home-sidebar=yes                # Home's sidebar (⌃⌘S)
icon-set=lucide                 # the line icons: lucide | sf (SF Symbols); read at launch
single-instance=no              # yes: a second launch hands its file to the running window and quits (read at launch)
home-tab=recent                 # where Home opens at launch: recent | folders | stash
stash-url=                      # Stash server, e.g. http://localhost:9999; empty = off
stash-api-key=                  # Stash API key when Stash has a login
stash-path-map=                 # extra path rules stashPrefix=localPrefix;… tried before the mounted shares
stash-stream=auto               # auto | never | always — play Stash's stream when the file is on no share this Mac can reach (always: the stream even then)
plugin-open-allowed=            # origins (http://host:port, comma-separated) whose plugin pages may open local videos
slot-left=empty, overlay, glass, mouse-leaves, 400, hidden, at-once      # left slot: views as tabs, the shown one first, joined by " + " (empty, playlist, plugin:<name>; e.g. playlist + plugin:Notes), pinned|overlay, dark|glass|clear, mouse-leaves|after-choice|manual, size, shown|hidden, at-once|tongue (how it comes from its edge)
slot-right=playlist, overlay, glass, mouse-leaves, 400, hidden, at-once  # right slot, as slot-left (the default keeps the playlist there)
slot-bottom=empty, overlay, glass, mouse-leaves, 240, hidden, at-once    # bottom slot, as slot-left; its size is a height, 120…900
slot-reveal-distance=12         # 2…60 points: how near the left or right edge the pointer brings a hidden slot (the bottom one: its last 2 points)
slot-flash=no                   # yes: the playlist's slot shows for 0.8 s when the video changes by autoadvance or a key (as Zen's sidebar on a tab switch)
mouse-profile=viewing           # viewing | editing: what the mouse's buttons do (editing: marks under back / forward; viewing: back shows the info, forward nothing). SmartShift held 0.6 s, or View › Mouse Buttons for Editing, switches
export-mode=all                 # all | every | fps — which frames of A-B the S export saves
export-every=10                 # 2…10000: export-mode=every saves every N-th frame
export-fps=1                    # 0.01…240: export-mode=fps saves this many frames per second of video
export-sharp=no                 # yes: keep only the sharpest frame of each N frames / 1/F s
export-skip-blurry=no           # yes: skip a window whose frame is blurrier than its neighbours
export-sharp-threshold=80       # 1…100 %: a window's best frame needs this share of its neighbours' median sharpness
export-sharp-neighbours=7       # 3…31, odd: how many windows that median is taken over
export-skip-duplicates=no       # yes: skip a frame too like the last one the export saved
export-duplicate-change=5       # 1…100 %: how much of the picture has to change since that frame
clip-template=%{video-name}_%{start}_%{end}   # C: clip name; %{start} = keyframe it begins on, %{end} = end of the mark (+ _joined / _cut)
clip-read-limit=40              # MB/s a clip may read, so playback keeps the network; 0 = no limit
clip-mode=separate              # separate | joined | inverted — what C makes of the marks (the last choice in its sheet)
clip-confirm=yes                # no: C saves by clip-mode without the sheet
scale=auto                      # auto | metalfx | lanczos | bilinear — how the picture is scaled to the screen
preview=yes                     # yes | no — thumbnail above the seek bar while you point at it
preview-width=240               # 80…640 points, longest side of that thumbnail
sharpen=0.3                     # 0…1, extra sharpness after upscaling on screen
sr-still=yes                    # redraw a paused frame sharper with Apple's neural network (macOS 26)
vibrance=0.5                    # 0…1, strength of the on-screen vibrance (v)
vibrance-on=no                  # yes: vibrance is on (v toggles it)
auto-color=no                   # yes: auto colour is on (c toggles it); each scene is analysed after its cut and corrected if it needs it
auto-color-strength=1           # 0…1, how much of the auto colour (c) is mixed in
auto-color-filters=curve,shadows,vibrance   # which parts of the auto colour apply (none = nothing)
auto-color-vibrance-gain=1      # 1…8: multiplies the vibrance the auto colour picks (Apple picks only ~0.06…0.15)
auto-color-interval=0           # 0…600 s: also recompute the auto colour once the frame is this far from the analysed one; 0 = off
auto-color-threshold=6          # 0…50: correct a scene only if the auto colour changes it by at least this much (mean difference, 0…255); 0 = always
auto-color-full=12              # 0…50: Δ at which a scene gets the whole auto-color-strength, ramping up from the threshold; 0 = whole strength at once
save-color=no                   # yes: s, ⌘C and the A-B export get the on-screen colour correction (vibrance and auto) too
save-scale=1                    # 1 | 2 | 4 | fit | width:N | height:N — size of frames saved with s and ⌘C
save-upscaler=ml                # ml | lanczos — how saved frames are enlarged
export-scale=1                  # same values — size of frames saved by the A-B export
ontop=no                        # yes: the player window floats above other apps' windows
stats-font-size=12              # 8…40 points, text size of the stats panel (i)
hold-speed=2                    # 0.1…16, speed while the hold key (w, or / in classic) is held
speed-step=0.25                 # 0.01…4, what [ ] add to or take from the speed
keep-speed=yes                  # yes: the speed set with [ ] stays for the next video in the window (shown when it opens; Backspace resets to 1×); no: every video starts at 1×. Reverse, the shuttle's speeds and the hold speed never carry over
scrub-audio=yes                 # yes: sound in pause — a piece per step, tape while scrubbing (⌥m toggles it)
scrub-audio-length=80           # 20…500 ms, length of the piece a single step plays
scrub-audio-pitch=tape          # tape: the scrub pitch follows the speed; natural: the sound's own pitch (⇧⌥m toggles it)
ab-loop=loop                    # loop | once | ping-pong — at B: back to A, pause, or turn around (⇧f / L cycles it)
segment-advance=repeat          # repeat | next — at the end of a locked segment: play it again, or go on to the next one
key-layout=classic              # classic (the original mpv-style keys) | left-hand
app-icon=horse                  # Dock icon while running: horse, or a picture of yours: ~/.config/framescrub/icons/<name>.png (or .icns), or a path
```

### Network files

Seeking stays quick on high-bitrate files from network volumes (SMB/NFS/AFP):

- Every file opens in the background: the window stays responsive while a share answers (or while macOS asks
  whether FrameScrub may read a network volume); "Opening <name>…" shows when it takes longer than 0.3 s.
- All decoders of a file (forward, backward, seek-bar thumbnails, audio, export) read it through one cache of
  2 MiB blocks (`read-cache`): each block crosses the network once, and sequential reading (playback, export)
  loads the next ~3 s ahead. Under memory pressure this budget is cut like the frame cache.
- The exact frame index of MP4/MOV/M4V files comes from the file header in a fraction of a second. Other
  formats (MKV, WebM, TS, …) are scanned in the background, pausing while a seek waits for its frame; a scan
  longer than a second shows "Indexing N%". Seeks to keyframes (`seek-mode=keyframe`) work meanwhile.
- **Network mode** (`network-mode`, General tab > Network volumes; `auto` applies it to files on a volume that is not local
  and to `http(s)` addresses; the stats panel's Read line says "network mode"). On a share that delivers a few MB/s every
  reader divides the same bandwidth, so playback gets what the others leave. In this mode: only the playing reader reads
  ahead, and ~40 s of video instead of 3 s (the read cache is at least 512 MiB), which rides out the seconds-long stalls
  shares have; the seek-bar preview, the black-bar sampler and the backward decoder read only the blocks they need; the preview
  waits 250 ms for the pointer to rest; black bars are looked for on 4 keyframes (not 10), 20 s after the file opened; paused,
  FrameScrub keeps 8 s of decoded frames above the playhead and 3 s below (not what the whole `cache-size` holds), so
  the file is not read for frames nobody asked for. `FRAMESCRUB_READ_TRACE=<file>` logs every read of the file by reader.
- With a key held, the picture follows the seeks with the frames that are ready on the way; the backward
  decoder starts 250 ms after a jump, once the frame you jumped to is shown.
- Frames nothing refers to are not decoded when they would be thrown away: in the run-up from a keyframe to an
  exact seek target, and when fast scrubbing has already moved past them. With B-frames this is about half the
  work, so long GOPs land sooner and a 4K H.264 file keeps up with scrubbing at ~240 frames per second.
- `hwdec=auto` (General tab > Video decoding) decodes H.264 and HEVC (MP4, MOV, MKV) through FrameScrub's own
  asynchronous VideoToolbox session, paused, scrubbing and playing alike. FFmpeg's VideoToolbox hwaccel waits for
  every frame (4K H.264 at ~150 fps on an M4 Max); keeping several frames in flight gives ~640 fps for 4K H.264 and
  ~730 for 4K HEVC, close to FFmpeg's software decoder (~820 / ~650) at ~0.4 ms of CPU per frame instead of ~13.
  Other codecs use FFmpeg's hwaccel where VideoToolbox has one, else software. If VideoToolbox cannot open a file
  or fails in the middle of it, decoding goes on in software from the same frame. `yes` is the same as `auto`;
  `no` decodes everything in software. The stats (`i`) show the decoder: `h264 (VideoToolbox)`,
  `av1 (FFmpeg VideoToolbox)` or `h264 (software)`.
- `i` adds three lines: `Seek:` (last seek and the median of the last ten), `Read:` (MB read from the file,
  share of reads served from the cache, current rate) and `Index:` (`container`, `scanning N%`, `scan` or
  `approximate`).

### Stash

With `stash-url` set (Settings → Stash), Home's sidebar gets **Stash › Library**: the
[Stash](https://github.com/stashapp/stash) WebUI in the window, made the first time you go to it (a launch with a
file never loads it) and kept, so going back finds the same page.

- On a scene's page the Stash player is replaced by the scene's cover with ▶ and the file's path; ▶ opens the file in
  FrameScrub **straight from its share**, not as a stream. Drive letters go to the PC's admin shares mounted on this Mac
  (`S:\Media\a.mp4` → `/Volumes/S$/Media/a.mp4`, the server most `?$` shares come from), `\\server.local\share\…` to that
  share (`.local` and case do not matter). A share that is not mounted is mounted as the Finder would (password from
  the keychain). Rules in `stash-path-map` (`stashPrefix=localPrefix;…`) come first.
- It starts where FrameScrub left the file, else at Stash's resume point.
- The title and the OSD name the scene (`Title — Studio · date`), and the stats panel (`i`) gets a Stash section
  with its details: performers, tags, rating, plays, watched time, resume point, markers, StashDB ids, description…
- Opened from a Stash list (a filter, a performer, a tag, a search), `<` `>`, PgUp / PgDn and autoadvance go through
  that list in its order, across its pages; "End of the Stash list" at its end. A scene opened without a list steps
  through its folder.
- ⌘W or the ‹ Stash button in the top left corner goes back to the same Stash page.
- In the Stash page the browser keys work: ⌘[ / ⌘] (and ⌘← / ⌘→ outside text fields) back and forward, ⌘R reload,
  the mouse's back and forward buttons, and a two-finger swipe. Stash's own keys are listed by `?` on its pages.
  Links to other sites open in the default browser.
- Watched time, the resume point and plays go back to Stash as Stash's own player sends them (Stash's
  `trackActivity` and `minimumPlayPercent` are followed).
- ⌘⌫ asks, then has Stash delete the scene, its file and its generated files; the next scene of the list opens.
- **Check** in Settings → Stash asks Stash for its version and shows where its first scene's file is on this Mac.
- A file on no share this Mac can reach (no mount, no rule, or the share will not mount) plays as **Stash's stream**
  (`<stash-url>/scene/<id>/stream`, read with Range requests like a file, the API key sent along). `stash-stream=never`
  fails instead as before; `always` streams every scene. The plugin bridge's `fileopened` and `info` say which with
  `source: "file" | "stream"`; for a stream `fileopened` gives the URL as `url` and `path: null`, and `info` adds
  `url`.
- A stream (Stash's or a plugin page's) opens in the background: the previous file stops at once, "Opening the
  stream…" shows until it plays, and the window stays responsive. Another open or ⌘W abandons it. Its bytes are used
  as they arrive, so it plays once the start of the file is in, not after a whole 2 MiB block.
- `framescrub://open?scene=<id>&t=&seg=` opens a scene by its Stash id: the file paths are asked of Stash, then found
  on the shares (or streamed) as for ▶. A plugin page's `open({scene})` without `paths` does the same.

### Sharp frames

"Only sharp frames" in the `S` sheet keeps, of every N frames (or 1/F s, or each frame with "All frames"), the
one with the most fine detail, and skips it when it is still blurrier than `export-sharp-threshold` % of the
median of the `export-sharp-neighbours` windows around it — a shaken or out-of-focus stretch leaves no file,
a dark scene is only compared with its neighbours. One pass over the range, as without it. `i` shows
"Sharpness: N" of the shown frame to help choose the threshold.

### Colour memory

Auto colour and vibrance are remembered where they were changed, as in Loupe: `c`, `v` and the strength step
(MX panel + wheel) set them for the open file only; the next video of the folder keeps its own. Each of
`auto-color`, `auto-color-strength`, `vibrance-on` and `vibrance` is taken from the first of: the file, its folder,
the nearest folder above it that has the key (on a share, not above `/Volumes/<share>`), `framescrub.conf`, the
built-in default. ⌥C / ⌥V save what is on screen for the folder (its subfolders inherit it), ⇧C / ⇧V make it the
default in `framescrub.conf`; values below that would now be the same are dropped, so the picture never changes on a
save. Playback > Colour has the same and Reset File Colour / Reset Folder Colour (enabled when there is something to
reset). Settings > Colour edits the defaults; a row whose key the open video or its folder sets shows that level
(«This file», «This folder», «Folder <name>») with «Use Default», which drops it there. A file's values are kept in its entry in
`~/Library/Application Support/FrameScrub/positions.json` (also with `resume-playback=no`), the folders' in
`~/Library/Application Support/FrameScrub/folder-colors.json` (up to 1000 folders, the least recently changed
dropped first); nothing is written next to the videos. Renaming or moving a file or folder loses its colour. Saved
and copied frames (`save-color=yes`) get the file's colour.

### Image quality

- On a large monitor the frame is enlarged with MetalFX (Lanczos when MetalFX is unavailable, bilinear with
  `scale=bilinear`) and reduced with Lanczos (bilinear with `scale=bilinear`). `i` shows "Scaling: …" (the scaler in use) and "Skipped frames: N".
- HDR video is tone-mapped to the display: on a screen without HDR headroom it is shown as SDR.
- `sr-still=yes`: after a frame has been paused for 0.3 s and is shown at more than 1.2x, the picture is redrawn
  with Apple's neural upscaler ("SR" in the OSD). SDR frames only; sources larger than 1920 px on the larger side
  are not redrawn. The first time, FrameScrub asks to download the model: Download / Not now / Never
  ("Never" writes `sr-still=no`).
- Colour correction (`v`, `c`) is applied on screen only, after HDR tone mapping and before scaling (so the
  neural-network still gets it too); on a 4K frame it costs about 0.3 ms of GPU time per frame, and `c` analyses
  the frame once in ~0.1 s. Saved and copied frames keep the original colour unless `save-color=yes` (Display tab >
  Colour). The automatic adjustments do not include face balance or red-eye, which would carry one frame's skin
  tone onto every other. Of what `c` finds, `auto-color-filters` keeps the tone curve (`curve`, contrast),
  shadows and highlights (`shadows`) and/or its own vibrance (`vibrance`); `auto-color-strength` mixes the result
  with the original (0.5 = half the correction). Apple's analysis picks a weak vibrance (about 0.06…0.15 on
  typical 4K footage, against 0.5 for `v`); `auto-color-vibrance-gain` multiplies it (capped at 1), keeping it
  relative to how dull each scene is. Both apply at once to the correction already computed. `i` shows
  `Colour: …` (vibrance, auto strength, the frame it was computed from and its parts, and whether files get it;
  ` · file` / ` · folder` at the end when the file or a folder sets them).
  With `auto-color-interval=N` the auto colour (once on with `c`) is computed again in the background whenever the
  frame on screen is N seconds of video or more from the analysed one — every N s while playing, and at once after
  a jump to another scene — and the new correction fades in over 0.5 s. `auto-color-interval` does not recompute a paused frame. Saved
  frames get the correction in effect when they are saved; an A-B export keeps the one it started with.
  `c` is remembered for the file ([Colour memory](#colour-memory)). While it is on, every scene is checked by itself: shown
  frames (up to 30 a second) are compared with the previous one at 64×36 pixels, and a scene cut, a jump or the first
  frame of a file has the frame on screen 0.25 s after the last cut analysed in the background (so a dissolve is over,
  and fast scrubbing waits until it slows down). The correction is applied only if, in full, it changes that frame by
  at least `auto-color-threshold` (mean difference over R, G, B, 0…255; default 6, 0 = every scene); otherwise the
  scene fades back to its own colours. Above the threshold the strength ramps up with Δ: a scene at the threshold
  gets almost none, one at `auto-color-full` (default 12) or more gets the whole `auto-color-strength` (Δ 9 with the
  defaults: half), so scenes that barely need it are barely touched and nothing jumps at the threshold;
  `auto-color-full=0` gives the whole strength at once. Clean, contrasty footage usually measures 2…5, flat or washed-out scenes 7…15.
  The decision does not depend on `auto-color-strength`, `-filters` or `-vibrance-gain`, and a new threshold applies
  at once. Nearly black frames (a fade-in, a title on black) are skipped and keep the previous state; the frame on
  screen is tried again every second of video until it has a picture. `i` shows `Δ` and, when the scene is left
  alone, `needs none`. `c` itself analyses the frame on screen, whatever it is, and applies the same threshold.
- `save-scale` / `export-scale` set the size of saved frames (`s`, A-B export): a factor `1`, `2`, `4`
  (`name_x2.jpg`), `fit` (into the pixel size of the screen the window is on) or `width:N` / `height:N`
  (one side in pixels, `16…16384`). The aspect ratio is kept and the long side never exceeds 16384 px. Files that
  are not factors get the size in the name (`name_3840x2160.jpg`). Frames larger than the target are reduced with
  Lanczos; enlarged ones use `save-upscaler`: `ml` works on macOS 26 only, for SDR output (JPEG, or an SDR
  source) from a source up to 1920 px on the larger side and for growth of at least 1.5×, and needs the Apple
  model (downloaded once, e.g. via the SR prompt): it enlarges ×4 and Lanczos brings that to the exact size.
  Otherwise Lanczos is used and the OSD appends " · Upscaled with Lanczos (reason)". HEIC/PNG/TIFF keep HDR; HDR
  files are enlarged with Lanczos.
- Under system memory pressure the frame cache budget is cut (and restored afterwards) and the cached
  super-resolution stills are released.
- The neural network keeps one ~2.8 GB session open while frames are being enlarged and closes it after 5 s
  without work, so an A-B export with `save-upscaler=ml` uses that much once, not once per thread.

Frames go to a folder named after the video, next to it. If that folder cannot be written,
they go to `~/Pictures/FrameScrub/<video name>/`.
