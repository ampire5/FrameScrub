import AppKit
import CoreImage
import FrameScrubCore
import HomeScreenKit
import InfoPanelKit
import LogiHIDPP
import StashKitUI
import SwiftUI

final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlayerCoreDelegate, StillEnhancerDelegate {
    private let core: PlayerCore
    /// The bindings in effect: the user's (`baseInputMap`) with the keys of the plugin page's declared actions added.
    private var inputMap: InputMap
    /// The user's bindings (input.conf and the defaults), before any page action key is added.
    private var baseInputMap: InputMap
    /// The actions each plugin page declared (by its token), in the order the pages first declared them: a key goes to
    /// the page that claimed it first. Dropped when the page goes away.
    private var pluginActions: [(page: Int, actions: [PluginAction])] = []
    private let gestures: GestureRouter
    /// The bound mouse buttons, from AppKit and from the Logitech mouse (`mouseBridge`).
    private let buttons: MouseButtonRouter
    /// The Logitech mouse, once `AppDelegate` has made it (after the first window is up); nil without it.
    private var mouseBridge: LogiMouseBridge?
    /// The mouse's haptics: `core.onHaptic` and the app's own events, for keyboard and mouse input only.
    private let haptics = MouseHaptics(bridge: nil)
    /// The held button whose wheel drives `core.edgeDrag` (`scrub-edge`): its release ends the drag.
    private var edgeDragOwner: MouseButton?
    /// The button whose edge drag Esc cancelled: its wheel moves no edge until it is released.
    private var edgeDragSuppressed: MouseButton?
    /// The previous wheel event's time: a notch after a pause is a fresh push (`EndBump.isFreshNotch`).
    private var lastWheelTime: Double?
    /// `haptic-end` once per push against the first / last file of the playlist.
    private var playlistEndBump = EndBump()
    /// The SmartShift button while FrameScrub takes it over: held, it switches the mouse profile (`SmartShiftPress`).
    private var smartShift = SmartShiftPress()
    private var smartShiftHold: DispatchWorkItem?
    private let videoView = VideoView()
    private let startScreen = HomeScreenView(background: nil)
    /// The recent files on the start screen, newest first; a card's id is the file's path.
    private var recentItems: [RecentItem] = []
    /// Bumped on every start screen: availability answers for an older one are dropped.
    private var recentGeneration = 0
    /// The Stash WebUI (Stash spec §2.1), created the first time the start screen shows the Stash tab.
    private var stashLibrary: StashLibraryView?
    private var stashSession: StashSession?
    /// Where the file on screen came from; a Stash scene is reported back to Stash.
    private(set) var origin = FileOrigin.plain
    /// Where closing the file goes back to: Stash for a scene and the folder steps after it, else Recent.
    private var returnTab = StartTab.recent
    /// The Stash scene of the file on screen (or of the failure on screen).
    private var stashScene: StashScene?
    /// A Stash scene whose file could not be found, while its reason is on screen: Return tries it again.
    private var failedScene: StashScene?
    /// The OSD's file name for a Stash file, waiting up to 0.5 s for Stash's title to replace it; nil when none waits.
    private var stashTitleWait: DispatchWorkItem?
    /// The step through Stash's queue waiting for its scene, which way it went and whether it plays on (autoadvance).
    private var queueGate = QueueStepGate()
    private var queueDirection = 1
    private var queuePlays = false
    /// Stash is deleting the scene that was on screen (its file already closed) or the next scene is on its way.
    private var deletingScene = false
    /// The play state last seen, so that a pause is reported to Stash once.
    private var wasPaused = true
    /// The file came from Stash's queue: next/previous follow the queue, not the folder.
    private var followsStashQueue: Bool {
        if case .stash(_, true) = origin { return stashLibrary != nil }
        return false
    }
    private let osd = OverlayView(fontSize: 15)
    /// The stats (`i`): sections of the file on screen, in the top right corner; made in `buildViews`.
    private var statsPanel: InfoPanelController!
    /// The slots at the window's edges, holding the playlist and the plugin pages that drive the player.
    private var slots: SlotsController!
    /// Which pages are heard and which may open files (`plugin-open-allowed`); seeded from the configured plugins.
    private var pluginPolicy = PluginPolicy()
    /// The video's edges in the window, set from the slots' layout (pinned slots take room from it).
    private var videoEdges: [NSLayoutConstraint] = []
    /// The part of the video no overlay slot covers: the seek bar, the OSD and the stats keep to it.
    private let visibleArea = NSLayoutGuide()
    private var visibleEdges: [NSLayoutConstraint] = []
    private var visibleVideoRect: CGRect?
    /// Each slot's setting is written once its changes rest for 0.5 s.
    private var slotWrites: [SlotEdge: Timer] = [:]
    /// Decodes frames for the page's `frame` requests; made on the first request for the open file.
    private var pluginGrabber: PluginFrameGrabber?
    /// While `core.open` runs: segment events wait until the page has heard `fileopened` (Ruling R20).
    private var holdsSegmentEvents = false
    /// The last segment event raised while held; dispatched right after `fileopened`.
    private var heldSegmentEvent: PluginEvent?
    private var pushPacing = PluginPushPacing()
    /// The open file's name and folder at once, its size and date once read off the main thread.
    private var fileFacts: FileFacts?
    /// Refreshes the stats every 0.5 s while the panel is on screen and the window can be seen.
    private var statsTimer: Timer?
    private let hud = FeedbackHUD()
    private let goToField = GoToField()
    private let seekBar = SeekBarView()
    private let backButton = BackButton()
    private let previewView = PreviewView()
    /// The playlist's view; shown in whichever slot holds the playlist.
    private let playlistPanel = PlaylistPanelView()
    /// The playlist panel's name filter (kept from file to file until cleared).
    private var playlistFilter = ""
    private let keyHelp = KeyHelpView()
    private var previewProvider: FrameScrubCore.PreviewProvider?
    private var previewImage: CGImage?
    /// Where the pointer is on the seek bar (0…1); nil while it is not on the bar.
    private var previewFraction: Double?
    /// The keyframe a scroll over the bar moved the preview to, and where the pointer was then; the preview stays
    /// there (and a click goes there) until the pointer moves away by more than `pinSlack`.
    private var previewPin: (frame: Int, fraction: Double)?
    private static let pinSlack: CGFloat = 3
    private var lensScroll = LensScroll()
    /// What the current provider (or the decision not to have one) was built for; unchanged means nothing to rebuild.
    private struct PreviewKey: Equatable {
        let enabled: Bool
        let width: CGFloat
        let url: URL?
        let scale: CGFloat
    }
    private var previewKey: PreviewKey?
    private var previewLeading: NSLayoutConstraint!
    /// The OSD sits in the top left corner, below the back button while that is shown.
    private var osdTop: NSLayoutConstraint!
    /// Persists `sr-still=no` through the shared settings store (set by AppDelegate).
    var onDisableSRStill: (() -> Void)?

    /// The app's clip queue, shared by every file opened in this window.
    func setClipQueue(_ queue: ClipQueue) { core.clipQueue = queue }
    private var playlist: Playlist?
    /// A page's list (`playlist(...)`, `enqueue(...)`); while set it is the playlist instead of the folder. Opening a
    /// file from elsewhere (Finder, Home, a link, a page's `open`) drops it.
    private var listPlaylist: ListPlaylist?
    /// The list's items shown in the panel, by the filter: row → item.
    private var listRowIndices: [Int] = []
    /// The open file's folder as last read; the playlist is sorted and filtered from it.
    private var folderListing: FolderListing?
    /// The folder read running in the background (a NAS folder can take seconds).
    private var folderRead: (folder: URL, done: DispatchGroup, result: FolderReadResult)?
    /// A command that needs the whole folder, waiting for that read.
    private var folderWait = FolderWait()
    private let folderQueue = DispatchQueue(label: "framescrub.folder", qos: .userInitiated)
    /// The opened file whose "12 / 48" line waits for the first read of its folder.
    private var positionPending: URL?
    private var hideSeekBarWork: DispatchWorkItem?
    private let enhancer = StillEnhancer(upscaler: SystemStillUpscaling())
    private var lastFrame: DecodedFrame?
    /// `a` cycles it; every file starts at `auto` (aspect spec).
    private var aspectMode = AspectMode.auto
    /// The black-bar detector's result for the open file (nil: no bars, or not known yet).
    private var detectedCrop: CGRect?
    private var cropSampler: CropSampler?
    /// Automatic colour adjustments computed from a still frame (`V`, saved as `auto-color`); empty when off.
    private(set) var autoColor: [ColorCorrection.Step] = []
    /// How much `autoColor` in full changes the analysed frame; below `auto-color-threshold` the scene is left alone.
    private var autoColorDelta: Double?
    private var autoColorFrame: Int?
    /// Video time of the frame auto colour was last (or is being) computed from; nil before the first try.
    private var autoColorSeconds: Double?
    /// Auto colour is on, but this file has no frame analysed yet (it opened on a black frame, or is HDR).
    private var autoColorPending: Bool { core.config.autoColor && autoColorFrame == nil }
    /// The last analysis met a nearly black frame: the frame on screen is tried again every second of video.
    private var autoColorWaitingForPicture = false
    private var autoColorSession = 0
    private lazy var autoColorWorker = LatestOnlyWorker<AutoColorRequest>(label: "framescrub.autocolor") { [weak self] request in
        // A black frame (fade-in, scene change) would spread its stretched tones over the next scene: keep the old state.
        let analysis = ColorCorrection.isTooDarkToAnalyse(request.image) ? nil : ColorCorrection.analyse(request.image)
        Task { @MainActor in self?.applyRecomputedAutoColor(analysis, frame: request.frame, session: request.session) }
    }
    /// Compares shown frames for scene cuts; its detector starts afresh with each `autoColorSession`.
    private lazy var sceneCutWorker = LatestOnlyWorker<SceneRequest>(label: "framescrub.scenecut") { [weak self, scenes = SceneCutState()] request in
        if scenes.session != request.session {
            scenes.detector.reset()
            scenes.session = request.session
        }
        guard scenes.detector.isCut(SceneSignature.of(request.image)) else { return }
        Task { @MainActor in self?.sceneCut(session: request.session) }
    }
    /// Analyses the frame on screen 0.25 s after the last scene cut, so a dissolve is over and fast scrubbing waits.
    private var sceneCutAnalysis: DispatchWorkItem?
    private var sceneSampling = SceneSampling()
    private var signatureCatchUpScheduled = false
    private let preferences: PreferencesStore
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// What is asked of the Logitech mouse's wheel now (see `updatePrecisionWheel`): all off until the player is in
    /// front.
    private var wheelWants = WheelWants(precision: false, freeSpin: true, playerInFront: false, overVideo: false)
    /// `playerInFront` at the last `updatePrecisionWheel`, to recheck the mouse when the player comes in front.
    private var playerWasInFront = false
    private var precisionCheckedAt = 0.0
    /// The pointer is hidden with `NSCursor.hide()` for a scrub (see `hideCursorForScrub`).
    private var cursorHiddenForScrub = false
    private var appObservers: [NSObjectProtocol] = []
    /// "Indexing N%" (spec §2.2): when the file was opened and when the message was last shown.
    private var openedAt = 0.0
    private var indexingShownAt: Double?
    /// Scene jumps (Shift+↑ / Shift+↓): the search is made on the first scene command after an open.
    private var sceneSearch: SceneSearch?
    /// Presses waiting for a search; more presses in the same direction add scenes. `retries`: finds again for them
    /// because playback moved past the result meanwhile (`SceneJumpPolicy`).
    private var scenePending: (direction: Int, count: Int, retries: Int)?
    /// Shows "Searching for…" when a search takes longer than 0.3 s.
    private var sceneSearchingShown: DispatchWorkItem?
    /// Each press's find carries this; a completion with an older one (cancelled, replaced) is ignored.
    private var sceneSearchToken = 0
    /// After a jump to an uncached frame the core shows its frame line once it is decoded; the scene line stays
    /// instead. The jump target, so nothing else is hidden.
    private var sceneFrameOSDToDrop: Int?
    /// framescrub.conf as last applied; `core.config` is it with the open file's colour laid over (colour memory §3).
    private var globalConfig: Config
    /// The open file's and its folders' colour; it writes the file's values into the core's `ResumeStore`.
    private let colorMemory: ColorMemory
    /// Where the effective colour came from at the last recompute (the stats mark it).
    private var colorOrigin = ColorOrigin.default

    init(config: Config, inputMap: InputMap, preferences: PreferencesStore, folderColors: FolderColors) {
        self.preferences = preferences
        let resumeStore = ResumeStore()   // one store: the core keeps the colour the edits write when it saves the position
        core = PlayerCore(config: config, resumeStore: resumeStore)
        colorMemory = ColorMemory(folders: folderColors, files: resumeStore)
        globalConfig = config
        self.inputMap = inputMap
        baseInputMap = inputMap
        gestures = GestureRouter(inputMap: inputMap, scrubSettings: config.scrub)
        buttons = MouseButtonRouter(map: inputMap, longPressMilliseconds: config.mouseLongPress)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FrameScrub"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.level = config.ontop ? .floating : .normal
        super.init(window: window)
        restoreFrame(of: window)
        playlistPanel.fontSize = CGFloat(config.playlistFontSize)
        applyStartScreenConfig(config)
        window.delegate = self
        core.delegate = self
        enhancer.delegate = self
        buildViews(in: window)
        setUpMouse()
        statsPanel.fontSize = CGFloat(config.statsFontSize)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.enhancer.purgeCache() }
        }
        source.resume()
        memoryPressure = source
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePrecisionWheel() }
            })
        }
        // After a wake the mouse, or LinearMouse replaying its own setting, may have switched the mode off.
        appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { self?.mouseBridge?.recheckHighResolutionWheel() }
            }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A `framescrub://open` link: the file (or the Stash scene, found or streamed as for ▶), then its position,
    /// segment and plugin page. A scene's open is asynchronous.
    func open(_ target: OpenLink.Target) {
        if let plugin = target.plugin { showLinkPlugin(plugin) }
        switch target.subject {
        case let .file(url):
            open(url, landing: target.landing)
        case let .stashScene(id):
            dropListPlaylist()
            openStashScene(id: id, paths: [], landing: target.landing)
        }
    }

    /// Opens a file from outside the folder (Finder, ⌘O, Recent, a link): closing it goes back to Recent. `landing`:
    /// where a link asked to land in it; `then`: what became of the open.
    func open(_ url: URL, landing: LinkTarget? = nil, then done: ((OpenOutcome) -> Void)? = nil) {
        dropListPlaylist()
        returnTab = .recent
        stashScene = nil
        stashOpens += 1   // nor a scene still being looked for
        queueGate.cancel()   // a Stash answer still on its way must not open over this file
        openFile(url, landing: landing, then: done)
    }

    /// What became of an `openFile`: a stream opens a while later, and another open or a close may come first.
    enum OpenOutcome { case opened, failed, superseded }

    /// Counts opens and the closes and failures that replace a file on screen: a stream read in the background opens
    /// only if nothing came after it.
    private var fileOpens = 0
    /// The file being read for an open, until it opens or is abandoned, and how to stop its reads.
    private var openingURL: URL?
    private var openingCancellation: OpenCancellation?
    /// "Opening <name>…", shown only when an open takes longer than `openingMessageDelay` (most files open sooner), and
    /// the work item that shows it.
    private var openingMessage: String?
    private var openingMessageItem: DispatchWorkItem?
    private static let openingMessageDelay = 0.3

    /// Opens `url`; `fallbackPosition` is where to start when nothing is remembered for it (Stash's resume point).
    /// `landing` (a link's or plugin's position and segments) is applied once it is open; it goes with this open only,
    /// so a failed open or the user's next file never inherits it. Every file is read in the background (a file on a
    /// share can take seconds, and macOS may first ask whether the app may read the network volume); the previous file
    /// stops at once and `then` hears how the open ended.
    private func openFile(_ url: URL, origin: FileOrigin = .plain, fallbackPosition: Double? = nil,
                          landing: LinkTarget? = nil, then done: ((OpenOutcome) -> Void)? = nil) {
        StartupTrace.beginOpen(url.lastPathComponent)
        abandonOpening()
        folderWait.cancel()   // a step or delete asked for the file before this one
        cancelEdgeDrag()   // the marks it moves are this file's
        cancelStashTitleWait()
        stashSession?.leave()   // the file on screen until now
        deletingScene = false
        self.origin = origin
        if origin == .plain { stashScene = nil }
        failedScene = nil
        recentThumbnailer.cancel()   // the file's reads come first
        pluginGrabber?.stop()
        pluginGrabber = nil
        saveThumbnail()
        dropSceneSearch()
        videoView.clear()
        enhancer.reset()
        lastFrame = nil
        cropSampler?.cancel()
        cropSampler = nil
        aspectMode = .auto
        detectedCrop = nil
        resetAutoColor()   // computed for the previous file's picture; the first frame with a picture is analysed
        rebuildPlaylist(around: url)   // set even if open fails, so < and > can skip a broken file
        failedURL = nil
        openedAt = ProcessInfo.processInfo.systemUptime
        indexingShownAt = nil
        // The previous file stops now; the window stays responsive while the file answers.
        closeCore()
        startScreen.isHidden = true
        stashLibrary?.isHidden = true
        window?.representedURL = nil
        updateTitle(url)
        statsFileChanged()
        openingURL = url
        let cancellation = OpenCancellation()
        openingCancellation = cancellation
        let message = "Opening \(ByteSources.isRemote(url) ? "the stream" : url.lastPathComponent)…"
        let item = DispatchWorkItem { [weak self] in
            guard let self, openingURL == url, openingMessage == message else { return }
            osd.onClick = nil
            osd.show(message, duration: nil)   // stays until the open ends
        }
        openingMessage = message
        openingMessageItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openingMessageDelay, execute: item)
        let prepare = core.preparation(for: url, cancellation: cancellation)
        let open = fileOpens
        Task { [weak self] in
            // Blocking reads: on a dispatch thread, not the cooperative pool.
            let (result, facts) = await withCheckedContinuation {
                (answer: CheckedContinuation<(Result<PreparedOpen, Error>, URL?), Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try prepare() }
                    answer.resume(returning: (result, Self.warmedFileURL(url, opened: (try? result.get()) != nil)))
                }
            }
            guard let self, open == fileOpens else {
                try? result.get().discard()
                done?(.superseded)
                return
            }
            openingCancellation = nil   // the cache is the player's now
            endOpening()
            switch result {
            case let .success(prepared):
                finishOpen(url, prepared, facts: facts ?? url, fallbackPosition: fallbackPosition, landing: landing)
                done?(.opened)
            case let .failure(error):
                showFailure(OpenFailure(error), url: url, facts: facts)
                done?(.failed)
            }
        }
    }

    /// `url` as one NSURL whose resource values (Recent's type, the title bar's icon and name) were read here, on the
    /// preparation's thread: AppKit asks that object, so the main thread finds them in its cache. Each is a round trip
    /// to a share (`getattrlist`: 0.1–0.3 s per open on SMB, sampled 2026-10-26); a stream has none. A file that did
    /// not open (`opened` false) gets one only if it exists: that too is asked here, not on the main thread.
    nonisolated private static func warmedFileURL(_ url: URL, opened: Bool) -> URL? {
        guard url.isFileURL else { return opened ? url : nil }
        if !opened, !FileManager.default.fileExists(atPath: url.path) { return nil }
        let warmed = NSURL(fileURLWithPath: url.path)
        _ = try? warmed.resourceValues(forKeys: [.typeIdentifierKey, .contentTypeKey, .localizedNameKey, .effectiveIconKey])
        return warmed as URL
    }

    /// Whatever opened or was shown next replaces a file still being read: its answer is dropped and its reads stop.
    private func abandonOpening() {
        fileOpens += 1
        openingCancellation?.cancel()
        openingCancellation = nil
        endOpening()
    }

    /// An open is over (opened, failed or abandoned): its message goes, or never comes.
    private func endOpening() {
        guard openingURL != nil else { return }
        openingURL = nil
        openingMessageItem?.cancel()
        openingMessageItem = nil
        if let message = openingMessage, osd.visibleText == message { osd.hide() }
        openingMessage = nil
    }

    /// The rest of `openFile` once the file is read: the player takes it and the window follows.
    private func finishOpen(_ url: URL, _ prepared: PreparedOpen, facts: URL, fallbackPosition: Double?, landing: LinkTarget?) {
        openCore(prepared, fallbackPosition: fallbackPosition, landingTime: landing?.time)
        core.sceneInfo = pageSceneInfos[url]   // a page's name for it: its frames and clips are named so
        core.frameFolder = pageFrameFolders[url]
        StartupTrace.mark("core opened")
        if let landing, !landing.isEmpty { core.applyLanding(landing) }   // after fileopened: its segment events follow
        colorFileChanged()   // before anything below reads the colour
        startScreen.isHidden = true
        stashLibrary?.isHidden = true
        updatePrecisionWheel()
        // The proxy icon (⌘-click shows the path, drag moves the file) asks the file's volume for its icon and name:
        // 0.1–0.4 s on a NAS when asked cold, behind the file's own reads. `facts` has them from the preparation's
        // thread, but a URL's cached values last only until the main run loop turns: so it is set now, in this pass,
        // with Recent below (1–2 ms instead, measured 2026-10-26). A NAS folder read competes with the file's own
        // reads: it waits for the first picture. A stream has no folder, no file facts and no place in Recent.
        if url.isFileURL { window?.representedURL = facts }
        videoView.onNextPicture = { [weak self] in
            guard url.isFileURL else { return }
            self?.readFolder(of: url)
            self?.readFileFacts(of: url)
        }
        showPlaylistPosition(url, opening: true)
        positionPending = playlist?.totalCount == 1 && folderListing?.folder != folder(of: url) ? url : nil
        if url.isFileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(facts)
            var hidden = HiddenRecent()
            hidden.reveal(url)   // removed from Recent once: opening it again brings it back
        }
        videoView.rotationClockwise = core.info?.rotationClockwise ?? 0
        gestures.scrubber.videoFPS = core.info?.frameRate ?? 30
        updateGeometry(reshapeWindow: false)
        startCropSampler()
        enhancer.isEnabled = core.config.srStill
        videoView.scaleMode = core.config.scaleMode
        videoView.sharpen = core.config.sharpen
        updateColorCorrection()
        updateScreenPixelSize()
        configurePreview(force: true)
        // The window keeps its size: the picture fits into it (⌘1–⌘4 and aspect changes still size the window).
        window?.resizeIncrements = NSSize(width: 1, height: 1)   // no aspect left from the previous file
        revealSeekBar()
        statsFileChanged()
        StartupTrace.mark("open returned")
    }

    /// `core.open`, then the page's `fileopened`, then the segment event the open raised, if any (segments given before
    /// the open, or the previous file's leaving): the page hears of the file before anything about its segments.
    private func openCore(_ prepared: PreparedOpen, fallbackPosition: Double?, landingTime: Double? = nil) {
        holdsSegmentEvents = true
        heldSegmentEvent = nil
        core.open(prepared, fallbackPosition: fallbackPosition, landingTime: landingTime)
        holdsSegmentEvents = false
        pluginFileOpened()
        if let held = heldSegmentEvent {
            heldSegmentEvent = nil
            dispatchToPages(held)
            pushPluginState(force: true)
        }
    }

    /// The file whose open failed, while its reason is on screen: Return tries it again.
    private var failedURL: URL?

    /// Leaves the previous file and keeps the reason on screen until another file opens.
    /// `facts`: the file as `warmedFileURL` gave it, nil when it does not exist.
    private func showFailure(_ failure: OpenFailure, url: URL, facts: URL?) {
        abandonOpening()   // a stream still being read must not open over the reason
        cancelStashTitleWait()
        dropSceneSearch()
        closeCore()
        videoView.clear(blank: true)
        failedURL = url
        var failure = failure
        if case .stash = origin, failure.kind == .notFound, let path = stashScene?.paths.first {
            failure = OpenFailure(reason: "File not found", detail: path)
        }
        showFailureMessage(failure, name: url.lastPathComponent)
        startScreen.isHidden = false
        stashLibrary?.isHidden = true
        updatePrecisionWheel()
        videoView.onNextPicture = nil
        statsFileChanged()
        readFolder(of: url)
        window?.representedURL = facts
        window?.title = url.lastPathComponent
    }

    /// A file (or the reason it did not open, or a Stash scene being deleted) is on screen.
    var hasOpenFile: Bool {
        core.url != nil || openingURL != nil || failedURL != nil || failedScene != nil || deletingScene
    }

    /// ⌘W / the back button: leaves the file and shows where it came from; with no file, closes the window.
    func closeFile() {
        guard hasOpenFile else { window?.performClose(nil); return }
        abandonOpening()
        folderWait.cancel()
        recentThumbnailer.cancel()
        saveThumbnail(wait: true)   // the start screen shows it next
        cancelStashTitleWait()
        stashSession?.leave()
        dropSceneSearch()
        closeCore()   // keeps the position for the next open
        videoView.clear(blank: true)
        hideSeekBarWork?.cancel()
        seekBar.alphaValue = 0
        showBackButton(false, duration: 0)
        failedURL = nil
        failedScene = nil
        deletingScene = false   // a delete still running finishes without opening anything
        queueGate.cancel()
        origin = .plain
        showStartScreen(tab: returnTab)
    }

    private var failureHint: String? { returnTab == .stash ? "⌘W — back to Stash" : nil }

    /// Why a file did not open, in place of the recent files.
    private func showFailureMessage(_ failure: OpenFailure, name: String) {
        let keys = ["Return — try again", "PgUp / PgDn — another file in the folder", "⌘O — open"]
            + (failureHint.map { [$0] } ?? [])
        startScreen.showMessage(title: "Cannot open \(name)", reason: failure.reason, detail: failure.detail, hints: keys)
    }

    private func applyStartScreenConfig(_ config: Config) {
        startScreen.cardSize = CGFloat(config.startCardSize)
        startScreen.layoutMode = config.homeLayout
    }

    // MARK: Stash

    /// Asks Stash's page for the next (+1) or previous (−1) scene of its queue; the answer arrives as an automatic
    /// scene. One step at a time; no answer in 5 s is the end of the list.
    private func stepStashQueue(_ direction: Int, plays: Bool = false, atEnd: (() -> Void)? = nil) {
        guard let stashLibrary, queueGate.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
        queueDirection = direction
        queuePlays = plays
        stashSession?.saveProgress()   // the file plays on if Stash has no next scene; openFile leaves it otherwise
        stashLibrary.step(direction)
        DispatchQueue.main.asyncAfter(deadline: .now() + QueueStepGate.timeout) { [weak self] in
            guard let self, queueGate.timedOut(at: ProcessInfo.processInfo.systemUptime) else { return }
            if let atEnd { atEnd() } else { showMessage("End of the Stash list") }
        }
    }

    /// ▶ on a Stash scene page, the scene a queue step asked for, or one a link or plugin page named: find the file on
    /// the shares (mounting one if needed) or take Stash's stream, and open it.
    /// `plays`: start playing once open (autoadvance); `onFailure`: the scene could not be opened.
    /// Counts scene opens, so only the newest one's answer opens its file.
    private var stashOpens = 0

    private func openStashScene(_ scene: StashScene, landing: LinkTarget? = nil, plays: Bool = false,
                                onFailure: (() -> Void)? = nil) {
        if scene.automatic {
            // Stash also opens a page with autoplay=true on a reload: only a step of ours is answered.
            guard queueGate.isPending else { return }
            queueGate.answered()
        }
        guard let stashSession = makeStashSession() else {
            showMessage("No Stash server: set stash-url in Settings → Stash", duration: 4)
            onFailure?()
            return
        }
        returnTab = .stash
        stashOpens += 1
        let open = stashOpens
        stashSession.resolve(scene) { [weak self] result in
            // A later open (a quick next step through a list) wins over an answer that arrives after it.
            guard let self, open == stashOpens else { return }
            stashScene = scene   // only now: during a mount the scene on screen (and ⌘⌫'s dialog) is still the old one
            switch result {
            case let .file(url), let .stream(url):
                window?.makeFirstResponder(videoView)
                let (queuePlays, step) = (queuePlays, queueDirection > 0 ? Feedback.playlistNext : .playlistPrevious)
                openFile(url, origin: .stash(sceneID: scene.id, hasQueue: scene.hasQueue),
                         fallbackPosition: scene.resumeTime > 0 ? scene.resumeTime : nil, landing: landing) { [weak self] outcome in
                    guard let self else { return }
                    if scene.automatic, outcome != .superseded { hud.show(openedHUD(step)) }
                    switch outcome {
                    case .opened:
                        stashSession.began(sceneID: scene.id, duration: core.durationSeconds)
                        if (scene.automatic && queuePlays || plays) && core.isPaused { core.play() }
                    case .failed: onFailure?()
                    case .superseded: break
                    }
                }
            case let .failed(failure):
                showStashFailure(failure, scene: scene)
                onFailure?()
            }
        }
    }

    /// A scene whose file was not found on the shares: the reason stays on screen until another file opens.
    private func showStashFailure(_ failure: OpenFailure, scene: StashScene) {
        abandonOpening()   // a stream still being read must not open over the reason
        cancelStashTitleWait()
        dropSceneSearch()
        closeCore()
        videoView.clear(blank: true)
        failedURL = nil
        failedScene = scene
        origin = .stash(sceneID: scene.id, hasQueue: scene.hasQueue)
        let name = scene.paths.first.map { $0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? $0 }
        showFailureMessage(failure, name: name ?? "Stash scene \(scene.id)")
        startScreen.isHidden = false
        stashLibrary?.isHidden = true
        updatePrecisionWheel()
        videoView.onNextPicture = nil
        statsFileChanged()
        window?.representedURL = nil
        window?.title = name ?? "FrameScrub"
        window?.makeFirstResponder(videoView)
    }

    /// What pages said about what they open (`info`), by URL: a stream they name is shown and exported by that name.
    /// A page's playlist replaces them; at most `ListPlaylist.maxItems` are kept.
    private var pageSceneInfos: [URL: SceneInfo] = [:]
    /// The folders pages gave for the frames and clips of what they open (`frames`), by URL; kept as `pageSceneInfos`.
    private var pageFrameFolders: [URL: URL] = [:]

    private func notePageFacts(_ request: PluginRequest, replacing: Bool) {
        if replacing || pageSceneInfos.count + request.infos.count > ListPlaylist.maxItems { pageSceneInfos = [:] }
        pageSceneInfos.merge(request.infos) { $1 }
        if replacing || pageFrameFolders.count + request.frames.count > ListPlaylist.maxItems { pageFrameFolders = [:] }
        pageFrameFolders.merge(request.frames) { $1 }
    }

    /// A page that names folders for frames (`frames`) writes on this Mac's disk: allowed as its local files are, with
    /// the same question the first time.
    private func whenFramesAllowed(_ request: PluginRequest, origin: PluginOrigin, verb: String,
                                   then apply: @escaping () -> Void) {
        guard let folder = request.frames.values.first else { apply(); return }
        switch pluginPolicy.decision(forSavingFrom: origin) {
        case .allowed, .notMedia: apply()
        case .untrusted: pluginFailed(request, "\(verb): the page is not trusted")
        case .needsConsent:
            let asked = request.frames.count == 1 ? "to save frames in \(folder.path)" : "to save frames in its folders"
            askOpenConsent(origin, asked: asked, verb: verb, request: request, then: apply)
        }
    }

    /// The name a file goes by on screen: a page's `Title — Studio · date` for it, else its file name.
    private func displayName(_ url: URL) -> String {
        pageSceneInfos[url]?.displayTitle(fallback: url.lastPathComponent) ?? url.lastPathComponent
    }

    /// The window title, and an OSD line when the folder has other videos: "12 / 48 · name.mp4". A file from Stash
    /// reads `Title — Studio · date` instead; `opening` is the file just opened (a folder read must not flash it again).
    private func showPlaylistPosition(_ url: URL, opening: Bool = false) {
        updateTitle(url)
        if case .stash = origin {   // Stash's queue and the folder's "12 / 48" are not what names the scene
            if opening { announceStashFile(url) }
            return
        }
        guard let position = playlistPositionText else { return }
        showMessage("\(position) · \(displayName(url))")
    }

    private func updateTitle(_ url: URL) {
        if case .stash = origin { window?.title = stashTitle(for: url); return }
        guard let position = playlistPositionText else { window?.title = displayName(url); return }
        window?.title = "\(displayName(url)) — \(position)"
    }

    /// "12 / 48" in the folder, "3 / 10" in a page's list; nil when the file is alone in it.
    private var playlistPositionText: String? {
        if let listPlaylist { return listPlaylist.items.count > 1 ? listPlaylist.positionText : nil }
        guard let playlist, playlist.totalCount > 1 else { return nil }
        return playlist.positionText
    }

    /// The loaded details of the Stash scene on screen; nil while Stash has not answered (or failed to).
    private var loadedStashDetails: StashSceneDetails? {
        guard case let .stash(sceneID, _) = origin, let details = stashSession?.details, details.sceneID == sceneID,
              case let .loaded(loaded) = details.state else { return nil }
        return loaded
    }

    private func stashTitle(for url: URL) -> String {
        StashTitle.text(details: loadedStashDetails, fileName: url.lastPathComponent)
    }

    /// The OSD of a Stash file just opened: its title if Stash has answered, else the file name once 0.5 s have passed
    /// without an answer (an answer within them shows the title instead, see `stashDetailsChanged`).
    private func announceStashFile(_ url: URL) {
        cancelStashTitleWait()
        guard loadedStashDetails == nil else { showMessage(stashTitle(for: url)); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            stashTitleWait = nil
            showMessage(url.lastPathComponent)
        }
        stashTitleWait = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func cancelStashTitleWait() {
        stashTitleWait?.cancel()
        stashTitleWait = nil
    }

    /// Stash's answer about the scene on screen. The first one inside the wait takes the OSD's place; each one (also
    /// the re-reports after a write to Stash) updates the window title when it changed. Failures leave the file name.
    /// Every state shows in the stats' Stash section.
    private func stashDetailsChanged(_ sceneID: String, _ state: StashDetailsState) {
        refreshStats()
        guard case let .stash(id, _) = origin, id == sceneID, let url = core.url, case .loaded = state else { return }
        let title = stashTitle(for: url)
        if stashTitleWait != nil {
            cancelStashTitleWait()
            showMessage(title)
        }
        if window?.title != title { window?.title = title }
    }

    /// Shows the recent files (or the hint when there are none), until a file opens; a file that cannot be reached
    /// now shows faint. Files without a saved picture get their keyframe at the remembered position, made in the
    /// background.
    func showStartScreen(tab: StartTab? = nil) {
        let resume = ResumeStore()
        let urls = RecentFiles.shown(NSDocumentController.shared.recentDocumentURLs, hidden: HiddenRecent().paths)
        recentItems = urls.map { url in
            let entry = resume.entry(for: url)
            return RecentItem(url: url, thumbnail: thumbnails.image(for: url), position: entry?.position, duration: entry?.duration)
        }
        cancelStashTitleWait()
        startScreen.showGrid()
        showRecentCards()
        recentGeneration += 1
        let generation = recentGeneration
        Task { @MainActor [weak self] in
            let reachable = await PathAvailability.check(urls.map(\.path), timeout: .seconds(1))
            guard let self, self.recentGeneration == generation else { return }
            var changed = false
            for i in self.recentItems.indices where reachable[self.recentItems[i].url.path] == .some(false) {
                self.recentItems[i].isDimmed = true
                changed = true
            }
            if changed { self.showRecentCards() }
        }
        let jobs = recentItems.filter { $0.thumbnail == nil }.map {
            RecentThumbnailer.Job(url: $0.url, seconds: $0.position.flatMap { $0 > 0 ? $0 : nil })
        }
        recentThumbnailer.start(jobs) {
            [weak self] url, duration in
            MainActor.assumeIsolated {
                guard let self, let i = self.recentItems.firstIndex(where: { $0.url == url }) else { return }
                self.recentItems[i].thumbnail = self.recentItems[i].thumbnail ?? self.thumbnails.image(for: url)
                self.recentItems[i].duration = duration
                self.showRecentCards()
            }
        }
        startScreen.isHidden = false
        updatePrecisionWheel()
        failedURL = nil
        videoView.onNextPicture = nil
        statsFileChanged()
        window?.representedURL = nil
        window?.title = "FrameScrub"
        applyStartScreenFrame()
        showStartTab(tab ?? core.config.startTab)
    }

    /// The recent files as cards, with the pictures there are.
    private func showRecentCards() {
        let menu = [HomeMenuItem(id: "finder", title: "Show in Finder"), HomeMenuItem(id: "copy", title: "Copy Path"),
                    HomeMenuItem(id: "remove", title: "Remove from Recent")]
        startScreen.sections = [HomeSection(title: nil, items: recentItems.map { item in
            HomeCardItem(id: item.url.path, title: item.url.lastPathComponent,
                         subtitle: RecentFiles.timeText(position: item.position, duration: item.duration),
                         tooltip: item.url.path, symbol: "film",
                         progress: RecentFiles.progress(position: item.position, duration: item.duration),
                         isDimmed: item.isDimmed, menu: menu)
        })]
        for item in recentItems { startScreen.setImage(item.thumbnail, for: item.url.path) }
    }

    /// A card size step on the start screen: from the width on screen, saved as `start-card-size` with the grid
    /// scrolling (`home-layout=scroll`) so the size shows as asked; ⌘0 is the default size and `fit` again.
    /// File › Copy Path (⌥⌘C, as Finder's Copy as Pathname), and Recent's Copy Path.
    func copyPath(of url: URL? = nil) {
        guard let url = url ?? core.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showMessage("Path copied")
    }

    /// The file on screen, for Copy Path.
    var currentURL: URL? { core.url }

    /// The start screen shows the recent files (not Stash, not why a file failed): the card size items work.
    var showsRecentCards: Bool { showsStartTabs && startScreen.selectedTab == 0 }

    func resizeStartCards(_ resize: HomeResize) {
        let defaults = Config()
        let size = resize.size(from: startScreen.pictureWidth, range: 140...800).map(Double.init) ?? defaults.startCardSize
        let layout = resize == .reset ? defaults.homeLayout : .scroll
        do {
            try preferences.update(["start-card-size", "home-layout"]) {
                $0.startCardSize = size
                $0.homeLayout = layout
            }
        } catch {
            showMessage("Cannot save settings: \(error)", duration: 4)
            return
        }
        showMessage(resize == .reset ? "Cards: \(Int(size)) pt, fit" : "Cards: \(Int(size)) pt")
    }

    private func recentMenuChosen(_ path: String, _ item: String) {
        let url = URL(filePath: path, directoryHint: .notDirectory)
        switch item {
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([url])
        case "copy": copyPath(of: url)
        case "remove":
            var hidden = HiddenRecent()
            hidden.hide(url)
            showStartScreen(tab: .recent)
        default: break
        }
    }

    /// Recent or the Stash library on the start screen; without Stash set up, always Recent.
    private func showStartTab(_ wanted: StartTab) {
        let config = core.config
        let tab = config.stashEnabled ? wanted : .recent
        startScreen.tabs = config.stashEnabled ? ["Recent", "Stash"] : []
        startScreen.selectedTab = tab == .stash ? 1 : 0
        if tab == .stash, let library = makeStashLibrary() {
            StartupTrace.mark("stash shown")
            library.isHidden = false
            library.focusPage()
        } else {
            stashLibrary?.isHidden = true
            window?.makeFirstResponder(videoView)
        }
    }

    private func makeStashLibrary() -> StashLibraryView? {
        if let stashLibrary { return stashLibrary }
        guard let container = window?.contentView, let url = URL(string: core.config.stashURL) else { return nil }
        let library = StashLibraryView(url: url, interceptors: [
            .scenePlayer(
                onOpen: { [weak self] scene in
                    if !scene.automatic { self?.dropListPlaylist() }   // ▶ on a scene page; a queue step is ours
                    self?.openStashScene(scene)
                },
                onBridgeMissing: { [weak self] in
                    self?.showMessage("Stash player not replaced: unsupported Stash version", duration: 5)
                })
        ])
        library.onPageLoaded = { StartupTrace.markOnce("stash page loaded") }
        _ = makeStashSession()
        library.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(library, positioned: .above, relativeTo: videoView)   // under the start screen's switch
        NSLayoutConstraint.activate([
            library.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            library.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            library.topAnchor.constraint(equalTo: startScreen.contentTop),
            library.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        stashLibrary = library
        return library
    }

    /// The Stash session, made with the Stash page or for the first scene a link or plugin page names (that needs no
    /// page); nil without `stash-url`.
    private func makeStashSession() -> StashSession? {
        if let stashSession { return stashSession }
        guard core.config.stashEnabled else { return nil }
        let session = StashSession(config: core.config)
        session.onStatus = { [weak self] in self?.showMessage($0, duration: 15) }
        session.onDetails = { [weak self] sceneID, state in self?.stashDetailsChanged(sceneID, state) }
        session.sample = { [weak self] () -> (position: Double, forward: Bool, speed: Double)? in
            guard let core = self?.core, core.url != nil else { return nil }
            return (core.currentSeconds, !core.isPaused && core.direction > 0, core.speed)
        }
        stashSession = session
        return session
    }

    /// Refreshes the start screen after the recent list changed (Clear Menu); does nothing while a file is open.
    func showStartScreenIfEmpty() {
        if !startScreen.isHidden { showStartScreen() }
    }

    /// Shows the window above other apps' windows, restoring it if minimized.
    func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private let thumbnails = ThumbnailStore()
    private lazy var recentThumbnailer = RecentThumbnailer(store: thumbnails)

    /// Keeps the picture on screen (as shown: upright, cut, square pixels) for the start screen's recent files.
    /// The picture of the file being left, for the start screen. Scaling and encoding it took the main thread at
    /// every switch of file; it runs in the background now (`wait`: at quit, so it is written before the app ends).
    private func saveThumbnail(wait: Bool = false) {
        guard let url = core.url, let image = videoView.displayedImage else { return }
        let picture = videoView.geometry.applied(to: image)
        let thumbnails = thumbnails
        let work = { thumbnails.save(picture, for: url, context: Self.thumbnailContext) }
        if wait { thumbnailQueue.sync(execute: work) } else { thumbnailQueue.async(execute: work) }
    }
    private let thumbnailQueue = DispatchQueue(label: "framescrub.thumbnail-save", qos: .utility)

    /// Stops rendering and shuts the core down (cancels export, filler threads, audio).
    func shutdown() {
        abandonOpening()   // a stream answering later must not open in a closed window
        stashSession?.flushBeforeQuit()
        for write in slotWrites.values where write.isValid { write.fire() }   // a slot changed just before quitting
        slotWrites = [:]
        recentThumbnailer.cancel()
        saveThumbnail(wait: true)
        memoryPressure?.cancel()
        memoryPressure = nil
        cancelMouseInput()   // and the button timer; the mouse itself is released at termination (`LogiMouse.follow`)
        statsTimer?.invalidate()
        statsTimer = nil
        previewProvider?.stop()
        previewProvider = nil
        cropSampler?.cancel()
        dropSceneSearch()
        videoView.stop()
        core.close()
    }

    /// Leaves the file (its position is kept for the next open); framescrub.conf's colour applies again.
    private func closeCore() {
        core.close()
        colorFileChanged()
    }

    /// A file opened or closed: the player gets framescrub.conf with the file's and its folders' colour over it.
    /// The views follow in the caller (`openFile`: `updateColorCorrection`); with no file nothing is drawn.
    private func colorFileChanged() {
        colorMemory.open(core.url, size: core.readCache?.fileSize)
        core.apply(effectiveConfig())
    }

    /// `globalConfig` with the open file's colour laid over it (colour memory §3); notes the origin for the stats.
    private func effectiveConfig() -> Config {
        let (config, origin) = colorMemory.effective(global: globalConfig)
        colorOrigin = origin
        return config
    }

    /// framescrub.conf changed (Preferences, menus, a reload, a default colour save).
    func applyConfig(_ global: Config) {
        globalConfig = global
        applyEffectiveConfig()
    }

    /// Settings or the file's colour changed: bring the running player and the views in line with the effective config.
    private func applyEffectiveConfig() {
        let config = effectiveConfig()
        let sortChanged = config.playlistSort != core.config.playlistSort
        let stashChanged = config.stashURL != core.config.stashURL || config.stashAPIKey != core.config.stashAPIKey
            || config.stashPathMap != core.config.stashPathMap || config.stashStream != core.config.stashStream
        // The scene search's decoder follows `hwdec` too: the next press makes a new one.
        if config.hwdec != core.config.hwdec { dropSceneSearch() }
        applyPluginConfig(config, previous: core.config)
        core.apply(config)
        sceneSearch?.threshold = config.sceneThreshold
        sceneSearch?.lookahead = config.sceneLookahead
        sceneSearch?.checkTime = config.sceneCheckTime
        sceneSearch?.searchTime = config.sceneSearchTime
        if sortChanged, let url = playlistAnchor {
            rebuildPlaylist(around: url)
            if core.url != nil { showPlaylistPosition(url) }
        }
        gestures.scrubber.settings = config.scrub
        buttons.update(map: inputMap, longPressMilliseconds: config.mouseLongPress)
        mouseBridge?.apply(config: config, map: inputMap)
        updatePrecisionWheel()   // wheel-precision may have changed
        enhancer.isEnabled = config.srStill
        videoView.scaleMode = config.scaleMode
        videoView.sharpen = config.sharpen
        if !config.autoColor, autoColorFrame != nil || autoColorSeconds != nil { resetAutoColor() }
        updateColorCorrection()   // a new threshold re-decides from the stored Δ
        if config.autoColor, let lastFrame { checkSceneCut(lastFrame) }   // turned on in Settings: a first frame is a cut
        window?.level = config.ontop ? .floating : .normal
        playlistPanel.fontSize = CGFloat(config.playlistFontSize)
        applyStartScreenConfig(config)
        if stashChanged, let library = stashLibrary {   // a new address, key or rules: a new page and session
            stashSession?.leave()
            library.removeFromSuperview()
            stashLibrary = nil
            stashSession = nil
        }
        if showsStartTabs, stashChanged || (startScreen.tabs.count == 2) != config.stashEnabled { showStartTab(config.startTab) }
        statsPanel.fontSize = CGFloat(config.statsFontSize)
        refreshEnhancement()
        configurePreview()
    }

    /// Vibrance (when on) and the automatic adjustments, for the screen and, with `save-color`, saved frames.
    /// `fade` blends a recomputed correction in instead of switching at once.
    private func updateColorCorrection(fade: Bool = false) {
        let config = core.config
        let needed = autoColorDelta.map { AutoColorSchedule.isNeeded(delta: $0, threshold: config.autoColorThreshold) } ?? true
        let share = autoColorDelta.map {
            AutoColorSchedule.rampStrength(delta: $0, threshold: config.autoColorThreshold, full: config.autoColorFull)
        } ?? 1
        let color = ColorCorrection(vibrance: config.vibranceOn ? config.vibrance : 0, auto: needed ? autoColor : [],
                                    autoStrength: config.autoColorStrength * share, autoFilters: config.autoColorFilters,
                                    autoVibranceGain: config.autoColorVibranceGain)
        videoView.setColorCorrection(color, fade: fade)
        core.colorCorrection = color
    }

    /// `c`: turns `auto-color` on (analysing the frame on screen, even a dark one) or off for this file.
    private func toggleAutoColor() {
        let enable = !core.config.autoColor
        if enable, core.url != nil, let frame = lastFrame, frame.dynamicRange == .sdr, let image = videoView.shownPicture {
            autoColorSession += 1   // drops a background analysis of an older frame
            let analysis = ColorCorrection.analyse(image)
            autoColor = analysis.steps
            autoColorDelta = analysis.delta
            autoColorWaitingForPicture = false
            autoColorFrame = frame.number
            autoColorSeconds = core.index?.seconds(forPTS: frame.pts) ?? core.currentSeconds
        }
        let outcome = colorMemory.toggle(.autoColor, global: globalConfig)
        guard runColorOutcome(outcome), enable else { return }   // runColorOutcome redraws; off: its OSD as is
        let on = outcome.osd   // "Auto colour: on · file"
        let interval = core.config.autoColorInterval
        let every = interval > 0 ? ", every \(String(format: "%g", interval)) s" : ""
        guard let frame = lastFrame else { return }
        guard frame.dynamicRange == .sdr else { showMessage("\(on), for SDR files (this one is HDR)"); return }
        guard !autoColor.isEmpty else { showMessage("\(on)\(every), nothing to correct here"); return }
        let delta = autoColorDelta.map { String(format: "Δ %.1f", $0) } ?? ""
        if let autoColorDelta, !AutoColorSchedule.isNeeded(delta: autoColorDelta, threshold: core.config.autoColorThreshold) {
            showMessage("\(on)\(every) (frame \(frame.number): \(delta), this scene needs none)")
            return
        }
        let kinds = AutoColorFilter.allCases.filter { kind in autoColor.contains { $0.kind == kind } }
        let used = kinds.filter(core.config.autoColorFilters.contains).map(\.rawValue)
        let off = kinds.filter { !core.config.autoColorFilters.contains($0) }.map(\.rawValue)
        showMessage("\(on)\(every) (frame \(frame.number): \(delta), \(used.isEmpty ? "nothing chosen" : used.joined(separator: ", "))"
                    + (off.isEmpty ? ")" : "; off in settings: \(off.joined(separator: ", ")))"))
    }

    /// `⇧C` / `⇧V` (`folder` false: framescrub.conf) and `⌥C` / `⌥V` (the folder): the effective values of `set`
    /// become that level's; the picture stays as it is. A default save writes framescrub.conf first and clears the
    /// lower levels only once that worked.
    private func saveColor(_ set: ColorSet, folder: Bool) {
        let before = globalConfig
        let outcome = colorMemory.save(set, on: folder ? .folder : nil, global: before)
        if !folder, outcome.haptic != .error {
            do {
                try preferences.update(Array(outcome.globalWrites.keys)) { $0 = $0.applying(outcome.globalWrites).config }
            } catch {
                runColorOutcome(ColorMemory.Outcome(osd: "Could not save framescrub.conf", haptic: .error))
                return
            }
            colorMemory.finishDefaultSave(set, global: before)
        }
        runColorOutcome(outcome)
    }

    /// Shows and plays what a colour command decided and, unless it failed (no video), redraws with the new effective
    /// config. The colour commands play their own haptic (`switchesSomething` keeps the generic `.toggle` out).
    @discardableResult
    private func runColorOutcome(_ outcome: ColorMemory.Outcome) -> Bool {
        if let haptic = outcome.haptic { haptics.play(haptic) }
        showMessage(outcome.osd)
        guard outcome.haptic != .error else { return false }
        applyEffectiveConfig()
        return true
    }

    private func resetAutoColor() {
        autoColor = []
        autoColorDelta = nil
        autoColorFrame = nil
        autoColorSeconds = nil
        autoColorWaitingForPicture = false
        sceneCutAnalysis?.cancel()
        sceneCutAnalysis = nil
        sceneSampling.reset()
        autoColorSession += 1   // drops an analysis still running for the old state and restarts the cut detector
    }

    /// Hands a shown frame to the scene-cut detector as `SceneSampling` allows; a frame that comes too early is
    /// replaced by the one on screen when its 1/30 s slot ends.
    private func checkSceneCut(_ frame: DecodedFrame) {
        guard core.config.autoColor, frame.dynamicRange == .sdr, let image = videoView.displayedImage else { return }
        switch sceneSampling.decide(frame: frame.number, at: ProcessInfo.processInfo.systemUptime) {
        case .now:
            sceneCutWorker.submit(SceneRequest(image: image, session: autoColorSession))
        case .later(let wait):
            guard !signatureCatchUpScheduled else { return }
            signatureCatchUpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                signatureCatchUpScheduled = false
                if let lastFrame { checkSceneCut(lastFrame) }
            }
        case .skip:
            break
        }
    }

    private func sceneCut(session: Int) {
        guard session == autoColorSession, core.config.autoColor else { return }
        sceneCutAnalysis?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, session == autoColorSession else { return }
            sceneCutAnalysis = nil
            analyseFrameOnScreen()
        }
        sceneCutAnalysis = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Analyses the frame on screen in the background (only the newest request runs); the result fades in.
    private func analyseFrameOnScreen() {
        guard core.config.autoColor, let frame = lastFrame, frame.dynamicRange == .sdr, let index = core.index,
              let image = videoView.shownPicture else { return }
        // Already analysed (by `V`, even a dark frame, or before a pause): same result. A dark result leaves
        // `autoColorFrame` alone, so waiting for a picture still retries.
        guard frame.number != autoColorFrame else { return }
        autoColorSeconds = index.seconds(forPTS: frame.pts)
        autoColorWorker.submit(AutoColorRequest(image: image, frame: frame.number, session: autoColorSession))
    }

    /// Besides scene cuts: every 1 s of video while the last analysis met a black frame, and with
    /// `auto-color-interval` once the frame on screen is that far from the analysed one.
    private func recomputeAutoColorIfDue(_ frame: DecodedFrame) {
        guard core.config.autoColor, frame.dynamicRange == .sdr, let index = core.index else { return }
        let interval = autoColorWaitingForPicture ? 1 : core.config.autoColorInterval
        guard AutoColorSchedule.isDue(interval: interval, analysedAt: autoColorSeconds, seconds: index.seconds(forPTS: frame.pts))
        else { return }
        analyseFrameOnScreen()
    }

    private func applyRecomputedAutoColor(_ analysis: AutoColorAnalysis?, frame: Int, session: Int) {
        guard session == autoColorSession, core.config.autoColor else { return }
        guard let analysis else { autoColorWaitingForPicture = true; return }
        autoColor = analysis.steps
        autoColorDelta = analysis.delta
        autoColorFrame = frame
        autoColorWaitingForPicture = false
        updateColorCorrection(fade: true)
    }

    /// The bindings in effect, for the key hints in the menus.
    var currentInputMap: InputMap { inputMap }

    /// The user's bindings changed (settings, input.conf): the page's action keys are added again on top.
    func applyInputMap(_ map: InputMap) {
        baseInputMap = map
        rebuildInputMap()
    }

    /// Sets the effective map from the base map and the declared actions (their keys count while the page is in a slot,
    /// shown or hidden), and brings an open key help up to date.
    private func rebuildInputMap() {
        inputMap = baseInputMap.merging(shownPluginActions).map
        gestures.inputMap = inputMap
        buttons.update(map: inputMap, longPressMilliseconds: core.config.mouseLongPress)
        mouseBridge?.apply(config: core.config, map: inputMap)
        keyHelp.refresh(inputMap, pluginActions: shownPluginActions)
    }

    /// The declared actions as the key help lists them: those of the pages in a slot (`PluginActionPolicy`).
    private var shownPluginActions: [PluginAction] {
        let inSlot = Set(slots?.pages.map(\.token) ?? [])
        return pluginActions.flatMap { PluginActionPolicy.bindable($0.actions, inSlot: inSlot.contains($0.page)) }
    }

    /// A page declared its actions (an empty list withdraws them). The reply says what the keys become; with the
    /// page's slot hidden that is what they will become once it is shown (nothing is bound before). A key an earlier
    /// page claimed is `key taken`.
    private func declarePluginActions(_ actions: [PluginAction], page: Int) -> PluginActionsReply {
        if let i = pluginActions.firstIndex(where: { $0.page == page }) {
            pluginActions[i].actions = actions
        } else {
            pluginActions.append((page, actions))
        }
        rebuildInputMap()
        let earlier = pluginActions.prefix { $0.page != page }.flatMap(\.actions)
        let outcome = baseInputMap.merging(earlier).map.merging(actions)
        return PluginActionsReply(bound: outcome.bound, refused: outcome.refused)
    }

    /// A new page committed (or the same one again, or the page process died): what the old one declared is void.
    private func clearPluginActions(of page: Int) {
        guard let i = pluginActions.firstIndex(where: { $0.page == page }) else { return }
        pluginActions.remove(at: i)
        rebuildInputMap()
    }

    /// A key bound to a page action: the first page in a slot that declared the name hears it, shown or hidden.
    private func runPluginAction(_ name: String) {
        let inSlot = Set(slots.pages.map(\.token))
        guard let entry = pluginActions.first(where: { entry in
                  PluginActionPolicy.shouldDispatch(name, declared: entry.actions, inSlot: inSlot.contains(entry.page))
              }), let page = slots.page(withToken: entry.page) else {
            showMessage("No plugin action: \(name)")
            return
        }
        let frame = core.displayedFrame ?? core.position   // what is on screen, not a seek in flight
        let t = core.index?.seconds(forFrame: frame) ?? core.positionSeconds
        page.dispatch(.action(name: name, t: t, frame: frame))
    }

    /// Shows scan progress once the scan has run for a second and the OSD is free, then refreshes it at most
    /// once a second while it stays on screen; never replaces another message.
    private func showIndexing(_ fraction: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - openedAt >= 1, now - (indexingShownAt ?? 0) >= 1 else { return }
        let showing = osd.visibleText?.hasPrefix("Indexing") == true
        guard indexingShownAt == nil ? (osd.visibleText == nil || showing) : showing else { return }
        indexingShownAt = now
        showMessage("Indexing \(Int(fraction * 100))%")
    }

    func showMessage(_ text: String, duration: Double = 1.5) {
        // Only the player's "Saved…" OSD is clickable; any other message must not keep its handler.
        osd.onClick = nil
        osd.show(text, duration: duration)
    }

    // MARK: Layout

    private func buildViews(in window: NSWindow) {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container
        for view in [videoView, startScreen, hud, osd, seekBar, backButton, previewView, keyHelp, goToField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        container.addLayoutGuide(visibleArea)
        videoEdges = [
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        visibleEdges = [
            visibleArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            visibleArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            visibleArea.topAnchor.constraint(equalTo: container.topAnchor),
            visibleArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(videoEdges + visibleEdges + [
            startScreen.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            startScreen.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            startScreen.topAnchor.constraint(equalTo: videoView.topAnchor),
            startScreen.bottomAnchor.constraint(equalTo: videoView.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: visibleArea.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: visibleArea.trailingAnchor),
            hud.topAnchor.constraint(equalTo: visibleArea.topAnchor),
            hud.bottomAnchor.constraint(equalTo: visibleArea.bottomAnchor),
            keyHelp.leadingAnchor.constraint(equalTo: visibleArea.leadingAnchor),
            keyHelp.trailingAnchor.constraint(equalTo: visibleArea.trailingAnchor),
            keyHelp.topAnchor.constraint(equalTo: visibleArea.topAnchor),
            keyHelp.bottomAnchor.constraint(equalTo: visibleArea.bottomAnchor),
            goToField.centerXAnchor.constraint(equalTo: visibleArea.centerXAnchor),
            goToField.topAnchor.constraint(equalTo: visibleArea.topAnchor, constant: 16),
            osd.leadingAnchor.constraint(equalTo: visibleArea.leadingAnchor, constant: 16),
            osd.trailingAnchor.constraint(lessThanOrEqualTo: visibleArea.trailingAnchor, constant: -16),
            seekBar.leadingAnchor.constraint(equalTo: visibleArea.leadingAnchor, constant: 16),
            seekBar.trailingAnchor.constraint(equalTo: visibleArea.trailingAnchor, constant: -16),
            seekBar.bottomAnchor.constraint(equalTo: visibleArea.bottomAnchor, constant: -12),
            seekBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: visibleArea.leadingAnchor, constant: 16),
            backButton.topAnchor.constraint(equalTo: visibleArea.topAnchor, constant: 16),
            previewView.bottomAnchor.constraint(equalTo: seekBar.topAnchor, constant: -6),
        ])
        previewLeading = previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16)
        previewLeading.isActive = true
        osdTop = osd.topAnchor.constraint(equalTo: visibleArea.topAnchor, constant: 16)
        osdTop.isActive = true
        buildStatsPanel(in: container)
        buildSlots(in: container)
        seekBar.onHover = { [weak self] in
            self?.showCursorAfterScrub()
            self?.hover($0)
        }
        seekBar.onScroll = { [weak self] in self?.scrollOverSeekBar($0) }
        seekBar.onEnterExit = { [weak self] in
            self?.showCursorAfterScrub()
            self?.updatePrecisionWheel()
        }
        let transport = seekBar.transport
        transport.onPrevious = { [weak self] in self?.runFromSeekBar(.playlistPrev) }
        transport.onNext = { [weak self] in self?.runFromSeekBar(.playlistNext) }
        transport.onToggleMute = { [weak self] in self?.runFromSeekBar(.cycleMute) }
        transport.onVolume = { [weak self] in
            self?.core.setVolume($0)
            self?.revealSeekBar()
        }
        core.onIndexReady = { [weak self] in
            self?.previewProvider?.updateIndex($0)
            self?.pluginGrabber?.updateIndex($0)
            self?.sceneSearch?.updateIndex($0)
        }
        core.onIndexProgress = { [weak self] in self?.showIndexing($0) }
        seekBar.alphaValue = 0
        backButton.alphaValue = 0
        backButton.onClick = { [weak self] in self?.closeFile() }
        startScreen.isHidden = true   // shown by showStartScreen() when the app starts with nothing to open
        startScreen.supportsTabs = false   // one window: ⌘ / ⇧ / the middle button open here too
        startScreen.aspect = 9.0 / 16
        startScreen.emptyHint = "Drop a video here or press ⌘O"
        startScreen.onTab = { [weak self] index in
            guard let self else { return }
            let tab: StartTab = index == 1 ? .stash : .recent
            do { try preferences.update(["start-tab"]) { $0.startTab = tab } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            showStartTab(tab)
        }
        startScreen.onCard = { [weak self] path, _ in
            guard let self else { return }
            open(URL(filePath: path, directoryHint: .notDirectory))   // not looked up: a share answers over the network
            self.window?.makeFirstResponder(videoView)
        }
        startScreen.onMenu = { [weak self] path, item in self?.recentMenuChosen(path, item) }
        startScreen.onResize = { [weak self] in self?.resizeStartCards($0) }
        playlistPanel.onSelect = { [weak self] row in
            guard let self else { return }
            if listPlaylist != nil {
                if listRowIndices.indices.contains(row) { openListItem(at: listRowIndices[row]) }
            } else if let playlist, playlist.files.indices.contains(row) {
                openFile(playlist.files[row])
            }
            self.window?.makeFirstResponder(videoView)   // not the buildViews parameter (would retain the window)
            slots.playlistChosePlay()
        }
        playlistPanel.onFilter = { [weak self] text in
            guard let self else { return }
            playlistFilter = text
            if listPlaylist != nil { updatePlaylistPanel(); return }
            guard let url = playlistAnchor else { return }
            rebuildPlaylist(around: url)
            updateTitle(url)
        }
        playlistPanel.onSort = { [weak self] in self?.setPlaylistSort($0) }
        playlistPanel.onSubmitFilter = { [weak self] in
            guard let self else { return }
            if let listPlaylist {
                self.window?.makeFirstResponder(videoView)
                if let target = listRowIndices.first(where: { $0 != listPlaylist.currentIndex }) {
                    openListItem(at: target)
                    slots.playlistChosePlay()
                }
                return
            }
            whenFolderRead { [weak self] in
                guard let self, let playlist else { return }
                let anchor = playlistAnchor
                self.window?.makeFirstResponder(videoView)   // not the buildViews parameter
                if let target = playlist.files.first(where: { $0 != anchor }) {   // the first match other than this file
                    openFile(target)
                    slots.playlistChosePlay()
                }
            }
        }
        playlistPanel.onEndFilter = { [weak self] in
            guard let self else { return }
            _ = slots.escape(in: playlistPanel)
            self.window?.makeFirstResponder(videoView)
        }

        goToField.onSubmit = { [weak self] text in
            guard let self, let target = GoToTarget.parse(text) else { return false }
            positionWillMove()
            core.inputIsFresh = true
            haptics.from(.keyboard) { self.core.goTo(target) }
            return true
        }
        goToField.onClose = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(videoView)   // not the buildViews parameter (would retain the window)
        }
        videoView.onKeyDown = { [weak self] in self?.handleKey($0) }
        videoView.onKeyUp = { [weak self] in
            if $0.keyCode == self?.holdKeyCode { self?.endHoldSpeed() }
        }
        videoView.onScroll = { [weak self] in self?.handleScroll($0) }
        videoView.onUndo = { [weak self] in
            guard let self else { return }
            haptics.from(menuSource) { self.core.undoMarks() }
        }
        videoView.onRedo = { [weak self] in
            guard let self else { return }
            haptics.from(menuSource) { self.core.redoMarks() }
        }
        videoView.canUndo = { [weak self] in self?.core.canUndoMarks ?? false }
        videoView.canRedo = { [weak self] in self?.core.canRedoMarks ?? false }
        videoView.onMagnify = { [weak self] in self?.handleMagnify($0) }
        videoView.onMouseButton = { [weak self] in self?.runBinding(KeyChord(key: $0)) }
        videoView.onLeftClick = { [weak self] in self?.slots.hideOverlays() }
        videoView.onOtherButton = { [weak self] button, keys, rightHeld, time in
            self?.buttons.appKitDown(button, keys: keys, rightHeld: rightHeld, at: time)
        }
        videoView.onOtherButtonUp = { [weak self] button, time in self?.buttons.appKitUp(button, at: time) }
        videoView.onMouseMoved = { [weak self] in
            self?.showCursorAfterScrub()
            self?.revealSeekBar()
            self?.updatePrecisionWheel()
        }
        videoView.onEnterExit = { [weak self] in
            self?.showCursorAfterScrub()
            self?.updatePrecisionWheel()
        }
        videoView.onOpenFile = { [weak self] in self?.open($0) }
        videoView.onDisplayRatioChange = { [weak self] in self?.refreshEnhancement() }
        videoView.onTick = { [weak self] in self?.core.tick() }
        seekBar.onSeek = { [weak self] fraction in
            guard let self else { return }
            releasePin(ifPointerAt: fraction)
            positionWillMove()
            haptics.from(.menu) { self.core.seekFromBar(toFrame: self.previewPin?.frame ?? self.frame(atBarFraction: fraction)) }   // the bar is silent
            revealSeekBar()
        }
        window.makeFirstResponder(videoView)
    }

    /// A menu item's command (its key equivalent counts as the keyboard).
    func runCommand(_ command: Command) { runInput(command, from: menuSource) }

    /// Edit > Copy (⌘C, nil target) reaches the player through the responder chain (VideoView -> window ->
    /// this controller), so a focused text field handles it first and the player copies the frame otherwise.
    @objc func copy(_ sender: Any?) { runInput(.copyFrame, from: menuSource) }

    /// A haptic event from outside the player (a clip written by the app's queue, or not).
    func playHaptic(_ event: HapticEvent) { haptics.play(event) }

    /// For the checkmark of Playback > Marks > Play Marks Only.
    var playMarksOnly: Bool { core.playMarksOnly }

    private func applyWindowSize(_ request: WindowSizing.Request) {
        guard let window, let upright = uprightVideoSize, let screen = window.screen ?? NSScreen.main else { return }
        let video = videoView.geometry.displaySize(of: upright)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        let result = WindowSizing.contentSize(for: request, video: video, backingScale: screen.backingScaleFactor,
                                              available: available)
        window.contentAspectRatio = result.size
        guard !isFullScreen else { return }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)   // a new size stays where the window is
        window.setContentSize(result.size)
        place(window, center: center)
        if let percent = result.fittedPercent { showMessage("Window: fit (\(percent)%)") }
    }

    // MARK: Aspect

    /// The open file's picture size after rotation, in its own pixels.
    private var uprightVideoSize: CGSize? {
        guard let info = core.info else { return nil }
        let sideways = info.rotationClockwise % 180 != 0
        return CGSize(width: sideways ? info.height : info.width, height: sideways ? info.width : info.height)
    }

    /// Applies `aspectMode` and the detected crop to the screen and to saved frames; a new shape reshapes the window
    /// (same height, centre kept).
    private func updateGeometry(reshapeWindow: Bool) {
        guard let info = core.info, let upright = uprightVideoSize else { return }
        let geometry = DisplayGeometry.resolve(mode: aspectMode, upright: upright, rotationClockwise: info.rotationClockwise,
                                               sampleAspect: info.sampleAspect, detectedCrop: detectedCrop)
        let changed = geometry.displaySize(of: upright) != videoView.geometry.displaySize(of: upright)
        videoView.geometry = geometry
        core.displayGeometry = geometry
        guard reshapeWindow, changed, let content = window?.contentView else { return }
        applyWindowSize(.keepHeight(content.bounds.height))
    }

    /// Black bars are looked for once per file, on keyframes spread over it, by a decoder of its own.
    private func startCropSampler() {
        guard let url = core.url, let index = core.index, let info = core.info else { return }
        let sampler = CropSampler(url: url, index: index, rotationClockwise: info.rotationClockwise, readCache: core.readCache,
                                  policy: core.networkPolicy)
        cropSampler = sampler
        sampler.start { [weak self] crop in
            MainActor.assumeIsolated {
                guard let self, self.cropSampler === sampler, let crop else { return }
                self.detectedCrop = crop
                if self.aspectMode == .auto { self.updateGeometry(reshapeWindow: true) }
            }
        }
    }

    private func cycleAspect() {
        guard let upright = uprightVideoSize else { return }
        aspectMode = aspectMode.next
        updateGeometry(reshapeWindow: true)
        let shown = videoView.geometry.displaySize(of: upright)
        showMessage("Aspect: \(aspectMode.label) (\(String(format: "%.2f", shown.width / shown.height)):1)")
    }

    private var aspectStatus: String {
        guard let info = core.info, let upright = uprightVideoSize else { return "Aspect: -" }
        return videoView.geometry.statusText(mode: aspectMode, upright: upright, sampleAspect: info.sampleAspect)
    }

    /// The window keeps its frame across launches (UserDefaults: window state, not a setting); a file still sizes it
    /// on open around the same centre.
    private static let frameKey = "WindowFrame"

    /// The wheel mode the user chose (SmartShift's free spin or ratchet), remembered as a Bool: absent means free
    /// spin. Settings binds to the same key.
    static let wheelFreeSpinKey = "wheelFreeSpin"

    private static var savedFrame: CGRect? { frame(forKey: frameKey) }

    private static func frame(forKey key: String) -> CGRect? {
        if let frame = UserDefaults.standard.string(forKey: key).map(NSRectFromString), frame.width > 0, frame.height > 0 {
            return frame
        }
        return nil
    }

    /// The start screen is showing Recent or Stash (not why a file failed).
    private var showsStartTabs: Bool { !startScreen.isHidden && failedURL == nil && failedScene == nil }

    /// Back on the start screen: the window keeps its size and place; only the video shape stops holding its aspect.
    private func applyStartScreenFrame() {
        guard let window, !isFullScreen else { return }
        window.resizeIncrements = NSSize(width: 1, height: 1)   // drops the video's contentAspectRatio
    }

    private func restoreFrame(of window: NSWindow) {
        let size = window.frame.size
        let saved = Self.savedFrame
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = NSScreen.main?.visibleFrame ?? screens.first ?? .zero
        window.setFrame(WindowPlacement.frame(saved: saved, fallbackSize: size, screens: screens, main: main), display: false)
    }

    private func place(_ window: NSWindow, center: CGPoint?) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = NSScreen.main?.visibleFrame ?? screens.first ?? .zero
        window.setFrameOrigin(WindowPlacement.origin(size: window.frame.size, center: center, screens: screens, main: main))
    }

    private func rememberFrame() {
        guard let window, window.isVisible, !isFullScreen else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    // MARK: Input

    /// A key for the player, from the video view or one the plugin page left unhandled; `stillDown` is false when the
    /// page's answer came after the key-up (a hold must not start then).
    private func handleKey(_ event: NSEvent, stillDown: Bool = true) {
        hideCursorOverVideo()
        if event.keyCode == 53, core.edgeDrag != nil {   // Esc cancels a live edge drag, and only that
            edgeDragSuppressed = edgeDragOwner
            cancelEdgeDrag()
            return
        }
        if keyHelp.isShown, event.keyCode == 53 { keyHelp.hide(); return }   // Esc closes the cheat sheet first
        if let failedURL, event.keyCode == 36 || event.keyCode == 76 { openFile(failedURL, origin: origin); return }   // Return / Enter: try again
        if let failedScene, event.keyCode == 36 || event.keyCode == 76 { openStashScene(failedScene); return }
        if !startScreen.isHidden, failedURL == nil, startScreen.handleKey(event) { return }   // arrows, Return: recent files
        guard let chord = KeyChord.fromKeyEvent(keyCode: event.keyCode,
                                                characters: KeyboardLayout.characters(for: event),
                                                modifiers: Modifiers(event.modifierFlags)),
              let command = inputMap.command(for: chord) else { return }
        if event.isARepeat && !command.repeatsWhenHeld { return }   // holding p must not flicker pause
        if command == .holdSpeed {
            guard holdKeyCode == nil, stillDown else { return }
            holdKeyCode = event.keyCode
            core.beginHoldSpeed()
            hud.show(.speed(core.speed * Double(core.direction)), hold: true)
            return
        }
        runInput(command, from: .keyboard, fresh: !event.isARepeat)
    }

    /// The icon for a file just opened by `event` (next / previous): a kept speed other than 1× (`keep-speed`) instead,
    /// so a faster or slower file is never a surprise.
    private func openedHUD(_ event: Feedback) -> Feedback {
        core.url != nil && core.speed != 1 ? .speed(core.speed) : event
    }

    /// A file opened by next / previous plays at a kept speed other than 1× (`keep-speed`): its icon replaces the step's,
    /// so a faster or slower file is never a surprise.
    private func showKeptSpeed(after outcome: OpenOutcome) {
        if outcome == .opened, core.speed != 1 { hud.show(.speed(core.speed)) }
    }

    /// The key held for hold-speed (backlog 4.5); its key-up, the window losing focus, or the keyboard moving between
    /// the video and the plugin panel ends the hold.
    private var holdKeyCode: UInt16?

    private func endHoldSpeed() {
        guard holdKeyCode != nil else { return }
        holdKeyCode = nil
        core.endHoldSpeed()
        hud.hide()
    }

    /// A mouse button's chord (a press is always fresh).
    private func runBinding(_ chord: KeyChord) {
        guard let command = inputMap.command(for: chord) else { return }
        runInput(command, from: .mouse)
    }

    /// Runs `command` from `source`: the haptics it causes play for the keyboard and the mouse only, and a
    /// `toggle-*` / `cycle-*` that switched something (no `.error` on the way; not `cycle pause`) plays `.toggle`. `fresh`: not a key's
    /// auto-repeat, not a wheel notch of the same spin (a step against the first / last frame bumps again).
    private func runInput(_ command: Command, from source: MouseHaptics.Source, fresh: Bool = true) {
        if case let .pluginAction(name) = command { runPluginAction(name); return }   // the page's, not the player's
        core.inputIsFresh = fresh
        haptics.from(source) {
            let errors = haptics.errorCount
            run(command)
            if command.isToggle, haptics.errorCount == errors, switchesSomething(command) { haptics.play(.toggle) }
        }
    }

    /// A toggle that needs an open video to do anything; the colour toggles play their own haptic (`runColorOutcome`).
    private func switchesSomething(_ command: Command) -> Bool {
        switch command {
        case .cycleAspect: core.info != nil
        case .toggleAutoColor, .toggleVibrance: false
        default: true
        }
    }

    /// A menu item chosen with its key equivalent is the keyboard; one clicked is a menu (silent).
    private var menuSource: MouseHaptics.Source { NSApp.currentEvent?.type == .keyDown ? .keyboard : .menu }

    private func run(_ command: Command) {
        sceneFrameOSDToDrop = nil
        if Self.movesPosition(command) { cancelSceneSearch() }
        switch command {
        case .sceneStep:
            sceneJump(1)
        case .sceneBackStep:
            sceneJump(-1)
        case .cycleFullscreen:
            window?.toggleFullScreen(nil)
        case let .setFullscreen(on):
            if !on && core.isExporting {
                core.perform(.exportRange)   // ESC cancels a running export first
            } else if isFullScreen != on {
                window?.toggleFullScreen(nil)
            }
        case .quit:
            NSApp.terminate(nil)
        case .stats:
            statsPanel.toggle()
        case .scrub, .ignore:
            break
        case let .addAutoColorStrength(delta):
            addAutoColorStrength(delta)
        case .scrubEdge:
            break   // a wheel binding (`perform`); a key has no wheel to drag the edge with
        case .playlistPrev:
            if listPlaylist != nil { stepListPlaylist(-1); return }
            if followsStashQueue { stepStashQueue(-1); return }
            whenFolderRead { [weak self] in self?.stepFolder(-1) }
        case .playlistNext:
            if listPlaylist != nil { stepListPlaylist(1); return }
            if followsStashQueue { stepStashQueue(1); return }
            whenFolderRead { [weak self] in self?.stepFolder(1) }
        case let .windowScale(scale):
            applyWindowSize(.scale(scale))
        case .windowFit:
            applyWindowSize(.fitScreen)
        case .revealFrames:
            revealFrames()
        case .showKeys:
            if keyHelp.isShown { keyHelp.hide() } else { keyHelp.show(inputMap, pluginActions: shownPluginActions) }
        case .goTo:
            guard core.index != nil else { showMessage("No video open"); return }
            goToField.open(with: FrameNaming.timecode(core.currentSeconds))
        case .cycleMouseProfile:
            switchMouseProfile()
        case .toggleUpscaler:
            let enable = !core.config.srStill
            do { try preferences.update(["sr-still"]) { $0.srStill = enable } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            showMessage("Still-frame upscaling: \(enable ? "on" : "off")")
        case .toggleVibrance:
            runColorOutcome(colorMemory.toggle(.vibrance, global: globalConfig))
        case .toggleAutoColor:
            toggleAutoColor()
        case let .saveAutoColor(folder):
            saveColor(.autoColor, folder: folder)
        case let .saveVibrance(folder):
            saveColor(.vibrance, folder: folder)
        case let .resetColor(level):
            runColorOutcome(colorMemory.reset(level))
        case .toggleScrubAudio:
            let enable = !core.config.scrubAudio
            do { try preferences.update(["scrub-audio"]) { $0.scrubAudio = enable } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            showMessage(core.hasAudio ? "Scrub audio: \(enable ? "on" : "off")" : "No audio")
        case .toggleScrubAudioPitch:
            let next: ScrubPitch = core.config.scrubAudioPitch == .natural ? .tape : .natural
            do { try preferences.update(["scrub-audio-pitch"]) { $0.scrubAudioPitch = next } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            showMessage(core.hasAudio ? "Scrub pitch: \(next.rawValue)" : "No audio")
        case .cycleAspect:
            cycleAspect()
        case .cycleUpscaler:
            let next: Upscaler = core.config.saveUpscaler == .ml ? .lanczos : .ml
            do { try preferences.update(["save-upscaler"]) { $0.saveUpscaler = next } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            showMessage("Upscaler: \(next == .ml ? "neural network" : "Lanczos")")
        case .deleteFile:
            deleteCurrentFile()
        case .closeFile:
            closeFile()
        case .cyclePlaylistSort:
            setPlaylistSort(core.config.playlistSort.next)
        case .playlistFilter:
            beginPlaylistFilter()
        case .togglePlaylist:
            slots.togglePlaylist()
        case .cycleABLoopMode:
            let mode = core.config.abLoop.next
            do { try preferences.update(["ab-loop"]) { $0.abLoop = mode } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            let text = switch mode {
            case .loop: "At B: loop back to A"
            case .once: "At B: pause"
            case .pingPong: "At A and B: turn around"
            }
            showMessage(text)
        case .cycleOntop:
            let enable = !core.config.ontop
            do { try preferences.update(["ontop"]) { $0.ontop = enable } } catch {
                showMessage("Cannot save settings: \(error)", duration: 4)
            }
            showMessage("On top: \(enable ? "yes" : "no")")
        case .saveClip:
            // Nothing to save: the core says so. One mark and no inversion: every choice gives the same file.
            guard let summary = core.clipSummary(),
                  core.config.clipConfirm, summary.segments > 1 || core.config.clipMode == .inverted else {
                core.perform(.saveClip)
                return
            }
            showClipSheet(summary)
        case .exportRange:
            if core.isExporting || core.loopA == nil || core.loopB == nil {
                core.perform(.exportRange)          // cancel a running export / "Set range with l first"
            } else {
                showExportSheet()
            }
        default:
            core.perform(command)
        }
    }

    /// `add auto-color-strength ±d` (the panel + wheel): the file's strength on the 0.05 grid within 0…1 (`ColorMemory`);
    /// `.limit` at an end, `.detent` on or past 0.25 / 0.5 / 0.75, else `.step`.
    private func addAutoColorStrength(_ delta: Double) {
        runColorOutcome(colorMemory.addStrength(delta, global: globalConfig))
    }

    /// Commands that move the position or change the file: they end a scene search that is still waiting.
    private static func movesPosition(_ command: Command) -> Bool {
        switch command {
        case .seek, .frameStep, .frameBackStep, .keyframeStep, .keyframeBackStep, .revertSeek, .scrub, .goTo,
             .playlistPrev, .playlistNext, .deleteFile:
            return true
        default:
            return false
        }
    }

    // MARK: Scene jumps

    /// Shift+↑ (+1) / Shift+↓ (-1): presses in the same direction while a search runs add a scene each; the other
    /// direction starts over.
    private func sceneJump(_ direction: Int) {
        guard let search = currentSceneSearch() else {
            if core.url == nil { showMessage("No video open") }   // open but not ready yet: nothing to say
            return
        }
        if let pending = scenePending, pending.direction != direction { cancelSceneSearch() }
        let count = (scenePending?.count ?? 0) + 1
        scenePending = (direction, count, 0)
        startSceneFind(search, direction: direction, count: count)
        if osd.visibleText?.hasPrefix("Searching for") == true {
            showSearchingForScene()
        } else if sceneSearchingShown == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, scenePending != nil else { return }
                showSearchingForScene()
            }
            sceneSearchingShown = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Finds for the pending presses from the current position; a completion of an earlier find is ignored from now on.
    private func startSceneFind(_ search: SceneSearch, direction: Int, count: Int) {
        sceneSearchToken += 1
        let token = sceneSearchToken
        search.find(from: core.position, direction: direction, scenes: count) { [weak self] result in
            MainActor.assumeIsolated { self?.sceneSearchEnded(result, token: token, direction: direction) }
        }
    }

    private func showSearchingForScene() {
        guard let pending = scenePending else { return }
        osd.onClick = nil
        osd.show("Searching for the \(pending.direction > 0 ? "next" : "previous") scene…"
                 + (pending.count > 1 ? " ×\(pending.count)" : ""), duration: nil)   // stays until the search ends
    }

    private func sceneSearchEnded(_ result: SceneSearch.Result, token: Int, direction: Int) {
        // A newer press, another seek or another file took over; a cancelled find never touches the state.
        guard result != .cancelled, token == sceneSearchToken, let pending = scenePending else { return }
        var result = result
        if case let .found(frame) = result {
            // Playback moved on during the search: never rewind past what is on screen.
            switch SceneJumpPolicy.decide(found: frame, direction: direction, currentPosition: core.position,
                                          retries: pending.retries) {
            case .jump:
                break
            case .searchAgain:
                if let search = sceneSearch {
                    scenePending = (direction, pending.count, pending.retries + 1)
                    startSceneFind(search, direction: direction, count: pending.count)
                    return
                }
                result = .none
            case .noScene:
                result = .none
            }
        }
        scenePending = nil
        sceneSearchingShown?.cancel()
        sceneSearchingShown = nil
        switch result {
        case let .found(frame):
            sceneFrameOSDToDrop = nil
            core.jumpToScene(frame: frame)   // exact, keeps play / pause, sets the revert point; glued to locked segments
            hud.show(direction > 0 ? .sceneNext : .scenePrevious)
            sceneFrameOSDToDrop = core.position
            showMessage("Scene \(direction > 0 ? "→" : "←") \(FrameNaming.timecode(core.currentSeconds))")
        case .none:
            showMessage(direction > 0 ? "No next scene" : "No previous scene")
        case let .notWithin(frame):
            // The looks stay cached: the next press goes on from there.
            let span = abs((core.index?.seconds(forFrame: frame) ?? core.currentSeconds) - core.currentSeconds)
            showMessage("No \(direction > 0 ? "next" : "previous") scene within \(FrameNaming.timecode(span).prefix(while: { $0 != "." })) · press again to look further",
                        duration: 3)
        case let .failed(reason):
            showMessage("Cannot search for scenes: \(reason)", duration: 4)
        case .cancelled:
            break
        }
    }

    /// The open file's scene search, made on first use.
    private func currentSceneSearch() -> SceneSearch? {
        if let sceneSearch { return sceneSearch }
        guard let url = core.url, let index = core.index, let info = core.info else { return nil }
        let search = SceneSearch(url: url, index: index, rotationClockwise: info.rotationClockwise, readCache: core.readCache,
                                 threshold: core.config.sceneThreshold, lookahead: core.config.sceneLookahead,
                                 checkTime: core.config.sceneCheckTime, searchTime: core.config.sceneSearchTime,
                                 preferHardware: core.config.hwdec.prefersHardware)
        sceneSearch = search
        return search
    }

    /// A seek outside `run(_:)` (go-to field, seek bar, trackpad scrub): ends the wait and lets its frame line show.
    private func positionWillMove() {
        sceneFrameOSDToDrop = nil
        cancelSceneSearch()
    }

    /// Forgets waiting presses; what the search has looked at stays cached for the file.
    private func cancelSceneSearch() {
        guard scenePending != nil || sceneSearchingShown != nil else { return }
        scenePending = nil
        sceneSearchingShown?.cancel()
        sceneSearchingShown = nil
        sceneSearch?.cancel()
        hideSearchingForScene()
    }

    private func hideSearchingForScene() {
        if osd.visibleText?.hasPrefix("Searching for") == true { osd.hide() }
    }

    /// The file closes or changes: the search and its decoder go. With `waitForTheDecoder`, the file is closed on return.
    private func dropSceneSearch(waitForTheDecoder: Bool = false) {
        cancelSceneSearch()
        sceneSearch?.close(wait: waitForTheDecoder)
        sceneSearch = nil
        sceneFrameOSDToDrop = nil
    }

    private func showExportSheet() {
        guard let window, window.attachedSheet == nil,
              let a = core.loopA, let b = core.loopB, let info = core.info else { return }
        let config = core.config
        let sideways = info.rotationClockwise % 180 != 0
        let source = CGSize(width: sideways ? info.height : info.width, height: sideways ? info.width : info.height)
        var sheet: NSWindow?
        let close = {
            if let panel = sheet { window.endSheet(panel) }
            sheet = nil   // breaks panel -> view -> close -> sheet, which would leak the window
        }
        let view = ExportSheetView(
            rangeText: "frames \(a)–\(b)", source: source, screen: core.screenPixelSize,
            hdr: (lastFrame?.dynamicRange ?? .sdr) != .sdr && config.frameFormat != .jpeg,   // HDR to JPEG is tone-mapped, then upscaled by ML
            upscaler: config.saveUpscaler,
            count: { [weak self] in self?.core.exportCount(for: $0) },
            onStart: { [weak self] selection, size, filters in
                close()
                guard let self else { return }
                do {
                    try preferences.update(["export-mode", "export-every", "export-fps", "export-scale", "export-sharp", "export-skip-blurry",
                                            "export-sharp-threshold", "export-skip-duplicates", "export-duplicate-change"]) {
                        switch selection {
                        case .all: $0.exportMode = .all
                        case let .every(n): $0.exportMode = .every; $0.exportEvery = n
                        case let .perSecond(f): $0.exportMode = .fps; $0.exportFPS = f
                        }
                        $0.exportScale = size
                        $0.exportSharp = filters.sharpest
                        $0.exportSkipBlurry = filters.skipBlurry
                        $0.exportSharpThreshold = filters.blurryThreshold
                        $0.exportSkipDuplicates = filters.skipDuplicates
                        $0.exportDuplicateChange = filters.duplicateChange
                    }
                } catch { showMessage("Cannot save settings: \(error)", duration: 4) }
                core.startExport(selection: selection)    // the exporter already has the new export-scale
            },
            onCancel: close,
            mode: { switch config.exportMode { case .all: return .all; case .every: return .every; case .fps: return .perSecond } }(),
            every: config.exportEvery, fps: config.exportFPS, size: config.exportScale,
            filters: .init(sharpest: config.exportSharp, skipBlurry: config.exportSkipBlurry, blurryThreshold: config.exportSharpThreshold,
                           skipDuplicates: config.exportSkipDuplicates, duplicateChange: config.exportDuplicateChange))
        let host = NSHostingController(rootView: view)
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        sheet = panel
        window.beginSheet(panel)
    }

    /// `c` with marks: how to save them (cut marks spec §4.1); the choice is remembered as `clip-mode`.
    private func showClipSheet(_ summary: ClipSummary) {
        guard let window, window.attachedSheet == nil else { return }
        var sheet: NSWindow?
        let close = {
            if let panel = sheet { window.endSheet(panel) }
            sheet = nil   // breaks panel -> view -> close -> sheet, which would leak the window
        }
        let view = ClipSheetView(summary: summary, selected: core.config.clipMode, onChoose: { [weak self] mode in
            close()
            guard let self else { return }
            if mode != core.config.clipMode {
                do { try preferences.update(["clip-mode"]) { $0.clipMode = mode } } catch {
                    showMessage("Cannot save settings: \(error)", duration: 4)
                }
            }
            core.saveMarks(mode)
        }, onCancel: close)
        let panel = NSWindow(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled]
        sheet = panel
        window.beginSheet(panel)
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func scrollSample(_ event: NSEvent) -> ScrollSample {
        ScrollSample(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
                     precise: event.hasPreciseScrollingDeltas, momentum: event.momentumPhase != [],
                     began: event.phase == .began, time: event.timestamp,
                     modifiers: Modifiers(event.modifierFlags),
                     rightButton: NSEvent.pressedMouseButtons & 0b10 != 0)
    }

    /// The held-button modifier of a scroll (`MBTN_BACK+WHEEL_UP`); the wheel also cancels the held buttons' taps.
    private func heldButtons(for sample: ScrollSample) -> Modifiers {
        buttons.wheel(hasDelta: sample.deltaX != 0 || sample.deltaY != 0, momentum: sample.momentum, at: sample.time)
    }

    /// `source`: who the scroll's haptics answer to; nil, the wheel's (`.mouse`) or the trackpad's.
    private func handleScroll(_ event: NSEvent, source: MouseHaptics.Source? = nil) {
        var sample = scrollSample(event)
        sample.heldButtons = heldButtons(for: sample)
        let owner = MouseButton.allCases.first { $0.modifier.map(sample.heldButtons.contains) ?? false }
        let fresh = EndBump.isFreshNotch(at: sample.time, previous: lastWheelTime)
        lastWheelTime = sample.time
        let actions = gestures.route(sample)
        if actions.contains(where: {
            switch $0 {
            case .scrubFrames, .scrubEdge: true
            default: false
            }
        }) { hideCursorForScrub() }
        perform(actions, from: source ?? (sample.precise ? .trackpad : .mouse), fresh: fresh, heldButton: owner)
    }

    private func handleMagnify(_ event: NSEvent) {
        perform(gestures.routePinch(magnification: Double(event.magnification), modifiers: Modifiers(event.modifierFlags)),
                from: .trackpad, fresh: true)
        if event.phase == .ended || event.phase == .cancelled { gestures.endPinch() }
    }

    /// `heldButton`: the button whose modifier the scroll's chord got, which owns a `scrub-edge` drag.
    private func perform(_ actions: [GestureAction], from source: MouseHaptics.Source, fresh: Bool,
                         heldButton: MouseButton? = nil) {
        for action in actions {
            switch action {
            case let .scrubFrames(frames, ticks):
                positionWillMove()
                core.inputIsFresh = fresh
                haptics.from(source) { core.scrub(by: frames, ticks: ticks) }
            case let .command(command): runInput(command, from: source, fresh: fresh)
            case let .scrubEdge(edge, frames): scrubEdge(edge, by: frames, heldButton: heldButton, from: source, fresh: fresh)
            case .zoomBy: break   // zoom view arrives with v1.1 Plan B
            }
        }
    }

    /// A `scrub-edge` wheel step (mouse spec §5.4): drags the mark edge while `heldButton` is down; its release
    /// (`buttons.onRelease`) makes the drag one ⌘Z step. The scroll's tail after the release moves nothing; bound
    /// without a held button (nothing would end the drag) it is a plain scrub.
    private func scrubEdge(_ edge: MarkEdge, by frames: Int, heldButton: MouseButton?, from source: MouseHaptics.Source,
                           fresh: Bool) {
        if let heldButton, !buttons.held.contains(heldButton) || heldButton == edgeDragSuppressed { return }
        positionWillMove()
        core.inputIsFresh = fresh
        guard let heldButton else {
            haptics.from(source) { core.scrub(by: frames) }
            return
        }
        haptics.from(source) {
            if core.edgeDrag != nil, edgeDragOwner != heldButton { core.endEdgeDrag() }   // another button's drag
            edgeDragOwner = heldButton
            core.scrubEdge(edge, by: frames)
        }
    }

    /// Esc, focus loss, another file: a live edge drag puts the marks back.
    private func cancelEdgeDrag() {
        core.cancelEdgeDrag()
        edgeDragOwner = nil
    }

    /// Everything the mouse buttons have in flight: presses (and the button timer), the edge drag.
    private func cancelMouseInput() {
        buttons.cancelAll()
        cancelEdgeDrag()
        edgeDragSuppressed = nil
    }

    // MARK: Mouse buttons and the Logitech mouse

    /// The bound mouse buttons (`MouseButtonRouter`) and the player's haptics.
    private func setUpMouse() {
        haptics.config = { [weak self] in self?.core.config ?? Config() }
        core.onHaptic = { [weak self] in self?.haptics.play($0) }   // filtered by the input running (`haptics.from`)
        core.onSeekHaptic = { [weak self] in self?.haptics.play($0, mouseOnly: true) }   // a seek's step: the mouse only
        buttons.onFire = { [weak self] chords in chords.forEach { self?.runBinding($0) } }
        buttons.onArmed = { [weak self] _ in
            guard let self, window?.isKeyWindow == true else { return }
            haptics.play(.longArmed)
        }
        buttons.onRelease = { [weak self] button in
            guard let self else { return }
            if edgeDragSuppressed == button { edgeDragSuppressed = nil }
            guard button == edgeDragOwner else { return }
            edgeDragOwner = nil
            core.inputIsFresh = true
            haptics.from(.mouse) { self.core.endEdgeDrag() }
        }
    }

    /// The Logitech mouse, made by `AppDelegate` after the first window is up: its buttons go through the same
    /// filter and recogniser as AppKit's, its wheel mode sets the events a notch sends, and Precision Scroll follows
    /// `updatePrecisionWheel`.
    func attach(_ bridge: LogiMouseBridge) {
        mouseBridge = bridge
        haptics.bridge = bridge
        buttons.heard = { [weak bridge] in bridge?.watching ?? [] }
        bridge.onButton = { [weak self] button, pressed, time in self?.mouseButton(button, pressed: pressed, at: time) }
        bridge.onHighResolution = { [weak self] on in
            self?.gestures.wheelEventsPerNotch = on ? GestureRouter.precisionEventsPerNotch : 1
        }
        gestures.wheelEventsPerNotch = bridge.isHighResolution ? GestureRouter.precisionEventsPerNotch : 1
        bridge.apply(config: core.config, map: inputMap)   // a reload may have come since the bridge was made
        bridge.onWheelMode = { [weak self] mode, byButton in
            // The user pressed the SmartShift button: the choice is theirs, so keep it for the next time. The package
            // reports a press only while it holds a wanted mode and has adopted the press, so it is stored even if
            // "in front" lags (a sheet opening right after the press): otherwise the stored choice would differ from
            // the package's and the press would be written over later. The OSD only shows over the player.
            guard let self, byButton else { return }
            UserDefaults.standard.set(mode == .freeSpin, forKey: Self.wheelFreeSpinKey)
            updatePrecisionWheel()
            if playerInFront { showMessage(mode == .freeSpin ? "Free spin · Precision Scroll" : "Ratchet") }
        }
        bridge.onSmartShift = { [weak self] pressed, time in self?.smartShiftButton(pressed: pressed, at: time) }
        wheelWants = WheelWants(precision: false, freeSpin: true, playerInFront: false, overVideo: false)
        playerWasInFront = false
        updatePrecisionWheel()
    }

    /// The SmartShift button, taken over while FrameScrub sets the wheel: held 0.6 s it switches the mouse profile with
    /// a click felt at that moment; a shorter press switches the wheel between free spin and ratchet, as the mouse would.
    private func smartShiftButton(pressed: Bool, at time: Double) {
        smartShiftHold?.cancel()
        smartShiftHold = nil
        guard pressed else {
            guard NSApp.isActive else { smartShift.cancel(); return }
            switch smartShift.release(at: time) {
            case .short: switchWheelMode()
            case .long: smartShiftHeld()
            case .none: break
            }
            return
        }
        smartShift.press(at: time)
        let hold = DispatchWorkItem { [weak self] in
            guard let self, smartShift.tick(at: ProcessInfo.processInfo.systemUptime) == .long else { return }
            smartShiftHeld()
        }
        smartShiftHold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + smartShift.threshold, execute: hold)
    }

    private func smartShiftHeld() {
        haptics.play(.toggle)
        switchMouseProfile()
    }

    /// What the mouse does with the button when nobody takes it: free spin ⇄ ratchet, kept as the user's choice.
    private func switchWheelMode() {
        let freeSpin = !(UserDefaults.standard.object(forKey: Self.wheelFreeSpinKey) as? Bool ?? true)
        UserDefaults.standard.set(freeSpin, forKey: Self.wheelFreeSpinKey)
        updatePrecisionWheel()
        showMessage(freeSpin ? "Free spin · Precision Scroll" : "Ratchet")
    }

    /// A button the Logitech mouse reported. Presses count while the player window is key (like the keys); a watched
    /// side button only with the pointer over a FrameScrub window. A release while FrameScrub is in the background
    /// (the package releases held buttons on deactivation) cancels instead of acting.
    private func mouseButton(_ button: MouseButton, pressed: Bool, at time: Double) {
        guard pressed else {
            guard NSApp.isActive else { cancelMouseInput(); return }
            buttons.mouseRelease(button, at: time)
            return
        }
        guard NSApp.isActive, window?.isKeyWindow == true else { return }
        if let page = slots.pageUnderPointer {   // back / forward over a plugin page are its history
            switch SideButtonFilter.pluginPagePress(button, mode: core.config.mxSideButtons) {
            case .pass: break
            case .drop: return
            case .pageBack: page.goBack(); return
            case .pageForward: page.goForward(); return
            }
        }
        if !startScreen.isHidden {
            // No file to act on, and the Stash page keeps its own back / forward: a watched button reaches it through
            // AppKit (its own monitor), a taken one only from here. A dropped press's release finds nothing held.
            let page = stashLibrary.flatMap { $0.isHidden ? nil : $0 }
            switch SideButtonFilter.startScreenPress(button, mode: core.config.mxSideButtons, stashPageShown: page != nil) {
            case .pass: break
            case .drop: return
            case .pageBack: page?.goBack(); return
            case .pageForward: page?.goForward(); return
            }
        }
        let rightHeld = NSEvent.pressedMouseButtons & 0b10 != 0
        let watched = core.config.mxSideButtons == .watch && button.sideCID != nil
        let underPointer = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        let passed = buttons.mousePress(button, keys: Modifiers(NSEvent.modifierFlags), rightHeld: rightHeld, at: time,
                                        watched: watched,
                                        overOwnWindow: NSApp.windows.contains { $0.windowNumber == underPointer })
        if passed, rightHeld { videoView.noteRightUsedAsModifier() }   // the right release is no MBTN_RIGHT then
    }

    // MARK: Overlays

    private func revealSeekBar() {
        // No file: nothing to show, and over the Stash page the bar would take its clicks.
        if !startScreen.isHidden { return }
        updateSeekBar()
        backButton.title = returnTab == .stash ? "Stash" : "Recent"
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            seekBar.animator().alphaValue = 1
        }
        showBackButton(true, duration: 0.15)
        hideSeekBarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if isPointer(over: seekBar) { revealSeekBar(); return }   // a pointer resting on the bar keeps it
            previewFraction = nil
            previewPin = nil
            seekBar.previewFrame = nil
            previewImage = nil
            previewView.hide()
            if isPointer(over: backButton) { revealSeekBar(); return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.seekBar.animator().alphaValue = 0
            }
            showBackButton(false, duration: 0.4)
            hideCursorOverVideo()
        }
        hideSeekBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Fades the back button in or out and moves the OSD out of its way.
    private func showBackButton(_ show: Bool, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            backButton.animator().alphaValue = show ? 1 : 0
            osdTop.animator().constant = show ? 16 + BackButton.height + 8 : 16
        }
    }

    /// The wheel mode (`wheel-precision=yes`: free spin or ratchet, the user's choice in `wheelFreeSpin`) is wanted
    /// of the mouse while the player window is in front, whatever the pointer is over. Precision Scroll is wanted on
    /// free spin only, while the pointer is over the video: not over the seek bar (its wheel steps the preview between
    /// keyframes), the playlist, the stats panel or the start screen, where macOS would scroll lists far too fast with
    /// it, nor over another window floating above the video (Spotlight, Raycast).
    private func updatePrecisionWheel() {
        guard let mouseBridge else { return }
        let inFront = playerInFront
        if inFront && !playerWasInFront && core.config.wheelPrecision {
            // Another LogiHIDPP app (Loupe) may have given back its own mode just after this one came forward: the
            // package would believe a stale mode.
            mouseBridge.recheckWheelMode()
            mouseBridge.recheckHighResolutionWheel()
        }
        playerWasInFront = inFront
        let overVideo = isPointer(over: videoView) && !isPointer(over: seekBar)
            && !(slots?.isPointerOverShownSlot ?? false)
            && !(window.map { isPointerOnStats(at: $0.mouseLocationOutsideOfEventStream) } ?? false)
            && NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window?.windowNumber
        let freeSpin = UserDefaults.standard.object(forKey: Self.wheelFreeSpinKey) as? Bool ?? true
        let wants = WheelWants(precision: core.config.wheelPrecision, freeSpin: freeSpin, playerInFront: inFront,
                               overVideo: overVideo)
        guard wants != wheelWants else {
            // While the pointer moves, look at the mouse now and then: it may have slept, reconnected, or had its
            // mode switched by LinearMouse, and a failed restore is retried.
            let now = ProcessInfo.processInfo.systemUptime
            if core.config.wheelPrecision, now - precisionCheckedAt > 2 {
                precisionCheckedAt = now
                mouseBridge.recheckHighResolutionWheel()
                mouseBridge.recheckWheelMode()
            }
            return
        }
        wheelWants = wants
        precisionCheckedAt = ProcessInfo.processInfo.systemUptime
        mouseBridge.takeSmartShift(wants.wheelMode != nil)
        mouseBridge.wantWheelMode(wants.wheelMode)
        mouseBridge.wantHighResolutionWheel(wants.highResolution)
    }

    /// The app is active and this window is key, with no sheet and no start screen: the one definition of "in front"
    /// for the wheel (`updatePrecisionWheel`, the SmartShift button).
    private var playerInFront: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.attachedSheet == nil && startScreen.isHidden
    }

    private func isPointer(over view: NSView) -> Bool {
        guard let window, !view.isHidden else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return view.bounds.contains(point)
    }

    /// `point` (window points) is on the stats panel.
    private func isPointerOnStats(at point: NSPoint) -> Bool {
        guard let frame = statsPanel?.panelFrame, let container = window?.contentView else { return false }
        return frame.contains(container.convert(point, from: nil))
    }

    /// Hides the pointer until it moves, when it rests on the video (not on the playlist, a sheet or another window).
    private func hideCursorOverVideo() {
        guard pointerRestsOnVideo else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// Hides the pointer for a scrub until it moves, leaves the video or the window stops being key. Not with
    /// `setHiddenUntilMouseMoves`: wheel events bring that pointer back, and hiding it again on the next scrub event
    /// made it flicker (~6 events a notch with Precision Scroll).
    private func hideCursorForScrub() {
        guard !cursorHiddenForScrub, pointerRestsOnVideo else { return }
        NSCursor.hide()
        cursorHiddenForScrub = true
    }

    private func showCursorAfterScrub() {
        guard cursorHiddenForScrub else { return }
        NSCursor.unhide()
        cursorHiddenForScrub = false
    }

    private var pointerRestsOnVideo: Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, let content = window.contentView,
              isPointer(over: content) else { return false }
        return !(slots?.isPointerOverShownSlot ?? false)
    }

    /// (Re)creates the preview decoder for the open file; `preview=no` or a failed decoder leaves the timecode only.
    private func configurePreview(force: Bool = false) {
        let scale = window?.backingScaleFactor ?? 2
        let key = PreviewKey(enabled: core.config.preview, width: CGFloat(core.config.previewWidth), url: core.url, scale: scale)
        if !force, key == previewKey { return }
        previewKey = nil
        previewProvider?.stop()
        previewProvider = nil
        previewImage = nil
        previewFraction = nil
        previewPin = nil
        seekBar.previewFrame = nil
        previewView.hide()
        guard core.config.preview else {
            previewKey = key   // preview off: nothing to build until the key changes
            return
        }
        guard let url = core.url, let index = core.index, let info = core.info else { return }
        previewKey = key   // set before the provider exists: an unavailable file is not retried until the key changes
        let provider = FrameScrubCore.PreviewProvider(url: url, index: index, rotationClockwise: info.rotationClockwise,
                                       widthPixels: Int(core.config.previewWidth * scale), readCache: core.readCache,
                                       policy: core.networkPolicy)
        provider.onImage = { [weak self] result in
            guard let self else { return }
            previewImage = videoView.geometry.thumbnail(of: result.image, context: Self.thumbnailContext) ?? result.image
            updatePreviewView()
        }
        provider.onUnavailable = { [weak self] in
            self?.previewProvider?.stop()
            self?.previewProvider = nil
            self?.previewImage = nil
            self?.updatePreviewView()
        }
        previewProvider = provider
    }

    /// Sorts and filters the folder's last listing (only `url` until the folder has been read).
    private func rebuildPlaylist(around url: URL) {
        let folder = folder(of: url)
        let listing = folderListing.flatMap { $0.folder == folder ? $0 : nil } ?? .empty(folder)
        playlist = Playlist(current: url, sort: core.config.playlistSort, filter: playlistFilter, listing: listing)
        updatePlaylistPanel()
    }

    /// The panel shows the page's list while there is one, else the folder.
    private func updatePlaylistPanel() {
        defer { updateTransport() }   // the seek bar's ⏮ ⏭ follow the same list
        if let listPlaylist {
            listRowIndices = listPlaylist.indices(matching: playlistFilter)
            playlistPanel.showList(name: listPlaylist.name)
            playlistPanel.update(rows: listRowIndices.map { PlaylistRow(listPlaylist.items[$0]) },
                                 current: listRowIndices.firstIndex(of: listPlaylist.currentIndex) ?? -1)
            return
        }
        listRowIndices = []
        playlistPanel.showSort(core.config.playlistSort)
        guard let playlist else { return }
        playlistPanel.update(rows: playlist.files.map { PlaylistRow(file: $0) }, current: playlist.currentIndex)
    }

    // MARK: A page's list

    /// Back to the folder as the playlist.
    private func dropListPlaylist() {
        guard listPlaylist != nil else { return }
        listPlaylist = nil
        updatePlaylistPanel()
    }

    /// < and > in the folder: the file before or after; at an end the window says so.
    private func stepFolder(_ direction: Int) {
        if let target = direction > 0 ? playlist?.next : playlist?.previous {
            _ = playlistEndBump.stepped(moved: true, direction: direction, fresh: core.inputIsFresh)
            hud.show(direction > 0 ? .playlistNext : .playlistPrevious)
            openFile(target) { [weak self] outcome in self?.showKeptSpeed(after: outcome) }
        } else {
            showMessage(direction > 0 ? "Last file" : "First file")
            if playlistEndBump.stepped(moved: false, direction: direction, fresh: core.inputIsFresh) { haptics.play(.end) }
        }
    }

    /// < and > in a page's list: the item before or after; the ends stop as the folder's do.
    private func stepListPlaylist(_ direction: Int) {
        guard let listPlaylist else { return }
        let target = listPlaylist.currentIndex + direction
        guard listPlaylist.items.indices.contains(target) else {
            showMessage(direction > 0 ? "Last item" : "First item")
            if playlistEndBump.stepped(moved: false, direction: direction, fresh: core.inputIsFresh) { haptics.play(.end) }
            return
        }
        _ = playlistEndBump.stepped(moved: true, direction: direction, fresh: core.inputIsFresh)
        openListItem(at: target)
        hud.show(openedHUD(direction > 0 ? .playlistNext : .playlistPrevious))
    }

    /// Opens the list's item at `index` (a scene's file is looked for only now), at the item's own time when the page
    /// gave one (over the remembered position). One that cannot be opened says so on screen and to the pages
    /// (`error`); at autoadvance (`plays`) the item after it is tried once.
    private func openListItem(at index: Int, plays: Bool = false, retried: Bool = false) {
        guard let item = listPlaylist?.select(index) else { return }
        updatePlaylistPanel()   // a scene opens later: the row moves now
        let failed = { [weak self] in
            guard let self, listPlaylist?.currentIndex == index, listPlaylist?.current == item else { return }   // moved on
            let title = PlaylistRow(item).title
            dispatchToPages(.error("cannot open \(title)"))
            guard plays, !retried, listPlaylist?.next != nil else { return }
            openListItem(at: index + 1, plays: true, retried: true)
            showMessage("Cannot open \(title): skipped", duration: 3)
        }
        let landing = item.time.map { LinkTarget(time: $0) }
        switch item {
        case let .file(url, _, _), let .stream(url, _, _):
            returnTab = .recent
            stashScene = nil
            stashOpens += 1   // a scene still being looked for must not replace this file
            queueGate.cancel()
            openFile(url, landing: landing) { [weak self] outcome in
                switch outcome {
                case .opened: if plays { self?.core.play() }
                case .failed: failed()
                case .superseded: break
                }
            }
        case let .scene(id, _, _):
            openStashScene(StashScene(id: id, paths: []), landing: landing, plays: plays, onFailure: failed)
        }
    }

    /// What is on screen as a list item, for `enqueue` in the folder: the Stash scene, else the open stream or file.
    private var currentPlaylistItem: PlaylistItem? {
        if case let .stash(sceneID, _) = origin, core.url != nil { return .scene(id: sceneID, title: window?.title) }
        guard let url = core.url else { return nil }
        return ByteSources.isRemote(url) ? .stream(url, title: window?.title) : .file(url, title: nil)
    }

    private func folder(of url: URL) -> URL { url.standardizedFileURL.deletingLastPathComponent() }

    /// Reads `url`'s folder in the background, then rebuilds the playlist; files added or removed since the last
    /// read show up then. An open starts it once its first picture is up (a failed one at once).
    private func readFolder(of url: URL) {
        let folder = folder(of: url)
        if folderRead?.folder == folder { return }   // a read that started moments ago is fresh enough
        let done = DispatchGroup()
        let result = FolderReadResult()
        done.enter()
        folderQueue.async {
            result.listing = FolderListing.read(folder)
            StartupTrace.mark("folder read: \(result.listing?.count ?? 0) videos")
            done.leave()
        }
        folderRead = (folder, done, result)
        done.notify(queue: .main) { [weak self] in self?.folderReadFinished(result) }
    }

    private func folderReadFinished(_ result: FolderReadResult) {
        if folderRead?.result === result { folderRead = nil }
        defer { if folderRead == nil { folderWait.readEnded()?() } }   // the command that waited, on the new listing
        guard let listing = result.listing else { return }
        guard let anchor = playlistAnchor, folder(of: anchor) == listing.folder else { return }   // another folder by now
        let pending = positionPending == anchor
        guard listing != folderListing || pending else { return }   // nothing new since the last read
        folderListing = listing
        positionPending = nil
        rebuildPlaylist(around: anchor)
        guard core.url == anchor else { return }   // a failed open keeps its title
        if pending { showPlaylistPosition(anchor) } else { updateTitle(anchor) }
    }

    /// Commands that need the whole folder (next or previous file, delete, Return in the filter) run once a read still
    /// running is over (`FolderWait`), as if it had been made in the open; the window answers meanwhile.
    private func whenFolderRead(_ action: @escaping () -> Void) {
        if folderRead == nil, let anchor = playlistAnchor, folderListing?.folder != folder(of: anchor) {
            readFolder(of: anchor)   // asked for before the first picture started it
        }
        folderWait.take(reading: folderRead != nil, action)?()   // run once the wait is left: it opens a file
    }

    /// The file the playlist is built around (`FolderWait.anchor`).
    private var playlistAnchor: URL? { FolderWait.anchor(open: core.url, opening: openingURL, failed: failedURL) }

    private func setPlaylistSort(_ sort: PlaylistSort) {
        guard sort != core.config.playlistSort else { return }
        do { try preferences.update(["playlist-sort"]) { $0.playlistSort = sort } } catch {   // applyConfig rebuilds the list
            showMessage("Cannot save settings: \(error)", duration: 4)
        }
        showMessage("Folder order: \(sort.title)")
    }

    /// The other mouse profile, kept (`mouse-profile`); the settings' observers rebuild the bindings.
    private func switchMouseProfile() {
        let profile = core.config.mouseProfile.next
        do { try preferences.update(["mouse-profile"]) { $0.mouseProfile = profile } } catch {
            showMessage("Cannot save settings: \(error)", duration: 4)
        }
        showMessage("Mouse buttons: \(profile.title)")
    }

    /// ⌘⌫: the file goes to the Trash (or, on a volume without one, is deleted after asking), then the next one opens.
    private func deleteCurrentFile() {
        guard let url = playlistAnchor else { return }
        if let clips = core.clipQueue {
            let pending = clips.pendingCount(for: url)
            if pending > 0 {
                let alert = NSAlert()
                alert.messageText = pending == 1 ? "1 clip from this file is still being saved"
                                                 : "\(pending) clips from this file are still being saved"
                alert.addButton(withTitle: "Don't Delete")                           // Return: the safe answer
                let delete = alert.addButton(withTitle: "Delete and Cancel Clips")   // no key equivalent
                delete.hasDestructiveAction = true
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                clips.cancel(for: url)
            }
        }
        if case let .stash(sceneID, _) = origin, core.url != nil {
            deleteStashScene(sceneID, url: url)
            return
        }
        whenFolderRead { [weak self] in self?.removeFile(url) }
    }

    /// The rest of ⌘⌫ once the folder is read: the neighbour to open next is known.
    private func removeFile(_ url: URL) {
        let neighbour = playlist?.neighbourAfterRemoval
        let outcome = FileRemoval.remove(url, confirmDelete: { confirmPermanentDelete(url) }, release: {
            abandonOpening()   // ⌘⌫ while it was still being read
            dropSceneSearch(waitForTheDecoder: true)   // a permanent delete follows at once
            closeCore()
            videoView.clear()
            statsFileChanged()
        })
        switch outcome {
        case .cancelled:
            return
        case let .failed(reason):
            showMessage("Cannot delete \(url.lastPathComponent): \(reason)", duration: 5)
            if core.url == nil { openFile(url) }   // closed for the delete: show it again
            return
        case .trashed, .deleted:
            failedURL = nil
            folderListing = folderListing?.removing(url)   // until the next read of the folder
            if let neighbour {
                openFile(neighbour)
            } else {
                closeCore()
                videoView.clear(blank: true)
                showStartScreen()
            }
            showMessage(outcome == .trashed ? "Moved to Trash: \(url.lastPathComponent)" : "Deleted: \(url.lastPathComponent)")
        }
    }

    /// ⌘⌫ on a file from Stash (Stash spec §2.7): Stash deletes the scene, its file and its generated files, then
    /// the next scene of the queue opens; without one, back to Stash.
    private func deleteStashScene(_ sceneID: String, url: URL) {
        guard let stashSession else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the scene and its file from Stash?"
        alert.informativeText = stashScene?.paths.first ?? url.path
        alert.addButton(withTitle: "Cancel")                // Return and Esc: the safe answer
        let delete = alert.addButton(withTitle: "Delete")   // no key equivalent
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let name = url.lastPathComponent
        let origin = origin
        let position = core.currentSeconds
        cancelStashTitleWait()
        stashSession.leave()
        dropSceneSearch(waitForTheDecoder: true)
        closeCore()   // nothing of ours holds the file while Stash deletes it
        videoView.clear()
        statsFileChanged()
        deletingScene = true
        Task { [weak self] in
            do {
                try await stashSession.destroyScene(sceneID)
                guard let self else { return }
                showMessage("Deleted: \(name)")
                guard deletingScene else {   // the user went back meanwhile: just leave the deleted scene's page
                    stashLibrary?.leaveDeletedScene()
                    return
                }
                if followsStashQueue {
                    stepStashQueue(1, plays: core.config.autoplay, atEnd: { [weak self] in self?.backToStashAfterDelete() })
                } else {
                    backToStashAfterDelete()
                }
            } catch {
                guard let self else { return }
                guard deletingScene else {
                    showMessage("Cannot delete \(name): \(error.localizedDescription)", duration: 5)
                    return
                }
                openFile(url, origin: origin, fallbackPosition: position) { [weak self] outcome in
                    guard let self, outcome != .superseded else { return }
                    if outcome == .opened, case let .stash(id, _) = origin {
                        stashSession.began(sceneID: id, duration: core.durationSeconds)
                    }
                    showMessage("Cannot delete \(name): \(error.localizedDescription)", duration: 5)
                }
            }
        }
    }

    /// The deleted scene's page is left and the Stash library shows again.
    private func backToStashAfterDelete() {
        stashLibrary?.leaveDeletedScene()
        deletingScene = false
        videoView.clear(blank: true)
        failedURL = nil
        failedScene = nil
        origin = .plain
        showStartScreen(tab: .stash)
    }

    private func confirmPermanentDelete(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(url.lastPathComponent)” permanently?"
        alert.informativeText = "This volume has no Trash. The file will be deleted immediately and cannot be restored."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")   // Return
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")                // Esc
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func beginPlaylistFilter() {
        slots.showPlaylistForFilter()
    }

    private func frame(atBarFraction fraction: Double) -> Int {
        Int((fraction * Double(max(core.frameCount - 1, 0))).rounded())
    }

    /// The frame the preview shows: where a scroll over the bar moved it, else under the pointer.
    private var previewFrame: Int? {
        previewPin?.frame ?? previewFraction.map(frame(atBarFraction:))
    }

    /// Lets the preview follow the pointer again once it has moved away from where the scroll left it.
    private func releasePin(ifPointerAt fraction: Double) {
        if let pin = previewPin, abs(fraction - pin.fraction) * (seekBar.bounds.width - 24) > Self.pinSlack { previewPin = nil }
    }

    private func hover(_ fraction: Double?) {
        previewFraction = fraction
        guard let fraction, let index = core.index else {
            previewPin = nil
            seekBar.previewFrame = nil
            previewImage = nil
            previewView.hide()
            return
        }
        releasePin(ifPointerAt: fraction)
        requestPreview(index)
        revealSeekBar()          // keeps the bar visible while the mouse is on it
    }

    private func requestPreview(_ index: FrameIndex) {
        guard let frame = previewFrame else { return }
        previewProvider?.request(seconds: index.seconds(forFrame: frame))
        updatePreviewView()
    }

    /// Scrolling over the bar moves the preview from keyframe to keyframe without touching playback; a click then
    /// goes to the keyframe shown. Without known keyframes (approximate index) the scroll does nothing.
    private func scrollOverSeekBar(_ event: NSEvent) {
        guard let fraction = previewFraction, let index = core.index, let from = previewFrame else {
            return handleScroll(event, source: .menu)   // no preview: the bar's scroll scrubs, silently (the bar never vibrates)
        }
        lensScroll.invertX = core.config.scrub.invert
        let sample = scrollSample(event)
        _ = heldButtons(for: sample)   // a held button's tap is cancelled here too
        let steps = lensScroll.steps(for: sample)
        guard steps != 0, let target = KeyframeLens.step(index, from: from, by: steps) else { return }
        previewPin = (target, fraction)
        requestPreview(index)
        revealSeekBar()
    }

    private static let thumbnailContext = CIContext(options: [.cacheIntermediates: false])

    private func updatePreviewView() {
        guard let frame = previewFrame, let index = core.index, let container = window?.contentView else { return }
        let lens = KeyframeLens(index: index, frame: frame)
        seekBar.previewFrame = frame
        previewView.show(image: previewImage, scale: window?.backingScaleFactor ?? 2,
                         time: "\(FrameNaming.timecode(index.seconds(forFrame: frame)))  f\(frame)" + (lens.map { "  " + $0.label } ?? ""),
                         lens: lens, playhead: core.position)
        previewView.layoutSubtreeIfNeeded()
        let fraction = Double(frame) / Double(max(core.frameCount - 1, 1))
        let trackX = seekBar.frame.minX + 12 + fraction * (seekBar.frame.width - 24)
        let width = previewView.fittingSize.width
        let maxLeading = max(container.bounds.width - width - 8, 8)
        previewLeading.constant = min(max(trackX - width / 2, 8), maxLeading)
    }

    private func updateSeekBar() {
        let marks = core.marks
        // What each clip gets before its mark from the keyframe it starts on (exact index only).
        let leadIns = core.index.map { index in
            index.isExact ? marks.segments.compactMap { segment -> ClosedRange<Int>? in
                let keyframe = index.keyframe(atOrBefore: segment.start)
                return keyframe < segment.start ? keyframe...(segment.start - 1) : nil
            } : []
        } ?? []
        seekBar.update(frameCount: core.frameCount, position: core.position, cached: core.cache.cachedRanges(),
                       loopA: core.loopA, loopB: core.loopB, marks: marks.segments.map { $0.start...$0.end },
                       leadIns: leadIns, openMark: marks.open, text: "\(core.progressText)   frame \(core.position)")
        updateTransport()
    }

    /// The seek bar's ⏮ ⏭ and volume, as the playlist and the player are now; the controls touch only what changed.
    /// ⏮ ⏭ follow < and >: a page's list, Stash's queue (whose ends only Stash knows), else the folder.
    private func updateTransport() {
        let (previous, next): (Bool, Bool) = if let listPlaylist {
            (listPlaylist.previous != nil, listPlaylist.next != nil)
        } else if followsStashQueue {
            (true, true)
        } else {
            (playlist?.previous != nil, playlist?.next != nil)
        }
        seekBar.transport.update(hasPrevious: previous, hasNext: next, volume: core.volume, muted: core.isMuted)
    }

    /// A click on a seek bar control: the command as its key runs it, silently (the bar plays no haptics), and the
    /// bar stays up.
    private func runFromSeekBar(_ command: Command) {
        runInput(command, from: .menu)
        updateTransport()
        revealSeekBar()
    }

    // MARK: Slots and plugin pages

    private func buildSlots(in container: ContainerView) {
        pluginPolicy = PluginPolicy(openAllowedText: globalConfig.pluginOpenAllowed)
        for entry in globalConfig.plugins { pluginPolicy.trust(entry.url) }
        slots = SlotsController(container: container, above: startScreen, config: globalConfig, playlistView: playlistPanel)
        slots.configurePage = { [weak self] in self?.configurePluginPage($0) }
        slots.onLayout = { [weak self] video, visible in self?.slotsLaidOut(video: video, visible: visible) }
        slots.onPersist = { [weak self] edge, setting in self?.persistSlot(edge, setting) }
        slots.onMessage = { [weak self] in self?.showMessage($0) }
        slots.onPagesChanged = { [weak self] in
            guard let self else { return }
            rebuildInputMap()   // a page's keys count while it is in a slot
            dispatchPanelInfo()
            pushPluginState(force: true)
            updatePrecisionWheel()
        }
        slots.onFocusVideo = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(videoView)
        }
        slots.onPageDropped = { [weak self] page in
            guard let self else { return }
            clearPluginActions(of: page.token)
            panelInfoSent[page.token] = nil
        }
        core.onSegmentChange = { [weak self] current, locked in
            guard let self else { return }
            if holdsSegmentEvents {
                heldSegmentEvent = .segment(current: current, locked: locked)   // after fileopened (`openCore`)
                return
            }
            dispatchToPages(.segment(current: current, locked: locked))
            pushPluginState(force: true)
        }
        slots.start()
    }

    /// A page the slots made: its requests, focus and keys come here.
    private func configurePluginPage(_ page: PluginPanel) {
        page.trusted = pluginPolicy.trusted
        applyPluginStash(globalConfig, to: page)
        page.onMessage = { [weak self] in self?.pluginMessage($0, from: $1) }
        page.onFocusChange = { [weak self, weak page] focused in
            self?.endHoldSpeed()   // the key-up may go elsewhere
            page?.dispatch(focused ? .focus : .blur)
            self?.dispatchPanelInfo()
            self?.pushPluginState(force: true)
        }
        page.onUnhandledKey = { [weak self, weak page] event, stillDown in
            guard let self else { return }
            // Esc the page left alone hides its slot when the slot lies over the video.
            if event.keyCode == 53, !event.isARepeat, let page, slots.escape(in: page) { return }
            handleKey(event, stillDown: stillDown)
        }
        page.onKeyUp = { [weak self] in
            if $0.keyCode == self?.holdKeyCode { self?.endHoldSpeed() }
        }
        page.onPageReplaced = { [weak self, weak page] in
            guard let self, let page else { return }
            clearPluginActions(of: page.token)
            panelInfoSent[page.token] = nil   // the new page has heard nothing yet
            dispatchPanelInfo()
        }
    }

    /// The `panel` event each page heard last.
    private var panelInfoSent: [Int: PanelInfo] = [:]

    /// Each page hears where its slot is and how it shows (`panel`), when that changed.
    private func dispatchPanelInfo() {
        for page in slots.pages {
            guard let info = slots.panelInfo(for: page), panelInfoSent[page.token] != info else { continue }
            panelInfoSent[page.token] = info
            page.dispatch(.panel(info))
        }
    }

    /// `framescrub.stash` for the plugins listed in the settings: Stash's address and key, nil without a server.
    private func applyPluginStash(_ config: Config, to page: PluginPanel) {
        page.stash = config.stashEnabled ? .init(url: config.stashURL, apiKey: config.stashAPIKey) : nil
        page.stashOrigins = Set(config.plugins.compactMap { PluginOrigin(url: $0.url) })
    }

    /// The pages get `window.framescrub` for the origins now trusted.
    private func applyPluginTrust() {
        for page in slots.pages { page.trusted = pluginPolicy.trusted }
    }

    /// The slots moved: the video takes its rect (only a pinned slot changes it), the seek bar, OSD and stats the part
    /// of it no overlay slot covers.
    private func slotsLaidOut(video: CGRect, visible: CGRect) {
        guard let container = window?.contentView else { return }
        let bounds = container.bounds
        func set(_ edges: [NSLayoutConstraint], _ rect: CGRect) {
            let constants = [rect.minX - bounds.minX, rect.maxX - bounds.maxX, bounds.maxY - rect.maxY, bounds.minY - rect.minY]
            for (edge, constant) in zip(edges, constants) where edge.constant != constant { edge.constant = constant }
        }
        set(videoEdges, video)
        set(visibleEdges, visible)
        visibleVideoRect = visible
        statsPanel.place()
    }

    private func persistSlot(_ edge: SlotEdge, _ setting: SlotSetting) {
        slotWrites[edge]?.invalidate()
        slotWrites[edge] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.preferences.update([edge.key]) { $0.slots[edge] = setting } } catch {
                    self.showMessage("Cannot save \(edge.key): \(error.localizedDescription)", duration: 3)
                }
            }
        }
    }

    /// Settings changed: which origins may open files, and the plugin list (a slot whose plugin changed loads it).
    private func applyPluginConfig(_ config: Config, previous: Config) {
        pluginPolicy.openAllowed = PluginPolicy(openAllowedText: config.pluginOpenAllowed).openAllowed
        for entry in config.plugins { pluginPolicy.trust(entry.url) }
        applyPluginTrust()
        for page in slots.pages { applyPluginStash(config, to: page) }
        slots.configChanged(config)
    }

    /// View › Focus Plugin Panel: the first page's slot is shown with the keyboard.
    func focusPluginPanel() {
        slots.togglePlugin(focus: true)
    }

    /// View › Show Plugin Panel: the slot holding the first page (or the first plugin put into an empty slot).
    func togglePluginPanel() {
        slots.togglePlugin()
    }

    /// View › Slots: ⌃⌘← / ⌃⌘→ / ⌃⌘↓.
    func toggleSlot(_ edge: SlotEdge) { slots.toggle(edge) }
    func togglePinOfCurrentSlot() { slots.togglePinOfCurrent() }
    func cycleBackdropOfCurrentSlot() { slots.cycleBackdropOfCurrent() }
    func clearCurrentSlot() { slots.clearCurrent() }

    /// A link's `plugin=` page; one the link may not load (a `file:` page) is refused with a notice.
    private func showLinkPlugin(_ url: URL) {
        pluginPolicy.trust(url)
        applyPluginTrust()
        guard slots.showLinkPage(url) else {
            showMessage("Cannot show the plugin page: \(url.absoluteString)", duration: 4)
            return
        }
    }

    /// An event for every page, shown or not.
    private func dispatchToPages(_ event: PluginEvent) {
        for page in slots.pages { page.dispatch(event) }
    }

    private func pluginMessage(_ request: PluginRequest, from origin: PluginOrigin) {
        let page = request.page.flatMap { slots.page(withToken: $0) }
        switch request.message {
        case let .seek(t): core.seek(toSeconds: t)
        case .play: if core.isPaused { core.play() }
        case .pause: if !core.isPaused { core.pause() }
        case let .step(n): core.step(frames: n)
        case let .loop(segment): core.setLoop(seconds: segment)
        case let .segments(list, lock, advance):
            guard core.setSegments(seconds: list, lock: lock ?? true, advance: advance) else {
                pluginFailed(request, "no segment inside the file")
                return
            }
        case let .lock(on):
            guard core.setSegmentLock(on) else { pluginFailed(request, "no segments"); return }
        case let .goSegment(i):
            guard core.goSegment(i) else { pluginFailed(request, "no such segment"); return }
        case let .actions(list):
            pluginDone(request, result: declarePluginActions(list, page: request.page ?? 0).json)
            return
        case .focusPlayer: window?.makeFirstResponder(videoView)
        case let .open(.file(url, landing)):
            whenFramesAllowed(request, origin: origin, verb: "open") { [self] in
                notePageFacts(request, replacing: false)
                page.map(slots.pageChosePlay)
                openFromPlugin(url, landing: landing, origin: origin, request: request)
            }
            return
        case let .open(.stashScene(id, paths, landing)):
            page.map(slots.pageChosePlay)
            dropListPlaylist()
            openStashScene(id: id, paths: paths, landing: landing)
        case let .open(.stream(url, landing)):   // nothing on this Mac is read: no consent to ask
            guard !isStashURL(url) else { pluginFailed(request, Self.stashURLRefusal("open")); return }
            whenFramesAllowed(request, origin: origin, verb: "open") { [self] in
                notePageFacts(request, replacing: false)
                page.map(slots.pageChosePlay)
                open(url, landing: landing) { [weak self] in self?.answerOpen(request, $0, name: url.absoluteString) }
            }
            return
        case .info, .marks, .playlist, .frame: answerPluginRequest(request); return
        case .hide:
            if let page { slots.hide(page: page) }
        case let .setPlaylist(items, index, name):
            whenListAllowed(items, verb: "playlist", origin: origin, request: request) { [self] in
                notePageFacts(request, replacing: true)
                listPlaylist = ListPlaylist(items: items, index: index, name: name)   // the message checked the index
                page.map(slots.pageChosePlay)
                openListItem(at: index)
                pluginDone(request)
            }
            return
        case let .enqueue(items):
            whenListAllowed(items, verb: "enqueue", origin: origin, request: request) { [self] in
                notePageFacts(request, replacing: false)
                let opensFirst = listPlaylist == nil && currentPlaylistItem == nil
                guard let list = ListPlaylist.enqueue(items, onto: listPlaylist, current: currentPlaylistItem) else {
                    pluginFailed(request, "enqueue: too many items")
                    return
                }
                listPlaylist = list
                if opensFirst { openListItem(at: 0) } else { updatePlaylistPanel(); core.url.map(updateTitle) }
                pluginDone(request)
            }
            return
        }
        pluginDone(request)
    }

    /// `info`, `marks`, `playlist` and `frame`: answered from the open file, refused without one.
    private func answerPluginRequest(_ request: PluginRequest) {
        guard let url = core.url, let info = core.info, let index = core.index else {
            pluginFailed(request, "no file is open")
            return
        }
        switch request.message {
        case .info:
            let details = PluginInfo(path: url.path, name: url.lastPathComponent, fps: info.frameRate,
                                     duration: core.durationSeconds, durationFrames: core.frameCount, width: info.width,
                                     height: info.height, rotation: info.rotationClockwise, codec: info.format.videoCodec,
                                     source: PluginSource(url: url),
                                     url: ByteSources.isRemote(url) ? url.absoluteString : nil)
            pluginDone(request, result: details.json)
        case .marks:
            let marks = PluginMarks(marks: core.marks, loopA: core.loopA, loopB: core.loopB, seconds: index.seconds(forFrame:))
            pluginDone(request, result: marks.json)
        case .playlist:
            let list = if let listPlaylist {
                PluginPlaylist(index: listPlaylist.currentIndex, count: listPlaylist.items.count,
                               total: listPlaylist.items.count, name: url.lastPathComponent, source: .list)
            } else {
                playlist.map { PluginPlaylist(index: $0.currentIndex, count: $0.files.count, total: $0.totalCount,
                                              name: url.lastPathComponent, source: followsStashQueue ? .stash : .folder) }
                    ?? PluginPlaylist(index: 0, count: 1, total: 1, name: url.lastPathComponent,
                                      source: followsStashQueue ? .stash : .folder)
            }
            pluginDone(request, result: list.json)
        case let .frame(frameRequest):
            guard let n = frameRequest.frameNumber(frameCount: core.frameCount, frameForSeconds: index.frameNumber(forSeconds:)) else {
                pluginFailed(request, "frame: past the end of the file")
                return
            }
            if pluginGrabber == nil {
                pluginGrabber = PluginFrameGrabber(url: url, index: index, rotationClockwise: info.rotationClockwise,
                                                   readCache: core.readCache)
            }
            pluginGrabber?.grab(frame: n, maxSide: frameRequest.maxSize) { [weak self] result in
                MainActor.assumeIsolated { self?.pluginFrameDecoded(result, for: request, file: url, index: index) }
            }
        default:
            pluginDone(request)
        }
    }

    /// A request carried out: a `request()` resolves (with `result`, JSON), a verb hears nothing.
    private func pluginDone(_ request: PluginRequest, result: String? = nil) {
        if let id = request.id, let page = request.page.flatMap({ slots.page(withToken: $0) }) {
            page.reply(.success(id, result: result))
        }
    }

    private func pluginFailed(_ request: PluginRequest, _ reason: String) {
        request.page.flatMap { slots.page(withToken: $0) }?.fail(id: request.id, reason)
    }

    /// A `frame` request's picture arrived (or not); nothing is said when another file is open by now.
    private func pluginFrameDecoded(_ result: Result<PluginFrameGrabber.Picture, PluginFrameGrabber.Failure>,
                                    for request: PluginRequest, file url: URL, index: FrameIndex) {
        guard core.url == url else { return }
        switch result {
        case let .success(picture):
            let t = (core.index ?? index).seconds(forPTS: picture.pts)
            let frame = PluginFrame(t: t, frame: picture.frame, width: Int(picture.size.width),
                                    height: Int(picture.size.height), jpeg: picture.jpeg)
            pluginDone(request, result: frame.json)
        case .failure(.stopped):
            break
        case .failure(.noFrame):
            pluginFailed(request, "frame: nothing decoded there")
        case let .failure(.decoding(reason)):
            pluginFailed(request, "frame: \(reason)")
        }
    }

    /// A page's `open` of a file or stream, answered once the open is over.
    private func answerOpen(_ request: PluginRequest, _ outcome: OpenOutcome, name: String) {
        switch outcome {
        case .opened: pluginDone(request)
        case .failed: pluginFailed(request, "open: cannot open \(name)")
        case .superseded: pluginFailed(request, "open: replaced by another open")
        }
    }

    /// A local file the page asked for: only a video, and only once the user has allowed the page's origin to open
    /// files (asked the first time, remembered in `plugin-open-allowed`).
    private func openFromPlugin(_ url: URL, landing: LinkTarget, origin: PluginOrigin, request: PluginRequest) {
        let openIt = { [self] in
            open(url, landing: landing) { [weak self] in self?.answerOpen(request, $0, name: url.path) }
        }
        switch pluginPolicy.decision(forOpening: url, from: origin) {
        case .allowed:
            openIt()
        case .notMedia:
            showMessage("The plugin page may only open video files: \(url.lastPathComponent)", duration: 4)
            pluginFailed(request, "open: not a video file")
        case .untrusted:
            pluginFailed(request, "open: the page is not trusted")
        case .needsConsent:
            askOpenConsent(origin, asked: "to open \(url.path)", verb: "open", request: request, then: openIt)
        }
    }

    /// A page's list with local files: allowed as `open({path})` would be for each of them, with one question for all.
    private func whenListAllowed(_ items: [PlaylistItem], verb: String, origin: PluginOrigin, request: PluginRequest,
                                 then apply: @escaping () -> Void) {
        let apply = { [weak self] in self?.whenFramesAllowed(request, origin: origin, verb: verb, then: apply) ?? () }
        let streams = items.compactMap { item -> URL? in if case let .stream(url, _, _) = item { url } else { nil } }
        guard !streams.contains(where: isStashURL) else { pluginFailed(request, Self.stashURLRefusal(verb)); return }
        let files = items.compactMap { item -> URL? in if case let .file(url, _, _) = item { url } else { nil } }
        switch pluginPolicy.decision(forOpening: files, from: origin) {
        case .allowed: apply()
        case .notMedia: pluginFailed(request, "\(verb): not a video file")
        case .untrusted: pluginFailed(request, "\(verb): the page is not trusted")
        case .needsConsent:
            let asked = files.count == 1 ? "to play \(files[0].path)" : "to play \(files.count) files"
            askOpenConsent(origin, asked: asked, verb: verb, request: request, then: apply)
        }
    }

    /// A URL on the Stash server: read with the API key, so a page may not name it (`{scene}` opens Stash's scenes).
    private func isStashURL(_ url: URL) -> Bool { !StashOpenPolicy.headers(for: url, config: core.config).isEmpty }

    private static func stashURLRefusal(_ verb: String) -> String { "\(verb): a Stash URL: open it by scene" }

    /// The first time a page's origin opens local files: ask, remember a yes in `plugin-open-allowed`.
    private func askOpenConsent(_ origin: PluginOrigin, asked: String, verb: String, request: PluginRequest,
                                then allowed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = PluginPolicy.consentQuestion(for: origin)
        alert.informativeText = "The page asked \(asked). Your answer is remembered for this page."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let decide = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { pluginFailed(request, "\(verb): not allowed by the user"); return }
            pluginPolicy.allowOpening(from: origin)
            let text = pluginPolicy.openAllowedText
            do { try preferences.update(["plugin-open-allowed"]) { $0.pluginOpenAllowed = text } } catch {
                showMessage("Cannot save plugin-open-allowed: \(error.localizedDescription)", duration: 3)
            }
            allowed()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: decide) } else { decide(alert.runModal()) }
    }

    /// A Stash scene the page asked for: its file is found on the shares as for ▶ on a scene page, and `landing` is
    /// applied once it is open.
    private func openStashScene(id: String, paths: [String], landing: LinkTarget) {
        openStashScene(StashScene(id: id, paths: paths), landing: landing)
    }

    /// The page hears of every file that opens, whoever opened it.
    private func pluginFileOpened() {
        var scene: String?
        if case let .stash(sceneID, _) = origin { scene = sceneID }
        let source = core.url.map(PluginSource.init) ?? .file
        dispatchToPages(.fileOpened(path: source == .file ? core.url?.path : nil,
                                    url: source == .stream ? core.url?.absoluteString : nil, scene: scene, source: source))
    }

    /// The player's state for the pages: at once on a state change, else ten times a second while frames show for a page
    /// whose slot is on screen and four times a second for one whose slot is hidden (see `PluginPushPacing`).
    private func pushPluginState(force: Bool) {
        guard let slots, !slots.pages.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let shownDue = pushPacing.due(shown: true, now: now, force: force)
        let hiddenDue = pushPacing.due(shown: false, now: now, force: force)
        guard shownDue || hiddenDue else { return }
        var state = PluginState(ready: core.url != nil, path: core.url?.path, name: core.url?.lastPathComponent,
                                t: core.positionSeconds, frame: core.position, fps: core.info?.frameRate ?? 0,
                                duration: core.durationSeconds, durationFrames: core.frameCount, playing: !core.isPaused,
                                loop: core.loopSeconds, segments: pluginSegments(), visible: true)
        if case let .stash(sceneID, _) = origin { state.scene = sceneID }
        for page in slots.pages where page.isShownInSlot ? shownDue : hiddenDue {
            var pageState = state
            pageState.panel = slots.panelInfo(for: page)
            pageState.visible = page.isShownInSlot
            page.push(pageState)
        }
    }

    /// The segment set for the page; nil with none.
    private func pluginSegments() -> PluginState.Segments? {
        guard core.segments != nil else { return nil }
        return PluginState.Segments(list: core.segmentsSeconds, current: core.currentSegment, locked: core.segmentsLocked,
                                    advance: core.segmentAdvance)
    }

    // MARK: Stats

    /// The stats panel goes over the video, under the seek bar, in the top right corner. It may cover the video below
    /// the title bar and above the seek bar's zone (its height even while the bar is hidden, so the panel stays put).
    private func buildStatsPanel(in container: ContainerView) {
        let seekBarZone: CGFloat = 12 + 44 + 8
        let panel = InfoPanelController(
            host: container, below: seekBar, keyPrefix: "statsPanel", defaultOrder: StatsContent.defaultOrder,
            defaultPlacement: PanelPlacement(corner: .topRight, dx: 12, dy: 12),
            area: { [weak container, weak self] in
                // The part of the video no slot covers (y down), above the seek bar.
                guard let bounds = container?.bounds else { return .zero }
                let visible = self?.visibleVideoRect ?? bounds
                return CGRect(x: visible.minX, y: bounds.maxY - visible.maxY, width: visible.width,
                              height: max(visible.height - seekBarZone, 0))
            })
        panel.middleTruncated = ["Folder"]
        // A held button with the wheel is one of the player's chords (MBTN_RIGHT+WHEEL, MBTN_BACK+WHEEL_UP and the
        // other held mouse buttons, the Logitech mouse's too, `buttons.held`): as over the video.
        panel.wheel = { [weak self] event in
            guard let self, NSEvent.pressedMouseButtons & 0b10 != 0 || !buttons.held.isEmpty else { return false }
            videoView.scrollWheel(with: event)
            return true
        }
        panel.otherMouse = { [weak self] event in
            guard let videoView = self?.videoView else { return }
            switch event.type {
            case .otherMouseDown: videoView.otherMouseDown(with: event)
            case .otherMouseDragged: videoView.otherMouseDragged(with: event)
            case .otherMouseUp: videoView.otherMouseUp(with: event)
            default: break
            }
        }
        // A value selected in the panel keeps ⌘C (while text is selected) and ⌘A; every other key goes on to the
        // player. ⌘C with nothing selected (a plain click on a value) copies the frame, as Edit › Copy does over the
        // video: that menu item, not the input.conf binding, is what ⌘C does there.
        panel.plainKey = { [weak self] event in
            guard let self else { return }
            window?.makeFirstResponder(videoView)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            if flags == .command, event.keyCode == 8 {   // kVK_ANSI_C, on any layout
                copy(nil)
                return
            }
            videoView.keyDown(with: event)
        }
        panel.onShownChange = { [weak self] shown in
            if shown { self?.refreshStats() }
            self?.updateStatsTimer()
            self?.updatePrecisionWheel()   // the panel may come or go under the pointer
        }
        container.onLayout = { [weak panel, weak self] in
            self?.slots?.containerDidLayout()
            panel?.place()
        }
        statsPanel = panel
    }

    /// For View › Show Stats / Hide Stats.
    var statsVisible: Bool { statsPanel.isVisible }

    /// For the ticks of Playback › Colour: the open file's colour over framescrub.conf.
    var colorConfig: Config { core.config }

    /// For Playback › Colour › Reset File / Folder Colour: whether there is anything to reset.
    func hasOwnColor(_ level: ColorLevel) -> Bool { colorMemory.hasOwn(level) }

    /// A file opened, failed or closed: the panel is there only while one is open, with the file's name and folder
    /// (its size and date follow the first picture, `readFileFacts`).
    private func statsFileChanged() {
        fileFacts = core.url.map {
            FileFacts(name: $0.lastPathComponent, folder: $0.deletingLastPathComponent().path, size: nil, modified: nil)
        }
        statsPanel.isAvailable = core.url != nil
        refreshStats()
    }

    /// The file's size and date, read off the main thread (a NAS can take a while); kept if the file is still open.
    private func readFileFacts(of url: URL) {
        Task { [weak self] in
            let facts = await Task.detached(priority: .utility) { FileFacts.read(url) }.value
            guard let self, core.url == url else { return }
            fileFacts = facts
            refreshStats()
        }
    }

    /// The panel's sections from the player, the file, the picture on screen and Stash's answer about the scene.
    /// Only while the panel is on screen: the player's snapshot starts measuring sharpness.
    private func refreshStats() {
        guard statsPanel.isShown else { return }
        let picture = PictureStats(
            scaler: videoView.scalerText, skippedFrames: videoView.skippedFrames, aspect: aspectStatus,
            colour: videoView.colorCorrection.statusText(autoFrame: autoColorFrame, autoPending: autoColorPending,
                                                         interval: core.config.autoColorInterval,
                                                         autoDelta: autoColorDelta, saved: core.config.saveColor,
                                                         origin: colorOrigin),
            sceneSearch: sceneSearch?.statusText)
        var stash: StashDetailsState?
        if case let .stash(sceneID, _) = origin, let details = stashSession?.details, details.sceneID == sceneID {
            stash = details.state
        }
        statsPanel.show(StatsContent.sections(player: core.stats, file: fileFacts, picture: picture, stash: stash))
    }

    /// The 0.5 s refresh runs while the panel is on screen and the window can be seen (not minimised or covered).
    private func updateStatsTimer() {
        let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        guard statsPanel?.isShown == true, visible else {   // the window's delegate is called before the panel exists
            statsTimer?.invalidate()
            statsTimer = nil
            return
        }
        guard statsTimer == nil else { return }
        refreshStats()   // what changed while the window could not be seen
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    // MARK: PlayerCoreDelegate

    func player(_ player: PlayerCore, display frame: DecodedFrame) {
        videoView.show(frame)
        lastFrame = frame
        checkSceneCut(frame)
        pushPluginState(force: false)
        recomputeAutoColorIfDue(frame)
        refreshEnhancement()
    }

    func playerStateDidChange(_ player: PlayerCore) {
        pushPluginState(force: true)
        if core.isPaused != wasPaused {
            wasPaused = core.isPaused
            if wasPaused { stashSession?.saveProgress() }
        }
        if seekBar.alphaValue > 0 { updateSeekBar() }
        refreshEnhancement()
    }

    func player(_ player: PlayerCore, showOSD text: String) {
        if let frame = sceneFrameOSDToDrop {
            sceneFrameOSDToDrop = nil   // one chance: any other OSD ends it
            if frame == core.position, text == core.frameText { return }   // the decoded jump target: the scene line stays
        }
        osd.onClick = text.hasPrefix("Saved") ? { [weak self] in self?.revealFrames() } : nil
        if text.hasPrefix("Saved") { videoView.flash() }
        osd.show(text, duration: 1.5)
    }

    func player(_ player: PlayerCore, showFeedback feedback: Feedback) {
        hud.show(feedback)
        switch feedback {
        case .volume, .mute: updateTransport()   // a key's change shows on the slider
        default: break
        }
    }

    private func revealFrames() {
        guard let target = core.revealTarget else { showMessage("No frames saved yet"); return }
        if (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            NSWorkspace.shared.open(target)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func player(_ player: PlayerCore, copyImage data: Data, frame: Int, note: String?) {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(data, forType: .png) else { showMessage("Copy failed"); return }
        videoView.flash()
        showMessage("Copied frame \(frame)" + (note.map { " · \($0)" } ?? ""))
    }

    func playerDidReachEnd(_ player: PlayerCore) {
        guard core.config.playlistAutoadvance else { return }
        if let listPlaylist {
            if listPlaylist.next != nil { openListItem(at: listPlaylist.currentIndex + 1, plays: true) }
            return
        }
        if followsStashQueue { stepStashQueue(1, plays: true); return }
        whenFolderRead { [weak self] in
            guard let self, let next = playlist?.next else { return }
            openFile(next) { [weak self] outcome in
                switch outcome {
                case .opened: self?.core.play()
                case .failed: self?.playerDidReachEnd(player)   // the playlist now follows the broken file: move past it
                case .superseded: break
                }
            }
        }
    }

    // MARK: StillEnhancerDelegate

    private func refreshEnhancement() {
        enhancer.update(frame: lastFrame, isPaused: core.isPaused,
                        rotationClockwise: core.info?.rotationClockwise ?? 0, ratio: videoView.displayRatio)
    }

    func stillEnhancer(_ enhancer: StillEnhancer, didEnhanceFrame number: Int, pts: Int64, image: CIImage) {
        videoView.showEnhanced(image, forFrame: number, pts: pts)
    }

    func stillEnhancer(_ enhancer: StillEnhancer, message: String) {
        showMessage(message, duration: 1.5)
    }

    func stillEnhancer(_ enhancer: StillEnhancer, requestModelDownload decide: @escaping (ModelDownloadChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download the Apple image-enhancement model?"
        alert.informativeText = "FrameScrub can redraw paused frames sharper with a neural network. The model downloads once."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not now")
        alert.addButton(withTitle: "Never")
        switch alert.runModal() {
        case .alertFirstButtonReturn: decide(.download)
        case .alertThirdButtonReturn: decide(.never)
        default: decide(.notNow)
        }
    }

    func stillEnhancerDidDisable(_ enhancer: StillEnhancer) {
        onDisableSRStill?()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        showCursorAfterScrub()
        shutdown()
        // The app has exactly one player window; without it nothing can play, even if Settings is still open.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func windowDidChangeScreen(_ notification: Notification) { updateScreenPixelSize() }
    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResignKey(_ notification: Notification) {
        endHoldSpeed()   // the key-up goes elsewhere
        cancelMouseInput()   // and so may a button's release
        showCursorAfterScrub()
        updatePrecisionWheel()
    }
    func windowDidBecomeKey(_ notification: Notification) { updatePrecisionWheel() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateStatsTimer() }
    func windowDidMiniaturize(_ notification: Notification) { updateStatsTimer() }
    func windowDidDeminiaturize(_ notification: Notification) { updateStatsTimer() }
    func windowDidEnterFullScreen(_ notification: Notification) { updatePrecisionWheel() }
    func windowDidExitFullScreen(_ notification: Notification) { updatePrecisionWheel() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }

    /// The stats panel's values use their own field editor (⌘C, ⌘A, plain keys to the player). Asked already while
    /// the window is being built, before the panel exists.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { statsPanel?.fieldEditor(for: client) }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateScreenPixelSize()
        configurePreview()
    }

    /// `save-scale=fit` / `export-scale=fit` fit frames into the physical pixels of the window's screen.
    private func updateScreenPixelSize() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        core.screenPixelSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.ctrl) }
        if flags.contains(.option) { insert(.alt) }
        if flags.contains(.command) { insert(.meta) }
    }
}

/// The window's content view; tells the stats panel to place itself on each layout (resize, full screen).
private final class ContainerView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// A frame for the background auto colour analysis (`CIImage` is immutable).
private struct AutoColorRequest: @unchecked Sendable {
    let image: CIImage
    let frame: Int
    let session: Int
}

/// A shown frame for the scene-cut detector.
private struct SceneRequest: @unchecked Sendable {
    let image: CIImage
    let session: Int
}

/// The scene-cut detector's state, touched only on its worker's queue.
private final class SceneCutState: @unchecked Sendable {
    var detector = SceneCutDetector()
    var session = -1
}

/// What a background folder read hands to the main thread (written before its group is left).
private final class FolderReadResult: @unchecked Sendable {
    var listing: FolderListing?
}
