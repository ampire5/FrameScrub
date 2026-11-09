import AppKit
import FrameScrubCore

/// The filmstrip is the seek surface when visible. A compact track takes over when folded.
final class SeekBarView: NSView, NSMenuDelegate, NSPopoverDelegate {
    var onSeek: ((Double) -> Void)?
    var onFilmSeek: ((Double) -> Void)?
    var onFilmstripRequest: (([Double]) -> Void)?
    var onFilmstripFold: (() -> Void)?
    var onHover: ((Double?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onEnterExit: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onFilmScrubBegan: (() -> Void)?
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
    private var images: [Double: NSImage] = [:]
    private var imageOrder: [Double] = []
    private var drag: (layout: TimelineFilmLayout, x: CGFloat, moved: Bool)?
    private var overviewDrag = false
    private var stripHeight: CGFloat = UserDefaults.standard.object(forKey: "timeline-film-height") == nil ? 48
        : min(96, max(0, CGFloat(UserDefaults.standard.double(forKey: "timeline-film-height"))))
    private var alwaysControls = UserDefaults.standard.bool(forKey: "timeline-controls-always")
    var filmstripEnabled: Bool { stripHeight > 0 }
    var showsFilmstrip: Bool { filmstripEnabled && (filmRevealed || filmPinned) }
    private var wantsFilm: Bool { showsFilmstrip }
    private var visibleFilmHeight: CGFloat { showsFilmstrip ? stripHeight : 0 }
    var isThumbnailInteraction: Bool { drag != nil || overviewDrag || scrolling || contextMenuOpen || transport.holding }
    var isInteracting: Bool { isThumbnailInteraction || lensPopover.isShown }
    var isAnimatingFilm: Bool { filmTransition != nil }
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
    var virtualTime: Double?
    private var currentSeconds: Double { virtualTime ?? index?.seconds(forFrame: position) ?? 0 }

    func updateVirtualCut(time: Double, duration: Double, paused: Bool) {
        virtualTime = time
        updateTimeline(index: nil, duration: duration, paused: paused)
        let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
        update(frameCount: 10_001, position: Int((10_000 * fraction).rounded()), cached: [],
               loopA: nil, loopB: nil,
               text: "\(FrameNaming.timecode(time)) / \(FrameNaming.timecode(duration))")
    }
    private var filmLayout: TimelineFilmLayout {
        let displayedTime = presentedFilmTime ?? currentSeconds
        let key = [Double(film.width), Double(stripHeight), Double(pictureAspect), duration, displayedTime,
                   lensSeconds, lensFocus, lensCrop, Double(filmMode.rawValue), lensMagnification, lensDensity]
        if cachedFilmLayout == nil || layoutKey != key {
            cachedFilmLayout = makeFilmLayout(center: displayedTime)
            layoutKey = key
        }
        return cachedFilmLayout!
    }
    private func makeFilmLayout(center: Double) -> TimelineFilmLayout {
        TimelineFilmLayout(width: Double(film.width), height: Double(stripHeight), aspect: Double(pictureAspect),
            duration: duration, center: center, secondsPerThumbnail: lensSeconds, focusFraction: lensFocus,
            cropStrength: lensCrop, mode: filmMode, magnification: lensMagnification, outsideDensity: lensDensity)
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
        } else if !filmPinned, !isInteracting, filmRevealed, hideFilmWork == nil {
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
            stopFilmTransition()
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
        guard filmMode != mode else { return }
        stopFilmTransition()
        drag = nil; scrollRest?.cancel(); scrollRest = nil; scrolling = false; scrollHasSought = false; scrollTime = nil
        clearHover()
        filmMode = mode; modeControl.setMode(mode)
        if save { UserDefaults.standard.set(mode.rawValue, forKey: "timeline-film-mode") }
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
        guard let index, index.isExact else { return (seconds * 10).rounded() / 10 }
        return index.seconds(forFrame: index.keyframe(atOrBefore: index.frameNumber(forSeconds: seconds)))
    }
    private func updateDesiredImages() {
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
        images[seconds] = NSImage(cgImage: image, size: .zero)
        imageOrder.removeAll { $0 == seconds }; imageOrder.append(seconds)
        // Two bounded screenfuls; decoder concurrency is still one.
        while imageOrder.count > TimelineFilmLayout.maximumCells * 2 { images[imageOrder.removeFirst()] = nil }
        // A completion already in flight may arrive after folding. Keep it cached without waking the view.
        guard wantsFilm, !isHidden, alphaValue > 0.01,
              window?.occlusionState.contains(.visible) == true else { return }
        needsDisplay = true
        // Paused video may have no subsequent input event to refresh AppKit's backing store.
        if !isHidden, alphaValue > 0.01, window != nil { displayIfNeeded() }
    }
    func resetFilmstrip() {
        stopFilmTransition()
        thumbnailDwell?.cancel(); thumbnailDwell = nil
        images.removeAll(); imageOrder.removeAll(); requestedTimes = []; desiredTimes = []
        drag = nil; overviewDrag = false
        clearHover()
        scrollRest?.cancel(); scrollRest = nil; scrolling = false; scrollHasSought = false; scrollTime = nil
        needsDisplay = true
    }
    func cancelInteraction() {
        stopFilmTransition()
        drag = nil; overviewDrag = false
        clearHover()
        scrollRest?.cancel(); scrollRest = nil; scrolling = false; scrollHasSought = false; scrollTime = nil
        updateFilmPointer(nil)
        cancelFilmstripRequests()
        scheduleControlHide()
        needsDisplay = true
    }
    func refreshVisibility() {
        if window?.occlusionState.contains(.visible) != true || alphaValue <= 0.01 {
            stopFilmTransition()
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
        guard playbackVisible else { return }
        if !wantsFilm { drawPositionRanges(in: track) }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                  .foregroundColor: NSColor(white: 1, alpha: 0.84)]
        let time = compactTime(currentSeconds) as NSString
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
    private func drawFilm() {
        let layout = filmLayout
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: film).addClip()
        for cell in layout.cells {
            guard let seconds = cell.seconds else { continue }
            let rect = NSRect(x: film.midX + CGFloat(cell.offset - cell.width / 2), y: film.minY,
                              width: max(0, CGFloat(cell.width) - 2), height: film.height)
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            if let image = images[imageTime(seconds)] {
                FilmstripThumbnail.draw(image, geometry: pictureGeometry, in: rect, opacity: 0.85,
                                            cropToFill: cell.cropped, cropAmount: cell.cropAmount)
            }
        }
        if playbackVisible {
            let edge = NSRect(x: film.minX, y: film.minY, width: film.width, height: 2)
            drawPositionRanges(in: edge, projection: layout.lens)
        }
        let head = min(film.maxX - 1, max(film.minX + 1, film.midX + CGFloat(layout.playheadOffset))).rounded()
        NSColor(white: 0, alpha: 0.65).setFill()
        NSRect(x: head - 2, y: film.minY, width: 4, height: film.height).fill()
        NSColor.white.setFill()
        NSRect(x: head - 1, y: film.minY, width: 2, height: film.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        if previewFrame != nil, let point = filmPointer {
            let cursorX = min(film.maxX - 1, max(film.minX + 1, point.x)).rounded()
            drawFilmCursor(at: cursorX, overPlayhead: abs(cursorX - head) <= 3)
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
        NSColor.white.setFill()
        let head = x(for: position)
        NSBezierPath(ovalIn: NSRect(x: head - 5, y: track.midY - 5, width: 10, height: 10)).fill()
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
        let clickedLayout = wantsFilm ? filmLayout : nil
        stopFilmTransition()
        showControls()
        if let clickedLayout {
            // Playback can move the lens between hover and click. Keep the destination we showed.
            if let filmHover, filmHover.point.x == point.x {
                pressedFilmTime = filmHover.seconds
            } else {
                pressedFilmTime = filmTarget(at: point.x, in: clickedLayout)
            }
            drag = (clickedLayout, 0, false)
            dragStartX = point.x
            clearHover()
        } else {
            overviewDrag = true; onSeek?(fraction(point.x))
        }
    }
    private var dragStartX: CGFloat = 0
    private var pressedFilmTime: Double = 0
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var drag {
            let wasMoving = drag.moved
            drag.x = point.x - dragStartX
            drag.moved = drag.moved || abs(drag.x) > 6
            self.drag = drag
            guard drag.moved else { return }
            if !wasMoving { onFilmScrubBegan?() }
            onFilmSeek?(drag.layout.lens.time(at: drag.layout.playheadOffset - Double(drag.x)))
            needsDisplay = true
        } else if overviewDrag { onSeek?(fraction(point.x)) }
    }
    override func mouseUp(with event: NSEvent) {
        if let drag, !drag.moved { onFilmSeek?(pressedFilmTime) }
        drag = nil; overviewDrag = false; requestedTimes = []
        updateDesiredImages(); needsDisplay = true; scheduleControlHide()
        updateFilmPointer(event.locationInWindow)
        onEnterExit?()
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !seekArea.isEmpty { addCursorRect(seekArea, cursor: wantsFilm ? .openHand : .pointingHand) }
    }
    /// Another input took over the playhead: its next film gesture must start at that new position.
    func cancelFilmScroll() {
        scrollRest?.cancel(); scrollRest = nil
        scrolling = false; scrollHasSought = false; scrollTime = nil
    }

    /// A controller's relative movement in timeline points, using exactly the horizontal trackpad's local scale.
    /// Keep subframe target time between pulses even when the displayed playhead has rounded to a frame.
    func scrollFilm(by points: Double) {
        guard duration > 0, points.isFinite, points != 0 else { return }
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
        onFilmSeek?(target)
    }

    private func scheduleFilmScrollRest() {
        let rest = DispatchWorkItem { [weak self] in
            guard let self else { return }
            scrolling = false; scrollHasSought = false; scrollTime = nil; scrollRest = nil
            saveLensPreferences()
            updateDesiredImages(); updateFilmPointer(window?.mouseLocationOutsideOfEventStream)
        }
        scrollRest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: rest)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if wantsFilm, seekArea.contains(point), !isOverControls(point), duration > 0 {
            guard event.momentumPhase.isEmpty else { return }
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            guard dx != 0 || dy != 0 else { return }
            scrolling = true; scrollRest?.cancel(); showControls()
            clearHover()
            if !scrollHasSought, !event.modifierFlags.contains(.option) {
                scrollHasSought = true; onFilmScrubBegan?()
            }
            if event.modifierFlags.contains(.option) {
                let delta = abs(dx) > abs(dy) ? -dx : dy
                let amount = delta * (event.hasPreciseScrollingDeltas ? 0.02 : 0.2)
                if filmMode == .segment { lensSeconds = min(30, max(0.1, lensSeconds * exp(amount))) }
                else { lensDensity = min(TimelineFilmLayout.maximumOutsideDensity, max(0.5, lensDensity * exp(-amount))) }
                requestedTimes = []; needsDisplay = true
            } else if event.hasPreciseScrollingDeltas && abs(dx) > abs(dy) {
                if event.phase.contains(.began) { scrollTime = nil }
                moveFilm(by: -dx)
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
    /// A finite geometry-only transition; it never decodes a frame or creates an idle display link.
    private func transitionFilm(to seconds: Double) {
        let from = presentedFilmTime ?? currentSeconds
        stopFilmTransition()
        guard let index, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let frame = index.frameNumber(forSeconds: seconds)
        let target = index.seconds(forFrame: frame)
        guard abs(target - from) > 1e-9 else { return }
        transitionFrame = frame; presentedFilmTime = from
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.wantsFilm, self.alphaValue > 0.01, self.window?.occlusionState.contains(.visible) == true else {
                    self.stopFilmTransition(); return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.14)
                self.presentedFilmTime = from + (target - from) * (1 - pow(1 - progress, 3))
                if progress >= 1 { self.stopFilmTransition() }
                self.needsDisplay = true
                self.displayIfNeeded()
            }
        }
        filmTransition = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopFilmTransition() {
        filmTransition?.invalidate(); filmTransition = nil; presentedFilmTime = nil; transitionFrame = nil
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
        for (title, value) in [("Hide Filmstrip", 0), ("Small Thumbnails", 36), ("Medium Thumbnails", 64), ("Large Thumbnails", 96)] {
            let item = NSMenuItem(title: title, action: #selector(setFilmHeight(_:)), keyEquivalent: "")
            item.target = self; item.tag = value; item.state = Int(stripHeight) == value ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let lens = NSMenuItem(title: "Time Lens…", action: #selector(showLensControls), keyEquivalent: "")
        lens.target = self; menu.addItem(lens)
        for mode in TimelineFilmMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectFilmMode(_:)), keyEquivalent: "")
            item.target = self; item.tag = mode.rawValue; item.state = filmMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pin = NSMenuItem(title: "Pin Filmstrip (⌥⌘L)", action: #selector(pinFilm), keyEquivalent: "")
        pin.target = self; pin.state = filmPinned ? .on : .off; menu.addItem(pin)
        let hide = NSMenuItem(title: "Fold Filmstrip (⌘L)", action: #selector(foldFilm), keyEquivalent: "")
        hide.target = self; menu.addItem(hide)
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Always Show Playback Controls", action: #selector(toggleAlwaysControls), keyEquivalent: "")
        item.target = self; item.state = alwaysControls ? .on : .off; menu.addItem(item)
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) {
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
            lensPopover.contentViewController = panel
            lensPopover.behavior = .transient; lensPopover.delegate = self
        }
        panel.setValues(seconds: lensSeconds, focus: lensFocus, crop: lensCrop,
                        magnification: lensMagnification, density: lensDensity, mode: filmMode, height: Double(stripHeight))
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
    @objc private func toggleAlwaysControls() {
        alwaysControls.toggle(); UserDefaults.standard.set(alwaysControls, forKey: "timeline-controls-always")
        if alwaysControls { setPlaybackControlsVisible(true) }
        onEnterExit?()
    }
}
