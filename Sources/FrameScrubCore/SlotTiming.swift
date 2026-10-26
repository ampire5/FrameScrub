import CoreGraphics

/// The edge reveal of one slot (spec §3.7, as a compact sidebar does it): the pointer touching the window's edge brings
/// the slot at once. The pointer there with a button held (scrubbing, dragging) does nothing, and so does a button
/// released there; after either, and after a reveal, the edge stays quiet until the pointer has left it.
public struct EdgeReveal: Sendable {
    public enum Output: Equatable, Sendable { case none, revealSlot }

    /// False from a reveal (or a button held at the edge) until the pointer leaves the edge.
    private var armed = true

    public init() {}

    /// Where the pointer is now; called on every move (and on button changes).
    public mutating func pointer(atEdge: Bool, buttonHeld: Bool) -> Output {
        guard atEdge else {
            armed = true
            return .none
        }
        guard armed, !buttonHeld else {
            armed = false
            return .none
        }
        armed = false
        return .revealSlot
    }

    /// The edge forgets the pointer (the slot was shown or hidden some other way).
    public mutating func reset() { armed = true }

    /// How near a side edge the pointer brings its slot: a band, so the pointer need not hit the window's last pixel
    /// (the user asked for it to come "a little sooner", 2026-10-26; it was 2 pt).
    public static let sideBand: CGFloat = 12
    /// The bottom stays a thin line: right above it is the seek bar.
    public static let bottomBand: CGFloat = 2
    /// Corners belong to no edge: a pointer in the corner is not resting at either side.
    public static let cornerZone: CGFloat = 24

    /// Whether `p` (in the container, `bounds`) is at `edge` for its reveal.
    public static func isAt(_ edge: SlotEdge, _ p: CGPoint, in bounds: CGRect) -> Bool {
        guard bounds.insetBy(dx: -1, dy: -1).contains(p) else { return false }
        switch edge {
        case .left:
            return p.x <= bounds.minX + sideBand && p.y > bounds.minY + cornerZone && p.y < bounds.maxY - cornerZone
        case .right:
            return p.x >= bounds.maxX - sideBand && p.y > bounds.minY + cornerZone && p.y < bounds.maxY - cornerZone
        case .bottom:
            // The middle third only: the rest of the bottom edge is the seek bar's.
            return p.y <= bounds.minY + bottomBand && abs(p.x - bounds.midX) < bounds.width / 6
        }
    }
}

/// The tongue of a slot that is revealed by a click (`SlotReveal.tongue`): a short pill at the edge that fades in as
/// the pointer comes near and follows it along the edge.
public enum EdgeTongue {
    /// From this far (points) the tongue starts to show.
    public static let reach: CGFloat = 150
    public static let length: CGFloat = 72
    /// Kept this far from the edge's ends.
    public static let cornerGap: CGFloat = 12

    public enum Reaction: Equatable, Sendable { case follow, hide, keep }

    /// What the tongue does on a pointer event. A press arrives at the app's pointer monitor before the view under the
    /// pointer gets it, so a press on the tongue must leave it in place, or the click would go to what is behind it.
    public static func reaction(buttonHeld: Bool, overTongue: Bool) -> Reaction {
        guard buttonHeld else { return .follow }
        return overTongue ? .keep : .hide
    }

    /// 0 at `reach` and beyond, 1 at the edge; it rises faster as the pointer nears.
    public static func opacity(distance: CGFloat) -> CGFloat {
        guard distance > 0 else { return 1 }
        guard distance < reach else { return 0 }
        let t = 1 - distance / reach
        return t * t
    }

    /// The tongue's middle along the edge: at the pointer, kept inside `span`.
    public static func center(at position: CGFloat, span: ClosedRange<CGFloat>) -> CGFloat {
        let low = span.lowerBound + length / 2 + cornerGap, high = span.upperBound - length / 2 - cornerGap
        guard low <= high else { return (span.lowerBound + span.upperBound) / 2 }
        return min(max(position, low), high)
    }
}

/// Whether the pointer counts as over a shown slot, for hiding when it leaves: inside the slot, or gone out of the
/// window across the slot's own edge and not far (a compact sidebar keeps open while the pointer overshoots).
public enum SlotHover {
    /// How far past a side edge, and past the bottom edge, the pointer may go.
    public static let outsideSide: CGFloat = 200
    public static let outsideBottom: CGFloat = 100
    /// Slack along the edge.
    private static let along: CGFloat = 7

    /// Points in one space (the window's content, say), `window` being its bounds.
    public static func counts(_ p: CGPoint, slot: CGRect, edge: SlotEdge, window: CGRect) -> Bool {
        if slot.contains(p) { return true }
        switch edge {
        case .left:
            return p.x < window.minX && window.minX - p.x <= outsideSide && spans(p.y, slot.minY, slot.maxY)
        case .right:
            return p.x > window.maxX && p.x - window.maxX <= outsideSide && spans(p.y, slot.minY, slot.maxY)
        case .bottom:
            return p.y < window.minY && window.minY - p.y <= outsideBottom && spans(p.x, slot.minX, slot.maxX)
        }
    }

    private static func spans(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Bool {
        v >= low - along && v <= high + along
    }
}

/// When an overlay slot hides by itself (spec §3.6). Only `mouseLeaves` hides on time: `mouseLeaveDelay` seconds after
/// the pointer left the slot, unless the slot is busy (typing in it, a popup of it open, its edge being dragged). A
/// slot shown with the pointer elsewhere (a chord, a menu) waits for the pointer to come in first.
public struct AutoHideClock: Sendable {
    public static let mouseLeaveDelay = 0.15
    private static let slack = 1e-9

    public let mode: SlotAutoHide
    private var leftAt: Double?
    /// The pointer has been in the slot since it was shown.
    private var entered = false
    private var busy = false

    public init(mode: SlotAutoHide) { self.mode = mode }

    public mutating func pointerInside(_ inside: Bool, now: Double) {
        if inside {
            entered = true
            leftAt = nil
        } else if entered, leftAt == nil {
            leftAt = now
        }
    }

    /// The slot came on screen: a leave from before it hid no longer counts.
    public mutating func shown(pointerInside inside: Bool, now: Double) {
        leftAt = nil
        entered = false
        pointerInside(inside, now: now)
    }

    public mutating func setBusy(_ busy: Bool) { self.busy = busy }

    public func shouldHide(now: Double) -> Bool {
        guard mode == .mouseLeaves, !busy, let leftAt else { return false }
        return now - leftAt + Self.slack >= Self.mouseLeaveDelay
    }

    /// The slot hides once its page starts something playing.
    public var hidesOnChoice: Bool { mode == .afterChoice }
}
