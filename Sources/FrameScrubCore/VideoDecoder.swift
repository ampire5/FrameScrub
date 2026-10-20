import CFFmpeg
import CoreVideo
import Foundation

/// Decodes the video stream of its own MediaSource into DecodedFrames in presentation order.
/// Not thread-safe: owned by exactly one worker.
///
/// Seeking is exact: after `seek(toFrame:)` the next `nextFrame()` returns that frame. If the
/// demuxer lands past the target (dts-based seeking, open-GOP leading pictures that cannot be
/// decoded from the keyframe), it backs off to earlier keyframes and tries again.
public final class VideoDecoder {
    public let source: MediaSource
    public var index: FrameIndex
    var backend: DecoderBackend
    public var backendKind: DecoderBackendKind { backend.kind }
    public var isHardware: Bool { backendKind.isHardware }
    public var codecName: String { backend.codecName }

    private let packet: UnsafeMutablePointer<AVPacket>
    private var inputEnded = false
    private var seekTarget: Int?
    private var lastSeekFrame = 0
    private var seekAttempts = 0
    private var lastFrameNumber: Int?
    private var consecutiveErrors = 0
    private var recreatedSession = false
    /// Frames the current backend has decoded, including pre-roll it did not output.
    var framesSinceOpen: Int { backend.decodedCount }
    /// Frames before this one are only decoded if others refer to them (`skipNonReference(before:)`).
    private var skipBefore: Int?
    private var outputs = OutputTracker()

    /// Frames a hardware decoder has given out and that are gone now: its VideoToolbox session's output pool keeps
    /// as many buffers as were ever out at once, in VTDecoderXPCService, until the session goes (flushing the pool
    /// does not free them). 0 for a software decoder, whose pool ages out in this process.
    public var poolSurplus: Int { isHardware ? outputs.surplus : 0 }

    private static let backoffFrames = [1, 32, 128, 512]

    public convenience init(source: MediaSource, index: FrameIndex, preferHardware: Bool = true) throws {
        try self.init(source: source, index: index, preferHardware: preferHardware, allowVideoToolboxBackend: true)
    }

    /// `allowVideoToolboxBackend: false` keeps H.264/HEVC on FFmpeg (tests, measurements).
    init(source: MediaSource, index: FrameIndex, preferHardware: Bool, allowVideoToolboxBackend: Bool) throws {
        self.source = source
        self.index = index
        source.selectStreams(video: true, audio: false)
        backend = try Self.makeBackend(source.videoStream, preferHardware: preferHardware,
                                       allowVideoToolbox: allowVideoToolboxBackend)
        packet = av_packet_alloc()!
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
    }

    private static func makeBackend(_ stream: UnsafeMutablePointer<AVStream>, preferHardware: Bool,
                                    allowVideoToolbox: Bool) throws -> DecoderBackend {
        if preferHardware && allowVideoToolbox && VTBackend.supports(stream) {
            // FFmpeg's hwaccel would ask the same hardware: a session VideoToolbox refuses means software.
            if let backend = try? VTBackend(stream: stream) { return backend }
            return try FFmpegBackend(stream: stream, hardware: false)
        }
        return try FFmpegBackend(stream: stream, hardware: preferHardware)
    }

    // MARK: Public

    public func seek(toFrame target: Int) throws {
        let clamped = min(max(target, 0), max(index.frameCount - 1, 0))
        seekTarget = clamped
        seekAttempts = 0
        try seekDemuxer(toFrame: index.keyframe(atOrBefore: clamped))
    }

    /// For thumbnails: repositions at the keyframe at or before `target` and keeps the first decoded frame
    /// (a keyframe) instead of decoding on up to `target`.
    public func seekToKeyframe(near target: Int) throws {
        seekTarget = nil
        seekAttempts = 0
        try seekDemuxer(toFrame: min(max(target, 0), max(index.frameCount - 1, 0)))
    }

    /// Spec §2.3: positions on a keyframe strictly after (`direction` > 0) or before (< 0) `current`, preferring
    /// the one near `target`; the next `nextFrame()` returns it. With no keyframe that way: the last/first frame.
    /// Works with an approximate index: the demuxer knows where the keyframes are.
    public func seekToKeyframe(toward target: Int, from current: Int, direction: Int) throws {
        try seekToKeyframe(towardPTS: index.pts(forFrame: target), fromPTS: index.pts(forFrame: current), direction: direction)
    }

    /// `seekToKeyframe(toward:from:direction:)` by time: for callers that know a keyframe's real pts, which an
    /// approximate index only estimates (the estimate can lie a tick or more off).
    func seekToKeyframe(towardPTS target: Int64, fromPTS now: Int64, direction: Int) throws {
        let minTS = direction > 0 ? now + 1 : Int64.min
        let maxTS = direction < 0 ? now - 1 : Int64.max
        let ts = min(max(target, minTS), maxTS)
        seekTarget = nil
        seekAttempts = 0
        guard source.seekFile(stream: source.videoStreamIndex, min: minTS, ts: ts, max: maxTS) >= 0 else {
            try seek(toFrame: direction > 0 ? index.frameCount - 1 : 0)
            return
        }
        backend.flush()
        inputEnded = false
        lastFrameNumber = nil
    }

    /// Repositions at the keyframe at or before `pts`; the next `nextFrame()` is the first frame decoded there.
    func seekToKeyframe(atOrBeforePTS pts: Int64) throws {
        seekTarget = nil
        seekAttempts = 0
        lastSeekFrame = index.frameNumber(forPTS: pts)
        try check(source.seek(stream: source.videoStreamIndex, toPTS: pts), "seek")
        backend.flush()
        inputEnded = false
        lastFrameNumber = nil
    }

    /// The caller no longer wants frames before `frame` (its focus has moved past them): until it says otherwise,
    /// non-reference frames before it are skipped. nil decodes everything again.
    public func skipNonReference(before frame: Int?) {
        skipBefore = frame
    }

    public func nextFrame() throws -> DecodedFrame? {
        while true {
            // A pool per frame: a seek's pre-roll can decode a whole GOP in this loop, and anything left autoreleased
            // with a frame keeps its IOSurface (VTDecoderXPCService memory) until the caller's pool drains.
            guard let decoded = try autoreleasepool(invoking: { try receiveFrame() }) else { return nil }
            if let target = seekTarget {
                // Past the target is a bad seek, unless the target was among the frames asked to be skipped.
                let targetSkipped = skipBefore.map { target < $0 } ?? false
                if decoded.number > target && !targetSkipped && lastSeekFrame > 0 && seekAttempts < Self.backoffFrames.count {
                    let backoff = Self.backoffFrames[seekAttempts]
                    seekAttempts += 1
                    try seekDemuxer(toFrame: index.keyframe(atOrBefore: max(0, lastSeekFrame - backoff)))
                    continue
                }
                if decoded.number < target { continue }   // pre-roll from the keyframe
                seekTarget = nil
            }
            lastFrameNumber = decoded.number
            return decoded
        }
    }

    // MARK: Decoding

    private func seekDemuxer(toFrame n: Int) throws {
        lastSeekFrame = n
        try check(source.seek(stream: source.videoStreamIndex, toPTS: index.pts(forFrame: n)), "seek")
        backend.flush()
        inputEnded = false
        lastFrameNumber = nil
    }

    private func receiveFrame() throws -> DecodedFrame? {
        while true {
            let result: BackendResult
            do { result = try backend.receive() } catch BackendError.corruptFrame(let code) {
                try handleDecodeError(code)
                continue
            } catch BackendError.sessionLost {
                try handleSessionLost()
                continue
            }
            switch result {
            case .frame(let frame):
                consecutiveErrors = 0
                return makeDecodedFrame(frame)
            case .ended:
                return nil
            case .needsInput:
                if inputEnded { return nil }
                try feedPacket()
            }
        }
    }

    private func feedPacket() throws {
        while true {
            if source.read(into: packet) < 0 {
                try backend.drain()   // the delayed frames come out
                inputEnded = true
                return
            }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == source.videoStreamIndex else { continue }
            do {
                let pts = packet.pointee.pts
                let preRoll = seekTarget.map { pts != cff_nopts() && index.frameNumber(forPTS: pts) < $0 } ?? false
                try backend.send(packet, output: !preRoll, mayDrop: skipsBeforeTarget(pts))
            } catch BackendError.corruptFrame(let code) {
                try handleDecodeError(code)
                continue
            } catch BackendError.sessionLost {
                try handleSessionLost()
                return
            }
            return
        }
    }

    /// The pre-roll from a keyframe up to the seek target is thrown away, and so are frames a caller catching up
    /// has been passed by; of those, only frames others refer to must be decoded. Skipping the rest roughly halves
    /// the work with B-frames (long GOPs over a NAS, fast scrubbing).
    private func skipsBeforeTarget(_ pts: Int64) -> Bool {
        guard pts != cff_nopts(), let limit = [seekTarget, skipBefore].compactMap({ $0 }).max() else { return false }
        return pts < index.pts(forFrame: limit)
    }

    /// Corrupt data is skipped. A hardware decoder that fails before producing any frame, or
    /// fails repeatedly, is replaced by a software decoder resuming at the same position.
    private func handleDecodeError(_ code: Int32) throws {
        consecutiveErrors += 1
        if isHardware && (framesSinceOpen == 0 || consecutiveErrors >= 3) {
            try replaceBackend(with: FFmpegBackend(stream: source.videoStream, hardware: false))
            return
        }
        if consecutiveErrors > 100 { throw FFmpegError(code, "decode") }
    }

    /// A lost VideoToolbox session (sleep, GPU change) is recreated once; when that one is lost too, or cannot be
    /// created, software decoding takes over.
    private func handleSessionLost() throws {
        if !recreatedSession, let fresh = try? VTBackend(stream: source.videoStream) {
            recreatedSession = true
            try replaceBackend(with: fresh)
        } else {
            try replaceBackend(with: FFmpegBackend(stream: source.videoStream, hardware: false))
        }
    }

    /// Continues with `newBackend` at the frame the caller expects next.
    private func replaceBackend(with newBackend: DecoderBackend) throws {
        let resume = seekTarget ?? lastFrameNumber.map { $0 + 1 } ?? 0
        backend = newBackend
        outputs = OutputTracker()
        consecutiveErrors = 0
        inputEnded = false
        try seek(toFrame: resume)
    }

    private func makeDecodedFrame(_ frame: BackendFrame) -> DecodedFrame {
        let timestamp = frame.pts != cff_nopts() ? frame.pts : index.pts(forFrame: (lastFrameNumber ?? -1) + 1)
        if isHardware { outputs.track(frame.pixelBuffer) }
        return DecodedFrame(number: index.frameNumber(forPTS: timestamp), pts: timestamp,
                            pixelBuffer: frame.pixelBuffer, dynamicRange: frame.dynamicRange,
                            pictureType: frame.pictureType)
    }
}

/// Counts the buffers a decoder gave out that are still alive, and the most that were alive at once.
private final class OutputTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = 0
    private var peak = 0

    var surplus: Int { lock.withLock { peak - alive } }

    /// The buffer carries a token until it is freed; a buffer given out again gets a new one, freeing the old first.
    func track(_ buffer: CVBuffer) {
        CVBufferSetAttachment(buffer, Self.key, Token(self), .shouldNotPropagate)
        lock.withLock {
            alive += 1
            peak = max(peak, alive)
        }
    }

    private func released() { lock.withLock { alive -= 1 } }

    private static let key = "FrameScrubOutputToken" as CFString

    private final class Token {
        let tracker: OutputTracker
        init(_ tracker: OutputTracker) { self.tracker = tracker }
        deinit { tracker.released() }
    }
}
