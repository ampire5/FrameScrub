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
  shared by hover `PreviewProvider` and `FilmstripPreviewLoader`'s provider. `preview=no` disables only
  the hover provider; filmstrip visibility independently gates its utility loader. It bounds small SDR images by entries
  and pixel bytes, with actual PTS/rotation/resolution identity. Providers reuse matching `FrameCache` keyframes
  before opening their own decoder; Core Image construction/rendering stays on each provider's worker.
  Shared-pool hits can bypass a busy provider worker; delivery generations prevent an older cold result from
  replacing a newer ready image. Network throttling applies only to cold reads, with the first read immediate.
  The film loader selects reusable samples first, then centre-first misses, with one utility request in flight
  and at most `TimelineFilmLayout.maximumCells` pending times. `PlayerCore.allowsBackgroundPreview` requires
  resolved foreground work (cached or terminally undecodable current frame, also the next frame while playing).
  `CacheFiller.onFocusUnavailable` reports the unresolved-to-undecodable focus transition outside its lock;
  PlayerCore checks session/current position and emits a state change even without a displayable frame.
  Hidden/interaction gating and display/state callbacks defer/resume work without polling. Stop suppresses
  queued delivery/completion; old providers can only populate their old per-file pool.
  Before reveal, a separate bounded prewarm snapshot contains only candidates currently reusable from that pool
  or playback cache. `readyOnly` requests prohibit fallback to decoding if the source is evicted. Visible requests
  take priority on the same worker. Exact-index/configuration readiness and display of a missing sample frame
  trigger planning; all-intra playback does not replan every frame. Folded delivery caches without invalidation.
  The prewarm gate also excludes active hover preview, export, interactions, Home and occlusion. Unavailable
  candidates are not retained/retried on playback ticks; no new reader, full-file scan or timer is introduced.
- `LowLatencyDisplay` (App) owns display-only Apple LL SR, temporal-only LL interpolation and Temporal Noise Filter.
  For TNF the controller retains at most one previous and two next cached originals with index timestamps; LL FI needs
  one consecutive next frame. `PlayerCore.onDisplayReferencesChange` wakes only the current TNF neighborhood when
  a cache insertion fills a missing reference, allowing paused refinement without polling or new decoding; Core's decode/cache/index/audio
  ownership is unchanged. `LowLatencyVideoProcessor` (Core) owns serially accessed VideoToolbox sessions and
  configuration-derived buffer pools/format transfer. `LatestVideoWork` bounds requests to one active plus one
  replaceable pending value; generation and revision invalidate old results without releasing active GPU buffers.
  Session startup/processing run off-main; original-first fallback never holds the player clock. Intermediates
  are selected on the existing display tick using the playback clock; pause, reverse and non-1x speed bypass FI.
  Settings, seek discontinuities, file changes, hiding and shutdown invalidate display results. A one-shot idle
  callback closes processor sessions after five seconds; output buffers remain retained and immutable. No new
  decoder, unbounded frame queue, repeating timer or export effect is introduced. LL processing precedes upright
  crop, Subject Focus, colour and the existing MetalFX/Lanczos screen fitting. Original and LL outputs have separate
  scaler caches. Unsupported dimensions/factors explicitly bypass effects without pre-downscaling sources. HDR bypasses
  LL SR/FI; TNF uses API-required lossless 8/10-bit buffers with propagated metadata and the normal display tone-map/
  headroom plan. `TemporalNoiseFilter` (Core) validates adjacent references, trims to configuration counts and marks
  discontinuities for jumps/repeated frames. TNF precedes SR and explicitly bypasses FI in this experiment. Failure
  caching prevents model reload loops; output buffers remain immutable and owned through completion. TNF defaults
  to paused/settled frames: LatestVideoWork defers its single replaceable pending request for 120 ms, cancelling
  prior scheduled starts without retaining obsolete buffers. Playback TNF is an explicit experimental mode, since
  measured 4K processing (~31 ms) missed presentation deadlines in the original-first pipeline.
  `FRAMESCRUB_CONFIG_DIR` optionally selects an absolute config directory for isolated launches. Opt-in GPU patch
  hashes and LL work/result/intermediate metrics support pipeline diagnosis. Custom deblocking and image SR have
  been removed; saved/copied images resize with Lanczos. Legacy removed config keys are accepted for migration.
- Experimental SDR Filter Lab belongs to `DisplayScaler`. Deband and chroma cleanup run at
  the scaler's input resolution, BEFORE screen fitting; MetalFX anti-ringing and output dither
  run AFTER scaling and before existing sharpening. Optional perceptual grain follows sharpening. This input may already contain Apple LL
  processing when enabled. `VideoView` prepares shared immutable GPU pipelines off-main once.
  Separate pre/post `ArtifactFilterRenderer`s each own at most two reusable private textures,
  at source/output size respectively. MetalFX's original input texture is reused for source
  cleanup; the filtered texture goes directly into MetalFX without another CI copy. Post AR
  references that actual filtered input. Other scalers render source cleanup once and consume
  its CIImage. No CPU readback, per-frame worker queue, temporal history or new timer is added.
  Split/changes compare FINAL scaled images. When source cleanup is enabled, an extra original
  baseline texture and upscale are created only for comparison, then released on returning to
  processed view. Comparison uses an unaliased post scratch texture. Settings/readiness request
  paused redraw; moving zoom retains its existing cheap path and refines after settling.
  `ArtifactFilterPanelView` exposes full grouped controls as a lazy transient tab in the shared Slots host.
  It uses the same PreferencesStore as Settings/menu, refreshes through existing config application,
  and commits sliders on release / numeric fields on editing end. Shared slot typing detection
  keeps it visible during numeric editing. Cleanup profiles preserve grain and introduce no new passes. N toggles filters; Option-N opens the panel via remappable input commands.
  No auto-activation policy is installed.
  HDR bypasses encoded-SDR filters. Config/Display settings and `ArtifactFilterMenu` share
  the existing store; decoder/cache/export ownership is unchanged. `filters-pipeline` measures
  real DisplayScaler at 6144×3456; `filters` retains the old direct post-scale microbench.
  `filter-fixtures`, `filter-images`, and `filter-order` are offline GPU evaluation commands;
  their I/O/readbacks never enter player presentation. libplacebo shader adaptation notices
  travel with packaged apps; reference mode uses separate source with retained LGPL notice.
  `PerceptualGrainPipelines`, prepared in the same off-main pipeline task, owns immutable
  independent monochrome template banks and shader states, including prepared AV1-style and
  particle banks (16×64² R16F each) loaded once off-main
  from Core's SwiftPM resource bundle. Old styles retain 4×128² banks. The shader queries bank
  dimensions/layers, and both fused/general encoders use one explicit style-to-bank mapping.
  `GrainTemplateBank` searches app/framework/CLI bundle locations and throws on missing files;
  standalone packaging copies `FrameScrub_FrameScrubCore.bundle` into Contents/Resources.
  No source files or patterns are fetched, synthesized or read from disk on a video frame.
  Each scaler's `PerceptualGrainRenderer`
  owns a quarter-source-size R16F mask and, on the general path, one reusable output RGBA16F texture; mask sampling
  examines every source-pixel phase and protects luma/chroma structure. It compares original
  and pre-cleaned input activity, with a weaker baseline in already smooth regions. This is
  a texture heuristic, not artifact detection. Random-offset blocks use variance-preserving
  overlap. VideoView supplies decoded frame numbers as deterministic seeds; pause redraw and
  reverse seek reproduce the pattern without a timer or image history. Grain is added after
  post cleanup and sharpening, before final split/changes. Nonzero sharpening needs a separate
  staging texture; sharpened comparison has one additional reusable staging texture. HDR/off
  bypass and release grain buffers. The original comparison side remains grain-free.
  The common MetalFX+luma/edge AR+grain path with sharpen0/dither0 is fused: shared
  `antiringValue`/`grainValue` functions are compiled once in the artifact Metal library.
  The fused encoder writes an existing post-renderer scratch target and releases its separate
  grain output/staging, retaining only the mask. Comparison excludes that processed target.
  Sharpening, dither, directional cleanup, grain-only and non-MetalFX retain the general path.
  `grainUsesFusedPass` is a diagnostic for actual path selection, not an activation policy.
  Normal source-frame scrubbing uses this same display pipeline. Moving zoom/pan remains
  the existing cheap-transform path until it settles; hover/filmstrip thumbnails are separate.
- `VideoView` applies optional Subject Focus before display scaling. `SubjectMasker` owns one mask worker and one
  replaceable pending job; recurrent model state stays on that worker. Models remain user supplied outside the repo.
  `SubjectMatting` keeps native half-float conversion on Apple Silicon; Intel uses Core's `HalfPrecisionAlpha` to convert raw IEEE binary16
  through vImage before the same clamp/round. Non-unit strides are packed, scratch is bounded by the model plane,
  and vImage tiling is disabled so no second worker is introduced. At 768×432, scratch peaks at about 1.90 MiB.
  A release x86_64 helper under Rosetta on M4 Max (30 warm runs, wall time) took 0.40 ms for dense storage and
  0.66 ms with a column stride of two; this is not a physical Intel Mac latency measurement.
  `SubjectFocusPanelView` is a transient singleton native tab registered by the app's `SlotsController` adapter;
  the shared Slots host owns its capsule, width, pinning, backdrop and visibility. No second slot implementation is used.
- Opt-in `PlaybackDiagnostics` (Core) bounds recent samples and configuration groups, writes local JSON on a utility
  queue, and distinguishes GPU execution from physical drawable presentation. Decoder and preview workers record
  their own stages; the app records masks, UI and display events. App termination flushes diagnostics after its
  existing asynchronous user-state persistence. See [pipeline diagnostics](bench/playback-diagnostics.md).
- Byte input → `ReadCache`/`ByteSource` → `MediaSource`/`VideoDecoder` → `DecoderBackend` (`VTBackend` or
  `FFmpegBackend`) → decoded frames → `FrameCache`. `CacheFiller` plans background work around the position.
- Browser → `FrameScrubHomeSource` → listings/posters/catalog → HomeScreenKit UI. Playlist navigation and
  persisted sort/history are application responsibilities at the integration boundary.
  Showing Home disables the shared slot host; returning to the player restores its presentation. Hidden slots
  neither reveal at the browser's edges nor intercept its scroller, and their saved configuration stays intact.
  Folder/Recent listing streams stay open for coalesced metadata updates; new durations update that subscription
  without resetting the browser. Replacing/cancelling the subscription cancels its read; a generation token keeps
  an old termination callback from clearing the new subscriber. Leaving Home cancels pending metadata publication.
  Folder-history side buttons merge AppKit and MouseService events through a separate `MouseButtonRouter` with
  only release-time Back/Forward taps. This retains duplicate/drag/swipe cancellation even when MouseService
  consumes AppKit's copy; Home visibility changes cancel pending taps. Web pages retain their own swipe handling.
  `FolderChangeMonitor` opens an event-only directory descriptor off the main thread and coalesces native directory
  events (including SMB) without polling. It reconciles the descriptor-open race once, stops while Home/window is
  hidden, and reconciles again on return. Folder enumeration/metadata reads use one utility `LatestOnlyWorker`
  with one replaceable pending read; stale results are discarded. View › Refresh (⌘R) uses the same listing stream.
  Thumbnail workers report failure as well as success. `PictureQueue` finishes failed jobs and suppresses repeated
  attempts until refresh; confirmed damaged versions are marked in shared `UnreadableFiles` and omitted from Home.
  Failure stamps come from the attempted file identity; network/read errors do not mark files damaged. Source
  updates and new filesystem events preserve a user pause of thumbnail generation.
- Plugin page → `PluginPanel` / bridge → core plugin messages/policies/actions → application/player commands.
  Keep external page data separate from trusted application configuration.

## Concurrency and cancellation

The UI, `AppDelegate`, app icon presentation, `PlayerCore` and its delegate are main-actor owned; isolated teardown closes the player on that actor.
`FolderColors`, `FolderSorts` and `ColorMemory` enforce their existing main-thread contract with `@MainActor`.
The folder write scheduler receives main-actor callbacks; the settings gesture table model is main-actor UI state.
Shared process registries, refusal/log caches, thumbnail
job selection and export accounting use `Mutex`; background export/progress callbacks are `@Sendable`.
Decoded frames publish fully initialized, thereafter read-only pixel buffers; queued audio buffers likewise
relinquish mutation before crossing to the engine queue. Their narrow SDK wrappers document that contract.
CacheFiller runtime state stays under its condition lock; callback/test configuration is fixed before workers start.
Decoding, probing, indexing, thumbnail generation and export have their own workers/queues. Consult each
implementation rather than assuming all Core methods are safe on arbitrary threads. `NetworkPolicy` governs reads; `ReadCache` bounds byte residency.

`LatestOnlyWorker` coalesces replacement work. `MetadataInspectionQueue` has one running probe and one pending
selection, cancels superseded jobs, and suppresses their completion. Open/close must cancel obsolete media work.
Do not add parallel probes or per-frame filesystem operations to the controller.

Closing the sole player window requests termination through the run loop. Do not enter AppKit's async termination
wait from a main-queue block: the main-actor user-state flush must be able to run and reply to `.terminateLater`.
`FrameScrub --bench-close-window` checks the real launch/close/flush path in a separate process with a watchdog.

## App icon collection

`FrameScrubCore/AppIcon.swift` lists loose user icons and one-level folder packs under the user icon directory;
`FrameScrub/AppIconSwitcher.swift` supplies the grouped choices to SettingsKit’s icon picker and applies the selection.
Pack icons are stored as file paths in the existing `app-icon` setting. Hidden files and duplicate PNG/ICNS
representations of the same name are omitted. Artwork remains user supplied, outside the repository.

## Persistence and integrations

`MediaCatalog` is the disposable SQLite catalog behind media facts and thumbnails; `FileFactsStore` and
`ThumbnailStore` expose those responsibilities. `ResumeStore` separately persists positions, loops, marks, colour
and last-viewed times in a bounded JSON store with a shared in-process snapshot and utility writer. Viewing history
is user state, not disposable metadata. Follow identity and modification checks before reusing facts. `Config`, `PreferencesStore` and input preferences supply settings;
`FrameScrubSettingsStore` adapts them to SettingsKit.

HomeScreenKit supplies browser, slots and filmstrip UI; SettingsKit supplies settings presentation; InfoPanelKit
supplies panel UI; StashKit supplies server/path/web integration. `StashSession` feeds activity batches to one
main-actor `StashActivityQueue`: it serializes whole batches, coalesces unsent saves for one scene and only accepts
writes when tracking is explicitly enabled. Failed writes return only to their playback visit; details refreshes
advance a separate read generation and cannot discard that visit's retries. Async termination waits for that
same queue, including earlier pending saves when the final sample adds nothing, bounded to one second off-main; the fallback quit hook enqueues without
blocking the main thread. Successful writes refresh the current scene from the server, including writes queued
before that scene was closed and reopened; stale detail reads cannot overwrite the refreshed snapshot.
App Logitech input is bridged through MouseService
(`LogiMouseBridge`); LogiHIDPP also supplies shared hardware types. See [kit workflow](kits.md).

Opt-in `tourbox=yes` starts the app's `TourBoxBridge`: one Console Max/MSP client on loopback TCP 50500, one
32-byte asynchronous read in flight, with delivery and player commands on the main thread. Every byte is an event;
TCP read boundaries are not message boundaries. `FrameScrubCore/TourBoxRouter` owns held/consumed buttons,
one-shot hold deadlines, and independent Knob sensitivity/progressive acceleration (enabled by default).
Bare Knob uses a continuous bounded quadratic gain above the configurable pulse-rate threshold, with time-based
rise smoothing and immediate deceleration. Knob press toggles the existing `tourbox-accel` preference through
PreferencesStore with OSD feedback; mode changes reset motion without losing the held click/duplicate guard.
Tall+Knob changes volume, Tall+Top toggles mute and Short+Top calls `PlayerCore.reversePlaybackDirection`,
preserving speed/pause and restarting/refocusing the reverse/forward clock path when playing. There is no coarse
multiplier. Modifier toggles act on each target down while the modifier stays held, consuming release taps.
Reversal, idle and modifiers reset velocity; tied batch timestamps cannot manufacture speed. Top uses
Core's existing temporary speed hold; keyboard and TourBox ownership are exclusive. Top+Tour switches profile and
consumes both taps. C1/C2 navigate on release or adjust per-file colour strength in Viewing; in Editing they set/edit
mark boundaries. `ColorMemory.addStrength(for:)` handles either auto colour or Vibrance with the same bounds,
per-file persistence and independent enable flags. The controller samples one arrival time per batch and routes
commands through existing player actions. Scroll emits timeline points: `SeekBarView.scrollFilm` shares the
horizontal trackpad's local scale and fractional target time, with a one-shot idle completion. Other position input
and TourBox cancellation reset that time to prevent stale jumps. Focus loss, Home, file/profile changes, disconnect
and shutdown restore held speed, cancel deadlines and cancel unfinished edge edits.
The bridge rejects extra clients and stops on disable/shutdown; it never polls or claims the USB device. The
separate event preset is generated from a locally supplied vendor Lite template; the keyboard preset remains intact.

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

## Gesture ownership

`GestureAxisLock` in Core fixes the first intentional scroll axis through momentum; a new non-momentum
begin resets it immediately. Phase-less scrolling re-arms after a 0.25 s gap. Loupe's `ViewerView` filters deltas
before button/folder/pan routing; FrameScrub's `GestureRouter` filters before command routing. Pointer right-drag
zoom and right-button scrolling keep their first owner until release. Button recognition ignores zero deltas;
middle-button scrolling must cross a wheel step (12 precise points or one notched unit) before cancelling a click.
State is local to the existing input owners; no polling, new queues or dependencies are introduced.
