# Settings on SettingsKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FrameScrub's ⌘, window becomes SettingsKit's, with pages for every conf key, a Key Bindings page and the
colour level that draws for the open video.

**Architecture:** A new library target `FrameScrubSettings` holds a `SettingsStore` over the existing
`PreferencesStore`, the pages, a `KeyBindingSource` over `InputPreferences` (today's `GesturePreferences`, extended to
the profile file) and the gesture table. SettingsKit gets two additive APIs on its branch `settings` (released as
0.7.0 at the end); FrameScrub builds against it in edit mode until then.

**Tech Stack:** Swift 6.2 toolchain (Swift 5 language mode), SwiftUI + AppKit, swift-testing, SettingsKit.

**Spec:** `docs/superpowers/specs/2026-10-27-settings-kit-design.md`

## Global Constraints

- macOS 26+, swift-tools 6.2, `swiftLanguageModes: [.v5]` (FrameScrub), the kit's own settings unchanged.
- Main-thread budgets: open ≤ 300 ms, a page's first visit ≤ 100 ms, a return ≈ 0, one setting ≤ 50 ms.
- `PreferencesStore` is the only writer of `framescrub.conf`; `InputPreferences` the only writer of input.conf and
  `input-<profile>.conf`.
- Excluded from the pages: `home-tab`, `slot-left`, `slot-right`, `slot-bottom`. Pseudo key: `wheel-free-spin`
  (`UserDefaults` key `wheelFreeSpin`).
- Kit changes are additive: Loupe builds and its tests pass unchanged against the kit branch.
- Kit work on SettingsKit branch `settings`; FrameScrub work on branch `settings` in `../FrameScrub-settings`;
  Package.resolved never committed from edit mode (docs/kits.md).
- Code style: match the surrounding files (doc comments on types and non-obvious members, English, the kit's and
  FrameScrub's wording: «Use Default», `framescrub.conf`).

## Review Focus

- A setting changed from a menu or the export sheet while the window is open must show at once in the window (the
  store's announcement path) — test in Task 4.
- An outside edit of framescrub.conf with a bad value must not crash the window or loop announcements — test in
  Task 4 (`reload` with a warning line announces only the keys that changed).
- Switching the mouse profile while the Key Bindings page is open must move rows to the new profile's sources —
  test in Task 6.
- Closing the video while the Colour page shows «This file: …» must clear the note, and «Use Default» with no video
  must do nothing — test in Task 7.
- A binding edit while input.conf is read-only must leave the map unchanged in the table and report the error —
  test in Task 6.

---

## SettingsKit (branch `settings`)

### Task 1: SettingsOverride — the store names the level

**Files:**
- Modify: `Sources/SettingsKit/SettingsStore.swift`, `Sources/SettingsKit/SettingsModel.swift:60-85, 290-300`,
  `Sources/SettingsKit/RowViews.swift:25-30, 478-500`
- Test: `Tests/SettingsKitTests/FolderNoteTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SettingsOverride: Equatable, Sendable {
      public let value: String; public let label: String; public let symbol: String; public let help: String
      public init(value: String, label: String = "This folder", symbol: String = "folder",
                  help: String = "The folder of the file on screen has its own value; the setting above applies elsewhere")
  }
  // SettingsStore
  func override(forKey key: String) -> SettingsOverride?   // default: folderOverride(forKey:).map { SettingsOverride(value: $0) }
  // SettingsModel
  public func override(_ key: String) -> SettingsOverride?
  public func folderOverride(_ key: String) -> String?     // kept: override(key)?.value
  ```

- [ ] **Step 1: Write failing tests** `aStoreWithOnlyFolderOverrideGetsThisFolder` (MemoryStore with a folder value
  → `model.override("k") == SettingsOverride(value: "v")`, label "This folder") and
  `aStoreLabelIsShown` (a store returning `SettingsOverride(value: "on", label: "This file", symbol: "doc", help: "h")`
  → `model.override("k")?.label == "This file"`; `FolderNote` built from it has the text "This file: On" for a toggle
  row — test through `FolderNote.title(_:row:)` returning `"This file: On"`).
- [ ] **Step 2:** `swift test --filter FolderNoteTests` → FAIL (no `override`).
- [ ] **Step 3: Implement.** The slot stores `SettingsOverride?`; `refreshFolderOverrides` asks `store.override`;
  `FolderNote` takes the override, shows `Label(title, systemImage: override.symbol)` with `.help(override.help)`;
  `static func title(_ o: SettingsOverride, row: SettingsRow) -> String` = `"\(o.label): \(text(o.value, row: row))"`.
- [ ] **Step 4:** `swift test` → all pass (Loupe is checked against the branch in Task 3).
- [ ] **Step 5: Commit** `Folder notes: the store names the level (SettingsOverride: label, symbol, help); folderOverride stays its default`.

### Task 2: KeyBindingStep — the source sets the step's range

**Files:**
- Modify: `Sources/SettingsKit/KeyBindingTable.swift:51-70`, `Sources/SettingsKit/KeyBindingSheet.swift:15-70, 155-175`
- Test: `Tests/SettingsKitTests/KeyBindingTableTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct KeyBindingStep: Equatable, Sendable {
      public let range: ClosedRange<Double>   // of the size
      public let defaultValue: Double
      public let signed: Bool                 // a negative step is allowed
      public static let standard = KeyBindingStep(range: 0.01...1, defaultValue: 0.05, signed: true)
      public init(range: ClosedRange<Double>, defaultValue: Double, signed: Bool)
      public var hint: String                 // "0.01–1; negative lowers", "1–600"
  }
  // KeyBindingSource
  func stepRule(for actionID: String) -> KeyBindingStep   // default .standard
  // KeyBindingDraft
  @MainActor public mutating func choose(actionID: String?, in source: KeyBindingSource)
  ```

- [ ] **Step 1: Failing tests** `aSourceRangeAcceptsLargeSteps` (rule 1…600 unsigned: stepText "120" → step 120;
  "-5" → nil; "0.5" → nil), `theStandardRuleIsUnchanged` ("0.05" → 0.05, "-0.1" → -0.1, "2" → nil),
  `choosingAnActionPutsItsDefaultWhenTheFieldDoesNotFit` (stepText "0.05", choose an action with rule 1…600 default
  5 → stepText "5"; a fitting value is kept), `hints` (`.standard.hint == "0.01–1; negative lowers"`,
  `KeyBindingStep(range: 1...600, defaultValue: 5, signed: false).hint == "1–600"`).
- [ ] **Step 2:** `swift test --filter KeyBindingTableTests` → FAIL.
- [ ] **Step 3: Implement.** `step(in:)` uses `source.stepRule(for: actionID)`; the sheet's action picker sets the
  action through `choose`; the step field's placeholder is `KeyBindingDraft.text(rule.defaultValue)` and its caption
  `rule.hint`. Numbers in the hint print as `KeyBindingDraft.text`.
- [ ] **Step 4:** `swift test` → all pass.
- [ ] **Step 5: Commit** `Key bindings: the source sets each action's step range and default (KeyBindingStep); 0.01–1 stays the default`.

### Task 3: Kit README and Loupe check

**Files:** Modify `README.md` (Per-folder overrides: `override(forKey:)`; Key-binding editor: `stepRule(for:)`).

- [ ] **Step 1:** Update the two bullets; mention FrameScrub as a user next to Loupe.
- [ ] **Step 2:** In `../Loupe`: `swift package edit SettingsKit --path ../SettingsKit`, `swift build` and
  `swift test --filter LoupeSettingsTests` → pass; `swift package unedit SettingsKit`; `git checkout Package.resolved`;
  Loupe's tree clean (`git status`).
- [ ] **Step 3: Commit** `README: SettingsOverride and KeyBindingStep`; push the branch `settings` (no PR merge or tag yet: Task 13).

---

## FrameScrub (branch `settings`, `../FrameScrub-settings`)

### Task 4: FrameScrubSettings target and the store

**Files:**
- Modify: `Package.swift` (target `FrameScrubSettings`: FrameScrubCore, SettingsKit, StashKit; the app depends on
  it; test target `FrameScrubSettingsTests`), `Sources/FrameScrubCore/Config.swift:421` (`set` → `public mutating func
  set(_ key: String, _ value: String) -> Bool`)
- Create: `Sources/FrameScrubSettings/FrameScrubSettingsStore.swift`
- Test: `Tests/FrameScrubSettingsTests/StoreTests.swift`
- Setup: copy `../FrameScrub/.swiftpm/configuration/mirrors.json` into the worktree; `swift package edit SettingsKit --path ../SettingsKit`.

**Interfaces:**
- Consumes: `PreferencesStore(config:url:)`, `update(_:_:)`, `addObserver`, `reload()`; `Config.keys`, `text(forKey:)`.
- Produces:
  ```swift
  @MainActor public final class FrameScrubSettingsStore: SettingsStore {
      public static let excludedKeys: Set<String>        // home-tab, slot-left, slot-right, slot-bottom
      public static let wheelFreeSpinKey = "wheel-free-spin"
      public init(preferences: PreferencesStore, defaults: UserDefaults = .standard,
                  colorLayers: @escaping () -> ColorLayerSnapshot? = { nil },
                  clearColor: @escaping (String, ColorLayerHit.Level) -> Void = { _, _ in })
      public static func changedKeys(from old: Config, to new: Config) -> [String]
      public func wheelFreeSpinDidChange()                // the player calls it; announces wheel-free-spin
  }
  ```
  (`ColorLayerSnapshot`, `ColorLayerHit` come from Task 7; until then the init takes no colour arguments — Task 7
  adds them.)

- [ ] **Step 1: Failing tests:** `everyKeyRoundTrips` (for each `Config.keys` key not excluded: `setValue(value(k)!)`
  of the default is a no-op; a changed sample value per type — booleans flip, numbers inside their range — reads back),
  `validateRefusesWhatConfigRefuses` (`validate("abc", "volume") != nil`, `validate("50", "volume") == nil`,
  `validate("a\nb", "frame-template") != nil`), `onlyChangedKeysAreAnnounced` (`preferences.update(["volume"])` →
  one notification with `["volume"]`), `reloadAnnouncesTheFileEdit` (write `volume=30\nbogus=1` to the temp conf,
  `reload()` → `["volume"]` only), `aFailedWriteThrowsWithTheValueApplied` (read-only temp file → `setValue` throws,
  `value(forKey:)` is the new value), `wheelFreeSpinLivesInDefaults` (suite defaults; set `no` → `defaults.bool` false,
  conf file not created), `removeValuesWritesOnce` (two keys changed → one notification listing both after removal).
- [ ] **Step 2:** `swift test --filter FrameScrubSettingsTests` → FAIL (no target / type).
- [ ] **Step 3: Implement** per spec «Who writes the files»; the observer keeps the last config to diff;
  `removeValues` is one `preferences.update(keys)` setting each default.
- [ ] **Step 4:** `swift test --filter FrameScrubSettingsTests` → pass; `swift build` → ok.
- [ ] **Step 5: Commit** `Settings: FrameScrubSettings target; FrameScrubSettingsStore over PreferencesStore (announces only the changed keys, wheel-free-spin in UserDefaults)` (Package.resolved not staged).

### Task 5: InputMap layers and InputPreferences

**Files:**
- Modify: `Sources/FrameScrubCore/InputMap.swift:615-660`, `Sources/FrameScrubCore/MouseProfile.swift:86-105`
- Rename: `Sources/FrameScrubCore/GesturePreferences.swift` → `InputPreferences.swift` (class `InputPreferences`; all
  uses in the app)
- Test: `Tests/FrameScrubCoreTests/InputMapTests.swift`, `Tests/FrameScrubCoreTests/MouseProfileTests.swift`,
  `Tests/FrameScrubCoreTests/InputPreferencesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum InputLayer: Equatable, Sendable { case builtIn, leftHand, profile(MouseProfile), file, profileFile(MouseProfile) }
  extension InputMap {
      public func layer(of chord: KeyChord) -> InputLayer?
      public var allBindings: [(chord: KeyChord, command: Command)]   // ignore included, sorted by description
  }
  public enum InputFile: Sendable { case main, profile }               // input.conf, input-<profile>.conf
  public final class InputPreferences {                                // GesturePreferences' API kept
      public var url: URL; public func url(of file: InputFile) -> URL
      public func edit(_ file: InputFile, _ transform: (String) -> String) throws
      public func reloadFiles() -> Bool                                // re-reads both; true when the map changed
  }
  ```
  `InputMap.apply(_:source:secondary:)` gets `layer: InputLayer` (default `.file`); `init(layout:)` passes
  `.builtIn` / `.leftHand`; `build` and `load` pass `.profile(p)` and `.profileFile(p)`.

- [ ] **Step 1: Failing tests:** `layersFollowTheirSource` (classic: `layer(of: SPACE) == .builtIn`; userText
  `SPACE ignore` → `.file`; viewing profile: `layer(of: MBTN_BACK) == .profile(.viewing)`; profileText
  `MBTN_BACK cycle pause` → `.profileFile(.viewing)`; left-hand layout: a left-hand key `.leftHand`),
  `editWritesTheProfileFile` (temp dir; `edit(.profile) { $0 + "MBTN_BACK cycle pause\n" }` → input-viewing.conf has
  the line, `inputMap.command(for: MBTN_BACK) == .cyclePause`, observers called once), `reloadFilesSeesAnOutsideEdit`.
- [ ] **Step 2:** `swift test --filter "InputMapTests|MouseProfileTests|InputPreferencesTests"` → FAIL.
- [ ] **Step 3: Implement**; `GestureBindingsTests` and the app compile with the new name.
- [ ] **Step 4:** same filter plus `GestureBindingsTests` → pass; `swift build` → ok.
- [ ] **Step 5: Commit** `Input: InputMap records each chord's layer; GesturePreferences becomes InputPreferences and writes input.conf or the profile's file`.

### Task 6: InputBindingSource

**Files:**
- Create: `Sources/FrameScrubSettings/InputBindingSource.swift`
- Test: `Tests/FrameScrubSettingsTests/InputBindingSourceTests.swift`

**Interfaces:**
- Consumes: Task 5; `KeyHelp.describe` (make it `public`), `KeyChord.menuOwned`, `MouseButton`, kit `KeyBindingSource`, `KeyBindingStep` (Task 2).
- Produces:
  ```swift
  @MainActor public final class InputBindingSource: KeyBindingSource {
      public init(preferences: InputPreferences, translateKey: @escaping (UInt16, Bool) -> String?,
                  menuRows: @escaping @MainActor () -> [(input: String, title: String)] = { [] })
      public static let menuNote: String
      public var profileNote: String                    // "Profile: Viewing. Buttons the profile sets are written to input-viewing.conf."
      func searchTexts(mouse: Bool) -> [String]
      static func file(for layer: InputLayer?) -> InputFile   // .profile / .profileFile → .profile, else .main
  }
  ```
  Step rules: `seek` 0.01…3600 default 5 signed; `seek exact` / `seek keyframes` same; `add volume` 0.1…100 default 2
  signed; `multiply speed` 1.001…4 default 1.1 unsigned; `set speed` 0.05…16 default 1 unsigned; `set window-scale`
  0.1…8 default 1 unsigned; `zoom` 0.01…4 default 0.25 signed; `add auto-color-strength` standard.
  Sources: `built-in`, `left-hand`, `viewing profile`, `editing profile`, `input.conf`, `input-viewing.conf`,
  `input-editing.conf`, `off`. Gesture chords (`GestureDevice` sides with any modifiers) are not rows.

- [ ] **Step 1: Failing tests:** `rowsCarryTheirSource`, `gestureAxesAreNotRows` (no row id starting `WHEEL_`,
  `TRACKPAD_`, `PINCH_` without a held-button modifier), `aProfileChordIsWrittenToTheProfileFile` (viewing:
  bind `MBTN_BACK` to `cycle pause` → input-viewing.conf has it, input.conf untouched), `aKeyIsWrittenToInputConf`,
  `removeABuiltInWritesIgnore`, `removeAFileLineCommentsItOut`, `restoreBuiltInCommentsOutTheLine`,
  `menuChordsAreRefused` (`keyToken` for ⌘, → `.failure("Belongs to a menu item")`), `stepRules` (seek → 0.01…3600),
  `aProfileSwitchMovesTheSources` (set `preferences.profile = .editing` → `MBTN_BACK` source `built-in`, one
  `.settingsStoreDidChange` posted), `aReadOnlyFileThrowsAndKeepsTheMap` (chmod 444 input.conf → `bind` throws,
  `rows()` unchanged).
- [ ] **Step 2:** `swift test --filter InputBindingSourceTests` → FAIL.
- [ ] **Step 3: Implement** after Loupe's `InputBindingSource` (rows, sheet, writes, `didBecomeActive`), with
  `ConfigText.settingBindings` / `removingBindings` for the line edits and `InputPreferences.edit(file)` for every
  write; an `ignore` line from «−» goes through `settingBindings`; comment-out uses a new
  `ConfigText.commentingOutBindings(for: Set<KeyChord>, in:)` (test it in `ConfigTextTests`).
- [ ] **Step 4:** filter → pass.
- [ ] **Step 5: Commit** `Settings: InputBindingSource — keys and mouse buttons of input.conf and the profile's file, written where they take effect`.

### Task 7: Colour levels

**Files:**
- Modify: `Sources/FrameScrubCore/ColorLayers.swift`, `Sources/FrameScrubCore/ColorMemory.swift`,
  `Sources/FrameScrubSettings/FrameScrubSettingsStore.swift`
- Test: `Tests/FrameScrubCoreTests/ColorLayersTests.swift`, `ColorMemoryTests.swift`, `Tests/FrameScrubSettingsTests/StoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ColorLayerSnapshot: Sendable { public var file: [String: String]?; public var chain: [(url: URL, values: [String: String])] }
  public struct ColorLayerHit: Equatable, Sendable {
      public enum Level: Equatable, Sendable { case file, folder(URL) }
      public let level: Level; public let value: String; public let isNearestFolder: Bool
  }
  extension ColorLayers { public static func nearest(_ key: String, in snapshot: ColorLayerSnapshot, global: Config) -> ColorLayerHit? }
  extension ColorMemory {
      public func snapshot() -> ColorLayerSnapshot?          // nil without an open file
      public func clear(_ key: String, on level: ColorLayerHit.Level)
  }
  ```
  Store `override(forKey:)`: «This file» / `doc`; «This folder» / `folder`; «Folder <lastPathComponent>» / `folder`;
  help «The video on screen has its own value; the setting above applies elsewhere» (file) and «… its folder …»;
  `clearFolderOverride` → `clearColor(key, hit.level)`, then announces the key.

- [ ] **Step 1: Failing tests:** `fileBeatsFolderBeatsAncestor`, `aRefusedValueShowsTheNextLevel` (file
  `vibrance=7` refused → the folder's), `onlyColourKeysHaveLevels` (`nearest("volume", …) == nil`),
  `clearDropsOneLevel` (ColorMemory with file and folder values: clear `.file` → snapshot's file lacks the key, folder
  keeps it), `noVideoNoNote` (store with `colorLayers { nil }` → `override` nil, `clearFolderOverride` does nothing and
  posts nothing), `labels` (`"This file"`, `"This folder"`, `"Folder Shoot"`).
- [ ] **Step 2:** run the three suites → FAIL.
- [ ] **Step 3: Implement**; `nearest` uses `Config.applyingColors` to skip refused values, as `effective` does.
- [ ] **Step 4:** suites → pass.
- [ ] **Step 5: Commit** `Settings: the colour rows show the level that draws for the open video (file, folder, ancestor) with Use Default`.

### Task 8: Pages

**Files:**
- Create: `Sources/FrameScrubSettings/SettingsPanel.swift` (pages list, context type, show/close — the window part is
  filled in Task 10), `Sources/FrameScrubSettings/Pages/Page<Name>.swift` × 12 (General, SpeedSeeking,
  HomeInterface, Scrolling, Mouse, KeyBindings, Saving, Display, Colour, Performance, Stash, Advanced)
- Move: `Sources/FrameScrub/Preferences/OutputSizeField.swift` → `Sources/FrameScrubSettings/OutputSizeField.swift` (public)
- Test: `Tests/FrameScrubSettingsTests/PagesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SettingsPanelContext {
      public var configURL: URL; public var inputPreferences: InputPreferences
      public var iconChoices: @MainActor () -> [IconChoice]; public var iconChoice: (@MainActor (String) -> IconChoice?)?
      public var iconFolder: URL?; public var buildLine: String
      public var translateKey: (UInt16, Bool) -> String?; public var menuRows: @MainActor () -> [(input: String, title: String)]
  }
  @MainActor public enum SettingsPanel {
      public static func pages() -> [SettingsPage]
      static var context: SettingsPanelContext?; static var bindingSource: InputBindingSource?
  }
  ```
  Page ids: `general`, `speed`, `home`, `scrolling`, `mouse`, `key-bindings`, `saving`, `display`, `colour`,
  `performance`, `stash`, `advanced`; titles and symbols and the rows as in the spec's Pages table. Descriptions:
  what the setting does, its range and default, from `Config.set`'s ranges and `Config()`'s values (the old window's
  labels and captions carried over). The Gestures card is a placeholder `.custom` until Task 9.

- [ ] **Step 1: Failing tests:** `everyPageKeyIsAConfKey` (keys of `pages()` ⊆ `Config.keys` ∪ {`wheel-free-spin`}),
  `everyConfKeyIsOnAPage` (`Config.keys` − excluded ⊆ page keys), `noKeyTwice`, `choicesAreValues` (every
  `.choice` word is accepted by `Config.set`), `descriptionsNameTheDefault` (every keyed row's description contains
  "default" case-insensitively, or "Default").
- [ ] **Step 2:** `swift test --filter PagesTests` → FAIL.
- [ ] **Step 3: Implement** the pages; the Stash Check button keeps today's text (version and first scene's path).
- [ ] **Step 4:** filter → pass; `swift build` → ok.
- [ ] **Step 5: Commit** `Settings: FrameScrub's pages — every framescrub.conf key with a description, Key Bindings, Stash's Check`.

### Task 9: Gesture table in a card

**Files:**
- Move: `Sources/FrameScrub/Preferences/GestureTableView.swift` → `Sources/FrameScrubSettings/GestureTableView.swift`
- Create: `Sources/FrameScrubSettings/GestureTableModel.swift` (replaces `GestureModel`, over `InputPreferences`)
- Modify: `Sources/FrameScrubSettings/Pages/PageMouse.swift`
- Test: `Tests/FrameScrubSettingsTests/GestureTableModelTests.swift`

**Interfaces:**
- Produces: `public final class GestureTableModel: ObservableObject { init(preferences: InputPreferences); rows;
  errorMessage; update(_:_:); add(_:); reset(); static func searchTexts(_ rows: [GestureBinding]) -> [String] }`

- [ ] **Step 1: Failing tests:** `editsGoThroughInputPreferences` (update a row → `preferences.bindings` has it),
  `searchTextsNameDevicesAndActions` (contains "Trackpad" and "Scrub frames").
- [ ] **Step 2:** filter → FAIL.
- [ ] **Step 3: Implement**; the view drops its own background, reads `@Environment(\.settingsStyle)` for text
  colours; the Gestures card's `.custom` passes `searchTexts`.
- [ ] **Step 4:** filter → pass.
- [ ] **Step 5: Commit** `Settings: the gesture table in a card of Mouse & Trackpad, over InputPreferences`.

### Task 10: The window in the app

**Files:**
- Modify: `Sources/FrameScrubSettings/SettingsPanel.swift` (`show(store:context:page:)`, `close()`,
  `refreshFolderOverrides()`, terminate observer, `.glass`, autosave `FrameScrubSettings`, `settingsLastPage`,
  `tabbingMode = .disallowed`), `Sources/FrameScrub/AppDelegate.swift:18-75, 340-370`,
  `Sources/FrameScrub/PlayerWindowController.swift` (open/close file and colour commands call
  `SettingsPanel.refreshFolderOverrides()`; wheel mode change calls `store.wheelFreeSpinDidChange()`),
  `Sources/FrameScrub/AppIconSwitcher.swift` (`choices` reused by the context)
- Delete: `Sources/FrameScrub/Preferences/PreferencesWindowController.swift`, `PreferencesView.swift`,
  `PreferencesModel.swift`, `StashPreferencesView.swift`, `GestureModel.swift`
- Keep: `ExportSheetView.swift`, `ClipSheetView.swift` (they import `FrameScrubSettings` for `OutputSizeField`)

- [ ] **Step 1:** Wire it; remove `prebuildPreferencesWindow`. `swift build` → ok; `swift test` (whole suite,
  `scripts/test.sh`) → pass.
- [ ] **Step 2: Manual run** (`swift run FrameScrub` or the app bundle via `scripts/make-app.sh`): ⌘, opens on
  General; search «haptic» finds the Mouse page; change Volume in the window and with 9/0 in the player → both
  sides follow; Key Bindings: bind a key, the player does it at once; open a video with a folder colour → Colour page
  shows «This folder: …», Use Default drops it; edit framescrub.conf in an editor and come back → the row follows.
  Screenshot of Mouse & Trackpad for the README.
- [ ] **Step 3: Commit** `Settings: ⌘, opens SettingsKit's window; the old tabbed window goes`.

### Task 11: Bench

**Files:**
- Modify: `Package.swift` (executable `FrameScrubBench`: FrameScrubSettings, FrameScrubCore, SettingsKit)
- Create: `Sources/FrameScrubBench/main.swift`, `Sources/FrameScrubBench/SettingsBench.swift` (after Loupe's), `docs/bench/2026-10-27-settings.md`

- [ ] **Step 1:** Port Loupe's `SettingsBench` (open, first visits, returns, 5 rounds, longest turn, `--start ID`,
  `BENCH_BLOCKS=1`) over `SettingsPanel.pages()` with a temp conf.
- [ ] **Step 2:** `uptime` < 5, then `swift run -c release FrameScrubBench settings` ×3 on the M4 Max; the old window's
  numbers from `main` (a throwaway timing of `PreferencesWindowController` open and tab switches in the same bench
  run built from `../FrameScrub`) for comparison; Intel runner per docs/intel-runner.md if reachable, else say so in
  the document.
- [ ] **Step 3:** Budgets met, rounds flat → write the document (what, machine, results table). A miss → profile
  with `sample` before changing anything, per CLAUDE.md.
- [ ] **Step 4: Commit** `Bench: settings window (FrameScrubBench settings); docs/bench/2026-10-27-settings.md`.

### Task 12: README

**Files:** Modify `README.md` (Settings section: pages, search, Key Bindings, colour levels; the screenshot to
`docs/images/settings.webp`), `ROADMAP.md` if it lists the settings window.

- [ ] **Step 1:** Write; **Step 2: Commit** `README: the settings window on SettingsKit`.

### Task 13: Release and PRs (ask the user before merging or tagging)

- [ ] **Step 1:** SettingsKit: PR `settings` → main. After the user's go: merge, tag `0.7.0`, push the tag.
- [ ] **Step 2:** FrameScrub: `swift package unedit SettingsKit`; Package.swift `SettingsKit from: "0.7.0"`;
  `swift package update SettingsKit`; `scripts/kits-check.py` → `kits: ok`; `swift test` → pass; commit
  `Package: SettingsKit 0.7.0`; push; PR `settings` → main.
