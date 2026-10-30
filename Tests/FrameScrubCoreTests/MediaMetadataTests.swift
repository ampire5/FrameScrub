import CFFmpeg
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct MediaMetadataTests {
    @Test func snapshotRoundTripAndAudio() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.withAudio))
        let metadata = source.metadata
        #expect(metadata.readerVersion == MediaMetadata.currentReaderVersion)
        #expect(metadata.facts == source.facts)
        #expect(metadata.sizeBytes > 0)
        #expect(metadata.container.contains("mp4"))
        let audio = try #require(metadata.streams.first { $0.kind == .audio })
        #expect(audio.codec == "aac")
        #expect(audio.sampleRate == 48000)
        #expect((audio.channels ?? 0) > 0)
        #expect(audio.codedWidth == nil)
        let data = try JSONEncoder().encode(metadata)
        #expect(try JSONDecoder().decode(MediaMetadata.self, from: data) == metadata)
    }

    @Test func geometryAndColor() throws {
        let rotated = try MediaSource(url: Fixtures.url(Fixtures.rotated)).metadata
        let video = try #require(rotated.streams.first { $0.kind == .video })
        #expect(video.codedWidth == 640 && video.codedHeight == 360)
        #expect(video.rotationClockwise == 270)
        #expect(rotated.facts.width == 360)
        let anamorphic = try MediaSource(url: Fixtures.url(Fixtures.anamorphic)).metadata
        let sar = try #require(anamorphic.streams.first?.sampleAspectRatio)
        #expect(abs(sar.value - 64.0 / 45) < 0.0001)
        let hdr = try MediaSource(url: Fixtures.url(Fixtures.hevc10)).metadata
        #expect(hdr.streams.first?.colorTransfer == "arib-std-b67")
        #expect(hdr.streams.first?.bitDepth == 10)
    }

    @Test func absenceAndBoundedTags() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.h264))
        av_dict_set(&source.formatContext.pointee.metadata, "title", String(repeating: "x", count: 10000), 0)
        av_dict_set(&source.formatContext.pointee.metadata, "private_custom_blob", "discard", 0)
        let metadata = source.metadata
        #expect(metadata.tags["title"]?.utf8.count == 1024)
        #expect(metadata.tagsTruncated)
        #expect(metadata.tags["private_custom_blob"] == nil)
        #expect(metadata.tags.count <= 16)
        #expect(metadata.streams.allSatisfy { $0.kind != .audio && $0.kind != .subtitle })
        #expect(metadata.chapters.isEmpty)
        #expect(!metadata.streamsTruncated && !metadata.chaptersTruncated)
        #expect(metadata.streams.first?.sampleRate == nil)
        #expect(metadata.streams.first?.colorTransfer != "unknown")
    }

    @Test func structuredHDRAndSharedTagBudget() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.withAudio))
        let par = source.videoStream.pointee.codecpar!
        let mastering = try #require(av_packet_side_data_new(&par.pointee.coded_side_data,
            &par.pointee.nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
            MemoryLayout<AVMasteringDisplayMetadata>.size, 0))
        var m = AVMasteringDisplayMetadata()
        m.has_primaries = 1
        m.display_primaries.0 = (AVRational(num: 68, den: 100), AVRational(num: 32, den: 100))
        m.white_point = (AVRational(num: 3127, den: 10000), AVRational(num: 329, den: 1000))
        m.has_luminance = 1
        m.min_luminance = AVRational(num: 0, den: 1)
        m.max_luminance = AVRational(num: 1000, den: 1)
        UnsafeMutableRawPointer(mastering.pointee.data).storeBytes(of: m, as: AVMasteringDisplayMetadata.self)
        let light = try #require(av_packet_side_data_new(&par.pointee.coded_side_data,
            &par.pointee.nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
            MemoryLayout<AVContentLightMetadata>.size, 0))
        var l = AVContentLightMetadata()
        l.MaxCLL = 1000
        l.MaxFALL = 400
        UnsafeMutableRawPointer(light.pointee.data).storeBytes(of: l, as: AVContentLightMetadata.self)
        let dolby = try #require(av_packet_side_data_new(&par.pointee.coded_side_data,
            &par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF,
            MemoryLayout<AVDOVIDecoderConfigurationRecord>.size, 0))
        var d = AVDOVIDecoderConfigurationRecord()
        d.dv_profile = 8
        d.dv_level = 6
        d.rpu_present_flag = 1
        d.bl_present_flag = 1
        d.dv_bl_signal_compatibility_id = 1
        UnsafeMutableRawPointer(dolby.pointee.data).storeBytes(of: d, as: AVDOVIDecoderConfigurationRecord.self)
        let keys = ["title", "artist", "album", "album_artist", "composer", "genre", "date", "creation_time",
                    "language", "handler_name", "encoder", "copyright", "comment", "description", "track", "disc"]
        for i in 0..<Int(source.formatContext.pointee.nb_streams) {
            let stream = source.formatContext.pointee.streams[i]!
            for key in keys { av_dict_set(&stream.pointee.metadata, key, String(repeating: "x", count: 1024), 0) }
        }
        av_dict_set(&source.formatContext.pointee.metadata, "title", "omitted", 0)
        let metadata = source.metadata
        let video = try #require(metadata.streams.first)
        #expect(video.masteringDisplay?.red?.x == 0.68)
        #expect(video.masteringDisplay?.minimumLuminance == 0)
        #expect(video.masteringDisplay?.maximumLuminance == 1000)
        #expect(video.contentLight?.maxCLL == 1000 && video.contentLight?.maxFALL == 400)
        #expect(video.dolbyVision?.profile == 8 && video.dolbyVision?.level == 6)
        #expect(video.dolbyVision?.rpuPresent == true)
        #expect(metadata.tags["title"] == nil && metadata.tagsTruncated)
        #expect(!video.tagsTruncated) // exactly 16 KiB, no per-field clipping
        let totalBytes = metadata.streams.flatMap { $0.tags.values }.reduce(0) { $0 + $1.utf8.count }
            + metadata.tags.values.reduce(0) { $0 + $1.utf8.count }
        #expect(totalBytes <= 32 * 1024)
        #expect(try JSONDecoder().decode(MediaMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
        let audio = try #require(metadata.streams.first { $0.kind == .audio })
        #expect(audio.masteringDisplay == nil && !audio.hasMasteringDisplayMetadata)
        #expect(audio.contentLight == nil && audio.dolbyVision == nil)
    }

    @Test func subtitleDispositionsAndChapterTimes() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.withAudio))
        let stream = try #require(source.audioStream)
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_SUBRIP
        stream.pointee.disposition = AV_DISPOSITION_DEFAULT | AV_DISPOSITION_FORCED
        av_dict_set(&stream.pointee.metadata, "language", "eng", 0)
        let chapter = UnsafeMutablePointer<AVChapter>.allocate(capacity: 1)
        chapter.initialize(to: AVChapter())
        chapter.pointee.id = 7
        chapter.pointee.time_base = AVRational(num: 1, den: 1000)
        chapter.pointee.start = 1250
        chapter.pointee.end = 2500
        av_dict_set(&chapter.pointee.metadata, "title", "Introduction", 0)
        let chapters = UnsafeMutablePointer<UnsafeMutablePointer<AVChapter>?>.allocate(capacity: 1)
        chapters.initialize(to: chapter)
        let original = source.formatContext.pointee.chapters
        let count = source.formatContext.pointee.nb_chapters
        source.formatContext.pointee.chapters = chapters
        source.formatContext.pointee.nb_chapters = 1
        defer {
            source.formatContext.pointee.chapters = original
            source.formatContext.pointee.nb_chapters = count
            av_dict_free(&chapter.pointee.metadata)
            chapter.deinitialize(count: 1)
            chapter.deallocate()
            chapters.deinitialize(count: 1)
            chapters.deallocate()
        }
        let metadata = source.metadata
        let subtitle = try #require(metadata.streams.first { $0.kind == .subtitle })
        #expect(subtitle.codec == "subrip")
        #expect(subtitle.tags["language"] == "eng")
        #expect(subtitle.disposition & AV_DISPOSITION_FORCED != 0)
        #expect(subtitle.sampleRate == nil && subtitle.pixelFormat == nil)
        #expect(metadata.chapters.first?.startSeconds == 1.25)
        #expect(metadata.chapters.first?.endSeconds == 2.5)
        #expect(metadata.chapters.first?.tags["title"] == "Introduction")
    }
}
