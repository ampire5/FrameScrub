import Foundation

/// Where to land in a file once it is open: a position, the segments to lock, or both. Carried by `framescrub://open`
/// links and by a plugin page's `open`; it says nothing about which file, so the same value serves a local path and a
/// Stash scene whose file is still being found.
public struct LinkTarget: Equatable, Sendable {
    /// The position to start at, in seconds; nil leaves it to the remembered position (or the first segment's start).
    public var time: Double?
    /// The segments to lock playback and scrubbing to; empty for none.
    public var segments: [ClosedRange<Double>]
    /// Whether the segments lock playback; nil leaves it to the default (locked).
    public var lock: Bool?
    /// What playback does at a segment's end; nil leaves it to the configuration.
    public var advance: SegmentAdvance?

    public init(time: Double? = nil, segments: [ClosedRange<Double>] = [], lock: Bool? = nil,
                advance: SegmentAdvance? = nil) {
        self.time = time
        self.segments = segments
        self.lock = lock
        self.advance = advance
    }

    /// Where to land: `time`, else the first segment's start.
    public var start: Double? { time ?? segments.first?.lowerBound }

    /// Nothing to apply: neither a position nor segments.
    public var isEmpty: Bool { time == nil && segments.isEmpty }

    /// "10-20,35.5-40" → two segments; nil when any item is malformed (the whole list is then ignored).
    public static func segments(from text: String) -> [ClosedRange<Double>]? {
        var result: [ClosedRange<Double>] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let segment = segment(from: String(item)) else { return nil }
            result.append(segment)
        }
        return result
    }

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
