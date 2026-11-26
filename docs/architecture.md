# FrameScrub architecture

Current code map; `Package.swift` defines target dependencies. Update this file when subsystem ownership,
concurrency, persistence or integration changes. Historical specs/plans are rationale, not the current contract.

## Targets

| Target | Owns | Entry points |
|---|---|---|
| FrameScrub | App lifecycle, player window, browser/playlist/plugin integration and display views | `Sources/FrameScrub/AppDelegate.swift`, `Sources/FrameScrub/PlayerWindowController.swift` |
| FrameScrubCore | Playback state machine, decoding, indexing, caches, audio, export and persisted facts | `Sources/FrameScrubCore/PlayerCore.swift` |
| FrameScrubPlaybackProvider | Optional sandboxed ExtensionKit scene, audio clock, transport and picture surface | `Sources/FrameScrubPlaybackProvider/PlaybackExtension.swift` |
| FrameScrubSettings | SettingsKit store, bindings and pages | `Sources/FrameScrubSettings/SettingsPanel.swift` |
| FrameScrubBench | Real-window settings, slots and playlist benchmarks | `Sources/FrameScrubBench/main.swift` |
| CFFmpeg / CSQLite / ObjCCatch / CNV12Bitpack | Native library interfaces, Objective-C exception boundary and lossless NV12 block packing | `Sources/CFFmpeg`, `Sources/CSQLite`, `Sources/ObjCCatch`, `Sources/CNV12Bitpack` |

Core is not synonymous with pure data: it includes FFmpeg/media I/O, concurrency and some platform integrations.
The executable supplies UI and connects commands/delegate callbacks to the core.

## Ownership and flows

- `AppDelegate` handles launch/open events, menus, settings and top-level application coordination.
- `PlayerWindowController` coordinates a player window, its `PlayerCore`, views, playlist, Home, slots, inspector
  and plugin panel. Its large size is not permission to mix another independent subsystem into it.
- `PlayerCore` is a main-thread state machine. It owns frame cache/filler, playback clock, audio and export state;
  its weak `PlayerCoreDelegate` delivers frames and state/feedback to the UI.
- `PlayerWindowController` sends playback feedback to `FeedbackHUD` above the visible timeline and filmstrip.
  The HUD updates one badge in place and replaces its one-shot fade deadline. Seeks can use the directional
  transport button or the navigation filmstrip instead.
- The optional playback provider can link the static `FrameScrubPlayback` product. A single worker owns
  `OnDemandVideo`, which uses `MediaSource`, `ReadCache` and `VideoDecoder` directly. The provider can
  duplicate a read-only descriptor into `FileByteSource` without resolving the file path. The cursor
  seeks by presentation timestamp and decodes the needed region on request. It starts no full-file index
  or prefetch. Each cursor retains a contiguous run of already decoded pictures, up to 64 MiB or 24
  frames with a minimum two-frame seek bracket. Nearby steps and seeks reuse its presentation timestamps,
  while a miss seeks to the preceding keyframe. Its owner closes the read cache to cancel stale I/O and
  discards the cursor after failed or cancelled decode work.
  The shipped extension also owns an audio decoder over the same cache and schedules one future picture
  against `PlaybackClock`. WebP uses `AnimatedImagePlayback`. GIF always uses the descriptor-backed FFmpeg
  cursor, with a two-block (4 MiB) input cache and a decoded history of at most 24 frames. On machines
  with enough RAM the GIF history grows from 64 to 192 MiB to keep adjacent reverse steps in memory.
  Packed BGRA preserves transparency and FFmpeg retains positive frame delays starting at 10 ms. A bounded GIF prefix
  supplies the loop count. On arm64 macOS 27.2.1, a 151 MiB mounted example and a local synthetic 1 GiB GIF
  reached frame zero in 0.76 s and 0.17 s. The test process peaked at 163 MiB and 167 MiB respectively after
  stepping forward, reversing, and seeking. These figures include the test runner and use warm filesystem caches.
  Protocol v4 accepts captured scroll and supported key events from Loupe. The provider loads the standalone
  layout, input bindings and scrub settings on its worker at media open. Its sandbox has read-only paths for those
  four configuration files. `GestureRouter` produces frame steps and transport actions. Scrubbing pauses on the
  first matching movement. Volume changes only the scene's audio mixer and is initialized from the player's config.
  Protocol v5 adds a viewer-wide play/pause command and a fixed 48-point transport row. Timeline drag and
  accessibility value changes submit seeks through the same worker, with one current request and one replacement.
  Protocol v6 toggles Auto Color and vibrance. The decode worker analyzes one picture per Auto Color
  enable and reuses the result with FrameScrub Core's renderer. The remote picture handles pan,
  magnification and right clicks. The host cancels a pending click when a right-button wheel gesture
  claims the press. A frame step also cancels the click before it pauses the clock.
  Scene removal or XPC invalidation stops the clock and releases the media. The `paused=1` open link suppresses
  autoplay and preserves the requested presentation time when the standalone player's exact index becomes ready.
- Open/seek/input → controller → `PlayerCore` → index/cache/decoder work → delegate frame → `VideoView`.
  `PictureQueue` and `PreviewProvider` concern presentation/previews, not a second playback source of truth.
- `OpenFailureView` routes its recovery buttons through the existing file-open and browser-return paths.
  `GoToField` keeps the draft input and displays the controller's correction when a jump cannot be made.
  `ExportSheetView.Choices` owns the export draft, including the custom pixels entered in `OutputSizeField`.
  The sheet sends validated options to the controller when Export is activated.
- `PlayerWindowController.configurePreview` creates one `PreviewImagePool` per open-file preview configuration,
  shared by hover `PreviewProvider` and `FilmstripPreviewLoader`'s provider. `preview=no` disables only
  the hover provider; filmstrip visibility independently gates its utility loader. It bounds small SDR images by entries
  and pixel bytes, with actual PTS/rotation/resolution identity. Providers reuse matching `FrameCache` keyframes
  before opening their own decoder; Core Image construction/rendering stays on each provider's worker.
  Shared-pool hits can bypass a busy provider worker; delivery generations prevent an older cold result from
  replacing a newer ready image. Network throttling applies only to cold reads, with the first read immediate.
  Hover applies crop and pixel aspect on a latest-only rendering worker. The controller delivers the result only
  for the current hover request and geometry. Clearing hover or closing the file invalidates an outstanding result.
  Page streams key the shared pool by the resolved video URL. A nominal index can reuse a pool image or
  playback picture at its requested PTS when the decoded timestamp matches that PTS.
  The film loader selects reusable samples first, then centre-first misses, with one utility request in flight
  and at most `TimelineFilmLayout.maximumCells` pending times. `PlayerCore.allowsBackgroundPreview` requires
  resolved foreground work (cached or terminally undecodable current frame, also the next frame while playing).
  A cold local filmstrip decode also checks foreground demand on its worker before opening or rendering and
  during packet traversal. A deferred sample stays in its current visible or warm batch and is retried when the
  player can spare the decoder. Ready images are served without asking for another decode.
  Visible Stash filmstrips try matching ready pictures first, then sample time cues from `StashStoryboard`'s VTT
  and sprite sheet. One utility request at a time fetches and crops bounded assets with same-origin authentication.
  Each cell is keyed by its time. Hiding or replacing the filmstrip cancels its pending storyboard work. Missing
  storyboards and cues fall back to the ordinary preview path. Folded warming reuses ready images while the
  storyboard is available or still untested.
  `CacheFiller.onFocusUnavailable` reports the unresolved-to-undecodable focus transition outside its lock;
  PlayerCore checks session/current position and emits a state change even without a displayable frame.
  Visible drag and scroll scrubs replace the pending thumbnail batch as the playhead moves. The batch dwell
  keeps its deadline and the loader still waits for foreground readiness. Hidden/interaction gating and
  display/state callbacks defer/resume work without polling. Stop suppresses
  queued delivery/completion; old providers can only populate their old per-file pool.
  The folded strip reveals as soon as the pointer enters its future height. Folding cancels any pending pointer hide,
  and a manual fold suppresses hover reveals until the pointer leaves the reveal zone. Opening by command waits for
  the pointer to enter before arming pointer-based hiding. A bounded preparation snapshot runs on
  the same worker and yields to visible requests. During playback it reuses only the shared pool or playback cache.
  While paused it can decode misses one at a time. On network volumes a miss taking at least the existing preview
  settle interval ends speculative reads for that snapshot. A failed speculative read also ends the batch of misses
  without disabling visible previews. `readyOnly` prohibits fallback if a cached source is evicted. Filmstrip reads
  skip read-ahead and software fallback uses one codec thread. Index/configuration readiness, paused position
  changes, folding, live resize completion and visibility restoration trigger planning. During playback a displayed missing
  sample can trigger planning, with no per-frame replan for all-intra media. Folded delivery caches without
  invalidation. Active hover preview, export, interactions, Home and occlusion gate preparation. It uses the same
  reader and introduces no full-file scan or timer.
- With `navigation-filmstrip=yes`, the window controller records the actual positions before and after user navigation.
  `NavigationRibbonView` keeps the first origin and uses one expiry job for the burst. The folded
  presentation clips an aspect-sized row to the available width. Narrow images use more closely spaced samples, within
  the same screenful limit as the full strip. `SeekBarView` chooses the samples and interpolates the actual
  position between their times. The view repositions retained thumbnail layers and the row together beneath a fixed
  playhead, drawing only new pictures. A shared Filmstrip popover controls side crop and stretch for both
  strips. Its Mini Strip tab changes only the compact width and height. Fit changes reuse the existing pictures.
  Both strips place whole-file progress under the thumbnails. The full strip's progress rail shows its own
  hover time and seeks on that same linear scale.
  Passive native glass backdrops share the over-media palette and leave timeline hit testing with the owning views. Hover
  or an open settings popover holds the ribbon. The reveal uses one small rise and the exit fades out, both omitted
  with Reduce Motion. The menu shortcut updates the same auto-show preference as Settings.
  The mini strip pin is saved in user defaults. The full strip takes precedence while open and folding it restores
  the pinned mini strip at the current position, which follows existing player state callbacks and shares the same
  picture cache and loader. Temporarily hiding the mini strip keeps its bounded tile row available for reuse.
  Idle preparation puts the selected scale's samples in the existing
  bounded batch. While the ribbon is visible its missing pictures replace the loader's visible batch. Ready pictures and
  playback frames can fill it during the foreground seek. Cold reads wait for foreground readiness and the existing
  network dwell. Compact and open film share the same serial utility worker. Opening the full film or clearing the journey
  discards the compact batch; an in-flight decode can still enter the same file's cache.
  Both strips center the current time on the playhead and add a quieter duration when it fits. The mini scale
  button reports the visible time span by interpolating its sample times at the clip edges. The full strip draws
  relative time marks using its seek projection, with authored fragment markers taking precedence. When either
  strip takes over from the other, the destination playhead and readout draw immediately. For 210 ms the full
  picture surface expands from the compact width or shrinks toward it using a soft-edged compositor mask.
  On the way back the mini pictures fade in while the full strip keeps its picture surface in place until the
  animation finishes. The transition uses the existing pictures and adds no thumbnail work or timers. Reduce Motion
  swaps the strips immediately.
  Pending thumbnails reserve their cells.
  The frame count requires an exact index and a single source fragment on a virtual cut.
  The open strip keeps the current time at the playhead and labels the pointer's seek target when the labels fit separately.
  Its detail row shows the virtual-cut fragment. Virtual-cut hover maps the target to source time,
  with a frame index when the session already has the exact source index.
- Filmstrip clicks capture the time under the pointer at mouse-down and seek on release through the normal player path.
  After a paused Whole File Lens click lands on the requested frame, `SeekBarView` keeps that projection until
  playback resumes or the position changes. The playhead coasts within that projection on the existing finite
  main-run-loop transition timer. Elsewhere distant clicks can briefly blend the old and destination geometry.
  Thumbnail requests resume for the settled view; intermediate positions never
  reach the decoder. File changes, other position input and hiding cancel the coast.
  The optional frame preview uses `VideoView`'s existing display link while paused. It checks for every ready
  intermediate frame in a corridor of up to 240 frames under one cache lock, or uses up to three existing
  filmstrip thumbnails. It performs no media reads and keeps the normal seek authoritative for edits,
  exports and playback. New input, a new player frame or hiding ends the preview.
  VideoView limits preview density using cached availability, the display link interval and recent CPU
  encoding and GPU execution times. It retains at most one sampled command buffer and reads its
  status without waiting. A pending sample can skip an intermediate picture. The destination draws normally.
  A direct drag uses its mouse-down projection and moves the real playhead, with throttled mark haptics.
  Slow drag gains use the local frame interval, with an optional detent on a nearby editing mark. Reversing
  releases the detent on the first movement. The preview sampler reserves a short consecutive arrival run
  when it is already in cache and fits the display budget.
  Painted mark handles identify a specific source-frame boundary and share `EdgeDrag` bounds, undo and
  cancellation with the wheel editor. The view holds its pointer-down projection during the edit.
  A latest-only utility worker can make one original reference thumbnail from the decoded cache.
  A fast release advances at roughly 30 samples per second on the same finite timer and interpolates the
  film geometry between those updates. It lasts up to 220 ms at the default transition setting.
  The horizontal trackpad gesture accepts native momentum only for its owned scroll sequence.
  Each sample must be ready in the playback cache and inside the current segment lock. The first miss,
  a fresh grab, a command or hiding cancels the coast. Edge resistance shifts only the film cells.
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
  Viewing profile Forward toggles filters and Forward + wheel adjusts Overall effect. Wheel steps update the
  shared PreferencesStore in memory and coalesce config writes off the main thread.
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
  Normal source-frame scrubbing uses this same display pipeline. A paused source picture can submit once
  after the input turn using the latest view state when the current display interval has not submitted a picture.
  The next tick can submit any newer pending state. Playback, filmstrip previews, moving zoom/pan, and timed
  colour and focus transitions stay on the display tick. Hover/filmstrip thumbnails are separate.
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
  Direct HTTP(S) `.m3u8` VOD opens use `HLSDemuxInput` with libavformat's HTTP and verified HTTPS transport.
  Video and audio open their own demuxers under one `HLSMediaSession`. It shares cancellation and a bounded
  in-memory cache for completed whole init and media responses. FFmpeg streams new bytes through as they arrive.
  The HLS demuxers disable persistent HTTP connections so a failed init-segment request leaves the demuxer usable.
  Byte ranges, redirects, playlists, cookie-dependent requests and oversize objects use native reads. The filler
  interrupts obsolete reads on cold jumps, and audio interrupts old reads when its playback generation changes. An explicit seek can
  retry frames skipped after a segment failure. VOD uses a duration and nominal-rate timeline without downloading the
  full stream for indexing. The forward worker fills the bound ahead of the playhead and leaves played frames
  in the existing decoded cache for backward scrub. A cold paused seek retains up to three nearby pre-roll frames
  from that same decode and publishes the target first. During normal playback and pause it is the only video
  decoder filling that window. During forward playback the clock holds both tracks when a requested video
  frame is still loading. The HLS preview provider reuses ready frames only.
  The file and HTTP Range paths use the byte cache. A newer distant cold jump outside the GOP in progress
  can stop obsolete forward pre-roll at a packet boundary. An absolute paused jump to an earlier picture
  in the same GOP can also stop it on a local file with an exact index and no loop or locked region. A later cold
  target in that GOP can continue from the forward decoder's existing packet cursor. This uses the same
  exact landing and nearby history as a demux seek. If the cursor ends or passes the target, the decoder
  retries from the target's keyframe. Replacing an index stops pre-roll on local files.
  The forward decoder repositions on its own worker. Shared
  reads that have already started can finish into the cache. Reads started before the jump cannot schedule more
  read-ahead for the cancelled generation. With an exact index on a local file, a cold paused landing retains
  up to eight already traversed pictures within the planned cache window and publishes the target first.
  For a long forward jump from the visible picture, the active preroll can separately send a single near-target
  preview without caching it or requesting scrub audio. Both the worker and player validate the target before
  publishing. The player checks its session, pause state and visible frame and excludes virtual cuts and locked
  segments. A long paused backward jump can request an image already in the shared preview pool. It must be on the
  path to the target, closer than the picture already shown and within one second and 60 frames of it. The
  window presents it as a thumbnail while the exact picture is pending. It stays outside the decoded cache,
  playback position and scrub-sound path. A replacement seek, playback, or a decoded picture clears it.
  The paused local cache keeps more history for a reversal from unit forward steps and leaves upcoming
  frames ready during coarse forward movement. During sustained local backward steps, it shifts the same byte
  budget toward upcoming frames so longer pieces of a GOP can finish before the cursor passes them. Locked
  regions keep their normal window.
  The local backward worker also stops between packets when its chunk leaves the active window or playback mode.
  A chunk overtaken by uninterrupted reverse playback still contributes to the decode-level estimate. When
  their plans are full the workers sleep on focus, budget, cache-tier, and sibling progress events. The backward
  worker retains its single jump-settle deadline. A waiting decoder arms a one-shot notification when enough
  of its pixel buffers are released to return its pool.
  The window owns a single web-open generation shared by File → Open URL,
  the external `framescrub://open?url=` handler, Recent, and plugin bridge opens. It resolves pages on a serial worker
  and prepares the selected stream off the main thread while leaving the active player in place. Replacing an open
  cancels extraction or closes both caches. Late preparation is discarded. External URLs and plugin `open({page})`
  resolve pages through the same route. Plugin `open({url})` is explicit direct media.

  The resolver tries installed yt-dlp then gallery-dl, classifies bounded diagnostics, and reports stable item
  identifiers and selected-format metadata. The window opens a specific item from Recent and never stores the signed
  media addresses there. Core uses a page and item key for resume and marks, and reports the advertised format
  in Info. Direct media started through the web path leaves no durable playback record. A terminal read failure
  reaches the window while the current picture is still available. Reconnect resolves again with the last displayed
  time and previous play/pause state. Split HTTP tracks have separate range caches and align to the same clock.
  Extracted videos keep a nominal timeline to avoid a full remote index scan.
  The playback VideoToolbox decoder requests native lossless packed 10-bit surfaces for supported HEVC 4:2:0
  Main10 sources. It falls back to ordinary P010 on session or output incompatibility. The cache charges native
  packed surfaces by IOSurface allocation size. Separate decoders for exports, analysis and thumbnails retain their
  conventional output. The inspector fetches conventional luma on its bounded worker when its displayed source is
  packed. Core Image consumes packed surfaces directly; temporal denoising can pass native buffers to its matching
  configuration without a transfer copy.
  For NV12, `FrameCache` protects the focus and its ready neighbors. Distant frames can move to immutable
  `PackedNV12Frame` payloads using an independent lossless block codec with SIMD on arm64. Packed and ready
  entries share one byte budget and eviction policy. A packed entry counts as resident when planning decodes and
  displaying cached ranges. A lookup that needs immediate pixels returns only a ready surface. A serial foreground
  restore queue prioritizes the current target, then neighboring frames, and publishes through the filler's normal
  insertion callback. One utility compression job can be in flight. It yields when the focus is missing or a
  restore is pending. Both workers do pixel work outside the cache lock and validate the entry and current focus
  before publication. Restored NV12 surfaces stay ready farther from the playhead before becoming eligible
  for packing again. Both tiers remain subject to the same byte budget. Stop and index invalidation prevent
  stale work from repopulating the cache.
  With an exact index, the filler supplies the clip's frame count and its planning fraction. The cache skips
  new software NV12 compression while the entire clip fits that share of the byte budget at the largest
  observed decoded-frame size. Existing packed entries still restore on demand. Budget, index or frame-size
  changes can re-enable compression. Native packed Main10 remains a decoder output format.
  [Live scrub measurements](bench/live-scrub-cache.md) record the production cache and fill behavior.
- Paused scrubbing takes ready pixels directly from the cache. Only a missing target needs a stand-in lookup.
  The seek bar reuses its resident ranges until a frame enters or leaves the cache. Moving between packed
  and ready storage preserves those ranges.
- Paused audio uses a separate `ScrubAudio` decoder and a bounded PCM window. The picture on screen
  primes that window when audio attaches and when playback pauses. The worker wakes on transport or picture
  changes, continues a contiguous decode without seeking again and fills tape extensions in batches for
  local media. Pause-to-play, mute and distant jumps can stop an extension between decoded buffers. Snippet
  readiness checks coverage only. The worker prepares immutable tape snapshots outside the shared lock,
  copies PCM in contiguous spans and applies fades at the edges of those spans. The audio render thread
  uses the latest available snapshot without waiting for the worker. A reversed frame step seeds a bounded
  velocity estimate with the new sign while the regular averaging span fills.
- Browser → `FrameScrubHomeSource` → listings/posters/catalog → HomeScreenKit UI. Playlist navigation and
  persisted sort/history are application responsibilities at the integration boundary.
  File View uses HomeScreenKit's ordered multi-selection. The Edit menu and context menu exchange file URLs with
  Finder through the system clipboard. `FrameScrubHomeSource` dispatches one filesystem batch at a time to
  `FileViewFileActions` off the main thread. Moves update favorite folder paths, and completed changes refresh the
  affected listing through its existing subscription. Move and Trash report items still used by an export.
  Permanent deletion on volumes without a Trash requires confirmation.
  `FrameScrubHomeSource` builds the Favorites source and sidebar shortcuts from `FolderFavorites` (ordered paths
  in FrameScrub's defaults). Favorites requests the same folder covers as File View. Folder cards show available
  posters from the media catalog before listing any child folder. The background listing then supplies the summary
  and the normal identity-checked cover. Both passes discard results when the request is cancelled.
  Recursive browsing uses the same bounded listing worker and poster pipeline, with
  a separate active result and the opening folder tab as the playback return destination. MediaCatalog serves
  the last successful walk provisionally and replaces it once a fresh walk succeeds.
  Folder renames update favorite descendants. Mount changes and Refresh recheck availability with a bounded utility worker pool
  and repaint the sidebar without changing the browser's location.
  HomeScreenKit owns the opt-in File View tab histories. `PlayerWindowController` records the opening tab ID
  for playback return and saves a versioned tab snapshot in the user-state termination flush. At launch or on
  File › Last Session, the previous run's snapshot supplies the tabs to restore. Explicit file opens use the same
  player and take precedence over session restore.
  The playlist capsule's options menu changes `playlist-view` through the shared `PreferencesStore`.
  Configuration application switches the existing list/strip views and keeps the menu and Settings in sync.
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
  hidden, and reconciles again on return. Folder enumeration and metadata use up to two utility reads so a blocked
  stale read can yield to the selected tab. There is one replaceable pending request, reads for a listing are serial,
  and stale results are discarded. View › Refresh (⌘R) uses the same listing stream.
  Thumbnail workers report failure as well as success. `PictureQueue` finishes failed jobs and suppresses repeated
  attempts until refresh; confirmed damaged versions are marked in shared `UnreadableFiles` and omitted from Home.
  Failure stamps come from the attempted file identity; network/read errors do not mark files damaged. Source
  updates and new filesystem events preserve a user pause of thumbnail generation.
- Plugin page → `PluginPanel` / bridge → core plugin messages/policies/actions → application/player commands.
  Keep external page data separate from trusted application configuration.
  An open link registers its plugin as a session-only tab choice. It does not reveal a slot, switch tabs,
  or navigate a configured page.
- A configured plugin can register a same-origin HTTP cut catalog. `PluginCatalogSource` owns the listing,
  image and cut requests. File View uses its ordinary collection cards and cancels image work when leaving.
  Registration is scoped to the live configured page. The host checks limits, origins, source open policy and
  file fingerprints before playback. `VirtualCutTimeline` resolves overlaps while retaining authored IDs for
  resume. `VirtualCutPlayback` owns pending seek generations and cross-source transitions; the window
  routes the virtual timeline to its existing `PlayerCore`. Core holds the active file's frame and audio
  bounds, and suppresses source resume writes. One upcoming source may be prepared on a utility queue
  when foreground reads are ready. Closing or changing target cancels obsolete preparation. The provider
  owns analysis, shared draft persistence, revisions and previews, outside the player process.
  An open cut is an immutable provider snapshot. The catalog builds and validates its timeline once off the
  main actor. Native playback does not query the provider to seek or to advance.
  File View stays visible until the first target picture has been queued for rendering. Source changes keep the last
  picture and window frame, then apply the new source's fitted geometry with its first frame. Cut failures
  distinguish resolution, file open and first-picture errors. Source opens within a cut do not send the plugin
  an original-scene event; plugin state and seeks use cut seconds until the user opens an original.
  A first target missing on the approximate index can advance to a decodable frame within the same span,
  or retry the requested source time when the exact index arrives. A new target supersedes that retry.
  A cut retains exact indexes for up to four recently used, fingerprinted sources and caps timestamp storage
  at approximately 8 MiB. Reopening a source still verifies the file; an index hit avoids scanning it again.
  The cut filmstrip marks joins in cut time and retains bounded in-range samples across source opens.
  It can reuse the upcoming source's verified byte cache for one representative frame. The active filmstrip
  reader and upcoming preview share a utility read slot, gated by foreground readiness and visibility.
  For a source with a retained exact index, the upcoming preview can also retain one decoded landing frame
  up to 32 MiB. The player seeds its cache only if the live seek resolves to that same frame and timestamp.
  Playback requests at most one cold visible sample per span; further cold detail is filled while paused.
  A source editor can publish unlocked segments to show its ranges and dim the rest of the source timeline.
  A numbered filmstrip marker sends an explicit edit event to the owning catalog page with the authored row ID.
  Original context verifies the source fingerprint and opens at the row's source time. The owning editor can
  publish the selected authored row's bounds separately from the merged guides. The player previews a dragged
  edge on the exact source frame index and emits one commit to that editor on release. The editor owns the draft
  and saves it. On return, the host can read the requested revision from the same catalog and remap the row ID
  and source time onto its timeline.
  An unrelated media open invalidates the context, so a late reply cannot replace that media.
  Live analysis is provider-owned too. A configured page can request the current original file's fingerprint
  on demand. The host reuses the open read cache, reads only the fingerprint blocks on a utility worker, and
  invalidates the open token on source changes. The page matches the fingerprint to the provider's job before
  publishing checked intervals and provisional or refined findings. The timeline renders those snapshots in a
  separate layer. A marker click goes to the page that supplied it. Updating the layer does not change transport
  state or the ordinary segment lock. While a job runs and the video window is visible, the host periodically
  signals the owning page to refresh. The page polls with at most one request in flight. Completion, source
  change or window occlusion stops refresh signals and restores the default WebKit scheduling.
  A continuous gesture keeps one replaceable cross-source seek. Same-source targets and explicit moves execute at
  once; pointer-up flushes a queued seek, and a paused Home retains the target without starting an open.
  Dragging the cut filmstrip keeps its pointer-down projection in cut time. Source-file inertia and its cached
  frame previews stay on the original file timeline, where a cached frame has an unambiguous source index.

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

`FileOpenPreparation` owns ordinary file preparation per player window. Two dispatch workers allow a new open past
one stuck filesystem call. One replaceable request waits for a slot. A displaced request completes once on the main
actor even while its worker is still blocked. The worker retains its slot until it returns and discards any stale
result. Cancellation stops further metadata warmup after a blocked call returns. The controller still checks the
generation before applying the answer. A prepared virtual fragment goes directly to playback. Web stream selection
and preparation keep the current playback until a replacement is ready.

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

`PlaybackThumbnailWriter` snapshots the displayed image, geometry and file identity when leaving playback. A serial
utility worker saves one snapshot at a time. Two pending snapshots hold the latest distinct identities, with older
ones dropped under load. Home can show immediately and the existing Recent picture queue updates the card by ID
after the save. Generated Recent thumbnails fill missing entries, and an older in-flight card read cannot replace
the newly published picture. Termination still awaits the separate user-state barrier. See the
[window lifecycle measurements](bench/2026-11-26-window-lifecycle.md).

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

FrameScrub uses MouseService 0.5 or later for the Ulanzi D100H. Enable the viewing profile in
`framescrub.conf` with `d100h=yes`. The active player window requests input through the shared MouseClient. Focus changes and connection loss cancel held gestures before they can run release actions.
`D100HViewingProfile` maps inputs to existing playback commands, with an independent GestureRouter for the
wheel's scroll and fast-scrub bindings. The clockwise turn produces the forward-scrub wheel delta.
`d100h-edge-offset` is a percentage (default 10). Set
`d100h-mute-detents=yes` to turn off the dial detents temporarily while the player has focus.

Opt-in `tourbox=yes` starts the app's `TourBoxBridge`: one Console Max/MSP client on loopback TCP 50500, one
32-byte asynchronous read in flight, with delivery and player commands on the main thread. Every byte is an event;
TCP read boundaries are not message boundaries. `FrameScrubCore/TourBoxRouter` owns held/consumed buttons,
one-shot hold deadlines, and independent Knob sensitivity/progressive acceleration (enabled by default).
Bare Knob uses a continuous bounded quadratic gain above the configurable pulse-rate threshold, with time-based
rise smoothing and immediate deceleration. Knob press toggles the existing `tourbox-accel` preference through
PreferencesStore with OSD feedback; mode changes reset motion without losing the held click/duplicate guard.
Tall+Knob changes volume and Short+Knob changes speed by default. The router swaps these two Knob
assignments when `tourbox-knob-modifiers-swap=yes`. Tall+Top toggles mute and Short+Top calls `PlayerCore.reversePlaybackDirection`,
preserving speed/pause and restarting/refocusing the reverse/forward clock path when playing. There is no coarse
multiplier. Modifier toggles act on each target down while the modifier stays held, consuming release taps.
Reversal, idle and modifiers reset velocity; tied batch timestamps cannot manufacture speed. Top uses
Core's existing temporary speed hold; keyboard and TourBox ownership are exclusive. Top+Tour switches profile and
consumes both taps. C1/C2 navigate on release or adjust per-file colour strength in Viewing; in Editing they set/edit
mark boundaries. `ColorMemory.addStrength(for:)` handles either auto colour or Vibrance with the same bounds,
per-file persistence and independent enable flags. The controller samples one arrival time per batch and routes
commands through existing player actions. Scroll emits timeline points: `SeekBarView.scrollFilm` shares the
horizontal trackpad's local scale and fractional target time, with a one-shot idle completion. Other position input
and TourBox cancellation reset that time to prevent stale jumps. The router applies `tourbox-scroll-invert` when
decoding Scroll pulses, so it also covers Tall+Scroll. Focus loss, Home, file/profile changes, disconnect
and shutdown restore held speed, cancel deadlines and cancel unfinished edge edits.
The bridge rejects extra clients and stops on disable/shutdown; it never polls or claims the USB device. The
separate event preset is generated from a locally supplied vendor Lite template; the keyboard preset remains intact.

The optional Everything Home source uses the `EverythingSearchUI` package and HomeScreenKit's page source.
The app opens resolved file URLs through its normal window controller. Folder results go to File View.
The page owns its search session and suspends requests off-screen. The shared package saves the latest search
and library in the host app’s preferences. The source appears when Network Everything has saved connection settings.

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

## Keys and Gestures

`PlayerWindowController` presents SettingsKit's `CheatSheetView` over the player window. The controller
routes Escape, Page Up/Down and ⌘F while the help is open. The search field handles typing, and the kit restores
the previous first responder on close. Opening the help ends held player input and suspends precision scrolling
over the picture. `ShortcutHelpContent` formats the same effective input map used for dispatch, including profile
layers and plugin actions available in slots. It shares command labels with Key Bindings and uses the same menu
shortcut list. Fixed video gestures are listed separately. Rebuilding the input map updates the sheet if open.
The auto colour and vibrance strength commands route from the input map through the controller to `ColorMemory`,
which stores each effect's strength for the open file.

## Gesture ownership

`GestureAxisLock` in Core fixes the first intentional scroll axis through momentum; a new non-momentum
begin resets it immediately. Phase-less scrolling re-arms after a 0.25 s gap. Loupe's `ViewerView` filters deltas
before button/folder/pan routing; FrameScrub's `GestureRouter` filters before command routing. Pointer right-drag
zoom and right-button scrolling keep their first owner until release. Button recognition ignores zero deltas;
middle-button scrolling must cross a wheel step (12 precise points or one notched unit) before cancelling a click.
On the standalone video surface, `VideoView` observes indirect touches and the primary trackpad press.
`HeldTrackpadSwipe` claims the press when three fingers are down and recognizes horizontal motion from either
the touch centroid or precise scroll. The first stream to establish the axis owns the press. The controller
dispatches the existing playlist commands, and a change of direction can step back within the same press.
`VideoView` cancels any tentative picture pan when the swipe takes over. Releasing the button ends navigation,
and the recognizer consumes the remaining scroll and momentum. Focus loss, hiding and touch cancellation clear it.
Over the video, optional trackpad scrub momentum keeps only the tail of an owned horizontal scrub. The router
passes native deltas through the existing frame accumulator and seek path. The momentum distance setting scales
only the released movement before frame rounding, preserving the system's deceleration.
State is local to the existing input owners; no polling, new queues or dependencies are introduced.
On the video, `VideoView` recognizes a three-finger double tap from indirect touch events and routes it to the
window's existing full-screen command. Force Click uses AppKit's stage 2 pressure event to toggle the existing
information panel once per press. The view dispatches the ordinary double-click binding on release, after it can
tell which presses became force clicks. Showing Home or losing window focus clears gesture state.
