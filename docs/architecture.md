# FrameScrub architecture

Current code map; `Package.swift` defines target dependencies. Update this file when subsystem ownership,
concurrency, persistence or integration changes. Historical specs/plans are rationale, not the current contract.

## Targets

| Target | Owns | Entry points |
|---|---|---|
| FrameScrub | App lifecycle, player window, browser/playlist/plugin integration and display views | `Sources/FrameScrub/AppDelegate.swift`, `Sources/FrameScrub/PlayerWindowController.swift` |
| FrameScrubCore | Playback state machine, decoding, indexing, caches, audio, export and persisted facts | `Sources/FrameScrubCore/PlayerCore.swift` |
| FrameScrubSettings | SettingsKit store, bindings and pages | `Sources/FrameScrubSettings/SettingsPanel.swift` |
| FrameScrubBench | Real-window settings, slots and playlist benchmarks | `Sources/FrameScrubBench/main.swift` |
| CFFmpeg / CSQLite / ObjCCatch | Native library interfaces and Objective-C exception boundary | `Sources/CFFmpeg`, `Sources/CSQLite`, `Sources/ObjCCatch` |

Core is not synonymous with pure data: it includes FFmpeg/media I/O, concurrency and some platform integrations.
The executable supplies UI and connects commands/delegate callbacks to the core.

## Ownership and flows

- `AppDelegate` handles launch/open events, menus, settings and top-level application coordination.
- `PlayerWindowController` coordinates a player window, its `PlayerCore`, views, playlist, Home, slots, inspector
  and plugin panel. Its large size is not permission to mix another independent subsystem into it.
- `PlayerCore` is a main-thread state machine. It owns frame cache/filler, playback clock, audio and export state;
  its weak `PlayerCoreDelegate` delivers frames and state/feedback to the UI.
- Open/seek/input → controller → `PlayerCore` → index/cache/decoder work → delegate frame → `VideoView`.
  `PictureQueue` and `PreviewProvider` concern presentation/previews, not a second playback source of truth.
- `PlayerWindowController.configurePreview` creates one `PreviewImagePool` per open-file preview configuration,
  shared by hover `PreviewProvider` and `FilmstripPreviewLoader`'s provider. It bounds small SDR images by entries
  and pixel bytes, with actual PTS/rotation/resolution identity. Providers reuse matching `FrameCache` keyframes
  before opening their own decoder; Core Image construction/rendering stays on each provider's worker.
  The film loader selects reusable samples first, then centre-first misses, with one utility request in flight
  and at most `TimelineFilmLayout.maximumCells` pending times. `PlayerCore.allowsBackgroundPreview` requires
  resolved foreground work (cached or terminally undecodable current frame, also the next frame while playing).
  `CacheFiller.onFocusUnavailable` reports the unresolved-to-undecodable focus transition outside its lock;
  PlayerCore checks session/current position and emits a state change even without a displayable frame.
  Hidden/interaction gating and display/state callbacks defer/resume work without polling. Stop suppresses
  queued delivery/completion; old providers can only populate their old per-file pool.
- Byte input → `ReadCache`/`ByteSource` → `MediaSource`/`VideoDecoder` → `DecoderBackend` (`VTBackend` or
  `FFmpegBackend`) → decoded frames → `FrameCache`. `CacheFiller` plans background work around the position.
- Browser → `FrameScrubHomeSource` → listings/posters/catalog → HomeScreenKit UI. Playlist navigation and
  persisted sort/history are application responsibilities at the integration boundary.
- Plugin page → `PluginPanel` / bridge → core plugin messages/policies/actions → application/player commands.
  Keep external page data separate from trusted application configuration.

## Concurrency and cancellation

The UI and `PlayerCore` state changes belong to the main thread; decoding, probing, indexing, thumbnail generation
and export have their own workers/queues. Consult each implementation rather than assuming all Core methods are
safe on arbitrary threads. `NetworkPolicy` governs reads; `ReadCache` bounds byte residency.
`LatestOnlyWorker` coalesces replacement work. `MetadataInspectionQueue` has one running probe and one pending
selection, cancels superseded jobs, and suppresses their completion. Open/close must cancel obsolete media work.
Do not add parallel probes or per-frame filesystem operations to the controller.

## Persistence and integrations

`MediaCatalog` is the disposable SQLite catalog behind media facts and thumbnails; `FileFactsStore` and
`ThumbnailStore` expose those responsibilities. `ResumeStore` separately persists positions, loops, marks, colour
and last-viewed times in a bounded JSON store with a shared in-process snapshot and utility writer. Viewing history
is user state, not disposable metadata. Follow identity and modification checks before reusing facts. `Config`, `PreferencesStore` and input preferences supply settings;
`FrameScrubSettingsStore` adapts them to SettingsKit.

HomeScreenKit supplies browser, slots and filmstrip UI; SettingsKit supplies settings presentation; InfoPanelKit
supplies panel UI; StashKit supplies server/path/web integration. App Logitech input is bridged through MouseService
(`LogiMouseBridge`); LogiHIDPP also supplies shared hardware types. See [kit workflow](kits.md).

## Change entry points and verification

| Work | Start here | Check |
|---|---|---|
| Seeking/playback/marks | `Sources/FrameScrubCore/PlayerCore.swift`, `ScrubController.swift`, `PlaybackEdges.swift`, `CutMarks.swift` in the same directory | `Tests/FrameScrubCoreTests` |
| Read/decode/network | `Sources/FrameScrubCore/ReadCache.swift`, `VideoDecoder.swift`, `NetworkPolicy.swift` in the same directory | decoder/cache tests and relevant `docs/bench` |
| Media facts/history | `Sources/FrameScrubCore/MediaCatalog.swift`, `ResumeStore.swift`, `FileFactsStore.swift` in the same directory | catalog/facts/resume tests |
| Inspector | `Sources/FrameScrub/MediaMetadataInspector.swift`, `Sources/FrameScrubCore/MetadataInspectionQueue.swift` | metadata queue tests |
| Settings | `Sources/FrameScrubSettings` | `Tests/FrameScrubSettingsTests`, `FrameScrubBench settings` |

Run `swift test --jobs 4` with the native dependencies described in [README](../README.md). Use the real-window
benches for navigation/control latency, and compare first visit with return separately. [User reference](reference.md)
describes controls/settings, not internal ownership. No architectural change should silently alter kit pins.
