import Foundation

/// `scrub-edge` (mouse spec §5.4): the start or end of the mark under the playhead follows the frame while the wheel
/// scrubs. Bounded by its pair and the neighbouring segment (a frame short of it, since touching segments merge), so
/// the live marks never merge or reorder; the edge is set directly, never through `markIn` / `markOut`.
public struct EdgeDrag: Equatable, Sendable {
    private enum Target: Equatable, Sendable {
        case segment(Int)   // index into `original.segments`
        case open
        case none           // nothing under the playhead: a plain scrub
    }

    public let edge: MarkEdge
    /// The marks when the drag began: what cancel puts back and what ⌘Z returns to.
    public let original: CutMarks
    private let target: Target
    private let frameCount: Int

    /// Starts on the segment containing `position` (or the open start, for .start); nil segment = plain scrub.
    public init(edge: MarkEdge, marks: CutMarks, position: Int, frameCount: Int) {
        self.edge = edge
        original = marks
        self.frameCount = frameCount
        if let i = marks.segmentIndex(containing: position) {
            target = .segment(i)
        } else if edge == .start, marks.open != nil {
            target = .open
        } else {
            target = .none
        }
    }

    /// Whether an edge is dragged at all (false: the drag only scrubs).
    public var movesAnEdge: Bool { target != .none }

    /// Where the playhead may go: start ≤ own end − 1 and ≥ previous end + 2; end ≥ own start + 1 and ≤ next start − 2;
    /// whole file without a segment. Always holds the edge's own frame (a one-frame segment keeps start = end).
    /// An open start has no neighbour bound: the whole file, like a tap on I.
    public var allowed: ClosedRange<Int> {
        let file = 0...max(frameCount - 1, 0)
        guard case let .segment(i) = target else { return file }
        let segments = original.segments
        let segment = segments[i]
        switch edge {
        case .start:
            let low = i > 0 ? segments[i - 1].end + 2 : file.lowerBound
            return min(low, segment.start)...max(segment.end - 1, segment.start)
        case .end:
            let high = i + 1 < segments.count ? segments[i + 1].start - 2 : file.upperBound
            return min(segment.start + 1, segment.end)...max(high, segment.end)
        }
    }

    /// The marks with the dragged edge at `frame` (clamped to `allowed`).
    public func marks(at frame: Int) -> CutMarks {
        let frame = min(max(frame, allowed.lowerBound), allowed.upperBound)
        switch target {
        case .none:
            return original
        case .open:
            return CutMarks(segments: original.segments, open: frame)
        case let .segment(i):
            var segments = original.segments
            switch edge {
            case .start: segments[i].start = frame
            case .end: segments[i].end = frame
            }
            return CutMarks(segments: segments, open: original.open)   // within the bounds: nothing to merge
        }
    }
}
