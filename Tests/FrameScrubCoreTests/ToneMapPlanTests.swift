import CoreImage
import Testing
@testable import FrameScrubCore

@Suite struct ToneMapPlanTests {
    @Test func sdrContentIsNeverTouched() {
        for headroom in [1.0, 2.0, 16.0] {
            #expect(ToneMapPlan.resolve(range: .sdr, displayHeadroom: headroom) == .none)
        }
    }

    @Test func screensWithoutHeadroomGetSDR() {
        for range in [DynamicRange.hlg, .pq] {
            #expect(ToneMapPlan.resolve(range: range, displayHeadroom: 1.0) == .toSDR)
            #expect(ToneMapPlan.resolve(range: range, displayHeadroom: 1.05) == .toSDR)
        }
    }

    @Test func screensWithHeadroomGetItsValue() {
        #expect(ToneMapPlan.resolve(range: .hlg, displayHeadroom: 1.06) == .toHeadroom(1.06))
        #expect(ToneMapPlan.resolve(range: .pq, displayHeadroom: 4) == .toHeadroom(4))
    }

    /// Largest colour component of the rendered image in extended linear sRGB.
    private func peak(_ image: CIImage) -> Float {
        let context = CIContext()
        let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
        // 32-bit floats: Float16 is unavailable on Intel Macs (lts/macos26).
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: image.extent,
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return stride(from: 0, to: pixels.count, by: 4).map { (i: Int) -> Float in
            max(pixels[i], pixels[i + 1], pixels[i + 2])
        }.max() ?? 0
    }

    @Test func rendererHonoursThePlan() throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seek(toFrame: 10)
        let frame = try #require(try decoder.nextFrame())
        #expect(frame.dynamicRange == .hlg)
        let untouched = peak(FrameImageRenderer.displayImage(for: frame, rotationClockwise: 0, plan: .none))
        let sdr = peak(FrameImageRenderer.displayImage(for: frame, rotationClockwise: 0, plan: .toSDR))
        let limited = peak(FrameImageRenderer.displayImage(for: frame, rotationClockwise: 0, plan: .toHeadroom(1.5)))
        #expect(sdr <= 1.001)
        #expect(limited <= 1.5 + 0.01)
        #expect(untouched >= limited)
        #expect(untouched >= sdr)
    }
}
