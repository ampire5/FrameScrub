import AppKit
import FrameScrubCore

/// The filmstrip is the seek surface when visible. A compact track takes over when folded.
final class SeekBarView: NSView, NSMenuDelegate, NSPopoverDelegate {
    var onSeek: ((Double) -> Void)?
    var onFilmSeek: ((Double) -> Void)?
    var onEditFragment: ((Int) -> Void)?
    var onAnalysisFragment: ((PluginAnalysisTimeline.Fragment) -> Void)?
    var onCutEdgePreview: ((Int) -> Void)?
    var onCutEdgeCommit: ((VirtualCutFragmentEdges, MarkEdge, Int, Double) -> Void)?
    var onFilmDrag: ((Double) -> Void)?
    var onFilmCoast: ((Double) -> Bool)?
    var onFilmClickPreview: ((Double) -> Void)?
    var onFilmPress: (() -> Void)?
    var onMarkDragBegin: ((MarkEdgeHandle) -> Bool)?
    var onMarkDragMove: ((Double) -> Void)?
    var onMarkDragEnd: ((Bool) -> Void)?
    var onFilmstripRequest: (([Double]) -> Void)?
    var onFilmstripFold: (() -> Void)?
    var onHover: ((Double?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onEnterExit: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onFilmScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    let transport = TransportControls()
    let modeControl = TimelineModeControl()
    private(set) var filmMode = TimelineFilmMode(rawValue: UserDefaults.standard.integer(forKey: "timeline-film-mode")) ?? .lens
    private var filmHover: (point: NSPoint, seconds: Double)?
    var filmPointer: NSPoint? { filmHover?.point }
    private var pictureAspect: CGFloat = 16.0 / 9
    private var pictureGeometry = DisplayGeometry.identity
    private var filmSettle = 0.25
    private var filmRevealed = false
    private var hideFilmWork: DispatchWorkItem?
    private var scrollRest: DispatchWorkItem?
    private var scrollTime: Double?
    private var filmTransition: Timer?
    private var presentedFilmTime: Double?
    private var transitionFrame: Int?
    private var outgoingFilm: (layout: TimelineFilmLayout, opacity: CGFloat)?
    private var animatesFilmClicks = UserDefaults.standard.object(forKey: "timeline-click-inertia") as? Bool ?? true
    private var previewsSeekFrames = UserDefaults.standard.bool(forKey: "timeline-click-preview-frames")
    private(set) var filmSeekPreviewSettings = FilmSeekPreviewSettings(
        milliseconds: UserDefaults.standard.object(forKey: "timeline-preview-duration-ms") as? Double ?? 180,
        rateIndex: UserDefaults.standard.object(forKey: "timeline-preview-rate") as? Int ?? 1)
    private var scrolling = false
    private var scrollHasSought = false
    private var filmSteps = LensScroll()
    private var lensSeconds = UserDefaults.standard.object(forKey: "timeline-lens-seconds") == nil ? 1
        : UserDefaults.standard.double(forKey: "timeline-lens-seconds")
    private var lensFocus = UserDefaults.standard.object(forKey: "timeline-lens-focus") == nil ? 0.3
        : UserDefaults.standard.double(forKey: "timeline-lens-focus")
    private var lensCrop = UserDefaults.standard.object(forKey: "timeline-lens-crop") == nil ? 0.7
        : UserDefaults.standard.double(forKey: "timeline-lens-crop")
    private var lensMagnification = UserDefaults.standard.object(forKey: "timeline-lens-magnification") == nil ? 2.75
        : UserDefaults.standard.double(forKey: "timeline-lens-magnification")
    private var lensDensity = UserDefaults.standard.object(forKey: "timeline-lens-density") == nil ? 2.75
        : UserDefaults.standard.double(forKey: "timeline-lens-density")
    private var layoutKey: [Double] = []
    private var cachedFilmLayout: TimelineFilmLayout?
    private let lensPopover = NSPopover()
    private(set) var playbackVisible = true
    private var contextMenuOpen = false
    private var filmAutoRevealSuppressed = false
    private(set) var filmPinned = UserDefaults.standard.bool(forKey: "timeline-film-pinned") {
        didSet { if filmPinned != oldValue { modeControl.setPinned(filmPinned) } }
    }
    private var index: FrameIndex?
    private var duration = 0.0
    private var paused = true
    private var frameCount = 0
    private var position = 0
    private var cached: [ClosedRange<Int>] = []
    private var loopA: Int?
    private var loopB: Int?
    private var marks: [ClosedRange<Int>] = []
    private var leadIns: [ClosedRange<Int>] = []
    private var openMark: Int?
    private var hovering = false
    private var pointerInside = false
    private var hideControls: DispatchWorkItem?
    private var thumbnailDwell: DispatchWorkItem?
    private var desiredTimes: [Double] = []
    private var requestedTimes: [Double] = []
    private var images: [Double: (picture: NSImage, source: CGImage)] = [:]
    private var imageOrder: [Double] = []
    private var cutPosters: [Int: NSImage] = [:]
    private var cutPosterOrder: [Int] = []
    private struct CutEdgeGesture {
        let edges: VirtualCutFragmentEdges
        let edge: MarkEdge
        let layout: TimelineFilmLayout
        let startX: CGFloat
        let grabOffset: Double
        var landing: (frame: Int, time: Double)?
    }
    private var cutEdges: VirtualCutFragmentEdges?
    private var cutEdgeGesture: CutEdgeGesture?
    private var drag: TimelineFilmDrag?
    private var markDrag: (handle: MarkEdgeHandle, layout: TimelineFilmLayout, startX: CGFloat,
                           grabOffset: Double, started: Bool)?
    private var markDragReference: NSImage?
    var isDraggingMark: Bool { markDrag?.started == true }
    private var horizontalFilmScroll = false
    private var horizontalFilmMomentum = false
    private var isFilmDragTransition = false
    private var filmStretch = 0.0
    private var overviewDrag = false
    private var overviewMoved = false
    var isContinuousSeek: Bool {
        if let drag { return drag.hasMoved }
        if overviewDrag { return overviewMoved }
        return scrolling
    }
    private var stripHeight: CGFloat = UserDefaults.standard.object(forKey: "timeline-film-height") == nil ? 48
        : min(96, max(0, CGFloat(UserDefaults.standard.double(forKey: "timeline-film-height"))))
    private var alwaysControls = UserDefaults.standard.bool(forKey: "timeline-controls-always")
    var filmstripEnabled: Bool { stripHeight > 0 }
    var showsFilmstrip: Bool { filmstripEnabled && (filmRevealed || filmPinned) }
    private var wantsFilm: Bool { showsFilmstrip }
    private var visibleFilmHeight: CGFloat { showsFilmstrip ? stripHeight : 0 }
    var isThumbnailInteraction: Bool {
        cutEdgeGesture != nil || drag != nil || markDrag != nil || overviewDrag || scrolling ||
            contextMenuOpen || transport.holding || isAnimatingFilmClick
    }
    var isInteracting: Bool { isThumbnailInteraction || lensPopover.isShown }
    var isAnimatingFilm: Bool { filmTransition != nil }
    private var isAnimatingFilmClick: Bool { isAnimatingFilm && transitionFrame == nil }
    var previewFrame: Int? { didSet { if oldValue != previewFrame { needsDisplay = true } } }
    private var timelineBottom: CGFloat { visibleFilmHeight }
    private var timeline: NSRect { NSRect(x: 0, y: timelineBottom, width: bounds.width, height: 28) }
    private var compactFilmControls: Bool { bounds.width >= TimelineModeControl.wideLayoutMinimum }
    private var transportBottom: CGFloat { timelineBottom + (wantsFilm ? (compactFilmControls ? 4 : 32) : 35) }
    private var transportHeight: CGFloat { 34 }
    var preferredHeight: CGFloat { transportBottom + transportHeight + 7 }
    private var film: NSRect { NSRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: visibleFilmHeight) }
    private var track: NSRect {
        NSRect(x: 12, y: timelineBottom + (hovering ? 6 : 7), width: max(0, bounds.width - 24), height: hovering ? 5 : 3)
    }
    private var seekArea: NSRect {
        // The film and the row above it share one target, with room for vertical drift.
        NSRect(x: 0, y: 0, width: bounds.width,
               height: playbackVisible ? timeline.maxY + 4 : visibleFilmHeight)
    }
    private var virtualTime: Double?
    private var cutTimeline: VirtualCutTimeline?
    private var sourceSegments: [ClosedRange<Int>] = []
    private var sourceSegmentsLocked = false
    private(set) var analysisTimeline: PluginAnalysisTimeline?
    private struct AnalysisDrawing {
        let row: NSRect
        let duration: Double
        let covered: CGPath
        let provisional: CGPath
        let refined: CGPath
    }
    private var analysisDrawing: AnalysisDrawing?
    private var timelineStatus: String?
    private var cutFilmMode: TimelineFilmMode = .overview
    private var effectiveFilmMode: TimelineFilmMode { cutTimeline == nil ? filmMode : cutFilmMode }
    private var currentSeconds: Double { virtualTime ?? index?.seconds(forFrame: position) ?? 0 }

    func setCutTimeline(_ timeline: VirtualCutTimeline?) {
        cutTimeline = timeline
        virtualTime = nil
        timelineStatus = nil
        cutFilmMode = .overview
        modeControl.setMode(effectiveFilmMode)
        setAccessibilityLabel(timeline == nil ? "Video timeline" : "Virtual cut timeline")
        resetFilmstrip()
    }

    func updateVirtualCut(time: Double, span: Int, paused: Bool, previewSettle: Double) {
        guard let cutTimeline else { return }
        let duration = cutTimeline.duration
        virtualTime = time
        updateTimeline(index: nil, duration: duration, paused: paused, previewSettle: previewSettle)
        timelineStatus = "Cut \(span + 1)/\(cutTimeline.spans.count)  ·  \(FrameNaming.timecode(time)) / \(FrameNaming.timecode(duration))"
        let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
        update(frameCount: 10_001, position: Int((10_000 * fraction).rounded()), cached: [],
               loopA: nil, loopB: nil, text: timelineStatus ?? "")
    }

    func showSourceSegments(_ ranges: [ClosedRange<Int>], locked: Bool) {
        sourceSegments = ranges
        sourceSegmentsLocked = locked
        timelineStatus = ranges.isEmpty ? nil : (locked ? "Fragment preview" : "Source with fragments")
    }

    func setAnalysisTimeline(_ timeline: PluginAnalysisTimeline?) {
        guard analysisTimeline != timeline else { return }
        analysisTimeline = timeline
        analysisDrawing = nil
        setAccessibilityHelp(timeline == nil ? nil : "Analysis results can also be selected in the analysis panel.")
        needsDisplay = true
    }

    private var analysisRow: NSRect {
        NSRect(x: track.minX, y: timelineBottom, width: track.width, height: 4)
    }

    private func isOverAnalysisRow(_ point: NSPoint) -> Bool {
        cutTimeline == nil && analysisTimeline != nil && playbackVisible && duration > 0 && analysisRow.contains(point)
    }

    private func analysisFragment(at point: NSPoint) -> PluginAnalysisTimeline.Fragment? {
        let row = analysisRow
        guard isOverAnalysisRow(point), let analysisTimeline else { return nil }
        let time = Double((point.x - row.minX) / row.width) * duration
        let tolerance = 1.5 * duration / row.width
        var closest: PluginAnalysisTimeline.Fragment?
        var closestDistance = tolerance
        for fragment in analysisTimeline.fragments where fragment.range.lowerBound < duration {
            let distance = max(0, fragment.range.lowerBound - time, time - fragment.range.upperBound)
            if distance < closestDistance || (distance == closestDistance && fragment.refined && closest?.refined != true) {
                closest = fragment
                closestDistance = distance
            }
        }
        return closest
    }

    /// Window coordinates for the real-window analysis timeline benchmark.
    func analysisMarkerPoint(at time: Double, id: String? = nil) -> NSPoint? {
        let row = analysisRow
        let point = NSPoint(x: row.minX + row.width * time / max(0.001, duration), y: row.midY)
        guard let fragment = analysisFragment(at: point), id == nil || id == fragment.id else { return nil }
        return convert(point, to: nil)
    }
    private var filmLayout: TimelineFilmLayout {
        if let markDrag { return markDrag.layout }
        let displayedTime = presentedFilmTime ?? (horizontalFilmScroll ? scrollTime : nil) ?? currentSeconds
        let key = [Double(film.width), Double(stripHeight), Double(pictureAspect), duration, displayedTime,
                   lensSeconds, lensFocus, lensCrop, Double(effectiveFilmMode.rawValue), lensMagnification, lensDensity]
        if cachedFilmLayout == nil || layoutKey != key {
            cachedFilmLayout = makeFilmLayout(center: displayedTime)
            layoutKey = key
        }
        return cachedFilmLayout!
    }
    private func makeFilmLayout(center: Double) -> TimelineFilmLayout {
        TimelineFilmLayout(width: Double(film.width), height: Double(stripHeight), aspect: Double(pictureAspect),
            duration: duration, center: center, secondsPerThumbnail: lensSeconds, focusFraction: lensFocus,
            cropStrength: lensCrop, mode: effectiveFilmMode, magnification: lensMagnification, outsideDensity: lensDensity)
    }
    /// The same samples that reveal will draw, without revealing, requesting a read or invalidating the view.
    func prewarmFilmstripTimes(center: Double) -> [Double] {
        guard filmstripEnabled, !showsFilmstrip, film.width > 0, index?.isExact == true else { return [] }
        let layout = makeFilmLayout(center: center)
        var times: [Double] = []
        for cell in layout.cells.sorted(by: { abs($0.offset - layout.playheadOffset) < abs($1.offset - layout.playheadOffset) }) {
            guard let seconds = cell.seconds else { continue }
            let key = imageTime(seconds)
            if images[key] == nil, !times.contains(key) { times.append(key) }
        }
        return times
    }
    private var scale: TimelineProjection { filmLayout.lens }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        transport.alphaValue = alwaysControls ? 1 : 0
        addSubview(transport)
        modeControl.alphaValue = transport.alphaValue
        modeControl.setMode(filmMode)
        modeControl.setPinned(filmPinned)
        modeControl.onPin = { [weak self] in self?.toggleFilmPin() }
        modeControl.onSelect = { [weak self] in self?.setFilmMode($0) }
        modeControl.onSettings = { [weak self] in self?.showLensControls() }
        addSubview(modeControl)
        addSubview(modeControl, positioned: .above, relativeTo: transport)
        transport.onHold = { [weak self] in
            self?.showControls(); self?.scheduleControlHide(); self?.updateDesiredImages(); self?.onEnterExit?()
        }
        setAccessibilityLabel("Video timeline")
        setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit { hideControls?.cancel(); thumbnailDwell?.cancel(); hideFilmWork?.cancel(); scrollRest?.cancel(); filmTransition?.invalidate() }

    override func layout() {
        super.layout()
        transport.frame = NSRect(x: 12, y: transportBottom, width: max(0, bounds.width - 24), height: transportHeight)
        modeControl.isHidden = !showsFilmstrip
        modeControl.frame = compactFilmControls
            ? NSRect(x: bounds.width - 300, y: transportBottom + 3, width: 150, height: 28)
            : NSRect(x: 44, y: timelineBottom + 10, width: 110, height: 19)
        transport.layoutSubtreeIfNeeded()
        onHeightChange?(preferredHeight)
        updateDesiredImages()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    /// The player leaves an 8 pt inset below the bar. Once revealed, both rows
    /// and the controls hold the panel open as the pointer moves between them.
    func isInRevealZone(_ pointInWindow: NSPoint?) -> Bool {
        guard let pointInWindow else { return false }
        let point = convert(pointInWindow, from: nil)
        guard bounds.minX <= point.x, point.x < bounds.maxX, point.y >= -8 else { return false }
        let controlsTop = playbackVisible ? seekArea.maxY : (showsFilmstrip ? film.maxY + 24 : 16)
        let revealTop = filmAutoRevealSuppressed ? controlsTop : max(controlsTop, stripHeight)
        if point.y < revealTop { return true }
        guard playbackVisible else { return false }
        return point.y < timeline.maxY || isOverControls(point)
    }

    private func isOverControls(_ point: NSPoint) -> Bool {
        (!modeControl.isHidden && modeControl.alphaValue > 0.01 && modeControl.frame.contains(point)) ||
            (transport.alphaValue > 0.01 && transport.occupiedRects.contains { $0.contains(point) })
    }

    func updateFilmPointer(_ pointInWindow: NSPoint?) {
        if isInRevealZone(pointInWindow) {
            hideFilmWork?.cancel(); hideFilmWork = nil
            if filmstripEnabled, !filmAutoRevealSuppressed, !filmPinned { setFilmRevealed(true) }
        } else if cutTimeline == nil, sourceSegments.isEmpty, !filmPinned, !isInteracting, filmRevealed, hideFilmWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                hideFilmWork = nil
                if !isInteracting {
                    setPlaybackControlsVisible(false)
                    setFilmRevealed(false)
                }
            }
            hideFilmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
    func setFilmRevealed(_ shown: Bool, force: Bool = false) {
        guard force || filmRevealed != shown else { return }
        filmRevealed = shown
        if !showsFilmstrip {
            cancelCutEdgeGesture()
            cancelMarkDrag()
            stopFilmTransition()
            cancelFilmScroll()
            clearHover()
            onFilmstripFold?()
            cancelFilmstripRequests()
        }
        onHeightChange?(preferredHeight)
        needsLayout = true; needsDisplay = true
        layoutSubtreeIfNeeded(); updateDesiredImages()
    }
    func toggleFilmVisibility() {
        if !filmstripEnabled { stripHeight = 48; UserDefaults.standard.set(48, forKey: "timeline-film-height") }
        if showsFilmstrip {
            filmPinned = false; UserDefaults.standard.set(false, forKey: "timeline-film-pinned")
            filmAutoRevealSuppressed = true; setFilmRevealed(false, force: true)
        } else { filmAutoRevealSuppressed = false; setFilmRevealed(true) }
        onEnterExit?()
    }
    func toggleFilmPin() {
        if !filmstripEnabled { stripHeight = 48; UserDefaults.standard.set(48, forKey: "timeline-film-height") }
        filmPinned.toggle(); UserDefaults.standard.set(filmPinned, forKey: "timeline-film-pinned")
        filmAutoRevealSuppressed = false
        if filmPinned { setFilmRevealed(true, force: true) }
        else { setFilmRevealed(false, force: true) }
        onEnterExit?()
    }
    func revealPlaybackControls() { showControls() }
    func setFilmMode(_ mode: TimelineFilmMode, save: Bool = true) {
        guard effectiveFilmMode != mode else { return }
        cancelMarkDrag()
        stopFilmTransition()
        cancelCutEdgeGesture()
        drag = nil; cancelFilmScroll()
        clearHover()
        if cutTimeline == nil {
            filmMode = mode
            if save { UserDefaults.standard.set(mode.rawValue, forKey: "timeline-film-mode") }
        } else { cutFilmMode = mode }
        modeControl.setMode(mode)
        requestedTimes = []; updateDesiredImages(); needsDisplay = true
        onEnterExit?()
    }
    func configureLens(seconds: Double, focus: Double, crop: Double, magnification: Double? = nil,
                       density: Double? = nil, save: Bool = true) {
        stopFilmTransition()
        lensSeconds = seconds.isFinite ? min(30, max(0.1, seconds)) : 1
        lensFocus = focus.isFinite ? min(0.75, max(0.08, focus)) : 0.3
        lensCrop = crop.isFinite ? min(1, max(0, crop)) : 0.7
        if let magnification { lensMagnification = magnification.isFinite ? min(3.8, max(1, magnification)) : 2.75 }
        if let density {
            lensDensity = density.isFinite ? min(TimelineFilmLayout.maximumOutsideDensity, max(0.5, density)) : 2.75
        }
        if save { saveLensPreferences() }
        requestedTimes = []; updateDesiredImages(); needsDisplay = true
    }
    private func saveLensPreferences() {
        for (key, value) in [("timeline-lens-seconds", lensSeconds), ("timeline-lens-focus", lensFocus),
                             ("timeline-lens-crop", lensCrop), ("timeline-lens-magnification", lensMagnification),
                             ("timeline-lens-density", lensDensity)] {
            if UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.double(forKey: key) != value {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }
    func configureFilmHeight(_ height: Double, save: Bool = true) {
        guard height.isFinite else { return }
        let value = CGFloat(min(96, max(36, height))).rounded()
        guard value != stripHeight else { return }
        applyFilmHeight(value, save: save)
    }
    func setPlaybackControlsVisible(_ shown: Bool) {
        let shown = shown || alwaysControls
        guard playbackVisible != shown else { return }
        playbackVisible = shown
        window?.invalidateCursorRects(for: self)
        if shown { showControls() }
        else {
            clearHover()
            hideControls?.cancel()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15; transport.animator().alphaValue = 0
                modeControl.animator().alphaValue = 0
            }
        }
        needsDisplay = true
    }
    func updateTimeline(index: FrameIndex?, duration: Double, paused: Bool,
                        uprightSize: CGSize? = nil, geometry: DisplayGeometry = .identity, previewSettle: Double = 0.25) {
        self.index = index
        filmSettle = max(0, previewSettle)
        pictureGeometry = geometry
        if let uprightSize, uprightSize.height > 0 {
            let aspect = geometry.aspect(of: uprightSize)
            pictureAspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9
        }
        self.duration = duration.isFinite ? max(0, duration) : 0
        let newlyPaused = paused && !self.paused
        self.paused = paused
        if newlyPaused { requestedTimes = [] }
    }
    func update(frameCount: Int, position: Int, cached: [ClosedRange<Int>], loopA: Int?, loopB: Int?,
                marks: [ClosedRange<Int>] = [], leadIns: [ClosedRange<Int>] = [], openMark: Int? = nil, text: String) {
        self.frameCount = frameCount; self.position = position; self.cached = cached
        if let transitionFrame, position != transitionFrame { stopFilmTransition() }
        self.loopA = loopA; self.loopB = loopB; self.marks = marks; self.leadIns = leadIns; self.openMark = openMark
        setAccessibilityValue(text)
        updateDesiredImages()
        if playbackVisible || wantsFilm { needsDisplay = true }
    }
    /// Requested times have already been snapped to inexpensive keyframes, never decoded on this thread.
    private func imageTime(_ seconds: Double) -> Double {
        if let cutTimeline, let location = cutTimeline.location(at: seconds) {
            let span = cutTimeline.spans[location.spanIndex]
            // A bucket can straddle a join. Keep its representative on the same side as its cell.
            return max(span.cutStart, min(span.cutEnd.nextDown, (seconds * 10).rounded() / 10))
        }
        guard let index, index.isExact else { return (seconds * 10).rounded() / 10 }
        return index.seconds(forFrame: index.keyframe(atOrBefore: index.frameNumber(forSeconds: seconds)))
    }
    private func updateDesiredImages() {
        // The flying layout is only a visual effect. Do not schedule thumbnail reads for intermediate positions.
        guard !isAnimatingFilmClick, !horizontalFilmScroll else { cancelFilmstripRequests(); return }
        guard wantsFilm, film.width > 0, virtualTime != nil || (index?.frameCount ?? 0) > 0 else {
            cancelFilmstripRequests(); desiredTimes = []; return
        }
        let layout = filmLayout
        var times: [Double] = []
        // Centre first; requesting the same keyframe twice costs nothing and is removed here.
        for cell in layout.cells.sorted(by: { abs($0.offset - layout.playheadOffset) < abs($1.offset - layout.playheadOffset) }) {
            guard let seconds = cell.seconds else { continue }
            let key = imageTime(seconds)
            if !times.contains(key) { times.append(key) }
        }
        desiredTimes = times
        guard !isThumbnailInteraction, alphaValue > 0.01, window?.occlusionState.contains(.visible) == true else {
            cancelFilmstripRequests(); return
        }
        let missing = times.filter { images[$0] == nil }
        guard missing != requestedTimes else { return }
        requestedTimes = missing
        // Playback keeps moving the far samples. Update the batch without postponing its deadline on every frame.
        guard thumbnailDwell == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            thumbnailDwell = nil
            guard wantsFilm, !isThumbnailInteraction, alphaValue > 0.01,
                  window?.occlusionState.contains(.visible) == true else {
                requestedTimes = []; return
            }
            onFilmstripRequest?(requestedTimes)
        }
        thumbnailDwell = work
        // Reuses the network preview's established dwell; no timer runs once this request fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + filmSettle, execute: work)
    }
    private func cancelFilmstripRequests() {
        thumbnailDwell?.cancel(); thumbnailDwell = nil
        requestedTimes = []
        onFilmstripRequest?([])
    }
    func setFilmstripImage(_ image: CGImage, seconds: Double) {
        let thumbnail = NSImage(cgImage: image, size: .zero)
        images[seconds] = (thumbnail, image)
        if let span = cutTimeline?.location(at: seconds)?.spanIndex, cutPosters[span] == nil {
            storeCutPoster(thumbnail, span: span)
        }
        imageOrder.removeAll { $0 == seconds }; imageOrder.append(seconds)
        // Two bounded screenfuls; decoder concurrency is still one.
        while imageOrder.count > TimelineFilmLayout.maximumCells * 2 { images[imageOrder.removeFirst()] = nil }
        // A completion already in flight may arrive after folding. Keep it cached without waking the view.
        guard wantsFilm, !isHidden, alphaValue > 0.01,
              window?.occlusionState.contains(.visible) == true else { return }
        needsDisplay = true
        // Paused video may have no subsequent input event to refresh AppKit's backing store.
        if !isAnimatingFilmClick, !isHidden, alphaValue > 0.01, window != nil { displayIfNeeded() }
    }
    func cachedSeekThumbnails(from origin: Double, to target: Double) -> [CGImage] {
        let low = min(origin, target), high = max(origin, target)
        let times = images.keys.filter { $0 > low && $0 < high }.sorted()
        let count = min(times.count, 3)
        guard count >= 2 else { return [] }
        return (0..<count).compactMap { slot in
            let index = (2 * slot + 1) * times.count / (2 * count)
            let offset = target > origin ? index : times.count - 1 - index
            return images[times[offset]]?.source
        }
    }
    func resetFilmstrip() {
        cancelCutEdgeGesture()
        cancelMarkDrag()
        stopFilmTransition()
        thumbnailDwell?.cancel(); thumbnailDwell = nil
        images.removeAll(); imageOrder.removeAll(); requestedTimes = []; desiredTimes = []
        cutPosters.removeAll(); cutPosterOrder.removeAll()
        drag = nil; overviewDrag = false
        clearHover()
        cancelFilmScroll()
        needsDisplay = true
    }
    func hasCutPoster(_ span: Int) -> Bool { cutPosters[span] != nil }

    func setCutPoster(_ image: CGImage, span: Int) {
        guard cutPosters[span] == nil else { return }
        storeCutPoster(NSImage(cgImage: image, size: .zero), span: span)
        if showsFilmstrip { needsDisplay = true }
    }

    private func storeCutPoster(_ image: NSImage, span: Int) {
        cutPosters[span] = image
        cutPosterOrder.append(span)
        if cutPosterOrder.count > TimelineFilmLayout.maximumCells {
            cutPosters[cutPosterOrder.removeFirst()] = nil
        }
    }
    func filmstripSourceChanged() {
        thumbnailDwell?.cancel(); thumbnailDwell = nil
        requestedTimes = []
        updateDesiredImages()
    }
    func cancelInteraction() {
        cancelCutEdgeGesture()
        cancelMarkDrag()
        stopFilmTransition()
        drag = nil; overviewDrag = false
        clearHover()
        cancelFilmScroll()
        updateFilmPointer(nil)
        cancelFilmstripRequests()
        scheduleControlHide()
        needsDisplay = true
    }
    func refreshVisibility() {
        if window?.occlusionState.contains(.visible) != true || alphaValue <= 0.01 {
            cancelCutEdgeGesture()
            cancelMarkDrag()
            stopFilmTransition()
            cancelFilmScroll()
            cancelFilmstripRequests(); hideControls?.cancel()
        } else { updateDesiredImages() }
    }
    private func x(for frame: Int) -> CGFloat {
        let fraction = index.map { duration > 0 ? $0.seconds(forFrame: frame) / duration : 0 }
            ?? Double(frame) / Double(max(frameCount - 1, 1))
        return track.minX + track.width * CGFloat(min(1, max(0, fraction)))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard wantsFilm || playbackVisible else { return }
        NSColor(white: 0, alpha: 0.58).setFill()
        let height = wantsFilm ? visibleFilmHeight : timeline.maxY
        let plate = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8).fill()
        if wantsFilm, duration > 0 { drawFilm() }
        if playbackVisible { drawAnalysisTimeline() }
        guard playbackVisible || (timelineStatus != nil && wantsFilm) else { return }
        if !wantsFilm { drawPositionRanges(in: track) }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                  .foregroundColor: NSColor(white: 1, alpha: 0.84)]
        let time = (timelineStatus ?? compactTime(currentSeconds)) as NSString
        let labelSize = time.size(withAttributes: attrs)
        var timeX = bounds.midX
        if wantsFilm {
            let clearance = 12 + labelSize.width / 2
            timeX = compactFilmControls
                ? min(timeX, modeControl.frame.minX - clearance)
                : max(timeX, modeControl.frame.maxX + clearance)
        }
        let labelOrigin = NSPoint(x: timeX - labelSize.width / 2, y: timelineBottom + (wantsFilm ? 12 : 14))
        if wantsFilm {
            let badge = NSRect(origin: labelOrigin, size: labelSize).insetBy(dx: -6, dy: -2)
            NSColor(white: 0, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        }
        time.draw(at: labelOrigin, withAttributes: attrs)
        guard !wantsFilm else { return }
        ("0:00" as NSString).draw(at: NSPoint(x: 12, y: timelineBottom + 14), withAttributes: attrs)
        let end = compactTime(duration) as NSString
        end.draw(at: NSPoint(x: bounds.width - 12 - end.size(withAttributes: attrs).width, y: timelineBottom + 14), withAttributes: attrs)
    }

    private func drawAnalysisTimeline() {
        let row = analysisRow
        guard cutTimeline == nil, let analysisTimeline, duration > 0, !row.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }
        if analysisDrawing?.row != row || analysisDrawing?.duration != duration {
            let covered = CGMutablePath(), provisional = CGMutablePath(), refined = CGMutablePath()
            func rect(_ range: ClosedRange<Double>, y: CGFloat, height: CGFloat, minimum: CGFloat = 0) -> NSRect {
                let left = row.minX + row.width * CGFloat(range.lowerBound / duration)
                let right = row.minX + row.width * CGFloat(min(duration, range.upperBound) / duration)
                let width = max(minimum, right - left)
                let x = max(row.minX, min(row.maxX - width, (left + right - width) / 2))
                return NSRect(x: x, y: y, width: width, height: height)
            }
            for range in analysisTimeline.covered where range.lowerBound < duration {
                covered.addRect(rect(range, y: row.minY, height: 1))
            }
            for fragment in analysisTimeline.fragments where fragment.range.lowerBound < duration {
                if fragment.refined {
                    refined.addRect(rect(fragment.range, y: row.minY + 1, height: 3, minimum: min(2, row.width)))
                } else {
                    provisional.addRect(rect(fragment.range, y: row.minY + 2, height: 2, minimum: min(2, row.width)))
                }
            }
            analysisDrawing = AnalysisDrawing(row: row, duration: duration, covered: covered,
                                              provisional: provisional, refined: refined)
        }
        guard let drawing = analysisDrawing else { return }
        NSColor(white: 0, alpha: 0.72).setFill()
        row.fill()
        for (path, color) in [(drawing.covered, NSColor(white: 1, alpha: 0.65)),
                              (drawing.provisional, NSColor.systemOrange),
                              (drawing.refined, NSColor.systemGreen)] where !path.isEmpty {
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }
    private func drawFilm() {
        let layout = cutEdgeGesture?.layout ?? filmLayout
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: film).addClip()
        if let outgoingFilm {
            drawFilmContent(layout, opacity: 1 - outgoingFilm.opacity)
            drawFilmContent(outgoingFilm.layout, opacity: outgoingFilm.opacity)
        } else {
            drawFilmContent(layout)
        }
        drawMarkHandles(layout)
        drawCutMarkers(in: layout)
        drawCutEdges(in: layout)
        NSGraphicsContext.restoreGraphicsState()
        let head = filmHead(in: layout)
        if previewFrame != nil, let point = filmPointer {
            let cursorX = min(film.maxX - 1, max(film.minX + 1, point.x)).rounded()
            drawFilmCursor(at: cursorX, overPlayhead: abs(cursorX - head) <= 3)
        }
    }
    private func drawFilmContent(_ layout: TimelineFilmLayout, opacity: CGFloat = 1) {
        guard opacity > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        if opacity < 1 {
            context.saveGState()
            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for cell in layout.cells {
            guard let seconds = cell.seconds else { continue }
            let rect = NSRect(x: film.midX + CGFloat(cell.offset - cell.width / 2 + filmStretch), y: film.minY,
                              width: max(0, CGFloat(cell.width) - 2), height: film.height)
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let span = cutTimeline?.location(at: seconds)?.spanIndex
            if let image = images[imageTime(seconds)]?.picture ?? span.flatMap({ cutPosters[$0] }) {
                FilmstripThumbnail.draw(image, geometry: pictureGeometry, in: rect, opacity: 0.85,
                                            cropToFill: cell.cropped, cropAmount: cell.cropAmount)
            }
        }
        let filmX: (Double) -> CGFloat = { self.film.midX + CGFloat(layout.lens.offset(for: $0)) }
        drawFragmentGuides(in: film, x: filmX)
        if playbackVisible {
            let edge = NSRect(x: film.minX, y: film.minY, width: film.width, height: 2)
            drawPositionRanges(in: edge, projection: layout.lens)
        }
        let head = filmHead(in: layout)
        NSColor(white: 0, alpha: 0.65).setFill()
        NSRect(x: head - 2, y: film.minY, width: 4, height: film.height).fill()
        NSColor.white.setFill()
        NSRect(x: head - 1, y: film.minY, width: 2, height: film.height).fill()
        if opacity < 1 {
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }
    private func filmHead(in layout: TimelineFilmLayout) -> CGFloat {
        let offset = isDraggingMark ? layout.lens.offset(for: currentSeconds) : layout.playheadOffset
        return min(film.maxX - 1, max(film.minX + 1, film.midX + CGFloat(offset))).rounded()
    }

    private func markHandles(in layout: TimelineFilmLayout) -> [(handle: MarkEdgeHandle, rect: NSRect)] {
        guard onMarkDragBegin != nil, let index else { return [] }
        let firstRow: CGFloat = cutEdges != nil && index.isExact && film.height >= 20 ? 14 : 1
        func handle(_ boundary: MarkEdgeHandle, side: CGFloat, row: CGFloat) -> (MarkEdgeHandle, NSRect)? {
            let x = film.midX + CGFloat(layout.lens.offset(for: index.seconds(forFrame: boundary.frame)))
            let height = min(9, film.height - row)
            guard x >= film.minX - 1, x <= film.maxX + 1, height > 0 else { return nil }
            let center = min(film.maxX - 3, max(film.minX + 3, x + side))
            return (boundary, NSRect(x: center - 3, y: film.minY + row, width: 6, height: height))
        }
        var result: [(MarkEdgeHandle, NSRect)] = []
        for range in marks {
            if let start = handle(.segment(frame: range.lowerBound, edge: .start), side: -3, row: firstRow) { result.append(start) }
            if let end = handle(.segment(frame: range.upperBound, edge: .end), side: 3, row: firstRow) { result.append(end) }
        }
        let openRow = max(firstRow, min(firstRow + 10, film.height - 9))
        if let openMark, let open = handle(.open(frame: openMark), side: -3, row: openRow) { result.append(open) }
        return result
    }

    private func drawMarkHandles(_ layout: TimelineFilmLayout) {
        for (_, rect) in markHandles(in: layout) {
            NSColor(white: 0, alpha: 0.75).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
        if let reference = markDragReference {
            let height = max(0, film.height - 16)
            let width = min(112, height * reference.size.width / max(1, reference.size.height))
            let onLeft = filmHead(in: layout) >= film.midX
            let x = onLeft ? film.minX + 6 : film.maxX - width - 6
            let rect = NSRect(x: x, y: film.minY + 13, width: width, height: height)
            NSColor(white: 0, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3).fill()
            FilmstripThumbnail.draw(reference, geometry: pictureGeometry, in: rect, opacity: 1,
                                    cropToFill: false, cropAmount: 0)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                                        .foregroundColor: NSColor.white]
            let text = "Original" as NSString
            let label = NSRect(origin: NSPoint(x: rect.minX + 2, y: rect.minY + 1),
                               size: text.size(withAttributes: attrs)).insetBy(dx: -2, dy: -1)
            NSColor(white: 0, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: label, xRadius: 2, yRadius: 2).fill()
            text.draw(at: NSPoint(x: label.minX + 2, y: label.minY + 1), withAttributes: attrs)
        }
    }

    func markHandlePoint(for handle: MarkEdgeHandle) -> NSPoint? {
        guard showsFilmstrip, let rect = markHandles(in: filmLayout).first(where: { $0.handle == handle })?.rect
        else { return nil }
        return convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    func setMarkDragReference(_ image: CGImage) {
        guard isDraggingMark else { return }
        markDragReference = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        needsDisplay = true
    }

    func cancelMarkDrag() { finishMarkDrag(commit: false) }

    private func finishMarkDrag(commit: Bool) {
        guard let markDrag else { return }
        self.markDrag = nil
        markDragReference = nil
        if markDrag.started { onMarkDragEnd?(commit) }
        needsDisplay = true
    }

    func setCutEdges(_ edges: VirtualCutFragmentEdges?) {
        guard cutEdges != edges else { return }
        cancelCutEdgeGesture()
        cutEdges = edges
        if edges != nil, filmstripEnabled { setFilmRevealed(true) }
        needsDisplay = true
    }

    @discardableResult func cancelCutEdgeGesture() -> Bool {
        guard cutEdgeGesture != nil else { return false }
        cutEdgeGesture = nil
        requestedTimes = []
        updateDesiredImages()
        needsDisplay = true
        return true
    }

    private func cutEdgeHandles(in layout: TimelineFilmLayout) -> [(edge: MarkEdge, x: CGFloat, rect: NSRect)] {
        guard let cutEdges, index?.isExact == true, cutTimeline == nil, film.height >= 20 else { return [] }
        return [MarkEdge.start, .end].compactMap { edge in
            let time = cutEdgeGesture?.edge == edge ? cutEdgeGesture?.landing?.time ?? cutEdges.time(for: edge)
                : cutEdges.time(for: edge)
            let x = film.midX + CGFloat(layout.lens.offset(for: time))
            guard x >= film.minX - 0.5, x <= film.maxX + 0.5 else { return nil }
            let left = edge == .start ? x - 11 : x
            let rect = NSRect(x: left, y: film.minY, width: 11, height: 12).intersection(film)
            if rect.width >= 3 { return (edge, x, rect) }
            let inwardX = edge == .start ? film.minX : film.maxX - 11
            return (edge, x, NSRect(x: inwardX, y: film.minY, width: 11, height: 12))
        }
    }

    private func drawCutEdges(in layout: TimelineFilmLayout) {
        for handle in cutEdgeHandles(in: layout) {
            NSColor(white: 0.07, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: handle.rect, xRadius: 3, yRadius: 3).fill()
            NSColor.systemYellow.setFill()
            NSRect(x: handle.x - 1, y: film.minY, width: 2, height: film.height).fill()
            NSRect(x: handle.rect.midX - 0.5, y: handle.rect.minY + 3, width: 1, height: 6).fill()
        }
    }

    func cutEdgePoint(for edge: MarkEdge) -> NSPoint? {
        guard showsFilmstrip, let rect = cutEdgeHandles(in: filmLayout).first(where: { $0.edge == edge })?.rect
        else { return nil }
        return convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// Keep labels on the upper edge of the film, leaving the picture below them available for scrubbing.
    private func cutMarkers(in layout: TimelineFilmLayout) -> [(span: Int, rect: NSRect)] {
        guard let cutTimeline, film.width >= 24, film.height >= 20 else { return [] }
        let width: CGFloat = cutTimeline.spans.count >= 1000 ? 34 : 24
        let firstTime = filmTarget(at: film.minX, in: layout)
        guard let first = cutTimeline.location(at: firstTime)?.spanIndex else { return [] }
        var result: [(span: Int, rect: NSRect)] = []
        var nextX = film.minX
        for span in first..<cutTimeline.spans.count {
            let start = film.midX + CGFloat(layout.lens.offset(for: cutTimeline.spans[span].cutStart))
            let x = max(film.minX, start + 2)
            if x + width > film.maxX { break }
            let end = film.midX + CGFloat(layout.lens.offset(for: cutTimeline.spans[span].cutEnd))
            guard x >= nextX, x + width <= end else { continue }
            let rect = NSRect(x: x, y: film.maxY - 18, width: width, height: 16)
            result.append((span, rect))
            nextX = rect.maxX + 2
        }
        return result
    }

    func cutMarkerPoint(for span: Int) -> NSPoint? {
        guard showsFilmstrip, let rect = cutMarkers(in: filmLayout).first(where: { $0.span == span })?.rect else { return nil }
        return convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// Window coordinates for a real-window drag starting at the current cut position.
    func cutFilmDragPoints(from start: Double, to end: Double) -> (NSPoint, NSPoint)? {
        guard cutTimeline != nil, showsFilmstrip else { return nil }
        let lens = filmLayout.lens
        let displacement = CGFloat(lens.offset(for: end) - lens.offset(for: start))
        guard abs(displacement) > 6, abs(displacement) < film.width else { return nil }
        let y = film.minY + min(1, film.height / 2)
        let pressed = NSPoint(x: film.midX + displacement / 2, y: y)
        let dragged = NSPoint(x: pressed.x - displacement, y: y)
        return (convert(pressed, to: nil), convert(dragged, to: nil))
    }

    private func drawCutMarkers(in layout: TimelineFilmLayout) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        for (span, rect) in cutMarkers(in: layout) {
            NSColor(white: 0.07, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let title = String(span + 1) as NSString
            let size = title.size(withAttributes: attributes)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
    private func drawFilmCursor(at x: CGFloat, overPlayhead: Bool) {
        let top = film.maxY
        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: x - 5, y: top + 7))
        cursor.line(to: NSPoint(x: x + 5, y: top + 7))
        cursor.line(to: NSPoint(x: x + 1, y: top))
        if !overPlayhead {
            cursor.line(to: NSPoint(x: x + 1, y: film.minY + 1))
            cursor.line(to: NSPoint(x: x - 1, y: film.minY + 1))
        }
        cursor.line(to: NSPoint(x: x - 1, y: top))
        cursor.close()
        cursor.lineWidth = 2
        cursor.lineJoinStyle = .round
        NSColor(white: 0, alpha: 0.85).setStroke()
        cursor.stroke()
        NSColor(srgbRed: 0.46, green: 0.85, blue: 1, alpha: 1).setFill()
        cursor.fill()
    }
    private func compactTime(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
    private func drawPositionRanges(in track: NSRect, projection: TimelineProjection? = nil) {
        func x(for frame: Int) -> CGFloat {
            if let projection, let index { return film.midX + CGFloat(projection.offset(for: index.seconds(forFrame: frame))) }
            return self.x(for: frame)
        }
        if projection == nil {
            NSColor(white: 1, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        }
        NSColor.systemTeal.withAlphaComponent(0.85).setFill()
        for range in cached {
            NSRect(x: x(for: range.lowerBound), y: track.minY,
                   width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)), height: track.height).fill()
        }
        func fill(_ range: ClosedRange<Int>) {
            NSRect(x: x(for: range.lowerBound), y: track.minY,
                   width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)), height: track.height).fill()
        }
        NSColor.systemGreen.withAlphaComponent(0.3).setFill()
        leadIns.forEach(fill)
        NSColor.systemGreen.withAlphaComponent(0.65).setFill()
        marks.forEach(fill)
        if let open = openMark {
            NSColor.systemGreen.withAlphaComponent(0.35).setFill()
            fill(min(open, position)...max(open, position))
            NSColor.systemGreen.withAlphaComponent(0.9).setFill()
            NSRect(x: x(for: open) - 1, y: track.minY - 2, width: 2, height: track.height + 4).fill()
        }
        if let a = loopA, let b = loopB {
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            NSRect(x: x(for: min(a, b)), y: track.minY - 2, width: max(1, abs(x(for: b) - x(for: a))), height: track.height + 4).fill()
        }
        if projection == nil, hovering, let previewFrame {
            NSColor(white: 1, alpha: 0.9).setFill()
            NSRect(x: x(for: previewFrame).rounded() - 1, y: track.minY - 3, width: 2, height: track.height + 6).fill()
        }
        NSColor.systemYellow.setFill()
        for marker in [loopA, loopB].compactMap({ $0 }) {
            NSRect(x: x(for: marker) - 1, y: track.minY - 4, width: 2, height: track.height + 8).fill()
        }
        guard projection == nil else { return }
        drawFragmentGuides(in: track) { track.minX + track.width * CGFloat($0 / max(0.001, self.duration)) }
        NSColor.white.setFill()
        let head = x(for: position)
        NSBezierPath(ovalIn: NSRect(x: head - 5, y: track.midY - 5, width: 10, height: 10)).fill()
    }

    private func drawFragmentGuides(in rect: NSRect, x: (Double) -> CGFloat) {
        if let cutTimeline {
            // Show all visible joins; at dense zoom there is at most one marker per point.
            var previousX = -CGFloat.infinity
            for span in cutTimeline.spans.dropFirst() {
                let edge = x(span.cutStart).rounded()
                guard edge >= rect.minX, edge <= rect.maxX, edge > previousX else { continue }
                previousX = edge
                drawFragmentEdge(at: edge, in: rect)
            }
        } else if let index, !sourceSegments.isEmpty {
            var after = rect.minX
            for range in sourceSegments {
                let start = min(rect.maxX, max(rect.minX, x(index.seconds(forFrame: range.lowerBound))))
                let endTime = range.upperBound + 1 < index.frameCount ? index.seconds(forFrame: range.upperBound + 1) : duration
                let end = min(rect.maxX, max(start, x(endTime)))
                NSColor(white: 0, alpha: sourceSegmentsLocked ? 0.62 : 0.42).setFill()
                NSRect(x: after, y: rect.minY, width: max(0, start - after), height: rect.height).fill()
                if start > rect.minX && start < rect.maxX { drawFragmentEdge(at: start, in: rect) }
                if end > rect.minX && end < rect.maxX { drawFragmentEdge(at: end, in: rect) }
                after = end
            }
            NSColor(white: 0, alpha: sourceSegmentsLocked ? 0.62 : 0.42).setFill()
            NSRect(x: after, y: rect.minY, width: max(0, rect.maxX - after), height: rect.height).fill()
        }
    }

    private func drawFragmentEdge(at x: CGFloat, in rect: NSRect) {
        NSColor(white: 0, alpha: 0.8).setFill()
        NSRect(x: x - 2, y: rect.minY, width: 4, height: rect.height).fill()
        NSColor.systemYellow.setFill()
        NSRect(x: x - 1, y: rect.minY, width: 2, height: rect.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        if !modeControl.isHidden, modeControl.alphaValue > 0.01, modeControl.frame.contains(local) {
            return modeControl.hitTest(local)
        }
        if let control = transport.hitTest(local) { return control }
        guard let hit = super.hitTest(point) else { return nil }
        guard hit === self else { return hit }
        return seekArea.contains(local) ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        clearHover()
        updateFilmPointer(event.locationInWindow)
        scheduleControlHide(); onEnterExit?(); needsDisplay = true
    }
    private func clearHover() {
        let hadTarget = hovering || filmPointer != nil
        hovering = false; filmHover = nil
        if hadTarget { onHover?(nil); needsDisplay = true }
    }
    private func filmTarget(at x: CGFloat, in layout: TimelineFilmLayout) -> Double {
        layout.lens.time(at: Double(x - film.midX))
    }
    private func updateHover(at point: NSPoint) {
        guard duration > 0, !isInteracting, !isOverControls(point), seekArea.contains(point) else {
            clearHover(); return
        }
        if isOverAnalysisRow(point) {
            clearHover()
            return
        }
        hovering = !wantsFilm
        if wantsFilm {
            let seconds = filmTarget(at: point.x, in: filmLayout)
            filmHover = (point, seconds)
            onHover?(seconds / duration)
        } else {
            filmHover = nil
            onHover?(fraction(point.x))
        }
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        updateFilmPointer(event.locationInWindow)
        if isInRevealZone(event.locationInWindow), playbackVisible { showControls() }
        onEnterExit?()
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard seekArea.contains(point), !isOverControls(point) else { return }
        if isOverAnalysisRow(point) {
            clearHover()
            if let fragment = analysisFragment(at: point) { onAnalysisFragment?(fragment) }
            return
        }
        if wantsFilm, let cutEdges, point.y < film.minY + 12,
           let handle = cutEdgeHandles(in: filmLayout).first(where: { $0.rect.contains(point) }) {
            let layout = filmLayout
            onFilmPress?()
            cancelFilmScroll()
            cutEdgeGesture = CutEdgeGesture(edges: cutEdges, edge: handle.edge, layout: layout, startX: point.x,
                                            grabOffset: Double(handle.x - point.x))
            stopFilmTransition()
            clearHover()
            cancelFilmstripRequests()
            return
        }
        if wantsFilm, point.y >= film.maxY - 18,
           let marker = cutMarkers(in: filmLayout).first(where: { $0.rect.contains(point) }) {
            clearHover()
            onEditFragment?(marker.span)
            return
        }
        let caught = isFilmDragTransition || horizontalFilmMomentum
        if horizontalFilmScroll { cancelFilmScroll() }
        let clickedLayout = wantsFilm ? (caught ? makeFilmLayout(center: currentSeconds) : filmLayout) : nil
        if caught || !isAnimatingFilmClick { stopFilmTransition() }
        showControls()
        if let clickedLayout {
            onFilmPress?()
            if point.y <= film.minY + (cutEdges == nil ? 22 : 35), let index,
               let target = markHandles(in: clickedLayout)
                .filter({ $0.rect.insetBy(dx: -3, dy: -2).contains(point) })
                .min(by: { hypot($0.rect.midX - point.x, $0.rect.midY - point.y)
                    < hypot($1.rect.midX - point.x, $1.rect.midY - point.y) }) {
                stopFilmTransition()
                let offset = clickedLayout.lens.offset(for: index.seconds(forFrame: target.handle.frame))
                markDrag = (target.handle, clickedLayout, point.x, offset - Double(point.x - film.midX), false)
                clearHover()
                return
            }
            // Playback can move the lens between hover and click. Keep the destination we showed.
            if let filmHover, filmHover.point.x == point.x {
                pressedFilmTime = filmHover.seconds
            } else {
                pressedFilmTime = filmTarget(at: point.x, in: clickedLayout)
            }
            let last = cutTimeline == nil ? index?.seconds(forFrame: max(0, frameCount - 1)) ?? duration : duration
            let markSeconds = index.map { index in
                (marks.flatMap { [$0.lowerBound, $0.upperBound] } + [openMark].compactMap { $0 })
                    .map { index.seconds(forFrame: $0) }
            } ?? []
            let frameSeconds = index.flatMap { index -> Double? in
                guard frameCount > 1 else { return nil }
                let neighbor = position + (position < frameCount - 1 ? 1 : -1)
                return abs(index.seconds(forFrame: neighbor) - index.seconds(forFrame: position))
            }
            drag = TimelineFilmDrag(lens: clickedLayout.lens, lastFrameSeconds: last, pointer: point.x,
                                    timestamp: event.timestamp, caught: caught, markSeconds: markSeconds,
                                    frameSeconds: frameSeconds)
            clearHover()
        } else {
            overviewDrag = true; overviewMoved = false; onSeek?(fraction(point.x))
        }
    }
    private var pressedFilmTime: Double = 0
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var gesture = cutEdgeGesture {
            guard gesture.landing != nil || abs(point.x - gesture.startX) > 3, let index,
                  let landing = gesture.edges.landing(edge: gesture.edge,
                      at: gesture.layout.lens.time(at: Double(point.x - film.midX) + gesture.grabOffset),
                      index: index, duration: duration) else { return }
            if gesture.landing?.frame != landing.frame { onCutEdgePreview?(landing.frame) }
            gesture.landing = landing
            cutEdgeGesture = gesture
            needsDisplay = true
            return
        }
        if var markDrag {
            if !markDrag.started {
                guard abs(point.x - markDrag.startX) >= 3 else { return }
                guard onMarkDragBegin?(markDrag.handle) == true else { cancelMarkDrag(); return }
                markDrag.started = true
                self.markDrag = markDrag
            }
            onMarkDragMove?(markDrag.layout.lens.time(at: Double(point.x - film.midX) + markDrag.grabOffset))
            needsDisplay = true
            return
        }
        if var drag {
            let wasMoving = drag.hasMoved
            drag.move(to: point.x, at: event.timestamp,
                      precision: cutTimeline == nil && !event.modifierFlags.contains(.option))
            self.drag = drag
            guard drag.hasMoved else { return }
            if !wasMoving {
                stopFilmTransition()
                onFilmScrubBegan?()
            }
            filmStretch = allowsFilmDragMotion ? drag.stretch : 0
            let seek = cutTimeline == nil ? onFilmDrag ?? onFilmSeek : onFilmSeek
            seek?(drag.seconds)
            needsDisplay = true
        } else if overviewDrag {
            overviewMoved = true
            onSeek?(fraction(point.x))
        }
    }
    override func mouseUp(with event: NSEvent) {
        let completedDrag = drag?.hasMoved == true || (overviewDrag && overviewMoved)
        if let gesture = cutEdgeGesture {
            cutEdgeGesture = nil
            if let landing = gesture.landing, landing.time != gesture.edges.time(for: gesture.edge) {
                let start = gesture.edge == .start ? landing.time : gesture.edges.start
                let end = gesture.edge == .end ? landing.time : gesture.edges.end
                cutEdges = VirtualCutFragmentEdges(rangeID: gesture.edges.rangeID, start: start, end: end)
                onCutEdgeCommit?(gesture.edges, gesture.edge, landing.frame, landing.time)
            }
        } else if let markDrag {
            finishMarkDrag(commit: true)
            if !markDrag.started, let index { onFilmSeek?(index.seconds(forFrame: markDrag.handle.frame)) }
        } else if let drag, !drag.hasMoved, cutTimeline != nil {
            onFilmSeek?(pressedFilmTime)
        } else if let drag, !drag.hasMoved {
            let origin = filmLayout
            stopFilmTransition()
            if previewsSeekFrames, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let onFilmClickPreview {
                onFilmClickPreview(pressedFilmTime)
            } else {
                onFilmSeek?(pressedFilmTime)
            }
            animateFilmClick(from: origin)
        } else if let drag, allowsFilmDragMotion {
            finishFilmDrag(drag, timestamp: event.timestamp)
        }
        drag = nil; overviewDrag = false; requestedTimes = []
        if completedDrag { onScrubEnded?() }
        updateDesiredImages(); needsDisplay = true; scheduleControlHide()
        updateFilmPointer(event.locationInWindow)
        onEnterExit?()
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
    private var allowsFilmDragMotion: Bool {
        cutTimeline == nil && animatesFilmClicks && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func finishFilmDrag(_ drag: TimelineFilmDrag, timestamp: Double) {
        if filmStretch != 0 {
            let stretch = filmStretch
            let duration = 0.11
            isFilmDragTransition = true
            startFilmTransition(duration: duration) { view, elapsed in
                let remaining = 1 - elapsed / duration
                view.filmStretch = stretch * remaining * remaining * remaining
            }
        } else if let coast = drag.release(at: timestamp,
                                           duration: TimelineFilmDrag.Coast.defaultDuration * filmSeekPreviewSettings.motionScale),
                  let onFilmCoast {
            var lastSample = 0.0
            let duration = coast.duration
            isFilmDragTransition = true
            startFilmTransition(duration: duration) { view, elapsed in
                let target = coast.seconds(at: elapsed)
                if elapsed >= duration || elapsed - lastSample >= 1.0 / 30 {
                    lastSample = elapsed
                    guard onFilmCoast(target) else { view.stopFilmTransition(); return }
                }
                view.presentedFilmTime = target
            }
        }
    }

    func cancelFilmDragMotion() {
        if isFilmDragTransition { stopFilmTransition(); updateDesiredImages() }
        if horizontalFilmScroll { cancelFilmScroll(); needsDisplay = true }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !seekArea.isEmpty { addCursorRect(seekArea, cursor: wantsFilm ? .openHand : .pointingHand) }
    }
    /// Another input took over the playhead: its next film gesture must start at that new position.
    func cancelFilmScroll() {
        if isAnimatingFilmClick { stopFilmTransition() }
        scrollRest?.cancel(); scrollRest = nil
        horizontalFilmScroll = false; horizontalFilmMomentum = false
        scrolling = false; scrollHasSought = false; scrollTime = nil
    }

    /// A controller's relative movement in timeline points, using exactly the horizontal trackpad's local scale.
    /// Keep subframe target time between pulses even when the displayed playhead has rounded to a frame.
    func scrollFilm(by points: Double) {
        guard duration > 0, points.isFinite, points != 0 else { return }
        if horizontalFilmScroll { cancelFilmScroll() }
        hideFilmWork?.cancel(); hideFilmWork = nil
        if !showsFilmstrip { setFilmRevealed(true) }
        scrolling = true; scrollRest?.cancel(); showControls()
        if !scrollHasSought { scrollHasSought = true; onFilmScrubBegan?() }
        clearHover()
        moveFilm(by: points)
        scheduleFilmScrollRest()
        onEnterExit?()
    }

    private func moveFilm(by points: Double) {
        stopFilmTransition()
        let target = min(duration, max(0, (scrollTime ?? currentSeconds) + points * scale.secondsPerPoint))
        scrollTime = target
        if cutTimeline != nil || index?.frameNumber(forSeconds: target) != position { onFilmSeek?(target) }
    }

    private func scheduleFilmScrollRest() {
        let rest = DispatchWorkItem { [weak self] in
            guard let self else { return }
            horizontalFilmScroll = false; horizontalFilmMomentum = false
            let completedSeek = scrollHasSought
            scrolling = false; scrollHasSought = false; scrollTime = nil; scrollRest = nil
            if completedSeek { onScrubEnded?() }
            needsDisplay = true
            saveLensPreferences()
            updateDesiredImages(); updateFilmPointer(window?.mouseLocationOutsideOfEventStream)
        }
        scrollRest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: rest)
    }

    override func scrollWheel(with event: NSEvent) {
        guard cutEdgeGesture == nil, markDrag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let continuingMomentum = horizontalFilmScroll && !event.momentumPhase.isEmpty
        if wantsFilm, duration > 0, continuingMomentum || (seekArea.contains(point) && !isOverControls(point)) {
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            if !event.momentumPhase.isEmpty {
                guard horizontalFilmScroll, allowsFilmDragMotion else { return }
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    cancelFilmScroll(); updateDesiredImages(); needsDisplay = true
                } else if dx != 0 {
                    let target = min(duration, max(0, (scrollTime ?? currentSeconds) - dx * scale.secondsPerPoint))
                    guard onFilmCoast?(target) == true else {
                        cancelFilmScroll(); updateDesiredImages(); needsDisplay = true
                        return
                    }
                    scrollTime = target
                    horizontalFilmMomentum = true
                    scrollRest?.cancel()
                    scheduleFilmScrollRest()
                    needsDisplay = true
                }
                return
            }
            if horizontalFilmScroll, event.phase.contains(.cancelled) {
                cancelFilmScroll(); updateDesiredImages(); needsDisplay = true
                return
            }
            if event.phase.contains(.began) || (horizontalFilmScroll &&
                (!event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.option))) { cancelFilmScroll() }
            guard dx != 0 || dy != 0 else { return }
            if isAnimatingFilmClick { stopFilmTransition() }
            scrolling = true; scrollRest?.cancel(); showControls()
            clearHover()
            if !scrollHasSought, !event.modifierFlags.contains(.option) {
                scrollHasSought = true; onFilmScrubBegan?()
            }
            if event.modifierFlags.contains(.option) {
                let delta = abs(dx) > abs(dy) ? -dx : dy
                let amount = delta * (event.hasPreciseScrollingDeltas ? 0.02 : 0.2)
                if effectiveFilmMode == .segment { lensSeconds = min(30, max(0.1, lensSeconds * exp(amount))) }
                else { lensDensity = min(TimelineFilmLayout.maximumOutsideDensity, max(0.5, lensDensity * exp(-amount))) }
                requestedTimes = []; needsDisplay = true
            } else if event.hasPreciseScrollingDeltas && (horizontalFilmScroll || abs(dx) > abs(dy)) {
                horizontalFilmScroll = true
                moveFilm(by: -dx)
                needsDisplay = true
            } else {
                let sample = ScrollSample(deltaX: dx, deltaY: event.hasPreciseScrollingDeltas ? dy : -dy,
                    precise: event.hasPreciseScrollingDeltas,
                    momentum: false, began: event.phase.contains(.began), time: event.timestamp, modifiers: [])
                let steps = filmSteps.steps(for: sample)
                if steps != 0 {
                    let layout = filmLayout
                    let loaded = Set(layout.cells.compactMap(\.seconds).filter { images[imageTime($0)] != nil })
                    var tolerance = 0.0
                    if let index, frameCount > 1 {
                        let other = position < frameCount - 1 ? position + 1 : max(0, position - 1)
                        tolerance = abs(index.seconds(forFrame: other) - currentSeconds)
                    }
                    if let time = layout.stepSample(from: scrollTime ?? currentSeconds, by: steps,
                        available: loaded, tolerance: tolerance) {
                        scrollTime = time
                        transitionFilm(to: time)
                        onFilmSeek?(time)
                    }
                }
            }
            scheduleFilmScrollRest()
            onEnterExit?()
        } else { onScroll?(event) }
    }
    private func animateFilmClick(from origin: TimelineFilmLayout) {
        guard animatesFilmClicks, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              wantsFilm, abs(currentSeconds - origin.lens.center) > 1e-9 else { return }
        let motion = TimelineClickMotion(from: origin.lens.center, arrival: filmLayout.lens,
                                         durationScale: filmSeekPreviewSettings.motionScale)
        let start = motion.sample(elapsed: 0, target: currentSeconds)
        presentedFilmTime = start.center
        if start.outgoingOpacity > 0 { outgoingFilm = (origin, CGFloat(start.outgoingOpacity)) }
        startFilmTransition(duration: motion.duration) { view, elapsed in
            let sample = motion.sample(elapsed: elapsed, target: view.currentSeconds)
            view.presentedFilmTime = sample.center
            view.outgoingFilm = sample.outgoingOpacity > 0 ? (origin, CGFloat(sample.outgoingOpacity)) : nil
        }
    }

    /// A finite geometry-only transition; it never decodes a frame or creates an idle display link.
    private func transitionFilm(to seconds: Double) {
        let from = presentedFilmTime ?? currentSeconds
        stopFilmTransition()
        guard let index, allowsFilmDragMotion else { return }
        let frame = index.frameNumber(forSeconds: seconds)
        let target = index.seconds(forFrame: frame)
        guard abs(target - from) > 1e-9 else { return }
        transitionFrame = frame; presentedFilmTime = from
        let duration = 0.18 * filmSeekPreviewSettings.motionScale
        startFilmTransition(duration: duration) { view, elapsed in
            view.presentedFilmTime = from + (target - from) * (1 - pow(1 - elapsed / duration, 3))
            view.needsDisplay = true
            view.displayIfNeeded()
        }
    }
    private func startFilmTransition(duration: Double, update: @escaping @MainActor (SeekBarView, Double) -> Void) {
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.wantsFilm, self.alphaValue > 0.01, self.window?.occlusionState.contains(.visible) == true else {
                    self.stopFilmTransition(); return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let wasDragMotion = self.isFilmDragTransition
                update(self, min(elapsed, duration))
                if elapsed >= duration || self.filmTransition == nil {
                    self.stopFilmTransition()
                    self.updateDesiredImages()
                    if wasDragMotion { self.updateFilmPointer(self.window?.mouseLocationOutsideOfEventStream) }
                }
                self.needsDisplay = true
            }
        }
        filmTransition = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopFilmTransition() {
        if presentedFilmTime != nil || filmStretch != 0 { needsDisplay = true }
        filmTransition?.invalidate(); filmTransition = nil; presentedFilmTime = nil; transitionFrame = nil
        outgoingFilm = nil
        isFilmDragTransition = false; filmStretch = 0
    }
    private func fraction(_ x: CGFloat) -> Double { min(1, max(0, Double((x - track.minX) / max(1, track.width)))) }
    private func showControls() {
        hideControls?.cancel()
        if transport.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                transport.animator().alphaValue = 1
                modeControl.animator().alphaValue = 1
            }
        }
    }
    private func scheduleControlHide() {
        hideControls?.cancel()
        guard !alwaysControls else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !pointerInside, !isInteracting else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.transport.animator().alphaValue = 0; self.modeControl.animator().alphaValue = 0
            }
        }
        hideControls = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Timeline")
        menu.delegate = self
        let point = convert(event.locationInWindow, from: nil)
        let seconds = wantsFilm ? filmTarget(at: point.x, in: filmLayout) : fraction(point.x) * duration
        if let span = cutTimeline?.location(at: seconds)?.spanIndex {
            let item = NSMenuItem(title: "Edit This Fragment", action: #selector(editFragment(_:)), keyEquivalent: "")
            item.target = self; item.tag = span; menu.addItem(item)
            menu.addItem(.separator())
        }
        for (title, value) in [("Hide Filmstrip", 0), ("Small Thumbnails", 36), ("Medium Thumbnails", 64), ("Large Thumbnails", 96)] {
            let item = NSMenuItem(title: title, action: #selector(setFilmHeight(_:)), keyEquivalent: "")
            item.target = self; item.tag = value; item.state = Int(stripHeight) == value ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let lens = NSMenuItem(title: "Time Lens…", action: #selector(showLensControls), keyEquivalent: "")
        lens.target = self; menu.addItem(lens)
        for mode in TimelineFilmMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectFilmMode(_:)), keyEquivalent: "")
            item.target = self; item.tag = mode.rawValue; item.state = effectiveFilmMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let inertia = NSMenuItem(title: "Inertial Filmstrip Motion", action: #selector(toggleFilmClickInertia), keyEquivalent: "")
        inertia.target = self; inertia.state = animatesFilmClicks ? .on : .off; menu.addItem(inertia)
        let pin = NSMenuItem(title: "Pin Filmstrip (⌥⌘L)", action: #selector(pinFilm), keyEquivalent: "")
        pin.target = self; pin.state = filmPinned ? .on : .off; menu.addItem(pin)
        let hide = NSMenuItem(title: "Fold Filmstrip (⌘L)", action: #selector(foldFilm), keyEquivalent: "")
        hide.target = self; menu.addItem(hide)
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Always Show Playback Controls", action: #selector(toggleAlwaysControls), keyEquivalent: "")
        item.target = self; item.state = alwaysControls ? .on : .off; menu.addItem(item)
        return menu
    }

    @objc private func editFragment(_ item: NSMenuItem) { onEditFragment?(item.tag) }
    func menuWillOpen(_ menu: NSMenu) {
        if isAnimatingFilmClick { stopFilmTransition() }
        contextMenuOpen = true; hideFilmWork?.cancel(); hideFilmWork = nil; showControls()
        clearHover()
    }
    func menuDidClose(_ menu: NSMenu) {
        contextMenuOpen = false
        updateFilmPointer(window?.mouseLocationOutsideOfEventStream)
        updateDesiredImages(); scheduleControlHide(); onEnterExit?()
    }
    @objc private func showLensControls() {
        if lensPopover.isShown { lensPopover.performClose(nil); return }
        clearHover()
        stopFilmTransition()
        if filmstripEnabled { setFilmRevealed(true) }
        let panel: TimelineLensControls
        if let existing = lensPopover.contentViewController as? TimelineLensControls { panel = existing }
        else {
            panel = TimelineLensControls()
            panel.onChange = { [weak self] seconds, focus, crop, magnification, density in
                self?.configureLens(seconds: seconds, focus: focus, crop: crop, magnification: magnification, density: density)
            }
            panel.onHeightChange = { [weak self] in self?.configureFilmHeight($0) }
            panel.onFramePreviewChange = { [weak self] enabled in
                self?.previewsSeekFrames = enabled
                UserDefaults.standard.set(enabled, forKey: "timeline-click-preview-frames")
            }
            panel.onPreviewTuningChange = { [weak self] settings in
                self?.filmSeekPreviewSettings = settings
                UserDefaults.standard.set(settings.milliseconds, forKey: "timeline-preview-duration-ms")
                UserDefaults.standard.set(settings.rateIndex, forKey: "timeline-preview-rate")
            }
            panel.onInertiaChange = { [weak self] enabled in
                self?.animatesFilmClicks = enabled
                UserDefaults.standard.set(enabled, forKey: "timeline-click-inertia")
            }
            lensPopover.contentViewController = panel
            lensPopover.behavior = .transient; lensPopover.delegate = self
        }
        panel.setValues(seconds: lensSeconds, focus: lensFocus, crop: lensCrop,
                        magnification: lensMagnification, density: lensDensity, mode: effectiveFilmMode, height: Double(stripHeight))
        panel.previewsSeekFrames = previewsSeekFrames
        panel.previewSettings = filmSeekPreviewSettings
        panel.animatesFilmstrip = animatesFilmClicks
        lensPopover.show(relativeTo: NSRect(x: bounds.midX - 1, y: film.minY, width: 2, height: visibleFilmHeight),
                         of: self, preferredEdge: .maxY)
    }
    @objc private func selectFilmMode(_ item: NSMenuItem) {
        if let mode = TimelineFilmMode(rawValue: item.tag) { setFilmMode(mode) }
    }
    func popoverDidClose(_ notification: Notification) {
        saveLensPreferences()
        updateFilmPointer(window?.mouseLocationOutsideOfEventStream)
        updateDesiredImages(); scheduleControlHide(); onEnterExit?()
    }
    @objc private func setFilmHeight(_ item: NSMenuItem) {
        applyFilmHeight(CGFloat(item.tag), save: true)
    }
    private func applyFilmHeight(_ height: CGFloat, save: Bool) {
        stopFilmTransition()
        clearHover()
        stripHeight = height
        cancelFilmstripRequests()
        if save { UserDefaults.standard.set(Double(stripHeight), forKey: "timeline-film-height") }
        if stripHeight > 0 { filmAutoRevealSuppressed = false; filmRevealed = true }
        else {
            filmRevealed = false; filmPinned = false
            UserDefaults.standard.set(false, forKey: "timeline-film-pinned")
        }
        onHeightChange?(preferredHeight); requestedTimes = []; needsLayout = true; needsDisplay = true
    }
    @objc private func pinFilm() { toggleFilmPin() }
    @objc private func foldFilm() { toggleFilmVisibility() }
    @objc private func toggleFilmClickInertia() {
        animatesFilmClicks.toggle()
        UserDefaults.standard.set(animatesFilmClicks, forKey: "timeline-click-inertia")
    }
    @objc private func toggleAlwaysControls() {
        alwaysControls.toggle(); UserDefaults.standard.set(alwaysControls, forKey: "timeline-controls-always")
        if alwaysControls { setPlaybackControlsVisible(true) }
        onEnterExit?()
    }
}
