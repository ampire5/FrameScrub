import CFFmpeg
import CoreVideo
import Foundation
import VideoToolbox

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

    private let softwareThreads: Int32
    private var seekPackets: Int?
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

    /// The owner registers only while waiting, when retaining a surplus pool is avoidable.
    func watchPoolSurplus(over limit: Int, notify: @escaping @Sendable () -> Void) -> Bool {
        isHardware && outputs.watchSurplus(over: limit, notify: notify)
    }

    func stopWatchingPoolSurplus() { outputs.stopWatchingSurplus() }

    private static let backoffFrames = [1, 32, 128, 512]

    public convenience init(source: MediaSource, index: FrameIndex, preferHardware: Bool = true, prefersPackedOutput: Bool = false) throws {
        try self.init(source: source, index: index, preferHardware: preferHardware, allowVideoToolboxBackend: true,
                      prefersPackedOutput: prefersPackedOutput)
    }

    /// `allowVideoToolboxBackend: false` keeps H.264/HEVC on FFmpeg (tests, measurements).
    init(source: MediaSource, index: FrameIndex, preferHardware: Bool, allowVideoToolboxBackend: Bool,
         softwareThreads: Int32 = 0, prefersPackedOutput: Bool = false) throws {
        self.source = source
        self.index = index
        self.softwareThreads = softwareThreads
        source.selectStreams(video: true, audio: false)
        backend = try Self.makeBackend(source.videoStream, preferHardware: preferHardware,
                                       allowVideoToolbox: allowVideoToolboxBackend, softwareThreads: softwareThreads,
                                       prefersPackedOutput: prefersPackedOutput)
        packet = av_packet_alloc()!
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
    }

    private static func makeBackend(_ stream: UnsafeMutablePointer<AVStream>, preferHardware: Bool,
                                    allowVideoToolbox: Bool, softwareThreads: Int32, prefersPackedOutput: Bool) throws -> DecoderBackend {
        if preferHardware && allowVideoToolbox && VTBackend.supports(stream) {
            // FFmpeg's hwaccel would ask the same hardware: a session VideoToolbox refuses means software.
            if let backend = try? VTBackend(stream: stream, prefersPackedOutput: prefersPackedOutput) { return backend }
            return try FFmpegBackend(stream: stream, hardware: false, softwareThreads: softwareThreads)
        }
        return try FFmpegBackend(stream: stream, hardware: preferHardware, softwareThreads: softwareThreads)
    }

    // MARK: Public

    public func seek(toFrame target: Int) throws {
        let clamped = min(max(target, 0), max(index.frameCount - 1, 0))
        seekTarget = clamped
        seekAttempts = 0
        if source.isHLS, clamped == 0, framesSinceOpen == 0, !inputEnded, lastFrameNumber == nil { return }
        try seekDemuxer(toFrame: index.keyframe(atOrBefore: clamped))
    }

    /// For thumbnails: repositions at the keyframe at or before `target` and keeps the first decoded frame
    /// (a keyframe) instead of decoding on up to `target`.
    public func seekToKeyframe(near target: Int) throws {
        seekTarget = nil
        seekAttempts = 0
        try seekDemuxer(toFrame: min(max(target, 0), max(index.frameCount - 1, 0)))
    }

    /// HLS selects segments on the decode timeline. A backward seek one frame
    /// before a keyframe's presentation time can still land on that keyframe.
    func previousHLSKeyframe(before frame: Int) throws -> DecodedFrame? {
        for offset in [2, 4, 8, 16, 32, 128, 512] where frame > 0 {
            let target = max(0, frame - offset)
            try seekToKeyframe(near: target)
            if let decoded = try nextFrame(), decoded.number < frame { return decoded }
            if target == 0 { break }
        }
        return nil
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

    public var diagnosticRole = "other"
    var reportsHTTPReadFailures = false

    public func nextFrame() throws -> DecodedFrame? {
        try nextFrame(keepingPrerollFrom: nil) { _ in }
    }

    /// For `continuingTo`, the owner must have decoded an earlier picture in the same GOP with
    /// this decoder and index. A cursor that ends or passes the target gets one ordinary seek.
    func nextFrame(keepingPrerollFrom start: Int?, previewPreroll: ClosedRange<Int>? = nil, continuingTo: Int? = nil,
                   isObsolete: (() -> Bool)? = nil,
                   onPreroll: (DecodedFrame) -> Void) throws -> DecodedFrame? {
        var retryFromKeyframe = continuingTo
        if let continuingTo {
            seekTarget = continuingTo
            seekAttempts = 0
        }
        let diagnosticStart = PlaybackDiagnostics.enabled ? PlaybackDiagnostics.now() : 0
        if diagnosticStart > 0, seekTarget != nil { seekPackets = 0 }
        defer {
            if let count = seekPackets {
                PlaybackDiagnostics.shared.record("seek_video_packets", Double(count),
                                                  group: "decoder.\(diagnosticRole).\(isHardware ? "hardware" : "software")")
                seekPackets = nil
            }
        }
        while true {
            // A pool per frame: a seek's pre-roll can decode a whole GOP in this loop, and anything left autoreleased
            // with a frame keeps its IOSurface (VTDecoderXPCService memory) until the caller's pool drains.
            let picture = try autoreleasepool {
                try receiveFrame(keepingPrerollFrom: start, previewPreroll: previewPreroll, isObsolete: isObsolete)
            }
            if let target = retryFromKeyframe, picture.map({ $0.number > target }) ?? true {
                if isObsolete?() == true { throw CancellationError() }
                retryFromKeyframe = nil
                try seek(toFrame: target)
                continue
            }
            guard let decoded = picture else { return nil }
            if let target = seekTarget {
                // Past the target is a bad seek, unless the target was among the frames asked to be skipped.
                let targetSkipped = skipBefore.map { target < $0 } ?? false
                if decoded.number > target && !targetSkipped && lastSeekFrame > 0 && seekAttempts < Self.backoffFrames.count {
                    let backoff = Self.backoffFrames[seekAttempts]
                    seekAttempts += 1
                    try seekDemuxer(toFrame: index.keyframe(atOrBefore: max(0, lastSeekFrame - backoff)))
                    continue
                }
                if decoded.number < target {
                    if start.map({ decoded.number >= $0 }) == true || previewPreroll?.contains(decoded.number) == true {
                        onPreroll(decoded)
                    }
                    continue
                }
                seekTarget = nil
            }
            lastFrameNumber = decoded.number
            if PlaybackDiagnostics.enabled {
                PlaybackDiagnostics.shared.record("next_frame_work_ms", (PlaybackDiagnostics.now() - diagnosticStart) * 1000,
                                                   group: "decoder.\(diagnosticRole).\(isHardware ? "hardware" : "software")")
            }
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

    private func receiveFrame(keepingPrerollFrom start: Int?, previewPreroll: ClosedRange<Int>?,
                              isObsolete: (() -> Bool)?) throws -> DecodedFrame? {
        while true {
            if isObsolete?() == true { throw CancellationError() }
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
                try feedPacket(keepingPrerollFrom: start, previewPreroll: previewPreroll, isObsolete: isObsolete)
            }
        }
    }

    private func feedPacket(keepingPrerollFrom start: Int?, previewPreroll: ClosedRange<Int>?,
                            isObsolete: (() -> Bool)?) throws {
        while true {
            let result = source.read(into: packet)
            defer { av_packet_unref(packet) }
            if isObsolete?() == true { throw CancellationError() }
            if result < 0 {
                if source.isHLS, result != cff_error_eof() { try check(result, "read HLS video") }
                if !source.isHLS, reportsHTTPReadFailures {
                    let status = source.byteReadError ?? result
                    if status != cff_error_eof() { try check(status, "read HTTP video") }
                }
                try backend.drain()   // the delayed frames come out
                inputEnded = true
                return
            }
            guard packet.pointee.stream_index == source.videoStreamIndex else { continue }
            seekPackets? += 1
            do {
                let pts = packet.pointee.pts
                let discardBefore = seekTarget.map { target in min(start ?? target, target) }
                var preRoll = false
                var preview = false
                if let discardBefore, pts != cff_nopts() {
                    let number = index.frameNumber(forPTS: pts)
                    preRoll = number < discardBefore
                    preview = previewPreroll?.contains(number) == true
                }
                try backend.send(packet, output: !preRoll || preview,
                                 mayDrop: !preview && skipsBeforeTarget(pts, seekLimit: discardBefore))
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
    private func skipsBeforeTarget(_ pts: Int64, seekLimit: Int?) -> Bool {
        guard pts != cff_nopts(), let limit = [seekLimit, skipBefore].compactMap({ $0 }).max() else { return false }
        return pts < index.pts(forFrame: limit)
    }

    /// Corrupt data is skipped. A hardware decoder that fails before producing any frame, or
    /// fails repeatedly, is replaced by a software decoder resuming at the same position.
    private func handleDecodeError(_ code: Int32) throws {
        consecutiveErrors += 1
        if (backend as? VTBackend)?.usingPackedOutput == true,
           (code == kVTParameterErr || lastFrameNumber == nil || consecutiveErrors >= 3),
           let ordinary = try? VTBackend(stream: source.videoStream) {
            try replaceBackend(with: ordinary)
            return
        }
        if isHardware && (framesSinceOpen == 0 || consecutiveErrors >= 3) {
            try replaceBackend(with: FFmpegBackend(stream: source.videoStream, hardware: false, softwareThreads: softwareThreads))
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
            try replaceBackend(with: FFmpegBackend(stream: source.videoStream, hardware: false, softwareThreads: softwareThreads))
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
    private var surplusWatch: (limit: Int, notify: @Sendable () -> Void)?

    var surplus: Int { lock.withLock { peak - alive } }

    /// The buffer carries a token until it is freed; a buffer given out again gets a new one, freeing the old first.
    func track(_ buffer: CVBuffer) {
        CVBufferSetAttachment(buffer, Self.key, Token(self), .shouldNotPropagate)
        lock.withLock {
            alive += 1
            peak = max(peak, alive)
        }
    }

    /// True if the owner can release its pool now. Otherwise arm a one-shot notification.
    func watchSurplus(over limit: Int, notify: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            if peak - alive > limit { return true }
            surplusWatch = (limit, notify)
            return false
        }
    }

    func stopWatchingSurplus() { lock.withLock { surplusWatch = nil } }

    private func released() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            alive -= 1
            guard let watch = surplusWatch, peak - alive > watch.limit else { return nil }
            surplusWatch = nil
            return watch.notify
        }
        // A pixel buffer can be released while the filler or cache is locked.
        if let notify { DispatchQueue.global(qos: .utility).async(execute: notify) }
    }

    private static var key: CFString { "FrameScrubOutputToken" as CFString }

    private final class Token {
        let tracker: OutputTracker
        init(_ tracker: OutputTracker) { self.tracker = tracker }
        deinit { tracker.released() }
    }
}
