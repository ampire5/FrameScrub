import Foundation

/// One marked stretch of a video, frames `start` through `end`.
public struct CutSegment: Equatable, Codable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// The segments marked in a file for cutting (cut marks spec §2): sorted, never overlapping or touching, plus at
/// most one open segment whose start is set (`I`) and whose end is not yet (`O`). Frame numbers of the file's index.
public struct CutMarks: Equatable, Sendable {
    public private(set) var segments: [CutSegment]
    public private(set) var open: Int?

    public init(segments: [CutSegment] = [], open: Int? = nil) {
        self.segments = segments
        self.open = open
        normalize()
    }

    public var isEmpty: Bool { segments.isEmpty && open == nil }

    /// 0-based index of the segment with `start ≤ frame ≤ end`.
    public func segmentIndex(containing frame: Int) -> Int? {
        segments.firstIndex { $0.start <= frame && frame <= $0.end }
    }

    /// 1-based number, by start, among the segments and the open start, of the one starting at `start`.
    public func number(ofSegmentStartingAt start: Int) -> Int {
        segments.filter { $0.start < start }.count + (open.map { $0 < start ? 1 : 0 } ?? 0) + 1
    }

    /// `I`: moves the open start, else the start of the segment at `p`, else opens a segment at `p`.
    @discardableResult
    public mutating func markIn(at p: Int) -> Int {
        if open == nil, let i = segmentIndex(containing: p) {
            segments[i].start = p
            normalize()
            return numberOfSegment(containing: p)
        }
        open = p
        return number(ofSegmentStartingAt: p)
    }

    /// `O`: closes the open segment at `p`, else moves the end of the segment at `p`, else moves the end of the
    /// nearest segment left of `p` to `p` (none: a segment from the first frame).
    @discardableResult
    public mutating func markOut(at p: Int) -> Int {
        if let start = open {
            open = nil
            return add(CutSegment(start: min(start, p), end: max(start, p)))
        }
        if let i = segmentIndex(containing: p) ?? segments.lastIndex(where: { $0.end < p }) {
            segments[i].end = p
            normalize()
            return numberOfSegment(containing: p)
        }
        return add(CutSegment(start: 0, end: p))
    }

    /// Adds `segment`, merging it with any it overlaps or touches; the number of the segment it ends up in.
    @discardableResult
    public mutating func add(_ segment: CutSegment) -> Int {
        segments.append(segment)
        normalize()
        return numberOfSegment(containing: segment.start)
    }

    private func numberOfSegment(containing frame: Int) -> Int {
        number(ofSegmentStartingAt: segments[segmentIndex(containing: frame)!].start)
    }

    /// Removes the segment at `p`, else the open one; its number, nil when there is neither.
    public mutating func delete(at p: Int) -> Int? {
        if let i = segmentIndex(containing: p) {
            let number = number(ofSegmentStartingAt: segments[i].start)
            segments.remove(at: i)
            return number
        }
        if let start = open {
            let number = number(ofSegmentStartingAt: start)
            open = nil
            return number
        }
        return nil
    }

    /// Removes everything; how many segments (the open one included) there were.
    public mutating func clear() -> Int {
        let count = segments.count + (open == nil ? 0 : 1)
        segments = []
        open = nil
        return count
    }

    /// `k`: moves the start of the segment at `p` (else the open start) to the nearer keyframe, the one at or after
    /// it only while that stays within the segment. Nil without such a segment or without an exact index.
    public mutating func snapStart(at p: Int, index: FrameIndex) -> Int? {
        guard index.isExact else { return nil }
        func nearest(to start: Int, limit: Int?) -> Int {
            let before = index.keyframe(atOrBefore: start)
            guard before != start, let after = index.keyframe(after: start - 1), limit.map({ after <= $0 }) ?? true
            else { return before }
            let seconds = index.seconds(forFrame: start)
            return index.seconds(forFrame: after) - seconds < seconds - index.seconds(forFrame: before) ? after : before
        }
        if let i = segmentIndex(containing: p) {
            let start = nearest(to: segments[i].start, limit: segments[i].end)
            segments[i].start = start
            normalize()
            return numberOfSegment(containing: start)
        }
        guard let start = open else { return nil }
        open = nearest(to: start, limit: nil)
        return number(ofSegmentStartingAt: open!)
    }

    /// The start of the segment (or open start) numbered `n` (1-based, by start).
    public func start(ofNumber n: Int) -> Int? {
        let starts = (segments.map(\.start) + (open.map { [$0] } ?? [])).sorted()
        return starts.indices.contains(n - 1) ? starts[n - 1] : nil
    }

    /// The nearest segment edge (or open start) before / after `p`.
    public func boundary(before p: Int) -> Int? { edges.last { $0 < p } }
    public func boundary(after p: Int) -> Int? { edges.first { $0 > p } }

    private var edges: [Int] {
        (segments.flatMap { [$0.start, $0.end] } + (open.map { [$0] } ?? [])).sorted()
    }

    /// The marks with every frame number transformed (an index remap).
    public func mapped(_ transform: (Int) -> Int) -> CutMarks {
        CutMarks(segments: segments.map { CutSegment(start: transform($0.start), end: transform($0.end)) },
                 open: open.map(transform))
    }

    /// The open segment closed at `p` when `p` is after its start; otherwise unchanged.
    public func closed(at p: Int) -> CutMarks {
        guard let start = open, p > start else { return self }
        var marks = self
        marks.markOut(at: p)
        return marks
    }

    /// Sorted by start, each `start ≤ end`, overlapping or touching segments merged.
    private mutating func normalize() {
        let sorted = segments.map { CutSegment(start: min($0.start, $0.end), end: max($0.start, $0.end)) }
            .sorted { $0.start < $1.start }
        var merged: [CutSegment] = []
        for segment in sorted {
            if let last = merged.last, segment.start <= last.end + 1 {
                merged[merged.count - 1].end = max(last.end, segment.end)
            } else {
                merged.append(segment)
            }
        }
        segments = merged
    }
}

/// ⌘Z / ⇧⌘Z for cut marks (spec §2.2): the marks before each change with the change's name, at most `limit`
/// steps. A new change drops what could be redone.
public struct CutHistory: Sendable {
    private let limit: Int
    private var undoSteps: [(marks: CutMarks, label: String)] = []
    private var redoSteps: [(marks: CutMarks, label: String)] = []

    public init(limit: Int = 100) { self.limit = limit }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    /// Records a change named `label` made to `before`.
    public mutating func record(_ before: CutMarks, label: String) {
        undoSteps.append((before, label))
        if undoSteps.count > limit { undoSteps.removeFirst(undoSteps.count - limit) }
        redoSteps = []
    }

    /// The marks before the last change and its name; `current` becomes what redo brings back.
    public mutating func undo(_ current: CutMarks) -> (marks: CutMarks, label: String)? {
        guard let step = undoSteps.popLast() else { return nil }
        redoSteps.append((current, step.label))
        return step
    }

    /// The marks after the last undone change and its name.
    public mutating func redo(_ current: CutMarks) -> (marks: CutMarks, label: String)? {
        guard let step = redoSteps.popLast() else { return nil }
        undoSteps.append((current, step.label))
        return step
    }
}

/// What `c` would save in each mode (the sheet's numbers, cut marks spec §4.1). Seconds include the lead-ins from
/// the keyframes the clips start on; `joinedSeconds` (several marks) and `invertedSeconds` are nil until the index is
/// exact.
public struct ClipSummary: Equatable, Sendable {
    public let segments: Int
    public let separateClips: Int
    public let separateSeconds: Double
    public let separateLeadIn: Double
    public let joinedSeconds: Double?
    public let joinedLeadIn: Double
    public let invertedSeconds: Double?
}

extension CutMarks {
    /// Frames past a range's end that its clip may already hold: the references written so its last frames decode
    /// (B-frame reorder delay). A next range whose keyframe falls within them joins it, so no frame is written twice.
    static let reorderFrames = 4

    /// The frame ranges `c` writes in `mode` (spec §4.4), one inner array per clip job; the open segment is not
    /// included (close it first). Empty = nothing to save; nil = needs an exact index (`inverted`, and `joined` of
    /// several segments: without known keyframes a range could start inside the one before and repeat it).
    public func clipRanges(_ mode: ClipMode, index: FrameIndex) -> [[ClosedRange<Int>]]? {
        let ranges = segments.map { $0.start...$0.end }
        switch mode {
        case .separate:
            return ranges.map { [$0] }
        case .joined:
            guard index.isExact || ranges.count < 2 else { return nil }
            // A segment whose clip would start (on its keyframe) inside the one before joins it: no frame twice.
            var joined: [ClosedRange<Int>] = []
            for range in ranges {
                if let last = joined.last,
                   index.keyframe(atOrBefore: range.lowerBound) <= last.upperBound + 1 + Self.reorderFrames {
                    joined[joined.count - 1] = last.lowerBound...range.upperBound
                } else {
                    joined.append(range)
                }
            }
            return joined.isEmpty ? [] : [joined]
        case .inverted:
            guard index.isExact else { return nil }
            // Each gap starts on the first keyframe after a segment, so nothing marked gets in.
            let starts = [0] + ranges.map { index.keyframe(after: $0.upperBound) }
            let ends = ranges.map { $0.lowerBound - 1 } + [index.frameCount - 1]
            let gaps = zip(starts, ends).compactMap { start, end in start.flatMap { $0 <= end ? $0...end : nil } }
            return gaps.isEmpty ? [] : [gaps]
        }
    }
}
