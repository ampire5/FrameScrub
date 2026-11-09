import AppKit
import CoreImage
import FrameScrubCore
import FrameScrubSettings
import HomeScreenKit
import InfoPanelKit
import LogiHIDPP
import StashKitUI
import SwiftUI

final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlayerCoreDelegate {
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
    private let tourBoxBridge = TourBoxBridge()
    private var tourBoxRouter = TourBoxRouter()
    private var tourBoxTap: DispatchWorkItem?
    private var tourBoxEnabled = false
    private var tourBoxEditsEdge = false
    private var tourBoxHoldsSpeed = false
    /// Folder history uses the same duplicate/drag protection, with no player holds or wheel chords.
    private let homeButtons = MouseButtonRouter(map: InputMap(bindings: [
        KeyChord(key: "MBTN_BACK"): .playlistPrev,
        KeyChord(key: "MBTN_FORWARD"): .playlistNext,
    ]), longPressMilliseconds: 400)
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
    /// Holds Home where the video is: over it and under the slots. Home goes in the first time it shows.
    private let homeHost = NSView()
    private var home: HomeView?
    /// Home's source (the view holds it weakly).
    private var homeSource: FrameScrubHomeSource?
    /// The window's title while Home has the window, put back when it goes.
    private var titleBeforeHome: String?
    private var hasShownHome = false
    /// The folder a video was opened from in Home and that video: Home goes back to it, the file selected.
    /// The order is Home's sort of that folder, which its playlist follows while the folder is the playlist.
    private var folderReturn: (folder: URL, file: URL)?
    /// Each folder's order, shared with Home's grid.
    private let folderSorts: FolderSorts
    /// The videos the decoders could not read in this run: Home draws them faint, the folder's steps go past them.
    private let unreadable: UnreadableFiles
    /// Esc on Home (`makeHome`).
    private var homeKeys: Any?
    /// Why a file did not open, in its place.
    private let failureView = OpenFailureView()
    /// The Stash WebUI (Stash spec §2.1), Home's Stash page, created the first time it is shown.
    private var stashLibrary: StashLibraryView?
    private var stashSession: StashSession?
    /// Where the file on screen came from; a Stash scene is reported back to Stash.
    private(set) var origin = FileOrigin.plain
    /// Where closing the file goes back to: Stash for a scene and the folder steps after it, else Recent.
    private var returnTab = HomeTab.recent
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
    private weak var artifactFilterPanel: ArtifactFilterPanelView?
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
    private var pluginAnalysisSourceID: String?
    private var pluginAnalysisOwner: (page: Int, origin: PluginOrigin)?
    private var pluginAnalysisPolling: Task<Void, Never>?
    private var pluginAnalysisVersion: String?
    private struct AnalysisVersionWaiter {
        let id: Int
        let page: Int
        let origin: PluginOrigin
    }
    private var pluginAnalysisVersionWaiters: [AnalysisVersionWaiter] = []
    private struct AnalysisVersionRead: Sendable {
        let sourceID: String
        let cache: ReadCache
    }
    private lazy var pluginAnalysisVersionWorker = LatestOnlyWorker<AnalysisVersionRead>(
        label: "framescrub.analysis-version", qos: .utility
    ) { [weak self] work in
        let version = try? VirtualCutMediaVersion.read(from: work.cache)
        Task { @MainActor in self?.finishPluginAnalysisVersion(version, sourceID: work.sourceID) }
    }
    private var pluginAnalysisVersionInFlight = false
    /// While `core.open` runs: segment events wait until the page has heard `fileopened` (Ruling R20).
    private var holdsSegmentEvents = false
    /// The last segment event raised while held; dispatched right after `fileopened`.
    private var heldSegmentEvent: PluginEvent?
    private var pushPacing = PluginPushPacing()
    /// The open file's name and folder at once, its size and date once read off the main thread.
    private var fileFacts: StatsFile?
    /// Refreshes the stats every 0.5 s while the panel is on screen and the window can be seen.
    private var statsTimer: Timer?
    private let hud = FeedbackHUD()
    private let goToField = GoToField()
    private let seekBar = SeekBarView()
    private var virtualCut: VirtualCutSession?
    private struct CutEditContext {
        let token = UUID()
        let session: VirtualCutSession
        let catalog: (source: String, card: String)
        let anchor: VirtualCutTimeline.Anchor
        let source: VirtualCutSource
        let time: Double
        var originalReady = false
    }
    private var virtualCutReturn: CutEditContext?
    private lazy var virtualCutAnchors: [String: VirtualCutTimeline.Anchor] = {
        guard let data = UserDefaults.standard.data(forKey: "virtual-cut.resume") else { return [:] }
        return (try? JSONDecoder().decode([String: VirtualCutTimeline.Anchor].self, from: data)) ?? [:]
    }()
    private var virtualCutCatalogLocation: (source: String, card: String)?
    private var pluginCatalogs: [Int: PluginCatalogSource] = [:]
    private var catalogOpen: Task<Void, Never>?
    private var virtualCutBenchBoundary: Double?
    private var cutBenchOutsideFrames = 0
    private var cutBenchDecodedSpans = Set<Int>()
    private var cutBenchEarlyPosters = Set<Int>()
    private var cutBenchLandingHits = 0
    private var isVirtualCutBench = false
    private var cutBenchRequest = 0
    private var cutBenchPresented = 0
    private var cutBenchStarted = 0.0
    private var cutBenchOpenStarts = 0
    private var cutBenchSuperseded = 0
    private var cutBenchWarmStarts = 0
    private var cutBenchWarmReused = 0

    private var seekBarHeight: NSLayoutConstraint!
    private var filmstripLoader: FilmstripPreviewLoader?
    private var filmstripPrewarmFrames = Set<Int>()
    private var pausedFilmstripPrewarmPosition: Int?
    private let backButton = BackButton()
    private let previewView = PreviewView()
    /// The playlist's view; shown in whichever slot holds the playlist.
    private let playlistPanel = PlaylistPanelView()
    /// The playlist panel's name filter (kept from file to file until cleared).
    private var playlistFilter = ""
    private let keyHelp = KeyHelpView()
    private var previewProvider: FrameScrubCore.PreviewProvider?
    private var previewImage: CGImage?
    private var previewSample: (seconds: Double, exact: Bool)?
    /// Where the pointer is on the seek bar (0…1); nil while it is not on the bar.
    private var previewFraction: Double?
    private var cutHoverFraction: Double?
    private var previewHoverWork: DispatchWorkItem?
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
    private var backButtonTop: NSLayoutConstraint!
    /// In full screen, how far the title bar that slides in with the menu bar reaches down over the window (0 while it
    /// is away): the back button and the OSD move down by it, not under it (`followFullScreenTitlebar`).
    private var titlebarInset: CGFloat = 0
    private var titlebarObserver: NSObjectProtocol?
    private var isBackButtonShown = false
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
    private var markReferenceGeneration = 0
    private lazy var markReferenceWorker = LatestOnlyWorker<(frame: DecodedFrame, rotation: Int, generation: Int)>(
        label: "framescrub.mark-reference", qos: .utility
    ) { [weak self] request in
        guard let image = FrameImageRenderer().thumbnail(for: request.frame, rotationClockwise: request.rotation, width: 224)
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, markReferenceGeneration == request.generation else { return }
            seekBar.setMarkDragReference(image)
        }
    }
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
    /// What is asked of the Logitech mouse's wheel now (see `updatePrecisionWheel`): all off until the player is in
    /// front.
    private var wheelWants = WheelWants(precision: false, freeSpin: true, playerInFront: false, overVideo: false)
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

    init(config: Config, inputMap: InputMap, preferences: PreferencesStore, folderColors: FolderColors, folderSorts: FolderSorts,
         unreadable: UnreadableFiles) {
        self.folderSorts = folderSorts
        self.unreadable = unreadable
        self.preferences = preferences
        let resumeStore = ResumeStore()   // one store: the core keeps the colour the edits write when it saves the position
        core = PlayerCore(config: config, resumeStore: resumeStore)
        core.setViewingVisible(false)
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
        playlistPanel.mode = config.playlistView
        playlistPanel.stripReturn = config.playlistStripReturn
        applyHomeConfig(config)
        window.delegate = self
        core.delegate = self
        buildViews(in: window)
        setUpMouse()
        setUpTourBox()
        statsPanel.fontSize = CGFloat(config.statsFontSize)
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePrecisionWheel() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A `framescrub://open` link: the file (or the Stash scene, found or streamed as for ▶), then its position,
    /// segment and plugin page. A scene's open is asynchronous.
    func open(_ target: OpenLink.Target) {
        guard !isTerminating else { return }
        if let plugin = target.plugin { showLinkPlugin(plugin) }
        switch target.subject {
        case let .file(url):
            open(url, landing: target.landing)
        case let .stashScene(id):
            leaveVirtualCut()
            dropListPlaylist()
            openStashScene(id: id, paths: [], landing: target.landing)
        }
    }

    /// Opens a file from outside the folder (Finder, ⌘O, Recent, a link): closing it goes back to Recent. `landing`:
    /// where a link asked to land in it; `then`: what became of the open.
    /// `homeFolder`: the folder it was opened from in Home (closing goes back there).
    func open(_ url: URL, landing: LinkTarget? = nil, homeFolder: URL? = nil,
              then done: ((OpenOutcome) -> Void)? = nil) {
        guard !isTerminating else { done?(.superseded); return }
        dropListPlaylist()
        returnTab = homeFolder == nil ? .recent : .folders
        folderReturn = homeFolder.map { (folder: $0, file: url) }
        stashScene = nil
        stashOpens += 1   // nor a scene still being looked for
        queueGate.cancel()   // a Stash answer still on its way must not open over this file
        openFile(url, landing: landing, then: done)
    }

    /// What became of an `openFile`: a stream opens a while later, and another open or a close may come first.
    enum OpenOutcome: Equatable { case opened, failed(OpenFailure), superseded }

    /// Counts opens and the closes and failures that replace a file on screen: a stream read in the background opens
    /// only if nothing came after it.
    private var fileOpens = 0
    private var isTerminating = false
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
    /// `stepped`: the direction of the step through the folder that asked for it (‹ ›, autoadvance); a file the decoders
    /// cannot read is then gone past, as a known one is, instead of showing why it did not open.
    private func openFile(_ url: URL, origin: FileOrigin = .plain, fallbackPosition: Double? = nil,
                          landing: LinkTarget? = nil, stepped: Int? = nil,
                          virtualSource: VirtualCutSource? = nil, virtualBounds: Range<Double>? = nil,
                          contextVersion: String? = nil,
                          warmed: PreparedOpen? = nil, then done: ((OpenOutcome) -> Void)? = nil) {
        guard !isTerminating else { warmed?.discard(); done?(.superseded); return }
        gestures.cancelScrubMomentum()
        seekBar.setCutEdges(nil)
        if virtualSource == nil {
            if contextVersion == nil { virtualCutReturn = nil }
            leaveVirtualCut()
        }
        else if isVirtualCutBench { cutBenchOpenStarts += 1 }
        StartupTrace.beginOpen(url.lastPathComponent)
        MetadataInspectionQueue.shared.cancel()
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
        if core.virtualPlaybackBounds == nil { saveThumbnail() }
        dropSceneSearch()
        lastFrame = nil
        videoView.clear(keepingPicture: virtualSource != nil)
        cropSampler?.cancel()
        cropSampler = nil
        if virtualSource == nil { aspectMode = .auto }
        detectedCrop = nil
        resetAutoColor()   // computed for the previous file's picture; the first frame with a picture is analysed
        if virtualSource == nil { rebuildPlaylist(around: url) }   // < and > can skip a broken file
        failedURL = nil
        openedAt = ProcessInfo.processInfo.systemUptime
        indexingShownAt = nil
        // The previous file stops now; the window stays responsive while the file answers.
        closeCore()
        if virtualSource == nil { hideHome() }
        failureView.isHidden = true
        updateViewingVisibility()
        window?.representedURL = nil
        updateTitle(url)
        statsFileChanged()
        openingURL = url
        let cancellation = OpenCancellation()
        openingCancellation = cancellation
        let message = virtualSource != nil ? "Opening fragment…" :
            "Opening \(ByteSources.isRemote(url) ? "the stream" : url.lastPathComponent)…"
        let item = DispatchWorkItem { [weak self] in
            guard let self, openingURL == url, openingMessage == message else { return }
            if !showsHome {
                osd.onClick = nil
                osd.show(message, duration: nil)   // stays until the open ends
            }
        }
        openingMessage = message
        openingMessageItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openingMessageDelay, execute: item)
        let prepare = core.preparation(for: url, cancellation: cancellation, expectedVersion: virtualSource?.version ?? contextVersion)
        let open = fileOpens
        Task { [weak self] in
            // Blocking reads: on a dispatch thread, not the cooperative pool.
            let (result, facts) = await withCheckedContinuation {
                (answer: CheckedContinuation<(Result<PreparedOpen, Error>, URL?), Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try warmed ?? prepare() }
                    answer.resume(returning: (result, Self.warmedFileURL(url, opened: (try? result.get()) != nil)))
                }
            }
            guard let self, open == fileOpens else {
                if virtualSource != nil, self?.isVirtualCutBench == true { self?.cutBenchSuperseded += 1 }
                try? result.get().discard()
                done?(.superseded)
                return
            }
            openingCancellation = nil   // the cache is the player's now
            endOpening()
            switch result {
            case let .success(prepared):
                unreadable.clear(url)
                finishOpen(url, prepared, facts: facts ?? url, fallbackPosition: fallbackPosition, landing: landing,
                           virtualBounds: virtualBounds, virtualIndex: virtualSource.flatMap { virtualCut?.reusedIndex(for: $0) })
                done?(.opened)
            case let .failure(error):
                let failure = OpenFailure(error)
                if virtualSource != nil { done?(.failed(failure)); return }
                if failure.marksUnreadable {
                    let entry = listedEntry(url)
                    unreadable.mark(url, date: entry?.date, size: entry?.size)
                    if let stepped, let next = playlist?.neighbour(stepped, skipping: isUnreadable) {
                        showMessage("\(url.lastPathComponent): skipped", duration: 3)
                        openFile(next, stepped: stepped, then: done)
                        return
                    }
                }
                showFailure(failure, url: url, facts: facts)
                done?(.failed(failure))
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
    private func finishOpen(_ url: URL, _ prepared: PreparedOpen, facts: URL, fallbackPosition: Double?,
                            landing: LinkTarget?, virtualBounds: Range<Double>?, virtualIndex: FrameIndex? = nil) {
        openCore(prepared, fallbackPosition: fallbackPosition, landingTime: landing?.time, virtualBounds: virtualBounds,
                 virtualIndex: virtualIndex)
        core.sceneInfo = pageSceneInfos[url]   // a page's name for it: its frames and clips are named so
        core.frameFolder = pageFrameFolders[url]
        StartupTrace.mark("core opened")
        if virtualBounds == nil, let landing, !landing.isEmpty { core.applyLanding(landing) }   // after fileopened: its segment events follow
        colorFileChanged()   // before anything below reads the colour
        if virtualBounds == nil { hideHome() }
        failureView.isHidden = true
        updateViewingVisibility()
        updatePrecisionWheel()
        // The proxy icon (⌘-click shows the path, drag moves the file) asks the file's volume for its icon and name:
        // 0.1–0.4 s on a NAS when asked cold, behind the file's own reads. `facts` has them from the preparation's
        // thread, but a URL's cached values last only until the main run loop turns: so it is set now, in this pass,
        // with Recent below (1–2 ms instead, measured 2026-10-26). A NAS folder read competes with the file's own
        // reads: it waits for the first picture. A stream has no folder, no file facts and no place in Recent.
        if url.isFileURL, virtualBounds == nil { window?.representedURL = facts }
        videoView.onNextPicture = { [weak self] in
            guard url.isFileURL, virtualBounds == nil else { return }
            self?.readFolder(of: url)
            self?.readFileFacts(of: url)
        }
        if virtualBounds == nil {
            showPlaylistPosition(url, opening: true)
            positionPending = playlist?.totalCount == 1 && folderListing?.folder != folder(of: url) ? url : nil
        } else { positionPending = nil }
        if url.isFileURL, virtualBounds == nil {
            NSDocumentController.shared.noteNewRecentDocumentURL(facts)
            var hidden = HiddenRecent()
            hidden.reveal(url)   // removed from Recent once: opening it again brings it back
        }
        videoView.rotationClockwise = core.info?.rotationClockwise ?? 0
        gestures.scrubber.videoFPS = core.info?.frameRate ?? 30
        updateGeometry(reshapeWindow: false, applyToPicture: virtualBounds == nil)
        if virtualBounds == nil { startCropSampler() }
        videoView.scaleMode = core.config.scaleMode
        videoView.sharpen = core.config.sharpen
        videoView.artifactSettings = core.config.artifactFilters
        updateColorCorrection()
        updateScreenPixelSize()
        configurePreview(force: true)
        // The window keeps its size: the picture fits into it (⌘1–⌘4 and aspect changes still size the window).
        window?.resizeIncrements = NSSize(width: 1, height: 1)   // no aspect left from the previous file
        if virtualBounds == nil {
            hideSeekBarWork?.cancel()
            hideSeekBarWork = nil
            seekBar.setPlaybackControlsVisible(false)
            seekBar.setFilmRevealed(false)
            seekBar.alphaValue = seekBar.showsFilmstrip || seekBar.playbackVisible ? 1 : 0
        }
        updateSeekBar()
        seekBar.refreshVisibility()
        updateSeekBarForPointer()
        statsFileChanged()
        StartupTrace.mark("open returned")
    }

    /// `core.open`, then the page's `fileopened`, then the segment event the open raised, if any (segments given before
    /// the open, or the previous file's leaving): the page hears of the file before anything about its segments.
    private func openCore(_ prepared: PreparedOpen, fallbackPosition: Double?, landingTime: Double? = nil,
                          virtualBounds: Range<Double>? = nil, virtualIndex: FrameIndex? = nil) {
        guard !isTerminating else { prepared.discard(); return }
        resetPluginAnalysisSource()
        holdsSegmentEvents = true
        heldSegmentEvent = nil
        core.open(prepared, fallbackPosition: fallbackPosition, landingTime: landingTime,
                  virtualBounds: virtualBounds, virtualIndex: virtualIndex)
        holdsSegmentEvents = false
        if virtualBounds == nil {
            if core.url?.isFileURL == true { pluginAnalysisSourceID = UUID().uuidString }
            pluginFileOpened()
        }
        if let held = heldSegmentEvent {
            heldSegmentEvent = nil
            dispatchToPages(held)
            pushPluginState(force: true)
        } else if virtualBounds == nil {
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
        lastFrame = nil
        videoView.clear(blank: true)
        failedURL = url
        var failure = failure
        if case .stash = origin, failure.kind == .notFound, let path = stashScene?.paths.first {
            failure = OpenFailure(reason: "File not found", detail: path)
        }
        showFailureMessage(failure, name: url.lastPathComponent)
        hideHome()
        failureView.isHidden = false
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
        guard hasOpenFile || virtualCut != nil else { window?.performClose(nil); return }
        gestures.cancelScrubMomentum()
        rememberVirtualCut()
        defer { leaveVirtualCut() }
        abandonOpening()
        folderWait.cancel()
        recentThumbnailer.cancel()
        saveThumbnail(wait: true)   // the start screen shows it next
        cancelStashTitleWait()
        stashSession?.leave()
        dropSceneSearch()
        closeCore()   // keeps the position for the next open
        lastFrame = nil
        videoView.clear(blank: true)
        hideSeekBarWork?.cancel()
        hideSeekBarWork = nil
        seekBar.alphaValue = 0
        showBackButton(false, duration: 0)
        failedURL = nil
        failedScene = nil
        deletingScene = false   // a delete still running finishes without opening anything
        queueGate.cancel()
        origin = .plain
        showHome(tab: virtualCut == nil ? returnTab : nil)
    }

    private var failureHint: String? { returnTab == .stash ? "⌘W — back to Stash" : nil }

    /// Why a file did not open, in place of the recent files.
    private func showFailureMessage(_ failure: OpenFailure, name: String) {
        let keys = ["Return — try again", "PgUp / PgDn — another file in the folder", "⌘O — open"]
            + (failureHint.map { [$0] } ?? [])
        failureView.show(title: "Cannot open \(name)", reason: failure.reason, detail: failure.detail, hints: keys)
    }

    private func applyHomeConfig(_ config: Config) {
        guard let home else { return }
        home.browser.cardSize = CGFloat(config.homeCardSize)
        if home.isSidebarVisible != config.homeSidebar { home.isSidebarVisible = config.homeSidebar }
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
        guard !isTerminating else { return }
        if scene.automatic {
            // Stash also opens a page with autoplay=true on a reload: only a step of ours is answered.
            guard queueGate.isPending else { return }
            queueGate.answered()
        }
        virtualCutReturn = nil
        leaveVirtualCut()
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
        lastFrame = nil
        videoView.clear(blank: true)
        failedURL = nil
        failedScene = scene
        origin = .stash(sceneID: scene.id, hasQueue: scene.hasQueue)
        let name = scene.paths.first.map { $0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? $0 }
        showFailureMessage(failure, name: name ?? "Stash scene \(scene.id)")
        hideHome()
        failureView.isHidden = false
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
        if let cut = virtualCut {
            if !showsHome { window?.title = cut.cut.title + " — Virtual Cut" }
            return
        }
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

    /// Home (Home spec, Window): Recent or the Stash library (`tab`, else `home-tab`; Stash only with `stash-url`) in
    /// place of the video. A file on screen is paused and stays open, so ⌘[ / Esc come back to it at once; with none,
    /// the window is the start screen. Home is made the first time and only hidden after that.
    func showHome(tab: HomeTab? = nil) {
        guard let window else { return }
        seekBar.cancelCutEdgeGesture()
        slots.isEnabled = false
        virtualCut?.playback.wantsPlayback = false
        virtualCut?.waitingForFirstPicture = false
        virtualCut?.scrubOpen?.cancel()
        virtualCut?.scrubOpen = nil
        virtualCut?.stopWarming()
        rememberVirtualCut()
        cancelTourBoxInput()
        homeButtons.cancelAll()
        core.setViewingVisible(false)
        let cpu = StartupTrace.threadCPU(), wall = Date(), first = home == nil
        let view = home ?? makeHome()
        cancelStashTitleWait()
        if core.url != nil {
            if !core.isPaused { core.pause() }
            if homeHost.isHidden {   // Recent's card for it shows where it is now
                core.rememberPosition()
                saveThumbnail()
            }
        }
        if homeHost.isHidden { titleBeforeHome = window.title }
        failedURL = nil
        failedScene = nil
        failureView.isHidden = true
        homeHost.isHidden = false
        view.isParked = false
        // Home's toolbar lies over its content (the browser insets its grid by the toolbar's height), as in Loupe.
        keepingFrame(of: window) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.toolbar = view.browser.nsToolbar
            window.titleVisibility = .hidden
        }
        hideSeekBarWork?.cancel()
        hideSeekBarWork = nil
        seekBar.alphaValue = 0
        showBackButton(false, duration: 0)
        osd.hide()   // the player's messages and icons were about the video, now behind Home
        hud.hide()
        applyHomeConfig(core.config)
        let config = core.config
        // A video opened from a folder goes back to that folder with it (or the file playing after it) selected.
        let back = core.url.flatMap { $0.isFileURL ? (folder: folder(of: $0), file: $0) : nil } ?? folderReturn
        let wanted = tab ?? (folderReturn != nil && core.url != nil ? .folders : config.homeTab)
        let shown = HomeRecent.shownTab(wanted, stashEnabled: config.stashEnabled)
        var selecting: String?
        let location: BrowserLocation
        if tab == nil, let cut = virtualCutCatalogLocation, virtualCut != nil {
            location = .source(cut.source)
            selecting = cut.card
        } else if let place = HomeRecent.location(of: shown) {
            location = place
        } else if let back {
            location = .folder(back.folder)
            selecting = back.file.path
        } else {
            location = view.browser.lastBrowsed
        }
        if shown == .folders, let selecting { view.browser.lastOpenedID = selecting }
        if view.browser.location == location, hasShownHome, selecting == nil {
            view.browser.reload()
        } else {
            view.browser.show(location, selecting: selecting)
        }
        hasShownHome = true
        homeSource?.setWatchingVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        updatePrecisionWheel()
        if core.url == nil {
            videoView.onNextPicture = nil
            statsFileChanged()
            window.representedURL = nil
            applyStartScreenFrame()
        }
        if shown == .stash { stashLibrary?.focusPage() } else { window.makeFirstResponder(view.browser) }
        if StartupTrace.enabled {   // the bench: the layout and drawing this pass would leave to the run loop, counted here
            window.layoutIfNeeded()
            window.displayIfNeeded()
            StartupTrace.cost(first ? "home shown (first)" : "home shown", cpu: cpu, wall: wall)
        }
    }

    /// Back to the video (or to the reason a file failed): Home stays in the window, hidden and parked.
    func hideHome() {
        guard let home, !homeHost.isHidden else { return }
        catalogOpen?.cancel()
        homeButtons.cancelAll()
        let cpu = StartupTrace.threadCPU(), wall = Date()
        homeHost.isHidden = true
        slots.isEnabled = true
        home.isParked = true
        homeSource?.stopImages()
        if let window {
            keepingFrame(of: window) {
                window.toolbar = nil
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                if !isFullScreen { window.styleMask.remove(.fullSizeContentView) }
            }
        }
        if let titleBeforeHome { window?.title = titleBeforeHome }
        titleBeforeHome = nil
        updateViewingVisibility()
        window?.makeFirstResponder(videoView)
        updatePrecisionWheel()
        if StartupTrace.enabled, let window {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            StartupTrace.cost("home hidden", cpu: cpu, wall: wall)
        }
        flushVirtualScrubOpen()
    }

    /// Home is in the window (Recent or Stash), not the video or why a file failed.
    var showsHome: Bool { !homeHost.isHidden }

    /// ⌘[ (the physical [ key, whatever the layout), Home's way back and forward's opposite.
    private static func isGoBack(_ event: NSEvent) -> Bool {
        event.keyCode == 33 && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }

    /// Esc on Home with a file open: back to it, paused where it was.
    private func returnFromHome() -> Bool {
        guard showsHome, core.url != nil, virtualCut?.waitingForFirstPicture != true else { return false }
        hideHome()
        return true
    }

    private func makeHome() -> HomeView {
        let source = FrameScrubHomeSource(
            folderSorts: folderSorts, defaultSort: { [weak self] in self?.core.config.playlistSort.defaultSort ?? .standard },
            recentURLs: { [weak self] in
                RecentFiles.shown(NSDocumentController.shared.recentDocumentURLs, hidden: HiddenRecent().paths,
                                  limit: self?.core.config.recentCount ?? 50)
            },
            thumbnails: thumbnails, thumbnailer: recentThumbnailer,
            stashPage: { [weak self] in self?.makeStashLibrary() },
            hasStash: { [weak self] in self?.core.config.stashEnabled ?? false }, unreadable: unreadable)
        let view = HomeView(source: source)
        source.catalogs = Dictionary(uniqueKeysWithValues: pluginCatalogs.values.map { ($0.locationID, $0) })
        source.onCut = { [weak self] in self?.chooseCatalogCut($0, id: $1, edit: $2) }
        source.onCatalogNavigation = { [weak self] in self?.catalogOpen?.cancel() }
        source.view = view.browser
        view.browser.unreadable = unreadable
        source.onOpen = { [weak self] url, location, sort in   // not looked up: a share answers over the network
            guard let self else { return }
            if case .folder(let folder) = location {
                self.open(url, homeFolder: folder)   // the playlist in the grid's order: the folder's own (FolderSorts)
            } else {
                self.open(url)
            }
        }
        source.onMenu = { [weak self] url, item in self?.recentMenuChosen(url, item) }
        view.translatesAutoresizingMaskIntoConstraints = false
        homeHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: homeHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: homeHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: homeHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: homeHost.bottomAnchor),
        ])
        let browser = view.browser
        browser.files = .videos   // 16:9 slots, "videos" in the counts, the length and progress on each picture
        // Square (posters fill their 16:9 slot, cropped) or Aspect (whole, fitted), and the names (⌥T, ⌥N and the
        // toolbar's button): the user's last choice, kept across launches.
        let defaults = UserDefaults.standard
        browser.style = defaults.string(forKey: "homeGridStyle").flatMap(GridStyle.init) ?? .aspect
        browser.names = defaults.string(forKey: "homeGridNames").flatMap(GridNames.init) ?? .auto
        browser.onStyle = { [weak browser] style in
            browser?.style = style
            defaults.set(style.rawValue, forKey: "homeGridStyle")
        }
        browser.onNames = { [weak browser] names in
            browser?.names = names
            defaults.set(names.rawValue, forKey: "homeGridNames")
        }
        // The sidebar's width as the user left it (a drag of its divider), kept across launches.
        let width = defaults.double(forKey: "homeSidebarWidth")
        if width > 0 { view.sidebarWidth = CGFloat(width) }
        view.onSidebarWidthChange = { width in defaults.set(Double(width.rounded()), forKey: "homeSidebarWidth") }
        browser.cardSizeRange = 60...480   // home-card-size's
        browser.onWindowText = { [weak self] title, _ in
            guard let self, self.showsHome else { return }
            self.window?.title = title
        }
        browser.onResize = { [weak self] in self?.resizeHomeCards($0) }
        browser.onOtherMouse = { [weak self] event, down in
            guard let self, event.buttonNumber == 3 || event.buttonNumber == 4,
                  let button = MouseButton(appKitButtonNumber: event.buttonNumber) else { return false }
            if down {
                homeButtons.appKitDown(button, keys: [], rightHeld: false, at: event.timestamp)
            } else {
                homeButtons.appKitUp(button, at: event.timestamp)
            }
            return true
        }
        view.onSidebarToggle = { [weak self] in self?.toggleHomeSidebar() }
        view.onDrop = { [weak self] url in self?.open(url) }
        // Esc on Home goes back to the open video, unless a field is being typed in (the filter, a rename): the browser
        // and the window keep Esc to themselves, so it is taken here first.
        homeKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  !(self.window?.firstResponder is NSText) else { return event }
            if event.keyCode == 53, self.returnFromHome() { return nil }
            // Home's card view owns first responder, so its unhandled keys do not
            // reach VideoView. Route this window-settings command explicitly;
            // keep navigation, text entry and playback commands with Home.
            guard self.showsHome,
                  let chord = KeyChord.fromKeyEvent(keyCode: event.keyCode,
                      characters: KeyboardLayout.characters(for: event), modifiers: Modifiers(event.modifierFlags)),
                  self.inputMap.command(for: chord) == .toggleSubjectFocusPanel else { return event }
            if !event.isARepeat { self.runInput(.toggleSubjectFocusPanel, from: .keyboard) }
            return nil
        }
        home = view
        homeSource = source
        return view
    }

    /// ⌃⌘S: Home's sidebar shown or hidden, saved as `home-sidebar`.
    func toggleHomeSidebar() {
        guard showsHome else { return }
        let shown = !core.config.homeSidebar
        do { try preferences.update(["home-sidebar"]) { $0.homeSidebar = shown } } catch {
            showMessage("Cannot save settings: \(error)", duration: 4)
        }
    }

    var canRefreshHome: Bool { showsHome && home?.browser.location != .source(HomeRecent.stash) }
    func refreshHome() {
        guard canRefreshHome else { return }
        homeSource?.refresh()
    }

    /// File › Copy Path (⌥⌘C, as Finder's Copy as Pathname), and Recent's Copy Path.
    func copyPath(of url: URL? = nil) {
        guard let url = url ?? core.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showMessage("Path copied")
    }

    /// The file on screen, for Copy Path.
    var currentURL: URL? { core.url }

    /// The card size on Home (`HomeResize`: ⌘= / ⌘− and the toolbar's − + by four sizes, ⌘ + wheel and a pinch by a
    /// column, the toolbar's slider, ⌘0 the default), saved as `home-card-size`.
    func resizeHomeCards(_ resize: HomeResize) {
        guard let browser = home?.browser, showsHome else { return }
        let size = browser.cardSize(after: resize, range: 60...480).map(Double.init) ?? Config().homeCardSize
        do { try preferences.update(["home-card-size"]) { $0.homeCardSize = size } } catch {
            showMessage("Cannot save settings: \(error)", duration: 4)
        }
    }

    private func recentMenuChosen(_ url: URL, _ item: String) {
        switch item {
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([url])
        case "copy":
            copyPath(of: url)
            home?.browser.showToast("Path copied")
        case "remove":
            var hidden = HiddenRecent()
            hidden.hide(url)
            home?.browser.reload()
        default: break
        }
    }

    /// The Stash WebUI, Home's Stash page (the browser puts it under its toolbar), made the first time it is shown or
    /// a queue is stepped; nil without `stash-url`.
    private func makeStashLibrary() -> StashLibraryView? {
        if let stashLibrary { return stashLibrary }
        guard let url = URL(string: core.config.stashURL), core.config.stashEnabled else { return nil }
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

    /// Lists Recent again after it changed (Clear Menu) while Home shows it.
    func recentChanged() {
        if showsHome, home?.browser.location == HomeRecent.location(of: .recent) { home?.browser.reload() }
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
        guard let url = core.url, let image = videoView.displayedImage, let identity = core.sourceIdentity else { return }
        let picture = videoView.geometry.applied(to: image)
        let thumbnails = thumbnails, context = Self.thumbnailContext
        let work: @Sendable () -> Void = { thumbnails.save(picture, for: url, context: context, identity: identity) }
        if wait { thumbnailQueue.sync(execute: work) } else { thumbnailQueue.async(execute: work) }
    }
    private let thumbnailQueue = DispatchQueue(label: "framescrub.thumbnail-save", qos: .utility)

    /// Freeze the last observed view/position before the async quit barrier. Cache data is disposable;
    /// user state must reach its worker before applicationWillTerminate can exit the process.
    func prepareUserStateForTermination() async {
        isTerminating = true
        core.setViewingVisible(false)
        stashOpens += 1
        queueGate.cancel()
        folderWait.cancel()
        abandonOpening()
        core.pause()
        saveThumbnail()
        rememberVirtualCut()
        let finishSession = stashSession?.prepareTerminationFlush()
        resetPluginAnalysisSource()
        core.close()
        await finishSession?()
        await core.flushUserState()
    }

    /// Stops rendering and shuts the core down (cancels export, filler threads, audio).
    func shutdown() {
        seekBar.cancelFilmScroll()
        tourBoxBridge.stop()
        abandonOpening()   // a stream answering later must not open in a closed window
        stashSession?.flushBeforeQuit()
        for write in slotWrites.values where write.isValid { write.fire() }   // a slot changed just before quitting
        slotWrites = [:]
        homeSource?.stopImages()
        recentThumbnailer.cancel()
        saveThumbnail(wait: true)
        cancelMouseInput()   // and the button timer; the mouse itself is released at termination (`LogiMouse.follow`)
        statsTimer?.invalidate()
        statsTimer = nil
        filmstripLoader?.stop()
        filmstripLoader = nil
        previewProvider?.stop()
        previewProvider = nil
        cropSampler?.cancel()
        dropSceneSearch()
        videoView.stop()
        resetPluginAnalysisSource()
        core.close()
    }

    /// Leaves the file (its position is kept for the next open); framescrub.conf's colour applies again.
    private func closeCore() {
        cancelTourBoxInput()
        filmstripLoader?.stop()
        filmstripLoader = nil
        if virtualCut == nil { seekBar.resetFilmstrip() }
        resetPluginAnalysisSource()
        core.close()
        pushPluginState(force: true)
        colorFileChanged()
    }

    /// A file opened or closed: the player gets framescrub.conf with the file's and its folders' colour over it.
    /// The views follow in the caller (`openFile`: `updateColorCorrection`); with no file nothing is drawn.
    private func colorFileChanged() {
        colorMemory.open(core.url, size: core.readCache?.fileSize)
        core.apply(effectiveConfig())
        SettingsPanel.refreshFolderOverrides()
    }

    /// The open video's own colour values and its folders', for the settings window's notes; nil without a video.
    func colorSnapshot() -> ColorLayerSnapshot? { colorMemory.snapshot() }

    /// The settings window's «Use Default» on a colour row: `level` drops `key`, the picture redraws.
    func clearColor(_ key: String, on level: ColorLayerHit.Level) {
        colorMemory.clear(key, on: level)
        applyEffectiveConfig()
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
        defer { SettingsPanel.refreshFolderOverrides() }   // a colour command may have set or dropped a level
        let config = effectiveConfig()
        let sortChanged = config.playlistSort != core.config.playlistSort
        let stashChanged = config.stashURL != core.config.stashURL || config.stashAPIKey != core.config.stashAPIKey
            || config.stashPathMap != core.config.stashPathMap || config.stashStream != core.config.stashStream
        // The scene search's decoder follows `hwdec` too: the next press makes a new one.
        if config.hwdec != core.config.hwdec { dropSceneSearch() }
        applyPluginConfig(config, previous: core.config)
        if config.mouseProfile != core.config.mouseProfile || config.tourBoxFramesPerPulse != core.config.tourBoxFramesPerPulse
            || config.tourBoxAccelerationStart != core.config.tourBoxAccelerationStart {
            cancelTourBoxInput()
        }
        core.apply(config)
        updateTourBox()
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
        videoView.scaleMode = config.scaleMode
        videoView.sharpen = config.sharpen
        videoView.artifactSettings = config.artifactFilters
        artifactFilterPanel?.refresh()
        refreshLowLatency()
        if !config.autoColor, autoColorFrame != nil || autoColorSeconds != nil { resetAutoColor() }
        updateColorCorrection()   // a new threshold re-decides from the stored Δ
        if config.autoColor, let lastFrame { checkSceneCut(lastFrame) }   // turned on in Settings: a first frame is a cut
        window?.level = config.ontop ? .floating : .normal
        playlistPanel.fontSize = CGFloat(config.playlistFontSize)
        playlistPanel.mode = config.playlistView
        playlistPanel.stripReturn = config.playlistStripReturn
        applyHomeConfig(config)
        if stashChanged, let library = stashLibrary {   // a new address, key or rules: a new page and session
            stashSession?.leave()
            library.removeFromSuperview()
            stashLibrary = nil
            stashSession = nil
        }
        if stashChanged {
            home?.reloadSidebar()   // Stash's row comes or goes
            if showsHome, home?.browser.location == HomeRecent.location(of: .stash) { showHome() }
        }
        statsPanel.fontSize = CGFloat(config.statsFontSize)
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
        // Over Home the OSD's corner is the toolbar's: Home's own toast says it, above its status line.
        if showsHome, let browser = home?.browser {
            browser.showToast(text, for: max(duration, 3))
            return
        }
        // Only the player's "Saved…" OSD is clickable; any other message must not keep its handler.
        osd.onClick = nil
        placeTopOverlays()
        osd.show(text, duration: duration)
    }

    // MARK: Layout

    private func buildViews(in window: NSWindow) {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container
        for view in [videoView, homeHost, failureView, hud, osd, seekBar, backButton, previewView, keyHelp, goToField] as [NSView] {
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
            homeHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            homeHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            homeHost.topAnchor.constraint(equalTo: container.topAnchor),
            homeHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            failureView.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            failureView.topAnchor.constraint(equalTo: videoView.topAnchor),
            failureView.bottomAnchor.constraint(equalTo: videoView.bottomAnchor),
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
            seekBar.bottomAnchor.constraint(equalTo: visibleArea.bottomAnchor, constant: -8),
            { let constraint = seekBar.heightAnchor.constraint(equalToConstant: seekBar.preferredHeight)
                seekBarHeight = constraint; return constraint }(),
            backButton.leadingAnchor.constraint(equalTo: visibleArea.leadingAnchor, constant: 16),
            previewView.bottomAnchor.constraint(equalTo: seekBar.topAnchor, constant: -6),
        ])
        previewLeading = previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16)
        previewLeading.isActive = true
        backButtonTop = backButton.topAnchor.constraint(equalTo: visibleArea.topAnchor, constant: 16)
        backButtonTop.isActive = true
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
            self?.updateSeekBarForPointer()
        }
        let transport = seekBar.transport
        transport.onPlay = { [weak self] in self?.runFromSeekBar(.cyclePause) }
        transport.onBack = { [weak self] in self?.runFromSeekBar(.seek(-10, .byConfig)) }
        transport.onForward = { [weak self] in self?.runFromSeekBar(.seek(10, .byConfig)) }
        transport.onSpeed = { [weak self] in self?.runFromSeekBar(.setSpeed($0)) }
        transport.onFullscreen = { [weak self] in self?.runFromSeekBar(.cycleFullscreen) }
        seekBar.onHeightChange = { [weak self] height in
            guard let self, seekBarHeight.constant != height else { return }
            seekBarHeight.constant = height
        }
        seekBar.onFilmstripRequest = { [weak self] times in self?.requestFilmstrip(times) }
        seekBar.onEditFragment = { [weak self] span in self?.selectVirtualCutFragment(span) }
        seekBar.onAnalysisFragment = { [weak self] fragment in
            guard let self, let owner = pluginAnalysisOwner, virtualCut == nil, !showsHome,
                  let page = slots.page(withToken: owner.page), isConfiguredAnalysisPage(page, origin: owner.origin) else { return }
            page.dispatch(.analysisFragment(id: fragment.id, refined: fragment.refined, start: fragment.range.lowerBound))
        }
        seekBar.onCutEdgePreview = { [weak self] frame in
            guard let self, virtualCutReturn?.originalReady == true, !showsHome else { return }
            if self.window?.firstResponder !== videoView { self.window?.makeFirstResponder(videoView) }
            if !core.isPaused { core.pause() }
            core.seek(toFrame: frame)
        }
        seekBar.onCutEdgeCommit = { [weak self] edges, edge, frame, time in
            guard let self, let context = virtualCutReturn, context.originalReady, !showsHome,
                  let catalog = catalogForCut(context.catalog.source),
                  let page = slots.page(withToken: catalog.page) else { return }
            page.dispatch(.cutEdgeCommit(rangeID: edges.rangeID, edge: edge, frame: frame, time: time))
        }
        seekBar.onFilmstripFold = { [weak self] in
            self?.videoView.cancelFilmSeekPreview()
            self?.prewarmFilmstrip()
        }
        seekBar.onFilmPress = { [weak self] in
            self?.gestures.cancelScrubMomentum()
            self?.videoView.cancelFilmSeekPreview()
        }
        seekBar.onMarkDragBegin = { [weak self] handle in
            guard let self, virtualCut == nil else { return false }
            if tourBoxEditsEdge { cancelTourBoxInput() }
            core.cancelEdgeDrag()
            edgeDragSuppressed = edgeDragOwner
            edgeDragOwner = nil
            positionWillMove()
            guard core.beginMarkEdgeDrag(handle) else { return false }
            markReferenceGeneration += 1
            if let frame = core.cache.frame(handle.frame), let info = core.info {
                markReferenceWorker.submit((frame, info.rotationClockwise, markReferenceGeneration))
            }
            return true
        }
        seekBar.onMarkDragMove = { [weak self] seconds in
            guard let self, let index = core.index else { return }
            core.moveMarkEdge(toFrame: index.frameNumber(forSeconds: seconds))
        }
        seekBar.onMarkDragEnd = { [weak self] commit in
            guard let self else { return }
            markReferenceGeneration += 1
            if commit { core.endEdgeDrag() } else { core.cancelEdgeDrag() }
        }
        seekBar.onFilmScrubBegan = { [weak self] in
            self?.virtualCut?.playback.wantsPlayback = false
            self?.core.pause()
        }
        seekBar.onScrubEnded = { [weak self] in self?.flushVirtualScrubOpen() }
        seekBar.onFilmSeek = { [weak self] seconds in self?.seekFilm(to: seconds, previewsFrames: false) }
        seekBar.onFilmDrag = { [weak self] seconds in self?.seekFilm(to: seconds, previewsFrames: false, dragging: true) }
        seekBar.onFilmCoast = { [weak self] seconds in
            guard let self, virtualCut == nil, let index = core.index else { return false }
            return core.coastFilm(toFrame: index.frameNumber(forSeconds: seconds))
        }
        seekBar.onFilmClickPreview = { [weak self] seconds in self?.seekFilm(to: seconds, previewsFrames: true) }
        transport.onToggleMute = { [weak self] in self?.runFromSeekBar(.cycleMute) }
        transport.onVolume = { [weak self] in
            self?.core.setVolume($0)
            self?.revealSeekBar()
        }
        core.onIndexReady = { [weak self] in
            if let cut = self?.virtualCut, let source = cut.loadedSource { cut.rememberIndex($0, for: source) }
            self?.previewProvider?.updateIndex($0)
            self?.filmstripLoader?.updateIndex($0)
            self?.pluginGrabber?.updateIndex($0)
            self?.sceneSearch?.updateIndex($0)
            self?.prewarmFilmstrip()
            self?.retryVirtualPictureWithExactIndex($0)
        }
        core.onIndexProgress = { [weak self] in self?.showIndexing($0) }
        seekBar.alphaValue = 0
        backButton.alphaValue = 0
        backButton.onClick = { [weak self] in self?.closeFile() }
        homeHost.isHidden = true   // shown by showHome() when the app starts with nothing to open
        failureView.isHidden = true
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
            if virtualCut != nil {
                guard case let .seconds(seconds) = target else { return false }
                return seekVirtualCut(to: seconds)
            }
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
        videoView.onScrollGestureReset = { [weak self] in self?.gestures.resetScroll() }
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
        videoView.onLeftClick = { [weak self] in
            self?.slots.hideOverlays()
        }
        videoView.zoomAllowed = { [weak self] in self.map { !$0.showsHome && $0.core.info != nil } ?? false }
        videoView.onOtherButton = { [weak self] button, keys, rightHeld, time in
            self?.buttons.appKitDown(button, keys: keys, rightHeld: rightHeld, at: time)
        }
        videoView.onOtherButtonUp = { [weak self] button, time in self?.buttons.appKitUp(button, at: time) }
        videoView.onMouseMoved = { [weak self] in
            self?.showCursorAfterScrub()
            self?.updateSeekBarForPointer()
            self?.updatePrecisionWheel()
        }
        videoView.onEnterExit = { [weak self] in
            self?.showCursorAfterScrub()
            self?.updateSeekBarForPointer()
            self?.updatePrecisionWheel()
        }
        videoView.onOpenFile = { [weak self] in self?.open($0) }
        videoView.onDisplayRatioChange = { [weak self] in self?.refreshLowLatency() }
        core.onVirtualPlaybackBoundary = { [weak self] direction in
            guard let self else { return }
            if let cut = virtualCut, cut.awaitingPicture != nil, cut.retryPictureAfterIndex != nil {
                return // the core is paused; a missing estimate must not skip the whole fragment
            }
            if isVirtualCutBench {
                virtualCutBenchBoundary = ProcessInfo.processInfo.systemUptime
                if let active = virtualCut?.playback.activeSpan, seekBar.hasCutPoster(active + direction) {
                    cutBenchEarlyPosters.insert(active + direction)
                }
            }
            advanceVirtualCut(direction)
        }
        core.onVirtualPictureUnavailable = { [weak self] in
            guard let self, let cut = virtualCut, let request = cut.awaitingPicture else { return }
            if core.index?.isExact == false, core.indexStatus != .failed {
                let firstMiss = cut.retryPictureAfterIndex == nil
                cut.retryPictureAfterIndex = request
                if firstMiss && core.isPaused, let index = core.index, let bounds = core.virtualPlaybackBounds {
                    let next = core.position + core.direction
                    if next >= index.frameNumber(forSeconds: bounds.lowerBound),
                       next <= index.frameNumber(before: bounds.upperBound) {
                        core.seek(toFrame: next)
                    }
                }
                if firstMiss && isVirtualCutBench { print("virtual-cut: retrying first picture while approximate") }
                return
            }
            if isVirtualCutBench {
                print("virtual-cut: decode focus unavailable frame=\(core.position) exact=\(core.index?.isExact == true)")
            }
            failVirtualCutMove(cut, request, reason: "The first frame could not be decoded.")
        }
        core.onDisplayReferencesChange = { [weak self] in self?.refreshLowLatency() }
        videoView.effectClock = { [weak self] in self?.core.clock.seconds ?? 0 }
        videoView.onTick = { [weak self] in self?.core.tick() }
        seekBar.onSeek = { [weak self] fraction in
            guard let self else { return }
            if let session = virtualCut {
                _ = seekVirtualCut(to: fraction * session.playback.timeline.duration,
                                   continuous: seekBar.isContinuousSeek)
                revealSeekBar()
                return
            }
            if core.segments != nil {
                core.seek(toSeconds: fraction * core.durationSeconds)
                revealSeekBar()
                return
            }
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
    private func updateGeometry(reshapeWindow: Bool, applyToPicture: Bool = true) {
        guard let info = core.info, let upright = uprightVideoSize else { return }
        let geometry = DisplayGeometry.resolve(mode: aspectMode, upright: upright, rotationClockwise: info.rotationClockwise,
                                               sampleAspect: info.sampleAspect, detectedCrop: detectedCrop)
        let changed = geometry.displaySize(of: upright) != videoView.geometry.displaySize(of: upright)
        if applyToPicture { videoView.geometry = geometry }
        core.displayGeometry = geometry
        // Automatic crop detection can finish while paused, with no subsequent position update.
        updateSeekBar()
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
                // The window keeps its size, as on open: bars found later only change how the picture fits into it.
                if self.aspectMode == .auto { self.updateGeometry(reshapeWindow: false) }
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
    static let wheelFreeSpinKey = FrameScrubSettingsStore.wheelFreeSpinDefaultsKey

    private static var savedFrame: CGRect? { frame(forKey: frameKey) }

    private static func frame(forKey key: String) -> CGRect? {
        if let frame = UserDefaults.standard.string(forKey: key).map(NSRectFromString), frame.width > 0, frame.height > 0 {
            return frame
        }
        return nil
    }

    /// Home's toolbar put on or taken off with the frame kept: AppKit takes the toolbar's 32 pt from the top of a
    /// full-size-content window when it gets one (and gives them back without it), so a window filling the screen
    /// opened 32 pt below the menu bar and the frame saved over Home kept that.
    private func keepingFrame(of window: NSWindow, _ change: () -> Void) {
        let frame = window.frame
        change()
        if !isFullScreen, window.frame != frame { window.setFrame(frame, display: false) }
    }

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
        if event.keyCode == 53, seekBar.cancelCutEdgeGesture() { return }
        if event.keyCode == 53, core.edgeDrag != nil {   // Esc cancels a live edge drag, and only that
            edgeDragSuppressed = edgeDragOwner
            cancelEdgeDrag()
            return
        }
        if keyHelp.isShown, event.keyCode == 53 { keyHelp.hide(); return }   // Esc closes the cheat sheet first
        if let session = virtualCut, session.playback.failure != nil,
           event.keyCode == 36 || event.keyCode == 76 {
            if let request = session.playback.retry() {
                osd.hide()
                moveVirtualCut(session, request)
            }
            return
        }
        if let failedURL, event.keyCode == 36 || event.keyCode == 76 { openFile(failedURL, origin: origin); return }   // Return / Enter: try again
        if let failedScene, event.keyCode == 36 || event.keyCode == 76 { openStashScene(failedScene); return }
        if showsHome {
            if event.keyCode == 53, returnFromHome() { return }   // Esc: back to the video
            if home?.browser.handleKey(event) == true { return }   // arrows, Return, typing a name: Home's cards
        } else if Self.isGoBack(event), core.url != nil {
            showHome()   // ⌘[ on a video: Home over it
            return
        }
        guard let chord = KeyChord.fromKeyEvent(keyCode: event.keyCode,
                                                characters: KeyboardLayout.characters(for: event),
                                                modifiers: Modifiers(event.modifierFlags)),
              let command = inputMap.command(for: chord) else { return }
        if event.isARepeat && !command.repeatsWhenHeld { return }   // holding p must not flicker pause
        if command == .holdSpeed {
            guard holdKeyCode == nil, !tourBoxHoldsSpeed, stillDown, !showsHome else { return }
            gestures.cancelScrubMomentum()
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
        if showsHome, !command.worksWithoutPlayer { return }   // the video behind Home is paused and stays so
        gestures.cancelScrubMomentum()
        videoView.cancelFilmSeekPreview()
        seekBar.cancelFilmDragMotion()
        seekBar.cancelMarkDrag()
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
        if runVirtualCutCommand(command) { return }
        sceneFrameOSDToDrop = nil
        if Self.movesPosition(command) { seekBar.cancelFilmScroll(); cancelSceneSearch() }
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
        case let .zoom(step):
            // ⌘+scroll zooms about the pointer, a key about the middle.
            if videoView.zoomAllowed() { videoView.zoom(by: step ?? 0.25, atPointer: NSApp.currentEvent?.type == .scrollWheel) }
        case .zoomReset:
            videoView.zoomToFit()
        case .revealFrames:
            revealFrames()
        case .showInFolder:
            showInFolder()
        case .showKeys:
            if keyHelp.isShown { keyHelp.hide() } else { keyHelp.show(inputMap, pluginActions: shownPluginActions) }
        case .goTo:
            guard core.index != nil else { showMessage("No video open"); return }
            goToField.open(with: FrameNaming.timecode(virtualCut?.playback.position ?? core.currentSeconds))
        case .cycleMouseProfile:
            switchMouseProfile()
        case .toggleArtifactFilters:
            do { try preferences.update(["artifact-enabled"]) { $0.artifactFilters.enabled.toggle() } }
            catch { showMessage("Cannot save settings: \(error)", duration: 4) }
            showMessage(preferences.config.artifactFilters.summary)
        case .toggleArtifactFilterPanel:
            slots.toggleArtifactFilterPanel()
        case .toggleUpscaler:
            do { try preferences.update(["ll-sr"]) { $0.lowLatency.scale = $0.lowLatency.scale == .off ? .auto : .off } }
            catch { showMessage("Cannot save settings: \(error)", duration: 4) }
            showMessage("Apple LL SR: \(preferences.config.lowLatency.scale.rawValue)")
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
        case .toggleSubjectFocus:
            setSubjectFocus(videoView.subjectFocus == nil ? Self.subjectFocusStyle : nil)
        case .cycleSubjectFocus:
            let settings = SubjectFocusSettings.shared
            setSubjectFocus(settings.select(settings.next(after: videoView.subjectFocus ?? Self.subjectFocusStyle)))
        case .toggleSubjectFocusPanel:
            slots.toggleSubjectFocusPanel()
        case .cycleUpscaler:
            let choices = LLScaleChoice.allCases
            let current = choices.firstIndex(of: core.config.lowLatency.scale) ?? 0
            do { try preferences.update(["ll-sr"]) { $0.lowLatency.scale = choices[(current + 1) % choices.count] } }
            catch { showMessage("Cannot save settings: \(error)", duration: 4) }
            showMessage("Apple LL SR: \(preferences.config.lowLatency.scale.rawValue)")
        case .deleteFile:
            deleteCurrentFile()
        case .closeFile:
            closeFile()
        case .cyclePlaylistSort:
            setPlaylistSort((playlistAnchor.flatMap { PlaylistSort(rawValue: folderSort(folder(of: $0)).key.rawValue) } ?? core.config.playlistSort).next)
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
    private func positionWillMove(keepingFilmScroll: Bool = false, keepingTrackpadScrub: Bool = false) {
        videoView.cancelFilmSeekPreview()
        if !keepingFilmScroll { seekBar.cancelFilmScroll() }
        if !keepingTrackpadScrub { gestures.cancelScrubMomentum() }
        sceneFrameOSDToDrop = nil
        cancelSceneSearch()
    }

    private func seekFilm(to seconds: Double, previewsFrames: Bool, dragging: Bool = false) {
        if seekVirtualCut(to: seconds, continuous: seekBar.isContinuousSeek) {
            revealSeekBar()
            return
        }
        guard let index = core.index else { return }
        let origin = core.position
        let frame = index.frameNumber(forSeconds: seconds)
        if dragging, frame == origin { return }
        let shouldPreview = previewsFrames && core.isPaused && lastFrame?.number == origin
        previewPin = nil
        positionWillMove(keepingFilmScroll: true)
        if dragging {
            haptics.from(.mouse) { core.dragFilm(toFrame: frame) }
        } else {
            haptics.from(.menu) { core.seek(toFrame: frame) }
        }
        if shouldPreview, core.isPaused {
            let target = core.position
            let settings = seekBar.filmSeekPreviewSettings
            if !videoView.previewFilmSeek(from: origin, to: target, cache: core.cache, settings: settings) {
                let thumbnails = seekBar.cachedSeekThumbnails(from: index.seconds(forFrame: origin),
                                                             to: index.seconds(forFrame: target))
                videoView.previewFilmSeek(thumbnails: thumbnails, target: target, settings: settings)
            }
        }
        revealSeekBar()
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
                     rightButton: NSEvent.pressedMouseButtons & 0b10 != 0, phased: !event.phase.isEmpty)
    }

    /// `source`: who the scroll's haptics answer to; nil, the wheel's (`.mouse`) or the trackpad's.
    private func handleScroll(_ event: NSEvent, source: MouseHaptics.Source? = nil) {
        var sample = scrollSample(event)
        let wheel = buttons.wheel(deltaX: sample.precise ? sample.deltaX : Double(event.deltaX),
                                  deltaY: sample.precise ? sample.deltaY : Double(event.deltaY),
                                  precise: sample.precise, momentum: sample.momentum, began: sample.began, at: sample.time)
        guard !wheel.pending else { return }
        sample.heldButtons = wheel.modifiers
        if sample.precise { sample.deltaX = wheel.deltaX; sample.deltaY = wheel.deltaY }
        let owner = MouseButton.allCases.first { $0.modifier.map(sample.heldButtons.contains) ?? false }
        let fresh = EndBump.isFreshNotch(at: sample.time, previous: lastWheelTime)
        lastWheelTime = sample.time
        if event.phase.contains(.cancelled) || !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) {
            gestures.resetScroll()
            return
        }
        let overVideo = source == nil && !showsHome && openingURL == nil && core.index != nil
        let motionAllowed = !sample.momentum || (core.config.scrub.trackpadMomentum &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let actions = gestures.route(sample, allowsScrubMomentum: overVideo && motionAllowed)
        if actions.contains(where: {
            switch $0 {
            case .scrubFrames, .scrubEdge: true
            default: false
            }
        }) { hideCursorForScrub() }
        perform(actions, from: source ?? (sample.precise ? .trackpad : .mouse), fresh: fresh, heldButton: owner)
    }

    private func handleMagnify(_ event: NSEvent) {
        gestures.cancelScrubMomentum()
        if gestures.pinchZooms(modifiers: Modifiers(event.modifierFlags)) {
            if videoView.zoomAllowed() { videoView.zoomMagnify(event) }
            return
        }
        perform(gestures.routePinch(magnification: Double(event.magnification), modifiers: Modifiers(event.modifierFlags)),
                from: .trackpad, fresh: true)
        if event.phase == .ended || event.phase == .cancelled { gestures.endPinch() }
    }

    /// `heldButton`: the button whose modifier the scroll's chord got, which owns a `scrub-edge` drag.
    private func perform(_ actions: [GestureAction], from source: MouseHaptics.Source, fresh: Bool,
                         heldButton: MouseButton? = nil) {
        for action in actions {
            switch action {
            // `where` binds only to the last pattern of a case: each pattern carries its own.
            case .scrubFrames where showsHome, .scrubEdge where showsHome:
                continue   // the wheel over Home scrolls Home
            case let .scrubFrames(frames, ticks):
                positionWillMove(keepingTrackpadScrub: true)
                core.inputIsFresh = fresh
                haptics.from(source) { if !scrubVirtualCut(frames) { core.scrub(by: frames, ticks: ticks) } }
            case let .command(command): runInput(command, from: source, fresh: fresh)
            case let .scrubEdge(edge, frames): scrubEdge(edge, by: frames, heldButton: heldButton, from: source, fresh: fresh)
            case .zoomBy: break   // `handleMagnify` gives the continuous zoom's pinch to the view
            }
        }
    }

    /// A `scrub-edge` wheel step (mouse spec §5.4): drags the mark edge while `heldButton` is down; its release
    /// (`buttons.onRelease`) makes the drag one ⌘Z step. The scroll's tail after the release moves nothing; bound
    /// without a held button (nothing would end the drag) it is a plain scrub.
    private func scrubEdge(_ edge: MarkEdge, by frames: Int, heldButton: MouseButton?, from source: MouseHaptics.Source,
                           fresh: Bool) {
        if tourBoxEditsEdge { cancelTourBoxInput() }
        if let heldButton, !buttons.held.contains(heldButton) || heldButton == edgeDragSuppressed { return }
        seekBar.cancelMarkDrag()
        positionWillMove()
        core.inputIsFresh = fresh
        guard let heldButton else {
            haptics.from(source) { if !scrubVirtualCut(frames) { core.scrub(by: frames) } }
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
        seekBar.cancelMarkDrag()
        cancelTourBoxInput()
        core.cancelEdgeDrag()
        edgeDragOwner = nil
    }

    /// Everything the mouse buttons have in flight: presses (and the button timer), the edge drag.
    private func cancelMouseInput() {
        buttons.cancelAll()
        gestures.resetScroll()
        homeButtons.cancelAll()
        cancelEdgeDrag()
        edgeDragSuppressed = nil
    }

    // MARK: TourBox Console

    private func setUpTourBox() {
        tourBoxBridge.onBytes = { [weak self] bytes in self?.receiveTourBox(bytes) }
        tourBoxBridge.onDisconnect = { [weak self] in self?.cancelTourBoxInput() }
        tourBoxBridge.onError = { [weak self] message in self?.showMessage(message, duration: 5) }
        updateTourBox()
    }

    private func updateTourBox() {
        tourBoxRouter.framesPerPulse = core.config.tourBoxFramesPerPulse
        tourBoxRouter.accelerates = core.config.tourBoxAccelerates
        tourBoxRouter.accelerationStart = core.config.tourBoxAccelerationStart
        tourBoxRouter.scrollPointsPerPulse = core.config.tourBoxScrollPoints
        guard tourBoxEnabled != core.config.tourBox else { return }
        tourBoxEnabled = core.config.tourBox
        if tourBoxEnabled { tourBoxBridge.start() } else { tourBoxBridge.stop() }
    }

    private var acceptsTourBox: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.attachedSheet == nil && !showsHome && core.info != nil
            && !isTerminating
    }

    private func receiveTourBox(_ bytes: [UInt8]) {
        guard acceptsTourBox else { cancelTourBoxInput(); return }
        let time = ProcessInfo.processInfo.systemUptime
        // Commands can change the profile or file synchronously; read the current state again for every byte.
        for byte in bytes {
            guard acceptsTourBox else { cancelTourBoxInput(); break }
            performTourBox(tourBoxRouter.receive([byte], at: time, profile: core.config.mouseProfile))
        }
        scheduleTourBoxTap()
    }

    private func scheduleTourBoxTap() {
        tourBoxTap?.cancel(); tourBoxTap = nil
        guard let deadline = tourBoxRouter.nextDeadline else { return }
        let tap = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tourBoxTap = nil
            guard self.acceptsTourBox else { self.cancelTourBoxInput(); return }
            self.performTourBox(self.tourBoxRouter.flush(at: ProcessInfo.processInfo.systemUptime))
            self.scheduleTourBoxTap()
        }
        tourBoxTap = tap
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: tap)
    }

    private func cancelTourBoxInput() {
        seekBar.cancelFilmScroll()
        tourBoxTap?.cancel(); tourBoxTap = nil
        _ = tourBoxRouter.cancel()
        if tourBoxHoldsSpeed { core.endHoldSpeed(); tourBoxHoldsSpeed = false; hud.hide() }
        if tourBoxEditsEdge { core.cancelEdgeDrag(); tourBoxEditsEdge = false }
    }

    private func performTourBox(_ actions: [TourBoxAction]) {
        for action in actions {
            // TourBox does not vibrate an unrelated Logitech mouse.
            haptics.from(.menu) {
                switch action {
                case let .command(command): runInput(command, from: .menu)
                case let .scrub(frames):
                    positionWillMove(); core.inputIsFresh = true; if !scrubVirtualCut(frames) { core.scrub(by: frames) }
                case let .edge(edge, frames):
                    seekBar.cancelMarkDrag()
                    if !tourBoxEditsEdge {
                        core.cancelEdgeDrag(); edgeDragOwner = nil; edgeDragSuppressed = nil
                        tourBoxEditsEdge = true
                    }
                    positionWillMove(); core.inputIsFresh = true; core.scrubEdge(edge, by: frames)
                case .endEdge:
                    if tourBoxEditsEdge { core.endEdgeDrag(); tourBoxEditsEdge = false }
                case .cancelEdge:
                    if tourBoxEditsEdge { core.cancelEdgeDrag(); tourBoxEditsEdge = false }
                case .beginSpeedHold:
                    guard holdKeyCode == nil, !tourBoxHoldsSpeed else { return }
                    tourBoxHoldsSpeed = true
                    core.beginHoldSpeed()
                    hud.show(.speed(core.speed * Double(core.direction)), hold: true)
                case .endSpeedHold:
                    if tourBoxHoldsSpeed { core.endHoldSpeed(); tourBoxHoldsSpeed = false; hud.hide() }
                case let .colorStrength(set, delta):
                    runColorOutcome(colorMemory.addStrength(delta, for: set, global: globalConfig))
                case .toggleFilmstrip: toggleFilmstrip()
                case .toggleAcceleration:
                    let enabled = !core.config.tourBoxAccelerates
                    do { try preferences.update(["tourbox-accel"]) { $0.tourBoxAccelerates = enabled } } catch {
                        showMessage("Cannot save settings: \(error)", duration: 4)
                    }
                    showMessage(enabled ? "TourBox: accelerated scrub" : "TourBox: linear scrub")
                case .reversePlayback: core.reversePlaybackDirection()
                case let .filmScroll(points): seekBar.scrollFilm(by: points)
                }
            }
        }
    }

    // MARK: Mouse buttons and the Logitech mouse

    /// The bound mouse buttons (`MouseButtonRouter`) and the player's haptics.
    private func setUpMouse() {
        homeButtons.onFire = { [weak self] chords in
            guard let self, showsHome, let browser = home?.browser,
                  browser.location != HomeRecent.location(of: .stash) else { return }
            for chord in chords {
                if chord.key == "MBTN_BACK" { browser.goBack() }
                if chord.key == "MBTN_FORWARD" { browser.goForward() }
            }
        }
        haptics.config = { [weak self] in self?.core.config ?? Config() }
        core.onHaptic = { [weak self] in self?.haptics.play($0) }   // filtered by the input running (`haptics.from`)
        core.onSeekHaptic = { [weak self] in self?.haptics.play($0, mouseOnly: true) }   // a seek's step: the mouse only
        buttons.onPress = { [weak self] in self?.gestures.resetScroll() }
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
        homeButtons.heard = { [weak bridge] in bridge?.watching ?? [] }
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
            SettingsPanel.wheelFreeSpinDidChange()
            updatePrecisionWheel()
            if playerInFront { showMessage(mode == .freeSpin ? "Free spin · Precision Scroll" : "Ratchet") }
        }
        bridge.onSmartShift = { [weak self] pressed, time in self?.smartShiftButton(pressed: pressed, at: time) }
        wheelWants = WheelWants(precision: false, freeSpin: true, playerInFront: false, overVideo: false)
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
            homeButtons.mouseRelease(button, at: time)
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
            case .browserBack, .browserForward: break   // not given over a plugin page
            }
        }
        if showsHome, let browser = home?.browser {
            // Web pages keep their own swipe handling; folder history merges HID and AppKit clicks.
            let page = browser.location == HomeRecent.location(of: .stash) ? stashLibrary : nil
            switch SideButtonFilter.homePress(button, mode: core.config.mxSideButtons, stashPageShown: page != nil) {
            case .pass: break
            case .drop: return
            case .pageBack: page?.goBack(); return
            case .pageForward: page?.goForward(); return
            case .browserBack, .browserForward:
                let underPointer = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
                homeButtons.mousePress(button, keys: [], rightHeld: false, at: time,
                                       watched: core.config.mxSideButtons == .watch,
                                       overOwnWindow: underPointer == window?.windowNumber)
                return
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

    private func updateSeekBarForPointer() {
        guard !showsHome, failureView.isHidden else { return }
        let point = window?.mouseLocationOutsideOfEventStream
        seekBar.updateFilmPointer(point)
        if seekBar.isInRevealZone(point) || seekBar.isInteracting {
            hideSeekBarWork?.cancel()
            hideSeekBarWork = nil
            if !seekBar.playbackVisible || seekBar.alphaValue < 1 { revealSeekBar(linger: false) }
        } else if hideSeekBarWork == nil, seekBar.playbackVisible || isBackButtonShown {
            scheduleSeekBarHide(after: 0.15)
        }
    }

    private func revealSeekBar(linger: Bool = true) {
        // No file: nothing to show, and over the Stash page the bar would take its clicks.
        if showsHome || !failureView.isHidden { return }
        updateSeekBar()
        backButton.title = switch returnTab {
        case .stash: "Stash"
        case .folders: folderReturn?.folder.lastPathComponent ?? "Folders"
        case .recent: "Recent"
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            seekBar.animator().alphaValue = 1
        }
        seekBar.refreshVisibility()
        seekBar.setPlaybackControlsVisible(true)
        seekBar.revealPlaybackControls()
        showBackButton(true, duration: 0.15)
        if linger { scheduleSeekBarHide(after: 1.5) }
    }

    private func scheduleSeekBarHide(after delay: TimeInterval) {
        hideSeekBarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            hideSeekBarWork = nil
            if seekBar.isInRevealZone(window?.mouseLocationOutsideOfEventStream) || seekBar.isInteracting { return }
            hover(nil)
            seekBar.setPlaybackControlsVisible(false)
            if !seekBar.playbackVisible, !seekBar.showsFilmstrip {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    self.seekBar.animator().alphaValue = 0
                }
            }
            if !isPointer(over: backButton) { showBackButton(false, duration: 0.2) }
            hideCursorOverVideo()
        }
        hideSeekBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Fades the back button in or out and moves the OSD out of its way.
    private func showBackButton(_ show: Bool, duration: TimeInterval) {
        isBackButtonShown = show
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            backButton.animator().alphaValue = show ? 1 : 0
            placeTopOverlays(animated: true)
        }
    }

    /// The back button and the OSD at the top: 16 pt down, and below the full-screen title bar while it is in.
    private func placeTopOverlays(animated: Bool = false) {
        guard let window, let content = window.contentView else { return }
        let layoutTop = content.convert(window.contentLayoutRect, from: nil).maxY
        let covered = max(titlebarInset, max(0, content.bounds.maxY - layoutTop))
        let visibleTopInset = max(0, visibleEdges[2].constant)
        let clearance = max(0, covered - visibleTopInset)
        let back = 16 + clearance
        let message = (isBackButtonShown ? 16 + BackButton.height + 8 : 16) + clearance
        if backButtonTop.constant != back {
            if animated { backButtonTop.animator().constant = back } else { backButtonTop.constant = back }
        }
        if osdTop.constant != message {
            if animated { osdTop.animator().constant = message } else { osdTop.constant = message }
        }
        updateSlotsTopInset()
    }

    /// In full screen the title bar (and the traffic lights) live in a window of their own that the system slides in
    /// with the menu bar; each of its moves says how far it now reaches over the screen (measured 2026-10-27: away,
    /// its bottom is the screen's top). The overlays follow it, so the back button is never under it.
    private func followFullScreenTitlebar(_ on: Bool) {
        if let titlebarObserver { NotificationCenter.default.removeObserver(titlebarObserver) }
        titlebarObserver = nil
        titlebarInset = 0
        defer { placeTopOverlays() }
        guard on, let window, let bar = window.standardWindowButton(.closeButton)?.window, bar !== window else { return }
        let update: @MainActor @Sendable () -> Void = { [weak self, weak bar] in
            guard let self, let bar, let window = self.window, let screen = window.screen else { return }
            let inset = max(0, min(200, screen.frame.maxY - bar.frame.minY))
            guard inset != self.titlebarInset else { return }
            self.titlebarInset = inset
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                self.placeTopOverlays(animated: true)
            }
        }
        titlebarObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: bar,
                                                                  queue: .main) { _ in MainActor.assumeIsolated { update() } }
        update()
    }

    /// The wheel mode (`wheel-precision=yes`: free spin or ratchet, the user's choice in `wheelFreeSpin`) is wanted
    /// of the mouse while the player window is in front, whatever the pointer is over. Precision Scroll is wanted on
    /// free spin only, while the pointer is over the video: not over the seek bar (its wheel steps the preview between
    /// keyframes), the playlist, the stats panel or the start screen, where macOS would scroll lists far too fast with
    /// it, nor over another window floating above the video (Spotlight, Raycast).
    func updatePrecisionWheel() {
        guard let mouseBridge else { return }
        let inFront = playerInFront
        let overVideo = isPointer(over: videoView) && !isPointer(over: seekBar)
            && !(slots?.isPointerOverShownSlot ?? false)
            && !(window.map { isPointerOnStats(at: $0.mouseLocationOutsideOfEventStream) } ?? false)
            && NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window?.windowNumber
        let freeSpin = UserDefaults.standard.object(forKey: Self.wheelFreeSpinKey) as? Bool ?? true
        let wants = WheelWants(precision: core.config.wheelPrecision, freeSpin: freeSpin, playerInFront: inFront,
                               overVideo: overVideo)
        if wants != wheelWants {
            wheelWants = wants
            mouseBridge.takeSmartShift(wants.wheelMode != nil)
        }
        // As areas of this window: MouseService applies them while the pointer is over it, and rechecks the mouse
        // itself after a sleep or a reconnect. Sent on every call (the bridge drops an unchanged wish), so the video's
        // rect follows a resize and full screen.
        mouseBridge.wantWheel(window: window?.windowNumber, mode: wants.wheelMode,
                              highResolutionRect: wants.highResolution ? videoView.convert(videoView.bounds, to: nil) : nil)
    }

    /// The app is active and this window is key, with no sheet and no start screen: the one definition of "in front"
    /// for the wheel (`updatePrecisionWheel`, the SmartShift button).
    private var playerInFront: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.attachedSheet == nil && !showsHome && failureView.isHidden
    }

    private func isPointer(over view: NSView) -> Bool {
        guard let window, !view.isHidden, view.alphaValue > 0.01 else { return false }
        if view === seekBar, let container = seekBar.superview {
            return seekBar.hitTest(container.convert(window.mouseLocationOutsideOfEventStream, from: nil)) != nil
        }
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

    /// Hover pictures follow `preview`; the filmstrip has its own visibility and utility decoder.
    private func configurePreview(force: Bool = false) {
        let scale = window?.backingScaleFactor ?? 2
        let key = PreviewKey(enabled: core.config.preview, width: CGFloat(core.config.previewWidth), url: core.url, scale: scale)
        if !force, key == previewKey { return }
        previewKey = nil
        filmstripPrewarmFrames.removeAll()
        pausedFilmstripPrewarmPosition = nil
        filmstripLoader?.stop()
        filmstripLoader = nil
        if virtualCut == nil { seekBar.resetFilmstrip() }
        previewProvider?.stop()
        previewProvider = nil
        hover(nil)
        guard let url = core.url, let index = core.index, let info = core.info else { return }
        previewKey = key   // set before the provider exists: an unavailable file is not retried until the key changes
        let imagePool = PreviewImagePool(url: url, rotationClockwise: info.rotationClockwise)
        if core.config.preview, virtualCut == nil {
            let provider = FrameScrubCore.PreviewProvider(url: url, index: index, rotationClockwise: info.rotationClockwise,
                                           widthPixels: Int(core.config.previewWidth * scale), readCache: core.readCache,
                                           policy: core.networkPolicy, imagePool: imagePool, frameCache: core.cache)
            provider.onImage = { [weak self] result in
                guard let self else { return }
                let start = PlaybackDiagnostics.enabled ? PlaybackDiagnostics.now() : 0
                if seekBar.filmstripEnabled { seekBar.setFilmstripImage(result.image, seconds: result.frameSeconds) }
                guard previewSample != nil else { return }
                previewImage = videoView.geometry.thumbnail(of: result.image, context: Self.thumbnailContext) ?? result.image
                updatePreviewView()
                if PlaybackDiagnostics.enabled {
                    let report = PlaybackDiagnostics.shared
                    report.record("callback_ui_ms", (PlaybackDiagnostics.now() - start) * 1000, group: "preview.ui")
                    report.record("request_to_ui_ready_ms", (PlaybackDiagnostics.now() - result.requestedAt) * 1000, group: "preview.ui")
                }
            }
            provider.onUnavailable = { [weak self] in
                self?.previewProvider?.stop()
                self?.previewProvider = nil
                self?.previewImage = nil
                self?.updatePreviewView()
            }
            previewProvider = provider
        }
        let loader = FilmstripPreviewLoader(url: url, index: index, rotation: info.rotationClockwise,
                                            width: Int(160 * scale), cache: core.readCache, policy: core.networkPolicy,
                                            imagePool: imagePool, frameCache: core.cache, exactSample: virtualCut != nil)
        loader.mayRead = { [weak self] in
            guard let self else { return false }
            guard seekBar.allowsVisibleFilmstripRequests, !showsHome else { return false }
            return core.allowsBackgroundPreview && virtualCut?.playback.pending == nil && virtualCut?.warm?.preview == nil
        }
        loader.mayPrewarm = { [weak self] readyOnly in
            guard let self else { return false }
            return (readyOnly || core.isPaused) && seekBar.filmstripEnabled && !seekBar.showsFilmstrip && !seekBar.isInteracting
                && previewFraction == nil && !showsHome && !core.isExporting && window?.inLiveResize == false
                && window?.occlusionState.contains(.visible) == true && core.allowsBackgroundPreview
        }
        loader.onImage = { [weak self] image, seconds in
            guard let self else { return }
            if let cut = virtualCut {
                for time in cut.filmSamples[seconds] ?? [] { seekBar.setFilmstripImage(image, seconds: time) }
            } else { seekBar.setFilmstripImage(image, seconds: seconds) }
        }
        filmstripLoader = loader
        prewarmFilmstrip()
    }

    private func requestFilmstrip(_ times: [Double]) {
        guard let cut = virtualCut else { filmstripLoader?.request(times); return }
        cut.filmSamples = [:]
        guard let source = cut.loadedSource, let active = cut.playback.activeSpan, cut.playback.pending == nil else {
            filmstripLoader?.request([])
            return
        }
        let timeline = cut.playback.timeline
        var sourceTimes: [Double] = []
        for time in times {
            guard let location = timeline.location(at: time), timeline.spans[location.spanIndex].source == source else { continue }
            if cut.filmSamples[location.sourceTime] == nil { sourceTimes.append(location.sourceTime) }
            cut.filmSamples[location.sourceTime, default: []].append(time)
        }
        if !core.isPaused && !seekBar.hasCutPoster(active) {
            let sample = sourceTimes.first { time in
                let span = timeline.spans[active]
                return span.sourceStart <= time && time < span.sourceEnd
            }
            filmstripLoader?.request(sample.map { [$0] } ?? [])
        } else {
            filmstripLoader?.request(sourceTimes, readyOnly: !core.isPaused)
        }
        requestUpcomingCutPoster(cut)
    }

    private func prewarmFilmstrip() {
        guard virtualCut == nil, let loader = filmstripLoader, let index = core.index, index.isExact, seekBar.filmstripEnabled,
              !seekBar.showsFilmstrip, !showsHome, window?.occlusionState.contains(.visible) == true else { return }
        seekBar.updateTimeline(index: core.index, duration: core.durationSeconds, paused: core.isPaused,
                               uprightSize: uprightVideoSize, geometry: videoView.geometry,
                               previewSettle: core.networkPolicy.previewSettle)
        let times = seekBar.prewarmFilmstripTimes(center: core.currentSeconds)
        pausedFilmstripPrewarmPosition = core.isPaused ? core.position : nil
        filmstripPrewarmFrames = core.isPaused ? [] : Set(times.map { index.frameNumber(forSeconds: $0) })
        loader.prewarm(times, paused: core.isPaused)
    }

    /// Sorts and filters the folder's last listing (only `url` until the folder has been read).
    private func rebuildPlaylist(around url: URL) {
        let folder = folder(of: url)
        let listing = folderListing.flatMap { $0.folder == folder ? $0 : nil } ?? .empty(folder)
        // The folder's order, as Home shows it, however the video was opened.
        playlist = Playlist(current: url, sort: folderSort(folder), filter: playlistFilter, listing: listing)
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
        playlistPanel.showSort(playlistAnchor.map { folderSort(folder(of: $0)) } ?? core.config.playlistSort.defaultSort)
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
        if let target = playlist?.neighbour(direction, skipping: isUnreadable) {
            _ = playlistEndBump.stepped(moved: true, direction: direction, fresh: core.inputIsFresh)
            hud.show(direction > 0 ? .playlistNext : .playlistPrevious)
            slots.videoChanged(cause: .key)
            openFile(target, stepped: direction) { [weak self] outcome in self?.showKeptSpeed(after: outcome) }
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

    /// `url` as the open folder's listing has it (its date and size), nil before the folder is read.
    private func listedEntry(_ url: URL) -> BrowserEntry? {
        let me = url.standardizedFileURL
        return folderListing?.entries.first { $0.url.standardizedFileURL == me }
    }

    /// Known to be unreadable, and not changed since.
    private func isUnreadable(_ url: URL) -> Bool {
        let entry = listedEntry(url)
        return unreadable.contains(url, date: entry?.date, size: entry?.size)
    }

    /// `folder`'s order, the one Home's grid shows it in: its own (`FolderSorts`), else `playlist-sort`'s.
    private func folderSort(_ folder: URL) -> BrowserSort {
        folderSorts.sort(for: folder) ?? core.config.playlistSort.defaultSort
    }

    /// The panel's order menu and F9: the open folder's order, for Home's grid too. The field it has already turns
    /// around, another starts in its first direction (`BrowserSortChoice`).
    private func setPlaylistSort(_ sort: PlaylistSort) {
        guard let anchor = playlistAnchor, let key = BrowserSort.Key(rawValue: sort.rawValue) else { return }
        let folder = folder(of: anchor)
        var choice = BrowserSortChoice(current: folderSort(folder))
        let chosen = choice.choose(key)
        folderSorts.set(chosen, for: folder)
        rebuildPlaylist(around: anchor)
        showMessage("Folder order: \(Self.orderTitle(chosen))")
    }

    /// "Name (A–Z)", "Date (newest first)", "Size (smallest first)".
    private static func orderTitle(_ sort: BrowserSort) -> String {
        switch sort.key {
        case .name: sort.ascending ? "Name (A–Z)" : "Name (Z–A)"
        case .date: sort.ascending ? "Date (oldest first)" : "Date (newest first)"
        case .size: sort.ascending ? "Size (smallest first)" : "Size (largest first)"
        }
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
            lastFrame = nil
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
                lastFrame = nil
                videoView.clear(blank: true)
                showHome()
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
        lastFrame = nil
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
        lastFrame = nil
        videoView.clear(blank: true)
        failedURL = nil
        failedScene = nil
        origin = .plain
        showHome(tab: .stash)
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
        core.index?.frameNumber(forSeconds: fraction * core.durationSeconds) ?? 0
    }

    /// The frame the preview shows: where a scroll over the bar moved it, else under the pointer.
    private var previewFrame: Int? {
        previewPin?.frame ?? previewFraction.map(frame(atBarFraction:))
    }

    /// Lets the preview follow the pointer again once it has moved away from where the scroll left it.
    private func releasePin(ifPointerAt fraction: Double) {
        if let pin = previewPin, abs(fraction - pin.fraction) * (seekBar.bounds.width - 24) > Self.pinSlack { previewPin = nil }
    }

    private var diagnosticSweepStarted = false
    private func diagnosticSweep(step: Int) {
        guard step < 100 else { hover(nil); return }
        hover(0.1 + Double(step % 40) * 0.02)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.diagnosticSweep(step: step + 1) }
    }

    private func hover(_ pointerFraction: Double?) {
        if let pointerFraction, virtualCut != nil {
            let enteredTimeline = cutHoverFraction == nil
            cutHoverFraction = pointerFraction
            if enteredTimeline {
                let work = DispatchWorkItem { [weak self] in
                    self?.previewHoverWork = nil
                    self?.updateCutHover()
                }
                previewHoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            } else if previewHoverWork == nil {
                updateCutHover()
            }
            return
        }
        cutHoverFraction = nil
        let fraction = virtualCut == nil ? pointerFraction : nil
        let enteredTimeline = previewFraction == nil
        previewFraction = fraction
        guard let fraction, let index = core.index else {
            previewHoverWork?.cancel()
            previewHoverWork = nil
            previewPin = nil
            seekBar.previewFrame = nil
            previewImage = nil
            previewSample = nil
            previewView.hide()
            return
        }
        releasePin(ifPointerAt: fraction)
        if enteredTimeline {
            // Brief crossings on the way to the controls should not flash a preview.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                previewHoverWork = nil
                if let index = core.index { requestPreview(index) }
            }
            previewHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else if previewHoverWork == nil {
            requestPreview(index)
        }
    }

    private func updateCutHover() {
        guard let fraction = cutHoverFraction, let timeline = virtualCut?.playback.timeline else { return }
        let seconds = fraction * timeline.duration
        guard let location = timeline.location(at: seconds) else { return }
        let span = timeline.spans[location.spanIndex]
        let heading = "Fragment \(location.spanIndex + 1)/\(timeline.spans.count)  ·  \(FrameNaming.timecode(seconds))"
        let source = "Source  \(FrameNaming.timecode(span.sourceStart)) – \(FrameNaming.timecode(span.sourceEnd))"
        previewView.show(image: nil, scale: 1, time: heading + "\n" + source, lens: nil, playhead: 0)
        placeTimelinePreview(at: fraction)
    }

    private func requestPreview(_ index: FrameIndex) {
        guard let frame = previewFrame else { return }
        // The timecode tracks the pointer continuously. The image only needs a new keyframe.
        let seconds = index.seconds(forFrame: index.keyframe(atOrBefore: frame))
        if let previewProvider, previewSample?.seconds != seconds || previewSample?.exact != index.isExact {
            previewSample = (seconds, index.isExact)
            previewProvider.request(seconds: seconds)
        }
        updatePreviewView()
    }

    /// Scrolling over the bar moves the preview from keyframe to keyframe without touching playback; a click then
    /// goes to the keyframe shown. Without known keyframes (approximate index) the scroll does nothing.
    private func scrollOverSeekBar(_ event: NSEvent) {
        guard !seekBar.showsFilmstrip, let fraction = previewFraction, let index = core.index, let from = previewFrame else {
            return handleScroll(event, source: .menu)   // no preview: the bar's scroll scrubs, silently (the bar never vibrates)
        }
        lensScroll.invertX = core.config.scrub.invert
        let sample = scrollSample(event)
        let wheel = buttons.wheel(deltaX: sample.precise ? sample.deltaX : Double(event.deltaX),
                                  deltaY: sample.precise ? sample.deltaY : Double(event.deltaY), precise: sample.precise,
                                  momentum: sample.momentum, began: sample.began, at: sample.time)
        guard !wheel.pending else { return }
        let steps = lensScroll.steps(for: sample)
        guard steps != 0, let target = KeyframeLens.step(index, from: from, by: steps) else { return }
        previewPin = (target, fraction)
        requestPreview(index)
        revealSeekBar()
    }

    private static let thumbnailContext = CIContext(options: [.cacheIntermediates: false])

    private func updatePreviewView() {
        let diagnosticStart = PlaybackDiagnostics.enabled ? PlaybackDiagnostics.now() : 0
        defer { if PlaybackDiagnostics.enabled {
            PlaybackDiagnostics.shared.record("update_view_ms", (PlaybackDiagnostics.now() - diagnosticStart) * 1000, group: "preview.ui")
        } }
        guard previewHoverWork == nil, let frame = previewFrame, let index = core.index else { return }
        let lens = seekBar.showsFilmstrip ? nil : KeyframeLens(index: index, frame: frame)
        let fragment = core.segments.flatMap { segments in
            segments.index(containing: frame).map { i in
                let range = segments.ranges[i]
                return "\nFragment \(i + 1)/\(segments.ranges.count)  ·  \(FrameNaming.timecode(index.seconds(forFrame: range.lowerBound))) – \(FrameNaming.timecode(index.seconds(forFrame: range.upperBound)))"
            }
        } ?? ""
        seekBar.previewFrame = frame
        previewView.show(image: previewImage, scale: window?.backingScaleFactor ?? 2,
                         time: "\(FrameNaming.timecode(index.seconds(forFrame: frame)))  f\(frame)" + (lens.map { "  " + $0.label } ?? "") + fragment,
                         lens: lens, playhead: core.position)
        let fraction = core.durationSeconds > 0 ? index.seconds(forFrame: frame) / core.durationSeconds : 0
        placeTimelinePreview(at: fraction)
    }

    private func placeTimelinePreview(at fraction: Double) {
        guard let container = window?.contentView else { return }
        previewView.layoutSubtreeIfNeeded()
        let localX = seekBar.filmPointer?.x ?? (12 + fraction * (seekBar.frame.width - 24))
        let trackX = seekBar.frame.minX + localX
        let width = previewView.fittingSize.width
        let maxLeading = max(container.bounds.width - width - 8, 8)
        previewLeading.constant = min(max(trackX - width / 2, 8), maxLeading)
    }

    private func updateSeekBar() {
        if let session = virtualCut {
            let state = session.playback
            let span = state.pending?.location.spanIndex ?? state.failure?.location.spanIndex ?? state.activeSpan ?? 0
            seekBar.updateVirtualCut(time: state.position, span: span, paused: core.isPaused,
                                     previewSettle: core.networkPolicy.previewSettle)
            updateTransport()
            return
        }
        seekBar.showSourceSegments(core.segments?.ranges ?? [], locked: core.segmentsLocked)
        let marks = core.marks
        // What each clip gets before its mark from the keyframe it starts on (exact index only).
        let leadIns = core.index.map { index in
            index.isExact ? marks.segments.compactMap { segment -> ClosedRange<Int>? in
                let keyframe = index.keyframe(atOrBefore: segment.start)
                return keyframe < segment.start ? keyframe...(segment.start - 1) : nil
            } : []
        } ?? []
        seekBar.updateTimeline(index: core.index, duration: core.durationSeconds, paused: core.isPaused,
                               uprightSize: uprightVideoSize, geometry: videoView.geometry,
                               previewSettle: core.networkPolicy.previewSettle)
        seekBar.update(frameCount: core.frameCount, position: core.position, cached: core.cache.cachedRanges(),
                       loopA: core.loopA, loopB: core.loopB, marks: marks.segments.map { $0.start...$0.end },
                       leadIns: leadIns, openMark: marks.open, text: "\(core.progressText)   frame \(core.position)")
        updateTransport()
    }

    /// Refresh only the controls whose values changed; file navigation belongs to the playlist slot.
    private func updateTransport() {
        seekBar.transport.update(volume: core.volume, muted: core.isMuted, paused: core.isPaused, speed: core.speed)
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
        slots = SlotsController(container: container, above: failureView, config: globalConfig, playlistView: playlistPanel)
        slots.makeArtifactFilterPanel = { [weak self] in
            let panel = ArtifactFilterPanelView()
            panel.settings = { [weak self] in self?.preferences.config.artifactFilters ?? .init() }
            panel.update = { [weak self] keys, edit in
                guard let self else { return }
                do { try preferences.update(keys) { edit(&$0.artifactFilters) } }
                catch { showMessage("Cannot save settings: \(error)", duration: 4) }
            }
            self?.artifactFilterPanel = panel
            return panel
        }
        slots.configurePage = { [weak self] in self?.configurePluginPage($0) }
        slots.makeSubjectFocusPanel = { [weak self] in
            let panel = SubjectFocusPanelView()
            panel.currentStyle = { [weak self] in self?.videoView.subjectFocus }
            panel.setStyle = { [weak self] in self?.setSubjectFocus($0) }
            panel.lastStyle = { Self.subjectFocusStyle }
            self?.subjectFocusPanel = panel
            return panel
        }
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
            removePluginCatalog(page.token)
            clearPluginAnalysisPage(page.token)
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
            removePluginCatalog(page.token)
            clearPluginAnalysisPage(page.token)
            panelInfoSent[page.token] = nil   // the new page has heard nothing yet
            dispatchPanelInfo()
            pushPluginState(force: true)
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
        let configured = Set(globalConfig.plugins.compactMap { PluginOrigin(url: $0.url) })
        for (token, catalog) in pluginCatalogs where !configured.contains(catalog.origin) {
            removePluginCatalog(token)
        }
        if let owner = pluginAnalysisOwner, !configured.contains(owner.origin) {
            clearPluginAnalysisPage(owner.page)
        }
        pluginAnalysisVersionWaiters.removeAll { !configured.contains($0.origin) }
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

    /// The side slots start below the title bar and toolbar wherever these lie over the content (Home's toolbar, the
    /// full-screen title bar while it is in), so the slots' headers and the traffic lights and pills never cover each
    /// other and both take clicks.
    private func updateSlotsTopInset() {
        guard let window, let slots, let container = window.contentView else { return }
        slots.topInset = isFullScreen ? titlebarInset
            : max(0, container.bounds.maxY - container.convert(window.contentLayoutRect, from: nil).maxY)
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
        case let .analysisSourceVersion(sourceID):
            guard let page, isConfiguredAnalysisPage(page, origin: origin), sourceID == pluginAnalysisSourceID,
                  let cache = core.readCache, virtualCut == nil else {
                pluginFailed(request, "Analysis requires the current local source and a configured page.")
                return
            }
            if let pluginAnalysisVersion {
                pluginDone(request, result: "\"\(pluginAnalysisVersion)\"")
                return
            }
            guard let id = request.id else { return }
            guard pluginAnalysisVersionWaiters.count < 16 else {
                pluginFailed(request, "Too many analysis version requests.")
                return
            }
            pluginAnalysisVersionWaiters.append(AnalysisVersionWaiter(id: id, page: page.token, origin: origin))
            if !pluginAnalysisVersionInFlight {
                pluginAnalysisVersionInFlight = true
                pluginAnalysisVersionWorker.submit(AnalysisVersionRead(sourceID: sourceID, cache: cache))
            }
            return
        case let .analysisTimeline(sourceID, snapshot):
            guard let page, isConfiguredAnalysisPage(page, origin: origin), sourceID == pluginAnalysisSourceID,
                  virtualCut == nil,
                  pluginAnalysisOwner.map({ $0.page == page.token && $0.origin == origin }) ?? true else {
                pluginFailed(request, "Analysis requires the current local source and its owning configured page.")
                return
            }
            let hadOwner = pluginAnalysisOwner != nil
            pluginAnalysisOwner = snapshot == nil ? nil : (page.token, origin)
            seekBar.setAnalysisTimeline(snapshot)
            if snapshot == nil { page.setAnalysisPollingAllowed(false) }
            updatePluginAnalysisPolling()
            if !hadOwner, snapshot != nil { revealSeekBar() }
        case let .cutCatalog(descriptor):
            guard let page, page.pageSource == .settings else { pluginFailed(request, "catalog requires a configured page"); return }
            if let descriptor {
                let configured = Set(globalConfig.plugins.compactMap { PluginOrigin(url: $0.url) })
                guard descriptor.allowed(from: origin, configured: configured) else {
                    pluginFailed(request, "catalog endpoint must have the configured page's origin")
                    return
                }
                let catalog = PluginCatalogSource(descriptor: descriptor, origin: origin, page: page.token)
                guard pluginCatalogs.count < 16 || pluginCatalogs[page.token] != nil,
                      !pluginCatalogs.values.contains(where: { $0.page != page.token && $0.locationID == catalog.locationID }) else {
                    pluginFailed(request, "catalog already registered or too many catalogs")
                    return
                }
                if pluginCatalogs[page.token]?.descriptor != descriptor {
                    pluginCatalogs[page.token]?.stop()
                    pluginCatalogs[page.token] = catalog
                    refreshPluginCatalogs()
                }
            } else { removePluginCatalog(page.token) }
        case let .openOriginalFragment(rangeID):
            openVirtualCutOriginal(rangeID: rangeID, request: request, origin: origin)
            return
        case let .returnToVirtualCut(revision):
            returnToVirtualCut(revision: revision, request: request, origin: origin)
            return
        case let .cutEditRange(edges):
            guard let context = virtualCutReturn, context.originalReady, virtualCut == nil, !showsHome,
                  let catalog = catalogForCut(context.catalog.source), catalog.page == request.page, catalog.origin == origin else {
                pluginFailed(request, "Fragment handles require the owning editor's original context.")
                return
            }
            if let edges {
                guard context.session.cut.ranges.contains(where: { $0.id == edges.rangeID && $0.source == context.source }),
                      edges.start < core.durationSeconds else {
                    pluginFailed(request, "The fragment is not in this original source.")
                    return
                }
            }
            seekBar.setCutEdges(edges)
            if edges != nil { revealSeekBar() }
        case let .seek(t):
            seekBar.cancelFilmScroll()
            if !seekVirtualCut(to: t) { core.seek(toSeconds: t) }
        case .play:
            if let session = virtualCut { session.playback.wantsPlayback = true }
            if core.isPaused, virtualCut?.playback.pending == nil, virtualCut?.playback.failure == nil { core.play() }
        case .pause:
            virtualCut?.playback.wantsPlayback = false
            if !core.isPaused { core.pause() }
        case let .step(n):
            seekBar.cancelFilmScroll()
            virtualCut?.playback.wantsPlayback = false
            core.step(frames: n)
        case let .loop(segment):
            if let session = virtualCut { session.playback.loops = segment != nil }
            else { core.setLoop(seconds: segment) }
        case let .segments(list, lock, advance):
            guard virtualCut == nil else { pluginFailed(request, "open the original to set source ranges"); return }
            let firstRanges = core.segments == nil
            guard core.setSegments(seconds: list, lock: lock ?? true, advance: advance) else {
                pluginFailed(request, "no segment inside the file")
                return
            }
            if firstRanges, core.segments != nil, !showsHome {
                seekBar.setFilmRevealed(true, force: true)
                revealSeekBar()
            }
        case let .lock(on):
            guard core.setSegmentLock(on) else { pluginFailed(request, "no segments"); return }
        case let .goSegment(i):
            seekBar.cancelFilmScroll()
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
                                    url: source == .stream ? core.url?.absoluteString : nil, scene: scene, source: source,
                                    sourceID: pluginAnalysisSourceID))
    }

    private func isConfiguredAnalysisPage(_ page: PluginPanel, origin: PluginOrigin) -> Bool {
        page.pageSource == .settings && globalConfig.plugins.contains { PluginOrigin(url: $0.url) == origin }
    }

    private func clearPluginAnalysisPage(_ token: Int) {
        if pluginAnalysisOwner?.page == token {
            slots.page(withToken: token)?.setAnalysisPollingAllowed(false)
            pluginAnalysisOwner = nil
            seekBar.setAnalysisTimeline(nil)
            updatePluginAnalysisPolling()
        }
        pluginAnalysisVersionWaiters.removeAll { $0.page == token }
    }

    private func resetPluginAnalysisSource() {
        finishPluginAnalysisVersion(nil, sourceID: pluginAnalysisSourceID)
        pluginAnalysisSourceID = nil
        if let owner = pluginAnalysisOwner { clearPluginAnalysisPage(owner.page) }
    }

    private var analysisViewingVisible: Bool {
        isVirtualCutBench || (!isTerminating && !showsHome && window?.isVisible == true
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true)
    }

    private func updatePluginAnalysisPolling() {
        let active = analysisViewingVisible && seekBar.analysisTimeline?.running == true
        guard let owner = pluginAnalysisOwner, let page = slots.page(withToken: owner.page),
              let sourceID = pluginAnalysisSourceID else {
            pluginAnalysisPolling?.cancel()
            pluginAnalysisPolling = nil
            return
        }
        page.setAnalysisPollingAllowed(active)
        if !active {
            pluginAnalysisPolling?.cancel()
            pluginAnalysisPolling = nil
            return
        }
        guard pluginAnalysisPolling == nil else { return }
        pluginAnalysisPolling = Task { @MainActor [weak page] in
            // Match the plugin's previous polling cadence. No refreshes at rest or in an occluded window.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_200))
                guard !Task.isCancelled, let page else { return }
                page.dispatch(.analysisRefresh(sourceID: sourceID))
            }
        }
    }

    private func finishPluginAnalysisVersion(_ version: String?, sourceID: String?) {
        guard sourceID == pluginAnalysisSourceID else { return }
        pluginAnalysisVersion = version
        pluginAnalysisVersionInFlight = false
        let waiters = pluginAnalysisVersionWaiters
        pluginAnalysisVersionWaiters.removeAll()
        for waiter in waiters {
            guard let page = slots.page(withToken: waiter.page), isConfiguredAnalysisPage(page, origin: waiter.origin) else { continue }
            if let version { page.reply(.success(waiter.id, result: "\"\(version)\"")) }
            else { page.reply(.failure(waiter.id, "Could not verify the current analysis source version.")) }
        }
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
                                loop: core.loopSeconds, segments: pluginSegments(), visible: true,
                                sourceID: pluginAnalysisSourceID)
        if let cut = virtualCut {
            state.path = nil
            state.name = cut.cut.title
            state.t = cut.playback.position
            state.duration = cut.playback.timeline.duration
            state.frame = 0
            state.durationFrames = 0
            state.fps = 0
            state.loop = nil
            state.segments = nil
        } else if case let .stash(sceneID, _) = origin { state.scene = sceneID }
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
            self?.placeTopOverlays()
            self?.slots?.containerDidLayout()
            panel?.place()
        }
        statsPanel = panel
    }

    /// For View › Show Stats / Hide Stats.
    var statsVisible: Bool { statsPanel.isVisible }
    var filmstripShown: Bool { seekBar.showsFilmstrip }
    var filmstripPinned: Bool { seekBar.filmPinned }
    func toggleFilmstrip() { seekBar.toggleFilmVisibility(); revealSeekBar() }
    func pinFilmstrip() { seekBar.toggleFilmPin(); revealSeekBar() }

    /// For the ticks of Playback › Colour: the open file's colour over framescrub.conf.
    var colorConfig: Config { core.config }

    // MARK: Subject Focus (spike)

    /// The style `H` and the menu last chose, shared by the windows (kept, as the panel's settings are).
    private static var subjectFocusStyle = UserDefaults.standard.string(forKey: "SubjectFocus.style")
        .flatMap(SubjectFocusStyle.init(rawValue:)) ?? .studio {
        didSet { UserDefaults.standard.set(subjectFocusStyle.rawValue, forKey: "SubjectFocus.style") }
    }
    /// The panel in a slot's tab (⌥H), once made.
    private weak var subjectFocusPanel: SubjectFocusPanelView?
    private static var focusFromEnvironmentDone = false

    /// Bench (`FRAMESCRUB_FOCUS_PANEL=bench`): the main thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`) for ⌥H showing
    /// the panel's tab (the first time builds it), a slider step and ⌥H hiding it, 5 rounds, logged.
    private func benchSubjectFocusPanel(round: Int = 1) {
        guard round <= 5 else { return }
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) * 1e3 + Double(t.tv_nsec) / 1e6 }
        var t = cpu()
        slots.toggleSubjectFocusPanel()
        let shown = cpu() - t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let panel = subjectFocusPanel else { return }
            var slides: [Double] = []
            for k in 0..<10 { t = cpu(); panel.benchSlide(to: -1 + Double(k) * 0.2); slides.append(cpu() - t) }
            t = cpu()
            slots.toggleSubjectFocusPanel()
            NSLog("subject focus panel bench: round %d, show %.2f ms, slider step %.2f ms (max %.2f), hide %.2f ms", round,
                  shown, slides.reduce(0, +) / Double(slides.count), slides.max()!, cpu() - t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.benchSubjectFocusPanel(round: round + 1) }
        }
    }

    /// Bench: `FRAMESCRUB_FOCUS_SCRUB=<frames a step>,<steps a second>` pauses and scrubs like the wheel, 40 steps
    /// forward and 20 back, round, for a minute (Subject Focus's scrub masks, `FRAMESCRUB_FOCUS_LOG=1`).
    private var scrubBenchStep = 0
    private func startScrubBench() {
        let parts = (ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_SCRUB"] ?? "").split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[1] > 0 else { return }
        let step = parts[0], interval = 1 / Double(parts[1])
        let requestedDuration = ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_SCRUB_SECONDS"].flatMap(Double.init)
        let duration = requestedDuration.flatMap { $0.isFinite && (1...60).contains($0) ? $0 : nil } ?? 60
        scrubBenchStep = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if !core.isPaused { core.pause() }
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
                let keepGoing = MainActor.assumeIsolated {
                    guard let self, self.scrubBenchStep < Int(duration / interval) else { return false }
                    self.core.scrub(by: self.scrubBenchStep % 60 < 40 ? step : -step, ticks: false)
                    self.scrubBenchStep += 1
                    return true
                }
                if !keepGoing { timer.invalidate() }
            }
        }
    }
    /// The style on screen; nil: off.
    var subjectFocus: SubjectFocusStyle? { videoView.subjectFocus }

    /// On in `style`, or off (nil), with its OSD line.
    func setSubjectFocus(_ style: SubjectFocusStyle?) {
        if let style { Self.subjectFocusStyle = style }
        videoView.setSubjectFocus(style)
        subjectFocusPanel?.refresh()
        let settings = SubjectFocusSettings.shared
        showMessage(style.map { "Subject Focus: \(settings.title(of: settings.choice(for: $0)))" } ?? "Subject Focus: off")
    }

    /// View › Subject Focus › Subject: All People / Main People, for every window.
    func setSubjectMainPeople(_ on: Bool) {
        SubjectFocusSettings.shared.mainPeople = on
        showMessage(on ? "Subject Focus: main people" : "Subject Focus: all people")
    }

    /// View › Subject Focus › Mask: RVM (the user's models) or Vision, for every window.
    func setSubjectMatting(_ rvm: Bool) {
        SubjectFocusSettings.shared.matting = rvm
        showMessage(rvm ? "Subject Focus mask: RVM" : "Subject Focus mask: Vision")
    }

    /// For Playback › Colour › Reset File / Folder Colour: whether there is anything to reset.
    func hasOwnColor(_ level: ColorLevel) -> Bool { colorMemory.hasOwn(level) }

    /// A file opened, failed or closed: the panel is there only while one is open, with the file's name and folder
    /// (its size and date follow the first picture, `readFileFacts`).
    private func statsFileChanged() {
        fileFacts = core.url.map {
            StatsFile(name: $0.lastPathComponent, folder: $0.deletingLastPathComponent().path, size: nil, modified: nil)
        }
        statsPanel.isAvailable = core.url != nil
        refreshStats()
    }

    /// The file's size and date, read off the main thread (a NAS can take a while); kept if the file is still open.
    private func readFileFacts(of url: URL) {
        Task { [weak self] in
            let facts = await Task.detached(priority: .utility) { StatsFile.read(url) }.value
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
        if let cut = virtualCut {
            guard cut.playback.pending == nil, cut.playback.failure == nil else { return }
            if isVirtualCutBench, let active = cut.playback.activeSpan, let index = core.index {
                let span = cut.playback.timeline.spans[active]
                let time = index.seconds(forPTS: frame.pts)
                let frameDuration = 1 / max(1, core.info?.frameRate ?? 30)
                let nextTime = index.isExact && frame.number + 1 < index.frameCount
                    ? index.seconds(forFrame: frame.number + 1) : time + frameDuration
                if nextTime <= span.sourceStart || time >= span.sourceEnd {
                    if cutBenchOutsideFrames == 0 {
                        print("virtual-cut: outside frame span=\(active) pts=\(time) next=\(nextTime) bounds=\(span.sourceStart)..<\(span.sourceEnd)")
                    }
                    cutBenchOutsideFrames += 1
                }
            }
            if cut.awaitingPicture != nil {
                guard frame.number == core.position else { return }
                cut.awaitingPicture = nil
                cut.retryPictureAfterIndex = nil
            }
            videoView.geometry = core.displayGeometry
        }
        // FRAMESCRUB_FOCUS=<style>: Subject Focus on with the first frame (self-tests and benches)
        if !Self.focusFromEnvironmentDone, let name = ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS"] {
            Self.focusFromEnvironmentDone = true
            if let style = SubjectFocusStyle(rawValue: name) { setSubjectFocus(style) }
            startScrubBench()
            switch ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_PANEL"] {   // benches, screenshots
            case "1": slots.toggleSubjectFocusPanel()
            case "bench": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.benchSubjectFocusPanel() }
            default: break
            }
        }
        if isVirtualCutBench, cutBenchRequest > cutBenchPresented, frame.number == core.position,
           let cut = virtualCut, cut.playback.pending == nil, let span = cut.playback.activeSpan {
            let request = cutBenchRequest, start = cutBenchStarted
            videoView.onBenchPresented = { [weak self] time in
                guard let self, cutBenchRequest == request, cutBenchPresented < request else { return }
                cutBenchPresented = request
                let stats = core.readCache?.stats
                print("virtual-cut: picture request=\(request) span=\(span) ms=\((time - start) * 1000) bytes=\(stats?.bytesFromFile ?? 0) hits=\(stats?.hits ?? 0)/\(stats?.requests ?? 0) reused-index=\(core.indexStatus == .reused)")
            }
        }
        if isVirtualCutBench, let active = virtualCut?.playback.activeSpan, cutBenchDecodedSpans.insert(active).inserted {
            let bytes = core.readCache?.stats.bytesFromFile ?? 0
            print("virtual-cut: decoded span=\(active) ms=\((CACurrentMediaTime() - cutBenchStarted) * 1000) bytes=\(bytes) reused-index=\(core.indexStatus == .reused)")
        }
        videoView.show(frame, playing: !core.isPaused)
        if let cut = virtualCut, cut.waitingForFirstPicture {
            // A video layer covered by Home may not obtain a drawable. Reveal once the picture is queued.
            cut.waitingForFirstPicture = false
            hideHome()
            window?.title = cut.cut.title + " — Virtual Cut"
            seekBar.setFilmRevealed(true, force: true)
            revealSeekBar()
            if cut.playback.wantsPlayback { core.play() }
        }
        if !diagnosticSweepStarted, ProcessInfo.processInfo.environment["FRAMESCRUB_DIAGNOSTIC_SWEEP"] == "1" {
            diagnosticSweepStarted = true
            if PlaybackDiagnostics.enabled, ProcessInfo.processInfo.environment["FRAMESCRUB_DIAGNOSTIC_4K"] == "1",
               let window {
                let scale = window.backingScaleFactor
                window.setContentSize(NSSize(width: 3840 / scale, height: 2160 / scale))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            core.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.diagnosticSweep(step: 0) }
        }
        // All-intra video has a keyframe on every tick. Only the bounded missing sample set triggers planning.
        if filmstripPrewarmFrames.contains(frame.number) {
            prewarmFilmstrip()
        }
        filmstripLoader?.resume()
        lastFrame = frame
        refreshLowLatency()
        checkSceneCut(frame)
        pushPluginState(force: false)
        recomputeAutoColorIfDue(frame)
    }

    func playerStateDidChange(_ player: PlayerCore) {
        virtualCut?.playback.update(sourceTime: core.currentSeconds)
        maybeWarmVirtualCut()
        if core.edgeDrag == nil, seekBar.isDraggingMark { seekBar.cancelMarkDrag() }
        videoView.updateFilmSeekPreview(position: core.position, paused: core.isPaused)
        if core.isPaused != wasPaused || (core.isPaused && pausedFilmstripPrewarmPosition != core.position) {
            prewarmFilmstrip()
        }
        filmstripLoader?.resume()
        videoView.diagnosticPlaybackChanged(playing: !core.isPaused)
        refreshLowLatency()
        pushPluginState(force: virtualCut == nil || core.isPaused != wasPaused)
        if core.isPaused != wasPaused {
            wasPaused = core.isPaused
            if wasPaused, virtualCut == nil { stashSession?.saveProgress() }
        }
        if seekBar.alphaValue > 0 { updateSeekBar() }
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

    /// `show-in-folder` (a double click, ↩, ⌘↑, File › Show in Folder): Home's Folders on the video's folder, the
    /// video selected, wherever it was opened from; Back from the video goes to that folder from now on.
    private func showInFolder() {
        guard let url = core.url, url.isFileURL else { showMessage("No video open"); return }
        returnTab = .folders
        folderReturn = (folder: folder(of: url), file: url)
        showHome(tab: .folders)
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
        if virtualCut != nil { return }
        guard core.config.playlistAutoadvance else { return }
        if let listPlaylist {
            if listPlaylist.next != nil {
                slots.videoChanged(cause: .autoadvance)
                openListItem(at: listPlaylist.currentIndex + 1, plays: true)
            }
            return
        }
        if followsStashQueue { stepStashQueue(1, plays: true); return }
        whenFolderRead { [weak self] in
            guard let self, let next = playlist?.neighbour(1, skipping: isUnreadable) else { return }
            slots.videoChanged(cause: .autoadvance)
            openFile(next, stepped: 1) { [weak self] outcome in   // a broken file is gone past by the open itself
                if outcome == .opened { self?.core.play() }
            }
        }
    }

    private func refreshLowLatency() {
        guard !isTerminating, !showsHome, window?.occlusionState.contains(.visible) == true,
              let frame = lastFrame, let index = core.index else { return }
        let start = index.seconds(forFrame: frame.number)
        let end = frame.number + 1 < index.frameCount ? index.seconds(forFrame: frame.number + 1) : start
        let candidate = core.cache.frame(frame.number + 1)
        let canInterpolate = candidate.map {
            LLPresentation.canInterpolate(frame: frame.number, next: $0.number, start: start, end: end,
                                          playing: !core.isPaused, speed: core.speed, direction: core.direction)
        } ?? false
        let settings = core.config.lowLatency.forPlayback(playing: !core.isPaused)
        videoView.lowLatency.noiseOnPause = core.config.lowLatency.noiseActive && !settings.noiseActive
        var noiseReferences: [TemporalNoiseReference] = []
        if settings.noiseActive {
            // M4 Max/macOS27.2 TNF query: one previous, two next frames. At most three retained references.
            for n in [frame.number - 1, frame.number + 1, frame.number + 2] where n >= 0 && n < index.frameCount {
                if let cached = core.cache.frame(n) {
                    noiseReferences.append(.init(frame: cached, seconds: index.seconds(forFrame: n)))
                }
            }
        }
        videoView.lowLatency.request(frame: frame, next: canInterpolate ? candidate : nil, start: start, end: end,
                                    settings: settings, ratio: videoView.displayRatio,
                                    rotation: videoView.rotationClockwise, noiseReferences: noiseReferences)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        showCursorAfterScrub()
        shutdown()
        // The app has exactly one player window; without it nothing can play, even if Settings is still open.
        // AppKit waits in a nested run loop for .terminateLater. Enter it from the run loop, not a main-queue
        // block: that block would prevent the main-actor persistence task from running and replying to AppKit.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    func windowDidChangeScreen(_ notification: Notification) { updateScreenPixelSize() }
    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResignKey(_ notification: Notification) {
        endHoldSpeed()   // the key-up goes elsewhere
        videoView.cancelFilmSeekPreview()
        seekBar.cancelInteraction()
        cancelMouseInput()   // and so may a button's release
        showCursorAfterScrub()
        updatePrecisionWheel()
    }
    private func updateViewingVisibility() {
        homeSource?.setWatchingVisible(showsHome && window?.isVisible == true && window?.isMiniaturized == false
                                      && window?.occlusionState.contains(.visible) == true)
        let visible = !isTerminating && !showsHome && failureView.isHidden && window?.isVisible == true
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        core.setViewingVisible(visible)
        updatePluginAnalysisPolling()
        if visible {
            refreshLowLatency()
            prewarmFilmstrip()
            filmstripLoader?.resume()
        } else {
            seekBar.cancelFilmDragMotion()
            videoView.cancelFilmSeekPreview()
            videoView.lowLatency.clear()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { updatePrecisionWheel(); updateViewingVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateStatsTimer(); seekBar.refreshVisibility(); updateViewingVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateStatsTimer(); updateViewingVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateStatsTimer(); updateViewingVisibility() }
    func windowDidEnterFullScreen(_ notification: Notification) {
        followFullScreenTitlebar(true)
        updatePrecisionWheel()
    }
    func windowWillExitFullScreen(_ notification: Notification) { followFullScreenTitlebar(false) }
    func windowDidExitFullScreen(_ notification: Notification) {
        // Home shown, full screen, back to the video, out of full screen: the video's window has its title bar again,
        // and its content (the back button, the OSD, the slots' tops) must start below it, not under it.
        if !showsHome { window?.styleMask.remove(.fullSizeContentView) }
        updatePrecisionWheel()
    }
    func windowDidResize(_ notification: Notification) {
        rememberFrame()
        if window?.inLiveResize != true { updatePrecisionWheel() }   // the video's rect (a live resize: at its end)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        updatePrecisionWheel()
        prewarmFilmstrip()
    }

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

extension PlayerWindowController {
    private func startVirtualCut(_ cut: VirtualCut, timeline: VirtualCutTimeline, key: String,
                                 catalog: (source: String, card: String)) {
        virtualCutReturn = nil
        leaveVirtualCut()
        stashOpens += 1
        queueGate.cancel()
        abandonOpening()
        dropListPlaylist()
        let session = VirtualCutSession(key: key, cut: cut, timeline: timeline)
        session.waitingForFirstPicture = showsHome
        resetPluginAnalysisSource()
        virtualCut = session
        virtualCutCatalogLocation = catalog
        aspectMode = .noCrop
        videoView.zoomPan.reset()
        seekBar.setCutTimeline(timeline)
        pushPluginState(force: true)
        if showsHome { showMessage("Opening virtual cut…") }
        let anchor = isVirtualCutBench ? nil : virtualCutAnchors[key]
        let time = anchor.map { timeline.resume(at: $0) } ?? 0
        if let request = session.playback.seek(time, playing: true) { moveVirtualCut(session, request) }
    }

    private func rememberVirtualCut() {
        guard !isVirtualCutBench, let session = virtualCut,
              let anchor = session.playback.timeline.anchor(at: session.playback.position),
              virtualCutAnchors[session.key] != anchor else { return }
        if virtualCutAnchors[session.key] == nil, virtualCutAnchors.count >= 128,
           let victim = virtualCutAnchors.keys.first { virtualCutAnchors.removeValue(forKey: victim) }
        virtualCutAnchors[session.key] = anchor
        if let data = try? JSONEncoder().encode(virtualCutAnchors) {
            UserDefaults.standard.set(data, forKey: "virtual-cut.resume")
        }
    }

    private func leaveVirtualCut() {
        guard virtualCut != nil else { return }
        rememberVirtualCut()
        virtualCut?.scrubOpen?.cancel()
        virtualCut?.stopWarming()
        virtualCut = nil
        virtualCutCatalogLocation = nil
        seekBar.setCutTimeline(nil)
        stashOpens += 1
        abandonOpening()
    }

    @discardableResult private func seekVirtualCut(to time: Double, continuous: Bool = false) -> Bool {
        guard let session = virtualCut else { return false }
        if let request = session.playback.seek(time, playing: session.playback.wantsPlayback) {
            let source = session.playback.timeline.spans[request.location.spanIndex].source
            if session.warm?.source != source { session.stopWarming() }
            if session.playback.shouldDeferOpen(request, continuous: continuous,
                                                loaded: session.loadedSource, opening: session.openingSource) {
                cancelVirtualSourceOpen(session)
                session.scrubOpen?.cancel()
                session.deferredScrub = request
                core.pause()   // keep play intent, but don't let the old source reach a join
                updateSeekBar()
                let work = DispatchWorkItem { [weak self, weak session] in
                    guard let self, let session, virtualCut === session,
                          session.deferredScrub == request else { return }
                    flushVirtualScrubOpen()
                }
                session.scrubOpen = work
                // A 12 ms cross-join burst used to open once per pulse on the 4K SMB bench.
                // Give a continuous gesture two 60 Hz frame periods; pointer-up flushes immediately.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33), execute: work)
            } else {
                moveVirtualCut(session, request)
            }
        }
        return true
    }

    private func flushVirtualScrubOpen() {
        guard !showsHome, let session = virtualCut, let request = session.deferredScrub,
              session.playback.pending == request else { return }
        moveVirtualCut(session, request)
    }

    private func cancelVirtualSourceOpen(_ session: VirtualCutSession) {
        guard session.openingSource != nil else { return }
        session.openingSource = nil
        session.openTicket = nil
        stashOpens += 1
        abandonOpening()
    }

    private func scrubVirtualCut(_ frames: Int) -> Bool {
        guard let session = virtualCut else { return false }
        session.playback.wantsPlayback = false
        core.pause()
        return seekVirtualCut(to: session.playback.position + Double(frames) / max(1, core.info?.frameRate ?? 30),
                              continuous: true)
    }

    private func advanceVirtualCut(_ direction: Int) {
        guard let session = virtualCut else { return }
        if let request = session.playback.advance(direction) { moveVirtualCut(session, request) }
        else { core.pause(); updateSeekBar() }
    }

    private func moveVirtualCut(_ session: VirtualCutSession, _ request: VirtualCutPlayback.Request) {
        session.scrubOpen?.cancel()
        session.scrubOpen = nil
        session.deferredScrub = nil
        session.awaitingPicture = nil
        session.retryPictureAfterIndex = nil
        if isVirtualCutBench {
            cutBenchRequest += 1
            cutBenchStarted = CACurrentMediaTime()
            videoView.onBenchPresented = nil
        }
        let span = session.playback.timeline.spans[request.location.spanIndex]
        if session.openingSource == span.source { updateSeekBar(); return } // the in-flight open uses the latest target
        cancelVirtualSourceOpen(session)
        if session.loadedSource == span.source, core.index != nil {
            finishVirtualCutMove(session, request)
            return
        }
        session.openingSource = span.source
        session.direction = core.direction
        core.pause()
        stashSession?.leave()
        if !session.waitingForFirstPicture { hideHome() }
        let ticket = UUID()
        session.openTicket = ticket
        let open: (URL, FileOrigin, PreparedOpen?, DecodedFrame?) -> Void = { [weak self, weak session] url, origin, prepared, landingFrame in
            guard let self, let session, virtualCut === session, session.openTicket == ticket,
                  let target = session.playback.pending else { return }
            let targetSpan = session.playback.timeline.spans[target.location.spanIndex]
            session.loadedSource = nil
            openFile(url, origin: origin, landing: LinkTarget(time: target.location.sourceTime),
                     virtualSource: span.source, virtualBounds: targetSpan.sourceStart..<targetSpan.sourceEnd,
                     warmed: prepared) { [weak self, weak session] outcome in
                guard let self, let session, virtualCut === session, session.openTicket == ticket,
                      let latest = session.playback.pending else { return }
                session.openingSource = nil
                switch outcome {
                case .opened:
                    session.loadedSource = span.source
                    finishVirtualCutMove(session, latest, reopened: true, landingFrame: landingFrame)
                case let .failed(failure):
                    failVirtualCutMove(session, latest, reason: failure.reason)
                case .superseded: break
                }
            }
        }
        if let warm = session.warm, warm.source == span.source, let prepared = warm.prepared,
           let url = warm.url, let origin = warm.origin {
            warm.preview?.stop()
            session.warm = nil
            if isVirtualCutBench { cutBenchWarmReused += 1 }
            open(url, origin, prepared, warm.landingFrame)
            return
        }
        session.stopWarming()
        switch span.source.kind {
        case .file:
            open(URL(filePath: span.source.locator), .plain, nil, nil)
        case .stream:
            if let url = URL(string: span.source.locator) { open(url, .plain, nil, nil) }
        case .scene:
            guard let stash = makeStashSession() else {
                failVirtualCutMove(session, request, reason: "Configure the scene server in Settings.")
                return
            }
            let scene = StashScene(id: span.source.locator, paths: [])
            stash.resolve(scene) { [weak self, weak session] result in
                guard let self, let session, virtualCut === session, session.openTicket == ticket,
                      let latest = session.playback.pending else { return }
                switch result {
                case let .file(url), let .stream(url):
                    stashScene = scene
                    open(url, .stash(sceneID: scene.id, hasQueue: false), nil, nil)
                case let .failed(failure):
                    failVirtualCutMove(session, latest, reason: failure.reason)
                }
            }
        }
    }

    private func finishVirtualCutMove(_ session: VirtualCutSession, _ request: VirtualCutPlayback.Request,
                                      reopened: Bool = false, landingFrame: DecodedFrame? = nil) {
        let span = session.playback.timeline.spans[request.location.spanIndex]
        guard let index = core.index, span.sourceStart < core.durationSeconds,
              span.sourceEnd <= core.durationSeconds + 1.0 / max(1, core.info?.frameRate ?? 30) else {
            failVirtualCutMove(session, request, reason: "The saved range is outside the source duration.")
            return
        }
        let previous = session.playback.activeSpan
        guard session.playback.opened(request) else { return }
        if reopened { session.awaitingPicture = request }
        if previous != session.playback.activeSpan { session.warmedForSpan = nil }
        core.virtualPlaybackBounds = span.sourceStart..<span.sourceEnd
        if reopened, core.direction != session.direction { core.reversePlaybackDirection() }
        let frame = min(index.frameNumber(forSeconds: request.location.sourceTime), index.frameNumber(before: span.sourceEnd))
        if let landingFrame, index.isExact, landingFrame.number == frame, landingFrame.pts == index.pts(forFrame: frame) {
            core.cache.insert(landingFrame)
            if isVirtualCutBench { cutBenchLandingHits += 1 }
        }
        core.seek(toFrame: frame)
        seekBar.filmstripSourceChanged()
        if session.playback.wantsPlayback && !showsHome && core.isPaused { core.play() }
        if !showsHome { window?.title = session.cut.title + " — Virtual Cut" }
        updateSeekBar()
    }

    private func failVirtualCutMove(_ session: VirtualCutSession, _ request: VirtualCutPlayback.Request, reason: String) {
        guard session.playback.failed(request) else { return }
        session.awaitingPicture = nil
        session.retryPictureAfterIndex = nil
        session.openingSource = nil
        session.loadedSource = nil
        core.pause()
        let number = request.location.spanIndex + 1
        if showsHome {
            showMessage("Fragment \(number) unavailable. \(reason) Open the card to retry.", duration: 8)
        } else {
            window?.title = session.cut.title + " — Virtual Cut"
            osd.show("Fragment \(number) unavailable. \(reason) Return to retry, › to skip.", duration: nil)
        }
        if isVirtualCutBench { print("virtual-cut: fragment \(number) unavailable: \(reason)") }
        updateSeekBar()
    }

    private func retryVirtualPictureWithExactIndex(_ index: FrameIndex) {
        guard let cut = virtualCut, let request = cut.retryPictureAfterIndex else { return }
        cut.retryPictureAfterIndex = nil
        guard cut.playback.pending == nil, cut.playback.failure == nil,
              cut.playback.activeSpan == request.location.spanIndex else { return }
        if cut.awaitingPicture == request {
            core.seek(toFrame: index.frameNumber(forSeconds: request.location.sourceTime))
            if cut.awaitingPicture == request, core.cache.isUndecodable(core.position) {
                failVirtualCutMove(cut, request, reason: "The first frame could not be decoded.")
                return
            }
        }
        if cut.playback.wantsPlayback && !showsHome { core.play() }
    }

    private func runVirtualCutCommand(_ command: Command) -> Bool {
        guard let session = virtualCut else { return false }
        switch command {
        case .cyclePause:
            session.playback.wantsPlayback.toggle()
            if session.playback.wantsPlayback {
                if session.playback.activeSpan != nil, session.playback.pending == nil { core.play() }
            } else { core.pause() }
            updateTransport()
        case let .seek(delta, _):
            _ = seekVirtualCut(to: session.playback.position + delta)
        case .playlistNext, .markNext:
            advanceVirtualCut(1)
        case .playlistPrev, .markPrev:
            advanceVirtualCut(-1)
        case .frameStep, .frameBackStep:
            let step = command == .frameStep ? 1 : -1
            if let index = core.index, let current = session.playback.activeSpan, session.playback.pending == nil {
                let span = session.playback.timeline.spans[current]
                let target = core.position + step
                if target >= index.frameCount || target < 0 ||
                    index.seconds(forFrame: target) >= span.sourceEnd || index.seconds(forFrame: target) < span.sourceStart {
                    session.playback.wantsPlayback = false
                    core.pause()
                    advanceVirtualCut(step)
                } else {
                    session.playback.wantsPlayback = false
                    core.perform(command)
                }
            }
        case .deleteFile, .saveClip, .exportRange, .markDelete, .markClear, .markSnap, .markIn, .markOut, .markLoop, .playMarks:
            showMessage("Open the original to use this action.")
        case .abLoop:
            session.playback.loops.toggle()
            showMessage(session.playback.loops ? "Loop cut: On" : "Loop cut: Off")
        default:
            return false
        }
        return true
    }
}

extension PlayerWindowController {
    private func removePluginCatalog(_ page: Int) {
        guard let old = pluginCatalogs.removeValue(forKey: page) else { return }
        if virtualCutReturn?.catalog.source == old.locationID { seekBar.setCutEdges(nil) }
        old.stop()
        refreshPluginCatalogs()
    }

    private func refreshPluginCatalogs() {
        homeSource?.catalogs = Dictionary(uniqueKeysWithValues: pluginCatalogs.values.map { ($0.locationID, $0) })
        if let browser = home?.browser, case let .source(id) = browser.location, id.hasPrefix("plugin-cut:") {
            if homeSource?.catalogs[id] == nil { browser.show(.source(HomeRecent.source), selecting: nil) }
            else if showsHome { browser.reload() }
        }
        home?.reloadSidebar()
    }

    private func chooseCatalogCut(_ catalog: PluginCatalogSource, id: String, edit: Bool) {
        catalogOpen?.cancel()
        guard pluginCatalogs[catalog.page] === catalog else { return }
        if edit {
            guard let page = slots.page(withToken: catalog.page) else { return }
            virtualCutReturn = nil
            if virtualCut != nil {
                leaveVirtualCut()
                closeCore()
                videoView.clear(blank: true)
            }
            hideHome()
            slots.focus(page: page)
            page.dispatch(.editVirtualCut(id: id))
            return
        }
        catalogOpen = Task { [weak self, weak catalog] in
            guard let catalog else { return }
            do {
                let (cut, timeline) = try await catalog.cut(id)
                try Task.checkCancellation()
                guard let self, pluginCatalogs[catalog.page] === catalog, showsHome,
                      home?.browser.location == .source(catalog.locationID) else { return }
                if let reason = catalogCutRefusal(cut, catalog: catalog) {
                    showMessage(reason, duration: 5)
                    return
                }
                if let page = slots.page(withToken: catalog.page) { slots.hide(page: page) }
                startVirtualCut(cut, timeline: timeline, key: catalog.locationID + "/" + id, catalog: (catalog.locationID, id))
            } catch {
                guard !Task.isCancelled, let self, showsHome else { return }
                showMessage(error.localizedDescription, duration: 5)
            }
        }
    }

    private func catalogForCut(_ location: String) -> PluginCatalogSource? {
        pluginCatalogs.values.first { $0.locationID == location }
    }

    private func catalogCutRefusal(_ cut: VirtualCut, catalog: PluginCatalogSource) -> String? {
        let files = cut.ranges.filter { $0.source.kind == .file }.map { URL(filePath: $0.source.locator) }
        if !files.isEmpty, pluginPolicy.decision(forOpening: files, from: catalog.origin) != .allowed {
            return "Allow this plugin to open local videos before playing this cut."
        }
        if cut.ranges.contains(where: { range in
            range.source.kind == .stream && URL(string: range.source.locator).map(isStashURL) == true
        }) {
            return "Use scene IDs for media from the configured server."
        }
        return nil
    }

    private func selectVirtualCutFragment(_ span: Int) {
        guard let session = virtualCut, let location = virtualCutCatalogLocation,
              let catalog = catalogForCut(location.source), let page = slots.page(withToken: catalog.page),
              let anchor = session.playback.timeline.editAnchor(span: span, currentTime: session.playback.position) else {
            showMessage("The cut editor is unavailable.")
            return
        }
        session.playback.wantsPlayback = false
        core.pause()
        slots.focus(page: page)
        page.dispatch(.editVirtualCut(id: location.card, rangeID: anchor.rangeID))
    }

    private func openVirtualCutOriginal(rangeID: String?, request: PluginRequest, origin: PluginOrigin) {
        let previous = virtualCutReturn
        guard let session = virtualCut ?? previous?.session,
              let location = virtualCutCatalogLocation ?? previous?.catalog,
              let catalog = catalogForCut(location.source), catalog.page == request.page, catalog.origin == origin,
              session.playback.pending == nil else {
            pluginFailed(request, "No cut from this editor is available.")
            return
        }
        let timeline = session.playback.timeline
        let time = previous?.time ?? session.playback.position
        let anchor = rangeID.map { timeline.editAnchor(rangeID: $0, currentTime: time) } ?? timeline.anchor(at: time)
        guard let anchor, let range = session.cut.ranges.first(where: { $0.id == anchor.rangeID }) else {
            pluginFailed(request, "This fragment is no longer in the open cut.")
            return
        }
        let context = CutEditContext(session: session, catalog: location, anchor: anchor,
                                     source: range.source, time: timeline.resume(at: anchor))
        leaveVirtualCut()
        seekBar.setCutEdges(nil)
        core.pause()
        virtualCutReturn = context
        catalogOpen?.cancel()
        stashOpens += 1
        abandonOpening()
        let open: (URL, FileOrigin) -> Void = { [weak self] url, origin in
            guard let self else { return }
            guard virtualCutReturn?.token == context.token else {
                pluginFailed(request, "Opening the original was superseded.")
                return
            }
            openFile(url, origin: origin, landing: LinkTarget(time: anchor.sourceTime),
                     contextVersion: range.source.version) { [weak self] outcome in
                guard let self else { return }
                if outcome == .opened, virtualCutReturn?.token == context.token {
                    core.pause()
                    virtualCutReturn?.originalReady = true
                    pluginDone(request)
                } else if case let .failed(failure) = outcome {
                    pluginFailed(request, failure.reason)
                } else {
                    pluginFailed(request, "Opening the original was superseded.")
                }
            }
        }
        switch range.source.kind {
        case .file:
            open(URL(filePath: range.source.locator), .plain)
        case .stream:
            if let url = URL(string: range.source.locator) { open(url, .plain) }
            else { pluginFailed(request, "The original stream URL is invalid.") }
        case .scene:
            guard let stash = makeStashSession() else {
                pluginFailed(request, "Configure the scene server in Settings.")
                return
            }
            let scene = StashScene(id: range.source.locator, paths: [])
            stash.resolve(scene) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .file(url), let .stream(url):
                    if virtualCutReturn?.token == context.token { stashScene = scene }
                    open(url, .stash(sceneID: scene.id, hasQueue: false))
                case let .failed(failure):
                    pluginFailed(request, failure.reason)
                }
            }
        }
    }

    private func returnToVirtualCut(revision: String?, request: PluginRequest, origin: PluginOrigin) {
        guard virtualCut == nil, let context = virtualCutReturn,
              let catalog = catalogForCut(context.catalog.source), catalog.page == request.page, catalog.origin == origin else {
            pluginFailed(request, "There is no original context to return from.")
            return
        }
        guard let revision, revision != context.session.cut.revision else {
            restoreVirtualCut(context.session, context: context)
            pluginDone(request)
            return
        }
        catalogOpen?.cancel()
        catalogOpen = Task { [weak self, weak catalog] in
            guard let self, let catalog else { return }
            do {
                let (cut, timeline) = try await catalog.cut(context.catalog.card)
                try Task.checkCancellation()
                guard virtualCutReturn?.token == context.token, pluginCatalogs[catalog.page] === catalog else {
                    pluginFailed(request, "Returning to the cut was superseded.")
                    return
                }
                guard cut.revision == revision else {
                    pluginFailed(request, "The cut changed again. Reload the editor and try returning.")
                    return
                }
                if let reason = catalogCutRefusal(cut, catalog: catalog) {
                    pluginFailed(request, reason)
                    return
                }
                let session = VirtualCutSession(key: context.session.key, cut: cut, timeline: timeline)
                session.playback.loops = context.session.playback.loops
                restoreVirtualCut(session, context: context)
                pluginDone(request)
            } catch {
                pluginFailed(request, Task.isCancelled ? "Returning to the cut was superseded." : error.localizedDescription)
            }
        }
    }

    private func restoreVirtualCut(_ session: VirtualCutSession, context: CutEditContext) {
        seekBar.setCutEdges(nil)
        virtualCutReturn = nil
        if let catalog = catalogForCut(context.catalog.source), let page = slots.page(withToken: catalog.page) {
            slots.hide(page: page)
        }
        session.loadedSource = nil
        virtualCutCatalogLocation = context.catalog
        resetPluginAnalysisSource()
        virtualCut = session
        aspectMode = .noCrop
        videoView.zoomPan.reset()
        seekBar.setCutTimeline(session.playback.timeline)
        pushPluginState(force: true)
        let timeline = session.playback.timeline
        let sameSource = session.cut.ranges.contains { $0.id == context.anchor.rangeID && $0.source == context.source }
        let time = sameSource ? timeline.resume(at: context.anchor, fallback: context.time) : min(context.time, timeline.duration)
        if let request = session.playback.seek(time, playing: false) { moveVirtualCut(session, request) }
    }
}

extension PlayerWindowController {
    private func maybeWarmVirtualCut() {
        guard let session = virtualCut, let active = session.playback.activeSpan,
              session.playback.pending == nil, session.playback.failure == nil, !showsHome,
              window?.occlusionState.contains(.visible) == true, core.allowsBackgroundPreview else { return }
        if let warm = session.warm {
            prepareUpcomingCutSource(session, warm: warm)
            requestUpcomingCutPoster(session)
            return
        }
        guard session.warmedForSpan != active else { return }
        let spans = session.playback.timeline.spans
        let next = active + core.direction
        guard spans.indices.contains(next), spans[next].source != session.loadedSource else { return }
        let span = spans[active]
        let remaining = core.direction > 0 ? span.cutEnd - session.playback.position : session.playback.position - span.cutStart
        guard core.isPaused || remaining < 4 else { return }
        session.warmedForSpan = active
        let source = spans[next].source
        let warm = VirtualCutSession.Warm(source: source, span: next)
        session.warm = warm
        let prepare: (URL, FileOrigin) -> Void = { [weak self, weak session, weak warm] url, origin in
            guard let self, let session, let warm, virtualCut === session, session.warm === warm else { return }
            warm.url = url
            warm.origin = origin
            prepareUpcomingCutSource(session, warm: warm)
        }
        switch source.kind {
        case .file:
            prepare(URL(filePath: source.locator), .plain)
        case .stream:
            if let url = URL(string: source.locator) { prepare(url, .plain) }
        case .scene:
            guard let stash = makeStashSession() else { return }
            stash.resolve(StashScene(id: source.locator, paths: []), mountAllowed: false) { result in
                switch result {
                case let .file(url), let .stream(url):
                    prepare(url, .stash(sceneID: source.locator, hasQueue: false))
                case .failed:
                    break
                }
            }
        }
    }

    private func prepareUpcomingCutSource(_ session: VirtualCutSession, warm: VirtualCutSession.Warm) {
        guard let url = warm.url, !warm.preparationStarted, !showsHome, core.allowsBackgroundPreview,
              window?.occlusionState.contains(.visible) == true else { return }
        warm.preparationStarted = true
        if isVirtualCutBench { cutBenchWarmStarts += 1 }
        let read = core.preparation(for: url, cancellation: warm.cancellation, expectedVersion: warm.source.version)
        Task { [weak self, weak session, weak warm] in
            let prepared: PreparedOpen? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: try? read())
                }
            }
            guard let self, let session, let warm, virtualCut === session, session.warm === warm else {
                prepared?.discard()
                return
            }
            warm.prepared = prepared
            requestUpcomingCutPoster(session)
        }
    }

    private func requestUpcomingCutPoster(_ session: VirtualCutSession) {
        guard let warm = session.warm, !warm.previewRequested, let prepared = warm.prepared,
              !showsHome, !seekBar.isThumbnailInteraction, filmstripLoader?.isReading != true,
              window?.occlusionState.contains(.visible) == true, core.allowsBackgroundPreview else { return }
        let index = session.reusedIndex(for: warm.source)
        let wantsPoster = !seekBar.hasCutPoster(warm.span) && seekBar.showsFilmstrip && seekBar.alphaValue > 0.01
        guard wantsPoster || index != nil else { return }
        let span = session.playback.timeline.spans[warm.span]
        let provider = prepared.makeCutPreview(widthPixels: Int(160 * (window?.backingScaleFactor ?? 2)), landingIndex: index)
        warm.previewRequested = true
        warm.preview = provider
        provider.onImage = { [weak self, weak warm] result in
            guard let self, let warm, virtualCut?.warm === warm else { return }
            if wantsPoster { seekBar.setCutPoster(result.image, span: warm.span) }
            if let frame = result.sourceFrame, frame.byteSize <= 32 << 20 { warm.landingFrame = frame }
        }
        provider.onRequestFinished = { [weak self, weak warm] in
            guard let self, let warm, virtualCut?.warm === warm else { return }
            warm.preview?.stop()
            warm.preview = nil
            filmstripLoader?.resume()
        }
        let seconds: Double
        if index == nil { seconds = span.sourceStart + (span.sourceEnd - span.sourceStart) / 2 }
        else { seconds = core.direction > 0 ? span.sourceStart : span.sourceEnd.nextDown }
        provider.request(seconds: seconds, speculative: true)
    }
}

extension PlayerWindowController {
    /// Run with a configured provider and a short cut containing at least two different sources.
    func runVirtualCutBench(card: String) {
        Task { @MainActor [weak self] in
            guard let self else { exit(1) }
            @MainActor func wait(timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if condition() { return true }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                return false
            }
            func fail(_ message: String) -> Never {
                print("virtual-cut: \(message)")
                exit(1)
            }
            func clickAnalysisMarker(at time: Double, id: String? = nil) {
                guard let window, let view = seekBar.superview, let point = seekBar.analysisMarkerPoint(at: time, id: id),
                      seekBar.hitTest(view.convert(point, from: nil)) === seekBar,
                      let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    fail("analysis marker missing")
                }
                seekBar.mouseDown(with: click)
            }
            isVirtualCutBench = true
            window?.orderFrontRegardless()
            if ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "whole-cut" {
                NSApp.activate()
                window?.makeKeyAndOrderFront(nil)
            }
            if ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "analysis-provider" {
                guard await wait(timeout: 150, {
                    seekBar.analysisTimeline?.fragments.contains(where: { !$0.refined }) == true
                }), let timeline = seekBar.analysisTimeline,
                   let first = timeline.fragments.first(where: { !$0.refined && $0.range.lowerBound < core.durationSeconds }) else {
                    fail("provider did not publish a provisional marker")
                }
                revealSeekBar()
                guard await wait({ seekBar.alphaValue > 0.01 }) else { fail("analysis timeline did not become visible") }
                window?.layoutIfNeeded()
                let end = min(first.range.upperBound, core.durationSeconds)
                clickAnalysisMarker(at: first.range.lowerBound + (end - first.range.lowerBound) / 2, id: first.id)
                guard await wait({
                    core.isPaused && abs(core.currentSeconds - first.range.lowerBound) < 0.15 &&
                    core.displayedFrame == core.position
                }) else { fail("provider provisional marker did not land on the displayed source frame") }
                print("analysis-provider: provisional marker landed at \(core.currentSeconds)")
                guard await wait(timeout: 150, {
                    guard let current = seekBar.analysisTimeline, current.jobID == timeline.jobID,
                          !current.fragments.isEmpty else { return false }
                    return current.fragments.allSatisfy(\.refined)
                }) else { fail("provider did not replace the provisional results with refined markers") }
                print("analysis-provider: refined publication reached the real timeline")
                exit(0)
            }
            if ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "analysis-timeline" {
                guard await wait({ pluginAnalysisSourceID != nil && slots.pages.contains { $0.pageSource == .settings } }),
                      let sourceID = pluginAnalysisSourceID, let page = slots.pages.first(where: { $0.pageSource == .settings }),
                      let url = page.url, let origin = PluginOrigin(url: url), let window, core.durationSeconds >= 5 else {
                    fail("analysis benchmark requires a configured plugin and a local video at least five seconds long")
                }
                func publish(_ id: String, snapshot: [String: Any]?, from publisher: PluginOrigin? = nil) {
                    let message = PluginMessage(json: ["cmd": "analysisTimeline", "sourceID": id,
                                                       "snapshot": snapshot as Any? ?? NSNull()])!
                    pluginMessage(PluginRequest(page: page.token, message: message), from: publisher ?? origin)
                }
                let snapshot: [String: Any] = [
                    "jobID": "benchmark", "covered": [[0, 1.5], [2.5, 4.5]],
                    "fragments": [["id": "first", "start": 1, "end": 2, "refined": false],
                                  ["id": "second", "start": 3, "end": 4, "refined": true]],
                ]
                revealSeekBar()
                publish("old-source", snapshot: snapshot)
                publish(sourceID, snapshot: snapshot, from: PluginOrigin(string: "https://unconfigured.invalid")!)
                guard seekBar.analysisMarkerPoint(at: 1.5) == nil else { fail("stale analysis was shown") }
                for id in 1...2 {
                    let request = PluginRequest(id: id, page: page.token, message: .analysisSourceVersion(sourceID: sourceID))
                    pluginMessage(request, from: origin)
                }
                guard pluginAnalysisVersionInFlight, pluginAnalysisVersionWaiters.count == 2,
                      await wait({ pluginAnalysisVersion != nil }),
                      pluginAnalysisVersion?.utf8.count == 16, pluginAnalysisVersionWaiters.isEmpty else {
                    fail("analysis version requests did not share a successful read")
                }
                let oldSegments = core.segmentsSeconds
                let originalCallback = seekBar.onAnalysisFragment
                var clicked: [String] = []
                seekBar.onAnalysisFragment = { fragment in
                    clicked.append(fragment.id)
                    originalCallback?(fragment)
                }
                for round in 1...3 {
                    seekBar.setFilmRevealed(round != 1, force: true)
                    let cpu = StartupTrace.threadCPU()
                    publish(sourceID, snapshot: snapshot)
                    window.layoutIfNeeded()
                    window.displayIfNeeded()
                    print("analysis-timeline: publish round \(round) CPU \(StartupTrace.threadCPU() - cpu) ms")
                    for time in [1.5, 3.5] { clickAnalysisMarker(at: time) }
                    guard clicked.suffix(2).elementsEqual(["first", "second"]), core.segmentsSeconds == oldSegments else {
                        fail("analysis marker click or segment independence failed")
                    }
                    clicked.removeAll()
                    publish(sourceID, snapshot: nil)
                    guard seekBar.analysisMarkerPoint(at: 1.5) == nil else { fail("clearing analysis left a marker") }
                }
                publish(sourceID, snapshot: snapshot)
                page.onPageReplaced?()
                guard seekBar.analysisMarkerPoint(at: 1.5) == nil else { fail("replacing the owning page left its analysis visible") }
                let step = core.durationSeconds / 2_000
                let starts = (0..<2_000).map { Double($0) * step }
                let denseSnapshot: [String: Any] = [
                    "jobID": "benchmark", "covered": starts.map { [$0, $0 + step / 2] },
                    "fragments": starts.enumerated().map { ["id": "\($0.offset)", "start": $0.element,
                                                           "end": $0.element + step / 2, "refined": $0.offset.isMultiple(of: 2)] },
                ]
                let cpu = StartupTrace.threadCPU()
                publish(sourceID, snapshot: denseSnapshot)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                print("analysis-timeline: publish 2,000 intervals and markers CPU \(StartupTrace.threadCPU() - cpu) ms")
                closeCore()
                guard pluginAnalysisSourceID == nil, seekBar.analysisMarkerPoint(at: 1.5) == nil else {
                    fail("closing the source left its analysis active")
                }
                print("analysis-timeline: source and origin scope, version coalescing, both marker clicks, clear, page replacement and close passed")
                exit(0)
            }
            guard await wait({ !pluginCatalogs.isEmpty }), let catalog = pluginCatalogs.values.first,
                  let browser = home?.browser else { fail("catalog not registered") }
            let location = BrowserLocation.source(catalog.locationID)
            if ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "catalog" {
                browser.show(location, selecting: nil)
                guard await wait({ (catalog.lastListing?.entries.count ?? 0) >= 100 }),
                      let entries = catalog.lastListing?.entries else { fail("catalog needs 100 cards") }
                hideHome()
                catalog.stop()
                let ids = entries.map(\.id)
                for offset in [0, 32, 64] {
                    // End the previous batch's subscription while preserving the cached images.
                    catalog.stop()
                    let batch = Array(ids.dropFirst(offset).prefix(32))
                    var delivered = Set<String>()
                    let start = ProcessInfo.processInfo.systemUptime
                    catalog.want(batch) { id, _ in delivered.insert(id) }
                    let warm = delivered.count
                    guard await wait({ delivered.count == batch.count }) else {
                        fail("preview batch \(offset) incomplete (\(delivered.count)/\(batch.count))")
                    }
                    print("virtual-cut: previews batch=\(offset) hits=\(warm)/\(batch.count) ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
                }
                // Immediate responses are decoded images already in the Mac cache. Do not
                // let a refill alter the cache between the two probes.
                for offset in [0, 64] {
                    catalog.stop()
                    var warm = Set<String>()
                    catalog.want(Array(ids.dropFirst(offset).prefix(32))) { id, _ in warm.insert(id) }
                    catalog.stop()
                    print("virtual-cut: revisit previews batch=\(offset) immediate hits=\(warm.count)/32")
                }
                exit(0)
            }
            for round in 1...3 {
                browser.show(.source(HomeRecent.source), selecting: nil)
                let cpu = StartupTrace.threadCPU()
                browser.show(location, selecting: card)
                window?.layoutIfNeeded()
                window?.displayIfNeeded()
                let elapsed = StartupTrace.threadCPU() - cpu
                print("virtual-cut: File View round \(round) CPU \(elapsed) ms")
                guard await wait({ catalog.lastListing?.entries.contains(where: { $0.id == card }) == true }) else {
                    fail("card not listed")
                }
            }
            let measureCache = ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "playback"
            let checkPresentation = ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "presentation"
            let checkWholeCut = ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "whole-cut"
            let originalWindowFrame = window?.frame
            let began = ProcessInfo.processInfo.systemUptime
            chooseCatalogCut(catalog, id: card, edit: false)
            if checkPresentation {
                guard await wait({ virtualCut != nil }), showsHome else {
                    fail("catalog disappeared before the cut had a picture")
                }
            }
            guard await wait({ virtualCut?.playback.activeSpan == 0 || virtualCut?.playback.failure != nil }),
                  let cut = virtualCut, cut.playback.failure == nil else { fail("first source did not open") }
            print("virtual-cut: first source wall \((ProcessInfo.processInfo.systemUptime - began) * 1_000) ms")
            guard cut.playback.timeline.spans.count > 1 else { fail("benchmark needs multiple spans") }
            let benchMode = ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"]
            if benchMode == "film-join" {
                guard await wait({ !showsHome }), let window else { fail("cut did not open") }
                cut.playback.wantsPlayback = false
                core.pause()
                let join = cut.playback.timeline.spans[1].cutStart
                let from = join - 0.7
                let to = join + 0.7
                _ = seekVirtualCut(to: from)
                guard await wait({ cut.playback.activeSpan == 0 && cut.playback.pending == nil }),
                      abs(cut.playback.position - from) < 0.12 else { fail("could not prepare film drag") }
                seekBar.setFilmRevealed(true, force: true)
                revealSeekBar()
                window.layoutIfNeeded()
                guard let (start, end) = seekBar.cutFilmDragPoints(from: from, to: to) else {
                    fail("cut film could not project drag")
                }
                let timestamp = ProcessInfo.processInfo.systemUptime
                @MainActor func pointer(_ type: NSEvent.EventType, _ point: NSPoint, _ elapsed: Double) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.option],
                        timestamp: timestamp + elapsed, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                seekBar.mouseDown(with: pointer(.leftMouseDown, start, 0))
                seekBar.mouseDragged(with: pointer(.leftMouseDragged, end, 0.016))
                guard seekBar.isContinuousSeek, cut.deferredScrub?.location.spanIndex == 1 else {
                    fail("film drag did not queue the cross-source target")
                }
                seekBar.mouseUp(with: pointer(.leftMouseUp, end, 0.032))
                guard !seekBar.isContinuousSeek, cut.deferredScrub == nil,
                      await wait({ cut.playback.activeSpan == 1 && cut.playback.pending == nil &&
                                   core.displayedFrame == core.position }),
                      abs(cut.playback.position - to) < 0.12 else {
                    fail("film drag did not display the target source after release")
                }
                print("virtual-cut: film drag coalesced and flushed across a source join")
                exit(0)
            }
            if benchMode == "fragment-context" || benchMode == "fragment-edge" {
                guard await wait({ !showsHome }) else { fail("cut did not open") }
                guard let window, let point = seekBar.cutMarkerPoint(for: 1),
                      let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    fail("second fragment has no visible marker")
                }
                seekBar.mouseDown(with: click)
                guard await wait({
                    virtualCut == nil && virtualCutReturn?.anchor.rangeID == "range-1" &&
                    openingURL == nil && core.virtualPlaybackBounds == nil && core.url != nil
                }), abs(core.currentSeconds - 2) < 0.12, core.isPaused else {
                    fail("editor did not open the selected source on the expected frame")
                }
                if benchMode == "fragment-edge" {
                    guard await wait({ seekBar.cutEdgePoint(for: .start) != nil }) else {
                        fail("original context did not expose the selected boundary")
                    }
                    func edgeMouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    }
                    for cancel in [true, false] {
                        guard let handle = seekBar.cutEdgePoint(for: .start) else { fail("boundary disappeared") }
                        let target = NSPoint(x: handle.x + (cancel ? 28 : 56), y: handle.y)
                        seekBar.mouseDown(with: edgeMouse(.leftMouseDown, handle))
                        seekBar.mouseDragged(with: edgeMouse(.leftMouseDragged, target))
                        guard core.currentSeconds > 2.02 else { fail("drag did not preview a later source frame") }
                        if cancel, !seekBar.cancelCutEdgeGesture() { fail("edge could not be cancelled") }
                        seekBar.mouseUp(with: edgeMouse(.leftMouseUp, target))
                    }
                }
                guard await wait({
                    virtualCut?.cut.revision == "second" && virtualCut?.playback.activeSpan == 0 &&
                    virtualCut?.playback.pending == nil && core.displayedFrame == core.position
                }), let returned = virtualCut,
                      abs(returned.playback.position - (benchMode == "fragment-edge" ? 0 : 0.75)) < 0.12,
                      core.isPaused else {
                    fail("return did not load the revised cut at the same source frame")
                }
                print("virtual-cut: fragment context opened and revision returned to the same source frame")
                exit(0)
            }
            if ProcessInfo.processInfo.environment["FRAMESCRUB_CUT_CACHE_BENCH"] == "fragment-info" {
                guard await wait({ !showsHome }) else { fail("cut did not open") }
                hover(0.1)
                guard await wait({ !previewView.isHidden }) else { fail("no fragment information over the cut timeline") }
                hover(nil)
                guard previewView.isHidden else { fail("fragment information did not close") }
                print("virtual-cut: fragment information appears and closes")
                exit(0)
            }
            if checkWholeCut {
                for span in cut.playback.timeline.spans.indices {
                    guard await wait({
                        cut.playback.failure != nil ||
                        cutBenchDecodedSpans.contains(span)
                    }), cut.playback.failure == nil else {
                        print("virtual-cut: stalled span=\(String(describing: cut.playback.activeSpan)) target=\(cut.playback.position) core=\(core.positionSeconds) paused=\(core.isPaused) index=\(core.indexStatus.text)")
                        fail("did not present span \(span + 1)")
                    }
                }
                guard await wait({ !cut.playback.wantsPlayback }), cut.playback.failure == nil,
                      cut.playback.activeSpan == cut.playback.timeline.spans.indices.last,
                      cutBenchOutsideFrames == 0 else {
                    print("virtual-cut: end time=\(cut.playback.position) playing=\(cut.playback.wantsPlayback) outside=\(cutBenchOutsideFrames) early posters=\(cutBenchEarlyPosters.count)")
                    fail("cut did not finish cleanly")
                }
                print("virtual-cut: all \(cut.playback.timeline.spans.count) spans reached the renderer and playback stopped; early posters=\(cutBenchEarlyPosters.count) landing hits=\(cutBenchLandingHits)")
                exit(0)
            }
            if checkPresentation {
                guard await wait({ cutBenchPresented >= 1 }), !showsHome else { fail("first cut picture not presented") }
                guard seekBar.accessibilityLabel() == "Virtual cut timeline" else { fail("cut timeline is not identified") }
            }
            if measureCache {
                guard await wait({ cutBenchPresented >= 1 }) else { fail("first source not presented") }
                removePluginCatalog(catalog.page)
            }
            let crossing = ProcessInfo.processInfo.systemUptime
            guard await wait({ cut.playback.activeSpan == 1 || cut.playback.failure != nil }),
                  cut.playback.failure == nil else { fail("playback did not cross the join") }
            print("virtual-cut: crossed join after \((ProcessInfo.processInfo.systemUptime - crossing) * 1_000) ms")
            if let boundary = virtualCutBenchBoundary {
                print("virtual-cut: boundary to source ready \((ProcessInfo.processInfo.systemUptime - boundary) * 1_000) ms")
            }
            if checkPresentation {
                guard await wait({ cutBenchPresented >= 2 }), window?.frame == originalWindowFrame else {
                    fail("second cut picture not presented in the original window frame")
                }
                guard videoView.zoomPan.isAtFit else { fail("cut picture is zoomed") }
                guard await wait({ seekBar.hasCutPoster(0) && seekBar.hasCutPoster(1) }) else {
                    fail("filmstrip lost a source's thumbnail at the join")
                }
                print("virtual-cut: both fragments have thumbnails in the same window")
                if cut.playback.wantsPlayback {
                    _ = seekVirtualCut(to: cut.playback.timeline.duration - 0.25)
                    guard await wait({ !cut.playback.wantsPlayback }) else { fail("cut did not stop at its end") }
                }
                guard cutBenchOutsideFrames == 0, cut.playback.activeSpan == 1 else {
                    fail("played frames outside the saved spans or looped without being asked")
                }
            }
            if measureCache {
                guard await wait({ cutBenchPresented == cutBenchRequest }),
                      pluginCatalogs[catalog.page] == nil else { fail("join did not play without the catalog") }
                print("virtual-cut: native join played while plugin catalog was unregistered")
            }
            cut.playback.wantsPlayback = false
            core.pause()
            _ = seekVirtualCut(to: 0.25)
            guard await wait({ cut.playback.activeSpan == 0 && cut.playback.pending == nil }),
                  cut.playback.failure == nil else { fail("seek back across join failed") }
            if measureCache {
                let join = cut.playback.timeline.spans[1].cutStart
                guard await wait({ cutBenchPresented == cutBenchRequest }) else { fail("A return was not presented") }
                for time in [join + 0.2, 0.25, join + 0.3, 0.35] {
                    _ = seekVirtualCut(to: time)
                    let request = cutBenchRequest
                    guard await wait({ cutBenchPresented == request || cut.playback.failure != nil }),
                          cut.playback.failure == nil else { fail("settled seek was not presented") }
                }
                let beforeBurst = cutBenchOpenStarts
                for n in 0..<20 {
                    _ = seekVirtualCut(to: (n.isMultiple(of: 2) ? join : 0) + 0.4 + Double(n) * 0.03, continuous: true)
                    try? await Task.sleep(for: .milliseconds(12))
                }
                let request = cutBenchRequest
                guard await wait({ cutBenchPresented == request || cut.playback.failure != nil }),
                      cut.playback.activeSpan == 0, cut.playback.failure == nil else { fail("latest rapid seek did not win") }
                print("virtual-cut: 20 rapid seeks settled, burst opens=\(cutBenchOpenStarts - beforeBurst), total opens=\(cutBenchOpenStarts), superseded opens=\(cutBenchSuperseded), warm reused=\(cutBenchWarmReused)/\(cutBenchWarmStarts)")
                let beforeCross = cutBenchOpenStarts
                for n in 0..<21 {
                    _ = seekVirtualCut(to: (n.isMultiple(of: 2) ? join : 0) + 0.2 + Double(n) * 0.025, continuous: true)
                    try? await Task.sleep(for: .milliseconds(12))
                }
                flushVirtualScrubOpen()  // pointer-up
                let finalRequest = cutBenchRequest
                guard await wait({ cutBenchPresented == finalRequest || cut.playback.failure != nil }),
                      cut.playback.activeSpan == 1, cut.playback.failure == nil else { fail("cross-source release did not win") }
                print("virtual-cut: 21 rapid seeks and release, burst opens=\(cutBenchOpenStarts - beforeCross)")
                pluginCatalogs[catalog.page] = catalog
                refreshPluginCatalogs()
            }
            showHome()
            guard browser.location == location else { fail("did not return to File View catalog") }
            print("virtual-cut: passed")
            exit(0)
        }
    }
}
