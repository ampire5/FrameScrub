import Foundation
import InfoPanelModel
import os
import QuartzCore

/// Where the frame index came from (spec §5).
public enum IndexStatus: Equatable, Sendable {
    case approximate, scanning(Double), scanned(seconds: Double), container(seconds: Double), failed

    public var text: String {
        switch self {
        case .approximate: return "Index: approximate"
        case let .scanning(f): return "Index: scanning \(Int(f * 100))%"
        case let .scanned(s): return String(format: "Index: scan (%.1f s)", s)
        case let .container(s): return String(format: "Index: container (%.2f s)", s)
        case .failed: return "Index: approximate (scan failed)"
        }
    }
}

public protocol PlayerCoreDelegate: AnyObject {
    func player(_ player: PlayerCore, display frame: DecodedFrame)
    func playerStateDidChange(_ player: PlayerCore)
    func player(_ player: PlayerCore, showOSD text: String)
    func playerDidReachEnd(_ player: PlayerCore)
    func player(_ player: PlayerCore, copyImage data: Data, frame: Int, note: String?)
    func player(_ player: PlayerCore, showFeedback feedback: Feedback)
}

public extension PlayerCoreDelegate {
    func playerDidReachEnd(_ player: PlayerCore) {}
    func player(_ player: PlayerCore, showFeedback feedback: Feedback) {}
    func player(_ player: PlayerCore, copyImage data: Data, frame: Int, note: String?) {}
}

/// The player state machine. Main thread only. Owns the cache and its filler, audio, the
/// playback clock and export; the UI forwards commands and draws what the delegate is given.
public final class PlayerCore {
    public weak var delegate: PlayerCoreDelegate?
    /// Writes the A-B clips (`c`); set by the app.
    public var clipQueue: ClipQueue?
    /// Called on the main thread when the exact frame index replaces the approximate one.
    public var onIndexReady: ((FrameIndex) -> Void)?
    /// Called on the main thread with the fraction of the file the index scan has read (spec §2.2).
    public var onIndexProgress: ((Double) -> Void)?
    /// Called on the main thread for each haptic event the player causes (mouse spec §5, §6).
    public var onHaptic: ((HapticEvent) -> Void)?
    /// Called on the main thread for the `.step` of a `seek ±N` that moved: the app plays it for mouse input only (the
    /// side wheel, a button), never for a key or its auto-repeat (`HapticSource.plays`). `.end` goes to `onHaptic`.
    public var onSeekHaptic: ((HapticEvent) -> Void)?
    /// The command or scrub about to run comes from a fresh press (not a key auto-repeat; a wheel notch after
    /// `EndBump.wheelPause`): a step against the first / last frame bumps again. Set by the app before `perform` / `scrub`.
    public var inputIsFresh = true
    public private(set) var config: Config
    /// Pixel size of the screen the window is on, for `save-scale=fit` / `export-scale=fit`.
    public var screenPixelSize: CGSize? {
        didSet { if oldValue != screenPixelSize { rebuildExporter() } }
    }
    /// The colour correction on screen; saved frames get it with `save-color=yes`.
    public var colorCorrection = ColorCorrection.identity {
        didSet { if config.saveColor { rebuildExporter() } }   // `apply` rebuilds it when save-color changes
    }
    /// The on-screen crop and pixel aspect; saved and copied frames get it too.
    public var displayGeometry = DisplayGeometry.identity {
        didSet { if oldValue != displayGeometry { rebuildExporter() } }
    }
    private var baseBudget: Int
    /// 1, or less while the system is short of memory (`watchMemoryPressure`).
    private var pressureFactor = 1.0
    public let cache: FrameCache
    public let clock: PlaybackClock

    public private(set) var url: URL?
    /// What the page that opened the file says about it (`SceneInfo`): a stream's frames and clips are named after it.
    /// Set after an open; an open or a close clears it.
    public var sceneInfo: SceneInfo? { didSet { if sceneInfo != oldValue { rebuildExporter() } } }
    public private(set) var info: MediaSource?
    /// The open file's shared reads (spec §4).
    public private(set) var readCache: ReadCache?
    /// How hard the open file may be read (`network-mode` and the file's volume), decided when it opens.
    public private(set) var networkPolicy = NetworkPolicy.local
    public private(set) var index: FrameIndex?
    public private(set) var position = 0
    public private(set) var isPaused = true
    public private(set) var speed = 1.0
    /// +1 forward, −1 backward (reverse playback spec §2); while paused, the way playback goes on.
    public private(set) var direction = 1
    /// The speed came from the shuttle (2, 4, 8×): Space after a pause plays on at 1×, a speed set with [ ] stays.
    private var shuttleSpeed = false
    /// When frames reached the screen during playback, for "shown N fps" in the stats.
    private var shownTimes: [Double] = []
    public private(set) var volume: Double
    public private(set) var isMuted = false
    public private(set) var loopA: Int? { didSet { syncCacheRegions() } }
    public private(set) var loopB: Int? { didSet { syncCacheRegions() } }
    /// The segments of the open file the playhead is kept inside while `segmentsLocked` (segment lock spec §1); nil
    /// without any, or before the file has an index. Built from `segmentsSource` with the current index.
    public private(set) var segments: SegmentSet? { didSet { syncCacheRegions() } }
    /// Moves are held inside `segments` and playback repeats or advances through them. Not remembered for the file.
    public private(set) var segmentsLocked = false { didSet { syncCacheRegions() } }
    /// What playback does at the end of a locked segment.
    public private(set) var segmentAdvance: SegmentAdvance { didSet { syncCacheRegions() } }
    /// Called on the main thread when the segment containing the playhead or the lock changes.
    public var onSegmentChange: ((_ current: Int?, _ locked: Bool) -> Void)?
    /// The segments as given, in seconds: the frames are counted again from them when the exact index arrives.
    private var segmentsSource: [ClosedRange<Double>] = []
    /// The last `(currentSegment, segmentsLocked)` passed to `onSegmentChange`.
    private var announcedSegment: (current: Int?, locked: Bool) = (nil, false)
    /// Cut marks of the open file (cut marks spec §2) and their ⌘Z history.
    public private(set) var marks = CutMarks()
    private var marksHistory = CutHistory()
    public var canUndoMarks: Bool { marksHistory.canUndo }
    public var canRedoMarks: Bool { marksHistory.canRedo }
    /// The live `scrub-edge` drag (mouse spec §5.4); `marks` shows its moving edge meanwhile.
    public private(set) var edgeDrag: EdgeDrag?
    /// The last step of the edge drag stopped at a bound of `edgeDrag.allowed`: `.limit` was played for this arrival.
    private var edgeAtLimit = false
    /// `haptic-end` once per push against the first / last frame.
    private var endBump = EndBump()
    /// Keyframe / mark ticks of the plain wheel scrub and the edge drag, at most one per 40 ms.
    private var scrubTicks = ScrubTicks()
    /// `P`: playback jumps over everything outside the marks and pauses after the last (spec §5); off for each new file.
    public private(set) var playMarksOnly = false
    public private(set) var displayedFrame: Int?
    /// Seek latencies (spec §5).
    public private(set) var seekTimer = SeekTimer()
    public private(set) var indexStatus = IndexStatus.approximate
    public var isExporting: Bool { exportFlag != nil }
    public var hasAudio: Bool { audio != nil }
    var hasScrubAudio: Bool { scrubAudio != nil }
    /// The time-pitch rate of the sound, nil without sound (tests).
    var audioRate: Float? { audio?.rate }
    /// Tests: how often the playback sound was (re)started.
    var audioPlayCalls: Int { audio?.playCalls ?? 0 }

    private let enableAudio: Bool
    private let fallbackRoot: URL
    private let resumeStore: ResumeStore?
    /// The bytes of a URL about to open; the default reads a file, or Stash's stream with its API key.
    private let byteSource: (URL, Config) throws -> ByteSource
    private let now: () -> Double
    private var filler: CacheFiller?
    private var exporter: FrameExporter?
    private var exportFlag: CancellationFlag?
    private var indexFlag: CancellationFlag?
    private var audio: AudioOutput?
    /// Playing, but the clock waits for the file's first picture (`restartClock`).
    private var clockWaitsForPicture = false
    private let audioSetupQueue = DispatchQueue(label: "framescrub.audio-setup", qos: .userInitiated)
    private static let audioLog = Logger(subsystem: "local.framescrub", category: "Audio")
    /// A piece of sound on every frame change in pause (scrub audio spec).
    private var scrubAudio: ScrubAudio?
    /// Tests: where scrub audio pieces go instead of the playback audio's engine.
    var snippetSinkOverride: SnippetSink?
    private var pendingScreenshot: Int?
    private var pendingCopy: Int?
    public private(set) var savedCount = 0
    public private(set) var lastSavedURL: URL?

    /// What "show frames in Finder" opens: the last saved file, else the video's frame folder if it exists.
    public var revealTarget: URL? {
        if let lastSavedURL { return lastSavedURL }
        guard let exporter else { return nil }
        let folder = exporter.settings.naming.directory(forVideo: exporter.nameURL)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
    private var frameOSDPending = false
    /// Sharpness of the shown frame for the stats (sharp export spec §5), and the share of its picture that changed
    /// since the frame measured before it (export dedupe spec §5), measured off the main thread.
    private var sharpness: (session: Int, frame: Int, score: Double?, change: Double?)?
    /// Signature of the last frame measured for the stats.
    private var statsSignature: (session: Int, signature: SceneSignature)?
    private var sharpnessPending: (session: Int, frame: Int)?
    private let sharpnessQueue = DispatchQueue(label: "framescrub.sharpness", qos: .utility)
    private var decodeErrorShown = false
    private(set) var session = 0
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// Tests only: skip building the exact index, so seeks run against the approximate one.
    var keepApproximateIndex = false
    /// Id of the keyframe seek whose landing may still move the position (spec §2.3); bumped by every
    /// other seek so a late landing never moves the user.
    private(set) var landingID = 0
    /// Direction of the running seek series (spec §3.2): frames that arrive on the way are shown only if
    /// they move the picture this way.
    var seekDirection = 1
    /// `revert-seek` (mpv): where the last seek series started. Frame steps are not seeks.
    private var revertPoint: Int?
    private var lastSeekAt = -Double.infinity
    /// Seeks closer together than this (holding an arrow key, dragging the bar) form one series.
    static let seekSeriesGap = 1.0

    /// Frames farther than this from the target are not shown as stand-ins while decoding.
    private static let standInDistance = 300

    public init(config: Config, enableAudio: Bool = true, fallbackRoot: URL = FrameNaming.defaultFallbackRoot,
                now: @escaping () -> Double = CACurrentMediaTime, resumeStore: ResumeStore? = nil,
                byteSource: @escaping (URL, Config) throws -> ByteSource = {
                    try ByteSources.open($0, headers: StashOpenPolicy.headers(for: $0, config: $1))
                }) {
        self.config = config
        self.byteSource = byteSource
        self.now = now
        self.enableAudio = enableAudio
        self.fallbackRoot = fallbackRoot
        self.resumeStore = resumeStore
        baseBudget = config.cacheSizeMiB << 20
        cache = FrameCache(budgetBytes: baseBudget)
        clock = PlaybackClock(now: now)
        volume = config.volume
        segmentAdvance = config.segmentAdvance
        watchMemoryPressure()
    }

    deinit {
        memoryPressure?.cancel()
        close()
    }

    public var frameCount: Int { index?.frameCount ?? 0 }
    public var currentSeconds: Double { index?.seconds(forFrame: position) ?? 0 }
    public var durationSeconds: Double { info?.durationSeconds ?? 0 }

    // MARK: Opening

    /// Opens `url`; `fallbackPosition` (seconds) is where to start when nothing is remembered for the file (Stash's
    /// resume point, Stash spec §2.3).
    public func open(_ url: URL, fallbackPosition: Double? = nil) throws {
        open(try preparation(for: url)(), fallbackPosition: fallbackPosition)
    }

    /// The part of opening `url` that reads it (the volume, the byte source, the read cache, the first probe), as work
    /// that touches no player state: the caller may run it on another thread and hand the result to `open(_:)`.
    /// Making it touches nothing: even the volume's kind (a `statfs`, which waits for an SMB server) is asked when it
    /// runs. `cancellation` stops it while it reads.
    public func preparation(for url: URL, cancellation: OpenCancellation? = nil) -> @Sendable () throws -> PreparedOpen {
        let config = config, factor = pressureFactor
        nonisolated(unsafe) let byteSource = byteSource
        return {
            let policy = NetworkPolicy.resolve(config.networkMode, url: url)
            let budget = Self.readCacheBudget(config: config, policy: policy, factor: factor)
            let readCache = try ReadCache(url: url, budgetBytes: budget, source: byteSource(url, config))
            try cancellation?.watch(readCache)
            let source = try MediaSource(url: url, readCache: readCache)
            readCache.probe = StreamProbe(source)
            return PreparedOpen(url: url, policy: policy, readCache: readCache, source: source)
        }
    }

    /// Opens a file `preparation(for:)` read; the file open until now is left.
    public func open(_ prepared: PreparedOpen, fallbackPosition: Double? = nil) {
        let url = prepared.url, readCache = prepared.readCache, source = prepared.source
        networkPolicy = prepared.policy
        StartupTrace.mark("probe done")
        readCache.readAheadBytes = min(Int(source.bytesPerSecond * networkPolicy.readAheadSeconds), readCacheBudget(1) / 2)
        // Segments given while no file was open are for this one; those of the file open now go with it.
        let pendingSegments = index == nil && !segmentsSource.isEmpty
            ? (seconds: segmentsSource, locked: segmentsLocked, advance: segmentAdvance) : nil
        close(announcing: pendingSegments == nil)   // restored segments are announced once, by the first seek
        session += 1
        let current = session
        let approximate = source.approximateIndex()
        self.url = url
        self.readCache = readCache
        info = source
        index = approximate
        if let pendingSegments {
            segmentsSource = pendingSegments.seconds
            segmentAdvance = pendingSegments.advance
            rebuildSegments()
            segmentsLocked = pendingSegments.locked && segments != nil   // all past the end: nothing to lock to
        }
        revertPoint = nil
        lastSeekAt = -.infinity
        endBump = EndBump()

        let filler = CacheFiller(url: url, index: approximate, cache: cache,
                                 estimatedFrameBytes: source.estimatedFrameBytes,
                                 playbackLookahead: max(8, Int(source.frameRate * 2)),
                                 preferHardware: config.hwdec.prefersHardware, readCache: readCache,
                                 policy: networkPolicy, frameRate: source.frameRate)
        filler.onInsert = { [weak self] n in
            DispatchQueue.main.async { self?.frameInserted(n, session: current) }
        }
        filler.onError = { [weak self] error in
            DispatchQueue.main.async { self?.decodeFailed(error, session: current) }
        }
        filler.onLanded = { [weak self] id, n in
            DispatchQueue.main.async { self?.landed(id, n, session: current) }
        }
        filler.start()
        self.filler = filler
        syncCacheRegions()

        rebuildExporter()
        if source.audioStreamIndex != nil {
            setUpAudioInBackground(url, zeroSeconds: Double(source.startPTS) * source.timeBase, readCache: readCache,
                                   session: current)
        }
        // keep-speed: the speed the user chose goes on; the shuttle's and a hold's are only for the file they began in.
        let kept = config.keepSpeed ? (shuttleSpeed ? 1 : heldFrom?.speed ?? speed) : 1
        heldFrom = nil   // the hold's key-up after the open has nothing to put back
        let willHaveSound = enableAudio && source.audioStreamIndex != nil   // the sound comes in later: its range now
        let range = willHaveSound ? AudioOutput.rateRange : 0.01...100
        speed = min(max(kept, range.lowerBound), range.upperBound)
        direction = 1
        shuttleSpeed = false
        clock.rate = speed   // the sound takes it when it comes in (`attachAudio`)
        clock.followsAudio = true
        buildIndexInBackground(url, readCache: readCache, session: current)
        seek(toFrame: 0)
        resumeIfRemembered(url, fallback: fallbackPosition)
        if config.autoplay { play() }
        if speed != 1 { feedback(.speed(speed)) }   // a kept speed is shown, so a faster file is no surprise
    }

    public func close() {
        close(announcing: true)
    }

    /// `announcing` false: `onSegmentChange` is left for the caller (`open` restoring segments given before it).
    private func close(announcing: Bool) {
        cancelEdgeDrag()   // before the marks are remembered: the drag never reached them
        rememberPosition()
        exportFlag?.cancel()
        exportFlag = nil
        indexFlag?.cancel()
        indexFlag = nil
        filler?.stop(waitForExit: false)   // never block the UI thread on decoders
        filler = nil
        audio?.stop()
        audio = nil
        scrubAudio?.stop()
        scrubAudio = nil
        clock.audioSeconds = nil
        clock.audioStarting = nil
        clock.stop()
        cache.removeAll()
        readCache?.close()
        readCache = nil
        url = nil
        sceneInfo = nil
        info = nil
        index = nil
        exporter = nil
        pendingScreenshot = nil
        pendingCopy = nil
        savedCount = 0
        lastSavedURL = nil
        decodeErrorShown = false
        loopA = nil
        loopB = nil
        marks = CutMarks()
        marksHistory = CutHistory()
        playMarksOnly = false
        segmentsSource = []
        segments = nil
        segmentsLocked = false
        segmentAdvance = config.segmentAdvance
        position = 0
        isPaused = true
        displayedFrame = nil
        clockWaitsForPicture = false
        seekTimer = SeekTimer()
        indexStatus = .approximate
        session += 1
        if announcing { announceSegment() }
    }

    /// Applies new settings while running (Preferences): cache budget, export settings and seek mode
    /// take effect immediately.
    public func apply(_ newConfig: Config) {
        if newConfig.volume != config.volume {
            volume = newConfig.volume
            applyVolume()
        }
        let cacheChanged = newConfig.cacheSizeMiB != config.cacheSizeMiB
        config = newConfig
        applyScrubAudioSettings()
        filler?.preferHardware = newConfig.hwdec.prefersHardware
        if cacheChanged {
            baseBudget = newConfig.cacheSizeMiB << 20
            setMemoryPressureFactor(pressureFactor)   // keeps a budget lowered by memory pressure
        }
        rebuildExporter()
    }

    private func rebuildExporter() {
        guard let url, let info else { return }
        exporter = FrameExporter(videoURL: url, nameURL: sceneInfo?.namingURL(for: url), rotationClockwise: info.rotationClockwise,
                                 settings: ExportSettings(config: config, fallbackRoot: fallbackRoot,
                                                          screenPixels: screenPixelSize, color: colorCorrection,
                                                          geometry: displayGeometry),
                                 readCache: readCache)
    }

    /// Seek-bar click or drag: lands on the keyframe nearest the target when `seek-mode=keyframe`
    /// (no direction rule, so every drag event over the same spot lands on the same frame).
    public func seekFromBar(toFrame n: Int) {
        scrubAudio?.userActed()
        guard let index else { return }
        noteSeek()
        seekTimer.start(at: now())
        seekDirection = n < position ? -1 : 1
        var target = n
        if usesKeyframes(.byConfig), !index.isExact {
            seekToKeyframe(toward: n, direction: n < position ? -1 : 1, hold: .nearest)
            return
        }
        if usesKeyframes(.byConfig), let keyframe = index.keyframeSeekTarget(from: position, toward: n, direction: 0),
           snapsToKeyframe(keyframe) {
            target = keyframe
        }
        seek(toFrame: target, direction: target < position ? -1 : 1, hold: .nearest)
    }

    /// Spec §2.3, keyframe seeks before the exact index is known: the position moves to `target` for now and
    /// the forward decoder finds the keyframe beyond the current frame in `direction`; `landed` moves there.
    private func seekToKeyframe(toward target: Int, direction: Int, hold: SegmentHold = .glued) {
        landingID += 1
        readCache?.cancelReadAhead()
        filler?.requestKeyframe(id: landingID, toward: target, from: position, direction: direction)
        move(toFrame: target, direction: direction, hold: hold)
    }

    func landed(_ id: Int, _ n: Int, session current: Int) {
        guard current == session, id == landingID, let index else { return }
        let frame = min(max(n, 0), max(index.frameCount - 1, 0))
        // A keyframe outside the locked segments: the seek stays on its target, held inside them (exactness inside the
        // segments beats the keyframe).
        if let segments = lockedSegments, segments.index(containing: frame) == nil { return }
        position = frame
        refocus(direction: 0)
        if !isPaused { restartClock() }
        showCurrent()
        osd(progressText + " K")
        announceSegment()
    }

    /// Opening the audio decoders and starting the engine takes 0.1–0.5 s (two probes of the file, the audio
    /// device), so it is done beside the video; playback that started meanwhile picks the sound up when it is ready.
    private func setUpAudioInBackground(_ url: URL, zeroSeconds zero: Double, readCache: ReadCache, session current: Int) {
        let withOutput = enableAudio
        let withScrub = enableAudio || snippetSinkOverride != nil
        audioSetupQueue.async { [weak self] in
            var output: AudioOutput?
            if withOutput {
                do {
                    output = try AudioOutput(decoder: AudioDecoder(url: url, zeroSeconds: zero, readCache: readCache))
                } catch {
                    Self.audioLog.error("Audio: no sound for the file: \(error, privacy: .public)")
                }
            }
            let scrubDecoder = withScrub ? try? AudioDecoder(url: url, zeroSeconds: zero, readCache: readCache) : nil
            StartupTrace.mark("audio ready")
            DispatchQueue.main.async {
                guard let self, current == self.session else { output?.stop(); return }
                self.attachAudio(output, scrubDecoder: scrubDecoder)
            }
        }
    }

    private func attachAudio(_ output: AudioOutput?, scrubDecoder: AudioDecoder?) {
        audio = output
        clock.audioSeconds = output.map { output in { output.currentSeconds } }
        clock.audioStarting = output.map { output in { output.isStarting } }
        output?.onRestart = { [weak self, weak output] in
            guard let self, let output, self.audio === output, !self.isPaused else { return }
            self.restartClock()   // the queued sound went with the stopped engine: it starts again at the frame on screen
        }
        if let scrubDecoder, let sink: SnippetSink = snippetSinkOverride ?? output {
            let scrub = ScrubAudio(decoder: scrubDecoder, sink: sink, tape: snippetSinkOverride == nil ? output : nil,
                                   shouldYield: { [weak filler] in filler?.hasUnresolvedFocus ?? false })
            scrubAudio = scrub
            applyScrubAudioSettings()
            scrub.fileOpened()
            if !isPaused { scrub.playbackStarted() }
        }
        applySpeed(speed)   // the time-pitch unit narrows the range
        applyVolume()
        // Playing forward on the host clock: started again with the sound, so the clock holds until it is heard instead
        // of jumping back to it.
        if !isPaused, direction > 0, !clockWaitsForPicture, output != nil { restartClock() }
    }

    private func buildIndexInBackground(_ url: URL, readCache: ReadCache, session current: Int) {
        guard !keepApproximateIndex else { return }
        let flag = CancellationFlag()
        indexFlag = flag
        let thread = Thread { [weak self, weak filler] in
            let started = CACurrentMediaTime()
            if let fast = try? MediaSource.containerIndex(url: url, readCache: readCache) {
                let status = IndexStatus.container(seconds: CACurrentMediaTime() - started)
                DispatchQueue.main.async { self?.indexReady(fast, session: current, status: status) }
                return
            }
            DispatchQueue.main.async {
                guard let self, current == self.session else { return }
                self.indexStatus = .scanning(0)
            }
            let scanStarted = CACurrentMediaTime()
            let progress = { (fraction: Double) in
                DispatchQueue.main.async {
                    guard let self, current == self.session else { return }
                    self.indexStatus = .scanning(fraction)
                    self.onIndexProgress?(fraction)
                }
            }
            // Past the read cache: one pass over the whole file must not evict the blocks seeks use.
            guard let exact = try? MediaSource(url: url, readCache: readCache, cached: false).buildIndex(
                isCancelled: { flag.isCancelled },
                shouldYield: { filler?.hasUnresolvedFocus ?? false },
                progress: progress) else {
                DispatchQueue.main.async { self?.indexFailed(session: current) }
                return
            }
            let status = IndexStatus.scanned(seconds: CACurrentMediaTime() - scanStarted)
            DispatchQueue.main.async { self?.indexReady(exact, session: current, status: status) }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    private func indexFailed(session current: Int) {
        guard current == session else { return }
        indexStatus = .failed
    }

    /// The cache follows the A–B loop, else the locked segments (segment lock spec §3): frames outside them are wasted
    /// work and evict useful ones.
    private func syncCacheRegions() {
        if let a = loopA, let b = loopB {
            filler?.setRegions([min(a, b)...max(a, b)], advance: .repeating)
        } else {
            filler?.setRegions(lockedSegments?.ranges ?? [], advance: segmentAdvance)
        }
    }

    func indexReady(_ exact: FrameIndex, session current: Int, status: IndexStatus) {
        // A scan that found no frames (odd container) is useless: keep the approximate index.
        guard current == session else { return }
        guard exact.frameCount > 0, let old = index, let filler else { indexStatus = .failed; return }
        indexStatus = status
        let unchanged = old.agrees(with: exact)
        if !unchanged {
            let remap = { (n: Int) in exact.nearestFrameNumber(forPTS: old.pts(forFrame: n)) }
            position = remap(position)
            loopA = loopA.map(remap)
            loopB = loopB.map(remap)
            marks = marks.mapped(remap)
            marksHistory = CutHistory()   // earlier states count frames of the old index
            edgeDrag = nil                // so does its original; the next wheel step begins anew from the moved edge
            pendingScreenshot = pendingScreenshot.map(remap)
            pendingCopy = pendingCopy.map(remap)
            displayedFrame = nil
        }
        index = exact
        rebuildSegments()   // from the seconds given, not remapped: the exact frames of those times
        if let segments = lockedSegments { position = segments.nearest(position) }
        StartupTrace.mark("exact index ready")
        if !unchanged { landingID += 1 }   // a pending landing counts frames of the old index
        filler.updateIndex(exact, clearCache: !unchanged)
        refocus(direction: 0)
        showCurrent()
        announceSegment()
        onIndexReady?(exact)
    }

    // MARK: Transport

    public func play() {
        guard let index else { return }
        if shuttleSpeed { applySpeed(1) }   // Space after the shuttle: 1× (spec §2)
        let loop = playbackLoop
        if playMarksOnly, lockedSegments == nil,
           let start = PlaybackEdges.markStart(position: position, direction: direction, marks: marks.segments) {
            seek(toFrame: start)
        } else if config.abLoop == .once, let loop, position == (direction > 0 ? loop.upperBound : loop.lowerBound) {
            // stopped on B (backward: on A), or on a repeated segment's end: the range starts over
            seek(toFrame: direction > 0 ? loop.lowerBound : loop.upperBound)
        } else if direction > 0 ? position >= index.frameCount - 1 : position <= 0 {
            if let segments = lockedSegments {
                // At the end of the file (backward: its start) in the segments: `next` starts over from the first
                // (backward: the end of the last), `repeat` from the start (end) of the loop or the current segment.
                let ranges = segments.ranges
                let range = segmentAdvance == .next && loopRange == nil
                    ? (direction > 0 ? ranges[0] : ranges[ranges.count - 1]) : playbackLoop ?? ranges[0]
                seek(toFrame: direction > 0 ? range.lowerBound : range.upperBound)
            } else {
                position = direction > 0 ? 0 : index.frameCount - 1
            }
        }
        isPaused = false
        scrubAudio?.playbackStarted()
        refocus(direction: direction)
        restartClock()
        showCurrent()
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        clockWaitsForPicture = false
        clock.stop()
        audio?.pause()
        scrubAudio?.playbackStopped()
        refocus(direction: 0)
        showCurrent()
    }

    /// While the segments are locked the target is held inside them (`SegmentHold.glued`: relative moves such as a
    /// step, a seek by some seconds, a revert or a scene jump). Absolute targets (`seek(toSeconds:)`, `goTo`) take the
    /// nearest edge.
    public func seek(toFrame n: Int, direction: Int = 0) {
        seek(toFrame: n, direction: direction, hold: .glued)
    }

    private func seek(toFrame n: Int, direction: Int, hold: SegmentHold) {
        landingID += 1
        readCache?.cancelReadAhead()   // blocks queued for the old position would delay this one
        move(toFrame: n, direction: direction, hold: hold)
    }

    /// Every seek, step and scrub ends here, so each is held inside the locked segments.
    private func move(toFrame n: Int, direction: Int, hold: SegmentHold = .glued) {
        guard let index else { return }
        position = held(min(max(n, 0), max(index.frameCount - 1, 0)), hold: hold)
        refocus(direction: direction)
        if !isPaused { restartClock() }
        showCurrent()
        announceSegment()
    }

    /// Horizontal-scroll scrubbing: pauses and moves by `frames` (negative = backward). No keyframe / mark ticks.
    public func scrub(by frames: Int) {
        scrub(by: frames, ticks: false)
    }

    /// `scrub(by:)`; `ticks`: a plain (not fast, multiplier 1) mouse-wheel scrub, which plays `.mark` when it passes a
    /// mark edge, A or B and `.keyframe` when it passes a keyframe (spec §5.6).
    public func scrub(by frames: Int, ticks: Bool) {
        scrubAudio?.userActed()
        let from = position
        step(by: frames)
        if ticks { playScrubTick(from: from, marks: tickMarks) }
    }

    /// Every mark start and end, the open start, A and B: the frames a plain wheel scrub ticks on.
    private var tickMarks: [Int] {
        marks.segments.flatMap { [$0.start, $0.end] } + [marks.open, loopA, loopB].compactMap { $0 }
    }

    /// The tick of a scrub from `from` to the position: a passed frame of `marks`, else a passed keyframe of the
    /// exact index (an approximate one knows none), throttled by `ScrubTicks`.
    private func playScrubTick(from: Int, marks: [Int]) {
        guard let index, position != from else { return }
        if let event = scrubTicks.crossed(from: from, to: position, keyframes: index.isExact ? index.keyframes : [],
                                          marks: marks, at: now()) {
            haptic(event)
        }
    }

    /// Advances playback to the clock; call on every display refresh.
    public func tick() {
        checkPendingScreenshot()
        // Before the starting frame is on screen the clock stands still: following it would move off the start. The frame
        // may be in already (shown before the playhead came to it, or decoded unseen): it starts the clock here.
        if clockWaitsForPicture, !isPaused {
            if let frame = cache.frame(position), frame.number != displayedFrame { display(frame) }
            else if displayedFrame == position || cache.isUndecodable(position) { restartClock() }
        }
        guard !isPaused, !clockWaitsForPicture, let index else { return }
        let seconds = clock.seconds
        let n = index.frameNumber(forSeconds: max(seconds, 0))
        let last = index.frameCount - 1
        let atEnd = direction > 0 && n >= last && seconds >= index.seconds(forFrame: last) + 1 / (info?.frameRate ?? 30)
        let atStart = direction < 0 && seconds < index.seconds(forFrame: 0)
        // Locked segments without an A–B loop: `next` plays them as marks, round and round; `repeat` loops the current
        // one (`playbackLoop`). Play-marks-only waits while they are locked.
        let locked = lockedSegments
        let segmentMarks = locked != nil && loopRange == nil && segmentAdvance == .next
            ? locked?.ranges.map { CutSegment(start: $0.lowerBound, end: $0.upperBound) } : nil
        let edgeMarks = segmentMarks ?? (playMarksOnly && locked == nil ? marks.segments : nil)
        switch PlaybackEdges.decide(target: n, pastStart: atStart, pastEnd: atEnd, position: position, direction: direction,
                                    loop: playbackLoop, mode: config.abLoop, marks: edgeMarks, wrapMarks: segmentMarks != nil,
                                    frameCount: index.frameCount) {
        case .none:
            break
        case let .jump(frame):
            seek(toFrame: frame)
            return
        case let .pause(at: frame):
            seek(toFrame: frame)
            pause()
            feedback(.pause)
            return
        case let .turn(at: frame):   // ping-pong
            direction = -direction
            seek(toFrame: frame)
            return
        case .endOfFile:
            position = last
            pause()
            osd("End of file")
            feedback(.endOfFile)
            delegate?.playerDidReachEnd(self)
            return
        case .startOfFile:
            seek(toFrame: 0)
            pause()
            osd("Start of file")
            return
        }
        guard n != position else { return }
        position = n   // not held: the edges above keep playback inside the segments
        announceSegment()
        checkPendingScreenshot()
        filler?.setFocus(n, mode: direction < 0 ? .reversing : .playing, direction: direction)
        // Skipping frames (spec §3): the decoded frame nearest the clock between it and the one on screen, within two
        // seconds of the clock — further back is another place (a seek), not a skipped stretch.
        let reach = Int(2 * speed * (info?.frameRate ?? 30)) + 1
        let passed = displayedFrame.flatMap { shown -> ClosedRange<Int>? in
            direction < 0 ? (shown > n ? n...min(shown - 1, n + reach) : nil)
                : (shown < n ? max(shown + 1, n - reach)...n : nil)
        }
        if let frame = cache.frame(n) ?? passed.flatMap({ cache.nearest(to: n, within: $0) }), frame.number != displayedFrame {
            display(frame)
            noteShown()
        }
        delegate?.playerStateDidChange(self)
    }

    public func perform(_ command: Command) {
        scrubAudio?.userActed()
        switch command {
        case .cyclePause:
            isPaused ? play() : pause()
            feedback(isPaused ? .pause : .play)
        case let .seek(seconds, precision):
            seekRelative(seconds, precision: precision)
            feedback(.seek(seconds))
        case .frameStep: step(by: 1)
        case .frameBackStep: step(by: -1)
        case .keyframeStep: keyframeStep(1)
        case .keyframeBackStep: keyframeStep(-1)
        case .revertSeek: revertSeek()
        case let .multiplySpeed(factor): setSpeed(speed * factor)
        case let .stepSpeed(direction): stepSpeed(direction)
        case let .setSpeed(value): setSpeed(value)
        case let .addVolume(delta):
            let wanted = volume + delta
            volume = min(max(wanted, 0), 100)
            applyVolume()
            feedback(.volume(Int(volume)))
            haptic(wanted < 0 || wanted > 100 ? .limit : .step)
        case .cycleMute:
            isMuted.toggle()
            applyVolume()
            feedback(.mute(isMuted))
        case .abLoop: cycleABLoop()
        case .screenshot: screenshot()
        case .copyFrame: copyFrame()
        case .exportRange: toggleExport()
        case .saveClip: saveMarks(config.clipMode)
        case .playMarks: togglePlayMarks()
        case .markIn: markIn()
        case .markOut: markOut()
        case .markPrev: jumpToMarkEdge(-1)
        case .markNext: jumpToMarkEdge(1)
        case .markSnap: snapMark()
        case .markLoop: markLoop()
        case .markDelete:
            changeMarks(refusing: "No mark here") { marks in marks.delete(at: position).map { "Mark \($0) deleted" } }
        case .markClear:
            changeMarks(refusing: "No marks") { marks in
                let count = marks.clear()
                return count == 0 ? nil : "All marks deleted (\(count))"
            }
        case .showProgress: osd(progressText)
        case .toggleSegmentLock: toggleSegmentLock()
        case .scrub, .cycleFullscreen, .setFullscreen, .cycleOntop, .stats, .quit, .ignore,
             .zoom, .zoomReset, .playlistPrev, .playlistNext, .togglePlaylist, .cyclePlaylistSort, .playlistFilter, .deleteFile, .closeFile, .cycleABLoopMode, .toggleUpscaler, .cycleUpscaler, .toggleVibrance, .toggleAutoColor, .saveAutoColor, .saveVibrance, .resetColor, .toggleScrubAudio, .toggleScrubAudioPitch, .cycleAspect, .windowScale, .windowFit,
             .revealFrames, .goTo, .holdSpeed, .showKeys, .sceneStep, .sceneBackStep, .addAutoColorStrength, .scrubEdge, .pluginAction: break
        case .shuttleBack: shuttle(.back)
        case .shuttleStop: shuttle(.stop)
        case .shuttleForward: shuttle(.forward)
        }
    }

    // MARK: Text

    /// "1.00", "−2.00× (shown 31 fps)" while playing backward or skipping (spec §2).
    private var speedText: String {
        let value = String(format: "%.2f", speed)
        guard !isPaused else { return (direction < 0 ? "\u{2212}" : "") + value }
        let shown = shownTimes.filter { $0 >= now() - 1 }.count
        return (direction < 0 ? "\u{2212}" : "") + value + "\u{00D7} (shown \(shown) fps)"
            + (filler?.reverseLevel.map { $0 == .all ? "" : ", \($0 == .references ? "reference frames" : "keyframes") only" } ?? "")
    }

    public var progressText: String {
        "\(FrameNaming.timecode(currentSeconds)) / \(FrameNaming.timecode(durationSeconds))"
    }

    public var frameText: String {
        var text = "Frame \(position) / \(max(frameCount - 1, 0)) · \(FrameNaming.timecode(currentSeconds))"
        // Backlog 4.6: K for a keyframe of the exact index, else the decoder's picture type once decoded.
        if index?.isKeyframe(position) == true {
            text += " · K"
        } else if let type = cache.frame(position)?.pictureType {
            text += " · \(type)"
        }
        if let a = loopA { text += " · " + offsetText(position - a, prefix: "A") }
        if let i = marks.segmentIndex(containing: position) { text += " · mark \(i + 1)/\(marks.segments.count)" }
        if index?.isExact == false { text += " ≈" }
        if !cache.contains(position) { text += " …" }
        return text
    }

    /// "A+30 f (1.00 s)", "A−10 f (−0.33 s)"; just the prefix at no distance.
    private func offsetText(_ frames: Int, prefix: String) -> String {
        guard frames != 0 else { return prefix }
        let sign = frames < 0 ? "−" : "+"
        return "\(prefix)\(sign)\(abs(frames)) f (\(frames < 0 ? sign : "")\(seconds(ofFrames: abs(frames))) s)"
    }

    /// "2.00": how long `frames` frames last by the index.
    private func seconds(ofFrames frames: Int) -> String {
        String(format: "%.2f", index.map { $0.seconds(forFrame: frames) - $0.seconds(forFrame: 0) } ?? 0)
    }

    /// The stats as plain text: the panel's sections without the file, Stash and picture ones (the app's).
    public var statsText: String {
        guard let stats else { return "No file" }
        return InfoText.plain(StatsContent.sections(player: stats, file: nil, picture: nil, stash: nil))
    }

    /// A snapshot of the player for the stats panel; nil without a file. Starts measuring the shown frame's sharpness.
    public var stats: PlayerStats? {
        guard let info, let index else { return nil }
        var marksText: String?
        if !marks.segments.isEmpty {
            let total = marks.segments.reduce(0.0) { $0 + index.seconds(forFrame: $1.end) - index.seconds(forFrame: $1.start) }
            marksText = "\(marks.segments.count) · \(FrameNaming.timecode(total)) total"
        }
        var abLoop: String?
        if let a = loopA, let b = loopB {
            abLoop = "\(timecode(a)) – \(timecode(b)), \(b - a) f (\(seconds(ofFrames: b - a)) s), \(config.abLoop.rawValue)"
        }
        let (sharpnessText, changeText) = sharpnessTexts
        return PlayerStats(
            format: info.format, width: info.width, height: info.height, bitDepth: info.bitDepth, rotation: info.rotationClockwise,
            sampleAspect: info.sampleAspect, frameRate: info.frameRate, duration: info.durationSeconds,
            decoder: filler?.decoderStatus.map { "\($0.codec) (\($0.backend.rawValue))" } ?? "starting",
            frame: position, lastFrame: index.frameCount - 1, exactIndex: index.isExact, time: progressText,
            cache: "\(cache.usedBytes >> 20) / \(cache.budgetBytes >> 20) MiB, \(cache.count) frames",
            readCache: readCache.map { networkPolicy.isNetwork ? $0.stats.text + ", network mode" : $0.stats.text }, seek: seekTimer.text, index: indexStatus.text,
            speed: speedText, volume: isMuted ? "muted" : "\(Int(volume))%", saved: savedCount, marks: marksText, abLoop: abLoop,
            sharpness: sharpnessText, change: changeText, lastDecodeError: filler?.lastError.map { "\($0)" },
            clips: clipQueue.flatMap { $0.isBusy ? "saving 1 · \($0.waitingCount) waiting" : nil })
    }

    /// Sharpness and change of the frame at `position`; starts measuring them and says "…" until the result is in.
    private var sharpnessTexts: (sharpness: String, change: String) {
        if let known = sharpness, known.session == session, known.frame == position {
            return (known.score.map { String(Int($0.rounded())) } ?? "n/a", known.change.map { String(format: "%.1f %%", $0) } ?? "n/a")
        }
        let key = (session: session, frame: position)
        if let frame = cache.frame(position), sharpnessPending.map({ $0 != key }) ?? true {
            sharpnessPending = key
            let previous = statsSignature.flatMap { $0.session == session ? $0.signature : nil }
            sharpnessQueue.async { [weak self] in
                let score = SharpnessMeter.score(frame.pixelBuffer)
                let signature = SceneSignature.of(FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: true))
                let change = previous.map { DuplicateFilter.change($0, signature) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sharpness = (key.session, key.frame, score, change)
                    self.statsSignature = (key.session, signature)
                    if let pending = self.sharpnessPending, pending == key { self.sharpnessPending = nil }
                }
            }
        }
        return ("…", "…")
    }

    // MARK: Private

    private func refocus(direction stepDirection: Int) {
        if isPaused {
            filler?.setFocus(position, mode: .paused, direction: stepDirection)
            return
        }
        if direction < 0 { filler?.setReverseDemand(speed: speed, framesPerSecond: info?.frameRate ?? 30) }
        filler?.setFocus(position, mode: direction < 0 ? .reversing : .playing, direction: direction)
    }

    /// Backward the clock runs on the host time at a negative rate and the audio waits (spec §3).
    private func restartClock() {
        // The frame playback starts on is not on screen yet (a new file, a seek the decoder has not reached; a stand-in
        // near it does not count): the clock and the sound start with it (`display`, `tick`), so the sound never runs
        // ahead of a decoder that is still on its way there. An undecodable frame does not hold playback.
        clockWaitsForPicture = displayedFrame != position && !cache.isUndecodable(position)
        guard !clockWaitsForPicture else {
            clock.stop()
            audio?.pause()
            return
        }
        clock.followsAudio = direction > 0
        clock.rate = speed * Double(direction)
        clock.start(at: currentSeconds)
        if direction > 0 { audio?.play(fromSeconds: currentSeconds) } else { audio?.pause() }
    }

    /// A shuttle key (spec §2).
    private func shuttle(_ key: ShuttleKey) {
        guard index != nil else { return }
        let next = Shuttle.press(key, in: PlayState(paused: isPaused, direction: direction, speed: speed))
        if next.paused {
            pause()
            feedback(.pause)
            return
        }
        let turned = next.direction != direction
        direction = next.direction
        applySpeed(next.speed)
        shuttleSpeed = next.speed > 1
        if isPaused {
            let keep = shuttleSpeed
            shuttleSpeed = false   // play() would reset the speed the shuttle just chose
            play()
            shuttleSpeed = keep
        } else if turned {
            restartClock()
            refocus(direction: direction)
        }
        feedback(.speed(speed * Double(direction)))
    }

    private func noteShown() {
        let t = now()
        shownTimes.append(t)
        shownTimes.removeAll { $0 < t - 1 }
    }

    /// Never drops a pending screenshot silently: cancels it when the user moved on or the
    /// frame turned out to be undecodable.
    private func checkPendingScreenshot() {
        if let pending = pendingScreenshot {
            if pending != position {
                pendingScreenshot = nil
                osd("Save cancelled")   // no `.error`: it comes from `tick`, outside any input
            } else if cache.isUndecodable(pending) {
                pendingScreenshot = nil
                refuse("Cannot save frame \(pending): undecodable")
            }
        }
        if let pending = pendingCopy {
            if pending != position {
                pendingCopy = nil
                osd("Copy cancelled")
            } else if cache.isUndecodable(pending) {
                pendingCopy = nil
                osd("Cannot copy frame \(pending): undecodable")
            }
        }
    }

    private func showCurrent() {
        checkPendingScreenshot()
        let standIn = cache.nearestAvailable(to: position).flatMap {
            abs($0.number - position) <= Self.standInDistance ? $0 : nil
        }
        if let frame = cache.frame(position) ?? standIn, frame.number != displayedFrame {
            display(frame)
        }
        if displayedFrame == position { seekTimer.finish(at: now()) }
        delegate?.playerStateDidChange(self)
    }

    /// Puts `frame` on screen; in pause it also gets its piece of scrub audio.
    private func display(_ frame: DecodedFrame) {
        StartupTrace.markOnce("first frame to view")
        displayedFrame = frame.number
        delegate?.player(self, display: frame)
        if clockWaitsForPicture, !isPaused { restartClock() }
        if isPaused, let seconds = index?.seconds(forFrame: frame.number) { scrubAudio?.frameShown(seconds: seconds) }
    }

    private func frameInserted(_ n: Int, session current: Int) {
        guard current == session, n == position || n == pendingScreenshot || n == pendingCopy || seekTimer.isRunning,
              let frame = cache.frame(n) else { return }
        // Spec §3.2: while a seek series has not reached its target, a decoded frame between the picture and
        // the target is shown, so a held key moves the picture as fast as frames arrive.
        if n != position, seekTimer.isRunning, let shown = displayedFrame,
           seekDirection > 0 ? (n > shown && n < position) : (n < shown && n > position) {
            display(frame)
            delegate?.playerStateDidChange(self)
            return
        }
        if n == position && displayedFrame != n {
            seekTimer.finish(at: now())
            display(frame)
            delegate?.playerStateDidChange(self)
            if frameOSDPending {
                frameOSDPending = false
                osd(frameText)
            }
        }
        if n == pendingScreenshot {
            pendingScreenshot = nil
            save(frame)
        }
        if n == pendingCopy {
            pendingCopy = nil
            copy(frame)
        }
    }

    /// Shows the first decoding error of a file once; later ones only appear in the stats.
    private func decodeFailed(_ error: Error, session current: Int) {
        guard current == session, !decodeErrorShown else { return }
        decodeErrorShown = true
        osd("Decode error: \(error)")
    }

    private func step(by frames: Int) {
        guard frames != 0, let index else { return }
        if !isPaused {
            pause()
            scrubAudio?.userActed()   // the pause is the step's own: its frame was asked for and sounds
        }
        let direction = frames > 0 ? 1 : -1
        let from = position
        defer { noteEnd(moved: position != from, direction: direction) }
        var n = min(max(position + frames, 0), index.frameCount - 1)
        while cache.isUndecodable(n), n + direction >= 0, n + direction < index.frameCount { n += direction }
        seek(toFrame: n, direction: direction)
        frameOSDPending = !cache.contains(position)
        osd(frameText)
    }

    /// The next keyframe, or the keyframe before the current frame (backlog 4.2). Before the exact index is
    /// known the decoder finds the keyframe in that direction (spec §2.3).
    private func keyframeStep(_ direction: Int) {
        guard let index else { return }
        let from = position
        defer { noteEnd(moved: position != from, direction: direction) }   // past the last keyframe too
        noteSeek()
        seekTimer.start(at: now())
        seekDirection = direction
        guard index.isExact else {
            seekToKeyframe(toward: position + direction, direction: direction)
            return
        }
        let target = direction > 0 ? index.keyframe(after: position) ?? position
            : index.keyframe(atOrBefore: max(position - 1, 0))
        seek(toFrame: target, direction: direction)
        frameOSDPending = !cache.contains(position)
        osd(frameText)
    }

    /// Back to where the last seek series started; pressed again, back to where the revert started.
    private func revertSeek() {
        guard let target = revertPoint, index != nil else { osd("Nothing to revert"); return }
        revertPoint = position
        lastSeekAt = -.infinity    // the next seek starts a new series
        seekTimer.start(at: now())
        seekDirection = target < position ? -1 : 1
        seek(toFrame: target, direction: seekDirection)
        osd(progressText)
        feedback(.revert)
    }

    /// ⌘G (backlog 4.3): an exact jump to a time or frame, clamped to the file; revert-seek comes back here.
    /// While the segments are locked an absolute target with no move to count along them takes the nearest edge.
    public func goTo(_ target: GoToTarget) {
        scrubAudio?.userActed()
        guard let index else { return }
        let frame = switch target {
        case let .seconds(seconds): index.frameNumber(forSeconds: seconds)
        case let .frame(n): n
        }
        jump(toFrame: frame, hold: .nearest)
    }

    /// Next / previous scene: like `goTo(.frame(frame))`, but the scene was searched from the playhead, so while the
    /// segments are locked the move is counted along them (`SegmentHold.glued`) and a cut found in a gap runs on into
    /// the following segment instead of falling back onto the edge it started from.
    public func jumpToScene(frame: Int) {
        scrubAudio?.userActed()
        jump(toFrame: frame, hold: .glued)
    }

    /// An exact jump that keeps play / pause and sets the revert point.
    private func jump(toFrame frame: Int, hold: SegmentHold) {
        guard let index else { return }
        revertPoint = position          // a deliberate jump: never part of a key-repeat series
        lastSeekAt = now()
        seekTimer.start(at: now())
        let target = min(max(frame, 0), max(index.frameCount - 1, 0))
        seekDirection = target < position ? -1 : 1
        seek(toFrame: target, direction: seekDirection, hold: hold)
        frameOSDPending = !cache.contains(position)
        osd(frameText)
    }

    private func noteSeek() {
        let t = now()
        if t - lastSeekAt > Self.seekSeriesGap { revertPoint = position }
        lastSeekAt = t
    }

    /// `seek ±N`: `.step` (`onSeekHaptic`) when the position moved, else `.end` (once per push).
    private func seekRelative(_ seconds: Double, precision: SeekPrecision) {
        guard let index else { return }
        let from = position
        defer {
            noteEnd(moved: position != from, direction: seconds < 0 ? -1 : 1)
            if position != from { onSeekHaptic?(.step) }
        }
        noteSeek()
        seekTimer.start(at: now())
        seekDirection = seconds < 0 ? -1 : 1
        var target = index.frameNumber(forSeconds: max(0, currentSeconds + seconds))
        if usesKeyframes(precision), !index.isExact {
            seekToKeyframe(toward: target, direction: seconds < 0 ? -1 : 1)
            osd(progressText)
            return
        }
        if usesKeyframes(precision), let keyframe = index.keyframeSeekTarget(from: position, toward: target,
                                                                    direction: seconds < 0 ? -1 : 1),
           snapsToKeyframe(keyframe) {
            target = keyframe
        }
        seek(toFrame: target, direction: seconds < 0 ? -1 : 1)
        osd(progressText + (index.isKeyframe(position) ? " K" : ""))
    }

    private func usesKeyframes(_ precision: SeekPrecision) -> Bool {
        precision == .keyframes || (precision == .byConfig && config.seekMode == .keyframe)
    }

    /// The next multiple of `step` above (`direction` > 0) or below `speed`, never less than one step; `atLowest`:
    /// that floor held it (a step down from one step or less).
    static func stepped(_ speed: Double, by direction: Int, step: Double) -> (speed: Double, atLowest: Bool) {
        let steps = speed / step
        let next = direction > 0 ? (steps + 1e-9).rounded(.down) + 1 : (steps - 1e-9).rounded(.up) - 1
        return (max(next, 1) * step, next < 1)
    }

    /// `step-speed` (mouse spec §5.1): `.limit` when the grid's lowest step or the speed range held the step, else
    /// `.detent` when the speed landed on or passed 1× (from exclusive, to inclusive), else `.step`.
    private func stepSpeed(_ direction: Int) {
        let from = speed
        let next = Self.stepped(speed, by: direction, step: config.speedStep)
        setSpeed(next.speed)
        let eps = 1e-9
        let detent = from < speed ? (1 > from + eps && 1 <= speed + eps) : (1 < from - eps && 1 >= speed - eps)
        haptic(next.atLowest || abs(speed - next.speed) > eps ? .limit : detent ? .detent : .step)
    }

    private func setSpeed(_ value: Double) {
        applySpeed(value)
        shuttleSpeed = false
        feedback(.speed(speed * Double(direction)))
    }

    private func applySpeed(_ value: Double) {
        // With audio the clock follows the audio, whose time-pitch unit only spans 1/32…32.
        let range = audio != nil ? AudioOutput.rateRange : 0.01...100
        speed = min(max(value, range.lowerBound), range.upperBound)
        clock.rate = speed * Double(direction)
        audio?.rate = Float(speed)
        if !isPaused && direction < 0 { filler?.setReverseDemand(speed: speed, framesPerSecond: info?.frameRate ?? 30) }
    }

    /// What the hold-speed key changed, to put back on release (backlog 4.5); nil while not held.
    private var heldFrom: (speed: Double, paused: Bool)?

    /// The hold-speed key went down: play at `hold-speed` (starting playback if paused) until `endHoldSpeed`.
    public func beginHoldSpeed() {
        guard heldFrom == nil, index != nil else { return }
        heldFrom = (speed, isPaused)
        applySpeed(config.holdSpeed)
        if isPaused {
            let keep = shuttleSpeed
            shuttleSpeed = false   // play() would put the shuttle's 1× back over the hold speed
            play()
            shuttleSpeed = keep
        }
    }

    /// The hold-speed key came up: the speed and the paused state from before the hold come back.
    public func endHoldSpeed() {
        guard let held = heldFrom else { return }
        heldFrom = nil   // the direction stays: a ping-pong turn or the shuttle during the hold is kept
        applySpeed(held.speed)
        if held.paused { pause() }
    }

    private func applyVolume() {
        audio?.volume = isMuted ? 0 : Float(volume / 100)
        scrubAudio?.audible = !isMuted && volume > 0
    }

    private func applyScrubAudioSettings() {
        scrubAudio?.enabled = config.scrubAudio
        scrubAudio?.length = Double(config.scrubAudioLengthMs) / 1000
        scrubAudio?.pitch = config.scrubAudioPitch
        scrubAudio?.audible = !isMuted && volume > 0
    }

    /// Seeks to a time in seconds (links, plugins); a time outside the locked segments takes the nearest edge.
    public func seek(toSeconds seconds: Double) {
        guard let index else { return }
        seek(toFrame: index.frameNumber(forSeconds: seconds), direction: 0, hold: .nearest)
    }

    /// Steps by whole frames, as the frame-step keys do (plugins).
    public func step(frames: Int) {
        step(by: frames)
    }

    /// An A-B loop over a range in seconds, nil to clear it (links, plugins).
    public func setLoop(seconds range: ClosedRange<Double>?) {
        guard let index else { return }
        if let range {
            let a = index.frameNumber(forSeconds: range.lowerBound)
            loopA = a
            loopB = max(a, index.frameNumber(forSeconds: range.upperBound))
        } else {
            loopA = nil
            loopB = nil
        }
        delegate?.playerStateDidChange(self)
    }

    /// The current position in seconds.
    public var positionSeconds: Double { index?.seconds(forFrame: position) ?? 0 }

    /// The loop in seconds, when both ends are set.
    public var loopSeconds: ClosedRange<Double>? {
        guard let index, let a = loopA, let b = loopB else { return nil }
        return index.seconds(forFrame: a)...index.seconds(forFrame: b)
    }

    // MARK: Segment lock

    /// How a target outside the locked segments is brought inside: `glued` counts the move along the segments with the
    /// gaps left out (a step, a seek by some seconds); `nearest` takes the nearest edge (a click on the bar, a landing).
    private enum SegmentHold { case glued, nearest }

    /// The segments while they are locked.
    private var lockedSegments: SegmentSet? { segmentsLocked ? segments : nil }

    /// The A–B loop, when both ends are set.
    private var loopRange: ClosedRange<Int>? { loopA.flatMap { a in loopB.map { a...$0 } } }

    /// What playback loops over: the A–B loop, else, with locked segments that repeat, the segment of the playhead.
    private var playbackLoop: ClosedRange<Int>? {
        if let loopRange { return loopRange }
        guard let segments = lockedSegments, segmentAdvance == .repeating,
              let i = segments.index(containing: segments.nearest(position)) else { return nil }
        return segments.ranges[i]
    }

    /// `frame` held inside the locked segments (spec §1): kept when inside one, else moved per `hold`.
    private func held(_ frame: Int, hold: SegmentHold) -> Int {
        guard let segments = lockedSegments, segments.index(containing: frame) == nil else { return frame }
        switch hold {
        case .glued: return segments.glued(from: position, to: frame)
        case .nearest: return segments.nearest(frame)
        }
    }

    /// Whether a keyframe seek snaps to `keyframe`: not when it lies outside the locked segments, where the seek's own
    /// target is held inside them instead (exact frames inside the segments beat a keyframe outside them).
    private func snapsToKeyframe(_ keyframe: Int) -> Bool {
        lockedSegments.map { $0.index(containing: keyframe) != nil } ?? true
    }

    /// Index of the segment containing the playhead.
    public var currentSegment: Int? { segments?.index(containing: position) }

    /// The segments in seconds: their frames' times with an index, else the seconds as given.
    public var segmentsSeconds: [ClosedRange<Double>] {
        guard let index, let segments else { return segmentsSource }
        return segments.ranges.map { index.seconds(forFrame: $0.lowerBound)...index.seconds(forFrame: $0.upperBound) }
    }

    /// Where a link or a plugin's `open` lands in the file just opened (Ruling R19): its segments (locked unless `lock`
    /// is false), then its time, else the start of the first segment — over the remembered position and Stash's resume
    /// point. Without segments, only the time. Announced once, where it lands.
    public func applyLanding(_ landing: LinkTarget) {
        if !landing.segments.isEmpty {
            assignSegments(seconds: landing.segments, lock: landing.lock ?? true, advance: landing.advance)
        }
        if let index, let time = landing.time {
            seek(toFrame: index.frameNumber(forSeconds: time), direction: 0, hold: .nearest)
        } else if !landing.segments.isEmpty, let first = segments?.ranges.first {
            seek(toFrame: first.lowerBound, direction: 0, hold: .nearest)
        }
        announceSegment()
        delegate?.playerStateDidChange(self)
    }

    /// Gives the open file its segments (links, plugins); an empty list clears them. `advance` nil takes the config's
    /// `segment-advance`. Locking moves the playhead to the nearest frame of a segment. Given while no file is open,
    /// they apply to the next one opened. Not remembered for the file. False when a file is open and none of the
    /// segments falls inside it (nothing is set then but an empty set).
    @discardableResult
    public func setSegments(seconds: [ClosedRange<Double>], lock: Bool = true, advance: SegmentAdvance? = nil) -> Bool {
        assignSegments(seconds: seconds, lock: lock, advance: advance)
        if lockedSegments != nil { seek(toFrame: position, direction: 0, hold: .nearest) }
        announceSegment()
        delegate?.playerStateDidChange(self)
        return seconds.isEmpty || index == nil || segments != nil
    }

    /// The segments, the lock and the advance set, and a loop across a gap dropped; the playhead is left where it is.
    private func assignSegments(seconds: [ClosedRange<Double>], lock: Bool, advance: SegmentAdvance?) {
        segmentsSource = seconds
        segmentAdvance = advance ?? config.segmentAdvance
        rebuildSegments()
        // Without an index they wait for the file; with one, ranges all past its end leave nothing to lock.
        segmentsLocked = lock && !seconds.isEmpty && (segments != nil || index == nil)
        if lockedSegments != nil { dropLoopOutsideSegments() }
    }

    /// Locks or unlocks the segments; false when there are none. Locking moves the playhead into them.
    public func setSegmentLock(_ on: Bool) -> Bool {
        guard segments != nil else { return false }
        segmentsLocked = on
        if on {
            dropLoopOutsideSegments()
            seek(toFrame: position, direction: 0, hold: .nearest)
        }
        announceSegment()
        delegate?.playerStateDidChange(self)
        return true
    }

    /// Seeks to the start of segment `i` (0-based); false when there is no such segment.
    public func goSegment(_ i: Int) -> Bool {
        guard let segments, segments.ranges.indices.contains(i) else { return false }
        seek(toFrame: segments.ranges[i].lowerBound)
        return true
    }

    /// Locking: an A–B loop not inside one segment is cleared, as playback would run through the gaps with it.
    private func dropLoopOutsideSegments() {
        guard let segments = lockedSegments, let a = loopA, let b = loopB else { return }
        guard segments.index(containing: a) == nil || segments.index(containing: a) != segments.index(containing: b) else {
            return
        }
        loopA = nil
        loopB = nil
    }

    /// `segments` from `segmentsSource` with the current index; nil without an index or without segments. Ranges wholly
    /// before the start or from the end of the file on are left out (the index would clamp them onto its first / last frame).
    private func rebuildSegments() {
        guard let index, !segmentsSource.isEmpty else { segments = nil; return }
        let end = durationSeconds > 0 ? durationSeconds : .infinity
        let set = SegmentSet(frames: segmentsSource.filter { $0.upperBound >= 0 && $0.lowerBound < end }.map {
            index.frameNumber(forSeconds: $0.lowerBound)...index.frameNumber(forSeconds: $0.upperBound)
        }, frameCount: index.frameCount)
        segments = set.isEmpty ? nil : set
    }

    /// Calls `onSegmentChange` when the segment of the playhead or the lock changed since the last call.
    private func announceSegment() {
        let state = (current: currentSegment, locked: segmentsLocked)
        guard state != announcedSegment else { return }
        announcedSegment = state
        onSegmentChange?(state.current, state.locked)
    }

    private func toggleSegmentLock() {
        guard let segments, setSegmentLock(!segmentsLocked) else { refuse("No segments"); return }
        osd(segmentsLocked ? "Segments locked: \((currentSegment ?? 0) + 1)/\(segments.ranges.count)"
            : "Segments unlocked (\(segments.ranges.count))")
    }

    private func cycleABLoop() {
        if let a = loopA, loopB == nil {
            if let segments = lockedSegments,
               segments.index(containing: a) == nil || segments.index(containing: a) != segments.index(containing: position) {
                loopA = nil
                refuse("A-B must be inside one segment")
                delegate?.playerStateDidChange(self)
                return
            }
            loopA = min(a, position)
            loopB = max(a, position)
            let length = loopB! - loopA!
            osd("A-B loop: \(timecode(loopA!)) - \(timecode(loopB!)) (\(length) f, \(seconds(ofFrames: length)) s)")
        } else if loopA == nil {
            loopA = position
            osd("A-B loop start: \(timecode(position))")
        } else {
            loopA = nil
            loopB = nil
            osd("Clear A-B loop")
        }
        delegate?.playerStateDidChange(self)
    }

    // MARK: Cut marks

    /// Applies a mark edit and shows its message; a change is recorded for ⌘Z under that message. A live edge drag is
    /// cancelled first, so the edit applies to the marks as they were before it (later wheel steps begin a new drag).
    /// An edit that returns nil found nothing to do: `refusal` is shown as a refusal.
    private func changeMarks(refusing refusal: String? = nil, _ edit: (inout CutMarks) -> String?) {
        cancelEdgeDrag()
        var changed = marks
        guard let message = edit(&changed) else {
            if let refusal { refuse(refusal) }
            delegate?.playerStateDidChange(self)
            return
        }
        if changed != marks {
            marksHistory.record(marks, label: message)
            marks = changed
        }
        osd(message)
        delegate?.playerStateDidChange(self)
    }

    /// "Mark 2 in: 00:01:23.456 · clip starts 2.40 s earlier" / "· on a keyframe" (the lead-in only with an exact index).
    private func markInText(_ number: Int, start: Int) -> String {
        var text = "Mark \(number) in: \(timecode(start))"
        if let index, index.isExact {
            let lead = index.seconds(forFrame: start) - index.seconds(forFrame: index.keyframe(atOrBefore: start))
            text += lead > 0.05 ? " · clip starts \(String(format: "%.2f", lead)) s earlier" : " · on a keyframe"
        }
        return text
    }

    /// "Mark 2: 00:01:23.456 – 00:01:31.000 (7.54 s)" for the segment containing `frame`.
    private func markText(_ number: Int, containing frame: Int, in marks: CutMarks) -> String {
        guard let i = marks.segmentIndex(containing: frame) else { return "Mark \(number)" }
        let segment = marks.segments[i]
        return "Mark \(number): \(timecode(segment.start)) – \(timecode(segment.end)) (\(seconds(ofFrames: segment.end - segment.start)) s)"
    }

    private func markIn() {
        changeMarks { marks in markInText(marks.markIn(at: position), start: position) }
    }

    private func markOut() {
        changeMarks { marks in markText(marks.markOut(at: position), containing: position, in: marks) }
    }

    private func snapMark() {
        guard let index, index.isExact else { refuse("Wait for the index to finish"); return }
        changeMarks(refusing: "No mark here") { marks in
            guard let number = marks.snapStart(at: position, index: index), let start = marks.start(ofNumber: number) else {
                return nil
            }
            return "Mark \(number) in: \(timecode(start)) (keyframe)"
        }
    }

    private func markLoop() {
        guard let a = loopA, let b = loopB else { refuse("Set an A-B range first"); return }
        changeMarks { marks in markText(marks.add(CutSegment(start: a, end: b)), containing: a, in: marks) }
    }

    /// `{` / `}`: exact seek to the nearest mark edge before / after the playhead.
    private func jumpToMarkEdge(_ direction: Int) {
        guard let target = direction < 0 ? marks.boundary(before: position) : marks.boundary(after: position) else {
            refuse(direction < 0 ? "No mark before" : "No mark after")
            return
        }
        noteSeek()
        seek(toFrame: target, direction: direction)
        osd(frameText)
    }

    private func togglePlayMarks() {
        guard playMarksOnly || !marks.segments.isEmpty else { refuse("No marks to play"); return }
        playMarksOnly.toggle()
        osd("Play marks only: \(playMarksOnly ? "on" : "off")")
        if playMarksOnly, !isPaused, lockedSegments == nil,
           let start = PlaybackEdges.markStart(position: position, direction: direction, marks: marks.segments) { seek(toFrame: start) }
        delegate?.playerStateDidChange(self)
    }

    // MARK: Edge drag

    /// `scrub-edge` wheel step: begins a drag if none (keeping its edge until it ends), scrubs by `frames` within
    /// the drag's bounds, and puts the edge on the frame reached.
    public func scrubEdge(_ edge: MarkEdge, by frames: Int) {
        guard let index else { return }
        if edgeDrag == nil { edgeAtLimit = false }
        let drag = edgeDrag ?? EdgeDrag(edge: edge, marks: marks, position: position, frameCount: index.frameCount)
        edgeDrag = drag
        let from = position
        var blocked = false
        if drag.movesAnEdge {
            let allowed = drag.allowed
            let wanted = position + frames
            let target = min(max(wanted, allowed.lowerBound), allowed.upperBound)
            if target != position { scrub(by: target - position) }   // at the bound: the scrub stops there
            blocked = target != wanted
        } else {
            scrub(by: frames)   // a plain scrub: the first / last frame bumps as `.end`
        }
        playScrubTick(from: from, marks: [])   // the edge passing a keyframe: where the clip will really start
        if blocked, !edgeAtLimit { haptic(.limit) }   // once per arrival at the bound
        edgeAtLimit = blocked
        let moved = drag.marks(at: position)
        if moved != marks {
            marks = moved
            delegate?.playerStateDidChange(self)
        }
    }

    /// Button released: the drag as one ⌘Z step with "Start 00:01:23.456 · f1234" / "End …"; without a mark under
    /// the playhead when it began, `I` / `O` at the final frame instead.
    public func endEdgeDrag() {
        guard let drag = edgeDrag else { return }
        edgeDrag = nil
        guard drag.movesAnEdge else {
            drag.edge == .start ? markIn() : markOut()
            return
        }
        let start = drag.edge == .start
        if marks != drag.original {
            marksHistory.record(drag.original, label: start ? "Mark start moved" : "Mark end moved")
        }
        let frame = min(max(position, drag.allowed.lowerBound), drag.allowed.upperBound)
        osd("\(start ? "Start" : "End") \(timecode(frame)) · f\(frame)")
        delegate?.playerStateDidChange(self)
    }

    /// Esc, focus loss, deactivation, another file: the marks as they were before the drag, no history entry.
    public func cancelEdgeDrag() {
        guard let drag = edgeDrag else { return }
        edgeDrag = nil
        marks = drag.original
        delegate?.playerStateDidChange(self)
    }

    /// ⌘Z: the marks before the last change.
    public func undoMarks() {
        cancelEdgeDrag()
        guard let step = marksHistory.undo(marks) else { return }
        marks = step.marks
        osd("Undo: \(step.label)")
        delegate?.playerStateDidChange(self)
    }

    /// ⇧⌘Z: the change undone last, again.
    public func redoMarks() {
        cancelEdgeDrag()
        guard let step = marksHistory.redo(marks) else { return }
        marks = step.marks
        osd("Redo: \(step.label)")
        delegate?.playerStateDidChange(self)
    }

    /// What `c` would save in each mode, for its sheet (spec §4.1); nil = no closed mark (with the open one closed
    /// at the playhead when it is after its start).
    public func clipSummary() -> ClipSummary? {
        guard let index else { return nil }
        let saving = CutMarks(segments: marks.closed(at: position).segments)
        guard !saving.segments.isEmpty else { return nil }
        func span(_ range: ClosedRange<Int>) -> Double {
            index.seconds(forFrame: range.upperBound) - index.seconds(forFrame: range.lowerBound)
        }
        func leadIn(_ range: ClosedRange<Int>) -> Double {
            index.seconds(forFrame: range.lowerBound) - index.seconds(forFrame: index.keyframe(atOrBefore: range.lowerBound))
        }
        let separate = (saving.clipRanges(.separate, index: index) ?? []).flatMap { $0 }
        let joined = saving.clipRanges(.joined, index: index).map { $0.flatMap { $0 } }
        return ClipSummary(segments: saving.segments.count, separateClips: separate.count,
                           separateSeconds: separate.reduce(0) { $0 + span($1) + leadIn($1) },
                           separateLeadIn: separate.reduce(0) { $0 + leadIn($1) },
                           joinedSeconds: joined.map { $0.reduce(0) { $0 + span($1) + leadIn($1) } },
                           joinedLeadIn: joined?.reduce(0) { $0 + leadIn($1) } ?? 0,
                           invertedSeconds: saving.clipRanges(.inverted, index: index).map { $0.joined().reduce(0) { $0 + span($1) } })
    }

    /// `c`: queues the marks as clips in `mode` and clears them (⌘Z brings them back). The open mark is closed at the
    /// playhead when that is after its start, else it stays for later.
    public func saveMarks(_ mode: ClipMode) {
        cancelEdgeDrag()   // a mark edit: the clips are of the marks before the drag
        let closed = marks.closed(at: position)
        guard !closed.segments.isEmpty else { osd("Mark a range first"); return }
        guard let clipQueue, let url, let index else { return }
        guard let ranges = CutMarks(segments: closed.segments).clipRanges(mode, index: index) else {
            refuse("Wait for the index to finish")
            return
        }
        guard !ranges.isEmpty else { osd("Nothing left outside the marks"); return }
        let naming = FrameNaming(directoryTemplate: config.frameDirectory, fileTemplate: config.frameTemplate)
        let named = sceneInfo?.namingURL(for: url) ?? url
        let busy = clipQueue.isBusy   // an idle queue starts the first job at once; do not count it while the worker wakes
        for job in ranges {
            let first = job[0].lowerBound, last = job[job.count - 1].upperBound
            clipQueue.enqueue(ClipJob(
                source: url, nameSource: sceneInfo?.namingURL(for: url),
                ranges: job.map { ClipRange(startPTS: index.pts(forFrame: $0.lowerBound), endPTS: index.pts(forFrame: $0.upperBound),
                                            keyframePTS: index.isExact ? index.pts(forFrame: index.keyframe(atOrBefore: $0.lowerBound)) : nil) },
                directory: naming.directory(forVideo: named),
                fallbackDirectory: FrameNaming.fallbackDirectory(forVideo: named, root: fallbackRoot),
                template: config.clipTemplate + mode.nameSuffix, aFrame: first, aSeconds: index.seconds(forFrame: first),
                endSeconds: index.seconds(forFrame: last), readLimit: config.clipReadLimitMB * 1_000_000))
        }
        let waiting = busy ? clipQueue.waitingCount : 0
        var text = mode != .separate ? "Joined clip queued" : ranges.count == 1 ? "Clip queued" : "\(ranges.count) clips queued"
        if waiting > 0 { text += " · \(waiting) waiting" }
        if closed.open != nil { text += "\nOpen mark left out" }
        marksHistory.record(marks, label: "Marks saved as clips")
        marks = CutMarks(open: closed.open)
        osd(text)
        delegate?.playerStateDidChange(self)
    }

    public static func clipSavedMessage(name: String, leadIn: Double) -> String {
        leadIn > 0.05 ? "Clip saved: \(name) (+\(String(format: "%.1f", leadIn)) s before A)" : "Clip saved: \(name)"
    }

    private func screenshot() {
        // While playing, the next tick would cancel a pending save: save what is on screen.
        if !isPaused, let shown = displayedFrame.flatMap(cache.frame) {
            save(shown)
        } else if let frame = cache.frame(position) {
            save(frame)
        } else {
            if pendingScreenshot == position { return }
            pendingScreenshot = position
            osd("Saving…")
        }
    }

    private func copyFrame() {
        guard index != nil else { osd("No video open"); return }
        // While playing, the next tick would cancel a pending copy: copy what is on screen.
        if !isPaused, let shown = displayedFrame.flatMap(cache.frame) {
            copy(shown)
        } else if let frame = cache.frame(position) {
            copy(frame)
        } else {
            if pendingCopy == position { return }
            pendingCopy = position
            osd("Copying…")
        }
    }

    private func copy(_ frame: DecodedFrame) {
        guard let exporter else { return }
        let current = session
        exporter.copyFrame(frame) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, current == self.session else { return }
                switch result {
                case let .success(copied):
                    let note = copied.fallbackReason.map { "Upscaled with Lanczos (\($0))" }
                    self.delegate?.player(self, copyImage: copied.data, frame: frame.number, note: note)
                case let .failure(error):
                    self.osd("Copy failed: \(error)")
                }
            }
        }
    }

    private func save(_ frame: DecodedFrame) {
        guard let exporter, let index else { return }
        let current = session
        exporter.saveFrame(frame, seconds: index.seconds(forPTS: frame.pts)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, current == self.session else { return }
                switch result {
                case let .success(saved):
                    self.savedCount += 1
                    self.lastSavedURL = saved.url
                    var text = saved.usedFallbackDirectory ? "Saved to \(saved.url.path)" : "Saved: \(saved.url.lastPathComponent)"
                    if let reason = saved.fallbackReason { text += " · Upscaled with Lanczos (\(reason))" }
                    self.osd(text)
                    self.haptic(.done)
                case let .failure(error):
                    self.osd("Save failed: \(error)")
                    self.haptic(.error)
                }
            }
        }
    }

    private func toggleExport() {
        if let flag = exportFlag {
            flag.cancel()
            osd("Cancelling export…")
            return
        }
        startExport(selection: ExportSelection(config: config))
    }

    /// Number of files an export of the current A–B range would write, or nil without a range.
    /// "Exported 52 frames, 33 blurry and 140 duplicates skipped".
    static func exportSummary(_ result: ExportResult) -> String {
        let skipped = [(result.blurry, "blurry"), (result.duplicates, result.duplicates == 1 ? "duplicate" : "duplicates")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let text = "Exported \(result.written) frame\(result.written == 1 ? "" : "s")"
        return skipped.isEmpty ? text : text + ", " + skipped.joined(separator: " and ") + " skipped"
    }

    public func exportCount(for selection: ExportSelection) -> Int? {
        guard let a = loopA, let b = loopB, let index else { return nil }
        return selection.frames(in: a...b, index: index).count
    }

    /// Exports the A–B range with `selection` (the Export dialog passes the user's choice).
    public func startExport(selection: ExportSelection) {
        guard exportFlag == nil else { return }
        guard let a = loopA, let b = loopB, let exporter, let index else {
            refuse("Set an A-B range first")
            return
        }
        let current = session
        exportFlag = exporter.exportRange(a...b, selection: selection, index: index, progress: { [weak self] written, total in
            DispatchQueue.main.async {
                guard let self, current == self.session, self.exportFlag?.isCancelled == false else { return }
                self.osd("Export \(written)/\(total)")
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, current == self.session else { return }
                let cancelled = self.exportFlag?.isCancelled ?? false
                self.exportFlag = nil
                switch result {
                case let .success(result):
                    if cancelled {
                        self.osd("Export cancelled (\(result.written) saved)")
                    } else {
                        self.osd(Self.exportSummary(result))
                    }
                case let .failure(error): self.osd("Export failed: \(error)")
                }
                self.delegate?.playerStateDidChange(self)
            }
        })
        delegate?.playerStateDidChange(self)
    }

    private func rememberPosition() {
        guard config.resumePlayback, let resumeStore, let url, let index else { return }
        resumeStore.save(ResumeEntry(position: index.seconds(forFrame: position),
                                     loopA: loopA.map(index.seconds(forFrame:)),
                                     loopB: loopB.map(index.seconds(forFrame:)),
                                     marks: marks.isEmpty ? nil
                                         : marks.segments.map { [index.seconds(forFrame: $0.start), index.seconds(forFrame: $0.end)] }
                                         + (marks.open.map { [[index.seconds(forFrame: $0)]] } ?? []),
                                     duration: durationSeconds > 0 ? durationSeconds : nil,
                                     color: resumeStore.color(for: url, size: readCache?.fileSize)),   // the colour edits write it themselves
                         for: url, size: readCache?.fileSize)
    }

    /// Spec §7.1: exact seek to the remembered position (unless less than 5 s remain) and the A–B range back.
    private func resumeIfRemembered(_ url: URL, fallback: Double?) {
        guard config.resumePlayback, let index else { return }
        guard let entry = resumeStore?.entry(for: url, size: readCache?.fileSize) ?? fallback.map({ ResumeEntry(position: $0) }) else { return }
        loopA = entry.loopA.map(index.frameNumber(forSeconds:))
        loopB = entry.loopB.map(index.frameNumber(forSeconds:))
        dropLoopOutsideSegments()   // segments given before the open are locked already
        if let saved = entry.marks {
            marks = CutMarks(segments: saved.filter { $0.count == 2 }.map {
                                 CutSegment(start: index.frameNumber(forSeconds: $0[0]), end: index.frameNumber(forSeconds: $0[1]))
                             },
                             open: saved.first { $0.count == 1 }.map { index.frameNumber(forSeconds: $0[0]) })
        }
        guard entry.position > 0, durationSeconds - entry.position >= 5 else { return }
        seek(toFrame: index.frameNumber(forSeconds: entry.position), direction: 0, hold: .nearest)
        osd("Resumed at \(FrameNaming.timecode(entry.position))")
    }

    private func timecode(_ frame: Int) -> String {
        FrameNaming.timecode(index?.seconds(forFrame: frame) ?? 0)
    }

    private func feedback(_ event: Feedback) {
        delegate?.player(self, showFeedback: event)
    }

    private func osd(_ text: String) {
        delegate?.player(self, showOSD: text)
    }

    private func haptic(_ event: HapticEvent) {
        onHaptic?(event)
    }

    /// A command that could not do what it was asked: its message and `.error`.
    private func refuse(_ text: String) {
        osd(text)
        haptic(.error)
    }

    /// A step, seek or scrub toward `direction` that `moved` or stopped at the first / last frame: `.end` once per push
    /// (`EndBump`, fresh by `inputIsFresh`); a move resets it.
    private func noteEnd(moved: Bool, direction: Int) {
        if endBump.stepped(moved: moved, direction: direction, fresh: inputIsFresh) { haptic(.end) }
    }

    /// Scales the cache budget for memory pressure; stays in force across `apply`.
    func setMemoryPressureFactor(_ factor: Double) {
        pressureFactor = factor
        cache.budgetBytes = Int(Double(baseBudget) * factor)
        readCache?.budgetBytes = readCacheBudget(factor)
    }

    private func readCacheBudget(_ factor: Double) -> Int {
        Self.readCacheBudget(config: config, policy: networkPolicy, factor: factor)
    }

    private static func readCacheBudget(config: Config, policy: NetworkPolicy, factor: Double) -> Int {
        Int(Double(max(config.readCacheMiB, config.readCacheMiB > 0 ? policy.minReadCacheMiB : 0) << 20) * factor)
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            let factor = event.contains(.critical) ? 0.25 : event.contains(.warning) ? 0.5 : 1
            self.setMemoryPressureFactor(factor)
        }
        source.resume()
        memoryPressure = source
    }
}

/// Stops a `PlayerCore.preparation` that is no longer wanted: its read cache closes, so the reads it waits for end
/// with `ECANCELED` and their downloads stop.
public final class OpenCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: ReadCache?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { () -> ReadCache? in
            cancelled = true
            return cache
        }?.close()
    }

    /// The preparation's read cache, closed at once if the cancel came first.
    func watch(_ readCache: ReadCache) throws {
        let late = lock.withLock { () -> Bool in
            cache = readCache
            return cancelled
        }
        if late {
            readCache.close()
            throw POSIXError(.ECANCELED)
        }
    }
}

/// What `PlayerCore.preparation(for:)` read of a file, for `PlayerCore.open(_:)`. Made on one thread and handed to
/// another once; nothing else touches it in between.
public struct PreparedOpen: @unchecked Sendable {
    public let url: URL
    let policy: NetworkPolicy
    let readCache: ReadCache
    let source: MediaSource

    /// Releases what was read, for an open that was abandoned.
    public func discard() { readCache.close() }
}
