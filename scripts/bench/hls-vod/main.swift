import CFFmpeg
import Foundation

private struct ProbeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// One producer follows the decoded frontier. The playhead reads the same cache during playback and scrubbing.
private final class Probe: @unchecked Sendable {
    private let cache = FrameCache(budgetBytes: 64 << 20)
    private let condition = NSCondition()
    private let worker = DispatchGroup()
    private var position = 0
    private var last = -1
    private var lookahead = 0
    private var rate = 0.0
    private var finished = false
    private var cancelled = false
    private var failure: Error?

    init(url: URL) {
        worker.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.worker.leave() }
            do {
                try self.decode(url)
                self.finish(nil)
            } catch {
                self.finish(error)
            }
        }
    }

    func stop() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
        worker.wait()
    }

    private var isCancelled: Bool { condition.withLock { cancelled } }

    private func finish(_ error: Error?) {
        condition.withLock {
            failure = error
            finished = true
            condition.broadcast()
        }
    }

    private func decode(_ url: URL) throws {
        var input = avformat_alloc_context()
        guard let context = input else { throw ProbeError("Cannot allocate HLS demuxer") }
        context.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<Probe>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
        }, opaque: Unmanaged.passUnretained(self).toOpaque())
        var options: OpaquePointer?
        defer {
            av_dict_free(&options)
            avformat_close_input(&input)
        }
        av_dict_set(&options, "protocol_whitelist", "http,https,tcp,tls", 0)
        av_dict_set(&options, "tls_verify", "1", 0)
        av_dict_set(&options, "rw_timeout", "5000000", 0)
        av_dict_set(&options, "http_multiple", "0", 0)
        guard let hls = av_find_input_format("hls") else { throw ProbeError("HLS demuxer unavailable") }
        try check(avformat_open_input(&input, url.absoluteString, hls, &options), "open HLS")
        try check(avformat_find_stream_info(context, nil), "probe streams")
        guard context.pointee.duration > 0 else { throw ProbeError("A finished HLS VOD is required") }
        let streamID = try check(av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0), "select video")
        let stream = context.pointee.streams[Int(streamID)]!
        for i in 0..<Int(context.pointee.nb_streams) where i != Int(streamID) {
            context.pointee.streams[i]!.pointee.discard = AVDISCARD_ALL
        }
        let preferredRate = av_q2d(stream.pointee.avg_frame_rate)
        let fps = preferredRate.isFinite && preferredRate > 0 ? preferredRate : av_q2d(stream.pointee.r_frame_rate)
        guard fps.isFinite, fps > 0 else { throw ProbeError("A nominal frame rate is required") }

        let backend: DecoderBackend
        if VTBackend.supports(stream), let vt = try? VTBackend(stream: stream) {
            backend = vt
        } else {
            backend = try FFmpegBackend(stream: stream, hardware: true, softwareThreads: 1)
        }
        guard let packet = av_packet_alloc() else { throw ProbeError("Cannot allocate packet") }
        defer {
            var allocated: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&allocated)
        }
        print("decode=\(backend.kind.rawValue) fps=\(fps)")
        var previousPTS: Int64?
        var eof = false
        var number = 0
        while awaitDemand() {
            switch try backend.receive() {
            case .ended:
                return
            case .needsInput:
                if eof { throw ProbeError("Decoder requested data after drain") }
                let result = av_read_frame(context, packet)
                defer { av_packet_unref(packet) }
                if isCancelled { return }
                if result == cff_error_eof() {
                    eof = true
                    try backend.drain()
                } else {
                    try check(result, "read HLS packet")
                    if packet.pointee.stream_index == streamID {
                        guard packet.pointee.flags & AV_PKT_FLAG_CORRUPT == 0 else {
                            throw ProbeError("HLS returned a corrupt video packet")
                        }
                        try backend.send(packet, output: true, mayDrop: false)
                    }
                }
            case .frame(let decoded):
                guard decoded.pts != cff_nopts(), previousPTS.map({ $0 < decoded.pts }) ?? true else {
                    throw ProbeError("Probe requires strictly increasing presentation timestamps")
                }
                previousPTS = decoded.pts
                let frame = DecodedFrame(number: number, pts: decoded.pts, pixelBuffer: decoded.pixelBuffer,
                                         dynamicRange: decoded.dynamicRange, pictureType: decoded.pictureType)
                let limit = min(16, (cache.budgetBytes / max(1, frame.byteSize) - 1) / 2)
                guard limit >= 3 else { throw ProbeError("Frame is too large for the probe cache budget") }
                cache.insert(frame)
                condition.withLock {
                    last = number
                    lookahead = limit
                    rate = fps
                    condition.broadcast()
                }
                number += 1
            }
        }
    }

    private func awaitDemand() -> Bool {
        condition.withLock {
            while !cancelled, last >= 0, last - position >= lookahead {
                condition.wait()
            }
            return !cancelled
        }
    }

    func warm() throws -> Double {
        try condition.withLock {
            let deadline = Date().addingTimeInterval(12)
            while !finished, last < min(12, max(3, lookahead)) {
                guard condition.wait(until: deadline) else { throw ProbeError("Timed out during warmup") }
            }
            if let failure { throw failure }
            guard last >= 3 else { throw ProbeError("VOD ended during warmup") }
            return rate
        }
    }

    func move(to target: Int) -> Bool {
        cache.setFocus(target, backShare: 0.5)
        condition.withLock {
            position = target
            condition.signal()
        }
        return cache.frame(target) != nil
    }

    func checkProducer(waitForLookahead: Bool = false) throws {
        try condition.withLock {
            if waitForLookahead {
                let deadline = Date().addingTimeInterval(5)
                while !finished, last - position < lookahead {
                    guard condition.wait(until: deadline) else { throw ProbeError("Timed out filling final lookahead") }
                }
            }
            if let failure { throw failure }
        }
    }

    var usedMiB: Double { Double(cache.usedBytes) / Double(1 << 20) }
    var readyAhead: Int {
        let window = condition.withLock { (position, max(position, last)) }
        return (window.0..<window.1).prefix { cache.hasReadyFrame($0 + 1) }.count
    }
}

private func run() throws {
    av_log_set_level(AV_LOG_WARNING)
    let args = CommandLine.arguments
    guard (2...3).contains(args.count), let url = URL(string: args[1]),
          ["http", "https"].contains(url.scheme), url.host != nil else {
        throw ProbeError("Usage: run.sh HLS_URL [frames]")
    }
    guard let frameCount = args.count == 3 ? Int(args[2]) : 90, (24...3_600).contains(frameCount) else {
        throw ProbeError("Choose between 24 and 3600 frames")
    }
    let clock = ContinuousClock()
    let started = clock.now
    let probe = Probe(url: url)
    defer { probe.stop() }
    let fps = try probe.warm()
    let warmed = started.duration(to: clock.now)
    let startOfPlayback = clock.now
    var playbackMisses = 0
    var scrubMisses = 0
    var scrubSamples = 0
    var minimumAhead = Int.max
    var maxScrub = Duration.zero
    for position in 0..<frameCount {
        let delay = clock.now.duration(to: startOfPlayback.advanced(by: .seconds(Double(position) / fps)))
        if delay > .zero { Thread.sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18) }
        try probe.checkProducer()
        if !probe.move(to: position) { playbackMisses += 1 }
        if position.isMultiple(of: 12), position >= 12 {
            minimumAhead = min(minimumAhead, probe.readyAhead)
            for target in [position - 2, position - 1, position, position + 1, position + 2, position] {
                let before = clock.now
                if !probe.move(to: target) { scrubMisses += 1 }
                maxScrub = max(maxScrub, before.duration(to: clock.now))
                scrubSamples += 1
            }
        }
    }
    try probe.checkProducer(waitForLookahead: true)
    print("warmup=\(warmed) play_misses=\(playbackMisses)/\(frameCount) scrub_misses=\(scrubMisses)/\(scrubSamples)")
    print("max_cache_scrub=\(maxScrub) min_sampled_ahead=\(minimumAhead) cache_MiB=\(probe.usedMiB)")
    guard playbackMisses == 0, scrubMisses == 0 else { throw ProbeError("Frame cache missed a playback or scrub request") }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
