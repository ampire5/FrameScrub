import Foundation

/// One scroll event as AppKit reports it (`scrollingDeltaX/Y`, `hasPreciseScrollingDeltas`, …).
public struct ScrollSample: Sendable {
    public var deltaX: Double
    public var deltaY: Double
    public var precise: Bool       // trackpad / Magic Mouse; false = mouse wheel
    public var momentum: Bool
    public var began: Bool
    public var time: Double
    public var modifiers: Modifiers
    /// The right mouse button is held: the scroll's chord gets `MBTN_RIGHT+` (by default a fast scrub).
    public var rightButton: Bool
    /// The other buttons held (`Modifiers.heldButtons`): the scroll's chord gets their prefixes too.
    public var heldButtons: Modifiers

    public init(deltaX: Double, deltaY: Double, precise: Bool, momentum: Bool, began: Bool, time: Double,
                modifiers: Modifiers, rightButton: Bool = false, heldButtons: Modifiers = []) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.precise = precise
        self.momentum = momentum
        self.began = began
        self.time = time
        self.modifiers = modifiers
        self.rightButton = rightButton
        self.heldButtons = heldButtons
    }
}

public enum GestureAction: Equatable, Sendable {
    /// A scrub by the frames; `ticks`: a plain mouse-wheel scrub (not the trackpad, not `scrub fast`, not accelerated),
    /// which plays keyframe / mark ticks.
    case scrubFrames(Int, ticks: Bool)
    /// A scrub of the mark edge (`scrub-edge start|end`): the same frames the plain scrub gives.
    case scrubEdge(MarkEdge, frames: Int)
    /// Continuous pinch zoom: the event's magnification (positive = zoom in).
    case zoomBy(Double)
    case command(Command)
}

/// Turns scrolls and pinches into actions through the gesture bindings of the input map
/// (`TRACKPAD_*`, `WHEEL_*`, `PINCH_IN/OUT`, with modifiers). Scrub bindings go through the
/// ScrubController; other bindings fire once per wheel notch or per `stepPoints` of trackpad travel.
public final class GestureRouter {
    public var inputMap: InputMap
    public let scrubber: ScrubController
    public static let stepPoints = 40.0
    public static let pinchStep = 0.1
    /// Events one notch of the vertical wheel sends with the Logitech high-resolution wheel on (measured on an
    /// MX Master 4 through macOS: 32 events for 5 notches, 62 for 10).
    public static let precisionEventsPerNotch = 6
    /// Events a notch of the vertical wheel sends: `precisionEventsPerNotch` while the Logitech wheel is in high
    /// resolution (Precision Scroll, `LogiMouse.isHighResolution`), else 1. The horizontal wheel always sends one.
    public var wheelEventsPerNotch = 1 {
        didSet {
            notchEvents = 0
            notchChord = nil
        }
    }

    private struct Axis: Equatable {
        var horizontal: Bool
        var modifiers: Modifiers
    }

    private var axis: Axis?
    private var travel = 0.0
    private var pinchTravel = 0.0
    /// Events of the current high-resolution notch so far, and the chord they belong to.
    private var notchEvents = 0
    private var notchChord: KeyChord?

    public init(inputMap: InputMap, scrubSettings: ScrubSettings) {
        self.inputMap = inputMap
        scrubber = ScrubController(settings: scrubSettings)
    }

    public func route(_ s: ScrollSample) -> [GestureAction] {
        if s.began {
            scrubber.reset()
            travel = 0
            axis = nil
        }
        let horizontal = abs(s.deltaX) > abs(s.deltaY)
        let delta = horizontal ? s.deltaX : s.deltaY
        guard delta != 0 else { return [] }
        let device = s.precise ? "TRACKPAD" : "WHEEL"
        let modifiers = (s.rightButton ? s.modifiers.union(.rightButton) : s.modifiers).union(s.heldButtons)
        let eventChord = chord(device, horizontal: horizontal, positive: delta > 0, modifiers: modifiers)
        guard let command = inputMap.command(for: eventChord) else { return [] }

        let perNotch = s.precise || horizontal ? 1 : wheelEventsPerNotch
        if case let .scrub(fast, invert) = command {
            return scrub(s, delta: delta, fast: fast, invert: invert, eventsPerNotch: perNotch)
        }
        if case let .scrubEdge(edge) = command {
            return scrub(s, delta: delta, fast: false, invert: false, eventsPerNotch: perNotch, edge: edge)
        }
        guard !s.momentum else { return [] }
        guard s.precise else { return wheelNotch(command, chord: eventChord, perNotch: perNotch) }

        let current = Axis(horizontal: horizontal, modifiers: modifiers)
        if current != axis {
            axis = current
            travel = 0
        }
        travel += delta
        var actions: [GestureAction] = []
        while abs(travel) >= Self.stepPoints {
            let positive = travel > 0
            if let step = inputMap.command(for: chord(device, horizontal: horizontal, positive: positive,
                                                      modifiers: modifiers)) {
                actions.append(.command(step))
            }
            travel -= positive ? Self.stepPoints : -Self.stepPoints
        }
        return actions
    }

    private func scrub(_ s: ScrollSample, delta: Double, fast: Bool, invert: Bool, eventsPerNotch: Int,
                       edge: MarkEdge? = nil) -> [GestureAction] {
        let boost = fast ? scrubber.settings.fastMultiplier : 1
        let frames = s.precise
            ? scrubber.preciseDelta(delta, at: s.time, isMomentum: s.momentum, boost: boost, invert: invert)
            : scrubber.wheelTick(deltaSign: delta > 0 ? 1 : -1, at: s.time, boost: boost, invert: invert,
                                 eventsPerNotch: eventsPerNotch)
        guard frames != 0 else { return [] }
        let ticks = !s.precise && !fast && scrubber.lastMultiplier == 1
        return [edge.map { .scrubEdge($0, frames: frames) } ?? .scrubFrames(frames, ticks: ticks)]
    }

    /// A wheel command fires once a notch: on every event of a regular wheel, on every `perNotch`-th of a
    /// high-resolution one (counted per chord, so a reversal starts a new notch).
    private func wheelNotch(_ command: Command, chord: KeyChord, perNotch: Int) -> [GestureAction] {
        guard perNotch > 1 else { return [.command(command)] }
        if chord != notchChord {
            notchChord = chord
            notchEvents = 0
        }
        notchEvents += 1
        guard notchEvents >= perNotch else { return [] }
        notchEvents = 0
        return [.command(command)]
    }

    public func routePinch(magnification: Double, modifiers: Modifiers) -> [GestureAction] {
        guard magnification != 0 else { return [] }
        let key = magnification > 0 ? "PINCH_OUT" : "PINCH_IN"
        guard let command = inputMap.command(for: KeyChord(key: key, modifiers: modifiers)) else { return [] }
        if command == .zoom(nil) { return [.zoomBy(magnification)] }
        pinchTravel += magnification
        var actions: [GestureAction] = []
        while abs(pinchTravel) >= Self.pinchStep {
            let out = pinchTravel > 0
            if let step = inputMap.command(for: KeyChord(key: out ? "PINCH_OUT" : "PINCH_IN", modifiers: modifiers)) {
                actions.append(.command(step))
            }
            pinchTravel -= out ? Self.pinchStep : -Self.pinchStep
        }
        return actions
    }

    /// Call when a pinch gesture ends so the next one starts from zero travel.
    public func endPinch() {
        pinchTravel = 0
    }

    private func chord(_ device: String, horizontal: Bool, positive: Bool, modifiers: Modifiers) -> KeyChord {
        let side = horizontal ? (positive ? "LEFT" : "RIGHT") : (positive ? "UP" : "DOWN")
        return KeyChord(key: "\(device)_\(side)", modifiers: modifiers)
    }
}
