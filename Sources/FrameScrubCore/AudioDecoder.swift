import AVFoundation
import CFFmpeg

/// Decodes the audio stream into stereo Float32 buffers. Times are seconds on the video
/// timeline (stream time minus `zeroSeconds`). Not thread-safe.
public final class AudioDecoder {
    public let source: MediaSource
    public let format: AVAudioFormat
    public let zeroSeconds: Double
    private let streamIndex: Int32
    private let timeBase: Double
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var resamplerInput = AVChannelLayout()   // what `resampler` expects: a frame differing gets a new one
    private var resamplerFormat = AV_SAMPLE_FMT_NONE
    private var resamplerRate: Int32 = 0
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private static let maxConsecutiveErrors = 100
    private var inputEnded = false
    private var trimBefore: Double?
    private var nextStart = 0.0

    public init(url: URL, zeroSeconds: Double, readCache: ReadCache? = nil) throws {
        source = try MediaSource(url: url, readCache: readCache)
        guard let index = source.audioStreamIndex, let stream = source.audioStream else {
            throw FFmpegError(-1, "no audio stream in \(url.lastPathComponent)")
        }
        streamIndex = index
        self.zeroSeconds = zeroSeconds
        timeBase = av_q2d(stream.pointee.time_base)
        packet = av_packet_alloc()!
        frame = av_frame_alloc()!
        source.selectStreams(video: false, audio: true)

        let parameters = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else { throw FFmpegError(-1, "no audio decoder") }
        codecContext = context
        try check(avcodec_parameters_to_context(context, parameters), "copy audio parameters")
        context.pointee.pkt_timebase = stream.pointee.time_base
        try check(avcodec_open2(context, codec, nil), "open audio decoder")

        format = AVAudioFormat(standardFormatWithSampleRate: Double(context.pointee.sample_rate), channels: 2)!
        try configureResampler(layout: &context.pointee.ch_layout, format: context.pointee.sample_fmt,
                               rate: context.pointee.sample_rate)
    }

    deinit {
        swr_free(&resampler)
        av_channel_layout_uninit(&resamplerInput)
        avcodec_free_context(&codecContext)
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
    }

    public var sampleRate: Double { format.sampleRate }

    /// Stereo Float32 at the stream's first rate from `layout`, `format` and `rate`. Joined recordings change the
    /// layout mid-stream; a resampler kept for the old one reads channel planes the frame does not have (a crash).
    private func configureResampler(layout: UnsafePointer<AVChannelLayout>, format: AVSampleFormat, rate: Int32) throws {
        swr_free(&resampler)
        var stereo = AVChannelLayout()
        av_channel_layout_default(&stereo, 2)
        try check(swr_alloc_set_opts2(&resampler, &stereo, AV_SAMPLE_FMT_FLTP, Int32(sampleRate),
                                      layout, format, rate, 0, nil), "configure resampler")
        try check(swr_init(resampler), "init resampler")
        av_channel_layout_uninit(&resamplerInput)
        try check(av_channel_layout_copy(&resamplerInput, layout), "copy channel layout")
        resamplerFormat = format
        resamplerRate = rate
    }

    public func seek(toSeconds seconds: Double) throws {
        // Seek slightly early: codecs like AAC drop the first output frame after a flush (priming),
        // so the requested time must be reached by decoding forward and trimming.
        let preroll = 0.1
        let pts = Int64(((seconds + zeroSeconds - preroll) / timeBase).rounded(.down))
        try check(source.seek(stream: streamIndex, toPTS: pts), "seek audio")
        avcodec_flush_buffers(codecContext)
        swr_close(resampler)
        try check(swr_init(resampler), "reset resampler")
        inputEnded = false
        trimBefore = seconds
        nextStart = seconds
    }

    public func nextBuffer() throws -> (buffer: AVAudioPCMBuffer, startSeconds: Double)? {
        while try receiveFrame() {
            defer { av_frame_unref(frame) }
            let timestamp = frame.pointee.best_effort_timestamp
            var start = timestamp != cff_nopts() ? Double(timestamp) * timeBase - zeroSeconds : nextStart
            guard var buffer = convertFrame() else { continue }
            if let trim = trimBefore {
                let skip = Int(((trim - start) * sampleRate).rounded())
                if skip >= Int(buffer.frameLength) { continue }
                if skip > 0 {
                    buffer = buffer.droppingFirst(skip)
                    start = trim
                }
                trimBefore = nil
            }
            nextStart = start + Double(buffer.frameLength) / sampleRate
            return (buffer, start)
        }
        return nil
    }

    private func receiveFrame() throws -> Bool {
        guard let context = codecContext else { return false }
        var errors = 0   // consecutive decode errors; give up after a bounded number
        while true {
            let result = avcodec_receive_frame(context, frame)
            if result == 0 { return true }
            if result == cff_error_eof() || (result == cff_error_eagain() && inputEnded) { return false }
            if result != cff_error_eagain() {
                errors += 1   // corrupt frame: read more input instead of retrying receive
                if errors > Self.maxConsecutiveErrors { return false }
            }
            if source.read(into: packet) < 0 {
                avcodec_send_packet(context, nil)
                inputEnded = true
                continue
            }
            if packet.pointee.stream_index == streamIndex {
                let sent = avcodec_send_packet(context, packet)
                if sent < 0 && sent != cff_error_eagain() {
                    errors += 1
                    if errors > Self.maxConsecutiveErrors { av_packet_unref(packet); return false }
                } else if sent >= 0 && result == cff_error_eagain() {
                    errors = 0
                }
            }
            av_packet_unref(packet)
        }
    }

    private func convertFrame() -> AVAudioPCMBuffer? {
        let frameFormat = AVSampleFormat(frame.pointee.format)
        if av_channel_layout_compare(&resamplerInput, &frame.pointee.ch_layout) != 0 || frameFormat != resamplerFormat
            || frame.pointee.sample_rate != resamplerRate {
            do {
                try configureResampler(layout: &frame.pointee.ch_layout, format: frameFormat,
                                       rate: frame.pointee.sample_rate)
            } catch {
                return nil
            }
        }
        let capacity = swr_get_out_samples(resampler, frame.pointee.nb_samples)
        guard capacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
              let channels = buffer.floatChannelData else { return nil }
        let produced = cff_swr_convert_frame(resampler, channels[0], channels[1], capacity, frame)
        guard produced > 0 else { return nil }
        buffer.frameLength = AVAudioFrameCount(produced)
        return buffer
    }
}

extension AVAudioPCMBuffer {
    func droppingFirst(_ count: Int) -> AVAudioPCMBuffer {
        let remaining = Int(frameLength) - count
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining))!
        result.frameLength = AVAudioFrameCount(remaining)
        for channel in 0..<Int(format.channelCount) {
            result.floatChannelData![channel].update(from: floatChannelData![channel] + count, count: remaining)
        }
        return result
    }
}
