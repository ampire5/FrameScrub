import CFFmpeg
import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import FrameScrubCore

@Suite struct VTBackendTests {
    /// Decodes `range` with `decoder` and checks every number, in the index and in the picture.
    private func expectExact(_ decoder: VideoDecoder, _ range: Range<Int>) throws {
        for n in range {
            let frame = try #require(try decoder.nextFrame())
            #expect(frame.number == n)
            #expect(readFrameNumber(frame.pixelBuffer) == n)
        }
    }

    @Test func sessionCreationFailureFallsBackToSoftware() throws {
        try VTBackend.$makeSessionOverride.withValue({ _ in throw BackendError.fatal(FFmpegError(-1, "test")) }) {
            let (source, index) = try openIndexed(Fixtures.h264)
            let decoder = try VideoDecoder(source: source, index: index)
            #expect(decoder.backendKind == .software)
            #expect(try decoder.nextFrame()?.number == 0)
        }
    }

    @Test func lostSessionIsRecreatedAndResumesExactly() throws {
        let injection = VTBackend.StatusInjection()
        try VTBackend.$injection.withValue(injection) {
            let (source, index) = try openIndexed(Fixtures.h264)
            let decoder = try VideoDecoder(source: source, index: index)
            try expectExact(decoder, 0..<100)
            let first = try #require(decoder.backend as? VTBackend)
            injection.statuses = [kVTInvalidSessionErr]
            try expectExact(decoder, 100..<200)
            #expect(decoder.backendKind == .videoToolbox)
            #expect(decoder.backend !== first)
        }
    }

    @Test func secondSessionLossFallsBackToSoftwareExactly() throws {
        let injection = VTBackend.StatusInjection()
        try VTBackend.$injection.withValue(injection) {
            let (source, index) = try openIndexed(Fixtures.h264)
            let decoder = try VideoDecoder(source: source, index: index)
            try expectExact(decoder, 0..<100)
            injection.statuses = [kVTInvalidSessionErr, kVTVideoDecoderMalfunctionErr]   // the second on the new session
            try expectExact(decoder, 100..<200)
            #expect(decoder.backendKind == .software)
        }
    }

    @Test func corruptFramesThreeInARowFallBackToSoftware() throws {
        let injection = VTBackend.StatusInjection()
        try VTBackend.$injection.withValue(injection) {
            let (source, index) = try openIndexed(Fixtures.h264)
            let decoder = try VideoDecoder(source: source, index: index)
            try expectExact(decoder, 0..<11)
            injection.statuses = [kVTVideoDecoderBadDataErr, kVTVideoDecoderBadDataErr, kVTVideoDecoderBadDataErr]
            try expectExact(decoder, 11..<100)
            #expect(decoder.backendKind == .software)
        }
    }

    /// Parameter sets repeated in a packet's side data at an IDR (as muxers do at a resolution or profile change).
    @Test func followsNewExtradataInSideData() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let backend = try VTBackend(stream: source.videoStream)
        let parameters = source.videoStream.pointee.codecpar.pointee
        let packet = av_packet_alloc()!
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        var numbers: [Int] = []
        func take() throws {
            while case .frame(let frame) = try backend.receive() {
                numbers.append(index.frameNumber(forPTS: frame.pts))
                #expect(readFrameNumber(frame.pixelBuffer) == numbers.last)
            }
        }
        while source.read(into: packet) >= 0 {
            defer { av_packet_unref(packet) }
            if packet.pointee.flags & AV_PKT_FLAG_KEY != 0 && packet.pointee.pts > index.pts(forFrame: 0) {
                let side = av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, Int(parameters.extradata_size))!
                side.update(from: parameters.extradata, count: Int(parameters.extradata_size))
                backend.forceNewSessionOnNextFormat = true
            }
            try backend.send(packet, output: true, mayDrop: false)
            try take()
        }
        try backend.drain()
        try take()
        #expect(numbers == Array(0..<600))
        #expect(backend.sessionsCreated == 3)   // at 250 and 500
    }

    /// Spec §3.2: the format description carries the stream's colour, full range included.
    @Test func formatExtensionsCarryFullRange() throws {
        var parameters = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parameters) }
        let p = try #require(parameters)
        p.pointee.height = 2160
        p.pointee.color_range = AVCOL_RANGE_JPEG
        #expect(ColorAttachments.formatExtensions(p)[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool == true)
        p.pointee.color_range = AVCOL_RANGE_MPEG
        #expect(ColorAttachments.formatExtensions(p)[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool == false)
    }

    /// A VideoToolbox session's pool keeps as many buffers as were ever out at once (measured 2026-10-15).
    @Test func poolSurplusCountsHardwareFramesGivenUp() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try VideoDecoder(source: source, index: index)
        #expect(decoder.backendKind == .videoToolbox)
        var kept: [DecodedFrame] = []
        for _ in 0..<40 { kept.append(try autoreleasepool { try #require(try decoder.nextFrame()) }) }
        #expect(decoder.poolSurplus == 0)
        kept.removeLast(30)
        #expect(decoder.poolSurplus == 30)
        kept.append(try autoreleasepool { try #require(try decoder.nextFrame()) })   // reuses one of them
        #expect(decoder.poolSurplus == 29)
        kept.removeAll()
        #expect(decoder.poolSurplus == 40)
    }

    @Test func softwareDecoderHasNoPoolSurplus() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try VideoDecoder(source: source, index: index, preferHardware: false)
        var kept: [DecodedFrame] = []
        for _ in 0..<10 { kept.append(try autoreleasepool { try #require(try decoder.nextFrame()) }) }
        kept.removeAll()
        #expect(decoder.poolSurplus == 0)
    }
}
