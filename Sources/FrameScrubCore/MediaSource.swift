import CFFmpeg
import Foundation

/// A demuxer over one media file. Not thread-safe: every consumer opens its own instance.
public final class MediaSource {
    public let url: URL
    let formatContext: UnsafeMutablePointer<AVFormatContext>
    public let videoStreamIndex: Int32
    public let audioStreamIndex: Int32?
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let rotationClockwise: Int
    /// Width / height of one coded pixel (SAR); 1 when the file does not say.
    public let sampleAspect: Double
    public let timeBase: Double
    public let frameRate: Double
    public let startPTS: Int64
    public let durationSeconds: Double
    /// Codecs and bit rates, for the stats.
    public let format: MediaFormat
    /// The file's shared reads (a private pass-through one when none was given).
    public let readCache: ReadCache
    let input: AVIOReader
    /// The streams' parameters came from the file's first probe (`ReadCache.probe`), not from probing again.
    public let usedSharedProbe: Bool

    /// Opens `url` through `readCache` (`cached: false` reads past its blocks; `noParse` is for index-only demuxing; `readAhead: false` loads no blocks beyond the ones asked for).
    public init(url: URL, readCache: ReadCache? = nil, cached: Bool = true, noParse: Bool = false, readAhead: Bool = true) throws {
        let cache = try readCache ?? ReadCache(url: url, budgetBytes: 0)
        let reader = try AVIOReader(cache: cache, cached: cached, readAhead: readAhead)
        guard let allocated = avformat_alloc_context() else { throw FFmpegError(-1, "allocate demuxer") }
        allocated.pointee.pb = reader.context   // custom I/O: avformat_close_input leaves pb to us
        // No AVFMT_FLAG_NOFILLIN: without it the stream's start_time (the index's zero) would be left unset for
        // fragmented MP4, and probing would read more of the file.
        if noParse { allocated.pointee.flags |= AVFMT_FLAG_NOPARSE }
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        try check(avformat_open_input(&context, url.path, nil, nil), "open \(url.lastPathComponent)")   // frees it on failure
        guard let fc = context else { throw FFmpegError(-1, "open \(url.lastPathComponent)") }
        let video: Int32
        let probe = cache.probe.flatMap { $0.matches(fc) ? $0 : nil }
        do {
            if let probe {
                try probe.apply(to: fc)   // the file's first open probed it: no video frames decoded again
            } else {
                try check(avformat_find_stream_info(fc, nil), "read stream info")
            }
            video = try check(av_find_best_stream(fc, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0), "find video stream")
        } catch {
            avformat_close_input(&context)
            throw error
        }
        let audio = av_find_best_stream(fc, AVMEDIA_TYPE_AUDIO, -1, video, nil, 0)
        let stream = fc.pointee.streams[Int(video)]!
        let parameters = stream.pointee.codecpar.pointee
        let tb = av_q2d(stream.pointee.time_base)
        let averageRate = av_q2d(stream.pointee.avg_frame_rate)
        let realRate = av_q2d(stream.pointee.r_frame_rate)

        self.url = url
        formatContext = fc
        videoStreamIndex = video
        audioStreamIndex = audio >= 0 ? audio : nil
        width = Int(parameters.width)
        height = Int(parameters.height)
        bitDepth = Int(cff_pix_fmt_depth(parameters.format))
        rotationClockwise = Int(cff_stream_rotation_cw(stream))
        let sar = av_guess_sample_aspect_ratio(fc, stream, nil)
        sampleAspect = sar.num > 0 && sar.den > 0 ? av_q2d(sar) : 1
        timeBase = tb
        frameRate = averageRate > 0 ? averageRate : (realRate > 0 ? realRate : 30)
        startPTS = stream.pointee.start_time != cff_nopts() ? stream.pointee.start_time : 0
        if stream.pointee.duration != cff_nopts() {
            durationSeconds = Double(stream.pointee.duration) * tb
        } else {
            durationSeconds = Double(fc.pointee.duration) / Double(AV_TIME_BASE)
        }
        let fileBitRate = fc.pointee.bit_rate > 0 ? fc.pointee.bit_rate
            : durationSeconds > 0 ? Int64(Double(cache.fileSize) * 8 / durationSeconds) : 0
        format = MediaFormat(formatContext: fc, video: video, audio: audioStreamIndex, fileBitRate: fileBitRate)
        self.readCache = cache
        input = reader
        usedSharedProbe = probe != nil
        selectStreams(video: true, audio: false)
    }

    deinit {
        var context: UnsafeMutablePointer<AVFormatContext>? = formatContext
        avformat_close_input(&context)
    }

    var videoStream: UnsafeMutablePointer<AVStream> {
        formatContext.pointee.streams[Int(videoStreamIndex)]!
    }

    var audioStream: UnsafeMutablePointer<AVStream>? {
        audioStreamIndex.map { formatContext.pointee.streams[Int($0)]! }
    }

    /// The file's average data rate: the container's bit rate, else size / duration.
    public var bytesPerSecond: Double {
        let bitRate = formatContext.pointee.bit_rate
        return bitRate > 0 ? Double(bitRate) / 8 : Double(readCache.fileSize) / max(durationSeconds, 1)
    }

    /// Rough size of one decoded frame (NV12 / P010), used before real frames are measured.
    public var estimatedFrameBytes: Int { width * height * 3 / 2 * (bitDepth > 8 ? 2 : 1) }

    /// Makes the demuxer return packets only for the chosen streams.
    public func selectStreams(video: Bool, audio: Bool) {
        for i in 0..<Int(formatContext.pointee.nb_streams) {
            let keep = (video && Int32(i) == videoStreamIndex) || (audio && Int32(i) == audioStreamIndex)
            formatContext.pointee.streams[i]!.pointee.discard = keep ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Reads the next packet of a selected stream; negative FFmpeg code at end of file.
    func read(into packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        av_read_frame(formatContext, packet)
    }

    /// Seeks `stream` to the last keyframe at or before `pts` (that stream's time base).
    func seek(stream: Int32, toPTS pts: Int64) -> Int32 {
        avformat_seek_file(formatContext, stream, Int64.min, pts, pts, 0)
    }

    /// `avformat_seek_file` with explicit bounds (that stream's time base).
    func seekFile(stream: Int32, min: Int64, ts: Int64, max: Int64) -> Int32 {
        avformat_seek_file(formatContext, stream, min, ts, max, 0)
    }

    public func approximateIndex() -> FrameIndex {
        let declared = Int(videoStream.pointee.nb_frames)
        let count = declared > 0 ? declared : Int((durationSeconds * frameRate).rounded())
        return .approximate(startPTS: startPTS, ticksPerFrame: 1 / (frameRate * timeBase),
                            frameCount: max(count, 1), timeBase: timeBase)
    }

    /// Scans every video packet (no decoding) to build an exact index. Call on a fresh source.
    /// While `shouldYield` holds the scan sleeps (spec §2.2: it does not compete with seeks); `progress` gets
    /// the fraction of the file read, rising by at least 1% per call, and 1 at the end.
    public func buildIndex(isCancelled: () -> Bool = { false }, shouldYield: () -> Bool = { false },
                           progress: (Double) -> Void = { _ in }) throws -> FrameIndex {
        try scanPackets(countAll: {}, isCancelled: isCancelled, shouldYield: shouldYield, progress: progress)
    }

    /// Spec §2.1: the exact index from the MP4/MOV sample tables. The header is read for real; then the reader
    /// returns zeros instead of frame data (`AVFMT_FLAG_NOPARSE` keeps parsers from looking at it), so the demuxer
    /// yields every packet's pts and keyframe flag without reading the file. Nil for other containers or when
    /// the checks fail (then the caller scans).
    public static func containerIndex(url: URL, readCache: ReadCache?) throws -> FrameIndex? {
        let source = try MediaSource(url: url, readCache: readCache, noParse: true)
        guard String(cString: source.formatContext.pointee.iformat.pointee.name).hasPrefix("mov,mp4") else { return nil }
        source.input.zeroData = true
        var packets = 0
        let index = try source.scanPackets(countAll: { packets += 1 })
        let declared = Int(source.videoStream.pointee.nb_frames)
        let last = index.frameCount > 0 ? index.seconds(forFrame: index.frameCount - 1) : 0
        guard acceptsContainerIndex(packets: packets, declaredFrames: declared, lastFrameSeconds: last,
                                    durationSeconds: source.durationSeconds) else { return nil }
        return index
    }

    /// Spec §2.1 checks: some packets, as many as the header declares (counting discarded ones), and the last
    /// frame within 1 s of the stream's duration (catches fragments the zero-data demuxer could not see).
    static func acceptsContainerIndex(packets: Int, declaredFrames: Int, lastFrameSeconds: Double,
                                      durationSeconds: Double) -> Bool {
        packets > 0 && (declaredFrames <= 0 || packets == declaredFrames) && abs(durationSeconds - lastFrameSeconds) <= 1
    }

    /// Reads every video packet; `countAll` is called for each one, including those the edit list discards.
    func scanPackets(countAll: () -> Void, isCancelled: () -> Bool = { false }, shouldYield: () -> Bool = { false },
                     progress: (Double) -> Void = { _ in }) throws -> FrameIndex {
        selectStreams(video: true, audio: false)
        guard let packet = av_packet_alloc() else { throw FFmpegError(-1, "allocate packet") }
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        var pts: [Int64] = []
        var keyframes = Set<Int64>()
        var packets = 0
        var reported = 0.0
        let fileSize = Double(max(readCache.fileSize, 1))
        while read(into: packet) >= 0 {
            defer { av_packet_unref(packet) }
            packets += 1
            if packets % 64 == 0 {
                while shouldYield() {
                    Thread.sleep(forTimeInterval: 0.05)
                    if isCancelled() { throw CancellationError() }
                }
                let fraction = min(1, Double(avio_tell(formatContext.pointee.pb)) / fileSize)
                if fraction - reported >= 0.01 {
                    reported = fraction
                    progress(fraction)
                }
            }
            guard packet.pointee.stream_index == videoStreamIndex else { continue }
            countAll()
            guard packet.pointee.flags & AV_PKT_FLAG_DISCARD == 0 else { continue }
            let p = packet.pointee.pts != cff_nopts() ? packet.pointee.pts : packet.pointee.dts
            guard p != cff_nopts() else { continue }
            pts.append(p)
            if packet.pointee.flags & AV_PKT_FLAG_KEY != 0 { keyframes.insert(p) }
            if pts.count % 2000 == 0, isCancelled() { throw CancellationError() }
        }
        progress(1)
        return FrameIndex(pts: pts, keyframePTS: keyframes, timeBase: timeBase, zeroPTS: startPTS)
    }
}

/// A file's stream parameters from its full probe, for its later opens in the same playback session
/// (`ReadCache.probe`). `avformat_find_stream_info` decodes at least 7 video frames of H.264 on one thread to guess the
/// decoder's delay — 0.15 s for 4K — and every reader of a session (decoders, sound, index, preview) opens the file
/// again on its own. A later open skips the probe and takes these. Only for MP4/MOV with sample
/// tables, whose header holds every packet's timing; fragmented files and other containers keep the full probe.
public final class StreamProbe: @unchecked Sendable {
    private struct Stream {
        let parameters: UnsafeMutablePointer<AVCodecParameters>
        let startTime: Int64
        let duration: Int64
        let averageRate: AVRational
        let realRate: AVRational
    }

    private let streams: [Stream]
    private let startTime: Int64
    private let duration: Int64
    private let bitRate: Int64

    public init?(_ source: MediaSource) {
        let fc = source.formatContext.pointee
        guard Self.isMOV(source.formatContext), source.videoStream.pointee.nb_frames > 0 else { return nil }
        var streams: [Stream] = []
        for i in 0..<Int(fc.nb_streams) {
            let stream = fc.streams[i]!.pointee
            guard let copy = avcodec_parameters_alloc() else { break }
            streams.append(Stream(parameters: copy, startTime: stream.start_time, duration: stream.duration,
                                  averageRate: stream.avg_frame_rate, realRate: stream.r_frame_rate))
            guard avcodec_parameters_copy(copy, stream.codecpar) >= 0 else { break }
        }
        self.streams = streams
        startTime = fc.start_time
        duration = fc.duration
        bitRate = fc.bit_rate
        guard streams.count == Int(fc.nb_streams) else { return nil }   // deinit frees what was copied
    }

    deinit {
        for stream in streams {
            var owned: UnsafeMutablePointer<AVCodecParameters>? = stream.parameters
            avcodec_parameters_free(&owned)
        }
    }

    private static func isMOV(_ fc: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        String(cString: fc.pointee.iformat.pointee.name).hasPrefix("mov,mp4")
    }

    /// The same file as probed, header read: the same streams with the same codecs.
    func matches(_ fc: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard Self.isMOV(fc), Int(fc.pointee.nb_streams) == streams.count else { return false }
        return streams.indices.allSatisfy {
            let codecpar = fc.pointee.streams[$0]!.pointee.codecpar.pointee
            return codecpar.codec_type == streams[$0].parameters.pointee.codec_type
                && codecpar.codec_id == streams[$0].parameters.pointee.codec_id
        }
    }

    /// In place of `avformat_find_stream_info`: what the full probe found.
    func apply(to fc: UnsafeMutablePointer<AVFormatContext>) throws {
        for (i, saved) in streams.enumerated() {
            let stream = fc.pointee.streams[i]!
            try check(avcodec_parameters_copy(stream.pointee.codecpar, saved.parameters), "copy stream parameters")
            stream.pointee.start_time = saved.startTime
            stream.pointee.duration = saved.duration
            stream.pointee.avg_frame_rate = saved.averageRate
            stream.pointee.r_frame_rate = saved.realRate
        }
        fc.pointee.start_time = startTime
        fc.pointee.duration = duration
        fc.pointee.bit_rate = bitRate
    }
}
