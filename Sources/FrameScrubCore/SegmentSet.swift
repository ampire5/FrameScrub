import Foundation

/// What playback does on reaching the end of a segment: play it again, or go on to the next one.
/// The raw values are the contract (`repeat` is a Swift keyword, hence `repeating`).
public enum SegmentAdvance: String, Sendable, Codable {
    case repeating = "repeat", next
}

/// The segments the playhead is kept inside: sorted, non-overlapping, non-touching frame ranges of one file.
/// Moves through it are "glued": the gaps between ranges do not exist, so frames are counted along the
/// concatenation of the ranges.
public struct SegmentSet: Equatable, Sendable {
    public private(set) var ranges: [ClosedRange<Int>]

    /// Sorts `frames`, merges ranges that overlap or touch, clamps them to `0...frameCount-1` and drops the empty ones.
    public init(frames: [ClosedRange<Int>], frameCount: Int) {
        let last = frameCount - 1
        let clamped = frames.compactMap { r -> ClosedRange<Int>? in
            let lower = max(r.lowerBound, 0), upper = min(r.upperBound, last)
            return lower <= upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for r in clamped {
            if let prev = merged.last, r.lowerBound <= prev.upperBound + 1 {
                merged[merged.count - 1] = prev.lowerBound...max(prev.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        ranges = merged
    }

    public var isEmpty: Bool { ranges.isEmpty }

    /// 0-based index of the range containing `frame`.
    public func index(containing frame: Int) -> Int? {
        ranges.firstIndex { $0.contains(frame) }
    }

    /// `frame` itself when inside a range; otherwise the nearest edge of the nearest range, the earlier range's
    /// edge on a tie. An empty set returns `frame` unchanged.
    public func nearest(_ frame: Int) -> Int {
        guard let first = ranges.first, let lastRange = ranges.last else { return frame }
        if frame < first.lowerBound { return first.lowerBound }
        if frame > lastRange.upperBound { return lastRange.upperBound }
        for (i, r) in ranges.enumerated() {
            if r.contains(frame) { return frame }
            let next = ranges[i + 1]   // frame lies past r and not past the last range, so a next one exists
            if frame < next.lowerBound {
                return frame - r.upperBound <= next.lowerBound - frame ? r.upperBound : next.lowerBound
            }
        }
        return frame   // unreachable: every frame within first.lower...last.upper is in a range or a gap
    }

    /// Moves by `target - position` frames along the concatenation of the ranges, starting from `nearest(position)`
    /// and clamped to the first and last frame of the set. A zero move returns `nearest(target)`; an empty set
    /// returns `target` unchanged.
    public func glued(from position: Int, to target: Int) -> Int {
        guard !ranges.isEmpty else { return target }
        let delta = target - position
        guard delta != 0 else { return nearest(target) }
        let total = ranges.reduce(0) { $0 + $1.count }
        let offset = min(max(offset(of: nearest(position)) + delta, 0), total - 1)
        return frame(at: offset)
    }

    /// Position of `frame` (which must lie in a range) on the concatenation of the ranges.
    private func offset(of frame: Int) -> Int {
        var before = 0
        for r in ranges {
            if r.contains(frame) { return before + (frame - r.lowerBound) }
            before += r.count
        }
        return before - 1
    }

    /// The frame at `offset` (which must be within `0..<total`) on the concatenation of the ranges.
    private func frame(at offset: Int) -> Int {
        var left = offset
        for r in ranges {
            if left < r.count { return r.lowerBound + left }
            left -= r.count
        }
        return ranges[ranges.count - 1].upperBound
    }
}
