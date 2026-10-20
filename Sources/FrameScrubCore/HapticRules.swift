import Foundation

/// The haptic a step on a numeric setting (auto-colour strength) plays: `.limit` past an end, `.detent` onto or across
/// a detent, else `.step`. Pure: the caller reads the value, asks here, applies the result and plays the event.
public enum AdjustStep {
    /// `value + delta` rounded to a multiple of `|step|` (so `0.65`, not `0.6500001`) and clamped to `range`.
    /// Event: `.limit` if the move went past an end (a push against the bound the value already sits on included), else
    /// `.detent` if it landed on or crossed a detent (from exclusive, to inclusive, either direction), else `.step`.
    public static func apply(_ value: Double, by delta: Double, step: Double, range: ClosedRange<Double>,
                             detents: [Double]) -> (value: Double, event: HapticEvent) {
        let eps = 1e-9
        let raw = value + delta
        let unit = abs(step)
        // Round to a multiple of the step, then to 6 places to shed the multiplication's noise.
        let snapped = unit > 0 ? ((raw / unit).rounded() * unit * 1e6).rounded() / 1e6 : raw
        let result = min(max(snapped, range.lowerBound), range.upperBound)
        if raw < range.lowerBound - eps || raw > range.upperBound + eps
            || snapped < range.lowerBound - eps || snapped > range.upperBound + eps {
            return (result, .limit)
        }
        let crossed = detents.contains { d in
            value < result ? (d > value + eps && d <= result + eps) : (d < value - eps && d >= result - eps)
        }
        return (result, crossed ? .detent : .step)
    }
}

/// The tick a scrub plays when it passes a mark edge (`.mark`) or a keyframe (`.keyframe`), at most one per
/// `minInterval` so a fast scrub is not a buzz.
public struct ScrubTicks: Sendable {
    /// The seconds after a returned tick within which no further tick is returned.
    public static let minInterval = 0.04

    private var lastTick: Double?

    public init() {}

    /// A scrub moved from frame `from` to `to`. `.mark` if a frame of `marks` (mark starts and ends, A, B) lies in
    /// (from, to] (or [to, from) going back), else `.keyframe` if one of `keyframes` (sorted ascending) does, else nil;
    /// nil too within `minInterval` of the last returned tick.
    public mutating func crossed(from: Int, to: Int, keyframes: [Int], marks: [Int], at t: Double) -> HapticEvent? {
        guard from != to else { return nil }
        if let last = lastTick, t - last < Self.minInterval { return nil }
        // The frames passed over, as the inclusive range lo...hi: forward (from, to], backward [to, from).
        let lo = from < to ? from + 1 : to
        let hi = from < to ? to : from - 1
        let event: HapticEvent
        if marks.contains(where: { $0 >= lo && $0 <= hi }) {
            event = .mark
        } else if Self.containsValue(in: lo...hi, sorted: keyframes) {
            event = .keyframe
        } else {
            return nil
        }
        lastTick = t
        return event
    }

    /// Whether the ascending `sorted` holds a value in `range`: binary search for the first one at or above its start.
    private static func containsValue(in range: ClosedRange<Int>, sorted: [Int]) -> Bool {
        var l = 0, h = sorted.count
        while l < h {
            let mid = (l + h) / 2
            if sorted[mid] < range.lowerBound { l = mid + 1 } else { h = mid }
        }
        return l < sorted.count && sorted[l] <= range.upperBound
    }
}

/// When a previous / next step that stopped at an end plays `haptic-end`: one bump per push against the end. The first
/// blocked step bumps; auto-repeats of a held key and further notches of a spinning wheel into the same end do not,
/// until a step moves, a step goes against the other end (a one-file list), or a fresh press comes. Fresh: a key press
/// that is not an auto-repeat, a mouse-button press, or a wheel notch after a pause of `wheelPause` (`isFreshNotch`).
public struct EndBump: Sendable {
    /// The seconds without a notch after which the next notch is a new push: longer than the gaps between the notches
    /// of a spin, shorter than a deliberate second turn.
    public static let wheelPause: TimeInterval = 0.3

    /// The direction of the end last bumped against, nil once a step moved.
    private var bumped: Int?

    public init() {}

    /// A step was tried: `moved` false when it stopped at an end; `direction` its sign. True: play `haptic-end`.
    public mutating func stepped(moved: Bool, direction: Int, fresh: Bool) -> Bool {
        guard !moved else {
            bumped = nil
            return false
        }
        let d = direction.signum()
        if bumped == d, !fresh { return false }
        bumped = d
        return true
    }

    /// Whether a wheel notch at `time` starts a new push: the first notch, or one `wheelPause` after the previous.
    public static func isFreshNotch(at time: TimeInterval, previous: TimeInterval?) -> Bool {
        guard let previous else { return true }
        return time - previous >= wheelPause
    }
}
