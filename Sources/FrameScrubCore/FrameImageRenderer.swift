import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO

public enum FrameImageRendererError: Error { case encodingFailed }

/// The single Core Image path from a decoded frame to pixels, used for display and for files.
/// Files keep the native resolution (rotation applied, no scaling). JPEG is tone-mapped to SDR
/// sRGB; HEIC (10-bit), PNG and TIFF (16-bit) keep HDR in BT.2100 HLG/PQ.
public final class FrameImageRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    /// Pixel size of the upright picture (what the file would have at scale 1).
    public static func uprightSize(of frame: DecodedFrame, rotationClockwise: Int) -> CGSize {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer), height = CVPixelBufferGetHeight(frame.pixelBuffer)
        return rotationClockwise % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    public static func orientation(forClockwiseRotation degrees: Int) -> CGImagePropertyOrientation {
        switch degrees {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// Upright image of the frame at native pixel size with its extent origin at (0, 0).
    public static func image(for frame: DecodedFrame, rotationClockwise: Int, toneMapToSDR: Bool) -> CIImage {
        var options: [CIImageOption: Any] = [:]
        if toneMapToSDR && frame.dynamicRange != .sdr { options[.toneMapHDRtoSDR] = true }
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer, options: options)
            .oriented(orientation(forClockwiseRotation: rotationClockwise))
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// The picture for the screen: HDR is reduced to what the display can show (spec §11.4).
    public static func displayImage(for frame: DecodedFrame, rotationClockwise: Int, plan: ToneMapPlan) -> CIImage {
        let image = Self.image(for: frame, rotationClockwise: rotationClockwise, toneMapToSDR: plan == .toSDR)
        if plan == .toSDR { return Self.clamped(image, to: 1) }
        guard case let .toHeadroom(target) = plan else { return image }
        // CIImage reports the content's own headroom for HLG/PQ buffers; fall back to the nominal peak.
        let fallback: Float = frame.dynamicRange == .pq ? 49.26 : 4.926
        let source = image.contentHeadroom > 1 ? image.contentHeadroom : fallback
        guard Float(target) < source else { return image }
        let filter = CIFilter.toneMapHeadroom()
        filter.inputImage = image
        filter.sourceHeadroom = source
        filter.targetHeadroom = Float(target)
        return Self.clamped(filter.outputImage ?? image, to: Float(target))
    }

    /// The tone mappers only shape values up to the content's nominal peak; wide-gamut colours
    /// (BT.2020 converted to the working space) can still land above it, so cap the result.
    private static func clamped(_ image: CIImage, to maximum: Float) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: -100, y: -100, z: -100, w: 0)
        filter.maxComponents = CIVector(x: CGFloat(maximum), y: CGFloat(maximum), z: CGFloat(maximum), w: 1)
        return filter.outputImage ?? image
    }

    static func colorSpace(of pixelBuffer: CVPixelBuffer) -> CGColorSpace? {
        guard let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) else { return nil }
        return CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
    }

    private func resized(_ image: CIImage, scale: OutputSize, screen: CGSize?, upscaler: Upscaler,
                         hdrOutput: Bool) -> (image: CIImage, fallbackReason: String?) {
        guard let target = scale.targetSize(source: image.extent.size, screen: screen), target != image.extent.size else {
            return (image, nil)
        }
        let result = FrameUpscaler.resize(image, to: target, upscaler: upscaler, hdrOutput: hdrOutput, context: context)
        return (result.image, result.fallbackReason)
    }

    /// PNG bytes for the clipboard: upright, tone-mapped to 8-bit sRGB, enlarged like a saved frame.
    public func pngData(_ frame: DecodedFrame, rotationClockwise: Int, scale: OutputSize = 1, screen: CGSize? = nil,
                        upscaler: Upscaler = .lanczos, color: ColorCorrection = .identity,
                        geometry: DisplayGeometry = .identity) throws -> (data: Data, fallbackReason: String?) {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let upright = color.apply(to: geometry.applied(to: Self.image(for: frame, rotationClockwise: rotationClockwise, toneMapToSDR: true)))
        let result = resized(upright, scale: scale, screen: screen, upscaler: upscaler, hdrOutput: false)   // SDR: ML allowed
        guard let data = context.pngRepresentation(of: result.image, format: .RGBA8, colorSpace: sRGB, options: [:]) else {
            throw FrameImageRendererError.encodingFailed
        }
        return (data, result.fallbackReason)
    }

    @discardableResult
    public func write(_ frame: DecodedFrame, rotationClockwise: Int, format: ImageFormat, quality: Int,
                      scale: OutputSize = 1, screen: CGSize? = nil, upscaler: Upscaler = .lanczos,
                      color: ColorCorrection = .identity, geometry: DisplayGeometry = .identity, to url: URL) throws -> String? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let hdr = frame.dynamicRange != .sdr
        let fallback = hdr
            ? CGColorSpace(name: frame.dynamicRange == .pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG)!
            : sRGB
        // Non-JPEG output keeps the source's own colour space (from the buffer's attachments).
        let space = Self.colorSpace(of: frame.pixelBuffer) ?? fallback
        let lossy = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Double(quality) / 100]
        // Cropped and stretched like the screen (aspect spec), then coloured and resized.
        var image = color.apply(to: geometry.applied(to: Self.image(for: frame, rotationClockwise: rotationClockwise,
                                                                    toneMapToSDR: format == .jpeg)))
        var fallbackReason: String?
        // After rotation, before writing (spec §11.3). ML only for SDR files: the network is display-referred.
        let resized = resized(image, scale: scale, screen: screen, upscaler: upscaler, hdrOutput: hdr && format != .jpeg)
        image = resized.image
        fallbackReason = resized.fallbackReason
        switch format {
        case .jpeg:
            try context.writeJPEGRepresentation(of: image, to: url, colorSpace: sRGB, options: lossy)
        case .heic:
            try context.writeHEIF10Representation(of: image, to: url, colorSpace: space, options: lossy)
        case .png:
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA16, colorSpace: space, options: [:])
        case .tiff:
            try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: space, options: [:])
        }
        return fallbackReason
    }

    /// A small SDR sRGB picture for the seek-bar preview, fitted into a `width` x `width` box.
    public func thumbnail(for frame: DecodedFrame, rotationClockwise: Int, width: Int) -> CGImage? {
        let image = Self.image(for: frame, rotationClockwise: rotationClockwise, toneMapToSDR: true)
        let scale = Double(width) / max(image.extent.width, image.extent.height)
        let small = scale < 1 ? ImageScaling.lanczos(image, to: CGSize(width: max(1, (image.extent.width * scale).rounded()),
                                                                       height: max(1, (image.extent.height * scale).rounded()))) : image
        return context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
