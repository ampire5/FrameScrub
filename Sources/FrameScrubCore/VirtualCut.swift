import Foundation

/// The provider's locator and the version of the media whose time axis was analyzed.
public struct VirtualCutSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case scene, file, stream }

    public let kind: Kind
    public let locator: String
    public let version: String

    public init(kind: Kind, locator: String, version: String) {
        self.kind = kind
        self.locator = locator
        self.version = version
    }

    var isValid: Bool {
        guard !locator.isEmpty, locator.utf8.count <= 4096,
              !version.isEmpty, version.utf8.count <= 256 else { return false }
        switch kind {
        case .scene:
            return locator.utf8.count <= 64 && locator.utf8.allSatisfy { (48...57).contains($0) }
        case .file:
            return locator.hasPrefix("/") && !locator.contains("\0")
        case .stream:
            guard let url = URL(string: locator), let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme) && url.host != nil && url.user == nil && url.password == nil
        }
    }
}

/// Authored ranges survive overlap resolution so the editor can still change each selection.
public struct VirtualCutRange: Codable, Equatable, Sendable {
    public let id: String
    public let source: VirtualCutSource
    public let start: Double
    public let end: Double

    public init(id: String, source: VirtualCutSource, start: Double, end: Double) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
    }
}

public struct VirtualCut: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let revision: String
    public let ranges: [VirtualCutRange]

    public init(id: String, title: String, revision: String, ranges: [VirtualCutRange]) {
        self.id = id
        self.title = title
        self.revision = revision
        self.ranges = ranges
    }

    public var timeline: VirtualCutTimeline? {
        guard !id.isEmpty, id.utf8.count <= 128, !title.isEmpty, title.utf8.count <= 512,
              !revision.isEmpty, revision.utf8.count <= 128 else { return nil }
        return VirtualCutTimeline(ranges: ranges)
    }
}

/// The authored row currently editable on the original filmstrip. Its end is exclusive.
public struct VirtualCutFragmentEdges: Equatable, Sendable {
    public let rangeID: String
    public let start: Double
    public let end: Double

    public init?(rangeID: String, start: Double, end: Double) {
        guard !rangeID.isEmpty, rangeID.utf8.count <= 128, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= Double(Int32.max) else { return nil }
        self.rangeID = rangeID
        self.start = start
        self.end = end
    }

    public func time(for edge: MarkEdge) -> Double { edge == .start ? start : end }

    public func landing(edge: MarkEdge, at target: Double, index: FrameIndex,
                        duration: Double) -> (frame: Int, time: Double)? {
        guard index.isExact, index.frameCount > 0, target.isFinite, duration.isFinite, duration > 0 else { return nil }
        let last = index.frameCount - 1
        let target = min(max(target, 0), duration)
        let frame = index.frameNumber(forSeconds: target)
        switch edge {
        case .start:
            let candidate = min(frame, index.frameNumber(before: min(end, duration)))
            let time = max(0, index.seconds(forFrame: candidate))
            return time < min(end, duration) ? (candidate, time) : nil
        case .end:
            if target == duration, duration > start { return (index.frameNumber(before: duration), duration) }
            let firstLater = index.frameNumber(before: start.nextUp) + 1
            let candidate = min(last, max(frame, firstLater))
            let time = index.seconds(forFrame: candidate)
            if time > start, time < duration { return (candidate, time) }
            return duration > start ? (index.frameNumber(before: duration), duration) : nil
        }
    }
}

/// Time is in seconds, and each span's end is exclusive.
public struct VirtualCutTimeline: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public let source: VirtualCutSource
        public let sourceStart: Double
        public let sourceEnd: Double
        public let cutStart: Double
        public let cutEnd: Double
    }

    public struct Location: Equatable, Sendable {
        public let spanIndex: Int
        public let sourceTime: Double
    }

    public struct Anchor: Codable, Equatable, Sendable {
        public let rangeID: String
        public let sourceTime: Double
    }

    private struct Union {
        var start: Double
        var end: Double
        var members: [Int]
        var first: Int
    }

    public static let maximumRanges = 2000
    public let spans: [Span]
    public var duration: Double { spans.last?.cutEnd ?? 0 }
    private let ranges: [VirtualCutRange]
    private let members: [[Int]]
    private let authoredIndex: [String: Int]
    private let spanForRange: [Int]

    public init?(ranges: [VirtualCutRange]) {
        guard !ranges.isEmpty, ranges.count <= Self.maximumRanges else { return nil }
        var bySource: [VirtualCutSource: [Int]] = [:]
        var authoredIndex: [String: Int] = [:]
        for (index, range) in ranges.enumerated() {
            guard !range.id.isEmpty, range.id.utf8.count <= 128, range.source.isValid,
                  range.start.isFinite, range.start >= 0, range.end.isFinite,
                  range.end <= Double(Int32.max), range.end > range.start,
                  authoredIndex.updateValue(index, forKey: range.id) == nil else { return nil }
            bySource[range.source, default: []].append(index)
        }
        var unions: [Union] = []
        for indices in bySource.values {
            let sorted = indices.sorted { ranges[$0].start < ranges[$1].start }
            var current: Union?
            for index in sorted {
                let range = ranges[index]
                if let end = current?.end, range.start < end {
                    current?.end = max(end, range.end)
                    current?.members.append(index)
                    if let first = current?.first { current?.first = min(first, index) }
                } else {
                    if let current { unions.append(current) }
                    current = Union(start: range.start, end: range.end, members: [index], first: index)
                }
            }
            if let current { unions.append(current) }
        }
        unions.sort { $0.first < $1.first }
        var spans: [Span] = []
        var spanForRange = Array(repeating: 0, count: ranges.count)
        var cutStart = 0.0
        for (index, union) in unions.enumerated() {
            let cutEnd = cutStart + (union.end - union.start)
            guard cutEnd > cutStart else { return nil }
            spans.append(Span(source: ranges[union.first].source, sourceStart: union.start, sourceEnd: union.end,
                              cutStart: cutStart, cutEnd: cutEnd))
            for member in union.members { spanForRange[member] = index }
            cutStart = cutEnd
        }
        self.spans = spans
        self.ranges = ranges
        self.members = unions.map { $0.members.sorted() }
        self.authoredIndex = authoredIndex
        self.spanForRange = spanForRange
    }

    public func location(at time: Double) -> Location? {
        guard time.isFinite else { return nil }
        let target = min(max(time, 0), duration)
        var lo = 0
        var hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if target < spans[mid].cutEnd { hi = mid } else { lo = mid + 1 }
        }
        let span = spans[lo]
        return Location(spanIndex: lo, sourceTime: min(span.sourceEnd.nextDown, span.sourceStart + (target - span.cutStart)))
    }

    public func anchor(at time: Double) -> Anchor? {
        guard let location = location(at: time),
              let member = members[location.spanIndex].first(where: {
                  let range = ranges[$0]
                  return range.start <= location.sourceTime && location.sourceTime < range.end
              }) else { return nil }
        return Anchor(rangeID: ranges[member].id, sourceTime: location.sourceTime)
    }

    /// Picks the authored row under the playhead, or the row at the selected span's start.
    public func editAnchor(span: Int, currentTime: Double) -> Anchor? {
        guard spans.indices.contains(span) else { return nil }
        return anchor(at: location(at: currentTime)?.spanIndex == span ? currentTime : spans[span].cutStart)
    }

    public func editAnchor(rangeID: String, currentTime: Double) -> Anchor? {
        guard let row = authoredIndex[rangeID] else { return nil }
        let range = ranges[row]
        if let current = location(at: currentTime), current.spanIndex == spanForRange[row],
           range.start <= current.sourceTime, current.sourceTime < range.end {
            return Anchor(rangeID: rangeID, sourceTime: current.sourceTime)
        }
        return Anchor(rangeID: rangeID, sourceTime: range.start)
    }

    public func resume(at anchor: Anchor, fallback: Double = 0) -> Double {
        guard let index = authoredIndex[anchor.rangeID], anchor.sourceTime.isFinite else {
            return fallback.isFinite ? min(max(0, fallback), duration) : 0
        }
        let range = ranges[index]
        let span = spans[spanForRange[index]]
        let sourceTime = max(range.start, min(anchor.sourceTime, range.end.nextDown))
        return min(span.cutEnd.nextDown, span.cutStart + (sourceTime - span.sourceStart))
    }
}
