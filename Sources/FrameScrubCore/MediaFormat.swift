import CFFmpeg
import Foundation

/// Codec, profile and bit rates of an open file, for the stats overlay (`i`).
public struct MediaFormat: Equatable, Sendable {
    public struct Audio: Equatable, Sendable {
        public var codec: String
        public var profile: String?
        public var sampleRate: Int
        public var channels: Int
        /// Bits per second; 0 when the container does not say.
        public var bitRate: Int64

        /// "aac LC".
        public var codecText: String { [codec, profile].compactMap { $0 }.joined(separator: " ") }
        /// "mono", "stereo", "6 ch"; nil when the file does not say.
        public var channelsText: String? {
            switch channels {
            case ..<1: return nil
            case 1: return "mono"
            case 2: return "stereo"
            default: return "\(channels) ch"
            }
        }
        /// "48 kHz", "44.1 kHz"; nil when the file does not say.
        public var sampleRateText: String? { sampleRate > 0 ? String(format: "%g kHz", Double(sampleRate) / 1000) : nil }
        /// "128 kbit/s"; nil when the container does not say.
        public var bitRateText: String? { bitRate > 0 ? MediaFormat.rate(bitRate) : nil }
    }

    public var videoCodec: String
    public var videoProfile: String?
    /// "4.0", "5.1"; nil when unknown or the codec has no levels we can read.
    public var videoLevel: String?
    /// FFmpeg's name of the stream's pixel format ("yuv420p10le").
    public var pixelFormat: String?
    /// Bits per second; 0 when the container does not say.
    public var videoBitRate: Int64
    public var audio: Audio?
    /// The demuxer's long name ("QuickTime / MOV").
    public var container: String
    /// Bits per second of the whole file.
    public var fileBitRate: Int64

    init(formatContext fc: UnsafeMutablePointer<AVFormatContext>, video: Int32, audio: Int32?, fileBitRate: Int64) {
        let v = fc.pointee.streams[Int(video)]!.pointee.codecpar.pointee
        videoCodec = String(cString: avcodec_get_name(v.codec_id))
        videoProfile = avcodec_profile_name(v.codec_id, v.profile).map { String(cString: $0) }
        videoLevel = Self.level(v.level, codec: v.codec_id)
        pixelFormat = av_get_pix_fmt_name(AVPixelFormat(rawValue: v.format)).map { String(cString: $0) }
        videoBitRate = v.bit_rate
        self.audio = audio.map { index in
            let a = fc.pointee.streams[Int(index)]!.pointee.codecpar.pointee
            return Audio(codec: String(cString: avcodec_get_name(a.codec_id)),
                         profile: avcodec_profile_name(a.codec_id, a.profile).map { String(cString: $0) },
                         sampleRate: Int(a.sample_rate), channels: Int(a.ch_layout.nb_channels), bitRate: a.bit_rate)
        }
        let format = fc.pointee.iformat.pointee
        container = format.long_name.map { String(cString: $0) } ?? String(cString: format.name)
        self.fileBitRate = fileBitRate
    }

    /// The level as written in specs: H.264 stores 10×, HEVC 30×, AV1 the seq_level_idx.
    init(videoCodec: String, videoProfile: String? = nil, videoLevel: String? = nil, pixelFormat: String? = nil, videoBitRate: Int64 = 0,
         audio: Audio? = nil, container: String, fileBitRate: Int64 = 0) {
        self.videoCodec = videoCodec
        self.videoProfile = videoProfile
        self.videoLevel = videoLevel
        self.pixelFormat = pixelFormat
        self.videoBitRate = videoBitRate
        self.audio = audio
        self.container = container
        self.fileBitRate = fileBitRate
    }

    static func level(_ raw: Int32, codec: AVCodecID) -> String? {
        guard raw > 0 else { return nil }
        switch codec {
        case AV_CODEC_ID_H264: return "\(raw / 10).\(raw % 10)"
        case AV_CODEC_ID_HEVC: return "\(raw / 30).\(raw % 30 / 3)"
        case AV_CODEC_ID_AV1: return "\(2 + raw >> 2).\(raw & 3)"
        default: return nil
        }
    }

    /// "h264 High L4.0, yuv420p, 9.9 Mbit/s": the codec part of the Video line. Without a stream bit rate,
    /// the whole file's (marked ≈) stands in when there is no audio to share it with.
    public var videoText: String {
        var parts = [[videoCodec, videoProfile, videoLevel.map { "L\($0)" }].compactMap { $0 }.joined(separator: " ")]
        if let pixelFormat { parts.append(pixelFormat) }
        if videoBitRate > 0 {
            parts.append(Self.rate(videoBitRate))
        } else if audio == nil, fileBitRate > 0 {
            parts.append("≈" + Self.rate(fileBitRate))
        }
        return parts.joined(separator: ", ")
    }

    /// "aac LC, 48 kHz, mono, 70 kbit/s", or "none".
    public var audioText: String {
        guard let audio else { return "none" }
        return [audio.codecText, audio.sampleRateText, audio.channelsText, audio.bitRateText].compactMap { $0 }.joined(separator: ", ")
    }

    /// "QuickTime / MOV, 9.9 Mbit/s overall".
    public var containerText: String {
        fileBitRate > 0 ? "\(container), \(Self.rate(fileBitRate)) overall" : container
    }

    static func rate(_ bitsPerSecond: Int64) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbit/s", Double(bitsPerSecond) / 1e6)
            : "\(Int((Double(bitsPerSecond) / 1000).rounded())) kbit/s"
    }
}
