import Foundation

public enum TourBoxAction: Equatable, Sendable {
    case command(Command)
    case scrub(Int)
    case edge(MarkEdge, Int)
    case endEdge, cancelEdge
    case beginSpeedHold, endSpeedHold
    case colorStrength(ColorSet, Double)
    case toggleFilmstrip, filmScroll(Double)
    case toggleAcceleration, reversePlayback
}

/// Console Max/MSP sends one byte per event (installed Console 5.12.1 uses OutputStream.write(int)). Every byte
/// matters, including coalesced TCP reads. These are relative pulses, not absolute angles or hardware timestamps.
public struct TourBoxRouter {
    private var held = Set<UInt8>()
    private var consumed = Set<UInt8>()
    private var edgeOwner: UInt8?
    private var topDeadline: Double?
    private var profileDeadline: Double?
    private var speedHeld = false
    /// Only held Top / Top+Tour schedule a one-shot callback. Nothing ticks at rest.
    public var nextDeadline: Double? { [topDeadline, profileDeadline].compactMap { $0 }.min() }
    public var framesPerPulse = 1.0
    public var accelerates = true {
        didSet { if accelerates != oldValue { resetMotion() } }
    }
    public var accelerationStart = 12.0
    public var scrollPointsPerPulse = 4.0
    private var carry = 0.0
    private var lastPulse: Double?
    private var pulsesAtLastTime = 0
    private var lastDirection = 0
    private var smoothedRate = 0.0

    public init() {}

    public mutating func receive(_ bytes: [UInt8], at time: Double, profile: MouseProfile) -> [TourBoxAction] {
        var actions = flush(at: time)
        for byte in bytes {
            switch byte {
            case 196, 132: actions += rotate(knob: true, direction: byte == 196 ? 1 : -1, at: time, profile: profile)
            case 201, 137: actions += rotate(knob: false, direction: byte == 201 ? -1 : 1, at: time, profile: profile)
            case 0, 2, 3, 10, 34, 35, 42, 55:
                guard held.insert(byte).inserted else { continue }
                resetMotion()
                // Pair before any tap: either press order works. A late Tour joins an active Top speed hold by
                // restoring playback first. Releasing an uncompleted pair never plays or saves a frame.
                if held == [2, 42] {
                    topDeadline = nil
                    profileDeadline = time + 0.6
                    consumed.formUnion(held)
                    actions += endSpeedHold()
                } else if held == [0, 2] || held == [3, 2] {
                    topDeadline = nil; profileDeadline = nil
                    actions += endSpeedHold()
                    actions.append(held.contains(0) ? .command(.cycleMute) : .reversePlayback)
                    consumed.formUnion(held)
                } else if held == [0, 34] || held == [0, 35] {
                    // The modifier may already be consumed by a previous target press. Each new target down
                    // still toggles immediately; duplicate downs were filtered by held.insert above.
                    actions.append(.command(held.contains(34) ? .toggleAutoColor : .toggleVibrance))
                    consumed.formUnion(held)
                } else if held.count > 1 {
                    consumed.formUnion(held)
                    topDeadline = nil; profileDeadline = nil
                    actions += endSpeedHold()
                } else if byte == 2 {
                    topDeadline = time + 0.4
                } else if byte == 55 {
                    consumed.insert(55)
                    actions.append(.toggleAcceleration)
                }
            case 128, 130, 131, 138, 162, 163, 170, 183:
                let button = byte - 128
                guard held.remove(button) != nil else { continue }
                if button == 2 { topDeadline = nil; actions += endSpeedHold() }
                if button == 2 || button == 42 { profileDeadline = nil }
                if edgeOwner == button { edgeOwner = nil; actions.append(.endEdge) }
                if !consumed.contains(button) {
                    switch button {
                    case 2: actions.append(.command(.cyclePause))
                    case 3: actions.append(.command(.setSpeed(1)))
                    case 10: actions.append(.toggleFilmstrip)
                    case 42: actions.append(.command(.screenshot))
                    case 34, 35:
                        actions.append(.command(profile == .viewing
                            ? (button == 34 ? .playlistPrev : .playlistNext)
                            : (button == 34 ? .markIn : .markOut)))
                    default: break
                    }
                }
                consumed.remove(button)
                resetMotion()
            default: break
            }
        }
        return actions
    }

    /// Also evaluated before a release, so a delayed run loop cannot turn a completed hold into a tap.
    public mutating func flush(at time: Double) -> [TourBoxAction] {
        if let deadline = profileDeadline, time >= deadline {
            profileDeadline = nil; topDeadline = nil
            return [.command(.cycleMouseProfile)]
        }
        if let deadline = topDeadline, time >= deadline {
            topDeadline = nil
            guard held == [2], !consumed.contains(2) else { return [] }
            consumed.insert(2); speedHeld = true
            return [.beginSpeedHold]
        }
        return []
    }

    public mutating func cancel() -> [TourBoxAction] {
        var actions: [TourBoxAction] = edgeOwner == nil ? [] : [.cancelEdge]
        actions += endSpeedHold()
        held.removeAll(); consumed.removeAll(); edgeOwner = nil
        topDeadline = nil; profileDeadline = nil
        resetMotion()
        return actions
    }

    private mutating func endSpeedHold() -> [TourBoxAction] {
        guard speedHeld else { return [] }
        speedHeld = false
        return [.endSpeedHold]
    }

    private mutating func rotate(knob: Bool, direction: Int, at time: Double, profile: MouseProfile) -> [TourBoxAction] {
        consumed.formUnion(held)
        topDeadline = nil; profileDeadline = nil
        let ending = endSpeedHold()
        // Unassigned combinations consume their taps; they never become zoom, scene steps or volume controls.
        if held.contains(2) || held.contains(42) || held.contains(55) || held.contains(10) { return ending }
        if held == [0] {
            if knob {
                return ending + [.command(.addVolume(Double(direction) * 2))]
            }
            return ending + [.command(.seek(Double(direction) * 60, .byConfig))]
        }
        if held == [3] { return ending + (knob ? [.command(.stepSpeed(direction))] : []) }
        if knob, held == [34] || held == [35] {
            let owner: UInt8 = held.contains(34) ? 34 : 35
            if profile == .viewing {
                return ending + [.colorStrength(owner == 34 ? .autoColor : .vibrance, Double(direction) * 0.05)]
            }
            edgeOwner = owner
            return ending + [.edge(owner == 34 ? .start : .end, direction)]
        }
        guard held.isEmpty else { return ending }
        guard knob else { return ending + [.filmScroll(Double(direction) * scrollPointsPerPulse)] }
        let frames = scrub(direction, at: time)
        return ending + (frames == 0 ? [] : [.scrub(frames)])
    }

    private mutating func resetMotion() {
        carry = 0; lastPulse = nil; pulsesAtLastTime = 0; lastDirection = 0; smoothedRate = 0
    }

    private mutating func scrub(_ direction: Int, at time: Double) -> Int {
        // Initial feel curve: one frame/pulse below 12 pulses/s (about 0.4 rev/s at 30 pulses/rev).
        // Quadratic gain has zero slope at entry and keeps growing for fast turns, bounded at 64×.
        // Rise smoothing (100 ms) rejects a single short interval; deceleration follows the current rate at once.
        // These are interaction choices for hardware trial, not measured worker limits or extra encoder precision.
        // Timestamp ties in a coalesced TCP read retain the last rate rather than manufacturing infinite speed.
        if lastDirection != direction { resetMotion() }
        else if lastPulse.map({ time - $0 > 0.2 }) == true {
            // A very slow turn must still accumulate fractions into frames; only velocity expires at rest.
            lastPulse = nil; pulsesAtLastTime = 0; smoothedRate = 0
        }
        if let lastPulse, time > lastPulse {
            let interval = time - lastPulse
            // The previous timestamp group contains every pulse received together. Its count over the next
            // elapsed interval estimates the sustained rate without inventing intra-batch hardware timestamps.
            let rate = min(200, Double(pulsesAtLastTime) / interval)
            let rise = -expm1(-interval / 0.1)
            smoothedRate = min(rate, smoothedRate + (rate - smoothedRate) * rise)
            pulsesAtLastTime = 1
        } else {
            // Bounded scalar; extra ties cannot increase the current gain or overflow an unbounded counter.
            pulsesAtLastTime = min(200, pulsesAtLastTime + 1)
        }
        lastDirection = direction; lastPulse = time
        let gain = accelerates
            ? 1 + min(63, pow(max(0, smoothedRate - accelerationStart) / 18, 2)) : 1
        carry += Double(direction) * framesPerPulse * gain
        let frames = Int(carry.rounded(.towardZero))
        carry -= Double(frames)
        return frames
    }
}
