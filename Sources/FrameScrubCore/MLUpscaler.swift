import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

public enum MLAvailability: Equatable, Sendable {
    case ready
    case modelNotReady(downloading: Bool)
    case tooLarge
    case unsupported(String)
}

/// Apple's image super-resolution (VTSuperResolutionScaler, x4 only).
public enum MLUpscaler {
    /// Measured: the image configuration accepts up to 1920 px on the larger side (1920x1080, 1088x1920 and
    /// 1024x1024 work; 1921x1081, 2048x1152 and 2000x2000 are rejected).
    public static let maxInputSide = 1920

    public static func fits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && max(width, height) <= maxInputSide
    }

    public static func availability(width: Int, height: Int) -> MLAvailability {
        guard fits(width: width, height: height) else { return .tooLarge }
        guard VTSuperResolutionScalerConfiguration.isSupported else { return .unsupported("not supported on this Mac") }
        guard let config = makeConfiguration(width: width, height: height) else { return .unsupported("rejected the image size") }
        switch config.configurationModelStatus {
        case .ready: return .ready
        case .downloading: return .modelNotReady(downloading: true)
        default: return .modelNotReady(downloading: false)
        }
    }

    /// Downloads the Apple model (no-op when it is there); throws when it cannot.
    public static func downloadModel() async throws {
        guard let config = makeConfiguration(width: 1920, height: 1080) else {
            throw MLUpscaleError.unavailable
        }
        try await config.downloadConfigurationModel()
    }

    /// `image` (extent origin (0, 0), at most `maxInputSide`) -> an image four times larger.
    /// Every caller shares one session (see `MLSessionPool`): a session costs ~2 GB while open.
    public static func upscale4x(_ image: CIImage, context: CIContext) async throws -> CIImage {
        try await pool.upscale(image, context: context)
    }

    static let pool = MLSessionPool { width, height in
        return try VTSuperResolutionSession(width: width, height: height)
    }

    /// Gamma-encoded (the model sees display-referred values), wide enough for Display P3 sources.
    static let workingSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    static func makeConfiguration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: 4, inputType: .image, usePrecomputedFlow: false,
            qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    static func makeBuffer(width: Int, height: Int, attributes: [String: Any]) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw MLUpscaleError.bufferFailed(status) }
        return buffer
    }
}

public enum MLUpscaleError: Error, CustomStringConvertible {
    case unavailable, modelNotReady, bufferFailed(CVReturn)

    public var description: String {
        switch self {
        case .unavailable: return "ML upscaler unavailable"
        case .modelNotReady: return "ML model not downloaded"
        case let .bufferFailed(status): return "ML buffer allocation failed (\(status))"
        }
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable { var result: Result<T, Error>? }

/// Runs async work from a background (non-main, non-cooperative) thread and waits for it.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    precondition(!Thread.isMainThread, "runBlocking must not run on the main thread")
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.result = await Result { try await operation() }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

public struct UpscaleResult {
    public let image: CIImage
    /// Why Lanczos was used instead of the requested ML upscaler; nil when nothing was substituted.
    public let fallbackReason: String?
}

/// Resizes an upright, native-size image for saving.
public enum FrameUpscaler {
    /// The network is only worth its cost (and ~3 GB) when the picture grows clearly.
    static let minimumNetworkRatio = 1.5

    /// Enlarges by 2 or 4.
    public static func upscale(_ image: CIImage, scale: Int, upscaler: Upscaler, hdrOutput: Bool,
                               context: CIContext) -> UpscaleResult {
        guard scale > 1 else { return UpscaleResult(image: image, fallbackReason: nil) }
        let target = CGSize(width: image.extent.width * CGFloat(scale), height: image.extent.height * CGFloat(scale))
        return resize(image, to: target, upscaler: upscaler, hdrOutput: hdrOutput, context: context)
    }

    /// Resizes to exactly `size` (same aspect ratio). Reducing, and small enlargements, use Lanczos. A larger
    /// enlargement uses the network when `upscaler` is `.ml` (x4, then Lanczos to the exact size).
    public static func resize(_ image: CIImage, to size: CGSize, upscaler: Upscaler, hdrOutput: Bool,
                              context: CIContext) -> UpscaleResult {
        let source = image.extent.size
        guard size != source, size.width >= 1, size.height >= 1 else { return UpscaleResult(image: image, fallbackReason: nil) }
        func lanczos(_ reason: String?) -> UpscaleResult {
            UpscaleResult(image: ImageScaling.lanczos(image, to: size), fallbackReason: reason)
        }
        guard upscaler == .ml, size.width / source.width >= minimumNetworkRatio else { return lanczos(nil) }
        if hdrOutput { return lanczos("HDR output") }
        let width = Int(source.width.rounded()), height = Int(source.height.rounded())
        switch MLUpscaler.availability(width: width, height: height) {
        case .tooLarge: return lanczos("source larger than \(MLUpscaler.maxInputSide) px")
        case let .unsupported(reason): return lanczos(reason)
        case .modelNotReady: return lanczos("model not downloaded")
        case .ready: break
        }
        do {
            let four = try runBlocking { try await MLUpscaler.upscale4x(image, context: context) }
            let exactFour = size.width == source.width * 4 && size.height == source.height * 4
            return UpscaleResult(image: exactFour ? four : ImageScaling.lanczos(four, to: size), fallbackReason: nil)
        } catch {
            return lanczos("\(error)")
        }
    }
}

final class VTSuperResolutionSession: MLSession, @unchecked Sendable {
    private let config: VTSuperResolutionScalerConfiguration
    private let processor = VTFrameProcessor()
    private let width: Int, height: Int

    init(width: Int, height: Int) throws {
        guard let config = MLUpscaler.makeConfiguration(width: width, height: height) else { throw MLUpscaleError.unavailable }
        guard config.configurationModelStatus == .ready else { throw MLUpscaleError.modelNotReady }
        self.config = config
        self.width = width
        self.height = height
        try processor.startSession(configuration: config)
    }

    func upscale(_ image: CIImage, context: CIContext) async throws -> CIImage {
        let source = try MLUpscaler.makeBuffer(width: width, height: height, attributes: config.sourcePixelBufferAttributes)
        let destination = try MLUpscaler.makeBuffer(width: width * 4, height: height * 4,
                                                    attributes: config.destinationPixelBufferAttributes)
        context.render(image, to: source, bounds: image.extent, colorSpace: MLUpscaler.workingSpace)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero),
              let parameters = VTSuperResolutionScalerParameters(
                  sourceFrame: sourceFrame, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                  submissionMode: .random, destinationFrame: destinationFrame) else { throw MLUpscaleError.unavailable }
        try await processor.process(parameters: parameters)
        return CIImage(cvPixelBuffer: destination, options: [.colorSpace: MLUpscaler.workingSpace])
    }

    func end() { processor.endSession() }
}
