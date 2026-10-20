import CFFmpeg
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct NALUnitsTests {
    /// Packets of a fixture in decode order with their parsed info.
    private func parsed(_ name: String) throws -> (sets: ParameterSets, units: [(pts: Int64, key: Bool, info: AccessUnitInfo)]) {
        let source = try MediaSource(url: Fixtures.url(name))
        let parameters = source.videoStream.pointee.codecpar.pointee
        let extradata = Data(bytes: parameters.extradata, count: Int(parameters.extradata_size))
        let family: VideoCodecFamily = parameters.codec_id == AV_CODEC_ID_HEVC ? .hevc : .h264
        let sets = try #require(ParameterSets.parse(extradata: extradata, family: family))
        var units: [(pts: Int64, key: Bool, info: AccessUnitInfo)] = []
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        while source.read(into: packet!) >= 0 {
            defer { av_packet_unref(packet) }
            let p = packet!.pointee
            guard p.stream_index == source.videoStreamIndex else { continue }
            let info = AccessUnitInfo.parse(UnsafeBufferPointer(start: p.data, count: Int(p.size)), parameterSets: sets)
            units.append((p.pts, p.flags & AV_PKT_FLAG_KEY != 0, info))
        }
        return (sets, units)
    }

    @Test func parsesAvcCAndHvcC() throws {
        let h264 = try parsed(Fixtures.h264).sets
        #expect(h264.family == .h264 && h264.nalLengthSize == 4 && h264.spsCount >= 1 && h264.ppsCount >= 1)
        let hevc = try parsed(Fixtures.hevc10).sets
        #expect(hevc.family == .hevc && hevc.nalLengthSize == 4 && !hevc.hevcPPS.isEmpty)
        #expect(ParameterSets.parse(extradata: Data([0, 0, 0, 1, 0x67]), family: .h264) == nil)   // Annex B
    }

    @Test(arguments: [Fixtures.h264, Fixtures.hevc10])
    func pictureTypesMatchFFmpeg(_ name: String) throws {
        let (source, index) = try openIndexed(name)
        let decoder = try VideoDecoder(source: source, index: index, preferHardware: false)
        var ffmpeg: [Int64: Character] = [:]
        while let frame = try decoder.nextFrame() { ffmpeg[frame.pts] = frame.pictureType }
        var mismatches: [String] = []
        for unit in try parsed(name).units {
            if unit.info.pictureType != ffmpeg[unit.pts] {
                mismatches.append("pts \(unit.pts): \(String(describing: unit.info.pictureType)) vs \(String(describing: ffmpeg[unit.pts]))")
            }
            if unit.info.isRandomAccess != unit.key { mismatches.append("pts \(unit.pts): random access \(unit.info.isRandomAccess)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    @Test func referenceFlagsAreConsistent() throws {
        let units = try parsed(Fixtures.h264).units
        #expect(units.filter { !$0.info.isReference }.count > 150)             // ~45 % of 600 are non-ref B
        #expect(units.allSatisfy { $0.info.isReference || $0.info.pictureType == "B" })
        #expect(units.filter(\.key).allSatisfy { $0.info.isRandomAccess && $0.info.isReference })
    }

    @Test func hevcOpenGOPHasLeadingPictures() throws {
        let units = try parsed(Fixtures.hevc10).units    // CRA at 60 followed by RASL in decode order
        #expect(units.contains { $0.info.isLeading })
    }
}
