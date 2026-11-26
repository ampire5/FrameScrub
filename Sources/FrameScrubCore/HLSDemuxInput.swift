import CFFmpeg
import Foundation
import os

/// Cancellation of a single demuxer's I/O independently of the media session.
final class HLSReadInterrupt: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
    func begin() { cancelled.withLock { $0 = false } }
}

/// Native libavformat input for an HTTP HLS VOD. Its interrupt state must live
/// until the demuxer closes, including while FFmpeg opens a nested segment.
final class HLSDemuxInput {
    private static let protocols = "http,https,tcp,tls,httpproxy"

    let session: HLSMediaSession
    private let read: HLSReadInterrupt?
    private var segments: [UnsafeMutablePointer<AVIOContext>: HLSSegmentIO] = [:]

    static func matches(_ url: URL) -> Bool {
        ByteSources.isRemote(url) && url.host != nil && url.pathExtension.lowercased() == "m3u8"
    }

    init(session: HLSMediaSession, read: HLSReadInterrupt?) {
        self.session = session
        self.read = read
    }

    private var isCancelled: Bool { session.isCancelled || read?.isCancelled == true }

    func open(_ url: URL) throws -> UnsafeMutablePointer<AVFormatContext> {
        guard !isCancelled else { throw POSIXError(.ECANCELED) }
        guard let demuxer = av_find_input_format("hls"), avio_find_protocol_name(url.absoluteString) != nil else {
            throw FFmpegError(-ENOSYS, "HLS HTTP transport is unavailable")
        }
        guard let context = avformat_alloc_context() else { throw FFmpegError(-ENOMEM, "allocate HLS demuxer") }

        context.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<HLSDemuxInput>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
        }, opaque: Unmanaged.passUnretained(self).toOpaque())
        context.pointee.io_open = { context, stream, url, flags, options in
            guard let context, let url, let stream, let opaque = context.pointee.interrupt_callback.opaque else {
                return -EINVAL
            }
            let input = Unmanaged<HLSDemuxInput>.fromOpaque(opaque).takeUnretainedValue()
            if let options { return input.openIO(context, stream, url, flags, options) }
            var local: OpaquePointer?
            defer { av_dict_free(&local) }
            return input.openIO(context, stream, url, flags, &local)
        }
        context.pointee.io_close2 = { context, stream in
            guard let context, let stream, let opaque = context.pointee.interrupt_callback.opaque else {
                return -EINVAL
            }
            let input = Unmanaged<HLSDemuxInput>.fromOpaque(opaque).takeUnretainedValue()
            guard let segment = input.segments.removeValue(forKey: stream) else { return avio_close(stream) }
            return segment.close(stream)
        }

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "protocol_whitelist", Self.protocols, 0)
        // A failed init-segment request can leave FFmpeg's persistent input closed but marked as reusable.
        av_dict_set(&options, "http_persistent", "0", 0)
        av_dict_set(&options, "http_multiple", "0", 0)
        av_dict_set(&options, "max_reload", "1", 0)
        av_dict_set(&options, "seg_max_retry", "2", 0)
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        try check(avformat_open_input(&opened, url.absoluteString, demuxer, &options), "open HLS playlist")
        guard let opened else { throw FFmpegError(-EIO, "open HLS playlist") }
        guard opened.pointee.duration > 0, opened.pointee.ctx_flags & AVFMTCTX_UNSEEKABLE == 0 else {
            var invalid: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&invalid)
            throw FFmpegError(-ENOSYS, "HLS playlist has no seekable duration")
        }
        return opened
    }

    private func openIO(_ context: UnsafeMutablePointer<AVFormatContext>,
                        _ stream: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>,
                        _ url: UnsafePointer<CChar>, _ flags: Int32,
                        _ options: UnsafeMutablePointer<OpaquePointer?>) -> Int32 {
        guard !isCancelled else { return -EINTR }
        let address = String(cString: url)
        let cacheable = eligibleSegment(address, flags, options.pointee)
        if cacheable, let data = session.segment(for: address), session.reserveSegmentIO(data.count) {
            let replay = HLSSegmentIO(session: session, interrupt: read, url: address,
                                      length: Int64(data.count), native: nil, bytes: data)
            if let wrapped = replay.makeContext() {
                segments[wrapped] = replay
                stream.pointee = wrapped
                return 0
            }
        }
        // FFmpeg does not forward TLS verification to all nested HTTP requests.
        av_dict_set(options, "protocol_whitelist", Self.protocols, 0)
        if let headers = session.requestHeaders { av_dict_set(options, "headers", headers, 0) }
        av_dict_set(options, "tls_verify", "1", 0)
        av_dict_set(options, "rw_timeout", "5000000", 0)
        let result = avio_open2(stream, url, flags, &context.pointee.interrupt_callback, options)
        guard result >= 0, cacheable, let native = stream.pointee else { return result }
        // Let FFmpeg see response cookies and the final URL of redirected playlists.
        guard responseOption("cookies", native)?.isEmpty != false,
              responseOption("location", native).map({ $0 == address }) ?? true else { return result }
        // Query the size already known to HTTP. avio_size can fall back to seeking.
        let length = avio_seek(native, 0, AVSEEK_SIZE)
        guard length > 0, length <= HLSSegmentIO.maximumBytes,
              session.reserveSegmentIO(Int(length)) else { return result }
        let recording = HLSSegmentIO(session: session, interrupt: read, url: address, length: length,
                                      native: native, bytes: Data(capacity: Int(length)))
        if let wrapped = recording.makeContext() {
            segments[wrapped] = recording
            stream.pointee = wrapped
        }
        return result
    }

    private func responseOption(_ name: String, _ context: UnsafeMutablePointer<AVIOContext>) -> String? {
        var value: UnsafeMutablePointer<UInt8>?
        av_opt_get(context, name, AV_OPT_SEARCH_CHILDREN, &value)
        defer { av_free(value) }
        return value.map { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
    }

    private func eligibleSegment(_ address: String, _ flags: Int32, _ options: OpaquePointer?) -> Bool {
        guard flags == AVIO_FLAG_READ, let url = URL(string: address), ByteSources.isRemote(url),
              ["ts", "m4s", "mp4", "m4a", "aac", "mp3", "ac3", "ec3"].contains(url.pathExtension.lowercased()),
              av_dict_get(options, "offset", nil, 0) == nil,
              av_dict_get(options, "end_offset", nil, 0) == nil else { return false }
        for option in ["headers", "cookies", "method", "post_data"] {
            if let entry = av_dict_get(options, option, nil, 0), entry.pointee.value.pointee != 0 { return false }
        }
        return true
    }
}
