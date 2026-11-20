import Foundation

/// A worker-owned cursor over one video. It decodes from the demuxer's nearest keyframe and
/// uses actual presentation times. Its approximate index is only for VideoDecoder's internal bookkeeping.
public final class OnDemandVideo {
    public enum SeekError: Error, Equatable {
        case invalidTime
        case ambiguousPresentationOrder
        case lostDisplayedFrame
    }

    private let decoder: VideoDecoder
    private let media: MediaSource
    private var currentPTS: Int64?
    private var recent: FrameWindow
    private var firstPTS: Int64?

    public var duration: Double { media.durationSeconds }
    public var rotationClockwise: Int { media.rotationClockwise }
    public var sampleAspect: Double { media.sampleAspect }

    public convenience init(url: URL, source: ByteSource, preferHardware: Bool = true) throws {
        let cache = try ReadCache(url: url, budgetBytes: 0, source: source)
        try self.init(url: url, readCache: cache, preferHardware: preferHardware)
    }

    /// The caller can close the read cache on cancellation, including while the demuxer is opening.
    public init(url: URL, readCache: ReadCache, preferHardware: Bool = true) throws {
        let media = try MediaSource(url: url, readCache: readCache, readAhead: false)
        self.media = media
        recent = FrameWindow(byteLimit: Self.historyByteLimit(for: media))
        decoder = try VideoDecoder(source: media, index: media.approximateIndex(),
                                   preferHardware: preferHardware, allowVideoToolboxBackend: true, softwareThreads: 1)
    }

    private static func historyByteLimit(for media: MediaSource) -> Int {
        let videoLimit = 64 << 20
        guard media.format.videoCodec == "gif" else { return videoLimit }
        // A 1080p GIF frame occupies 8 MiB in BGRA. The 20-frame reverse scrub bench needs
        // room for the anchor as well. A GIF may have only one keyframe, so a miss can replay
        // from the beginning. Keep the video budget on smaller machines and cap the GIF budget.
        let gifLimit = 192 << 20
        let memoryShare = ProcessInfo.processInfo.physicalMemory / 128
        return max(videoLimit, Int(min(UInt64(gifLimit), memoryShare)))
    }

    /// Audio gets its own demuxer cursor and shares the already-open file, including its cancellation.
    public func makeAudioDecoder() throws -> AudioDecoder? {
        guard media.audioStreamIndex != nil else { return nil }
        if media.readCache.probe == nil { media.readCache.probe = StreamProbe(media) }
        return try AudioDecoder(url: media.url, zeroSeconds: Double(media.startPTS) * media.timeBase,
                                readCache: media.readCache, readAhead: false)
    }

    public func time(of frame: DecodedFrame) -> Double {
        (Double(frame.pts) - Double(media.startPTS)) * media.timeBase
    }

    /// Presents the frame covering the requested time. At the end it presents the last frame.
    public func seek(to seconds: Double, isCancelled: () -> Bool = { false }) throws -> DecodedFrame? {
        guard seconds.isFinite, media.timeBase > 0 else { throw SeekError.invalidTime }
        let upperBound = duration.isFinite && duration > 0 ? duration : seconds
        let seconds = max(0, min(seconds, upperBound))
        let target = seconds / media.timeBase + Double(media.startPTS)
        let nearestTick = target.rounded()
        let ticks = abs(nearestTick - target) <= 2 * target.ulp ? nearestTick : target.rounded(.down)
        guard let pts = Int64(exactly: ticks) else { throw SeekError.invalidTime }

        try checkCancellation(isCancelled)
        if let frame = recent.covering(pts) { return present(frame) }
        currentPTS = nil
        let (earlier, atOrAfter) = try bracket(pts, needPredecessor: false, isCancelled: isCancelled)
        if let atOrAfter, atOrAfter.pts == pts { return present(atOrAfter) }
        return (earlier ?? atOrAfter).map(present)
    }

    public func next(isCancelled: () -> Bool = { false }) throws -> DecodedFrame? {
        try checkCancellation(isCancelled)
        if let currentPTS, let frame = recent.adjacent(to: currentPTS, offset: 1) { return present(frame) }
        let firstRead = currentPTS == nil
        guard let frame = try decode(after: currentPTS, isCancelled: isCancelled) else { return nil }
        if firstRead { firstPTS = frame.pts }
        recent.append(frame)
        return present(frame)
    }

    /// Reuse the contiguous decoded run when possible. On a miss, seek to the preceding keyframe
    /// and collect the tail while decoding toward the current frame.
    public func previous(isCancelled: () -> Bool = { false }) throws -> DecodedFrame? {
        try checkCancellation(isCancelled)
        guard let anchor = currentPTS, anchor > media.startPTS, anchor != firstPTS else { return nil }
        if let frame = recent.adjacent(to: anchor, offset: -1) { return present(frame) }
        let (earlier, atOrAfter) = try bracket(anchor, needPredecessor: true, isCancelled: isCancelled)
        guard let atOrAfter, atOrAfter.pts == anchor else {
            recent.clear()
            throw SeekError.lostDisplayedFrame
        }
        return earlier.map(present)
    }

    private func bracket(_ target: Int64, needPredecessor: Bool, isCancelled: () -> Bool)
        throws -> (DecodedFrame?, DecodedFrame?) {
        // A seek breaks continuity with the decoder's previous run. Only publish a replacement
        // window once a scan lands, so cancellation or failure cannot expose a partial run.
        recent.clear()
        var landing = needPredecessor ? target - 1 : target
        var backoffSeconds = 1.0
        while true {
            try checkCancellation(isCancelled)
            try decoder.seekToKeyframe(atOrBeforePTS: landing)
            var earlier: DecodedFrame?
            var atOrAfter: DecodedFrame?
            var scanned = FrameWindow(byteLimit: recent.byteLimit)
            while let frame = try decode(after: earlier?.pts, isCancelled: isCancelled) {
                scanned.append(frame)
                if frame.pts >= target {
                    atOrAfter = frame
                    break
                }
                earlier = frame
            }
            if earlier != nil || (!needPredecessor && atOrAfter?.pts == target) || landing <= media.startPTS {
                recent = scanned
                return (earlier, atOrAfter)
            }

            // A keyframe may be indexed by its DTS. When starting there produces only frames at or
            // after the target, seek before that index entry and decode the preceding GOP.
            if let indexed = media.indexedKeyframe(atOrBefore: landing), indexed > media.startPTS {
                landing = min(landing - 1, indexed - 1)
            } else {
                // Some containers lack an index here. Expand the retry window in time, independent of FPS.
                let ticks = max(1, (backoffSeconds / media.timeBase).rounded(.up))
                let retry = Double(landing) - ticks
                landing = Int64(exactly: retry).map { max(media.startPTS, min(landing - 1, $0)) } ?? media.startPTS
                backoffSeconds *= 2
            }
        }
    }

    private func decode(after previous: Int64?, isCancelled: () -> Bool) throws -> DecodedFrame? {
        while true {
            try checkCancellation(isCancelled)
            guard let frame = try decoder.nextFrame() else { return nil }
            guard frame.pts >= media.startPTS else { continue }
            if let previous, frame.pts <= previous { throw SeekError.ambiguousPresentationOrder }
            return frame
        }
    }

    private func present(_ frame: DecodedFrame) -> DecodedFrame {
        currentPTS = frame.pts
        return frame
    }

    private func checkCancellation(_ predicate: () -> Bool) throws {
        if predicate() { throw CancellationError() }
    }

    /// One consecutive run in presentation order, ending at the decoder's current frontier.
    /// The cursor can move within this run without moving the demuxer or decoder.
    private struct FrameWindow {
        // 64 MiB holds 21 frames of the 1080p scrub bench (docs/bench/2026-11-16-provider-scrub.md).
        // Cap small frames by count too, and always keep the two frames needed to bracket a seek.
        private static let maxFrames = 24
        let byteLimit: Int
        private var frames: [DecodedFrame] = []
        private var bytes = 0

        init(byteLimit: Int) { self.byteLimit = byteLimit }

        mutating func clear() {
            frames.removeAll()
            bytes = 0
        }

        mutating func append(_ frame: DecodedFrame) {
            while frames.count > 1,
                  frames.count >= Self.maxFrames || bytes > byteLimit - frame.byteSize {
                bytes -= frames.removeFirst().byteSize
            }
            frames.append(frame)
            bytes += frame.byteSize
        }

        func adjacent(to pts: Int64, offset: Int) -> DecodedFrame? {
            guard let index = frames.firstIndex(where: { $0.pts == pts }),
                  frames.indices.contains(index + offset) else { return nil }
            return frames[index + offset]
        }

        func covering(_ pts: Int64) -> DecodedFrame? {
            guard let first = frames.first, let last = frames.last,
                  first.pts <= pts, pts <= last.pts else { return nil }
            return frames.last { $0.pts <= pts }
        }
    }
}
