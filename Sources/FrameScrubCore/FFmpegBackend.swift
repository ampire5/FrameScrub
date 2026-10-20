import CFFmpeg
import CoreVideo

/// libavcodec decoding, in software or through FFmpeg's VideoToolbox hwaccel.
final class FFmpegBackend: DecoderBackend {
    private(set) var kind: DecoderBackendKind = .software
    private(set) var codecName = ""
    private(set) var decodedCount = 0

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private let frame: UnsafeMutablePointer<AVFrame>
    private let converter = SoftwareFrameConverter()
    private var draining = false

    init(stream: UnsafeMutablePointer<AVStream>, hardware: Bool) throws {
        frame = av_frame_alloc()!
        try open(stream: stream, hardware: hardware)   // on failure deinit frees what was allocated
    }

    deinit {
        avcodec_free_context(&codecContext)
        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
    }

    private func open(stream: UnsafeMutablePointer<AVStream>, hardware: Bool) throws {
        avcodec_free_context(&codecContext)
        let parameters = stream.pointee.codecpar!
        let id = parameters.pointee.codec_id

        var useHardware = false
        var codec: UnsafePointer<AVCodec>?
        if hardware {
            // libdav1d (FFmpeg's default AV1 decoder) has no hwaccel; the native "av1" decoder does.
            let candidate = id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("av1") : avcodec_find_decoder(id)
            if let candidate, Self.supportsVideoToolbox(candidate) {
                codec = candidate
                useHardware = true
            }
        }
        if codec == nil {
            codec = (id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : nil) ?? avcodec_find_decoder(id)
        }
        guard let codec else {
            throw FFmpegError(-1, "no decoder for \(String(cString: avcodec_get_name(id)))")
        }
        guard let context = avcodec_alloc_context3(codec) else { throw FFmpegError(-1, "allocate decoder") }
        codecContext = context
        try check(avcodec_parameters_to_context(context, parameters), "copy codec parameters")
        context.pointee.pkt_timebase = stream.pointee.time_base

        if useHardware {
            var device: UnsafeMutablePointer<AVBufferRef>?
            if av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) == 0 {
                context.pointee.hw_device_ctx = device   // the context takes ownership
            } else if id == AV_CODEC_ID_AV1 {
                return try open(stream: stream, hardware: false)    // native av1 cannot decode in software
            } else {
                useHardware = false
            }
        }
        if !useHardware { context.pointee.thread_count = 0 }
        try check(avcodec_open2(context, codec, nil), "open decoder")

        kind = useHardware ? .ffmpegVideoToolbox : .software
        codecName = String(cString: codec.pointee.name)
    }

    private static func supportsVideoToolbox(_ codec: UnsafePointer<AVCodec>) -> Bool {
        var i: Int32 = 0
        while let config = avcodec_get_hw_config(codec, i) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
               config.pointee.methods & Int32(AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 {
                return true
            }
            i += 1
        }
        return false
    }

    func send(_ packet: UnsafePointer<AVPacket>, output: Bool, mayDrop: Bool) throws {
        // `output` is not needed: VideoDecoder throws the pre-roll away itself.
        codecContext?.pointee.skip_frame = mayDrop ? AVDISCARD_NONREF : AVDISCARD_DEFAULT
        let result = avcodec_send_packet(codecContext, packet)
        if result < 0 && result != cff_error_eagain() { throw BackendError.corruptFrame(result) }
    }

    func receive() throws -> BackendResult {
        let result = avcodec_receive_frame(codecContext, frame)
        if result == 0 {
            defer { av_frame_unref(frame) }
            decodedCount += 1
            return .frame(try makeFrame())
        }
        if result == cff_error_eof() || (result == cff_error_eagain() && draining) { return .ended }
        if result == cff_error_eagain() { return .needsInput }
        throw BackendError.corruptFrame(result)
    }

    func drain() throws {
        avcodec_send_packet(codecContext, nil)
        draining = true
    }

    func flush() {
        avcodec_flush_buffers(codecContext)
        draining = false
    }

    private func makeFrame() throws -> BackendFrame {
        var timestamp = frame.pointee.best_effort_timestamp
        if timestamp == cff_nopts() { timestamp = frame.pointee.pts }

        let pixelBuffer: CVPixelBuffer
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
           let raw = cff_frame_hw_buffer(frame) {
            pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
        } else {
            kind = .software   // VideoToolbox declined this stream; FFmpeg fell back to software
            pixelBuffer = try converter.convert(frame)
        }
        let range = ColorAttachments.apply(from: frame, to: pixelBuffer)
        let type: Character? = switch frame.pointee.pict_type {
        case AV_PICTURE_TYPE_I: "I"
        case AV_PICTURE_TYPE_P: "P"
        case AV_PICTURE_TYPE_B: "B"
        default: nil
        }
        return BackendFrame(pts: timestamp, pixelBuffer: pixelBuffer, dynamicRange: range, pictureType: type)
    }
}
