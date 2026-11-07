import Foundation
import CoreVideo
import CoreMedia
@preconcurrency import VideoToolbox

/// Read-only buffers cross executors only after processing completes. One caller at a time,
/// enforced by LatestVideoWork; all session creation and processing runs off-main.
public final class LowLatencyVideoProcessor: @unchecked Sendable {
    public struct Request: @unchecked Sendable {
        public let frame: DecodedFrame
        public let next: DecodedFrame?
        public let start: Double
        public let end: Double
        public let settings: LowLatencyVideoSettings
        public let ratio: Double
        public let epoch: UInt64
        public let noiseReferences: [TemporalNoiseReference]
        public init(frame: DecodedFrame, next: DecodedFrame?, start: Double, end: Double,
                    settings: LowLatencyVideoSettings, ratio: Double, epoch: UInt64 = 0, noiseReferences: [TemporalNoiseReference] = []) {
            self.frame = frame; self.next = next; self.start = start; self.end = end
            self.settings = settings; self.ratio = ratio; self.epoch = epoch
            self.noiseReferences = noiseReferences
        }
    }
    public struct Output: @unchecked Sendable {
        public let current: CVPixelBuffer
        public let intermediates: [CVPixelBuffer]
        public let scaleFactor: Float?
        public let status: String
        public let noiseApplied: Bool
        public let dynamicRange: DynamicRange
        public var hasEffectImage: Bool { noiseApplied || scaleFactor != nil || !intermediates.isEmpty }
        init(current: CVPixelBuffer, intermediates: [CVPixelBuffer], scaleFactor: Float?, status: String,
             noiseApplied: Bool = false, dynamicRange: DynamicRange = .sdr) {
            self.current = current; self.intermediates = intermediates; self.scaleFactor = scaleFactor
            self.status = status; self.noiseApplied = noiseApplied; self.dynamicRange = dynamicRange
        }
    }
    private struct Key: Equatable { var width: Int; var height: Int; var factor: Float; var count: Int }
    private final class Session {
        let processor = VTFrameProcessor()
        let sourcePool: CVPixelBufferPool
        let destinationPool: CVPixelBufferPool
        let transfer: VTPixelTransferSession
        init(configuration: any VTFrameProcessorConfiguration) throws {
            sourcePool = try LowLatencyVideoProcessor.pool(configuration.sourcePixelBufferAttributes)
            destinationPool = try LowLatencyVideoProcessor.pool(configuration.destinationPixelBufferAttributes)
            var session: VTPixelTransferSession?
            try LowLatencyVideoProcessor.check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session))
            guard let session else { throw Failure.buffer }
            transfer = session
            try processor.startSession(configuration: configuration)
        }
        deinit { processor.endSession(); VTPixelTransferSessionInvalidate(transfer) }
        func input(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
            let output = try LowLatencyVideoProcessor.buffer(sourcePool)
            try LowLatencyVideoProcessor.check(VTPixelTransferSessionTransferImage(transfer, from: buffer, to: output))
            CVBufferPropagateAttachments(buffer, output)
            return output
        }
    }
    private struct NoiseKey: Equatable { var width: Int; var height: Int; var format: OSType }
    private var noise: TemporalNoiseFilter?
    private var noiseKey: NoiseKey?
    private var noiseFailure: String?
    private var sr: Session?
    private var fi: Session?
    private var srKey: Key?
    private var fiKey: Key?
    // Cache rejected/start-failed sessions until the input/config changes: never reload every frame.
    private var srFailure: String?
    private var fiFailure: String?
    private var epoch: UInt64?
    public init() {}
    public func reset() { noise = nil; noiseKey = nil; noiseFailure = nil; sr = nil; fi = nil; srKey = nil; fiKey = nil; srFailure = nil; fiFailure = nil }

    public func process(_ request: Request) async throws -> Output {
        precondition(!Thread.isMainThread)
        if epoch != request.epoch { reset(); epoch = request.epoch }
        guard request.settings.enabled else {
            reset()
            return Output(current: request.frame.pixelBuffer, intermediates: [], scaleFactor: nil,
                          status: request.settings.enabled ? "Apple LL: HDR bypass" : "Apple LL: off")
        }
        let w = CVPixelBufferGetWidth(request.frame.pixelBuffer), h = CVPixelBufferGetHeight(request.frame.pixelBuffer)
        var current = request.frame.pixelBuffer
        var noiseApplied = false
        var status: [String] = []
        if request.settings.noiseActive {
            let references = TemporalNoiseFilter.references(frame: request.frame, seconds: request.start, candidates: request.noiseReferences)
            if references.isEmpty {
                status.append("Temporal Noise: needs a cached reference frame")
            } else {
                let key = NoiseKey(width: w, height: h, format: TemporalNoiseFilter.pixelFormat(for: request.frame))
                if noiseKey != key {
                    noise = nil; noiseKey = key; noiseFailure = nil
                    do { noise = try TemporalNoiseFilter(width: w, height: h, format: key.format) }
                    catch { noiseFailure = String(describing: error) }
                }
                if let noise {
                    do {
                        current = try await noise.process(frame: request.frame, seconds: request.start, references: references, strength: request.settings.noiseStrength)
                        noiseApplied = true
                    } catch { self.noise = nil; noiseFailure = String(describing: error) }
                }
                status.append(noiseApplied ? "Temporal Noise \(request.settings.noiseStrength.formatted())" : "Temporal Noise unavailable: \(noiseFailure ?? "session")")
            }
        } else { noise = nil; noiseKey = nil; noiseFailure = nil }
        if request.frame.dynamicRange != .sdr {
            sr = nil; fi = nil; srKey = nil; fiKey = nil
            if request.settings.scale != .off || request.settings.intermediateFrames > 0 { status.append("Apple LL: HDR bypass") }
            return Output(current: current, intermediates: [], scaleFactor: nil, status: status.joined(separator: "; "),
                          noiseApplied: noiseApplied, dynamicRange: request.frame.dynamicRange)
        }
        let supported = VTLowLatencySuperResolutionScalerConfiguration.isSupported
            ? VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: w, frameHeight: h) : []
        let factor = request.settings.scale.factor(supported: supported, ratio: request.ratio)
        if let factor {
            let key = Key(width: w, height: h, factor: factor, count: 0)
            if srKey != key {
                sr = nil; srKey = key; srFailure = nil
                do {
                    sr = try Session(configuration: VTLowLatencySuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: factor))
                } catch { srFailure = String(describing: error) }
            }
            status.append(sr == nil ? "LL SR unavailable: \(srFailure ?? "session")" : "LL SR ×\(factor.formatted())")
        } else {
            sr = nil; srKey = nil; srFailure = nil
            if request.settings.scale != .off {
                status.append(request.settings.scale == .auto && request.ratio <= 1.05
                              ? "LL SR: native size" : "LL SR unsupported at \(w)×\(h) / requested scale")
            }
        }
        var intermediates: [CVPixelBuffer] = []
        if request.settings.intermediateFrames > 0, !request.settings.noiseActive, let next = request.next,
           next.number == request.frame.number + 1, request.end > request.start,
           CVPixelBufferGetWidth(next.pixelBuffer) == w, CVPixelBufferGetHeight(next.pixelBuffer) == h {
            let count = request.settings.intermediateFrames == 3 ? 3 : 1
            let key = Key(width: w, height: h, factor: 1, count: count)
            if fiKey != key {
                fi = nil; fiKey = key; fiFailure = nil
                if VTLowLatencyFrameInterpolationConfiguration.isSupported,
                   let configuration = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h,
                                                                                   numberOfInterpolatedFrames: count == 3 ? 2 : 1) {
                    do { fi = try Session(configuration: configuration) }
                    catch { fiFailure = String(describing: error) }
                } else { fiFailure = "unsupported at \(w)×\(h)" }
            }
            if let fi {
                do { intermediates = try await interpolate(request, next: next, session: fi, count: count) }
                catch { self.fi = nil; fiFailure = String(describing: error) }
            }
            status.append(fi == nil ? "LL FI unavailable: \(fiFailure ?? "session")" : "LL FI ×\(count + 1)")
        } else {
            if request.settings.intermediateFrames == 0 || request.settings.noiseActive { fi = nil; fiKey = nil; fiFailure = nil }
            else { status.append("LL FI: waiting for consecutive playback frames") }
            if request.settings.noiseActive && request.settings.intermediateFrames > 0 { status.append("LL FI bypassed while Temporal Noise is enabled") }
        }
        let nativeCurrent = current
        if let sr {
            do {
                current = try await upscale(current, session: sr, time: request.start)
                var scaled: [CVPixelBuffer] = []
                for (i, buffer) in intermediates.enumerated() {
                    let t = request.start + (request.end - request.start) * Double(i + 1) / Double(intermediates.count + 1)
                    scaled.append(try await upscale(buffer, session: sr, time: t))
                }
                intermediates = scaled
            } catch {
                self.sr = nil; srFailure = String(describing: error)
                current = nativeCurrent; intermediates = []
                status.append("LL SR failed; original")
            }
        }
        return Output(current: current, intermediates: intermediates, scaleFactor: self.sr == nil ? nil : factor,
                      status: status.joined(separator: "; "), noiseApplied: noiseApplied)
    }

    private func upscale(_ source: CVPixelBuffer, session: Session, time: Double) async throws -> CVPixelBuffer {
        let input = try session.input(source), output = try Self.buffer(session.destinationPool)
        CVBufferPropagateAttachments(source, output)
        let pts = CMTime(seconds: time, preferredTimescale: 600_000)
        guard let first = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: pts),
              let last = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts) else { throw Failure.buffer }
        try await session.processor.process(parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: first, destinationFrame: last))
        return output
    }

    private func interpolate(_ request: Request, next: DecodedFrame, session: Session, count: Int) async throws -> [CVPixelBuffer] {
        let source = try session.input(next.pixelBuffer), previous = try session.input(request.frame.pixelBuffer)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: CMTime(seconds: request.end, preferredTimescale: 600_000)),
              let previousFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: CMTime(seconds: request.start, preferredTimescale: 600_000)) else { throw Failure.buffer }
        let phases = (1...count).map { Float($0) / Float(count + 1) }
        let buffers = try phases.map { _ in try Self.buffer(session.destinationPool) }
        let frames = zip(phases, buffers).compactMap { phase, buffer -> VTFrameProcessorFrame? in
            CVBufferPropagateAttachments(request.frame.pixelBuffer, buffer)
            return VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(seconds: request.start + Double(phase) * (request.end - request.start), preferredTimescale: 600_000))
        }
        guard frames.count == count,
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: sourceFrame, previousFrame: previousFrame,
                                                                        interpolationPhase: phases, destinationFrames: frames) else { throw Failure.buffer }
        // Caller-owned destination buffers remain alive through completion; no unbounded output stream.
        for try await _ in session.processor.process(parameters: parameters) {}
        return buffers
    }
    private enum Failure: Error { case buffer, status(OSStatus) }
    private static func check(_ status: OSStatus) throws { if status != 0 { throw Failure.status(status) } }
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
