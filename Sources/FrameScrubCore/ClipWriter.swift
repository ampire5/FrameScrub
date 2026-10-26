import CFFmpeg
import Foundation

/// One stretch of a clip: the packets from the keyframe at or before `startPTS` to frame `endPTS` (video stream time
/// base).
public struct ClipRange: Sendable, Equatable {
    public let startPTS: Int64
    public let endPTS: Int64
    /// pts of the keyframe at or before the start when the index is exact; nil = seek back from the start.
    public let keyframePTS: Int64?

    public init(startPTS: Int64, endPTS: Int64, keyframePTS: Int64?) {
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.keyframePTS = keyframePTS
    }
}

/// One clip to save (A-B clip spec §3): its ranges written one after another into one file (cut marks spec §7).
public struct ClipJob: Sendable, Equatable {
    public let id: UUID
    public let source: URL
    /// What the clip is named after (`%{video-name}`): a page's scene for a stream (`SceneInfo.namingURL`); nil: `source`.
    public let nameSource: URL?
    public let ranges: [ClipRange]
    /// The frame-dir for this video.
    public let directory: URL
    public let fallbackDirectory: URL
    /// clip-template.
    public let template: String
    /// The first range's start frame and seconds, for `%{frame}` / `%{time}` and the lead-in.
    public let aFrame: Int
    public let aSeconds: Double
    /// The last range's end seconds, for `%{end}`.
    public let endSeconds: Double
    /// Read limit in bytes/s, 0 = none.
    public let readLimit: Int

    public init(id: UUID = UUID(), source: URL, nameSource: URL? = nil, ranges: [ClipRange], directory: URL,
                fallbackDirectory: URL, template: String, aFrame: Int, aSeconds: Double, endSeconds: Double, readLimit: Int) {
        precondition(!ranges.isEmpty, "a clip needs a range")
        self.id = id
        self.source = source
        self.nameSource = nameSource
        self.ranges = ranges
        self.directory = directory
        self.fallbackDirectory = fallbackDirectory
        self.template = template
        self.aFrame = aFrame
        self.aSeconds = aSeconds
        self.endSeconds = endSeconds
        self.readLimit = readLimit
    }

    /// A single-range clip (A-B).
    public init(id: UUID = UUID(), source: URL, startPTS: Int64, endPTS: Int64, keyframePTS: Int64?, directory: URL,
                fallbackDirectory: URL, template: String, aFrame: Int, aSeconds: Double, endSeconds: Double,
                readLimit: Int) {
        self.init(id: id, source: source, ranges: [ClipRange(startPTS: startPTS, endPTS: endPTS, keyframePTS: keyframePTS)],
                  directory: directory, fallbackDirectory: fallbackDirectory, template: template, aFrame: aFrame,
                  aSeconds: aSeconds, endSeconds: endSeconds, readLimit: readLimit)
    }

    /// pts of the first range's start frame.
    public var startPTS: Int64 { ranges[0].startPTS }
    /// pts of the last range's end frame.
    public var endPTS: Int64 { ranges[ranges.count - 1].endPTS }
    /// The first range's keyframe pts.
    public var keyframePTS: Int64? { ranges[0].keyframePTS }
}

public struct ClipResult: Sendable {
    public let url: URL
    /// A − the clip's actual start (its first keyframe), seconds.
    public let leadIn: Double
}

/// Copies the compressed packets of an A-B range into a new file (spec §3): no decoder, no re-encoding.
public enum ClipWriter {
    /// Debug hook: the first muxer fails, so the `.mkv` fallback runs.
    static var forceFallbackForTesting = false

    /// Writes `.<name>.part` next to the final name and renames it on success; the part is removed on any throw,
    /// including `CancellationError` when `isCancelled` turns true (checked per packet). The ranges follow one
    /// another in the file (cut marks spec §7).
    public static func write(_ job: ClipJob, isCancelled: () -> Bool) throws -> ClipResult {
        let directory = try outputDirectory(for: job)
        let bytes = ThrottledByteSource(try FileByteSource(url: job.source), bytesPerSecond: job.readLimit)
        let source = try MediaSource(url: job.source, readCache: try ReadCache(url: job.source, budgetBytes: 0, source: bytes), cached: false)
        let input = source.formatContext
        let video = source.videoStreamIndex
        var kept: [Int32] = []
        for i in 0..<Int32(input.pointee.nb_streams) {
            let stream = input.pointee.streams[Int(i)]!
            let keep = i == video || stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            stream.pointee.discard = keep ? AVDISCARD_DEFAULT : AVDISCARD_ALL
            if keep { kept.append(i) }
        }
        let videoTimeBase = source.videoStream.pointee.time_base
        let videoTimeBaseSeconds = av_q2d(videoTimeBase)
        let frameTicks = max(Int64((1 / source.frameRate / videoTimeBaseSeconds).rounded()), 1)
        // How far past B a frame written for its references can show: the reorder delay, at least 1 s. Bounds the
        // clip when the demuxer gives no dts (then the end is judged by pts).
        let videoDelay = Int64(source.videoStream.pointee.codecpar.pointee.video_delay)
        let delayFrames = Double(videoDelay + 1)
        let marginSeconds = max(delayFrames / source.frameRate, 1)
        let margin = Int64((marginSeconds / videoTimeBaseSeconds).rounded(.up))

        guard let packet = av_packet_alloc() else { throw FFmpegError(-1, "allocate packet") }
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        // Opened once the first range's keyframe is found: its pts (the clip's start) names the file.
        var output: ClipOutput?
        var leadIn = 0.0

        /// Copies one range; `previous` is where the last range ended in the clip (the end of its last video frame
        /// and its last video dts, video time base). Returns the same for this range.
        func copy(_ range: ClipRange, after previous: (end: Int64, dts: Int64)?) throws -> (end: Int64, dts: Int64) {
            try check(av_seek_frame(input, video, range.keyframePTS ?? range.startPTS, AVSEEK_FLAG_BACKWARD), "seek")
            // Packets read up to and including the first video keyframe. Audio stored before that keyframe may still
            // belong to the range.
            var pending: [UnsafeMutablePointer<AVPacket>] = []
            defer {
                for held in pending {
                    var held: UnsafeMutablePointer<AVPacket>? = held
                    av_packet_free(&held)
                }
            }
            var keyframe: (pts: Int64, dts: Int64)?
            while keyframe == nil {
                try autoreleasepool {
                    if isCancelled() { throw CancellationError() }
                    let code = source.read(into: packet)
                    if code == cff_error_eof() { throw FFmpegError(code, "find a keyframe at or before A") }
                    try check(code, "read")
                    defer { av_packet_unref(packet) }
                    if packet.pointee.stream_index == video {
                        // Video packets before the first keyframe cannot be decoded without what came before.
                        guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0, timestamp(packet) != cff_nopts() else { return }
                        let pts = timestamp(packet)
                        keyframe = (pts, packet.pointee.dts != cff_nopts() ? packet.pointee.dts : pts)
                    }
                    guard let held = av_packet_alloc() else { throw FFmpegError(-1, "allocate packet") }
                    av_packet_move_ref(held, packet)
                    pending.append(held)
                }
            }
            let start = keyframe!.pts
            // Where the keyframe lands in the clip: 0 for the first range; for a later one after the end of the last
            // frame before it, and far enough that its first dts (the keyframe's dts lead, or the reorder delay when
            // the demuxer gives none) stays above the last one.
            let base = previous.map { max($0.end, $0.dts + (videoDelay + 1) * frameTicks + (start - keyframe!.dts)) } ?? 0
            let shift = start - base
            let startSeconds = Double(start) * videoTimeBaseSeconds
            // Audio past this cannot belong to the range.
            let audioLimitSeconds = Double(range.endPTS) * videoTimeBaseSeconds + marginSeconds + 1
            if output == nil {
                leadIn = Double(range.startPTS - start) * videoTimeBaseSeconds
                let sourceExtension = job.source.pathExtension
                do {
                    if forceFallbackForTesting { throw FFmpegError(-1, "testing fallback") }
                    output = try ClipOutput(job: job, input: source, streams: kept, directory: directory,
                                            startSeconds: job.aSeconds - leadIn, fileExtension: sourceExtension)
                } catch {
                    guard sourceExtension.lowercased() != "mkv" else { throw error }
                    output = try ClipOutput(job: job, input: source, streams: kept, directory: directory,
                                            startSeconds: job.aSeconds - leadIn, fileExtension: "mkv")
                }
            }
            let output = output!
            // The end of the last video frame written (seconds): audio is kept up to it.
            var videoEndSeconds = startSeconds
            var lastDTS = keyframe!.dts
            // The last video dts written in the clip's time: after a seek Matroska gives the first reordered packets
            // no dts, and in a later range the muxer would guess them from the range before; they get the next one.
            var lastClipDTS = previous?.dts
            // Per audio stream, packets at or past `videoEndSeconds` when read, in order; once a stream has some, its
            // later packets queue behind them so its dts keep rising. Written as the video catches up.
            var heldAudio: [Int32: [UnsafeMutablePointer<AVPacket>]] = [:]
            defer {
                for held in heldAudio.values.joined() {
                    var held: UnsafeMutablePointer<AVPacket>? = held
                    av_packet_free(&held)
                }
            }
            func seconds(_ packet: UnsafeMutablePointer<AVPacket>) -> Double {
                Double(timestamp(packet)) * av_q2d(input.pointee.streams[Int(packet.pointee.stream_index)]!.pointee.time_base)
            }
            /// Writes each stream's held packets that now fall before `videoEndSeconds`, oldest first.
            func writeHeldAudio() throws {
                for (index, queue) in heldAudio {
                    var written = 0
                    while written < queue.count && seconds(queue[written]) < videoEndSeconds {
                        try output.write(queue[written], shiftingBy: shift, timeBase: videoTimeBase)
                        written += 1
                    }
                    heldAudio[index] = Array(queue[written...])
                    for packet in queue[..<written] {
                        var packet: UnsafeMutablePointer<AVPacket>? = packet
                        av_packet_free(&packet)
                    }
                }
            }
            // After the last video packet, reading goes on until every audio stream reaches `videoEndSeconds`.
            var videoDone = false
            let audioStreams = Set(kept.filter { $0 != video })
            var audioDone = Set<Int32>()
            /// Writes, holds or skips one packet; false when nothing later belongs to the range.
            func process(_ packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
                let index = packet.pointee.stream_index
                if index == video {
                    if videoDone {
                        // Reading on for audio stored after the video; give up once the video is a margin past its end.
                        let ts = packet.pointee.dts != cff_nopts() ? packet.pointee.dts : packet.pointee.pts
                        return ts != cff_nopts() && Double(ts) * videoTimeBaseSeconds < videoEndSeconds + marginSeconds
                    }
                    switch ClipWriter.videoAction(pts: packet.pointee.pts, dts: packet.pointee.dts, start: start,
                                                  end: range.endPTS, margin: margin) {
                    case .stop:
                        videoDone = true
                        try writeHeldAudio()
                        return audioStreams.count > audioDone.count
                    case .skip:
                        return true
                    case .write:
                        let ts = timestamp(packet)
                        let duration = packet.pointee.duration > 0
                            ? Double(packet.pointee.duration) * videoTimeBaseSeconds : 1 / source.frameRate
                        if packet.pointee.dts == cff_nopts(), let last = lastClipDTS { packet.pointee.dts = last + 1 + shift }
                        if packet.pointee.dts != cff_nopts() {
                            lastDTS = packet.pointee.dts
                            lastClipDTS = packet.pointee.dts - shift
                        } else {
                            lastDTS = max(lastDTS, ts)
                        }
                        try output.write(packet, shiftingBy: shift, timeBase: videoTimeBase)
                        if Double(ts) * videoTimeBaseSeconds + duration > videoEndSeconds {
                            videoEndSeconds = Double(ts) * videoTimeBaseSeconds + duration
                            try writeHeldAudio()
                        }
                        return true
                    }
                }
                guard timestamp(packet) != cff_nopts() else { return true }
                let time = seconds(packet)
                if videoDone && time >= videoEndSeconds {
                    audioDone.insert(index)
                    return audioStreams.count > audioDone.count
                }
                guard time >= startSeconds && time < audioLimitSeconds else { return true }
                if time < videoEndSeconds && heldAudio[index, default: []].isEmpty {
                    try output.write(packet, shiftingBy: shift, timeBase: videoTimeBase)
                } else {
                    guard let held = av_packet_alloc() else { throw FFmpegError(-1, "allocate packet") }
                    av_packet_move_ref(held, packet)
                    heldAudio[index, default: []].append(held)
                }
                return true
            }

            var finished = false
            for held in pending where !finished {
                try autoreleasepool {
                    if isCancelled() { throw CancellationError() }
                    finished = try !process(held)
                }
            }
            while !finished {
                try autoreleasepool {
                    if isCancelled() { throw CancellationError() }
                    let code = source.read(into: packet)
                    if code == cff_error_eof() {
                        finished = true
                        return
                    }
                    try check(code, "read")
                    defer { av_packet_unref(packet) }
                    finished = try !process(packet)
                }
            }
            // What is left of each stream past the end of the video is dropped.
            try autoreleasepool { try writeHeldAudio() }
            return (Int64((videoEndSeconds / videoTimeBaseSeconds).rounded()) - shift, lastDTS - shift)
        }

        do {
            var previous: (end: Int64, dts: Int64)?
            for range in job.ranges { previous = try copy(range, after: previous) }
            return ClipResult(url: try output!.finish(), leadIn: leadIn)
        } catch {
            output?.discard()
            throw error
        }
    }

    enum VideoAction: Equatable { case write, skip, stop }

    /// The end rule for one video packet (spec §3). dts only rises and a frame's pts is never below its dts, so the
    /// first packet with dts past B (`end`) ends the clip; every packet before it is written, including the frames
    /// after B that frames up to B reference (1–2 extra frames), so every frame up to B decodes. pts below `start`
    /// are open-GOP leading pictures, which reference frames before the keyframe. Without a dts the end is judged
    /// by pts with `margin`, and nothing past `end + margin` is written, so the clip stays bounded either way.
    static func videoAction(pts: Int64, dts: Int64, start: Int64, end: Int64, margin: Int64) -> VideoAction {
        let nopts = cff_nopts()
        if dts != nopts ? dts > end : pts != nopts && pts > end + margin { return .stop }
        let ts = pts != nopts ? pts : dts
        return ts != nopts && ts >= start && ts <= end + margin ? .write : .skip
    }

    private static func timestamp(_ packet: UnsafeMutablePointer<AVPacket>) -> Int64 {
        packet.pointee.pts != cff_nopts() ? packet.pointee.pts : packet.pointee.dts
    }

    /// The job's directory, or its fallback when that cannot be created or written (as `FrameExporter` does).
    private static func outputDirectory(for job: ClipJob) throws -> URL {
        let fm = FileManager.default
        if (try? fm.createDirectory(at: job.directory, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: job.directory.path) {
            return job.directory
        }
        try fm.createDirectory(at: job.fallbackDirectory, withIntermediateDirectories: true)
        return job.fallbackDirectory
    }
}

/// One muxer writing `.<name>.part` in the clip's directory. Not reused: `finish` or `discard` ends it.
private final class ClipOutput {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private let part: URL
    private let destination: URL
    /// Input stream index → output stream.
    private var streams: [Int32: UnsafeMutablePointer<AVStream>] = [:]
    private var inputStreams: [Int32: UnsafeMutablePointer<AVStream>] = [:]

    /// Creates the muxer and writes the header; on failure nothing is left on disk.
    init(job: ClipJob, input: MediaSource, streams kept: [Int32], directory: URL, startSeconds: Double,
         fileExtension: String) throws {
        let name = ClipOutput.availableName(
            FrameNaming.clipFileName(forVideo: job.nameSource ?? job.source, startSeconds: startSeconds, endSeconds: job.endSeconds,
                                     frame: job.aFrame, seconds: job.aSeconds, template: job.template,
                                     fileExtension: fileExtension),
            in: directory)
        destination = directory.appendingPathComponent(name)
        part = directory.appendingPathComponent(".\(name).part")
        // The muxer comes from the final name: ".part" names no format.
        guard let format = av_guess_format(nil, name, nil) else {
            throw FFmpegError(cff_averror_muxer_not_found(), "create muxer for .\(fileExtension)")
        }
        try check(avformat_alloc_output_context2(&context, format, nil, part.path), "create muxer")
        do {
            guard let output = context else { throw FFmpegError(-1, "create muxer") }
            for index in kept {
                let source = input.formatContext.pointee.streams[Int(index)]!
                guard let stream = avformat_new_stream(output, nil) else { throw FFmpegError(-1, "add stream") }
                try check(avcodec_parameters_copy(stream.pointee.codecpar, source.pointee.codecpar), "copy stream")
                if cff_muxer_keeps_codec_tag(format, stream.pointee.codecpar) == 0 { stream.pointee.codecpar.pointee.codec_tag = 0 }
                stream.pointee.time_base = source.pointee.time_base
                stream.pointee.disposition = source.pointee.disposition
                av_dict_copy(&stream.pointee.metadata, source.pointee.metadata, 0)
                streams[index] = stream
                inputStreams[index] = source
            }
            // avoid_negative_ts stays `auto`: the packets are already shifted so the first frame's pts is 0, and the
            // B-frame delay's negative dts goes into an MP4/MOV edit list (Matroska stores no dts). `make_zero`
            // would shift the dts to 0 instead and start the picture that many frames late.
            if format.pointee.flags & AVFMT_NOFILE == 0 {
                try check(avio_open(&output.pointee.pb, part.path, AVIO_FLAG_WRITE), "create \(part.lastPathComponent)")
            }
            // No `movflags=+faststart`: it rewrites the whole finished clip on the NAS, unthrottled and uncancellable,
            // and local players read the index from the end of the file just as well.
            try check(avformat_write_header(output, nil), "write header")
        } catch {
            discard()
            throw error
        }
    }

    deinit { close() }

    /// Shifts `packet` so the clip starts at zero, moves it to its output stream and hands it to the muxer
    /// (which takes the reference).
    func write(_ packet: UnsafeMutablePointer<AVPacket>, shiftingBy start: Int64, timeBase: AVRational) throws {
        let index = packet.pointee.stream_index
        guard let output = context, let stream = streams[index], let source = inputStreams[index] else { return }
        let shift = av_rescale_q(start, timeBase, source.pointee.time_base)
        if packet.pointee.pts != cff_nopts() { packet.pointee.pts -= shift }
        if packet.pointee.dts != cff_nopts() { packet.pointee.dts -= shift }
        av_packet_rescale_ts(packet, source.pointee.time_base, stream.pointee.time_base)
        packet.pointee.stream_index = stream.pointee.index
        packet.pointee.pos = -1
        try check(av_interleaved_write_frame(output, packet), "write")
    }

    /// Writes the trailer, closes the file and renames the part to the final name.
    func finish() throws -> URL {
        guard let output = context else { throw FFmpegError(-1, "write") }
        try check(av_write_trailer(output), "write trailer")
        if output.pointee.pb != nil, output.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_closep(&output.pointee.pb), "close \(part.lastPathComponent)")
        }
        close()
        try FileManager.default.moveItem(at: part, to: destination)
        return destination
    }

    /// Frees the muxer and removes the part.
    func discard() {
        close()
        try? FileManager.default.removeItem(at: part)
    }

    private func close() {
        guard let output = context else { return }
        if output.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 { avio_closep(&output.pointee.pb) }
        avformat_free_context(output)
        context = nil
    }

    /// `name`, or `name 2`, `name 3`… (before the extension) when it or its part is taken.
    private static func availableName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                || fm.fileExists(atPath: directory.appendingPathComponent(".\(candidate).part").path) {
            candidate = "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
