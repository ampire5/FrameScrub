import AppKit
import FrameScrubCore

/// Full-width time lens and an independent linear overview. Only the small transport capsules overlap video.
final class SeekBarView: NSView, NSMenuDelegate, NSPopoverDelegate {
    var onSeek: ((Double) -> Void)?
    var onFilmSeek: ((Double) -> Void)?
    var onFilmstripRequest: (([Double]) -> Void)?
    var onHover: ((Double?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onEnterExit: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onFilmScrubBegan: (() -> Void)?
    let transport = TransportControls()
    let filmHover = FilmstripThumbnailView()
    let modeControl = TimelineModeControl()
    private(set) var filmMode = TimelineFilmMode(rawValue: UserDefaults.standard.integer(forKey: "timeline-film-mode")) ?? .lens
    private var filmPointer: NSPoint?
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
    private var playbackVisible = true
    private var contextMenuOpen = false
    private var dismissedInZone = false
    private(set) var filmPinned = UserDefaults.standard.bool(forKey: "timeline-film-pinned")
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
    var preferredHeight: CGFloat { visibleFilmHeight + 76 }
    private var film: NSRect { NSRect(x: 12, y: 29, width: max(0, bounds.width - 24), height: visibleFilmHeight) }
    private var track: NSRect { NSRect(x: 12, y: hovering ? 6 : 7, width: max(0, bounds.width - 24), height: hovering ? 5 : 3) }
    private var currentSeconds: Double { index?.seconds(forFrame: position) ?? 0 }
    private var filmLayout: TimelineFilmLayout {
        let displayedTime = presentedFilmTime ?? currentSeconds
        let key = [Double(film.width), Double(stripHeight), Double(pictureAspect), duration, displayedTime,
                   lensSeconds, lensFocus, lensCrop, Double(filmMode.rawValue), lensMagnification, lensDensity]
        if cachedFilmLayout == nil || layoutKey != key {
            cachedFilmLayout = TimelineFilmLayout(width: key[0], height: key[1], aspect: key[2], duration: duration,
                center: displayedTime, secondsPerThumbnail: lensSeconds, focusFraction: lensFocus, cropStrength: lensCrop,
                mode: filmMode, magnification: lensMagnification, outsideDensity: lensDensity)
            layoutKey = key
        }
        return cachedFilmLayout!
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
        modeControl.onSelect = { [weak self] in self?.setFilmMode($0) }
        modeControl.onSettings = { [weak self] in self?.showLensControls() }
        addSubview(modeControl)
        filmHover.isHidden = true
        addSubview(filmHover)
        addSubview(transport, positioned: .above, relativeTo: filmHover)
        addSubview(modeControl, positioned: .above, relativeTo: transport)
        transport.onHold = { [weak self] in
            self?.showControls(); self?.scheduleControlHide(); self?.updateDesiredImages(); self?.onEnterExit?()
        }
        setAccessibilityLabel("Video timeline")
        setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { hideControls?.cancel(); thumbnailDwell?.cancel(); hideFilmWork?.cancel(); scrollRest?.cancel(); filmTransition?.invalidate() }

    override func layout() {
        super.layout()
        transport.frame = NSRect(x: 12, y: visibleFilmHeight + 35, width: max(0, bounds.width - 24), height: 34)
        modeControl.isHidden = !showsFilmstrip
        modeControl.frame = bounds.width >= 420
            ? NSRect(x: bounds.width - 276, y: visibleFilmHeight + 38, width: 126, height: 28)
            : NSRect(x: 44, y: 10, width: 90, height: 19)
        transport.layoutSubtreeIfNeeded()
        updateDesiredImages()
        updateFilmHover()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    /// The reveal zone keeps its coordinates when the film is folded; only its actual content is collapsed.
    func updateFilmPointer(_ pointInWindow: NSPoint?) {
        let point = pointInWindow.map { convert($0, from: nil) }
        let zone = NSRect(x: 0, y: 24, width: bounds.width, height: stripHeight + 12)
        let inside = filmstripEnabled && point.map { p in
            zone.contains(p) || (!filmHover.isHidden && filmHover.frame.contains(p)) ||
                (!modeControl.isHidden && modeControl.alphaValue > 0.01 && modeControl.frame.contains(p)) ||
                transport.occupiedRects.contains(where: { $0.contains(p) })
        } == true
        if !inside { dismissedInZone = false }
        if inside, !dismissedInZone {
            hideFilmWork?.cancel(); hideFilmWork = nil
            setFilmRevealed(true)
        } else if !filmPinned, !isInteracting, filmRevealed, hideFilmWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                hideFilmWork = nil
                if !isInteracting { setFilmRevealed(false) }
            }
            hideFilmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
    func setFilmRevealed(_ shown: Bool, force: Bool = false) {
        guard force || filmRevealed != shown else { return }
        filmRevealed = shown
        if !showsFilmstrip {
            stopFilmTransition()
            cancelFilmstripRequests(); filmPointer = nil; filmHover.isHidden = true
        }
        onHeightChange?(preferredHeight)
        needsLayout = true; needsDisplay = true
        layoutSubtreeIfNeeded(); updateDesiredImages()
    }
    func toggleFilmVisibility() {
        if !filmstripEnabled { stripHeight = 48; UserDefaults.standard.set(48, forKey: "timeline-film-height") }
        if showsFilmstrip {
            filmPinned = false; UserDefaults.standard.set(false, forKey: "timeline-film-pinned")
            dismissedInZone = true; setFilmRevealed(false, force: true)
        } else { dismissedInZone = false; setFilmRevealed(true) }
        onEnterExit?()
    }
    func toggleFilmPin() {
        if !filmstripEnabled { stripHeight = 48; UserDefaults.standard.set(48, forKey: "timeline-film-height") }
        filmPinned.toggle(); UserDefaults.standard.set(filmPinned, forKey: "timeline-film-pinned")
        dismissedInZone = false
        if filmPinned { setFilmRevealed(true, force: true) }
        else { setFilmRevealed(false, force: true) }
        onEnterExit?()
    }
    func revealPlaybackControls() { showControls() }
    func setFilmMode(_ mode: TimelineFilmMode, save: Bool = true) {
        guard filmMode != mode else { return }
        stopFilmTransition()
        drag = nil; scrollRest?.cancel(); scrollRest = nil; scrolling = false; scrollHasSought = false; scrollTime = nil
        filmMode = mode; modeControl.setMode(mode)
        if save { UserDefaults.standard.set(mode.rawValue, forKey: "timeline-film-mode") }
        requestedTimes = []; updateDesiredImages(); updateFilmHover(); needsDisplay = true
        onEnterExit?()
    }
    func configureLens(seconds: Double, focus: Double, crop: Double, magnification: Double? = nil,
                       density: Double? = nil, save: Bool = true) {
        stopFilmTransition()
        lensSeconds = seconds.isFinite ? min(30, max(0.1, seconds)) : 1
        lensFocus = focus.isFinite ? min(0.75, max(0.08, focus)) : 0.3
        lensCrop = crop.isFinite ? min(1, max(0, crop)) : 0.7
        if let magnification { lensMagnification = magnification.isFinite ? min(3.8, max(1, magnification)) : 2.75 }
        if let density { lensDensity = density.isFinite ? min(4, max(0.5, density)) : 2.75 }
        if save { saveLensPreferences() }
        requestedTimes = []; updateDesiredImages(); updateFilmHover(); needsDisplay = true
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
    func setPlaybackControlsVisible(_ shown: Bool) {
        playbackVisible = shown
        if shown { showControls() }
        else {
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
        updateFilmHover()
        if playbackVisible || wantsFilm { needsDisplay = true }
    }
    /// Requested times have already been snapped to inexpensive keyframes, never decoded on this thread.
    private func imageTime(_ seconds: Double) -> Double {
        guard let index, index.isExact else { return (seconds * 10).rounded() / 10 }
        return index.seconds(forFrame: index.keyframe(atOrBefore: index.frameNumber(forSeconds: seconds)))
    }
    private func updateDesiredImages() {
        guard wantsFilm, film.width > 0, let index, index.frameCount > 0 else {
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
        updateFilmHover()
        needsDisplay = true
        // Paused video may have no subsequent input event to refresh AppKit's backing store.
        if !isHidden, alphaValue > 0.01, window != nil { displayIfNeeded() }
    }
    func resetFilmstrip() {
        stopFilmTransition()
        thumbnailDwell?.cancel(); thumbnailDwell = nil
        images.removeAll(); imageOrder.removeAll(); requestedTimes = []; desiredTimes = []
        drag = nil; overviewDrag = false
        filmPointer = nil; filmHover.isHidden = true
        scrollRest?.cancel(); scrollRest = nil; scrolling = false; scrollHasSought = false; scrollTime = nil
        needsDisplay = true
    }
    func cancelInteraction() {
        stopFilmTransition()
        drag = nil; overviewDrag = false
        filmPointer = nil; filmHover.isHidden = true
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
        NSColor(white: 0, alpha: 0.58).setFill()
        if playbackVisible || wantsFilm {
            let bottom: CGFloat = playbackVisible ? 0 : 29
            NSBezierPath(roundedRect: NSRect(x: 0, y: bottom, width: bounds.width,
                                            height: visibleFilmHeight + 32 - bottom), xRadius: 8, yRadius: 8).fill()
        }
        if playbackVisible { drawOverview() }
        if wantsFilm, duration > 0 { drawFilm() }
        guard playbackVisible else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                  .foregroundColor: NSColor(white: 1, alpha: 0.84)]
        let time = compactTime(currentSeconds) as NSString
        let labelWidth = time.size(withAttributes: attrs).width
        let timeX = bounds.width < 420 && showsFilmstrip ? max(bounds.midX, modeControl.frame.maxX + 8 + labelWidth / 2) : bounds.midX
        time.draw(at: NSPoint(x: timeX - labelWidth / 2, y: 14), withAttributes: attrs)
        ("0:00" as NSString).draw(at: NSPoint(x: 12, y: 14), withAttributes: attrs)
        let end = compactTime(duration) as NSString
        end.draw(at: NSPoint(x: bounds.width - 12 - end.size(withAttributes: attrs).width, y: 14), withAttributes: attrs)
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
                FilmstripThumbnailView.draw(image, geometry: pictureGeometry, in: rect, opacity: 0.85,
                                            cropToFill: cell.cropped, cropAmount: cell.cropAmount)
            }
            if drag == nil, let point = filmPointer, rect.contains(point) {
                NSColor.white.withAlphaComponent(0.8).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1; outline.stroke()
            }
            let label = compactTime(seconds) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                       .foregroundColor: NSColor.white,
                                                       .backgroundColor: NSColor.black.withAlphaComponent(0.6)]
            if rect.width >= label.size(withAttributes: attrs).width + 6 {
                label.draw(at: NSPoint(x: rect.midX - label.size(withAttributes: attrs).width / 2, y: rect.minY + 2), withAttributes: attrs)
            }
        }
        NSColor.white.setFill()
        NSRect(x: film.midX + CGFloat(layout.playheadOffset) - 1, y: film.minY, width: 2, height: film.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    private func updateFilmHover() {
        guard let point = filmPointer, wantsFilm, film.contains(point), drag == nil,
              let cell = filmLayout.cell(at: Double(point.x - film.midX)), let seconds = cell.seconds,
              let image = images[imageTime(seconds)] else { filmHover.isHidden = true; return }
        let bottom = film.minY + 1
        var height = min(stripHeight * 1.7, bounds.height - bottom - 4)
        let center = film.midX + CGFloat(cell.offset)
        func frame(_ height: CGFloat) -> NSRect {
            let width = min(film.width, height * pictureAspect + 6)
            return NSRect(x: min(film.maxX - width, max(film.minX, center - width / 2)),
                          y: bottom, width: width, height: height)
        }
        let obstacles = transport.occupiedRects + (modeControl.isHidden ? [] : [modeControl.frame])
        // Near the edges show the complete picture below the controls, rather than growing over them.
        for obstacle in obstacles where obstacle.minY > bottom && frame(height).intersects(obstacle) {
            height = min(height, max(1, obstacle.minY - bottom - 4))
        }
        filmHover.frame = frame(height)
        filmHover.image = image; filmHover.geometry = pictureGeometry; filmHover.time = compactTime(seconds)
        filmHover.seconds = seconds
        filmHover.isHidden = false; filmHover.needsDisplay = true
    }
    private func compactTime(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
    private func drawOverview() {
        NSColor(white: 1, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
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
        if hovering, let previewFrame {
            NSColor(white: 1, alpha: 0.9).setFill()
            NSRect(x: x(for: previewFrame).rounded() - 1, y: track.minY - 3, width: 2, height: track.height + 6).fill()
        }
        NSColor.systemYellow.setFill()
        for marker in [loopA, loopB].compactMap({ $0 }) {
            NSRect(x: x(for: marker) - 1, y: track.minY - 4, width: 2, height: track.height + 8).fill()
        }
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
        if !filmHover.isHidden, filmHover.frame.contains(local) { return self }
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self, !playbackVisible, local.y < 29 { return nil }
        // The transparent area above the film overlays the video; it is not a reserved toolbar row.
        return hit === self && local.y > visibleFilmHeight + 32 ? nil : hit
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true; updateFilmPointer(event.locationInWindow); showControls(); onEnterExit?()
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false; hovering = false; filmPointer = nil; filmHover.isHidden = true
        updateFilmPointer(event.locationInWindow)
        onHover?(nil); scheduleControlHide(); onEnterExit?(); needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateFilmPointer(event.locationInWindow)
        let onOverview = point.y < 14
        hovering = onOverview
        let overControls = transport.occupiedRects.contains { $0.contains(point) } ||
            (!modeControl.isHidden && modeControl.frame.contains(point))
        if overControls { filmPointer = nil; filmHover.isHidden = true }
        else if film.contains(point) { filmPointer = point }
        else if filmHover.isHidden || !filmHover.frame.contains(point) { filmPointer = nil }
        updateFilmHover()
        if onOverview { onHover?(fraction(point.x)) } else { onHover?(nil) }
        showControls(); needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clickedLayout = filmLayout
        stopFilmTransition()
        showControls()
        let enlarged = !filmHover.isHidden && filmHover.frame.contains(point)
        if wantsFilm, film.contains(point) || enlarged {
            drag = (clickedLayout, 0, false)
            dragStartX = point.x
            let sample = enlarged ? filmHover.seconds : clickedLayout.cell(at: Double(point.x - film.midX))?.seconds
            pressedFilmX = sample.map { film.midX + CGFloat(clickedLayout.lens.offset(for: $0)) } ?? point.x
            filmHover.isHidden = true
        } else if point.y < 14 {
            overviewDrag = true; onSeek?(fraction(point.x))
        } else if point.y < 29 {
            if point.x < 65 { onFilmSeek?(0) }
            else if point.x > bounds.width - 65 { onFilmSeek?(duration) }
        }
    }
    private var dragStartX: CGFloat = 0
    private var pressedFilmX: CGFloat = 0
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
        if let drag, !drag.moved { onFilmSeek?(drag.layout.lens.time(at: Double(pressedFilmX - film.midX))) }
        drag = nil; overviewDrag = false; requestedTimes = []
        let point = convert(event.locationInWindow, from: nil)
        filmPointer = film.contains(point) ? point : nil
        updateDesiredImages(); needsDisplay = true; scheduleControlHide()
        updateFilmHover()
        updateFilmPointer(event.locationInWindow)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if wantsFilm { addCursorRect(film, cursor: .openHand) }
        if playbackVisible { addCursorRect(NSRect(x: track.minX, y: 0, width: track.width, height: 14), cursor: .pointingHand) }
    }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if wantsFilm, film.contains(point) || (!filmHover.isHidden && filmHover.frame.contains(point)), duration > 0 {
            guard event.momentumPhase.isEmpty else { return }
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            guard dx != 0 || dy != 0 else { return }
            scrolling = true; scrollRest?.cancel(); showControls()
            if !scrollHasSought, !event.modifierFlags.contains(.option) {
                scrollHasSought = true; onFilmScrubBegan?()
            }
            if event.modifierFlags.contains(.option) {
                let delta = abs(dx) > abs(dy) ? -dx : dy
                let amount = delta * (event.hasPreciseScrollingDeltas ? 0.02 : 0.2)
                if filmMode == .segment { lensSeconds = min(30, max(0.1, lensSeconds * exp(amount))) }
                else { lensDensity = min(4, max(0.5, lensDensity * exp(-amount))) }
                requestedTimes = []; updateFilmHover(); needsDisplay = true
            } else if event.hasPreciseScrollingDeltas && abs(dx) > abs(dy) {
                stopFilmTransition()
                if event.phase.contains(.began) { scrollTime = nil }
                let target = min(duration, max(0, (scrollTime ?? currentSeconds) - dx * scale.secondsPerPoint))
                scrollTime = target
                onFilmSeek?(target)
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
                        filmPointer = nil; filmHover.isHidden = true
                        transitionFilm(to: time)
                        onFilmSeek?(time)
                    }
                }
            }
            let rest = DispatchWorkItem { [weak self] in
                guard let self else { return }
                scrolling = false; scrollHasSought = false; scrollTime = nil; scrollRest = nil
                saveLensPreferences()
                updateDesiredImages(); updateFilmPointer(window?.mouseLocationOutsideOfEventStream)
            }
            scrollRest = rest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: rest)
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
    }
    func menuDidClose(_ menu: NSMenu) {
        contextMenuOpen = false
        updateFilmPointer(window?.mouseLocationOutsideOfEventStream)
        updateDesiredImages(); scheduleControlHide(); onEnterExit?()
    }
    @objc private func showLensControls() {
        if lensPopover.isShown { lensPopover.performClose(nil); return }
        stopFilmTransition()
        if filmstripEnabled { setFilmRevealed(true) }
        let panel: TimelineLensControls
        if let existing = lensPopover.contentViewController as? TimelineLensControls { panel = existing }
        else {
            panel = TimelineLensControls()
            panel.onChange = { [weak self] seconds, focus, crop, magnification, density in
                self?.configureLens(seconds: seconds, focus: focus, crop: crop, magnification: magnification, density: density)
            }
            lensPopover.contentViewController = panel
            lensPopover.behavior = .transient; lensPopover.delegate = self
        }
        panel.setValues(seconds: lensSeconds, focus: lensFocus, crop: lensCrop,
                        magnification: lensMagnification, density: lensDensity, mode: filmMode)
        lensPopover.show(relativeTo: NSRect(x: bounds.midX - 1, y: 29, width: 2, height: visibleFilmHeight),
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
        stripHeight = CGFloat(item.tag)
        cancelFilmstripRequests()
        UserDefaults.standard.set(Double(stripHeight), forKey: "timeline-film-height")
        if stripHeight > 0 { filmRevealed = true }
        else {
            filmRevealed = false; filmHover.isHidden = true; filmPinned = false
            UserDefaults.standard.set(false, forKey: "timeline-film-pinned")
        }
        onHeightChange?(preferredHeight); requestedTimes = []; needsLayout = true; needsDisplay = true
    }
    @objc private func pinFilm() { toggleFilmPin() }
    @objc private func foldFilm() { toggleFilmVisibility() }
    @objc private func toggleAlwaysControls() {
        alwaysControls.toggle(); UserDefaults.standard.set(alwaysControls, forKey: "timeline-controls-always")
        if alwaysControls { showControls() } else { scheduleControlHide() }
    }
}
