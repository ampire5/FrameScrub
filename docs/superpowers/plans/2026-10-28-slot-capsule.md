# Slot capsule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the slot's header with a glass capsule (tabs, the view's tools, the slot's buttons), let a slot hold
several views as tabs, copy Zen's show / hide rules, finish the branch's remaining items and merge `strip-slots` into
`polish-2`.

**Architecture:** Pure rules (settings text, clocks, motion constants, hand-over filter) live in FrameScrubCore with
Swift Testing tests; the views (`SlotCapsuleView`, `SlotView`, `PlaylistPanelView`) and `SlotsController` live in the
app target, which has no test target: they are verified by build, suites, the bench and dev-build screenshots.

**Tech Stack:** Swift 6, AppKit, Core Animation, Swift Testing, `scripts/test.sh`, `FrameScrubBench`.

**Spec:** `docs/superpowers/specs/2026-10-28-slot-capsule-design.md`

## Global Constraints

- Worktree `~/Projects/GitHub/FrameScrub-strip`, branch `strip-slots`; HomeScreenKit in edit mode → `../HomeScreenKit-strip`.
- Tests: `scripts/test.sh --filter '<Suite>'`; full: `scripts/test.sh` (baseline 1690 passed, 20 skipped).
- Text on the capsule light (`#f2f2f7` primary, `#9a9aa2` secondary); glass = `.hudWindow` + veil black .35; hairline `rgb(255 255 255 / .14)`; corner radius 14; capsule 28 pt high, 6 pt from the card's edges; buttons 28×24.
- Timings: hide 0.15 s after leave (unchanged); capsule fade 0.15 s in, out 0.6 s after leave; show / hide motion a spring settling in 0.25 s with ~1 % overshoot; outside-window (not across the slot's edge) hide 1.0 s; flash 0.8 s; Reduce Motion: 0.15 s fade both ways.
- Card gap to the window 4 pt; shadow radius 4, offset 3, opacity .24; card hairline white .15.
- Config: content list joined by ` + `; one entry reads / writes exactly as today; `slot-flash=off|on`, default `off`.
- `CLAUDE.md` budgets: tab switch ≤ 100 ms first visit, ≤ 16 ms return; capsule show ≤ 2 ms; no timers at rest; hidden tabs hidden from hit testing, key loop and VoiceOver; no rebuilding on return.
- Dev builds run only with `CFFIXED_USER_HOME=<scratchpad>/home`; never install without the user's word; never synthesize pointer input (it moves the user's pointer).
- Commit messages in the repository's style (a sentence saying what changed and why, no prefix tags).

## Review Focus

1. A config written by the old build (`playlist, overlay, …`) and by this build read back by an old build: old builds see `playlist + plugin:X` as invalid and fall back to the default slot — acceptable only for the right slot's default; the test pins that a single-entry slot writes the old text byte for byte.
2. The playlist tab moved from one slot to another while its filter field is open in the first slot's capsule: the field must close and the keys return to the player (no orphaned first responder).
3. Closing the shown tab: the next tab (or the previous when it was last) is shown, its page gets `isShownInSlot = true`; the closed page is dropped (`onPageDropped`).
4. The app deactivated while a slot's menu is open: the menu closes with the deactivation; the slot hides once (no hide inside menu tracking).
5. A hand-over note from an older build (no `bundle` key) arrives at a new build: it is accepted, so an old installed app's second launch still hands files to a new one.

---

### Task 1: Slot contents as a list, `slot-flash` key

**Files:**
- Modify: `Sources/FrameScrubCore/SlotSettings.swift` (SlotContent, SlotSetting)
- Modify: `Sources/FrameScrubCore/Config.swift` (`slotFlash` next to `slotRevealDistance`: property, get, set, the slot defaults)
- Modify: `docs/reference.md` (slot lines ~460, new `slot-flash` line), `README.md:158-161` (slots: tabs, capsule)
- Test: `Tests/FrameScrubCoreTests/SlotSettingsTests.swift`, `Tests/FrameScrubCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `SlotSetting.contents: [SlotContent]` (never contains `.empty`; `[]` is an empty slot), `SlotSetting.content: SlotContent` kept as a computed read of `contents.first ?? .empty` for callers not yet moved; `SlotContent.text` / `init?(text:)` unchanged; `Config.slotFlash: Bool` (key `slot-flash`, `on|off`).

- [ ] **Step 1: Write failing tests** in `SlotSettingsTests`:
  - `severalContentsRoundTrip`: `SlotSetting(text: "playlist + plugin:Stash, overlay, glass, mouse-leaves, 400, hidden, at-once")!.contents == [.playlist, .plugin(name: "Stash")]` and `.text` equals the input.
  - `singleContentWritesTheOldText`: `"plugin:Notes, overlay, glass, mouse-leaves, 560, hidden, at-once"` round-trips unchanged; `contents == [.plugin(name: "Notes")]`.
  - `emptyIsNoContents`: `"empty, …"` → `contents == []`, writes `empty, …`.
  - `pluginNameMayHoldPlus`: `"plugin:A+B, …"` → `[.plugin(name: "A+B")]`.
  - `emptyInsideAListIsDropped`: `"playlist + empty, …"` → `[.playlist]`.
  - `duplicateIsDropped`: `"playlist + playlist, …"` → `[.playlist]`.
  In `ConfigTests`: `slotFlashDefaultsOffAndParses` (`slot-flash=on` → true; `slot-flash=maybe` rejected).
- [ ] **Step 2: Run** `scripts/test.sh --filter 'SlotSettingsTests|ConfigTests'` → the new tests fail to compile (no `contents`, no `slotFlash`).
- [ ] **Step 3: Implement.** `init?(text:)` splits the content part on `" + "`, parses each with `SlotContent(text:)` (any nil → the whole setting nil), drops `.empty` and duplicates keeping the first; `text` joins with `" + "`, `[]` → `"empty"`. Add the `StoreTests` candidate value for `slot-flash` as Task 6 of the strip plan did for its keys.
- [ ] **Step 4: Run** the filter → pass; then `scripts/test.sh` → all pass.
- [ ] **Step 5: Commit** — "Slots hold a list of views (`playlist + plugin:Stash`), one view written as before; slot-flash key".

### Task 2: Zen's clocks and motion constants

**Files:**
- Modify: `Sources/FrameScrubCore/SlotTiming.swift`
- Test: `Tests/FrameScrubCoreTests/SlotTimingTests.swift`

**Interfaces:**
- Produces:
  - `AutoHideClock.outsideDelay = 1.0`; `mutating func pointerOutsideWindow(now: Double)` (left the window not across the slot's edge: hides at `now + outsideDelay` unless the pointer comes back); `mutating func menuClosed(pointerInside: Bool, now: Double)` (like `shown`: waits for the pointer to come in when outside); `static func hidesOnResign(mode: SlotMode) -> Bool` (overlay true, pinned false).
  - `struct CapsuleClock` — `static let fadeIn = 0.15, outDelay = 0.6`; `mutating func pointerInside(_: Bool, now: Double)`, `mutating func setBusy(_: Bool)`, `mutating func shownByKey()` (visible until the pointer has come in and left once), `func isVisible(now: Double) -> Bool`, `func nextChange(now: Double) -> Double?` (when to look again; nil at rest).
  - `enum SlotMotion` — `static let duration = 0.25`, `stiffness: Double`, `damping: Double`, `mass = 1.0`, `fade = 0.15`, `flash = 0.8`; doc comment with the measured settle and overshoot.
  - `enum SlotFlash` — `static func shouldFlash(enabled: Bool, slotShown: Bool, cause: VideoChangeCause) -> Bool`, `enum VideoChangeCause { case autoadvance, key, playlistClick, open }` (flash only for `.autoadvance` and `.key`).

- [ ] **Step 1: Write failing tests:**
  - `outsideTheWindowHidesAfterASecond`: entered, `pointerOutsideWindow(now: 0)`; `shouldHide(now: 0.99) == false`, `shouldHide(now: 1.0) == true`.
  - `comingBackCancelsTheOutsideHide`: as above, then `pointerInside(true, now: 0.5)`; `shouldHide(now: 2) == false`.
  - `afterAMenuThePointerMustComeBack`: entered, `menuClosed(pointerInside: false, now: 0)`; `shouldHide(now: 5) == false`; `pointerInside(true, 5)`, `pointerInside(false, 5.1)`; `shouldHide(now: 5.25) == true`.
  - `resignHidesOverlayOnly`: `hidesOnResign(mode: .overlay) == true`, `.pinned == false`.
  - `capsuleFadesOutAfterTheDelay`: in at 0, out at 1; `isVisible(1.59) == true`, `isVisible(1.6) == false`; `nextChange(now: 1) == 1.6`; at rest `nextChange == nil`.
  - `capsuleHeldWhileBusy`: busy, out at 0; `isVisible(10) == true`; unbusy at 10 → visible until 10.6.
  - `capsuleShownByKeyWaitsForThePointer`: `shownByKey()`; `isVisible(100) == true`; in at 100, out at 101 → hidden at 101.6.
  - `springSettlesInAQuarterSecondWithAboutOnePercent`: build `CASpringAnimation`-equivalent closed form (damped oscillator with `SlotMotion` constants, from 0 to 1): settle to within 0.5 % by `0.25 ± 0.03` s, peak between 1.005 and 1.015, peak time between 0.15 and 0.2 s. (Closed form in the test, no QuartzCore in Core.)
  - `flashOnlyForAutoadvanceAndKeys`: true for `.autoadvance` / `.key` when enabled and not shown; false when shown, disabled, or `.playlistClick` / `.open`.
- [ ] **Step 2: Run** `scripts/test.sh --filter SlotTimingTests` → fail (missing symbols).
- [ ] **Step 3: Implement.** Pick `stiffness` / `damping` for mass 1 meeting the test (damping ratio ≈ 0.82, ω₀ ≈ 2π / 0.28: e.g. stiffness ≈ 500, damping ≈ 36.7 — tune to the test, write the measured numbers in the doc comment). `CapsuleClock` keeps `leftAt`, `entered`, `busy`, `byKey`.
- [ ] **Step 4: Run** the filter → pass.
- [ ] **Step 5: Commit** — "Slot timing as Zen's compact mode: 1 s outside the window, hide on resign, wait after a menu, the capsule's clock, a 0.25 s spring, flash rule".

### Task 3: Facts store does not hold its lock while decoding (deferred minor 17)

**Files:**
- Modify: `Sources/FrameScrubCore/FileFactsStore.swift`
- Test: `Tests/FrameScrubCoreTests/FileFactsStoreTests.swift` (create if absent; else add)

**Interfaces:**
- Produces: unchanged API (`all()`, `set(_:for:)`, `save()`); `set` never waits for a file read.

- [ ] **Step 1: Write failing test** `setDoesNotWaitForTheFirstRead`: a store over a 5 000-entry facts file (written in the test to a temp dir); start `all()` on a background queue, then on the test's thread time `set(_, for: "/x")`; assert it returns in < 5 ms and that a later `all()` holds both the file's entries and `/x`. Also `setBeforeLoadIsKept`: `set` before any `all()`, then `all()` contains the file's entries plus the set one (set wins for the same path).
- [ ] **Step 2: Run** `scripts/test.sh --filter FileFactsStoreTests` → the timing test fails (set waits for the decode).
- [ ] **Step 3: Implement.** Decode outside the lock: `all()` takes a snapshot under the lock; if not loaded, it reads and decodes without the lock, then under the lock merges pending sets over the loaded entries (pending wins) and installs (first installer wins). `set` before load writes into `pending` + `order`. `save()` writes the merged snapshot (loading first, outside the lock).
- [ ] **Step 4: Run** the filter, then the full suite → pass.
- [ ] **Step 5: Commit** — "Facts store: the first read decodes outside the lock, so a write on the main thread never waits for it (strip review minor 17)".

### Task 4: A build takes only hand-overs addressed to it

**Files:**
- Create: `Sources/FrameScrubCore/HandOver.swift`
- Modify: `Sources/FrameScrub/AppDelegate.swift:310-335` (`postHandOver`, `observeHandOver`)
- Test: `Tests/FrameScrubCoreTests/HandOverTests.swift`

**Interfaces:**
- Produces: `enum HandOver { static let bundleKey = "bundle"; static func userInfo(path: String?, link: URL?, bundle: String) -> [String: String]; static func isForUs(_ userInfo: [AnyHashable: Any]?, ownBundle: String) -> Bool }`.

- [ ] **Step 1: First confirm the cause.** Read `isSecondary` and the launch path in `AppDelegate`: a second FrameScrub (any build) posts `openFileNotification` to every running FrameScrub. Write the finding in the commit message. If the cause is different, stop and report it before changing anything.
- [ ] **Step 2: Write failing tests:** `ownBundleIsAccepted` (`bundle` = own path → true); `otherBundleIsRefused` (`/Users/x/Applications/FrameScrub.app` vs `/…/build/FrameScrub.app` → false); `noteWithoutBundleIsAccepted` (old builds → true); `pathsCompareStandardized` (trailing slash and `..` → same).
- [ ] **Step 3: Run** `scripts/test.sh --filter HandOverTests` → fail.
- [ ] **Step 4: Implement** `HandOver`; `postHandOver` sends `HandOver.userInfo(… bundle: Bundle.main.bundlePath)`; the observer returns early unless `HandOver.isForUs(note.userInfo, ownBundle: Bundle.main.bundlePath)`. The secondary is the same bundle's second launch, so it still hands over to its own primary.
- [ ] **Step 5: Run** the filter and the full suite → pass. **Commit** — "A FrameScrub takes a hand-over only from its own bundle: a dev build next to the installed app no longer opens what the other was given".

### Task 5: `SlotCapsuleView`

**Files:**
- Create: `Sources/SlotChrome/SlotCapsuleView.swift` — a small library target `SlotChrome` (Package.swift: depends on FrameScrubCore; the FrameScrub app and FrameScrubBench depend on it) so the bench in Task 10 drives the real view; everything the app uses is `public`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `CapsuleClock`, `SlotMotion.fade` (Task 2).
- Produces:
  - `struct SlotTab: Equatable { let id: String; let symbol: String?; let letter: String?; let name: String; var selected: Bool }`
  - `struct SlotTool { let id: String; let symbol: String; var accent: Bool; let tip: String; let menu: (() -> NSMenu)?; let action: (() -> Void)? }`
  - `@MainActor final class SlotCapsuleView: NSView` with `static let height: CGFloat = 28`, `static let margin: CGFloat = 6`; `var edge: SlotEdge`; `var tabs: [SlotTab]`; `var tools: [SlotTool]`; `var pinned: Bool`; `var showsBackdropButton: Bool`; callbacks `onSelectTab: (String) -> Void`, `onTabMenu: (String, NSView) -> NSMenu?`, `onPlus: (NSView) -> Void`, `onPin`, `onBackdrop`, `onHide: () -> Void`, `onCapsuleMenu: () -> NSMenu`, `onFilterText: (String) -> Void`, `onFilterSubmit: () -> Void`, `onFilterEnd: () -> Void`; `func beginFilter(text: String)`; `var isEditingFilter: Bool`; `var isHoveringTab: Bool`; `func setVisible(_: Bool, animated: Bool)`.

- [ ] **Step 1: Build the view.** Frames, not constraints, in `layout()`; tab buttons from a pool reused on `tabs` change (no new views when only `selected` changes); the search field (`NSSearchField`, small) created on first `beginFilter`, then kept and hidden; opening it slides tabs+tools out by opacity / translation 0.15 s; Esc on a non-empty field clears, on an empty field ends (`onFilterEnd`). Right-click on a tab → `onTabMenu`; right-click elsewhere → `onCapsuleMenu`. Look per Global Constraints. `accessibilityRole` toolbar; each button labelled with its tip. Hide chevron symbol by edge: `.right` → `chevron.right`, `.left` → `chevron.left`, `.bottom` → `chevron.down`.
- [ ] **Step 2: Build** `swift build` (via `scripts/test.sh --filter SlotTimingTests`, which builds the app target) → compiles, no warnings in the new file.
- [ ] **Step 3: Commit** — "SlotChrome target with SlotCapsuleView: the slot's capsule (tabs, the view's tools, pin / backdrop / hide, a filter field), not yet used".

### Task 6: `SlotView` with the capsule, tabs host, Zen look and motion

**Files:**
- Modify: `Sources/FrameScrub/SlotView.swift`

**Interfaces:**
- Consumes: `SlotCapsuleView` (Task 5), `SlotMotion` (Task 2).
- Produces: `SlotView.capsule: SlotCapsuleView`; `func setViews(_ views: [String: NSView], shown id: String?)` (adds missing subviews once, keeps the rest; non-shown: `isHidden = true`, `setAccessibilityElement(false)`); `var shownView: NSView?`; `overlayInset` = 4; header, `titleButton`, `pinButton`, `backdropButton`, `closeButton`, `onHeaderMenu`, `onTogglePin`, `onCycleBackdrop`, `onClose` removed (the capsule's callbacks replace them; `SlotsController` wires `view.capsule`); `content` replaced by `setViews`; `headerHeight` removed (callers use `SlotCapsuleView.height + margin` where they inset).

- [ ] **Step 1: Change the view.** Content host fills the panel; capsule placed at the panel's top, `margin` from its edges, above the host. Hide: the same spring as show (`SlotMotion` constants) translating to the edge, `isHidden` at the end; Reduce Motion: fade `SlotMotion.fade` both ways. Card hairline .15, shadow radius 4 offset 3 opacity .24 (unchanged radius/offset). Text shadow on clear: the capsule keeps its own glass, no shadow needed on it.
- [ ] **Step 2: Fix the callers** in `SlotsController` just enough to compile (wire `capsule` callbacks to the old handlers; `setViews([id: view], shown: id)` with one view). Task 7 does the tabs.
- [ ] **Step 3: Run** `scripts/test.sh` → all pass (no behaviour test here; the build is the check).
- [ ] **Step 4: Commit** — "Slots: a capsule instead of the header, the view full height; 4 pt off the window, hairline .15; hides on the same 0.25 s spring it shows with".

### Task 7: Tabs in `SlotsController`

**Files:**
- Modify: `Sources/FrameScrub/SlotsController.swift`

**Interfaces:**
- Consumes: `SlotSetting.contents` (Task 1), `SlotView.setViews` / `capsule` (Task 6), `SlotTab` (Task 5).
- Produces: `Slot.pages: [String: PluginPanel]` (by plugin name), `Slot.shownContent: SlotContent?`; private `addTab(_:to:)`, `showTab(_:in:)`, `closeTab(_:in:)`, `moveTab(_:from:to:)`; `tabMenu(for:content:)`, `capsuleMenu(for:)`; `onPagesChanged` fired on tab switches.

- [ ] **Step 1: Implement.** Start: each slot builds only its first (shown) tab's view; other tabs' pages are built on first show (a page load is not cut into pieces, so not built ahead — `CLAUDE.md`). One playlist in the app: adding it to a slot removes its tab from the slot that had it (and ends its filter if open there: `playlistView.endFilter()` + `onFocusVideo`). Switching tabs: previous page `isShownInSlot = false`, new `true`; `contents` reordered so the shown one is first, `persist`. Closing the shown tab shows the next, else the previous; the last closed → empty slot ("+" in the middle). Closed page → `onPageDropped`. The "Hide by Itself" items move to `capsuleMenu`; Reload Page / Move to … / Close Tab to `tabMenu`. Plus menu adds a tab. Tab ids: `"playlist"`, `"plugin:<name>"`. Tabs' symbols: playlist `play.rectangle`; plugin: `PluginPanel`'s declared symbol if the bridge gives one (none today → letter).
- [ ] **Step 2: Run** `scripts/test.sh` → pass.
- [ ] **Step 3: Dev-build check** (see Task 11 Step 1 for the run command) with `slot-right=playlist + plugin:<a fixture page>`: screenshot of the right slot pinned with two tabs. Look: tabs, tools, buttons readable.
- [ ] **Step 4: Commit** — "Slots hold tabs: the capsule's tabs switch the views, + adds one, a tab's menu reloads, moves or closes it; views built once and kept".

### Task 8: Zen's show / hide in `SlotsController`, the flash

**Files:**
- Modify: `Sources/FrameScrub/SlotsController.swift`; the window controller where the video changes (find the call that sets the playlist's current item; pass the cause).

**Interfaces:**
- Consumes: Task 2's `AutoHideClock` additions, `CapsuleClock`, `SlotFlash`, `Config.slotFlash`.
- Produces: `SlotsController.videoChanged(cause: VideoChangeCause)`.

- [ ] **Step 1: Implement.**
  - In `autoHideTick`: pointer outside the window and not `SlotHover.counts` → `clock.pointerOutsideWindow(now:)` (once per leave).
  - Observe `NSWindow.didResignKeyNotification` of the container's window and `NSApplication.didResignActiveNotification`: hide overlay slots (`hidesOnResign`); not while `menuOpen` (the menu closes first; hide on `menuClosed` then).
  - Where `menuOpen` goes false: `clock.menuClosed(pointerInside: isPointer(in:), now:)`.
  - Before `hide(slot)` from the clock: skip while the window is being moved (`NSEvent.pressedMouseButtons != 0` with the last mouse-down in the title bar → `windowDragging` flag set by `NSWindow.willMoveNotification`, cleared on `didMoveNotification` + mouse up).
  - Capsule: `CapsuleClock` per slot, ticked from the same poll while shown; when nothing is pending, a single `DispatchWorkItem` at `nextChange` replaces polling for the capsule (no timer at rest). Pinned: capsule always visible. Busy: menu open, filter editing, `isHoveringTab`.
  - `videoChanged(cause:)`: if `SlotFlash.shouldFlash(enabled: slotFlash, slotShown:, cause:)` for the slot holding the playlist → show it without focus, hide after `SlotMotion.flash` unless the pointer came in; a new call restarts the 0.8 s.
- [ ] **Step 2: Run** `scripts/test.sh` → pass.
- [ ] **Step 3: Commit** — "Slots hide as Zen's sidebar: 1 s after the pointer left the window elsewhere, when the window or app loses focus, not during a window drag, after a menu only once the pointer was back; the capsule's own fade; slot-flash".

### Task 9: Playlist and pages under the capsule

**Files:**
- Modify: `Sources/FrameScrub/PlaylistPanelView.swift`, `Sources/FrameScrub/PlaylistStripView.swift` (top inset only if its fade does not already clear 34 pt), `Sources/FrameScrub/PluginPanel.swift` (+ the bridge script source it names)

**Interfaces:**
- Consumes: `SlotTool` (Task 5).
- Produces: `PlaylistPanelView.tools: [SlotTool]` (🔍 accent while `filterText` is not empty; ⇅ only for a folder playlist, its menu built on open with the current order ticked), `var filterText: String`, `func setFilter(_: String)`, `onToolsChanged: (() -> Void)?`; the capsule's filter callbacks drive the existing `onFilter` / `onSubmitFilter` / `onEndFilter`; `PluginPanel.topInset: CGFloat` → `document.documentElement.style.setProperty('--slot-top-inset', '<n>px')` on load and on change.

- [ ] **Step 1: Implement.** Remove the search field and sort popup row from `PlaylistPanelView`; `beginFilter()` now asks the slot's capsule (`SlotsController` routes ⌘F to the capsule of the slot holding the playlist, showing the slot first). Table: `scroll.contentInsets.top = SlotCapsuleView.height + SlotCapsuleView.margin * 2`; `automaticallyAdjustsContentInsets = false`. Strip: check its first row at rest clears the capsule; if not, add the same top inset to `FilmstripRowsView`'s layout through its existing insets (no kit change if it has one; otherwise note it and leave the overlap, the fade covers it).
- [ ] **Step 2: Run** `scripts/test.sh` → pass.
- [ ] **Step 3: Commit** — "Playlist: filter and order in the slot's capsule, the list starts under it; pages get --slot-top-inset".

### Task 10: Slots bench (and minor 18)

**Files:**
- Create: `Sources/FrameScrubBench/SlotsBench.swift`; Modify: `Sources/FrameScrubBench/main.swift` (`case "slots"`)
- Create: `docs/bench/2026-10-28-slot-capsule.md`

**Interfaces:**
- Consumes: `SlotChrome` (Task 5). Minor 18: `PlaylistStripView` stays in the app (its glue needs the app's stores and timers); the bench doc records this as minor 18's resolution, and that the capsule bench drives the real `SlotCapsuleView`.

- [ ] **Step 1: Bench.** Real window 400 × 900 on screen; a panel view with a capsule over three tab views (a `FilmstripRowsView` with 500 rows, two blank `WKWebView`s loaded with `about:blank`); per round: capsule shown / hidden 50× (CPU per action), tab switch first visit and return 20×, filter field open / close 20×; 5 rounds; `CLOCK_THREAD_CPUTIME_ID`, CA flush per action (as `PlaylistStripBench`).
- [ ] **Step 2: Run** `. scripts/deps-env.sh; $(swift build -c release --triple "$DEPS_TRIPLE" --show-bin-path)/FrameScrubBench slots --rounds 5` → per-round lines; rounds do not grow; within budgets. Write the table (machine, what, results) to the bench doc.
- [ ] **Step 3: Commit** — "Bench: slot capsule and tabs (docs/bench/2026-10-28-slot-capsule.md)".

### Task 11: Check, merge, build

**Files:** none new; `docs/reference.md` / `README.md` touched up if the check finds drift.

- [ ] **Step 1: Dev-build check.** `scripts/make-app.sh`; config in `<scratchpad>/home/.config/framescrub/framescrub.conf`: `playlist-view=strip`, `slot-right=playlist + plugin:<page>, pinned, glass, mouse-leaves, 400, shown, at-once`; run `CFFIXED_USER_HOME=<scratchpad>/home build/FrameScrub.app/Contents/MacOS/FrameScrub <fixture>`; bring the window forward before `screencapture -l <id>` (it captured black while behind on 2026-10-28). Screenshots: pinned with tabs; ⌘F with the field open; each backdrop with the slot overlay (`osascript` keys only: ⌃⌘→, ⌘F — no pointer). Quit it.
- [ ] **Step 2: Merge `polish-2` in** (FrameScrub-strip, Loupe-strip; HomeScreenKit-strip if `polish-2` moved) → `scripts/test.sh` all pass; Loupe `scripts/test.sh` all pass; kit `swift test` all pass.
- [ ] **Step 3: Ask the user** before the outward steps: tagging HomeScreenKit (FrameScrub pins `from: "0.7.0"`; `strip-slots` adds Filmstrip rows → `0.8.0`), pushing the tag, merging into `polish-2`, installing. Do only what they approve.
- [ ] **Step 4 (on approval): Merge** `strip-slots` into `polish-2` in HomeScreenKit, FrameScrub, Loupe (main checkouts: check `git worktree list`, `ListAgents` and dirty state first); unedit the kit in the strip worktrees; FrameScrub's `Package.swift` `from: "0.8.0"`; build both apps with `scripts/make-app.sh`; suites green; install only on the user's word; check `FSBuildHash` in the installed Info.plist.
