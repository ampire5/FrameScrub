import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import FrameScrubCore

/// The decoding paths a test runs on: the own VideoToolbox session, FFmpeg's hwaccel, FFmpeg software.
enum Path: CaseIterable { case videoToolbox, ffmpegVideoToolbox, software }

extension Path {
    /// The paths worth running here. Under Rosetta (CI's x86_64 job) there is no hardware decoder, so both
    /// VideoToolbox paths would decode in software once more, tripling the slowest suite; an Intel Mac runs all three.
    static let testable: [Path] = runsUnderRosetta ? [.software] : allCases
}

func makeDecoder(_ source: MediaSource, _ index: FrameIndex, _ path: Path) throws -> VideoDecoder {
    try VideoDecoder(source: source, index: index, preferHardware: path != .software,
                     allowVideoToolboxBackend: path == .videoToolbox)
}

@Suite struct VideoDecoderTests {
    /// Reverse playback's reference-frames level seeks to a chunk start that may be a frame it then skips: landing past
    /// the target is expected then, not a bad seek to back off from (which decoded GOPs again and again: 15 s chunks).
    @Test(arguments: Path.testable)
    func skippingFromTheTargetDoesNotBackOff(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)   // keyframes 0/250/500, B-frames
        for n in 260...270 {
            let decoder = try makeDecoder(try MediaSource(url: source.url), index, path)
            decoder.skipNonReference(before: n + 20)
            try decoder.seek(toFrame: n)
            let frame = try decoder.nextFrame()
            #expect(frame.map { $0.number >= n && $0.number <= n + 20 } == true, "frame \(n): got \(String(describing: frame?.number))")
            #expect(decoder.framesSinceOpen < 120, "frame \(n): decoded \(decoder.framesSinceOpen) frames to get there")
        }
    }

    private func decodeAll(_ name: String, preferHardware: Bool = true) throws -> (VideoDecoder, [DecodedFrame]) {
        let (source, index) = try openIndexed(name)
        let decoder = try VideoDecoder(source: source, index: index, preferHardware: preferHardware)
        var frames: [DecodedFrame] = []
        while let frame = try decoder.nextFrame() { frames.append(frame) }
        return (decoder, frames)
    }

    @Test(arguments: [Fixtures.h264, Fixtures.hevc10, Fixtures.vfr, Fixtures.editList, Fixtures.fragmented], Path.testable)
    func decodesEveryFrameInOrder(_ name: String, _ path: Path) throws {
        let (source, index) = try openIndexed(name)
        let decoder = try makeDecoder(source, index, path)
        var frames: [DecodedFrame] = []
        while let frame = try decoder.nextFrame() { frames.append(frame) }
        let expectedCount = name == Fixtures.h264 ? 600 : name == Fixtures.editList ? index.frameCount : 120
        #expect(frames.map(\.number) == Array(0..<expectedCount))
        let shift = name == Fixtures.editList ? 30 : 0   // h264_editlist starts 1 s into h264_cfr_gop250
        for frame in frames { #expect(readFrameNumber(frame.pixelBuffer) == frame.number + shift) }
    }

    @Test func decodesEveryAV1Frame() throws {
        let (_, frames) = try decodeAll(Fixtures.av1)
        #expect(frames.map(\.number) == Array(0..<120))
        for frame in frames { #expect(readFrameNumber(frame.pixelBuffer) == frame.number) }
    }

    @Test(.disabled(if: runsUnderRosetta, "no hardware VideoToolbox decoder for x86_64 code under Rosetta")) func usesTheOwnVideoToolboxPathForH264AndHEVC() throws {
        let (h264, frames) = try decodeAll(Fixtures.h264)
        #expect(h264.backendKind == .videoToolbox && h264.isHardware)
        #expect(frames[0].dynamicRange == .sdr)
        #expect(frames[0].byteSize >= 1920 * 1080 * 3 / 2)
        let (hevc, _) = try decodeAll(Fixtures.hevc10)
        #expect(hevc.backendKind == .videoToolbox)
        let (source, index) = try openIndexed(Fixtures.av1)
        let av1 = try VideoDecoder(source: source, index: index)
        #expect(av1.backendKind == (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? .ffmpegVideoToolbox : .software))
        let (software, _) = try decodeAll(Fixtures.h264, preferHardware: false)
        #expect(software.backendKind == .software)
    }

    @Test(arguments: Path.testable)
    func reportsThePictureType(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try makeDecoder(source, index, path)
        var frames: [DecodedFrame] = []
        while let frame = try decoder.nextFrame() { frames.append(frame) }
        for keyframe in [0, 250, 500] { #expect(frames[keyframe].pictureType == "I") }
        let types = Set(frames.compactMap(\.pictureType))
        #expect(types.isSuperset(of: ["P", "B"]), "\(types)")
    }

    @Test(arguments: Path.testable)
    func reportsHLGAndTenBitForHEVC(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        let frame = try #require(try makeDecoder(source, index, path).nextFrame())
        #expect(frame.dynamicRange == .hlg)
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        #expect(format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    @Test func releasingWithFramesInFlightIsSafe() throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        for _ in 0..<50 {
            let decoder = try VideoDecoder(source: source, index: index)
            _ = try decoder.nextFrame()          // a few packets in flight behind it
        }                                        // released each time: must not crash
    }

    @Test func softwareDecodingProducesIdenticalNumbers() throws {
        let (decoder, frames) = try decodeAll(Fixtures.h264, preferHardware: false)
        #expect(!decoder.isHardware && decoder.backendKind == .software)
        #expect(frames.count == 600)
        for frame in frames.prefix(300) { #expect(readFrameNumber(frame.pixelBuffer) == frame.number) }
    }

    @Test func softwareAV1UsesDav1d() throws {
        let (decoder, frames) = try decodeAll(Fixtures.av1, preferHardware: false)
        #expect(decoder.codecName == "libdav1d")
        #expect(frames.map(\.number) == Array(0..<120))
    }

    @Test(arguments: Path.testable)
    func seeksExactlyAcrossBFramesAndGOPs(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try makeDecoder(source, index, path)
        for target in [0, 1, 249, 250, 251, 499, 37, 599, 300] {
            try decoder.seek(toFrame: target)
            let frame = try #require(try decoder.nextFrame())
            #expect(frame.number == target)
            #expect(readFrameNumber(frame.pixelBuffer) == target)
        }
    }

    @Test(arguments: Path.testable)
    func seeksExactlyInOpenGOPHEVC(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        let decoder = try makeDecoder(source, index, path)
        for target in [119, 60, 59, 58, 61, 0, 90] {
            try decoder.seek(toFrame: target)
            let frame = try #require(try decoder.nextFrame())
            #expect(frame.number == target, "target \(target)")
            #expect(readFrameNumber(frame.pixelBuffer) == target)
        }
    }

    @Test(arguments: Path.testable)
    func backsOffToEarlierKeyframeInOpenGOPWithApproximateIndex(_ path: Path) throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.hevc10))
        let decoder = try makeDecoder(source, source.approximateIndex(), path)
        for target in [57, 58, 59, 60] {
            try decoder.seek(toFrame: target)
            let frame = try #require(try decoder.nextFrame())
            #expect(frame.number == target, "target \(target)")
            #expect(readFrameNumber(frame.pixelBuffer) == target)
        }
    }

    /// The pre-roll from the keyframe to the target skips frames nothing refers to: they would be thrown away.
    @Test(arguments: Path.testable)
    func preRollSkipsNonReferenceFrames(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)   // keyframe 0; ~45 % of the frames are non-reference B
        let decoder = try makeDecoder(source, index, path)
        let before = decoder.framesSinceOpen
        try decoder.seek(toFrame: 240)
        for n in 240...260 {
            let frame = try #require(try decoder.nextFrame())
            #expect(frame.number == n)
            #expect(readFrameNumber(frame.pixelBuffer) == n)
        }
        let decoded = decoder.framesSinceOpen - before
        #expect(decoded < 200, "decoded \(decoded) frames to reach 240…260")   // 261 without skipping, ~161 with
    }

    /// A decoder catching up with a focus ahead of it skips the non-reference frames it has already been passed by.
    @Test(arguments: Path.testable)
    func catchingUpSkipsNonReferenceFramesBehindTheFocus(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try makeDecoder(source, index, path)
        try decoder.seek(toFrame: 0)
        _ = try decoder.nextFrame()
        decoder.skipNonReference(before: 100)
        var numbers: [Int] = []
        while let frame = try decoder.nextFrame(), frame.number < 110 {
            numbers.append(frame.number)
            #expect(readFrameNumber(frame.pixelBuffer) == frame.number)
        }
        #expect(numbers.filter { $0 < 100 }.count < 80)   // 99 without skipping
        #expect(Array(numbers.drop { $0 < 100 }) == Array(100..<110))
    }

    @Test(arguments: Path.testable)
    func continuesSequentiallyAfterSeek(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try makeDecoder(source, index, path)
        try decoder.seek(toFrame: 300)
        var numbers: [Int] = []
        for _ in 0..<5 { numbers.append(try #require(try decoder.nextFrame()).number) }
        #expect(numbers == [300, 301, 302, 303, 304])
    }

    @Test(arguments: Path.testable)
    func seeksWithApproximateIndex(_ path: Path) throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.h264))
        let decoder = try makeDecoder(source, source.approximateIndex(), path)
        try decoder.seek(toFrame: 420)
        let frame = try #require(try decoder.nextFrame())
        #expect(frame.number == 420)
        #expect(readFrameNumber(frame.pixelBuffer) == 420)
    }

    @Test(arguments: Path.testable)
    func directionalKeyframeSeekWithAnApproximateIndex(_ path: Path) throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.h264))
        let decoder = try makeDecoder(source, source.approximateIndex(), path)
        try decoder.seekToKeyframe(toward: 260, from: 100, direction: 1)
        #expect(try decoder.nextFrame()?.number == 500)   // keyframes 0/250/500: the first one after 260
        try decoder.seekToKeyframe(toward: 260, from: 400, direction: -1)
        #expect(try decoder.nextFrame()?.number == 250)
        try decoder.seekToKeyframe(toward: 590, from: 550, direction: 1)
        #expect(try decoder.nextFrame()?.number == 599)   // no keyframe after: the last frame
    }

    /// Seeking again while frames of the previous position are still in flight: a late one is never taken for a
    /// frame of the new position.
    @Test(arguments: Path.testable)
    func rapidSeeksNeverReturnAStaleFrame(_ path: Path) throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try makeDecoder(source, index, path)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            try decoder.seek(toFrame: Int.random(in: 0..<600, using: &rng))
            _ = try decoder.nextFrame()                     // leave packets in flight
            let target = Int.random(in: 0..<600, using: &rng)
            try decoder.seek(toFrame: target)
            let frame = try #require(try decoder.nextFrame())
            #expect(frame.number == target && readFrameNumber(frame.pixelBuffer) == target)
        }
    }

    /// The pre-roll before a seek target is decoded as reference only: the VideoToolbox session does not output it.
    @Test(.disabled(if: runsUnderRosetta, "no hardware VideoToolbox decoder for x86_64 code under Rosetta")) func preRollIsNotOutputByVideoToolbox() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try makeDecoder(source, index, .videoToolbox)
        let backend = try #require(decoder.backend as? VTBackend)
        try decoder.seek(toFrame: 240)
        #expect(try decoder.nextFrame()?.number == 240)
        #expect(backend.outputCount <= 1 + VTBackend.maxInFlight + 2, "\(backend.outputCount) frames output")
    }
}
