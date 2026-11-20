import CoreGraphics

/// A primary click held with one finger while two others move horizontally. AppKit can
/// supply both raw touch motion and precise scroll. The first to establish an axis wins.
public struct HeldTrackpadSwipe {
    public enum Direction: Equatable { case next, previous }
    public enum Scroll: Equatable { case pass, consume, step(Direction) }

    private enum Source { case touches, scroll }
    private enum ScrollTail { case untilLift, untilNextBegin }
    private enum Axis {
        case vertical
        case horizontal(Direction, extreme: Double)
    }

    // Loupe's raw three-finger travel and default held-button scroll threshold.
    private static let touchDistance = 0.08
    private static let scrollDistance = 40.0
    private static let dominance = 2.0

    public private(set) var isPressed = false
    public private(set) var ownsPress = false
    public private(set) var touchCount = 0
    private var center: CGPoint?
    private var start: CGPoint?
    private var travel = CGPoint.zero
    private var source: Source?
    private var axis: Axis?
    private var scrollTail: ScrollTail?

    public init() {}

    public mutating func beginPress() -> Bool {
        _ = endPress()
        guard (1...3).contains(touchCount) else { return false }
        isPressed = true
        if touchCount == 3 { claimPress() }
        return true
    }

    /// Returns whether the swipe took over the click, even if the travel fell short.
    public mutating func endPress() -> Bool {
        let owned = ownsPress
        isPressed = false
        ownsPress = false
        start = nil
        travel = .zero
        source = nil
        axis = nil
        return owned
    }

    public mutating func touches(count: Int, center: CGPoint?, primaryDown: Bool) -> Direction? {
        touchCount = count
        self.center = center
        if count == 0, scrollTail != nil { scrollTail = .untilNextBegin }
        guard isPressed, primaryDown else { return nil }
        guard count == 3, let center else {
            start = nil
            if source == nil { travel = .zero }
            return nil
        }
        if !ownsPress { claimPress() }
        guard source != .scroll else { return nil }
        guard let start else {
            self.start = center
            if case .horizontal(let direction, _) = axis { axis = .horizontal(direction, extreme: 0) }
            return nil
        }
        return advance(x: center.x - start.x, y: center.y - start.y, source: .touches,
                       distance: Self.touchDistance)
    }

    /// Deltas are in the fingers' direction, independent of the system scrolling setting.
    public mutating func scroll(x: Double, y: Double, begins: Bool = false, momentum: Bool = false,
                                primaryDown: Bool = true) -> Scroll {
        if isPressed, primaryDown {
            suppressTail()
            guard ownsPress, touchCount == 3, !momentum, source != .touches else { return .consume }
            travel.x += x
            travel.y += y
            if let direction = advance(x: travel.x, y: travel.y, source: .scroll, distance: Self.scrollDistance) {
                return .step(direction)
            }
            return .consume
        }
        if begins, !momentum, scrollTail == .untilNextBegin { scrollTail = nil }
        return scrollTail == nil ? .pass : .consume
    }

    private mutating func claimPress() {
        ownsPress = true
        start = center
        suppressTail()
    }

    private mutating func suppressTail() {
        scrollTail = touchCount == 0 ? .untilNextBegin : .untilLift
    }

    private mutating func advance(x: Double, y: Double, source: Source, distance: Double) -> Direction? {
        switch axis {
        case .vertical:
            return nil
        case .horizontal(.next, let extreme):
            let minimum = min(extreme, x)
            if x - minimum >= distance {
                axis = .horizontal(.previous, extreme: x)
                return .previous
            }
            axis = .horizontal(.next, extreme: minimum)
            return nil
        case .horizontal(.previous, let extreme):
            let maximum = max(extreme, x)
            if maximum - x >= distance {
                axis = .horizontal(.next, extreme: x)
                return .next
            }
            axis = .horizontal(.previous, extreme: maximum)
            return nil
        case nil:
            if abs(x) >= distance, abs(x) > abs(y) * Self.dominance {
                let direction: Direction = x < 0 ? .next : .previous
                self.source = source
                axis = .horizontal(direction, extreme: x)
                return direction
            }
            if abs(y) >= distance, abs(y) > abs(x) * Self.dominance {
                self.source = source
                axis = .vertical
            }
            return nil
        }
    }
}
