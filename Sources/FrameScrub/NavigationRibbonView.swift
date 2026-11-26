import AppKit
import FrameScrubCore
import HomeChrome

enum TimelinePositionText {
    static func clock(_ seconds: Double, tenths: Bool = true) -> String {
        let tenthsValue = Int((min(Double(Int32.max), max(0, seconds.isFinite ? seconds : 0)) * 10).rounded(.down))
        let whole = tenthsValue / 10
        let clock = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        return tenths ? "\(clock).\(tenthsValue % 10)" : clock
    }

    static func position(_ seconds: Double, duration: Double) -> String {
        "\(clock(seconds)) / \(clock(duration, tenths: duration < 1))"
    }

    static func interval(_ seconds: Double) -> String {
        if seconds < 0.05 { return "<0.1 s" }
        let rounded = (seconds * 10).rounded() / 10
        if rounded >= 60 { return clock(rounded.rounded(), tenths: false) }
        return String(format: rounded == rounded.rounded() ? "%.0f s" : "%.1f s", rounded)
    }
}

/// A seek series in the active timeline's seconds, including virtual cuts.
struct NavigationJourney {
    struct FrameInfo {
        let delta: Int
        var position: (current: Int, last: Int)?
    }

    let origin: Double
    let target: Double
    let duration: Double
    var frames: FrameInfo? = nil

    var displacement: String? {
        let delta = target - origin
        let magnitude = abs(delta)
        guard magnitude >= 0.05 else { return nil }
        let sign = delta < 0 ? "−" : "+"
        if magnitude < 59.95 { return sign + String(format: "%.1f s", magnitude) }
        return sign + TimelinePositionText.clock(magnitude.rounded(), tenths: false)
    }

    var frameDisplacement: String? {
        guard let frameDelta = frames?.delta, frameDelta != 0 else { return nil }
        return (frameDelta < 0 ? "−" : "+") + "\(frameDelta.magnitude.formatted()) fr"
    }

    var framePosition: String? {
        frames?.position.map { "Frame \($0.current.formatted()) / \($0.last.formatted())" }
    }

    @MainActor func drawTrack(in track: NSRect) {
        Self.drawProgress(in: track, time: target, duration: duration, origin: origin)
    }

    @MainActor static func drawProgress(in track: NSRect, time: Double, duration: Double,
                                       origin: Double? = nil, hover: Double? = nil) {
        guard track.width > 0, duration > 0 else { return }
        let target = track.minX + track.width * min(1, max(0, time / duration))
        let radius = track.height / 2
        NSColor(white: 0.12, alpha: 0.43).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -0.5, dy: -0.7),
                     xRadius: radius + 0.5, yRadius: radius + 0.5).fill()
        let shape = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(white: 1, alpha: 0.26).setFill()
        track.fill()
        NSColor.systemCyan.withAlphaComponent(0.43).setFill()
        NSRect(x: track.minX, y: track.minY, width: target - track.minX, height: track.height).fill()
        let start = origin.map { track.minX + track.width * min(1, max(0, $0 / duration)) }
        if let start {
            NSColor.systemCyan.withAlphaComponent(0.90).setFill()
            NSRect(x: min(start, target), y: track.minY, width: abs(target - start), height: track.height).fill()
        }
        if let hover {
            let x = track.minX + track.width * hover
            if abs(x - target) > 3 {
                let tick = NSRect(x: x - 0.5, y: track.midY - 2, width: 1, height: 4)
                NSColor(white: 0.08, alpha: 1).setFill()
                tick.insetBy(dx: -1, dy: -0.5).fill()
                NSColor.white.setFill()
                tick.fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let start {
            NSColor(white: 1, alpha: 0.85).setFill()
            NSRect(x: start - 0.5, y: track.midY - 2, width: 1, height: 4).fill()
        }
        let dot = NSBezierPath(ovalIn: NSRect(x: target - 2.25, y: track.midY - 2.25, width: 4.5, height: 4.5))
        NSColor(white: 0.08, alpha: 1).setStroke()
        dot.lineWidth = 1
        dot.stroke()
        FilmstripPlayhead.accent.setFill()
        dot.fill()
    }
}

/// The nearby projection of the current position, above the bottom edge.
final class NavigationRibbonView: NSView {
    enum Scale: Int {
        case near, wide

        var stride: Int { self == .near ? 1 : 3 }
        var title: String { self == .near ? "Near" : "Wide" }
    }

    struct Projection: Equatable {
        static let defaultRadius = 3
        let pictures: [NSImage?]
        var fraction: Double
        var missingTimes: [Double] = []
        var placeholderIndices: Set<Int> = []
        var sampleTimes: [Double?] = []

        /// Use the same fractional cell coordinates as the moving row, including partial edge cells.
        func visibleDuration(pitch: CGFloat, width: CGFloat, duration: Double) -> Double? {
            guard pitch > 0, width > 0, duration > 0,
                  let first = sampleTimes.firstIndex(where: { $0 != nil }),
                  let last = sampleTimes.lastIndex(where: { $0 != nil }) else { return nil }
            let center = Double(sampleTimes.count / 2) + fraction
            let radius = Double(width / (2 * pitch))
            func time(at slot: Double) -> Double {
                if slot < Double(first) { return 0 }
                if slot >= Double(last + 1) { return duration }
                let index = Int(slot.rounded(.down))
                guard let start = sampleTimes[index] else { return 0 }
                let end = index < last ? sampleTimes[index + 1] ?? duration : duration
                return start + (end - start) * (slot - Double(index))
            }
            return max(0, time(at: center + radius) - time(at: center - radius))
        }
    }

    private struct ThumbnailFit: Equatable {
        var crop = 1.0
        var stretch = 0.0
    }

    @MainActor private final class FrameTile: NSObject, @preconcurrency CALayerDelegate {
        let layer = CALayer()
        private(set) var picture: NSImage?
        private(set) var showsPlaceholder = false
        var geometry = DisplayGeometry.identity
        private var fit = ThumbnailFit()

        override init() {
            super.init()
            layer.delegate = self
            layer.anchorPoint = .zero
            layer.needsDisplayOnBoundsChange = true
        }

        func update(_ picture: NSImage?, geometry: DisplayGeometry, fit: ThumbnailFit, placeholder: Bool = false) {
            guard picture !== self.picture || geometry != self.geometry || fit != self.fit || placeholder != showsPlaceholder else { return }
            if picture !== self.picture { layer.contents = nil }
            self.picture = picture
            showsPlaceholder = placeholder
            self.geometry = geometry
            self.fit = fit
            layer.setNeedsDisplay()
        }

        func draw(_ layer: CALayer, in context: CGContext) {
            guard picture != nil || showsPlaceholder else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            let rect = layer.bounds
            FilmstripThumbnail.drawBackground(in: rect)
            if let picture {
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
                FilmstripThumbnail.draw(picture, geometry: geometry, in: rect, opacity: 1, cropSides: true,
                                        cropAmount: fit.crop, stretch: fit.stretch)
            }
        }
    }

    private static let dwell = 1.15
    private static let scaleKey = "navigation-filmstrip-scale"
    private static let scaleFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let pin = NSButton()
    private let scaleButton = NSButton()
    private let settingsButton = NSButton()
    private let stripGlass = TimelineGlass(radius: 8)
    private let captionInk = TimelineInk()
    private let framesClip = NSView()
    private let row = CALayer()
    private var tiles = (0..<(2 * Projection.defaultRadius + 1)).map { _ in FrameTile() }
    private var tileSize = CGSize.zero
    private var pictureAspect = 16.0 / 9
    private(set) var sampleRadius = Projection.defaultRadius
    private var thumbnailFit = ThumbnailFit()
    private var step: CGFloat { tileSize.width + 2 }
    private let edgeMask = CAGradientLayer()
    private let playhead = TimelineInk()
    private var expiresAt = 0.0
    private var expiry: DispatchWorkItem?
    private var projection: Projection?
    private var hovering = false
    private var settingsOpen = false
    private var keptOpen = false
    private var presented = false
    private(set) var usesFullFilm = false
    private var fadingJourney: NavigationJourney?
    private(set) var scale = Scale(rawValue: UserDefaults.standard.integer(forKey: scaleKey)) ?? .near
    private(set) var journey: NavigationJourney?
    var isPresenting: Bool { journey != nil && !usesFullFilm }
    var handoffWidth: CGFloat? { framesClip.isHidden || framesClip.frame.width <= 1 ? nil : framesClip.frame.width }
    var onPin: (() -> Void)?
    var onSettings: ((NSView) -> Void)?
    var onScaleChanged: (() -> Void)?
    var onSampleRadiusChanged: ((Int) -> Void)?
    var onJourneyChanged: ((NavigationJourney?) -> Void)?
    var onPresentationChanged: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        Chrome.Palette.overMedia.apply(to: self)
        addSubview(stripGlass)
        framesClip.wantsLayer = true
        framesClip.layer?.masksToBounds = true
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        edgeMask.locations = [0, 0.10, 0.90, 1]
        framesClip.layer?.mask = edgeMask
        row.anchorPoint = .zero
        framesClip.layer?.addSublayer(row)
        for tile in tiles { row.addSublayer(tile.layer) }
        addSubview(framesClip)
        playhead.paint = { [weak playhead] in
            guard let bounds = playhead?.bounds else { return }
            FilmstripPlayhead.draw(x: bounds.midX, bottom: bounds.minY,
                                   top: bounds.maxY - FilmstripPlayhead.topExtension)
        }
        addSubview(playhead, positioned: .above, relativeTo: framesClip)
        captionInk.frame = bounds
        captionInk.autoresizingMask = [.width, .height]
        addSubview(captionInk)

        pin.image = Icons.symbol("pin", pointSize: 10, description: "Pin filmstrip")
        pin.target = self
        pin.action = #selector(pinClicked)
        pin.toolTip = "Pin filmstrip"
        pin.setAccessibilityLabel("Pin filmstrip")
        settingsButton.image = Icons.symbol("slider.horizontal.3", pointSize: 10, description: "Filmstrip settings")
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.toolTip = "Filmstrip settings"
        settingsButton.setAccessibilityLabel("Filmstrip settings")
        scaleButton.title = scale.title
        scaleButton.font = Self.scaleFont
        scaleButton.target = self
        scaleButton.action = #selector(scaleClicked)
        scaleButton.toolTip = "Switch navigation filmstrip scale"
        scaleButton.setAccessibilityLabel("Navigation filmstrip scale")
        scaleButton.setAccessibilityValue(scale.title)
        for button in [scaleButton, settingsButton, pin] {
            button.isBordered = false
            button.refusesFirstResponder = true
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.backgroundColor = Chrome.Palette.overMedia.glassTint.cgColor
            button.layer?.cornerRadius = 4
            button.isHidden = true
            addSubview(button)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Navigation filmstrip")
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit { expiry?.cancel() }

    override func layout() {
        super.layout()
        let height = floor(min(bounds.height - 32, bounds.height * 0.55))
        let available = max(0, bounds.width - 12)
        let width = min(floor(available / 5), max(10, floor(height * pictureAspect)))
        framesClip.isHidden = width < 10 || height < 14
        stripGlass.isHidden = framesClip.isHidden
        let pitch = width + 2
        let maximumRadius = (TimelineFilmLayout.maximumCells - 1) / 2
        let visibleWidth = min(available, CGFloat(2 * maximumRadius - 1) * pitch - 2)
        let radius = max(Projection.defaultRadius, Int(ceil(visibleWidth / (2 * pitch) + 0.5)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !framesClip.isHidden {
            tileSize = CGSize(width: width, height: height)
            framesClip.frame = NSRect(x: (bounds.width - visibleWidth) / 2, y: 26, width: visibleWidth, height: height)
            stripGlass.frame = framesClip.frame.insetBy(dx: -3, dy: -3).intersection(bounds)
            positionTiles()
            edgeMask.frame = framesClip.bounds
        }
        CATransaction.commit()
        playhead.frame = NSRect(x: bounds.midX - FilmstripPlayhead.width / 2, y: framesClip.frame.minY,
                                width: FilmstripPlayhead.width, height: max(0, height + FilmstripPlayhead.topExtension))
        playhead.isHidden = framesClip.isHidden
        let buttonY = bounds.width <= 320 && !framesClip.isHidden ? framesClip.frame.maxY - 17 : 5
        scaleButton.frame = NSRect(x: 8, y: buttonY, width: 35, height: 15)
        pin.frame = NSRect(x: bounds.maxX - 28, y: buttonY, width: 20, height: 15)
        settingsButton.frame = NSRect(x: pin.frame.minX - 24, y: buttonY, width: 20, height: 15)
        updateContentsScale()
        positionFrames()
        if !scaleButton.isHidden { updateScaleButton() }
        updateCaption()
        needsDisplay = true
        if !framesClip.isHidden, sampleRadius != radius {
            sampleRadius = radius
            onSampleRadiusChanged?(radius)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        for tile in tiles where tile.layer.contentsScale != scale {
            tile.layer.contentsScale = scale
            tile.layer.setNeedsDisplay()
        }
    }

    /// Keep the controls available while the pointer is over the visible strip, leaving the rest of the video interactive.
    @discardableResult func updatePointer(_ windowPoint: NSPoint?) -> Bool {
        let overStrip = isPresenting && windowPoint.map {
            NSRect(x: 0, y: 4, width: bounds.width, height: max(24, framesClip.frame.maxY)).contains(convert($0, from: nil))
        } == true
        if hovering != overStrip {
            hovering = overStrip
            updateHold()
        }
        return overStrip || settingsOpen
    }

    func setSettingsOpen(_ shown: Bool) {
        guard settingsOpen != shown else { return }
        settingsOpen = shown
        updateHold()
    }

    func setKeptOpen(_ shown: Bool, pinned: Bool) {
        keptOpen = shown
        let label = pinned ? "Unpin Mini Filmstrip" : "Pin Mini Filmstrip"
        pin.toolTip = "\(label) (⌥⇧⌘L)"
        pin.setAccessibilityLabel(label)
    }

    private func updateHold() {
        let held = hovering || settingsOpen
        for button in [scaleButton, settingsButton, pin] { button.isHidden = !held }
        if held { updateScaleButton() }
        updateCaption()
        if held {
            expiry?.cancel()
            expiry = nil
        } else if journey != nil {
            expiresAt = ProcessInfo.processInfo.systemUptime + Self.dwell
            scheduleExpiry(after: Self.dwell)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isPresenting, let hit = super.hitTest(point),
              hit === pin || hit === scaleButton || hit === settingsButton else { return nil }
        return hit
    }

    @objc private func pinClicked() { onPin?() }
    @objc private func settingsClicked() { onSettings?(settingsButton) }

    @objc private func scaleClicked() {
        scale = scale == .near ? .wide : .near
        UserDefaults.standard.set(scale.rawValue, forKey: Self.scaleKey)
        onScaleChanged?()
        updateScaleButton()
        updateCaption()
    }

    @discardableResult func record(from before: Double, to after: Double, duration: Double,
                                   at now: Double = ProcessInfo.processInfo.systemUptime,
                                   frames: ((Double, Double) -> NavigationJourney.FrameInfo?)? = nil) -> Bool {
        guard duration.isFinite, duration > 0, before.isFinite, after.isFinite else { return false }
        let start = min(duration, max(0, before)), end = min(duration, max(0, after))
        guard start != end else { return false }
        let origin = (hovering || settingsOpen || now < expiresAt) ? journey?.origin ?? start : start
        let next = NavigationJourney(origin: min(duration, origin), target: end, duration: duration,
                                     frames: frames?(origin, end))
        expiresAt = now + Self.dwell
        if !hovering, !settingsOpen, expiry == nil { scheduleExpiry(after: Self.dwell) }
        updateJourney(next)
        return true
    }

    /// Follow playback outside a navigation burst. The burst keeps its landing and displacement briefly.
    @discardableResult func showPosition(_ time: Double, duration: Double, frames: NavigationJourney.FrameInfo?,
                                         at now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard keptOpen, time.isFinite, duration.isFinite, duration > 0 else { return false }
        let time = min(duration, max(0, time))
        if let journey {
            if !usesFullFilm, journey.origin != journey.target, now < expiresAt || hovering || settingsOpen { return false }
            if journey.origin == time, journey.target == time, journey.duration == duration,
               journey.frames?.position?.current == frames?.position?.current,
               journey.frames?.position?.last == frames?.position?.last { return false }
        }
        updateJourney(NavigationJourney(origin: time, target: time, duration: duration, frames: frames))
        return true
    }

    private func updateJourney(_ next: NavigationJourney) {
        journey = next
        fadingJourney = nil
        onJourneyChanged?(next)
        setAccessibilityValue([TimelinePositionText.position(next.target, duration: next.duration), next.framePosition,
                               next.displacement, next.frameDisplacement]
            .compactMap { $0 }.joined(separator: " · "))
        if !scaleButton.isHidden { updateScaleButton() }
        updateCaption()
        needsDisplay = true
        updatePresentation()
    }

    func setProjection(_ projection: Projection, geometry: DisplayGeometry) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if tiles.count != projection.pictures.count || zip(tiles, projection.pictures).contains(where: { $0.picture !== $1 }) {
            // Retain the tiles of pictures already in the strip when the time window advances.
            // We can then move them and the row together, without waiting for a backing-store redraw.
            var available = tiles
            while available.count < projection.pictures.count {
                let tile = FrameTile()
                tile.layer.contentsScale = window?.backingScaleFactor ?? 1
                row.addSublayer(tile.layer)
                available.append(tile)
            }
            let aligned = projection.pictures.map { picture -> FrameTile? in
                guard let existing = available.firstIndex(where: { $0.picture === picture }) else { return nil }
                return available.remove(at: existing)
            }
            tiles = aligned.map { $0 ?? available.removeFirst() }
            for tile in available { tile.layer.removeFromSuperlayer() }
            positionTiles()
        }
        for (index, tile) in tiles.enumerated() {
            tile.update(projection.pictures[index], geometry: geometry, fit: thumbnailFit,
                        placeholder: projection.placeholderIndices.contains(index))
        }
        // This transform follows the user's position directly and does not run an animation.
        self.projection = projection
        positionFrames()
        CATransaction.commit()
        if !scaleButton.isHidden, updateScaleButton() { updateCaption() }
    }

    private func positionTiles() {
        let radius = CGFloat(tiles.count / 2)
        row.bounds = NSRect(x: 0, y: 0, width: max(0, CGFloat(tiles.count) * step - 2), height: tileSize.height)
        row.position = CGPoint(x: framesClip.bounds.midX - radius * step - tileSize.width / 2, y: 0)
        for (slot, tile) in tiles.enumerated() {
            tile.layer.bounds = CGRect(origin: .zero, size: tileSize)
            tile.layer.position = CGPoint(x: CGFloat(slot) * step, y: 0)
        }
    }

    func setPictureAspect(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0, pictureAspect != aspect else { return }
        pictureAspect = aspect
        needsLayout = true
        if isPresenting { layoutSubtreeIfNeeded() }
    }

    func configureThumbnailFit(crop: Double, stretch: Double) {
        let fit = ThumbnailFit(crop: crop, stretch: stretch)
        guard fit != thumbnailFit else { return }
        thumbnailFit = fit
        for tile in tiles { tile.update(tile.picture, geometry: tile.geometry, fit: fit, placeholder: tile.showsPlaceholder) }
    }

    private func positionFrames() {
        let x = -CGFloat(projection?.fraction ?? 0) * step
        guard x != row.affineTransform().tx else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.setAffineTransform(CGAffineTransform(translationX: x, y: 0))
        CATransaction.commit()
    }

    func showWithFullFilm(_ shown: Bool, animatingPictures: Bool = false) {
        guard usesFullFilm != shown else { return }
        usesFullFilm = shown
        if shown {
            cancelPictureHandoff()
            setSettingsOpen(false)
            updatePointer(nil)
        }
        updatePresentation(animated: false)
        let duration = FilmstripHandoff.duration
        if animatingPictures, isPresenting, duration > 0, window?.occlusionState.contains(.visible) == true {
            FilmstripHandoff.reveal(framesClip.layer, from: 0.45, duration: duration)
            FilmstripHandoff.reveal(stripGlass.layer, from: 0.35, duration: duration)
        }
    }

    func clear(animated: Bool = false) {
        cancelPictureHandoff()
        expiry?.cancel()
        expiry = nil
        fadingJourney = animated ? journey : nil
        if journey != nil {
            journey = nil
            onJourneyChanged?(nil)
        }
        setSettingsOpen(false)
        updatePointer(nil)
        updatePresentation(animated: animated)
        if !animated { resetFrames() }
    }

    private func cancelPictureHandoff() {
        framesClip.layer?.removeAnimation(forKey: FilmstripHandoff.opacityKey)
        stripGlass.layer?.removeAnimation(forKey: FilmstripHandoff.opacityKey)
    }

    private func resetFrames() {
        projection = nil
        for tile in tiles { tile.update(nil, geometry: .identity, fit: thumbnailFit) }
        if journey == nil { updateCaption() }
    }

    private func scheduleExpiry(after delay: Double) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            expiry = nil
            let remaining = expiresAt - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                scheduleExpiry(after: remaining)
            } else if keptOpen, let journey {
                let frames = journey.frames.map { NavigationJourney.FrameInfo(delta: 0, position: $0.position) }
                showPosition(journey.target, duration: journey.duration, frames: frames)
            } else {
                clear(animated: true)
            }
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updatePresentation(animated: Bool = true) {
        let shown = isPresenting
        setAccessibilityHidden(!shown)
        guard shown != presented || !animated else { return }
        let changed = shown != presented
        presented = shown
        if changed { onPresentationChanged?() }
        let duration = animated ? Chrome.Motion.duration(0.15) : 0
        guard duration > 0, let layer else {
            layer?.removeAnimation(forKey: "strip-reveal-opacity")
            layer?.removeAnimation(forKey: "strip-reveal-position")
            alphaValue = shown ? 1 : 0
            if !shown, !usesFullFilm || journey == nil { finishFade() }
            return
        }
        if shown {
            let fromOpacity = layer.presentation()?.opacity ?? 0
            let fromY = layer.animation(forKey: "strip-reveal-position") != nil
                ? layer.presentation()?.affineTransform().ty ?? -4 : -4
            alphaValue = 1
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = fromOpacity
            reveal.toValue = 1
            reveal.duration = duration
            layer.add(reveal, forKey: "strip-reveal-opacity")
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.mass = 1
            rise.stiffness = 300
            rise.damping = 28.4
            rise.fromValue = fromY
            rise.toValue = 0
            rise.duration = 0.26
            layer.add(rise, forKey: "strip-reveal-position")
        } else {
            let fall = CABasicAnimation(keyPath: "transform.translation.y")
            fall.fromValue = layer.presentation()?.affineTransform().ty ?? 0
            fall.toValue = -3
            fall.duration = duration
            layer.add(fall, forKey: "strip-reveal-position")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.journey == nil else { return }
                self.finishFade()
            }
        }
    }

    private func finishFade() {
        fadingJourney = nil
        resetFrames()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let journey = journey ?? fadingJourney else { return }
        let track = NSRect(x: 8, y: 1.5, width: max(0, bounds.width - 16), height: 2.5)
        journey.drawTrack(in: track)
    }

    private func updateCaption() {
        guard let journey = journey ?? fadingJourney else {
            captionInk.paint = nil
            captionInk.needsDisplay = true
            return
        }
        let controlsBesideText = (hovering || settingsOpen) && pin.frame.minY < 23
        let right = controlsBesideText ? settingsButton.frame.minX - 4 : bounds.maxX - 8
        let left = controlsBesideText ? scaleButton.frame.maxX + 4 : bounds.minX + 8
        let row = NSRect(x: left, y: 9, width: max(0, right - left), height: 17)
        let compactCount = journey.frames?.position.map { "Fr \($0.current.formatted())" }
        let frames = [journey.framePosition, compactCount].compactMap { $0 }
        let readout = FilmstripReadout(time: journey.target, duration: journey.duration, anchor: bounds.midX, in: row)
        captionInk.paint = {
            readout?.draw(in: row, frames: frames, journey: journey)
        }
        captionInk.needsDisplay = true
    }

    @discardableResult private func updateScaleButton() -> Bool {
        var title = scale.title
        var value = title
        var help = "Switch navigation filmstrip scale"
        var width: CGFloat = 35
        if let journey, !framesClip.isHidden,
           let duration = projection?.visibleDuration(pitch: step, width: framesClip.bounds.width, duration: journey.duration),
           duration > 0 {
            let span = TimelinePositionText.interval(duration)
            let full = "\(title) · \(span)"
            let required = ceil((full as NSString).size(withAttributes: [.font: Self.scaleFont]).width) + 12
            let gap: CGFloat = scaleButton.frame.minY < 23 ? 48 : 12
            if required <= bounds.midX - gap - scaleButton.frame.minX {
                title = full
                width = required
            }
            help = "Switch mini filmstrip scale. Visible span: \(span)"
            value = full
        }
        if scaleButton.toolTip != help { scaleButton.toolTip = help }
        if scaleButton.accessibilityValue() as? String != value { scaleButton.setAccessibilityValue(value) }
        if scaleButton.title != title { scaleButton.title = title }
        guard scaleButton.frame.width != width else { return false }
        scaleButton.frame.size.width = width
        return true
    }
}
