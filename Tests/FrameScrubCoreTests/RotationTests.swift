import CoreImage
import Foundation
import ImageIO
import Testing
@testable import FrameScrubCore

/// The display matrix turns every picture the same way FFmpeg and AVFoundation do. The fixtures' frame-number strip
/// (top edge of the coded picture) shows where the coded top-left corner ended up.
@Suite struct RotationTests {
    /// Fixture, clockwise turn, and where bit i of the strip lies in the upright 360x640 / 640x360 picture.
    /// Mirrored matrices are shown upright without the mirror.
    static let cases: [(String, Int)] = [(Fixtures.withAudio, 0), (Fixtures.rotated90, 90), (Fixtures.rotated180, 180),
                                         (Fixtures.rotated, 270), (Fixtures.hflip, 0), (Fixtures.hflipRotated, 270)]

    private static func bitCentre(_ bit: Int, rotation: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        let along = 64 * bit + 32
        switch rotation {
        case 90: return (width - 32, along)
        case 180: return (width - along, height - 32)
        case 270: return (32, height - along)
        default: return (along, 32)
        }
    }

    /// The frame number read from an upright picture turned `rotation` degrees clockwise.
    private static func frameNumber(_ image: CGImage, rotation: Int) -> Int? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var number = 0
        for bit in 0..<(max(width, height) / 64) {
            let (x, y) = bitCentre(bit, rotation: rotation, width: width, height: height)
            if pixels[(y * width + x) * 4] > 128 { number |= 1 << bit }
        }
        return number
    }

    private func decode(_ name: String, frame n: Int) throws -> (MediaSource, DecodedFrame) {
        let (source, index) = try openIndexed(name)
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seek(toFrame: n)
        return (source, try #require(try decoder.nextFrame()))
    }

    @Test(arguments: cases) func readsTheTurnFromTheDisplayMatrix(name: String, rotation: Int) throws {
        #expect(try MediaSource(url: Fixtures.url(name)).rotationClockwise == rotation)
    }

    @Test(arguments: cases) func savedFramesAreUpright(name: String, rotation: Int) throws {
        let (source, frame) = try decode(name, frame: 5)
        let url = makeTemporaryDirectory().appendingPathComponent("f.png")
        try FrameImageRenderer().write(frame, rotationClockwise: source.rotationClockwise, format: .png, quality: 90, to: url)
        let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(CGSize(width: image.width, height: image.height) == (rotation % 180 == 0 ? CGSize(width: 640, height: 360) : CGSize(width: 360, height: 640)))
        #expect(Self.frameNumber(image, rotation: rotation) == 5)
    }

    @Test(arguments: cases) func displayedPicturesAreUpright(name: String, rotation: Int) throws {
        let (source, frame) = try decode(name, frame: 9)
        let image = FrameImageRenderer.displayImage(for: frame, rotationClockwise: source.rotationClockwise, plan: .none)
        let cg = try #require(CIContext().createCGImage(image, from: image.extent))
        #expect(Self.frameNumber(cg, rotation: rotation) == 9)
    }

    @Test func homeThumbnailsAreUpright() throws {
        let result = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.rotated180), at: 0))
        let cg = try #require(CIContext().createCGImage(result.picture, from: result.picture.extent))
        #expect(cg.width == 640 && cg.height == 360)
        #expect(Self.frameNumber(cg, rotation: 180) == 0)
    }
}
