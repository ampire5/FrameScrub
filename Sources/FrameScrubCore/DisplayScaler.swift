import CoreImage
import Metal
import MetalFX

/// Scales the upright source image to its fitted on-screen size. Core Image output goes into
/// a MetalFX spatial scaler (upscaling) or a Lanczos filter (downscaling and fallback); the
/// MetalFX scaler and its textures are kept until a size or colour mode changes.
public final class DisplayScaler {
    public private(set) var lastChoice = ScalerChoice.none
    /// Why MetalFX is not in use (nil while it is).
    public private(set) var metalFXUnavailableReason: String?
    /// How many MetalFX scalers were created (they are expensive; a steady picture creates one).
    public private(set) var scalerCreations = 0

    private let device: MTLDevice
    private let context: CIContext
    private var current: (scaler: MTLFXSpatialScaler, key: Key, input: MTLTexture, output: MTLTexture)?

    private struct Key: Equatable { var inW: Int, inH: Int, outW: Int, outH: Int, hdr: Bool }

    private static let gammaSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    public init(device: MTLDevice, context: CIContext, allowMetalFX: Bool = true) {
        self.device = device
        self.context = context
        if !allowMetalFX {
            metalFXUnavailableReason = "disabled"
        } else if !MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            metalFXUnavailableReason = "not supported by this GPU"
        }
    }

    /// `image` must have its extent origin at (0, 0). Work is encoded into `commandBuffer`; the
    /// returned image is only valid once that buffer has run, and is composed into the same buffer.
    public func scaled(_ image: CIImage, to size: CGSize, mode: ScaleMode, sharpen: Double, hdr: Bool,
                       commandBuffer: MTLCommandBuffer) -> CIImage {
        let ratio = Double(size.width / image.extent.width)
        var choice = ScalerChoice.choose(mode: mode, ratio: ratio, metalFXAvailable: metalFXUnavailableReason == nil)
        var result = image
        switch choice {
        case .none, .bilinear:
            result = image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width,
                                                              y: size.height / image.extent.height))
        case .lanczos:
            result = ImageScaling.lanczos(image, to: size)
        case .metalFX:
            if let scaled = encodeMetalFX(image, to: size, hdr: hdr, commandBuffer: commandBuffer) {
                result = scaled
            } else {
                choice = .lanczos
                result = ImageScaling.lanczos(image, to: size)
            }
        }
        if choice != .bilinear, ratio > ScalerChoice.neutralBand.upperBound { result = ImageScaling.sharpened(result, amount: sharpen) }
        lastChoice = choice
        return result
    }

    /// One line for the stats overlay.
    public var statusText: String {
        switch lastChoice {
        case .none: return "Scaling: none"
        case .bilinear: return "Scaling: bilinear"
        case .lanczos:
            return "Scaling: Lanczos" + (metalFXUnavailableReason.map { " (MetalFX unavailable: \($0))" } ?? "")
        case .metalFX: return "Scaling: MetalFX"
        }
    }

    private func encodeMetalFX(_ image: CIImage, to size: CGSize, hdr: Bool, commandBuffer: MTLCommandBuffer) -> CIImage? {
        let key = Key(inW: Int(image.extent.width.rounded()), inH: Int(image.extent.height.rounded()),
                      outW: Int(size.width.rounded()), outH: Int(size.height.rounded()), hdr: hdr)
        if current?.key != key {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = key.inW
            descriptor.inputHeight = key.inH
            descriptor.outputWidth = key.outW
            descriptor.outputHeight = key.outH
            descriptor.colorTextureFormat = .rgba16Float
            descriptor.outputTextureFormat = .rgba16Float
            descriptor.colorProcessingMode = hdr ? .hdr : .perceptual
            guard let scaler = descriptor.makeSpatialScaler(device: device),
                  let input = makeTexture(width: key.inW, height: key.inH),
                  let output = makeTexture(width: key.outW, height: key.outH) else {
                metalFXUnavailableReason = "scaler creation failed"
                current = nil
                return nil
            }
            current = (scaler, key, input, output)
            scalerCreations += 1
        }
        guard let current else { return nil }
        let destination = CIRenderDestination(mtlTexture: current.input, commandBuffer: commandBuffer)
        destination.colorSpace = hdr ? Self.linearSpace : Self.gammaSpace
        guard (try? context.startTask(toRender: image, to: destination)) != nil else { return nil }
        current.scaler.colorTexture = current.input
        current.scaler.outputTexture = current.output
        current.scaler.inputContentWidth = key.inW
        current.scaler.inputContentHeight = key.inH
        current.scaler.encode(commandBuffer: commandBuffer)
        guard let result = CIImage(mtlTexture: current.output,
                                   options: [.colorSpace: hdr ? Self.linearSpace : Self.gammaSpace]) else { return nil }
        return ImageScaling.origin(result)   // upright as read back: no extra orientation (verified)
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}
