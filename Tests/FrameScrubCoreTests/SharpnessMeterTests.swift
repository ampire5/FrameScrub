import CoreVideo
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct SharpnessMeterTests {
    /// Luma `value(x, y)` (0…255, rounded) as NV12 or P010; chroma is left as allocated.
    private func buffer(width: Int = 1280, height: Int = 720, tenBit: Bool = false,
                        _ value: (Int, Int) -> Double) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        CVPixelBufferCreate(nil, width, height, format, nil, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(min(255, max(0, value(x, y))).rounded())
                if tenBit {
                    base.advanced(by: y * stride + x * 2).assumingMemoryBound(to: UInt16.self).pointee = UInt16(v) << 8
                } else {
                    base.advanced(by: y * stride + x).assumingMemoryBound(to: UInt8.self).pointee = v
                }
            }
        }
        return buffer
    }

    private let checkerboard: (Int, Int) -> Double = { x, y in (x / 16 + y / 16) % 2 == 0 ? 40 : 215 }
    private let soft: (Int, Int) -> Double = { x, y in 127.5 + 87.5 * sin(Double(x) * .pi / 16) * sin(Double(y) * .pi / 16) }

    @Test func hardEdgesScoreFarAboveSoftOnes() throws {
        let sharp = try #require(SharpnessMeter.score(try buffer(checkerboard)))
        let blurred = try #require(SharpnessMeter.score(try buffer(soft)))
        #expect(sharp > 4 * blurred, "sharp \(sharp), soft \(blurred)")
    }

    @Test func motionBlurScoresFarBelowSharp() throws {
        // The checkerboard averaged over 9 px along x only: horizontal motion blur, vertical edges stay crisp.
        let checker = checkerboard
        let smeared: (Int, Int) -> Double = { x, y in (-4...4).map { checker(x + $0 + 64, y) }.reduce(0, +) / 9 }
        let sharp = try #require(SharpnessMeter.score(try buffer(checkerboard)))
        let moved = try #require(SharpnessMeter.score(try buffer(smeared)))
        #expect(moved < 0.3 * sharp, "sharp \(sharp), moved \(moved)")
    }

    @Test func detailDecidesNotTheBackground() throws {
        // A sharp quarter of the frame on a flat background scores like a frame sharp everywhere.
        let checker = checkerboard
        let patch: (Int, Int) -> Double = { x, y in x < 660 && y < 380 ? checker(x, y) : 128 }
        let sharp = try #require(SharpnessMeter.score(try buffer(checkerboard)))
        let partly = try #require(SharpnessMeter.score(try buffer(patch)))
        #expect(partly > 0.9 * sharp, "sharp \(sharp), quarter \(partly)")
    }

    @Test func flatFrameScoresZero() throws {
        let flat = try #require(SharpnessMeter.score(try buffer { _, _ in 128 }))
        #expect(flat < 0.01)
    }

    @Test func eightAndTenBitOfOnePictureScoreAlike() throws {
        let eight = try #require(SharpnessMeter.score(try buffer(checkerboard)))
        let ten = try #require(SharpnessMeter.score(try buffer(tenBit: true, checkerboard)))
        #expect(abs(eight - ten) / eight < 0.05, "8-bit \(eight), 10-bit \(ten)")
    }

    @Test func smallFrameIsMeasuredWithoutReduction() throws {
        let small = try #require(SharpnessMeter.score(try buffer(width: 320, height: 200, checkerboard)))
        #expect(small > 100)
    }

    @Test func otherPixelFormatsAreNotMeasured() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        #expect(SharpnessMeter.score(try #require(pb)) == nil)
    }

    @Test func decodedFixtureFramesAreMeasured() throws {
        for (name, n) in [(Fixtures.h264, 42), (Fixtures.hevc10, 10)] {
            let (source, index) = try openIndexed(name)
            let decoder = try VideoDecoder(source: source, index: index)
            try decoder.seek(toFrame: n)
            let frame = try #require(try decoder.nextFrame())
            let score = try #require(SharpnessMeter.score(frame.pixelBuffer), "\(name)")
            #expect(score > 0, "\(name)")
        }
    }
}
