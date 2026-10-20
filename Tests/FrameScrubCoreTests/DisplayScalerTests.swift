import CoreImage
import Metal
import MetalFX
import Testing
@testable import FrameScrubCore

private let metalFXSupported = MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false

@Suite struct DisplayScalerTests {
    private let device: MTLDevice
    private let context: CIContext

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    private func run(_ scaler: DisplayScaler, _ image: CIImage, to size: CGSize, mode: ScaleMode = .auto,
                     sharpen: Double = 0, hdr: Bool = false) -> CIImage {
        let queue = device.makeCommandQueue()!
        let buffer = queue.makeCommandBuffer()!
        let result = scaler.scaled(image, to: size, mode: mode, sharpen: sharpen, hdr: hdr, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        return result
    }

    @Test(.enabled(if: metalFXSupported, "MetalFX is not supported on this GPU"))
    func upscaleUsesMetalFXAndKeepsOrientation() {
        let scaler = DisplayScaler(device: device, context: context)
        let out = run(scaler, markerImage(), to: CGSize(width: 128, height: 128))
        #expect(scaler.lastChoice == .metalFX)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 128, height: 128))
        let topLeft = samplePixel(out, x: 10, y: 10, context: context)
        let bottomLeft = samplePixel(out, x: 10, y: 118, context: context)
        #expect(topLeft[0] > 200 && topLeft[2] < 80)        // red stays on top
        #expect(bottomLeft[2] > 200 && bottomLeft[0] < 80)  // blue stays at the bottom
    }

    @Test(.enabled(if: metalFXSupported, "MetalFX is not supported on this GPU"))
    func hdrModeAlsoWorks() {
        let scaler = DisplayScaler(device: device, context: context)
        let out = run(scaler, markerImage(), to: CGSize(width: 128, height: 128), hdr: true)
        #expect(scaler.lastChoice == .metalFX)
        #expect(out.extent.size == CGSize(width: 128, height: 128))
    }

    @Test(.enabled(if: metalFXSupported, "MetalFX is not supported on this GPU"))
    func scalerIsReusedUntilTheSizeChanges() {
        let scaler = DisplayScaler(device: device, context: context)
        _ = run(scaler, markerImage(), to: CGSize(width: 128, height: 128))
        _ = run(scaler, markerImage(), to: CGSize(width: 128, height: 128))
        #expect(scaler.scalerCreations == 1)
        _ = run(scaler, markerImage(), to: CGSize(width: 192, height: 192))
        #expect(scaler.scalerCreations == 2)
        _ = run(scaler, markerImage(), to: CGSize(width: 192, height: 192), hdr: true)
        #expect(scaler.scalerCreations == 3)
    }

    @Test func downscaleUsesLanczos() {
        let scaler = DisplayScaler(device: device, context: context)
        let out = run(scaler, markerImage(), to: CGSize(width: 32, height: 32))
        #expect(scaler.lastChoice == .lanczos)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(scaler.statusText == "Scaling: Lanczos")
    }

    @Test func nearOneIsNotResampledWithAFilter() {
        let scaler = DisplayScaler(device: device, context: context)
        let out = run(scaler, markerImage(), to: CGSize(width: 64, height: 64))
        #expect(scaler.lastChoice == .none)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    @Test func withoutMetalFXUpscalingFallsBackToLanczosAndSaysWhy() {
        let scaler = DisplayScaler(device: device, context: context, allowMetalFX: false)
        let out = run(scaler, markerImage(), to: CGSize(width: 128, height: 128))
        #expect(scaler.lastChoice == .lanczos)
        #expect(scaler.statusText == "Scaling: Lanczos (MetalFX unavailable: disabled)")
        let topLeft = samplePixel(out, x: 10, y: 10, context: context)
        #expect(topLeft[0] > 200 && topLeft[2] < 80)
    }

    @Test func bilinearModeNeverUsesTheFilters() {
        let scaler = DisplayScaler(device: device, context: context)
        let out = run(scaler, markerImage(), to: CGSize(width: 128, height: 128), mode: .bilinear)
        #expect(scaler.lastChoice == .bilinear)
        #expect(out.extent.size == CGSize(width: 128, height: 128))
        #expect(scaler.scalerCreations == 0)
    }

    @Test func sharpeningOnlyAppliesWhenUpscaling() {
        let scaler = DisplayScaler(device: device, context: context, allowMetalFX: false)
        let edge = ImageScaling.origin(markerImage())
        let plain = run(scaler, edge, to: CGSize(width: 128, height: 128), sharpen: 0)
        let sharp = run(scaler, edge, to: CGSize(width: 128, height: 128), sharpen: 1)
        let across = (60...67).map { samplePixel(plain, x: $0, y: 20, context: context)[0] }
        let acrossSharp = (60...67).map { samplePixel(sharp, x: $0, y: 20, context: context)[0] }
        #expect(across != acrossSharp)
        let smallPlain = run(scaler, edge, to: CGSize(width: 32, height: 32), sharpen: 0)
        let smallSharp = run(scaler, edge, to: CGSize(width: 32, height: 32), sharpen: 1)
        #expect((0..<32).map { samplePixel(smallPlain, x: $0, y: 5, context: context) }
                == (0..<32).map { samplePixel(smallSharp, x: $0, y: 5, context: context) })
    }

    @Test func bilinearModeIsNeverSharpened() {
        let scaler = DisplayScaler(device: device, context: context)
        let edge = ImageScaling.origin(markerImage())
        let plain = run(scaler, edge, to: CGSize(width: 128, height: 128), mode: .bilinear, sharpen: 0)
        let sharp = run(scaler, edge, to: CGSize(width: 128, height: 128), mode: .bilinear, sharpen: 1)
        #expect((0..<128).map { samplePixel(plain, x: $0, y: 20, context: context) }
                == (0..<128).map { samplePixel(sharp, x: $0, y: 20, context: context) })
    }
}
