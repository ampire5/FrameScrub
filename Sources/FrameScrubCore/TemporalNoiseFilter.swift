import Foundation
import CoreVideo
import CoreMedia
@preconcurrency import VideoToolbox

public struct TemporalNoiseReference: @unchecked Sendable {
    public let frame: DecodedFrame
    public let seconds: Double
    public init(frame: DecodedFrame, seconds: Double) { self.frame = frame; self.seconds = seconds }
}

/// Worker-owned, native-size temporal denoiser. Inputs are immutable cached originals, never
/// previous filtered output. Runtime on M4 Max/macOS27.2 (2026-11-07): one past/two future references.
/// That bounds request ownership to four source buffers; configuration counts trim them further.
final class TemporalNoiseFilter {
    private let configuration: VTTemporalNoiseFilterConfiguration
    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private let transfer: VTPixelTransferSession
    private var lastFrame: Int?
    private var lastSeconds: Double?

    static func pixelFormat(for frame: DecodedFrame) -> OSType {
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let tenBit = frame.dynamicRange != .sdr || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        if tenBit { return full ? kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange : kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange }
        return full ? kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
    }

    static func references(frame: DecodedFrame, seconds: Double, candidates: [TemporalNoiseReference]) -> [TemporalNoiseReference] {
        guard seconds.isFinite else { return [] }
        let valid = candidates.filter {
            $0.seconds.isFinite && $0.frame.dynamicRange == frame.dynamicRange
                && CVPixelBufferGetWidth($0.frame.pixelBuffer) == CVPixelBufferGetWidth(frame.pixelBuffer)
                && CVPixelBufferGetHeight($0.frame.pixelBuffer) == CVPixelBufferGetHeight(frame.pixelBuffer)
                && pixelFormat(for: $0.frame) == pixelFormat(for: frame)
        }
        var result: [TemporalNoiseReference] = []
        if let past = valid.first(where: { $0.frame.number == frame.number - 1 && $0.seconds < seconds && seconds - $0.seconds < 1 }) { result.append(past) }
        if let next = valid.first(where: { $0.frame.number == frame.number + 1 && $0.seconds > seconds && $0.seconds - seconds < 1 }) {
            result.append(next)
            if let last = valid.first(where: { $0.frame.number == frame.number + 2 && $0.seconds > next.seconds && $0.seconds - seconds < 1 }) { result.append(last) }
        }
        return result
    }

    init(width: Int, height: Int, format: OSType) throws {
        guard VTTemporalNoiseFilterConfiguration.isSupported,
              VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats.contains(format),
              let minimum = VTTemporalNoiseFilterConfiguration.minimumDimensions,
              let maximum = VTTemporalNoiseFilterConfiguration.maximumDimensions,
              width >= minimum.width, height >= minimum.height, width <= maximum.width, height <= maximum.height,
              let configuration = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height, sourcePixelFormat: format) else { throw Failure.unsupported }
        self.configuration = configuration
        sourcePool = try Self.pool(configuration.sourcePixelBufferAttributes)
        destinationPool = try Self.pool(configuration.destinationPixelBufferAttributes)
        var transfer: VTPixelTransferSession?
        try Self.check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer))
        guard let transfer else { throw Failure.buffer }
        self.transfer = transfer
        try processor.startSession(configuration: configuration)
    }
    deinit { processor.endSession(); VTPixelTransferSessionInvalidate(transfer) }

    func process(frame: DecodedFrame, seconds: Double, references: [TemporalNoiseReference], strength: Double) async throws -> CVPixelBuffer {
        let past = Array(references.filter { $0.seconds < seconds }.suffix(configuration.previousFrameCount ?? 0))
        let future = Array(references.filter { $0.seconds > seconds }.prefix(configuration.nextFrameCount ?? 0))
        guard !past.isEmpty || !future.isEmpty else { throw Failure.noReferences }
        func prepared(_ frame: DecodedFrame, _ time: Double) throws -> VTFrameProcessorFrame {
            let buffer = try Self.buffer(sourcePool)
            try Self.check(VTPixelTransferSessionTransferImage(transfer, from: frame.pixelBuffer, to: buffer))
            CVBufferPropagateAttachments(frame.pixelBuffer, buffer)
            guard let wrapped = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600_000)) else { throw Failure.buffer }
            return wrapped
        }
        let input = try prepared(frame, seconds)
        let previous = try past.map { try prepared($0.frame, $0.seconds) }
        let next = try future.map { try prepared($0.frame, $0.seconds) }
        let output = try Self.buffer(destinationPool)
        CVBufferPropagateAttachments(frame.pixelBuffer, output)
        guard let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: input.presentationTimeStamp),
              let parameters = VTTemporalNoiseFilterParameters(sourceFrame: input, nextFrames: next, previousFrames: previous,
                  destinationFrame: destination, filterStrength: Float(min(1, max(0, strength))),
                  hasDiscontinuity: (lastFrame.map { $0 + 1 != frame.number } ?? true) || (lastSeconds.map { $0 >= seconds } ?? true)) else { throw Failure.buffer }
        try await processor.process(parameters: parameters)
        lastFrame = frame.number; lastSeconds = seconds
        CVBufferPropagateAttachments(frame.pixelBuffer, output)
        return output
    }
    private enum Failure: Error { case unsupported, noReferences, buffer, status(OSStatus) }
    private static func check(_ value: OSStatus) throws { if value != 0 { throw Failure.status(value) } }
    private static func pool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        try check(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool))
        guard let pool else { throw Failure.buffer }; return pool
    }
    private static func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer))
        guard let buffer else { throw Failure.buffer }; return buffer
    }
}
