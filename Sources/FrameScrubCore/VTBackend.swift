import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Our own asynchronous VideoToolbox decoder for H.264/HEVC with avcC/hvcC: FFmpeg's packets go into a
/// `VTDecompressionSession` that keeps up to `maxInFlight` frames busy, unlike FFmpeg's hwaccel, which waits for
/// every frame. Frames come out of the session in decode order and are put back in presentation order here.
final class VTBackend: DecoderBackend {
    let kind = DecoderBackendKind.videoToolbox
    let codecName: String
    var decodedCount: Int { state.lock.withLock { state.decoded } }
    /// Frames the session handed back as pictures (not the ones decoded only as references).
    var outputCount: Int { state.lock.withLock { state.output } }

    static let maxInFlight = 4

    /// Tests: replaces creating the session.
    @TaskLocal static var makeSessionOverride: (@Sendable (CMVideoFormatDescription) throws -> VTDecompressionSession)?
    /// Tests: statuses returned instead of the next DecodeFrame calls, shared by every backend created in its scope.
    final class StatusInjection: @unchecked Sendable {
        var statuses: [OSStatus] = []
        func take() -> OSStatus? { statuses.isEmpty ? nil : statuses.removeFirst() }
    }
    @TaskLocal static var injection: StatusInjection?
    /// Tests: the next new extradata gets a new session even when the current one could take it.
    var forceNewSessionOnNextFormat = false
    private(set) var sessionsCreated = 0

    /// What the session's output handlers share with the backend: they must not touch the backend itself, which
    /// may be gone when a late callback arrives.
    private final class State {
        let lock = NSLock()
        let slots = DispatchSemaphore(value: VTBackend.maxInFlight)
        var inbox: [(pts: Int64, image: CVImageBuffer?, status: OSStatus)] = []
        /// Raised by every flush: a callback of a packet sent before it is dropped.
        var generation = 0
        var decoded = 0
        var output = 0
    }

    private let stream: UnsafeMutablePointer<AVStream>
    private let timeBase: AVRational
    private var parameterSets: ParameterSets
    private var format: CMVideoFormatDescription
    private var session: VTDecompressionSession
    private let tenBit: Bool
    private let injection = VTBackend.injection
    private let state = State()
    private let dynamicRange: DynamicRange
    private var queue: ReorderQueue<BackendFrame>
    private var pictureTypes: [Int64: Character] = [:]
    private var draining = false
    /// The first random-access picture sent since the last flush; earlier pictures (HEVC RASL, leading B-frames of
    /// an open GOP) lack references from before it.
    private var startPTS: Int64?

    /// H.264 or HEVC in avcC/hvcC with parameter sets in the record (not avc3/hev1, not Annex B).
    static func supports(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        parameterSets(stream.pointee.codecpar).map { $0.spsCount > 0 && $0.ppsCount > 0 } ?? false
    }

    private static func parameterSets(_ parameters: UnsafePointer<AVCodecParameters>) -> ParameterSets? {
        let p = parameters.pointee
        let family: VideoCodecFamily
        switch p.codec_id {
        case AV_CODEC_ID_H264: family = .h264
        case AV_CODEC_ID_HEVC: family = .hevc
        default: return nil
        }
        let inBandTags = ["avc3", "hev1"].map { tag in tag.utf8.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        guard !inBandTags.contains(p.codec_tag), let extradata = p.extradata, p.extradata_size > 0 else { return nil }
        return ParameterSets.parse(extradata: Data(bytes: extradata, count: Int(p.extradata_size)), family: family)
    }

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        let parameters = stream.pointee.codecpar!
        guard let sets = Self.parameterSets(parameters) else { throw FFmpegError(-1, "not avcC/hvcC") }
        self.stream = stream
        timeBase = stream.pointee.time_base
        parameterSets = sets
        codecName = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        queue = ReorderQueue(depth: Int(parameters.pointee.video_delay))
        tenBit = cff_pix_fmt_depth(parameters.pointee.format) > 8
        format = try Self.makeFormat(parameters, Data(bytes: parameters.pointee.extradata,
                                                      count: Int(parameters.pointee.extradata_size)), sets)
        session = try Self.makeSession(format, tenBit: tenBit)
        sessionsCreated = 1
        let probe = try Self.attachmentProbe()
        dynamicRange = ColorAttachments.apply(from: parameters, to: probe)
    }

    deinit {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    private static func makeFormat(_ parameters: UnsafePointer<AVCodecParameters>, _ atoms: Data,
                                   _ sets: ParameterSets) throws -> CMVideoFormatDescription {
        let p = parameters.pointee
        var extensions = ColorAttachments.formatExtensions(parameters)
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
            [sets.family == .hevc ? "hvcC" : "avcC": atoms] as CFDictionary
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: sets.family == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: p.width, height: p.height, extensions: extensions as CFDictionary,
            formatDescriptionOut: &description)
        guard status == noErr, let description else { throw FFmpegError(status, "format description") }
        return description
    }

    /// Hardware sessions VideoToolbox refused, by codec and bit depth, until when that answer is believed. Without a
    /// hardware decoder for a format (Intel Macs without HEVC 10-bit) every new decoder would spend about a
    /// second asking again before software takes over; a minute lets a decoder that was only busy (after sleep) back.
    private static let refusalLock = NSLock()
    private static var refusedUntil: [String: TimeInterval] = [:]
    static let refusalMemory: TimeInterval = 60

    private static func makeSession(_ format: CMVideoFormatDescription, tenBit: Bool) throws -> VTDecompressionSession {
        if let makeSessionOverride { return try makeSessionOverride(format) }
        let key = "\(CMFormatDescriptionGetMediaSubType(format)) \(tenBit ? 10 : 8)"
        let now = ProcessInfo.processInfo.systemUptime
        if refusalLock.withLock({ (refusedUntil[key] ?? 0) > now }) {
            throw FFmpegError(kVTCouldNotFindVideoDecoderErr, "VideoToolbox session (refused within the last minute)")
        }
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                                   : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                          kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                  decoderSpecification: specification,
                                                  imageBufferAttributes: attributes, outputCallback: nil,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let session else {
            refusalLock.withLock { refusedUntil[key] = now + refusalMemory }
            throw FFmpegError(status, "VideoToolbox session")
        }
        return session
    }

    /// A tiny buffer to learn the dynamic range from the same mapping the frames get.
    private static func attachmentProbe() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        guard status == kCVReturnSuccess, let pb else { throw FFmpegError(status, "pixel buffer") }
        return pb
    }

    func send(_ packet: UnsafePointer<AVPacket>, output: Bool, mayDrop: Bool) throws {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let size = Int(packet.pointee.size)
        let pts = packet.pointee.pts
        var sideSize = 0
        if let side = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sideSize), sideSize > 0 {
            try adopt(extradata: Data(bytes: side, count: sideSize))
        }
        let info = AccessUnitInfo.parse(UnsafeBufferPointer(start: data, count: size), parameterSets: parameterSets)
        if mayDrop && !info.isReference { return }
        if startPTS == nil && (info.isRandomAccess || packet.pointee.flags & AV_PKT_FLAG_KEY != 0) { startPTS = pts }
        let leading = startPTS.map { pts != cff_nopts() && pts < $0 } ?? true
        if let type = info.pictureType { pictureTypes[pts] = type }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block)
        guard status == noErr, let block else { throw BackendError.fatal(FFmpegError(status, "block buffer")) }
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        var timing = CMSampleTimingInfo(duration: time(packet.pointee.duration), presentationTimeStamp: time(pts),
                                        decodeTimeStamp: time(packet.pointee.dts))
        var sizes = [size]
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw BackendError.fatal(FFmpegError(status, "sample buffer")) }

        var flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        // Edit lists mark the packets before the visible start: decoded as references, never shown (as libavcodec).
        if !output || leading || packet.pointee.flags & AV_PKT_FLAG_DISCARD != 0 { flags.insert(._DoNotOutputFrame) }
        let state = state
        let generation = state.lock.withLock { state.generation }
        state.slots.wait()
        status = injection?.take() ?? VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags,
                                                   infoFlagsOut: nil) { status, _, image, _, _ in
            state.lock.withLock {
                guard generation == state.generation else { return }
                if status == noErr { state.decoded += 1 }
                if image != nil { state.output += 1 }
                if status == noErr || !leading || Self.isSessionLoss(status) { state.inbox.append((pts, image, status)) }
            }
            state.slots.signal()
        }
        if status != noErr {
            state.slots.signal()
            if !leading || Self.isSessionLoss(status) { throw Self.error(status) }
        }
    }

    func receive() throws -> BackendResult {
        try collect()
        if let frame = draining ? queue.popAll() : queue.pop() { return .frame(frame) }
        return draining ? .ended : .needsInput
    }

    func drain() throws {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        draining = true
    }

    func flush() {
        state.lock.withLock {
            state.generation += 1
            state.inbox.removeAll()
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        queue.removeAll()
        pictureTypes.removeAll()
        draining = false
        startPTS = nil
    }

    /// Moves what the session has output into the reorder queue; a failed frame is reported once.
    private func collect() throws {
        let arrived = state.lock.withLock {
            defer { state.inbox.removeAll() }
            return state.inbox
        }
        var failure: OSStatus?
        for entry in arrived {
            guard entry.status == noErr else {
                failure = failure ?? entry.status
                pictureTypes[entry.pts] = nil
                continue
            }
            guard let image = entry.image else { continue }
            _ = ColorAttachments.apply(from: stream.pointee.codecpar, to: image)
            queue.insert(BackendFrame(pts: entry.pts, pixelBuffer: image, dynamicRange: dynamicRange,
                                      pictureType: pictureTypes.removeValue(forKey: entry.pts)), pts: entry.pts)
        }
        if let failure { throw Self.error(failure) }
    }

    private static func isSessionLoss(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr
    }

    private static func error(_ status: OSStatus) -> BackendError {
        isSessionLoss(status) ? .sessionLost(status) : .corruptFrame(status)
    }

    /// New parameter sets in a packet's side data: a new format description, and a new session if the current one
    /// cannot take it (after the frames it holds have come out).
    private func adopt(extradata: Data) throws {
        guard let sets = ParameterSets.parse(extradata: extradata, family: parameterSets.family) else { return }
        let newFormat = try Self.makeFormat(stream.pointee.codecpar, extradata, sets)
        if forceNewSessionOnNextFormat || !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            forceNewSessionOnNextFormat = false
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            let newSession = try Self.makeSession(newFormat, tenBit: tenBit)
            VTDecompressionSessionInvalidate(session)
            session = newSession
            sessionsCreated += 1
        }
        format = newFormat
        parameterSets = sets
    }

    private func time(_ value: Int64) -> CMTime {
        value == cff_nopts() ? .invalid : CMTime(value: value * Int64(timeBase.num), timescale: timeBase.den)
    }
}
