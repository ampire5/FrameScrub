import CoreVideo
import Foundation

enum Fixtures {
    static let h264 = "h264_cfr_gop250.mp4"     // 1920x1080, 30 fps, 600 frames, keyframes 0/250/500
    static let hevc10 = "hevc10_hlg.mov"        // 3840x2160, 10-bit HLG, 120 frames, open GOP
    static let vfr = "h264_vfr.mp4"             // 1280x720, 120 frames, VFR (1/60 time base)
    static let av1 = "av1.mkv"                  // 1920x1080, 120 frames
    static let withAudio = "withaudio.mp4"      // 640x360, 25 fps, 4 s, AAC 48 kHz
    static let withAudioGOP25 = "withaudio_gop25.mp4"   // the same, keyframes 0/25/50/75
    static let withAudioGOP25MKV = "withaudio_gop25.mkv"   // the same in Matroska
    static let rotated = "rotated.mp4"          // withaudio.mp4 + display matrix (270 cw)
    static let audioLate = "audiolate.mp4"      // withaudio.mp4 with its audio starting ~2 s after the video
    static let audioLead = "audiolead.mp4"      // withaudio.mp4, fragmented, audio track first: audio read ~1 s ahead
    static let noDecoder = "nodecoder.nut"      // 320x200, 250 frames of a codec FFmpeg cannot decode
    static let fragmented = "h264_frag.mp4"     // h264_vfr.mp4 as fragmented MP4 (moof boxes)
    static let editList = "h264_editlist.mp4"   // h264_cfr_gop250.mp4 copied from 1 s: an edit list
    static let anamorphic = "anamorphic_letterbox.mp4"   // 720x576, SAR 64:45, 88-pixel bars top and bottom, 50 frames
    static let scenes = "scenes.mp4"            // 320x180, 175 frames, keyframes every 25; scenes at 0, 50 (black), 75, 125
    static let scenesMidGOP = "scenes_midgop.mp4"   // 320x180, 125 frames, keyframes 0/50/100; the cut at 60, inside a GOP
    static let layoutChange = "audio_layout_change.ts"   // 320x180, 25 fps, 4 s; AAC 48 kHz: 2 s stereo, then 2 s mono
    static let all = [h264, hevc10, vfr, av1, withAudio, rotated, audioLead, noDecoder, fragmented, editList, anamorphic, scenes, scenesMidGOP, layoutChange]

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FrameScrubCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        precondition(FileManager.default.fileExists(atPath: url.path),
                     "Missing fixture \(name). Run scripts/make-fixtures.sh first.")
        return url
    }
}

/// Reads the frame number drawn by scripts/make-fixtures.sh (bit i = 64x64 block at x = 64*i, y = 0).
func readFrameNumber(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let format = CVPixelBufferGetPixelFormatType(pb)
    let sixteenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let bits = min(16, CVPixelBufferGetWidthOfPlane(pb, 0) / 64)
    var number = 0
    for bit in 0..<bits {
        let offset = 32 * stride + (bit * 64 + 32) * (sixteenBit ? 2 : 1)
        let luma = sixteenBit
            ? Int(base.load(fromByteOffset: offset, as: UInt16.self) >> 8)
            : Int(base.load(fromByteOffset: offset, as: UInt8.self))
        if luma > 128 { number |= 1 << bit }
    }
    return number
}

/// Polls `condition` every 5 ms until it holds or `timeout` seconds pass.
func eventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@testable import FrameScrubCore

/// Opens a fixture and builds its exact index with a second demuxer.
func openIndexed(_ name: String) throws -> (MediaSource, FrameIndex) {
    let url = Fixtures.url(name)
    return (try MediaSource(url: url), try MediaSource(url: url).buildIndex())
}

import CoreGraphics
import ImageIO

func imageProperties(_ url: URL) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
    return properties
}

func rgbaPixels(imageAt url: URL) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? pixels : nil
}

/// Reads the fixture frame number from a saved image (top-left blocks, via an sRGB bitmap).
func readFrameNumber(imageAt url: URL, scale: Double = 1) -> Int? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
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
    for bit in 0..<min(16, Int(Double(width) / (64 * scale))) where pixels[(Int(32 * scale) * width + Int(Double(bit * 64 + 32) * scale)) * 4] > 128 {
        number |= 1 << bit
    }
    return number
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("framescrub-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
