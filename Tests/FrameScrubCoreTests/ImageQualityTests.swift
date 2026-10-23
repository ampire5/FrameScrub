import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import FrameScrubCore

/// The VideoToolbox paths against FFmpeg's software decoder on the same frames: decoded planes, colour metadata,
/// the picture as shown, and the automatic colour correction computed from it.
@Suite struct ImageQualityTests {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private struct PlaneDifference { var bytes = 0, differing = 0, maximum = 0 }

    /// Byte differences over both planes (16-bit samples for P010).
    private func planeDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> PlaneDifference {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let wide = CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        var result = PlaneDifference()
        for plane in 0..<2 {
            let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!, pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
            let sa = CVPixelBufferGetBytesPerRowOfPlane(a, plane), sb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            let samples = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 0 ? 1 : 2)   // Cb and Cr interleaved
            for row in 0..<CVPixelBufferGetHeightOfPlane(a, plane) {
                result.bytes += samples
                if memcmp(pa + row * sa, pb + row * sb, samples * (wide ? 2 : 1)) == 0 { continue }
                for i in 0..<samples {
                    let x = wide ? Int(pa.load(fromByteOffset: row * sa + i * 2, as: UInt16.self) >> 6)
                                 : Int(pa.load(fromByteOffset: row * sa + i, as: UInt8.self))
                    let y = wide ? Int(pb.load(fromByteOffset: row * sb + i * 2, as: UInt16.self) >> 6)
                                 : Int(pb.load(fromByteOffset: row * sb + i, as: UInt8.self))
                    if x != y {
                        result.differing += 1
                        result.maximum = max(result.maximum, abs(x - y))
                    }
                }
            }
        }
        return result
    }

    /// The picture as the player shows it in SDR, as sRGB bytes, at most 960 wide (the planes are compared in full).
    private func shown(_ frame: DecodedFrame) -> (image: CIImage, pixels: [UInt8]) {
        let full = FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: true)
        let scale = min(1, 960 / full.extent.width)
        let image = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        Self.context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (image, pixels)
    }

    private func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0
        for i in a.indices where i % 4 != 3 { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count / 4 * 3)
    }

    private func attachments(_ pb: CVPixelBuffer) -> [String] {
        [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey].map {
            (CVBufferCopyAttachment(pb, $0, nil) as? String) ?? "none"
        }
    }

    private func frame(_ decoder: VideoDecoder, _ n: Int) throws -> DecodedFrame {
        try decoder.seek(toFrame: n)
        return try #require(try decoder.nextFrame())
    }

    private func compare(source: () throws -> MediaSource, index: FrameIndex, frames: [Int], path: Path) throws {
        let reference = try makeDecoder(source(), index, .software)
        let tested = try makeDecoder(source(), index, path)
        for n in frames {
            let a = try frame(reference, n), b = try frame(tested, n)
            #expect(b.number == n && a.number == n)
            #expect(CVPixelBufferGetPixelFormatType(a.pixelBuffer) == CVPixelBufferGetPixelFormatType(b.pixelBuffer))
            #expect(a.dynamicRange == b.dynamicRange, "frame \(n)")
            #expect(attachments(a.pixelBuffer) == attachments(b.pixelBuffer), "frame \(n)")

            let planes = planeDifference(a.pixelBuffer, b.pixelBuffer)
            #expect(planes.differing == 0, "frame \(n): \(planes.differing) of \(planes.bytes) samples differ, by up to \(planes.maximum)")

            let (imageA, pixelsA) = shown(a), (imageB, pixelsB) = shown(b)
            let shownDifference = meanAbsoluteDifference(pixelsA, pixelsB)
            #expect(shownDifference < 0.05, "frame \(n): shown pictures differ by \(shownDifference) on average")

            let analysisA = ColorCorrection.analyse(imageA), analysisB = ColorCorrection.analyse(imageB)
            #expect(analysisA.steps.map(\.name) == analysisB.steps.map(\.name), "frame \(n)")
            #expect(abs(analysisA.delta - analysisB.delta) < 0.05, "frame \(n): Δ \(analysisA.delta) vs \(analysisB.delta)")
            let corrections = ColorCorrection(vibrance: 0.5, auto: analysisA.steps)
            var outA = [UInt8](repeating: 0, count: pixelsA.count), outB = outA
            let width = Int(imageA.extent.width) * 4
            Self.context.render(corrections.apply(to: imageA), toBitmap: &outA, rowBytes: width, bounds: imageA.extent,
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            Self.context.render(corrections.apply(to: imageB), toBitmap: &outB, rowBytes: width, bounds: imageB.extent,
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            #expect(meanAbsoluteDifference(outA, outB) < 0.05, "frame \(n): corrected pictures differ")
            let changedA = meanAbsoluteDifference(outA, pixelsA), changedB = meanAbsoluteDifference(outB, pixelsB)
            #expect(abs(changedA - changedB) < 0.05, "frame \(n): the correction changes \(changedB) against \(changedA)")
        }
    }

    @Test(.disabled(if: isVirtualMachine, "a VM's paravirtual VideoToolbox decodes to other pixels"),
          .disabled(if: runsUnderRosetta, "no hardware VideoToolbox decoder for x86_64 code under Rosetta"),
          arguments: [Fixtures.h264, Fixtures.hevc10], [Path.videoToolbox, Path.ffmpegVideoToolbox])
    func matchesSoftwareDecoding(_ name: String, _ path: Path) throws {
        let (_, index) = try openIndexed(name)
        let frames = name == Fixtures.h264 ? [0, 37, 251, 599] : [0, 59, 61, 119]
        try compare(source: { try MediaSource(url: Fixtures.url(name)) }, index: index, frames: frames, path: path)
    }

    /// FRAMESCRUB_PERF=1 FRAMESCRUB_PERF_FILE=… swift test --filter realFileMatchesSoftwareDecoding
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF"] != nil
                   && ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFileMatchesSoftwareDecoding() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"]!)
        let index = try MediaSource.containerIndex(url: url, readCache: nil) ?? MediaSource(url: url).buildIndex()
        let frames = [0.1, 0.3, 0.5, 0.7].map { Int(Double(index.frameCount) * $0) }
        try compare(source: { try MediaSource(url: url) }, index: index, frames: frames, path: .videoToolbox)
    }
}
