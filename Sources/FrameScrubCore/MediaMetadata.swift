import CFFmpeg
import Foundation
import HomeScreenModel

/// A bounded, owned snapshot of the already-probed demuxer. No packet reads or decoding.
/// Nil means no usable declared value, not that extraction is pending. Collection/tag truncation
/// flags distinguish absence from values omitted by bounds; HDR presence flags retain malformed declarations.
/// Persist `readerVersion` with the snapshot; re-probe older versions when new fields are needed.
public struct MediaMetadata: Codable, Sendable, Equatable {
    public static let currentReaderVersion = 2
    public static let readerVersion = currentReaderVersion
    public var readerVersion: Int
    public var facts: FileFacts
    public var container: String
    public var containerDescription: String?
    public var sizeBytes: Int64
    public var durationSeconds: Double?
    public var startSeconds: Double?
    public var bitRate: Int64?
    public var tags: [String: String]
    /// An allowlisted tag was shortened or omitted by the shared byte budget.
    public var tagsTruncated: Bool
    public var streams: [Stream]
    public var chapters: [Chapter]
    public var streamsTruncated: Bool
    public var chaptersTruncated: Bool

    public struct Rational: Codable, Sendable, Equatable {
        public var numerator: Int
        public var denominator: Int
        init?(_ value: AVRational) {
            guard value.num > 0, value.den > 0 else { return nil }
            numerator = Int(value.num)
            denominator = Int(value.den)
        }
        public var value: Double { Double(numerator) / Double(denominator) }
    }

    public struct Chromaticity: Codable, Sendable, Equatable {
        public var x: Double?
        public var y: Double?
        init(_ x: AVRational, _ y: AVRational) {
            self.x = metadataScalar(x)
            self.y = metadataScalar(y)
        }
    }

    public struct MasteringDisplay: Codable, Sendable, Equatable {
        /// CIE 1931 xy coordinates; nil when the corresponding declaration is absent.
        public var red: Chromaticity?
        public var green: Chromaticity?
        public var blue: Chromaticity?
        public var whitePoint: Chromaticity?
        /// cd/m². Zero is valid; malformed rationals are nil.
        public var minimumLuminance: Double?
        public var maximumLuminance: Double?
    }

    public struct ContentLight: Codable, Sendable, Equatable {
        /// cd/m²; zero means unspecified in the declaration.
        public var maxCLL: UInt32
        public var maxFALL: UInt32
    }

    public struct DolbyVision: Codable, Sendable, Equatable {
        public var versionMajor: UInt8
        public var versionMinor: UInt8
        public var profile: UInt8
        public var level: UInt8
        public var rpuPresent: Bool
        public var enhancementLayerPresent: Bool
        public var baseLayerPresent: Bool
        public var baseLayerSignalCompatibilityID: UInt8
    }

    public struct Stream: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case video, audio, subtitle, data, attachment, unknown }
        public var index: Int
        public var kind: Kind
        public var codec: String
        public var profile: String?
        public var level: String?
        public var bitRate: Int64?
        public var durationSeconds: Double?
        public var startSeconds: Double?
        public var timeBase: Rational?
        public var frameRate: Rational?
        public var frameCount: Int64?
        /// Codec parameters' dimensions, before rotation and sample-aspect correction.
        public var codedWidth: Int?
        public var codedHeight: Int?
        public var rotationClockwise: Int?
        public var sampleAspectRatio: Rational?
        public var pixelFormat: String?
        public var bitDepth: Int?
        public var colorPrimaries: String?
        public var colorTransfer: String?
        public var colorSpace: String?
        public var colorRange: String?
        public var chromaLocation: String?
        public var hasMasteringDisplayMetadata: Bool
        public var hasContentLightMetadata: Bool
        public var hasDolbyVisionConfiguration: Bool
        /// Nil with a true presence flag means a malformed/undersized side-data payload.
        public var masteringDisplay: MasteringDisplay?
        public var contentLight: ContentLight?
        public var dolbyVision: DolbyVision?
        public var sampleRate: Int?
        public var channels: Int?
        public var channelLayout: String?
        /// FFmpeg's AV_DISPOSITION bit mask, retaining all declared flags.
        public var disposition: Int32
        public var tags: [String: String]
        /// An allowlisted tag was shortened or omitted by the shared byte budget.
        public var tagsTruncated: Bool
    }

    public struct Chapter: Codable, Sendable, Equatable {
        public var id: Int64
        public var startSeconds: Double?
        public var endSeconds: Double?
        public var tags: [String: String]
        /// An allowlisted tag was shortened or omitted by the shared byte budget.
        public var tagsTruncated: Bool
    }
}

extension MediaSource {
    /// Call on this source's owning queue. Copies only bounded header metadata; no extra I/O.
    public var metadata: MediaMetadata {
        let fc = formatContext.pointee
        var tagBudget = 32 * 1024
        let streamLimit = 128
        let chapterLimit = 256
        let streams = (0..<min(Int(fc.nb_streams), streamLimit)).compactMap { i -> MediaMetadata.Stream? in
            guard let pointer = fc.streams[i], let parameters = pointer.pointee.codecpar else { return nil }
            let st = pointer.pointee
            let p = parameters.pointee
            let video = p.codec_type == AVMEDIA_TYPE_VIDEO
            let audio = p.codec_type == AVMEDIA_TYPE_AUDIO
            let kind: MediaMetadata.Stream.Kind = switch p.codec_type {
            case AVMEDIA_TYPE_VIDEO: .video
            case AVMEDIA_TYPE_AUDIO: .audio
            case AVMEDIA_TYPE_SUBTITLE: .subtitle
            case AVMEDIA_TYPE_DATA: .data
            case AVMEDIA_TYPE_ATTACHMENT: .attachment
            default: .unknown
            }
            let sar = av_guess_sample_aspect_ratio(formatContext, pointer, nil)
            func has(_ type: AVPacketSideDataType) -> Bool {
                av_packet_side_data_get(p.coded_side_data, p.nb_coded_side_data, type) != nil
            }
            let mastering: MediaMetadata.MasteringDisplay? = metadataSideData(p, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, as: AVMasteringDisplayMetadata.self).map { m in
                .init(red: m.has_primaries != 0 ? .init(m.display_primaries.0.0, m.display_primaries.0.1) : nil,
                      green: m.has_primaries != 0 ? .init(m.display_primaries.1.0, m.display_primaries.1.1) : nil,
                      blue: m.has_primaries != 0 ? .init(m.display_primaries.2.0, m.display_primaries.2.1) : nil,
                      whitePoint: m.has_primaries != 0 ? .init(m.white_point.0, m.white_point.1) : nil,
                      minimumLuminance: m.has_luminance != 0 ? metadataScalar(m.min_luminance) : nil,
                      maximumLuminance: m.has_luminance != 0 ? metadataScalar(m.max_luminance) : nil)
            }
            let light: MediaMetadata.ContentLight? = metadataSideData(p, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, as: AVContentLightMetadata.self).map {
                .init(maxCLL: $0.MaxCLL, maxFALL: $0.MaxFALL)
            }
            let dolby: MediaMetadata.DolbyVision? = metadataSideData(p, AV_PKT_DATA_DOVI_CONF, as: AVDOVIDecoderConfigurationRecord.self).map {
                .init(versionMajor: $0.dv_version_major, versionMinor: $0.dv_version_minor,
                      profile: $0.dv_profile, level: $0.dv_level, rpuPresent: $0.rpu_present_flag != 0,
                      enhancementLayerPresent: $0.el_present_flag != 0, baseLayerPresent: $0.bl_present_flag != 0,
                      baseLayerSignalCompatibilityID: $0.dv_bl_signal_compatibility_id)
            }
            var tagsTruncated = false
            let tags = metadataTags(st.metadata, budget: &tagBudget, truncated: &tagsTruncated)
            var layout = p.ch_layout
            var buffer = [CChar](repeating: 0, count: 256)
            let layoutResult = audio ? av_channel_layout_describe(&layout, &buffer, buffer.count) : -1
            return .init(index: Int(st.index), kind: kind,
                         codec: metadataText(avcodec_get_name(p.codec_id)) ?? "unknown",
                         profile: metadataText(avcodec_profile_name(p.codec_id, p.profile)),
                         level: MediaFormat.level(p.level, codec: p.codec_id),
                         bitRate: p.bit_rate > 0 ? p.bit_rate : nil,
                         durationSeconds: metadataTime(st.duration, base: av_q2d(st.time_base), nonnegative: true),
                         startSeconds: metadataTime(st.start_time, base: av_q2d(st.time_base)),
                         timeBase: .init(st.time_base),
                         frameRate: video ? (.init(st.avg_frame_rate) ?? .init(st.r_frame_rate)) : nil,
                         frameCount: st.nb_frames > 0 ? st.nb_frames : nil,
                         codedWidth: video && p.width > 0 ? Int(p.width) : nil,
                         codedHeight: video && p.height > 0 ? Int(p.height) : nil,
                         rotationClockwise: video ? Int(cff_stream_rotation_cw(pointer)) : nil,
                         sampleAspectRatio: video ? .init(sar) : nil,
                         pixelFormat: video ? metadataText(av_get_pix_fmt_name(AVPixelFormat(rawValue: p.format))) : nil,
                         bitDepth: video && p.format >= 0 ? Int(cff_pix_fmt_depth(p.format)) : nil,
                         colorPrimaries: video && p.color_primaries != AVCOL_PRI_UNSPECIFIED ? metadataText(av_color_primaries_name(p.color_primaries)) : nil,
                         colorTransfer: video && p.color_trc != AVCOL_TRC_UNSPECIFIED ? metadataText(av_color_transfer_name(p.color_trc)) : nil,
                         colorSpace: video && p.color_space != AVCOL_SPC_UNSPECIFIED ? metadataText(av_color_space_name(p.color_space)) : nil,
                         colorRange: video && p.color_range != AVCOL_RANGE_UNSPECIFIED ? metadataText(av_color_range_name(p.color_range)) : nil,
                         chromaLocation: video && p.chroma_location != AVCHROMA_LOC_UNSPECIFIED ? metadataText(av_chroma_location_name(p.chroma_location)) : nil,
                         hasMasteringDisplayMetadata: has(AV_PKT_DATA_MASTERING_DISPLAY_METADATA),
                         hasContentLightMetadata: has(AV_PKT_DATA_CONTENT_LIGHT_LEVEL),
                         hasDolbyVisionConfiguration: has(AV_PKT_DATA_DOVI_CONF),
                         masteringDisplay: mastering, contentLight: light, dolbyVision: dolby,
                         sampleRate: audio && p.sample_rate > 0 ? Int(p.sample_rate) : nil,
                         channels: audio && p.ch_layout.nb_channels > 0 ? Int(p.ch_layout.nb_channels) : nil,
                         channelLayout: layoutResult >= 0 && layoutResult < buffer.count ? String(cString: buffer) : nil,
                         disposition: st.disposition, tags: tags, tagsTruncated: tagsTruncated)
        }
        let chapters = (0..<min(Int(fc.nb_chapters), chapterLimit)).compactMap { i -> MediaMetadata.Chapter? in
            guard let chapter = fc.chapters[i]?.pointee else { return nil }
            let base = av_q2d(chapter.time_base)
            var tagsTruncated = false
            let tags = metadataTags(chapter.metadata, budget: &tagBudget, truncated: &tagsTruncated)
            return .init(id: chapter.id, startSeconds: metadataTime(chapter.start, base: base),
                         endSeconds: metadataTime(chapter.end, base: base), tags: tags, tagsTruncated: tagsTruncated)
        }
        var tagsTruncated = false
        let tags = metadataTags(fc.metadata, budget: &tagBudget, truncated: &tagsTruncated)
        return MediaMetadata(readerVersion: MediaMetadata.currentReaderVersion, facts: facts,
                             container: metadataText(fc.iformat.pointee.name) ?? "unknown",
                             containerDescription: metadataText(fc.iformat.pointee.long_name),
                             sizeBytes: readCache.fileSize,
                             durationSeconds: metadataTime(fc.duration, base: 1 / Double(AV_TIME_BASE), nonnegative: true),
                             startSeconds: metadataTime(fc.start_time, base: 1 / Double(AV_TIME_BASE)),
                             bitRate: fc.bit_rate > 0 ? fc.bit_rate : nil, tags: tags, tagsTruncated: tagsTruncated,
                             streams: streams, chapters: chapters,
                             streamsTruncated: fc.nb_streams > streamLimit, chaptersTruncated: fc.nb_chapters > chapterLimit)
    }
}

private func metadataTime(_ ticks: Int64, base: Double, nonnegative: Bool = false) -> Double? {
    guard ticks != cff_nopts(), base.isFinite, base > 0 else { return nil }
    let value = Double(ticks) * base
    return value.isFinite && (!nonnegative || value >= 0) ? value : nil
}

/// Reads at most 1024 bytes, even for maliciously large tag strings.
private func metadataText(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, 1024)
    guard length > 0 else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
}

private func metadataTags(_ dictionary: OpaquePointer?, budget: inout Int, truncated: inout Bool) -> [String: String] {
    // Fixed allowlist bounds both work and storage; no paths, binary attachments or arbitrary dumps.
    let keys = ["title", "artist", "album", "album_artist", "composer", "genre", "date", "creation_time",
                "language", "handler_name", "encoder", "copyright", "comment", "description", "track", "disc"]
    var result: [String: String] = [:]
    for key in keys {
        guard let entry = av_dict_get(dictionary, key, nil, 0), let pointer = entry.pointee.value else { continue }
        let length = strnlen(pointer, 1025)
        guard length > 0 else { continue }
        let retained = min(length, 1024, budget)
        if retained < length { truncated = true }
        guard retained > 0 else { continue }
        // Drop an incomplete UTF-8 suffix instead of adding replacement bytes beyond the budget.
        var bytes = Array(UnsafeRawBufferPointer(start: pointer, count: retained))
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        let value = String(decoding: bytes, as: UTF8.self)
        if bytes.count < retained { truncated = true }
        result[key] = value
        budget -= bytes.count
    }
    return result
}

private func metadataScalar(_ rational: AVRational) -> Double? {
    guard rational.den > 0, rational.num >= 0 else { return nil }
    let value = av_q2d(rational)
    return value.isFinite ? value : nil
}

/// Copy a fixed-size, validated payload; never retain FFmpeg pointers or inspect arbitrary side data.
private func metadataSideData<T>(_ parameters: AVCodecParameters, _ type: AVPacketSideDataType, as: T.Type) -> T? {
    guard let side = av_packet_side_data_get(parameters.coded_side_data, parameters.nb_coded_side_data, type),
          side.pointee.size >= MemoryLayout<T>.size, let data = side.pointee.data else { return nil }
    return UnsafeRawPointer(data).loadUnaligned(as: T.self)
}
