import Foundation

/// Where to land in a file once it is open: a position, a segment to loop, or both. Carried by `framescrub://open`
/// links and by a plugin page's `open`; it says nothing about which file, so the same value serves a local path and a
/// Stash scene whose file is still being found.
public struct LinkTarget: Equatable, Sendable {
    /// The position to start at, in seconds; nil leaves it to the remembered position (or the segment's start).
    public var time: Double?
    /// An A-B loop to play and scrub inside.
    public var segment: ClosedRange<Double>?

    public init(time: Double? = nil, segment: ClosedRange<Double>? = nil) {
        self.time = time
        self.segment = segment
    }

    /// Where to land: `time`, else the segment's start.
    public var start: Double? { time ?? segment?.lowerBound }

    /// Nothing to apply: neither a position nor a segment.
    public var isEmpty: Bool { time == nil && segment == nil }

    /// "12.5-18" → 12.5...18; nil when malformed, negative, or empty (b must be above a).
    public static func segment(from text: String) -> ClosedRange<Double>? {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let a = parts[0], let b = parts[1] else { return nil }
        return segment(a, b)
    }

    /// `a...b` when it is a segment: both finite, `a` not negative, `b` above `a`.
    public static func segment(_ a: Double, _ b: Double) -> ClosedRange<Double>? {
        guard a.isFinite, b.isFinite, a >= 0, b > a else { return nil }
        return a...b
    }

    /// `t` when it is a position: finite and not negative.
    public static func time(_ t: Double) -> Double? {
        t.isFinite && t >= 0 ? t : nil
    }
}
