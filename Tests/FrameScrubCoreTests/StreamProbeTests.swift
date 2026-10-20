import CFFmpeg
import Foundation
import Testing
@testable import FrameScrubCore

/// Later opens of a file in a playback session reuse its first probe (
/// `avformat_find_stream_info` decodes video frames, up to 0.15 s for 4K H.264; a later open skips it). They must see what a full probe sees.
@Suite struct StreamProbeTests {
    static let shareable = [Fixtures.h264, Fixtures.hevc10, Fixtures.vfr, Fixtures.withAudio, Fixtures.rotated,
                            Fixtures.audioLate, Fixtures.editList, Fixtures.anamorphic, Fixtures.scenes]

    /// A source opened through a cache that already holds the file's probe, and the full one it came from.
    private func pair(_ name: String) throws -> (full: MediaSource, shared: MediaSource) {
        let url = Fixtures.url(name)
        let cache = try ReadCache(url: url, budgetBytes: 0)
        let full = try MediaSource(url: url, readCache: cache)
        cache.probe = try #require(StreamProbe(full))
        return (full, try MediaSource(url: url, readCache: cache))
    }

    @Test(arguments: shareable)
    func aSharedProbeOpensLikeAFullOne(_ name: String) throws {
        let (full, shared) = try pair(name)
        #expect(!full.usedSharedProbe && shared.usedSharedProbe)
        #expect(shared.summary == full.summary)
        let (a, b) = (try shared.buildIndex(), try full.buildIndex())
        #expect(a.frameCount == b.frameCount && a.agrees(with: b))
        let url = Fixtures.url(name)
        let fromHeader = try MediaSource.containerIndex(url: url, readCache: shared.readCache)
        let fromHeaderFull = try MediaSource.containerIndex(url: url, readCache: nil)
        #expect(fromHeader.map { $0.frameCount } == fromHeaderFull.map { $0.frameCount })
        if let fromHeader, let fromHeaderFull { #expect(fromHeader.agrees(with: fromHeaderFull)) }
    }

    @Test(arguments: [Fixtures.h264, Fixtures.hevc10, Fixtures.editList], Path.allCases)
    func aSharedProbeDecodesTheSameFrames(_ name: String, _ path: Path) throws {
        let (full, shared) = try pair(name)
        let index = try MediaSource(url: full.url).buildIndex()
        func frames(_ source: MediaSource) throws -> [String] {
            let decoder = try makeDecoder(source, index, path)
            var seen: [String] = []
            for _ in 0..<12 { if let f = try decoder.nextFrame() { seen.append("\(f.number) \(f.pts) \(readFrameNumber(f.pixelBuffer)) \(f.dynamicRange)") } }
            try decoder.seek(toFrame: index.frameCount - 5)
            while let f = try decoder.nextFrame() { seen.append("\(f.number) \(f.pts) \(readFrameNumber(f.pixelBuffer)) \(f.dynamicRange)") }
            return seen
        }
        #expect(try frames(shared) == frames(full))
    }

    @Test func audioOpensThroughASharedProbe() throws {
        let url = Fixtures.url(Fixtures.withAudio)
        let cache = try ReadCache(url: url, budgetBytes: 0)
        cache.probe = StreamProbe(try MediaSource(url: url, readCache: cache))
        let decoder = try AudioDecoder(url: url, zeroSeconds: 0, readCache: cache)
        #expect(decoder.source.usedSharedProbe)
        #expect(try decoder.nextBuffer() != nil)
    }

    /// Fragmented MP4 and other containers: their header does not hold the video's timing, so they keep the full probe.
    @Test(arguments: [Fixtures.fragmented, Fixtures.audioLead, Fixtures.av1, Fixtures.withAudioGOP25MKV, Fixtures.noDecoder])
    func filesWithoutSampleTablesKeepTheFullProbe(_ name: String) throws {
        #expect(StreamProbe(try MediaSource(url: Fixtures.url(name))) == nil)
    }
}

extension MediaSource {
    /// What later code reads from the source and its streams.
    var summary: String {
        var parts = ["\(width)x\(height) \(bitDepth) bit, rot \(rotationClockwise), sar \(sampleAspect), tb \(timeBase), "
                     + "\(frameRate) fps, start \(startPTS), \(durationSeconds) s, \(format)"]
        let fc = formatContext.pointee
        for i in 0..<Int(fc.nb_streams) {
            let st = fc.streams[i]!.pointee
            let p = st.codecpar.pointee
            let extra = p.extradata.map { Data(bytes: $0, count: Int(p.extradata_size)) } ?? Data()
            parts.append("stream \(i): codec \(p.codec_id.rawValue) fmt \(p.format) delay \(p.video_delay) profile \(p.profile) "
                         + "level \(p.level) range \(p.color_range.rawValue) prim \(p.color_primaries.rawValue) "
                         + "trc \(p.color_trc.rawValue) space \(p.color_space.rawValue) loc \(p.chroma_location.rawValue) "
                         + "field \(p.field_order.rawValue) sar \(p.sample_aspect_ratio.num)/\(p.sample_aspect_ratio.den) "
                         + "rate \(p.framerate.num)/\(p.framerate.den) bits \(p.bits_per_raw_sample) "
                         + "audio \(p.sample_rate) \(p.ch_layout.nb_channels) \(p.frame_size) extra \(extra.base64EncodedString()) "
                         + "start \(st.start_time) dur \(st.duration) avg \(st.avg_frame_rate.num)/\(st.avg_frame_rate.den) "
                         + "r \(st.r_frame_rate.num)/\(st.r_frame_rate.den) frames \(st.nb_frames)")
        }
        parts.append("file start \(fc.start_time) dur \(fc.duration) rate \(fc.bit_rate)")
        return parts.joined(separator: "\n")
    }
}
