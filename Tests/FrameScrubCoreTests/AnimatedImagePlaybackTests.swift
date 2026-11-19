import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct AnimatedImagePlaybackTests {
    // Synthetic 4 × 2 animations. The blue frame blends at x=2 over red and then clears
    // its rectangle. The green frame blends at x=0. All three leave some pixels transparent.
    static let gif = "R0lGODlhBAACAPAAAAAAAP8AACH/C05FVFNDQVBFMi4wAwEDAAAh+QQFBwAAACwAAAAABAACAAACBEwAhgUAIfkECQ0AAAAsAgAAAAIAAgCAAAAAAAD/AgIMXAAh+QQFFAAAACwAAAAAAgACAIAAAAAA/wACAgxcADs="
    static let webP = "UklGRroAAABXRUJQVlA4WAoAAAASAAAAAwAAAQAAQU5JTQYAAAAAAAAAAwBBTk1GLgAAAAAAAAAAAAMAAAEAAEYAAABWUDhMFQAAAC8DQAAQDxDzH/MfDIUAAqCgieh/PABBTk1GKAAAAAEAAAAAAAEAAAEAAIIAAAFWUDhMEAAAAC8BQAAQDxAx//MfjIzofwBBTk1GKAAAAAAAAAAAAAEAAAEAAMgAAABWUDhMEAAAAC8BQAAQDzD/EfMfjIzofwA="

    @Test(arguments: [(gif, 4), (webP, 3)])
    func stepsAndSeeksUsingVariableFrameDurations(_ fixture: String, _ loops: Int) throws {
        let animation = try open(fixture)
        #expect(animation.frameCount == 3)
        #expect(animation.totalPlayCount == loops)
        #expect(animation.duration == 0.4)
        #expect(animation.currentFrame == nil)
        #expect(try animation.previous() == nil)

        let first = try #require(try animation.next())
        #expect(first.index == 0)
        #expect(first.seconds == 0)
        #expect(first.duration == 0.07)
        #expect(try animation.previous() == nil)
        #expect(try animation.seek(to: 0.069).index == 0)

        let second = try animation.seek(to: 0.07)
        #expect(second.index == 1)
        #expect(second.seconds == 0.07)
        #expect(second.duration == 0.13)
        #expect(try animation.seek(to: 0.07.nextDown).index == 0)
        #expect(try animation.seek(to: 0.2.nextDown).index == 1)

        #expect(try animation.seek(to: 0.2).index == 2)
        #expect(try animation.next() == nil)
        #expect(try animation.previous()?.index == 1)
        #expect(try animation.previous()?.index == 0)
        #expect(try animation.seek(to: 9).index == 2)
        #expect(try animation.seek(to: -3).index == 0)
    }

    @Test(arguments: [gif, webP])
    func compositesPartialFramesAndDisposalWithTransparency(_ fixture: String) throws {
        let animation = try open(fixture)
        let clear: [UInt8] = [0, 0, 0, 0]
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]

        // Start with a random access to the last frame, then step backward.
        let last = try animation.seek(to: 0.3)
        #expect(try firstRow(last.image) == green + red + clear + clear)
        let second = try #require(try animation.previous())
        #expect(try firstRow(second.image) == red + red + blue + clear)
        let first = try #require(try animation.previous())
        #expect(try firstRow(first.image) == red + red + clear + clear)
    }

    @Test func missingGIFLoopCountPlaysOnceAndZeroLoopsForever() throws {
        var gif = try #require(Data(base64Encoded: Self.gif))
        // Netscape extension starts at byte 19; its loop field counts repetitions after the initial play.
        gif[35] = 0
        #expect(try open(gif.base64EncodedString()).totalPlayCount == nil)

        gif.removeSubrange(19..<38)
        #expect(try open(gif.base64EncodedString()).totalPlayCount == 1)
    }

    @Test func zeroWebPLoopCountPlaysForever() throws {
        var webP = try #require(Data(base64Encoded: Self.webP))
        // The ANIM chunk contains a four-byte background followed by a two-byte loop count.
        webP[42] = 0
        #expect(try open(webP.base64EncodedString()).totalPlayCount == nil)
    }

    @Test func rejectsNonAnimations() throws {
        let staticGIF = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        #expect(throws: AnimatedImagePlayback.DecodingError.self) { try open(staticGIF) }
    }

    @Test func rejectsLargeEncodedFilesBeforeReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 65 * 1024 * 1024)
        try file.close()

        #expect(throws: AnimatedImagePlayback.DecodingError.encodedSizeLimit) {
            try AnimatedImagePlayback(source: FileByteSource(url: url))
        }
    }

    @Test func rejectsOversizeCanvasesBeforeDecoding() throws {
        var gif = try #require(Data(base64Encoded: Self.gif))
        // Widen the logical screen while leaving the individual image rectangles unchanged.
        gif.replaceSubrange(6..<10, with: [0, 32, 0, 32])
        #expect(throws: AnimatedImagePlayback.DecodingError.canvasSizeLimit) {
            try open(gif.base64EncodedString())
        }
    }

    @Test func streamedGIFKeepsTransparencyAndFrameOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(Data(base64Encoded: Self.gif)).write(to: url)
        let media = try OnDemandVideo(url: URL(fileURLWithPath: "/animation.gif"),
                                      source: FileByteSource(url: url), preferHardware: false)
        let first = try #require(try media.next())
        let buffer = first.pixelBuffer
        try #require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer))
            #expect(bytes.load(fromByteOffset: 3, as: UInt8.self) == 255)
            #expect(bytes.load(fromByteOffset: 15, as: UInt8.self) == 0)
        }
        let second = try #require(try media.next())
        #expect(media.time(of: second) == 0.07)
        #expect(try media.previous()?.pts == first.pts)
        #expect(try media.seek(to: 0.2).map(media.time(of:)) == 0.2)
    }

    @Test(arguments: [UInt8(0), UInt8(1)])
    func streamedGIFUsesTheDefaultOnlyForZeroDelay(_ delay: UInt8) throws {
        var gif = try #require(Data(base64Encoded: Self.gif))
        let firstControl = try #require(gif.range(of: Data([0x21, 0xf9, 0x04])))
        gif[firstControl.upperBound + 1] = delay
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try gif.write(to: url)
        let media = try OnDemandVideo(url: URL(fileURLWithPath: "/animation.gif"),
                                      source: FileByteSource(url: url), preferHardware: false)
        _ = try #require(try media.next())
        let second = try #require(try media.next())
        #expect(abs(media.time(of: second) - (delay == 0 ? 0.1 : 0.01)) < 1e-9)
    }

    private func open(_ fixture: String) throws -> AnimatedImagePlayback {
        let data = try #require(Data(base64Encoded: fixture))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let sender = try FileHandle(forReadingFrom: url)
        let source = try FileByteSource(duplicatingReadOnlyDescriptor: sender.fileDescriptor)
        try sender.close()
        try FileManager.default.removeItem(at: url)
        return try AnimatedImagePlayback(source: source)
    }

    private func firstRow(_ image: CGImage) throws -> [UInt8] {
        #expect(image.width == 4)
        #expect(image.height == 2)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * 4))
    }
}
