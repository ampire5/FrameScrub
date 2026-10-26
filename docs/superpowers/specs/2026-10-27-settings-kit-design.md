# Settings: SettingsKit's window in FrameScrub

Date: 2026-10-27. Status: design, not implemented.

## Problem

FrameScrub's settings window (⌘,) is its own: `PreferencesWindowController` with six tabs (General, Scrolling,
Saving, Display, Mouse & Trackpad, Stash), each a SwiftUI `Form` in its own hosting view, built ahead 1.5 s after
launch. It shows about 75 of the ~100 keys of `framescrub.conf`, has no search, no descriptions, no reset, and no
way to edit key or mouse button bindings: input.conf is edited by hand, except for the gesture table. A colour value
that the open video's file or folder overrides is shown as the default, silently.

Loupe moved to SettingsKit (IINA-style sidebar, search, cards, descriptions, reset, a key-binding editor, per-folder
notes). FrameScrub depends on SettingsKit (≥ 0.5.0) already but only for `IconPickerWindowController`.

## Goals

1. ⌘, opens a `SettingsWindowController` with FrameScrub's pages; the old window and its model are removed.
2. Every key the old window has, with a description (range, default) as in Loupe, plus the keys of
   `framescrub.conf` the old window lacks (the haptic patterns, `haptic-strong-strength`, `mouse-long-press`,
   `segment-advance`, `ontop`, `stash-stream`, `app-icon`, `plugin-open-allowed`, the export sheet's defaults).
3. A Key Bindings page: keyboard and mouse button bindings of input.conf and the profile files, editable.
4. The four colour keys show the level that draws for the open video (file, folder, ancestor folder) with
   «Use Default» to drop it.
5. Within the budgets of `CLAUDE.md`, measured on the real window.

Not in scope: `home-tab` (Home's state, not a setting) and `slot-left`, `slot-right`, `slot-bottom` (a composite
value View › Slots sets). The coverage test lists them as excluded.

## Architecture

### Who writes the files

`PreferencesStore` stays the only writer of `framescrub.conf` (in place, only the changed keys, defaults not
added). The kit's store is a view of it:

`FrameScrubSettingsStore: SettingsStore` (main actor):

- `value(forKey:)` → `preferences.config.text(forKey:)`; `defaultValue(forKey:)` → `Config().text(forKey:)`.
- `validate(_:forKey:)` → a line break is refused; otherwise `Config.set(key, value)` on a copy must accept it.
- `setValue(_:forKey:)` → `preferences.update([key]) { $0.set(key, value) }`; a write error is thrown after the
  value is applied (the row shows the kit's error; the app keeps the value until quit, as now).
- `removeValues(forKeys:)` → one `update` setting each key to its default (the file keeps lines that already exist,
  as `persist` does now).
- An observer on `PreferencesStore` compares `text(forKey:)` of the old and new config over `Config.keys` and posts
  `.settingsStoreDidChange` with only the changed keys. Menus, the export sheet, the icon picker, SR's «Never» and
  `reload()` (an edit in a text editor) reach the window the same way as its own writes.
- `wheel-free-spin`: a pseudo key over `UserDefaults` (`PlayerWindowController.wheelFreeSpinKey`), never written to
  the conf; announced when the player changes it.

Rejected alternatives: writing the file from the kit's store and calling `preferences.reload()` (Loupe's way) makes
two writers of one file and re-reads and parses it on every slider tick; replacing `PreferencesStore` everywhere
churns the player and the sheets for the same result.

### input.conf

`GesturePreferences` becomes `InputPreferences`: the one owner of the live `InputMap` (layout → input.conf →
profile lines → `input-<profile>.conf`) and of the writes to input.conf and `input-<profile>.conf`; its observers
give the player the new map at once, as now. Its `edit` takes the file to write. The gesture table and the Key
Bindings tables write only through it.

`InputMap.apply` records the layer of each chord (today it records only `secondary`): built-in, left-hand,
the profile, input.conf, `input-<profile>.conf`.

### Target

A new library target `FrameScrubSettings` (FrameScrubCore + SettingsKit + StashKit): the store, the pages,
`InputBindingSource`, the gesture table adapter, `OutputSizeField` (the export sheet keeps using it). The app target
imports it; tests and the bench use it without the app.

`SettingsPanel` (an enum, as Loupe's): makes the `SettingsWindowController` (`.glass`, autosave name
`FrameScrubSettings`, last page in `settingsLastPage`) on the first ⌘,, never at launch; `tabbingMode = .disallowed`;
`endEditing()` on `willTerminate`. The 1.5 s prebuild goes: the kit builds a page in pieces and keeps it. The first
⌘, is measured (budget ~300 ms).

`SettingsPanelContext` from the app: `InputPreferences`, the colour layers of the open video and a way to clear one
(see Colour levels), the icon choices and folder (`AppIconSwitcher.choices`, `AppIcon.userDirectory`), the build
line, `translateKey`, the menus' shortcuts, the plugin's actions.

Removed: `PreferencesWindowController`, `PreferencesTabsController`, `PreferencesView`, `PreferencesModel`,
`PreferencesTabFeed`, `StashPreferencesView` (with `CommitField`), `GestureModel`, `DraftField`, `StepperRow`,
`SliderRow`.

## Pages

Sidebar order. Rows nest under the switch they depend on instead of `.disabled` (no modifier on inactive subtrees).

| Page (symbol) | Sections and keys |
|---|---|
| General (`gearshape`) | Playback: volume, autoplay, resume-playback, playlist-autoadvance, playlist-sort, activate-on-open, ab-loop, segment-advance · App: key-layout, single-instance, ontop, app-icon (`.icon` over `IconChoice`, `current:` for the row's one picture) · Build: `.custom` (the build line, selectable, and Copy) |
| Speed & Seeking (`gauge.with.dots.needle.67percent`) | Speed: hold-speed, speed-step, keep-speed · Seeking: seek-mode · Scenes: scene-threshold, scene-lookahead, scene-check-time, scene-search-time · Scrub audio: scrub-audio › scrub-audio-pitch, scrub-audio-length |
| Home & Interface (`house`) | Home: home-card-size, home-sidebar, recent-count · Text: playlist-font-size, stats-font-size · Slots: slot-reveal-distance |
| Scrolling (`scroll`) | Scrubbing: scrub-accel › scrub-accel-from, scrub-accel-max; scrub-px-per-frame, scrub-fast-multiplier, scrub-invert · Logitech wheel: wheel-precision › wheel-free-spin, wheel-precision-mode, wheel-precision-frames, wheel-precision-time |
| Mouse & Trackpad (`computermouse`) | Buttons: mouse-profile, mouse-long-press · Haptics: mouse-haptics › haptic-step, -detent, -limit, -long-armed, -toggle, -end, -keyframe, -mark, -done, -error, haptic-strength (a number or keep), haptic-strong-strength · MX Master: mx-panel-force (keep, default or a number), mx-side-buttons · Gestures: `.custom` (the gesture table) |
| Key Bindings (`keyboard`) | Keyboard, Mouse: a `KeyBindingTable` each |
| Saving (`square.and.arrow.down`) | Frames: frame-format, jpeg-quality, heic-quality, frame-dir, frame-template, save-scale, save-upscaler, save-color · Clips: clip-template, clip-mode, clip-confirm, clip-read-limit · Range export: export-scale, export-threads, export-mode, export-every, export-fps, export-sharp, export-skip-blurry, export-sharp-threshold, export-sharp-neighbours, export-skip-duplicates, export-duplicate-change |
| Display (`display`) | Picture: scale, sharpen, sr-still · Seek bar preview: preview › preview-width |
| Colour (`paintpalette`) | Vibrance: vibrance-on › vibrance · Auto colour: auto-color › auto-color-strength, auto-color-threshold, auto-color-full, auto-color-interval, auto-color-filters (`.flags`), auto-color-vibrance-gain |
| Performance (`speedometer`) | cache-size, read-cache, hwdec, network-mode |
| Stash (`books.vertical`) | stash-url, stash-api-key, stash-path-map, stash-stream, Check (`.button`: Stash's version and its first scene's path on this Mac, as now) |
| Advanced (`wrench.and.screwdriver`) | plugin-open-allowed · Show framescrub.conf / input.conf in Finder |

Rows:

- `save-scale`, `export-scale`: `.custom` with `OutputSizeField` (1×, 2×, 4×, Fit, a width or a height).
- `scrub-audio-pitch` is a `.choice` (natural, tape), no longer a switch.
- `stash-api-key`: a text row (the kit has no secure field; Loupe's is the same).
- `stash-path-map`: the conf's `;`-separated text; the description gives the form. The old multi-line editor goes.

If a row needs something the kit lacks, it goes into SettingsKit 0.7.0 with the changes below.

## Key Bindings

`InputBindingSource: KeyBindingSource` over `InputPreferences`:

- **Rows**: the effective map without `ignore` and without the wheel, trackpad and pinch axes (the gesture table's).
  Source: `built-in` / `left-hand`, `viewing profile` / `editing profile`, `input.conf`, `input-viewing.conf` /
  `input-editing.conf`, `off`. The menus' shortcuts follow the keys read-only, as in Loupe.
- **Where an edit goes**: to the layer that would otherwise hide it. A chord the active profile sets (its lines or
  `input-<profile>.conf`) is written to `input-<profile>.conf`; any other to input.conf. Above the mouse table:
  «Profile: Viewing. Buttons the profile sets are written to input-viewing.conf.»
- **«−»**: a built-in or profile binding gets an `ignore` line in that file; a line of a file is commented out.
  **Restore Built-in** comments out the line in the file it came from.
- **Actions**: grouped by `KeyHelp.Section` (Playback, Frames, Seeking, Saving, Picture, Window, Sound, Plugin),
  titled by `KeyHelp.describe`, as the `?` cheat sheet. `seek N`, `add volume N`, `multiply speed N`,
  `set speed N`, `set window-scale N`, `zoom N`, `add auto-color-strength N` take a step; `seek … exact`,
  `seek … keyframes`, `scrub fast`, `scrub invert` are items of their own.
- **Buttons and press kinds**: `MouseButton.allCases`; tap, `_LONG`, `_DBL`, `+ wheel`, with the right button;
  disabled where `KeyChord.parse` does not take the combination.
- **Key recorder**: `KeyChord.fromKeyEvent` with the app's `translateKey` (a letter records by its Latin letter on
  any layout). A chord in `KeyChord.menuOwned` is refused: «Belongs to a menu item».
- **Outside edits**: on `didBecomeActive` both files are read again and announced when they changed; a change of
  profile or layout comes through `InputPreferences`' observer.

The gesture table stays its own view (axes, invert and a parameter do not fit `KeyBindingTable`) in a `.custom` row,
restyled for the kit's cards (no background of its own, the glass style's colours); a thin adapter over
`InputPreferences` replaces `GestureModel`; its `searchTexts` are the devices' and actions' titles.

## Colour levels

For `auto-color`, `auto-color-strength`, `vibrance-on`, `vibrance` the store asks the context for
`colorLayers() -> (file: [String: String]?, chain: [(url: URL, values: [String: String])])?` (nil: no open video)
and shows the nearest level that draws, as `ColorLayers.effective` lays them (a value `Config` refuses does not
draw, so the next level shows through):

- the file's own value: «This file: …» (`doc`);
- `chain[0]`: «This folder: …» (`folder`);
- an ancestor: «Folder <name>: …» (`folder`).

«Use Default» drops the key on that level: the file's through a new `ColorMemory.clear(_ key:)`, a folder's through
`FolderColors.clear([key], for: url)`; the player redraws through its existing colour path. A level below may then
show.

`SettingsPanel.refreshFolderOverrides()` runs when a video opens or closes and after c, v, ⇧C, ⌥C and the colour
resets; nothing while the window was never shown.

## SettingsKit 0.7.0

On SettingsKit's branch `settings` (docs/kits.md), both additive, Loupe unchanged:

1. `SettingsStore.override(forKey:) -> SettingsOverride?`; `SettingsOverride` holds `value`, `label`, `symbol`,
   `help`. The default wraps `folderOverride(forKey:)` as «This folder». `FolderNote` shows `label: value` and
   «Use Default», which still calls `clearFolderOverride(forKey:)` (it drops the level shown).
2. `KeyBindingSource.stepRange(for actionID:) -> ClosedRange<Double>`, default 0.01…1 (today's fixed range). The
   step field's placeholder comes from the range.

## Speed

Budgets (`CLAUDE.md`): opening the window ≤ 300 ms, a page's first visit ≤ 100 ms, a return ≈ 0, a change of one
setting ≤ 50 ms, all main-thread CPU.

A new executable `FrameScrubBench` with a `settings` mode after Loupe's `SettingsBench`: the real window and pages,
`CLOCK_THREAD_CPUTIME_ID` per action, the open, first visits and returns apart, 5 rounds in a row (rounds that grow
are a bug), the longest run loop turn. Run on the M4 Max at load < 5 and on the Intel runner (docs/intel-runner.md).
`docs/bench/2026-10-xx-settings.md` gets the numbers with the old window's for comparison.

## Tests

- **Store**: every `Config.keys` key not excluded round-trips through `value`, `validate`, `setValue`; only changed
  keys are announced, also after `reload()` and a menu's change; a write error is thrown with the value applied;
  `wheel-free-spin` goes to `UserDefaults`, not the conf; `removeValues` writes once.
- **Coverage**: every page key is in `Config.keys` (or is `wheel-free-spin`), and every `Config.keys` key is on a page
  or in the excluded list.
- **InputBindingSource**: the layer of each row; a profile chord's edit goes to `input-<profile>.conf`, others to
  input.conf; «−» and Restore for a built-in, a profile and a file row; `menuOwned` refused; `stepRange`.
- **Colour levels**: file over folder over ancestor; a refused value skipped; Use Default drops one level.
- **Kit**: `override` by default and from a store; `stepRange` by default and the app's.

## Release

1. SettingsKit, branch `settings`: the two API additions, tests, README; PR; tag **0.7.0**.
2. FrameScrub, branch `settings` (worktree `../FrameScrub-settings`): built against the kit in edit mode while the
   kit's branch is open; then `SettingsKit from: "0.7.0"` and Package.resolved; README (Settings section,
   screenshot), the bench document; `scripts/kits-check.py` says `kits: ok`; PR.
3. Loupe is not touched.
