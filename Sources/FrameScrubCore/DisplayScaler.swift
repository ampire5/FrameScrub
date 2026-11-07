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
    private let artifactRenderer: ArtifactFilterRenderer
    private let preRenderer: ArtifactFilterRenderer
    private let grainRenderer: PerceptualGrainRenderer
    private var grainComparisonInput: MTLTexture?
    private var grainComparisonAllocations = 0
    var comparisonAllocationCount: Int { grainComparisonAllocations + artifactRenderer.scratchAllocations }
    public private(set) var grainUsesFusedPass = false
    public var grainScratchBytes: Int { grainRenderer.allocatedBytes + (grainComparisonInput?.allocatedSize ?? 0) }
    private var artifactInput: MTLTexture?
    private var artifactOutput: MTLTexture?
    private var comparisonInput: MTLTexture?
    public var artifactScratchBytes: Int { preRenderer.allocatedBytes + artifactRenderer.allocatedBytes + grainScratchBytes }
    public private(set) var artifactStatus = "Filters: off"
    private var current: (scaler: MTLFXSpatialScaler, key: Key, input: MTLTexture, output: MTLTexture)?

    private struct Key: Equatable { var inW: Int, inH: Int, outW: Int, outH: Int, hdr: Bool }

    private static let gammaSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    public init(device: MTLDevice, context: CIContext, allowMetalFX: Bool = true) {
        self.device = device
        self.context = context
        artifactRenderer = ArtifactFilterRenderer(device: device)
        preRenderer = ArtifactFilterRenderer(device: device)
        grainRenderer = PerceptualGrainRenderer(device: device)
        if !allowMetalFX {
            metalFXUnavailableReason = "disabled"
        } else if !MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            metalFXUnavailableReason = "not supported by this GPU"
        }
    }

    /// `image` must have its extent origin at (0, 0). Work is encoded into `commandBuffer`; the
    /// returned image is only valid once that buffer has run, and is composed into the same buffer.
    public func scaled(_ image: CIImage, to size: CGSize, mode: ScaleMode, sharpen: Double, hdr: Bool, artifactSettings: ArtifactFilterSettings = .init(),
                       artifactPipelines: ArtifactFilterPipelines? = nil, grainSeed: UInt32 = 0, commandBuffer: MTLCommandBuffer) -> CIImage {
        let ratio = Double(size.width / image.extent.width)
        var choice = ScalerChoice.choose(mode: mode, ratio: ratio, metalFXAvailable: metalFXUnavailableReason == nil)
        if choice == .metalFX && !prepareMetalFX(image, to: size, hdr: hdr) { choice = .lanczos }
        artifactStatus = artifactSettings.summary
        let active = artifactSettings.applies(hdr: hdr) && artifactPipelines != nil
        var pre = artifactSettings, post = artifactSettings
        pre.grain = .off; post.grain = .off
        pre.antiring = .off; pre.dither = 0; pre.comparison = .processed
        post.deband = .off; post.chroma = .off; post.comparison = .processed
        let wantsGrain = active && artifactSettings.grain != .off && artifactSettings.grainAmount > 0
        if !wantsGrain { grainRenderer.clear(); grainComparisonInput = nil }
        grainUsesFusedPass = false
        var grainMaskReady = false, didSharpen = false
        var workingImage = image
        var preparedInput: MTLTexture?
        var failure: String?
        if active && (pre.active || wantsGrain), let artifactPipelines {
            let input: MTLTexture?
            if choice == .metalFX { input = current?.input; artifactInput = nil }
            else {
                if artifactInput?.width != Int(image.extent.width) || artifactInput?.height != Int(image.extent.height) {
                    artifactInput = makeTexture(width: Int(image.extent.width), height: Int(image.extent.height))
                }
                input = artifactInput
            }
            if let input, render(image, into: input, hdr: false, commandBuffer: commandBuffer) {
                let output = preRenderer.encode(input, source: nil, settings: pre, hdr: false, pipelines: artifactPipelines, commandBuffer: commandBuffer)
                if wantsGrain {
                    grainMaskReady = grainRenderer.prepareMask(original: input, cleaned: output, settings: artifactSettings, pipelines: artifactPipelines, commandBuffer: commandBuffer)
                    if !grainMaskReady { failure = grainRenderer.status }
                }
                if preRenderer.status.contains("failed") { failure = preRenderer.status }
                if let filtered = CIImage(mtlTexture: output, options: [.colorSpace: Self.gammaSpace]) {
                    preparedInput = output; workingImage = ImageScaling.origin(filtered)
                } else { failure = "Filters: source image failed" }
            } else { failure = "Filters: source allocation/render failed" }
        } else { artifactInput = nil; preRenderer.clear() }
        var result: CIImage
        switch choice {
        case .metalFX:
            if let output = encodeMetalFX(workingImage, to: size, hdr: hdr, preparedInput: preparedInput, commandBuffer: commandBuffer) { result = output }
            else { choice = .lanczos; result = ImageScaling.lanczos(workingImage, to: size) }
        case .lanczos: result = ImageScaling.lanczos(workingImage, to: size)
        case .none, .bilinear:
            result = workingImage.transformed(by: CGAffineTransform(scaleX: size.width / workingImage.extent.width, y: size.height / workingImage.extent.height))
        }
        let compare = active && [.split, .changes].contains(artifactSettings.comparison)
        if !post.active && !compare { artifactRenderer.clear() }
        if active && (post.active || compare || wantsGrain), let artifactPipelines {
            let scaledInput: MTLTexture?
            if choice == .metalFX { scaledInput = current?.output; artifactOutput = nil }
            else {
                if artifactOutput?.width != Int(size.width) || artifactOutput?.height != Int(size.height) { artifactOutput = makeTexture(width: Int(size.width), height: Int(size.height)) }
                if let output = artifactOutput, render(result, into: output, hdr: false, commandBuffer: commandBuffer) { scaledInput = output }
                else { scaledInput = nil }
            }
            if let scaledInput {
                var output = scaledInput
                let canFuse = wantsGrain && grainMaskReady && choice == .metalFX &&
                    [.luma,.edge].contains(post.antiring) && post.antiringStrength > 0 && post.dither == 0 && sharpen == 0
                if canFuse, let source = preparedInput ?? current?.input, let target = artifactRenderer.reusableTarget(for: scaledInput),
                   grainRenderer.encodeFusedAntiring(source: source, input: scaledInput, target: target, settings: artifactSettings, seed: grainSeed, pipelines: artifactPipelines, commandBuffer: commandBuffer) {
                    output = target; grainUsesFusedPass = true
                } else if post.active {
                    output = artifactRenderer.encode(scaledInput, source: choice == .metalFX ? (preparedInput ?? current?.input) : nil,
                        settings: post, hdr: false, pipelines: artifactPipelines, commandBuffer: commandBuffer)
                }
                if wantsGrain && grainMaskReady && !grainUsesFusedPass {
                    if choice != .bilinear, ratio > ScalerChoice.neutralBand.upperBound, sharpen > 0 {
                        if let staged = grainRenderer.staging(width: output.width, height: output.height),
                           let im = CIImage(mtlTexture: output, options: [.colorSpace: Self.gammaSpace]),
                           render(ImageScaling.sharpened(ImageScaling.origin(im), amount: sharpen), into: staged, hdr: false, commandBuffer: commandBuffer) {
                            output = staged; didSharpen = true
                        } else { failure = "Filters: grain sharpen staging failed" }
                    }
                    if failure == nil {
                        output = grainRenderer.encode(output, settings: artifactSettings, seed: grainSeed, pipelines: artifactPipelines, commandBuffer: commandBuffer)
                        if grainRenderer.status.contains("failed") { failure = grainRenderer.status }
                    }
                }
                var final = output
                if !grainUsesFusedPass && post.active && artifactRenderer.status.contains("failed") { failure = artifactRenderer.status }
                if compare {
                    var baseline: MTLTexture? = scaledInput
                    if pre.active && preparedInput != nil {
                        if comparisonInput?.width != Int(size.width) || comparisonInput?.height != Int(size.height) { comparisonInput = makeTexture(width: Int(size.width), height: Int(size.height)) }
                        baseline = comparisonInput
                        if let baseline {
                            if choice == .metalFX, let current {
                                // The original input was retained; this second upscale is comparison-only.
                                current.scaler.colorTexture = current.input; current.scaler.outputTexture = baseline
                                current.scaler.encode(commandBuffer: commandBuffer)
                            } else {
                                let original = choice == .lanczos ? ImageScaling.lanczos(image, to: size) : image.transformed(by: CGAffineTransform(scaleX: size.width/image.extent.width, y: size.height/image.extent.height))
                                if !render(original, into: baseline, hdr: false, commandBuffer: commandBuffer) { failure = "Filters: comparison render failed" }
                            }
                        }
                    } else { comparisonInput = nil }
                    if didSharpen, let unsharpened = baseline {
                        if grainComparisonInput?.width != unsharpened.width || grainComparisonInput?.height != unsharpened.height {
                            grainComparisonInput = makeTexture(width: unsharpened.width, height: unsharpened.height)
                            grainComparisonAllocations += 1
                        }
                        if let target = grainComparisonInput,
                           let im = CIImage(mtlTexture: unsharpened, options: [.colorSpace: Self.gammaSpace]),
                           render(ImageScaling.sharpened(ImageScaling.origin(im), amount: sharpen), into: target, hdr: false, commandBuffer: commandBuffer) {
                            baseline = target
                        } else { failure = "Filters: grain comparison staging failed" }
                    } else { grainComparisonInput = nil }
                    if let baseline, failure == nil {
                        final = artifactRenderer.encodeComparison(original: baseline, processed: output, comparison: artifactSettings.comparison, pipelines: artifactPipelines, commandBuffer: commandBuffer)
                        if artifactRenderer.status.contains("failed") { failure = artifactRenderer.status }
                    } else { failure = failure ?? "Filters: comparison allocation failed" }
                } else { comparisonInput = nil; grainComparisonInput = nil }
                if let outputImage = CIImage(mtlTexture: final, options: [.colorSpace: Self.gammaSpace]) { result = ImageScaling.origin(outputImage) }
            } else { failure = "Filters: output allocation/render failed" }
        } else { artifactOutput = nil; comparisonInput = nil; artifactRenderer.clear() }
        if hdr && artifactSettings.active { artifactStatus = "Filters: HDR bypass" }
        else if artifactSettings.applies(hdr: false) && artifactPipelines == nil { artifactStatus = "Filters: preparing" }
        else if let failure { artifactStatus = failure }
        else if active {
            artifactStatus = artifactSettings.summary + (pre.active ? "; cleanup before scale" : "")
            if choice != .metalFX && [.luma,.edge].contains(post.antiring) { artifactStatus += "; AR needs MetalFX" }
        }
        if !didSharpen, choice != .bilinear, ratio > ScalerChoice.neutralBand.upperBound { result = ImageScaling.sharpened(result, amount: sharpen) }
        lastChoice = choice
        return result
    }

    private func render(_ image: CIImage, into texture: MTLTexture, hdr: Bool, commandBuffer: MTLCommandBuffer) -> Bool {
        let target = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        target.colorSpace = hdr ? Self.linearSpace : Self.gammaSpace
        return (try? context.startTask(toRender: image, to: target)) != nil
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

    private func prepareMetalFX(_ image: CIImage, to size: CGSize, hdr: Bool) -> Bool {
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
                return false
            }
            current = (scaler, key, input, output)
            scalerCreations += 1
        }
        return current != nil
    }

    private func encodeMetalFX(_ image: CIImage, to size: CGSize, hdr: Bool, preparedInput: MTLTexture?, commandBuffer: MTLCommandBuffer) -> CIImage? {
        guard prepareMetalFX(image, to: size, hdr: hdr) else { return nil }
        guard let current else { return nil }
        if preparedInput == nil && !render(image, into: current.input, hdr: hdr, commandBuffer: commandBuffer) { return nil }
        current.scaler.colorTexture = preparedInput ?? current.input
        current.scaler.outputTexture = current.output
        current.scaler.inputContentWidth = current.key.inW
        current.scaler.inputContentHeight = current.key.inH
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
