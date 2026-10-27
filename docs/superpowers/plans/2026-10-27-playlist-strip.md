# Playlist Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With `playlist-view = strip`, FrameScrub's playlist slot shows a vertical filmstrip (whole pictures, the
browsed row larger with a card) on a row layout and view in HomeScreenKit; scrolling browses, a click or ↩ opens.

**Architecture:** HomeScreenKit (`../HomeScreenKit-strip`, branch `strip-slots`) gains a layout protocol for
`FilmstripScroll`, a pure row layout `FilmstripRows`, and a view `FilmstripRowsView`. FrameScrub
(`../FrameScrub-strip`, branch `strip-slots`, kit in edit mode) keeps `PlaylistPanelView` as the slot's content and
swaps its table for `PlaylistStripView`; the state (browsed / playing / return) and the poster dwell are pure types
in FrameScrubCore.

**Tech Stack:** Swift 6.2 tools, Swift 5 language mode, AppKit + Core Animation, swift-testing, macOS 26.

**Spec:** `docs/superpowers/specs/2026-10-27-playlist-strip-design.md` (read it first; this plan argues from it).

## Global Constraints

- Branch `strip-slots` in both repos; never commit to `polish-2`, never `make-app --install` without the user's word.
- FrameScrub builds the kit in edit mode against `../HomeScreenKit-strip`; `Package.resolved` is not committed from
  edit mode (`git checkout Package.resolved` before each commit if it changed).
- `playlist-view`: `list` | `strip`, default `list`. `playlist-strip-return`: 0…30 s, default 3, 0 = never.
- Background work at `.utility`; main thread never decodes or reads files; at rest no timers or animations run.
- Posters on dwell: 0.3 s in the visible window; at most 24 queued; one worker (the strip's own thumbnailer).
- Budgets (bench, main-thread CPU): show slot first ≤ 100 ms / again ≤ 30 ms; scroll event p99 ≤ 8 ms; browsed
  moves by one ≤ 16 ms; filter 500 → 40 rows ≤ 50 ms.
- Code reads like its neighbours: doc comments in the same terse style, `///` on every type and non-obvious member.
- Kit tests: `swift test --filter <Name>` in `HomeScreenKit-strip`. FrameScrub tests: `scripts/test.sh --filter <Name>`.

**Deviations from the spec, decided here** (Task 1 writes them into the spec):
- No `FilmstripAxis.vertical`: `FilmstripScroll` is already axis-free (`fingerDelta` = along, `crossDelta` =
  across); the vertical view passes the vertical delta as `fingerDelta`. Only the layout protocol is added.
- `FilmstripView` and `FilmstripRowsView` share only the edge fade (`FilmstripFade`); the cell pools differ in what
  a cell holds and stay per view.
- Posters: Home's `PictureQueue` moves to its own file and is reused with the `posters` store and its own
  one-worker `RecentThumbnailer`.
- `PlaylistRow` gains `url: URL?` (the local file; nil for scenes and streams) so the strip can find pictures.

## Review Focus

1. **One item, or none.** A folder with a single video, or an empty filter result: the strip shows the one row (or
   nothing), no crash, no scroll; ↩ with no rows does nothing. → Task 2 (`rowsSingleAndEmpty`), Task 6
   (`stateEmptyRows`).
2. **The playing video filtered out.** The filter hides the playing file: `browsed` goes to the first row, the
   return does nothing (nothing to return to) until the filter clears. → Task 6 (`returnWhenPlayingHidden`).
3. **Autoadvance mid-browse.** The next file starts while the user is scrolling: `playing` moves, `browsed` stays
   under the fingers; after the gesture the return goes to the new one. → Task 6 (`playingChangesDuringGesture`).
4. **Scenes and streams in a list playlist.** Rows without a local URL: an empty frame, the title, no poster asked,
   no crash. → Task 7 (`rowWithoutURL`), Task 8 (`dwellSkipsNil`).
5. **Fast flick across 500 rows.** Rows passing through the window do not queue posters (none stays 0.3 s); the
   queue never exceeds 24. → Task 8 (`flickQueuesNothing`, `capAt24`).

---

### Task 1: Worktrees build; `FilmstripTrack`; spec deviations

**Files:**
- Create: `HomeScreenKit-strip/Sources/FilmstripModel/FilmstripTrack.swift`
- Modify: `HomeScreenKit-strip/Sources/FilmstripModel/FilmstripScroll.swift` (`event`, `drag`, `settled`,
  `layoutChanged`, `move`: `layout: FilmstripLayout` → `layout: some FilmstripTrack`)
- Modify: `HomeScreenKit-strip/Sources/FilmstripModel/FilmstripLayout.swift` (conformance)
- Modify: `FrameScrub-strip/docs/superpowers/specs/2026-10-27-playlist-strip-design.md` (the four deviations)
- Test: `HomeScreenKit-strip/Tests/FilmstripModelTests/FilmstripScrollTests.swift`

**Interfaces:**
- Produces: `public protocol FilmstripTrack { var itemCount: Int { get }; var offsetRange: ClosedRange<Double> { get }; func centre(of item: Int) -> Double; func item(atBase position: Double) -> Int? }`

- [ ] **Step 1:** In `FrameScrub-strip`: `swift package edit HomeScreenKit --path ../HomeScreenKit-strip`, then
  `swift build`. Expected: builds. `git checkout Package.resolved` if it changed.
- [ ] **Step 2: Failing test** `scrollOnAnyTrack`: a `struct EvenTrack: FilmstripTrack` (10 items, pitch 50,
  centre(of: i) = 50·i, offsetRange 0…450); `event(fingerDelta: -60, …, layout: EvenTrack(), current: 0)` returns
  `item == 1`.
- [ ] **Step 3:** `swift test --filter FilmstripScrollTests` → fails to compile (no protocol).
- [ ] **Step 4:** Add the protocol, conform `FilmstripLayout`, make the five methods generic.
- [ ] **Step 5:** `swift test --filter FilmstripModelTests` → all pass (existing ones unchanged).
- [ ] **Step 6:** Write the four deviations into the spec's Architecture section.
- [ ] **Step 7: Commit** each repo: kit `FilmstripScroll on any FilmstripTrack (the layout protocol it reads)`;
  FrameScrub `Spec: playlist strip, decisions of the plan`.

### Task 2: `FilmstripRows` (pure row layout)

**Files:**
- Create: `HomeScreenKit-strip/Sources/FilmstripModel/FilmstripRows.swift`
- Test: `HomeScreenKit-strip/Tests/FilmstripModelTests/FilmstripRowsTests.swift`

**Interfaces:**
- Consumes: `FilmstripTrack`.
- Produces:
  ```swift
  public struct FilmstripRow: Equatable, Sendable {
      public let item: Int
      public let start: Double, length: Double   // along, base coordinates (top = 0, growing down)
      public let picture: CGRect                  // within the row: x across, y along
  }
  public struct FilmstripRows: FilmstripTrack, Equatable, Sendable {
      public static let portraitCap = 1.0        // a picture is never taller than wide
      public static let gapRatio = 0.08           // of rowPicture
      public init(itemCount: Int, aspects: [Double?], length: Double, width: Double,
                  rowPicture: Double, currentPicture: Double, cardHeight: Double)
      public func rows(offset: Double, current: Int, expansion: Double) -> [FilmstripRow]   // visible only
      public func fades(rows: [FilmstripRow], current: Int) -> (start: Double, end: Double)
  }
  ```
  Aspect = width ÷ height, nil = 16:9. A plain row: picture `rowPicture` wide, height `rowPicture / max(aspect,
  portraitCap)`, row length = that. The current row: picture `currentPicture` wide (same rule), row length =
  picture height + `cardHeight`; `expansion` 0…1 interpolates the current row between plain and full. `offset` is
  the base position under the strip's centre.

- [ ] **Step 1: Failing tests:**
  - `wholePictures`: aspects `[16/9, 4/3, 9/16, nil]`, `rowPicture` 96 → picture heights 54, 72, 96, 54.
  - `currentRowHasCard`: `currentPicture` 280, `cardHeight` 120, current 16:9 → row length 157.5 + 120.
  - `centreRoundTrip`: for 50 items, `item(atBase: centre(of: i)) == i` for all i.
  - `offsetRange`: 1 item → `c…c`; many → `centre(of: 0)…centre(of: n-1)`.
  - `visibleOnly`: length 600, 500 items, offset at item 250 → every returned row intersects 0…600 around the
    centre, and count < 30.
  - `fadesNeverOverCurrent`: at item 0 → start fade 0; at the last → end fade 0; elsewhere neither fade reaches the
    current row.
  - `rowsSingleAndEmpty` (Review Focus 1): 0 items → `rows` empty, `item(atBase:)` nil; 1 item → one row.
- [ ] **Step 2:** `swift test --filter FilmstripRowsTests` → fails (no type).
- [ ] **Step 3:** Implement with prefix sums of plain lengths (`[Double]`, `itemCount + 1`), the current row's
  extra length added after `current`; `item(atBase:)` by binary search.
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5: Commit** `FilmstripRows: the vertical row layout (whole pictures, the current row larger with its card)`.

### Task 3: `FilmstripFade` shared by both views

**Files:**
- Create: `HomeScreenKit-strip/Sources/Filmstrip/FilmstripFade.swift`
- Modify: `HomeScreenKit-strip/Sources/Filmstrip/FilmstripView.swift` (`fadeLayer`, `fadeMask`, `placeFade`)
- Test: `HomeScreenKit-strip/Tests/FilmstripTests/FilmstripViewTests.swift` (existing)

**Interfaces:**
- Produces: `@MainActor final class FilmstripFade { let layer: CALayer; init(axis: Axis); func place(bounds: CGRect, start: CGFloat, end: CGFloat) }` with `enum Axis { case horizontal, vertical }` (internal to the module).

- [ ] **Step 1:** Run `swift test --filter FilmstripTests`; note the pass count.
- [ ] **Step 2:** Move the fade code out of `FilmstripView` unchanged in behaviour (horizontal case = today's
  gradient `startPoint`/`endPoint` and locations); `FilmstripView` uses `FilmstripFade(axis: .horizontal)`.
- [ ] **Step 3:** Same tests, same count, all pass.
- [ ] **Step 4: Commit** `Filmstrip: the edge fade in its own type, for a second strip view`.

### Task 4: `FilmstripRowsView` and the demo

**Files:**
- Create: `HomeScreenKit-strip/Sources/Filmstrip/FilmstripRowsView.swift`
- Modify: `HomeScreenKit-strip/Sources/homescreen-demo/FilmstripDemo.swift` (a vertical case: 300 fake rows)
- Test: `HomeScreenKit-strip/Tests/FilmstripTests/FilmstripRowsViewTests.swift`

**Interfaces:**
- Consumes: `FilmstripRows`, `FilmstripRow`, `FilmstripFade`, `HomeChrome` text styles.
- Produces (all `public`, `@MainActor`):
  ```swift
  final class FilmstripRowsView: NSView {
      var layout: FilmstripRows                      // set by the owner; relayout on set
      var playing: Int?                              // marker: accent edge + "▶ " before the title
      var card: NSView?                              // placed under the browsed row's picture
      var onPress: ((Int) -> Void)?                  // click on a row (≤ 3 pt of travel)
      var onDrag: ((CGFloat) -> Void)?, onDragEnd: (() -> Void)?   // along delta, points
      var onStripScroll: ((NSEvent) -> Void)?        // every scroll event (none passes to superviews)
      var onVisibleChange: (() -> Void)?
      private(set) var visibleItems: [Int]           // centre outwards
      func show(offset: Double, current: Int, expansion: Double, animated: Bool)
      func setRow(_ item: Int, title: String, detail: String, progress: Double?)
      func setImage(_ image: CGImage?, forItem item: Int)
      func forget(_ item: Int); func forgetAll(); func remap(_ map: [Int: Int])
  }
  ```
  Layers per visible row from a pool: picture (contents, corner radius `Chrome.Radius.cell`), progress bar (3 pt,
  black 55 % track, accent share), title and detail `CATextLayer`s (12 / 10 pt, `Chrome.Text`), all in one content
  layer moved as a whole; no drawing in `draw(_:)`. `scrollWheel` never calls `super`.

- [ ] **Step 1: Failing tests:**
  - `poolFollowsWindow`: 500 rows, height 600 → sublayer count of the content layer < 40 after `show` at 0, 250, 499.
  - `pressReportsItem`: a synthesized mouse down/up at the centre row's frame → `onPress(current)`.
  - `scrollIsSwallowed`: a scroll event reaches `onStripScroll` and not the superview (a test superview counting
    `scrollWheel`).
  - `cardSitsUnderPicture`: with `card` set, its frame's top equals the browsed picture's bottom + 6.
- [ ] **Step 2:** `swift test --filter FilmstripRowsViewTests` → fail.
- [ ] **Step 3:** Implement. The demo gets a vertical strip next to the horizontal one, driven by the same
  `FilmstripScroll` (vertical delta as `fingerDelta`).
- [ ] **Step 4:** Tests pass; `swift run homescreen-demo` and look at the vertical strip (take a screenshot for the
  user).
- [ ] **Step 5: Commit** `FilmstripRowsView: the vertical strip of rows (picture, title, detail, position, card)`.

### Task 5: Loupe regression against the branch

**Files:** none in git (a worktree `../Loupe-strip` on a new branch `strip-slots` from `polish-2`).

- [ ] **Step 1:** `git -C ../Loupe worktree add -b strip-slots ../Loupe-strip polish-2`; in it,
  `swift package edit HomeScreenKit --path ../HomeScreenKit-strip`.
- [ ] **Step 2:** `swift test` in `Loupe-strip` → all pass. Same in `Loupe` (polish-2) for the baseline if any fail.
- [ ] **Step 3:** Run Loupe's strip bench as its docs say (`LoupeBench strip`, see `Sources/LoupeBench/StripBench.swift`)
  in both; numbers within 10 % of each other. Record both in the task report.

### Task 6: Config keys and `PlaylistStripState`

**Files:**
- Modify: `FrameScrub-strip/Sources/FrameScrubCore/Config.swift` (keys list, `text(forKey:)`, `set`)
- Modify: `FrameScrub-strip/Sources/FrameScrubSettings/Pages/PageHomeInterface.swift` (two rows by
  `playlist-font-size`)
- Create: `FrameScrub-strip/Sources/FrameScrubCore/PlaylistStripState.swift`
- Test: `FrameScrub-strip/Tests/FrameScrubCoreTests/ConfigTests.swift`,
  `FrameScrub-strip/Tests/FrameScrubCoreTests/PlaylistStripStateTests.swift`

**Interfaces:**
- Produces: `Config.playlistView: PlaylistView` (`enum PlaylistView: String { case list, strip }`),
  `Config.playlistStripReturn: Double`.
- Produces:
  ```swift
  public struct PlaylistStripState: Equatable, Sendable {
      public private(set) var playing: Int?, browsed: Int?
      public private(set) var returnDeadline: Double?   // nil: nothing armed
      public init(returnDelay: Double)                   // 0 = never
      public mutating func rowsChanged(count: Int, playing: Int?, map: [Int: Int])
      public mutating func opened(_ row: Int)            // playing = browsed = row, disarm
      public mutating func browse(to row: Int, now: Double, inGesture: Bool)   // arms unless in gesture
      public mutating func activity(now: Double, inGesture: Bool)   // pointer over / typing: re-arm or hold
      public mutating func fire(now: Double) -> Bool      // true: browsed went back to playing
      public mutating func cancel()                       // slot hidden / window not visible
  }
  ```
- [ ] **Step 1: Failing tests:** `ConfigTests`: both keys round-trip, defaults `list` / 3, `playlist-strip-return`
  rejects 31 and -1. `PlaylistStripStateTests`:
  - `browseArmsReturn`: delay 3, browse at t=10 → deadline 13; `fire(now: 12.9)` false; `fire(now: 13)` true,
    browsed == playing, deadline nil.
  - `zeroNeverReturns`: delay 0 → deadline stays nil.
  - `gestureHolds`: browse with `inGesture: true` → no deadline; `activity(now: 20, inGesture: false)` → 23.
  - `returnWhenPlayingHidden` (Review Focus 2): rowsChanged with playing nil → browsed 0, `fire` does nothing.
  - `playingChangesDuringGesture` (Review Focus 3): browse(…, inGesture: true), `rowsChanged(… playing: 5 …)` →
    playing 5, browsed unchanged; activity(not in gesture) arms; fire → browsed 5.
  - `stateEmptyRows` (Review Focus 1): rowsChanged(count: 0) → both nil, every call is a no-op.
  - `mapKeepsBrowsed`: browsed 7, map `[7: 3]` → browsed 3; browsed missing from map → playing ?? 0.
- [ ] **Step 2:** `scripts/test.sh --filter "ConfigTests|PlaylistStripStateTests"` → fail.
- [ ] **Step 3:** Implement; descriptions on the settings rows: "Playlist: a list of names, or a strip of pictures"
  and "Seconds before the strip goes back to the playing video after browsing (0: never)".
- [ ] **Step 4:** Same command → pass; `scripts/test.sh --filter FrameScrubSettingsTests` (coverage) → pass.
- [ ] **Step 5: Commit** `playlist-view and playlist-strip-return; PlaylistStripState (browsed, playing, the return)`.

### Task 7: `PlaylistRow.url` and `PlaylistRowFacts`

**Files:**
- Modify: `FrameScrub-strip/Sources/FrameScrubCore/ListPlaylist.swift` (`PlaylistRow`: `public let url: URL?`;
  `init(file:)` sets it; `init(_ item:)` sets it for `.file`, nil otherwise)
- Create: `FrameScrub-strip/Sources/FrameScrubCore/PlaylistRowFacts.swift`
- Test: `FrameScrub-strip/Tests/FrameScrubCoreTests/PlaylistRowFactsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PlaylistRowFacts: Equatable, Sendable {
      public let detail: String          // "2:14:05 · 4K · HEVC"; without facts: "1.2 GB"; neither: ""
      public let progress: Double?       // position ÷ length, 0…1; nil unplayed; nil when ≥ 0.98
      public let card: [String]          // lines: size · date; "3840×2160 · HEVC · 23.976 fps"; "watched 42 %"
      public init(facts: FileFacts?, resume: ResumeEntry?, size: Int64?, date: Date?)
  }
  ```
  Resolution class from the longer side: ≥ 3800 "4K", ≥ 2500 "1440p", ≥ 1900 "1080p", ≥ 1260 "720p", else "SD".
  Lengths as `H:MM:SS` from an hour, else `M:SS`. Sizes with `ByteCountFormatter` (`.file`).
- [ ] **Step 1: Failing tests:** `detailWithFacts` (8045 s, 3840×2160, "hevc" → "2:14:05 · 4K · HEVC"),
  `detailWithoutFacts` (size 1_288_490_188 → "1.2 GB"), `progressPlayed` (60 of 600 → 0.1), `progressFinished`
  (595 of 600 → nil), `progressUnplayed` (nil), `rowWithoutURL` (Review Focus 4: `PlaylistRow(.scene(…))`.url == nil,
  `PlaylistRow(file:)`.url == the file).
- [ ] **Step 2:** `scripts/test.sh --filter PlaylistRowFactsTests` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Pass; whole `scripts/test.sh` still green (PlaylistRow's `Equatable` change).
- [ ] **Step 5: Commit** `PlaylistRowFacts: a playlist row's facts line, position and card; PlaylistRow keeps its file`.

### Task 8: Posters on dwell

**Files:**
- Create: `FrameScrub-strip/Sources/FrameScrubCore/PosterDwell.swift`
- Create: `FrameScrub-strip/Sources/FrameScrub/PictureQueue.swift` (moved from `FrameScrubHomeSource.swift`
  unchanged, `private` → internal)
- Modify: `FrameScrub-strip/Sources/FrameScrub/FrameScrubHomeSource.swift` (the class removed from it)
- Test: `FrameScrub-strip/Tests/FrameScrubCoreTests/PosterDwellTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PosterDwell: Sendable {
      public static let delay = 0.3, cap = 24
      public init()
      /// The rows in the window now (nil url: nothing to make) at `now`; returns the files due, in window order,
      /// at most `cap`, each once until `reset()`.
      public mutating func visible(_ urls: [URL?], now: Double) -> [URL]
      public var nextDeadline: Double? { get }   // when to call again; nil: nothing waiting
      public mutating func reset()
  }
  ```
- [ ] **Step 1: Failing tests:** `dueAfterDelay` (seen at 0, `visible` at 0.29 → [], at 0.3 → [url]),
  `flickQueuesNothing` (Review Focus 5: 500 urls, each visible for 0.05 s in turn → nothing due, ever),
  `capAt24` (40 urls visible from 0, at 0.3 → 24), `onlyOnce` (due at 0.3, again at 1.0 → []),
  `dwellSkipsNil` (Review Focus 4: `[nil, url]` → [url]), `leftWindowForgotten` (seen at 0, gone at 0.1, back at
  0.2 → not due at 0.3, due at 0.5).
- [ ] **Step 2:** `scripts/test.sh --filter PosterDwellTests` → fail.
- [ ] **Step 3:** Implement; move `PictureQueue` (Home behaviour unchanged).
- [ ] **Step 4:** Pass; `scripts/test.sh` green; `swift build` of the app.
- [ ] **Step 5: Commit** `PosterDwell: posters only for rows that stay in view; PictureQueue in its own file`.

### Task 9: `PlaylistStripView` in the playlist slot

**Files:**
- Create: `FrameScrub-strip/Sources/FrameScrub/PlaylistStripView.swift`
- Modify: `FrameScrub-strip/Sources/FrameScrub/PlaylistPanelView.swift` (table or strip under the bar;
  `update(rows:current:)` feeds whichever is shown; ↑ ↓ ⇞ ⇟ ↩ in `control(_:textView:doCommandBy:)` go to the strip
  when shown; `var view: PlaylistView`)
- Modify: `FrameScrub-strip/Sources/FrameScrub/PlayerWindowController.swift` (`playlistPanel.view =
  config.playlistView` where `fontSize` is set, lines ~261 and ~1152)

**Interfaces:**
- Consumes: `FilmstripRowsView`, `FilmstripRows`, `FilmstripScroll`, `PlaylistStripState`, `PlaylistRowFacts`,
  `PosterDwell`, `PictureQueue`, `ThumbnailStore`, `ResumeStore`, `FileFactsStore`.
- Produces: `final class PlaylistStripView: NSView` with `onSelect: ((Int) -> Void)?`,
  `update(rows: [PlaylistRow], current: Int)`, `step(by: Int)`, `openBrowsed()`, `returnDelay: Double`.

Behaviour as the spec's Behaviour section. Pictures: `ThumbnailStore()` (last frame) first, then the `posters`
store (`ThumbnailStore(directory: …/posters, limit: 2000, maxSide: 480)`), both read off the main thread through a
`PictureQueue`; misses go to `PosterDwell` and its due files to the queue with a one-worker `RecentThumbnailer`.
The dwell and return timers are one-shot `Timer`s re-armed from `nextDeadline` / `returnDeadline`; both cancelled
in `viewDidMoveToWindow` (nil window) and on `NSWindow.didChangeOcclusionStateNotification` when not visible.
The card: an `NSStackView` of `NSTextField` labels from `PlaylistRowFacts.card`, rebuilt only when `browsed` changes.

- [ ] **Step 1:** Implement; `swift build` passes.
- [ ] **Step 2:** `scripts/test.sh` green.
- [ ] **Step 3:** Run the built app (not installed) with `playlist-view = strip` on a test folder
  (`scripts/make-fixtures.sh` output): scroll browses without changing the video; click and ↩ open; after 3 s it
  returns; filter and order work; the slot pinned and overlay; ⌘+scroll over the strip does not zoom the video.
  Screenshots for the user.
- [ ] **Step 4: Commit** `Playlist strip: playlist-view = strip shows the playlist as a vertical filmstrip in its slot`.

### Task 10: Bench

**Files:**
- Create: `FrameScrub-strip/Sources/FrameScrubBench/PlaylistStripBench.swift`
- Modify: `FrameScrub-strip/Sources/FrameScrubBench/main.swift` (`case "playlist-strip"`)
- Create: `FrameScrub-strip/docs/bench/2026-10-27-playlist-strip.md`

Follows `SettingsBench.swift`: the real `PlayerWindowController`'s slot with a `PlaylistPanelView` in `strip` mode,
500 generated rows (3 aspects, a third with facts), `CLOCK_THREAD_CPUTIME_ID` around each action, 5 rounds, p50 /
p99 / max per action, first visit and return separately.

- [ ] **Step 1:** Implement; `swift run FrameScrubBench playlist-strip` prints the table.
- [ ] **Step 2:** Every action within the Global Constraints budgets; rounds do not grow. If one is over: profile
  with `sample`, fix, measure each fix alone, before/after in the doc.
- [ ] **Step 3:** Doc with machine, method, table, and "Intel Mac: not measured yet".
- [ ] **Step 4: Commit** `Bench: playlist strip (docs/bench/2026-10-27-playlist-strip.md)`.
