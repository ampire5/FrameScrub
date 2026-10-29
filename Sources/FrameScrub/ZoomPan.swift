import AppKit
import FrameScrubCore

/// Zoom and pan inside the picture, with Loupe's gestures and feel (its `ViewTransform` maths, shared through
/// FrameScrubCore): a pinch zooms about the fingers and halts at the stops (fill, 100 %); past a zoom limit it stretches
/// and springs back. A left drag on a zoomed picture grabs it (rubber band at the edges, a glide after release); a right
/// drag up or down zooms about the press point; a two-finger double tap toggles Fit ↔ 100 %; the zoom keys play out
/// over `animationDuration`. Two-finger scrolling stays the scrub. Never smaller than Fit (`floorAtFit`).
///
/// Coordinates are the drawable's physical pixels, origin top-left, y down. Everything runs on the main thread; the
/// motions advance on the video view's display link (`tick`), which already runs, so nothing else repeats.
@MainActor
final class ZoomPan {
    /// The transform on screen changed: the picture must be drawn again.
    var onChange: (() -> Void)?

    static let stops: [ZoomStop] = [.fill, .percent(100)]
    /// Loupe's `zoom-animation` default.
    static let animationDuration = 0.150
    /// Loupe's `rmb-zoom-speed` default: 200 / 1.5 ≈ 133 pt of travel doubles the scale.
    static let rmbZoomSpeed = 1.5
    /// The upper zoom limit, physical pixels per picture pixel (Fit can be above it for a tiny video).
    static let ceiling = 32.0

    private(set) var transform: ViewTransform {
        didSet { if transform != oldValue { onChange?() } }
    }
    /// The target of a running zoom animation: the base the next zoom key adds to, so `⌘= ⌘= ⌘=` adds steps.
    private var zoomTarget: ViewTransform?
    private var animation: ZoomAnimation?
    private var coast: InertiaCoast?
    private var rubber = PanRubber(enabled: true)

    private struct Pinch {
        var stops: ZoomStopGesture
        var proposed: Double
        var last: ViewTransform
    }
    private var pinch: Pinch?

    private var dragPoint: CGPoint?
    private var dragVelocity = DragVelocityTracker()

    private var rmbZoom: RMBZoom?
    private var rmbStops: ZoomStopGesture?
    private var rmbPress: CGPoint?
    private(set) var rmbDragging = false

    private var lastTick: CFTimeInterval?

    init() {
        var t = ViewTransform(imageSize: .zero, viewSize: .zero)
        t.floorAtFit = true
        t.ceiling = Self.ceiling
        t.offCentre = true
        transform = t
    }

    // MARK: State

    /// At Fit, still: the picture is drawn as without zoom (the cached fit scaler and all).
    var isAtFit: Bool {
        guard transform.offset == .zero, transform.stretch == nil else { return false }
        switch transform.mode {
        case .fit: return true
        case .free(let r): return abs(r - 1) < 1e-9
        default: return abs(transform.scale - transform.fitScale) <= transform.fitScale * 1e-9
        }
    }

    /// A gesture holds the picture or a motion plays: frames are drawn the cheap way, refined once it rests.
    var isMoving: Bool {
        pinch != nil || dragPoint != nil || rmbDragging || animation != nil || coast != nil || rubber.isAnimating
    }

    /// Whether a left drag moves the picture (it is larger than the view on some axis) rather than the window.
    var canPan: Bool { transform.canPan }

    /// The picture's size in square pixels (`DisplayGeometry.displaySize`): a new aspect or turn keeps the relative
    /// centre and the zoom's ratio to Fit.
    func setPictureSize(_ size: CGSize) {
        guard size != transform.imageSize else { return }
        settle()
        transform = transform.withImageSize(size)
    }

    func setViewSize(_ size: CGSize) {
        guard size != transform.viewSize else { return }
        settle()
        transform = transform.withViewSize(size)
    }

    /// Back to Fit at once (a new file).
    func reset() {
        stopAll()
        zoomTarget = nil
        transform = transform.withMode(.fit)
    }

    // MARK: Pinch

    /// Pinch zooms about the fingers: the picture point under them stays put. One gesture halts at each stop it reaches;
    /// the next one goes on past it. Past a zoom limit it stretches; lifting the fingers springs it back.
    func magnify(_ event: NSEvent, at point: CGPoint) {
        stopMotions()
        let t = transform
        if event.phase.contains(.began) || pinch?.last != t {
            pinch = Pinch(stops: ZoomStopGesture(transform: t, stops: Self.stops, rubber: true), proposed: t.scale, last: t)
        }
        guard var p = pinch else { return }
        p.proposed *= max(0.01, 1 + Double(event.magnification))
        let r = p.stops.constrain(p.proposed)
        transform = t.zoomed(toScale: r.scale, anchor: point).withStretch(Self.stretch(p.stops.stretch, anchor: point))
        stopFeedback(p.stops.justHit)
        p.last = transform
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else {
            pinch = p
            return
        }
        pinch = nil
        if p.stops.stretch != 1 { springBackZoom() } else { onChange?() }   // at rest: the refined frame
    }

    /// Two-finger double tap: Fit ↔ 100 % at the fingers; a video that 100 % would show not much larger than Fit (or
    /// smaller) goes to twice Fit instead.
    func smartZoom(at point: CGPoint) {
        let base = zoomTarget ?? transform
        if !isFit(base) {
            animate(to: base.withMode(.fit))
            return
        }
        let s = base.fitScale * 1.5 <= 1 ? 1 : base.fitScale * 2
        animate(to: base.zoomed(toScale: s, anchor: point))
    }

    // MARK: Keys

    /// `zoom N`: the scale times 2^N about `point` (the view centre without one), animated; repeats add to the target.
    func zoom(by log2Step: Double, at point: CGPoint?) {
        let base = zoomTarget ?? transform
        let anchor = point ?? CGPoint(x: base.viewSize.width / 2, y: base.viewSize.height / 2)
        animate(to: base.zoomed(toScale: base.scale * pow(2, log2Step), anchor: anchor))
    }

    /// `zoom-reset`: back to Fit, animated.
    func zoomToFit() {
        animate(to: (zoomTarget ?? transform).withMode(.fit))
    }

    // MARK: Left drag

    /// A press catches a glide or a spring where it shows.
    func leftDown(at point: CGPoint, time: TimeInterval) {
        stopMotions(catching: true)
        dragPoint = point
        dragVelocity.reset()
        dragVelocity.add(point, at: time)
    }

    /// The grabbed picture point stays under the cursor; past an edge the picture stretches against the rubber band.
    func leftDragged(to point: CGPoint, time: TimeInterval) {
        guard let last = dragPoint else { return }
        dragPoint = point
        dragVelocity.add(point, at: time)
        guard point != last else { return }
        transform = rubber.pan(by: CGVector(dx: point.x - last.x, dy: point.y - last.y), on: transform)
    }

    /// A held stretch springs back with the release velocity on its axis; the other axis glides.
    func leftUp(time: TimeInterval) {
        guard dragPoint != nil else { return }
        dragPoint = nil
        let v = dragVelocity.releaseVelocity(at: time)
        dragVelocity.reset()
        let stretched = transform.offset
        releaseRubber(velocity: v)
        let glide = CGVector(dx: stretched.dx == 0 ? v.dx : 0, dy: stretched.dy == 0 ? v.dy : 0)
        if glide != .zero { coast = InertiaCoast(velocity: glide) }
        if coast?.isFinished == true { coast = nil }
        if !isMoving { onChange?() }
    }

    /// Whether a left press is held for a pan.
    var isDragging: Bool { dragPoint != nil }

    // MARK: Right drag

    func rightDown(at point: CGPoint) {
        stopMotions()
        rmbZoom = RMBZoom(anchor: point, transform: transform,
                          pointsPerDoubling: RMBZoom.pointsPerDoubling(speed: Self.rmbZoomSpeed), offCentre: true)
        rmbStops = ZoomStopGesture(transform: transform, stops: Self.stops, rubber: true)
        rmbPress = point
        rmbDragging = false
    }

    /// Zoom follows the cumulative vertical travel since the press (up zooms in), exact and drift-free; below the click
    /// slop nothing happens, so a shaky click stays a click. Returns whether the drag zooms (the release is no click).
    @discardableResult
    func rightDragged(to point: CGPoint, backing: CGFloat) -> Bool {
        guard let zoom = rmbZoom, let press = rmbPress, var stops = rmbStops else { return false }
        // Computed from the press transform: a new file, aspect or window size since makes it stale.
        guard transform.imageSize == zoom.start.imageSize, transform.viewSize == zoom.start.viewSize else {
            endRightZoom()
            return rmbDragging
        }
        if !rmbDragging {
            guard hypot(point.x - press.x, point.y - press.y) / backing >= RMBZoom.clickSlopPoints else { return false }
            rmbDragging = true
        }
        let r = stops.constrain(zoom.scale(dyPoints: (point.y - press.y) / backing))
        rmbStops = stops
        transform = zoom.transform(toScale: r.scale).withStretch(Self.stretch(stops.stretch, anchor: zoom.anchor))
        stopFeedback(stops.justHit)
        return true
    }

    /// Returns whether the press was a zoom drag (then it is no click). Past a zoom limit it springs back.
    @discardableResult
    func rightUp() -> Bool {
        let dragged = rmbDragging, stretched = (rmbStops?.stretch ?? 1) != 1
        endRightZoom()
        if stretched { springBackZoom() } else if dragged { onChange?() }
        return dragged
    }

    /// The right button became a modifier (a wheel, another button): it zooms no more in this press.
    func endRightZoom() {
        rmbZoom = nil
        rmbStops = nil
        rmbPress = nil
        rmbDragging = false
    }

    // MARK: Motion

    /// One display frame: the zoom animation, the glide and the springs.
    func tick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        guard animation != nil || coast != nil || rubber.isAnimating else {
            lastTick = nil
            return
        }
        let last = lastTick ?? timestamp
        lastTick = targetTimestamp
        let dt = min(targetTimestamp - last, 0.05)
        guard dt > 0 else { return }
        if let a = animation {
            guard a.to.imageSize == transform.imageSize, a.to.viewSize == transform.viewSize else {
                animation = nil
                zoomTarget = nil
                return
            }
            if a.isFinished(at: targetTimestamp) {
                animation = nil
                zoomTarget = nil
                transform = a.to
                onChange?()   // at rest: the refined frame
            } else {
                transform = a.transform(at: targetTimestamp)
            }
            return
        }
        var t = transform
        if var c = coast {
            let want = c.step(dt: dt)
            // An axis that cannot move all of `want` met an edge: its glide is gone and it bounces with its speed.
            let left = t.panLeftover(want)
            let hitX = abs(left.dx) > 0.01, hitY = abs(left.dy) > 0.01
            if hitX || hitY {
                t = rubber.bounce(x: hitX ? c.velocity.dx : nil, y: hitY ? c.velocity.dy : nil, on: t)
                c.stopAxis(x: hitX, y: hitY)
            }
            t = t.panned(by: want).withOffset(t.offset)
            coast = c.isFinished ? nil : c
        }
        if rubber.isAnimating, let sprung = rubber.step(dt: dt, on: t) { t = sprung }
        transform = t
        if !isMoving { onChange?() }
    }

    private func animate(to target: ViewTransform) {
        let now = CACurrentMediaTime()
        animation = nil
        coast = nil
        rubber.reset()
        let a = ZoomAnimation(from: transform, to: target, start: now, duration: Self.animationDuration)
        guard !a.isFinished(at: now) else {
            transform = target
            zoomTarget = nil
            return
        }
        animation = a
        zoomTarget = target
        lastTick = nil
    }

    private func springBackZoom() {
        guard transform.stretch != nil else { return }
        animate(to: transform.withStretch(nil))
    }

    private func releaseRubber(velocity: CGVector = .zero) {
        transform = rubber.release(velocity: velocity, on: transform)
    }

    /// A gesture takes over: a zoom animation stops on the frame on screen, a glide ends, and a spring is caught where
    /// it shows (`catching`, a left press) or dropped.
    private func stopMotions(catching: Bool = false) {
        coast = nil
        if animation != nil {
            animation = nil
            zoomTarget = nil
            transform = transform.withStretch(nil)
        }
        if catching {
            if rubber.isAnimating { transform = rubber.grab(on: transform) }
        } else {
            rubber.reset()
            if transform.offset != .zero { transform = transform.withOffset(.zero) }
        }
    }

    /// Not a gesture (a resize, a new aspect): an animation jumps to its target, everything else stops.
    private func settle() {
        if let target = zoomTarget { transform = target }
        animation = nil
        zoomTarget = nil
        stopAll()
    }

    private func stopAll() {
        coast = nil
        animation = nil
        pinch = nil
        dragPoint = nil
        endRightZoom()
        rubber.reset()
        if transform.offset != .zero || transform.stretch != nil { transform = transform.withStretch(nil) }
    }

    private func isFit(_ t: ViewTransform) -> Bool {
        abs(t.scale - t.fitScale) <= t.fitScale * 1e-6
    }

    private static func stretch(_ factor: Double, anchor: CGPoint) -> ZoomStretch? {
        factor == 1 ? nil : ZoomStretch(factor: factor, anchor: anchor)
    }

    /// A tick on the trackpad when a gesture lands on a stop.
    private func stopFeedback(_ justHit: Bool) {
        guard justHit else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
