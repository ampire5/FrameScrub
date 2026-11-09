/// State for the host's asynchronous opens. Only the latest seek may update a cut.
public struct VirtualCutPlayback: Sendable {
    public struct Request: Equatable, Sendable {
        let generation: UInt64
        public let location: VirtualCutTimeline.Location
    }

    public let timeline: VirtualCutTimeline
    public var wantsPlayback = false
    public var loops = false
    public private(set) var position = 0.0
    public private(set) var activeSpan: Int?
    public private(set) var pending: Request?
    public private(set) var failure: Request?
    private var generation: UInt64 = 0

    public init(timeline: VirtualCutTimeline) {
        self.timeline = timeline
    }

    public mutating func seek(_ time: Double, playing: Bool) -> Request? {
        guard let location = timeline.location(at: time) else { return nil }
        position = min(max(time, 0), timeline.duration)
        wantsPlayback = playing
        failure = nil
        generation &+= 1
        let request = Request(generation: generation, location: location)
        pending = request
        return request
    }

    public mutating func opened(_ request: Request) -> Bool {
        guard pending == request else { return false }
        pending = nil
        activeSpan = request.location.spanIndex
        return true
    }

    public mutating func failed(_ request: Request) -> Bool {
        guard pending == request else { return false }
        pending = nil
        failure = request
        activeSpan = nil
        return true
    }

    public mutating func retry() -> Request? {
        guard failure != nil else { return nil }
        return seek(position, playing: wantsPlayback)
    }

    public mutating func update(sourceTime: Double) {
        guard pending == nil, failure == nil, let activeSpan, sourceTime.isFinite else { return }
        let span = timeline.spans[activeSpan]
        position = max(span.cutStart, min(span.cutEnd.nextDown, span.cutStart + (sourceTime - span.sourceStart)))
    }

    public mutating func advance(_ direction: Int) -> Request? {
        let index = pending?.location.spanIndex ?? failure?.location.spanIndex ?? activeSpan ?? 0
        let next = index + (direction < 0 ? -1 : 1)
        let spans = timeline.spans
        if spans.indices.contains(next) {
            return seek(direction < 0 ? spans[next].cutEnd.nextDown : spans[next].cutStart, playing: wantsPlayback)
        }
        if loops {
            return seek(direction < 0 ? timeline.duration : 0, playing: wantsPlayback)
        }
        wantsPlayback = false
        return nil
    }
}
