import CFFmpeg
import Foundation
import HomeScreenModel

/// A video's facts for its card (HomeScreenKit's file-cards spec): what the demuxer already knows once the file is open
/// for its poster, so nothing more is read.
extension MediaSource {
    public var facts: FileFacts {
        let turned = rotationClockwise % 180 != 0
        let p = videoStream.pointee.codecpar.pointee
        let hdr = p.color_trc == AVCOL_TRC_SMPTE2084 || p.color_trc == AVCOL_TRC_ARIB_STD_B67
        return FileFacts(width: turned ? height : width, height: turned ? width : height,
                         duration: durationSeconds > 0 ? durationSeconds : nil, codec: VideoFacts.codec(format.videoCodec),
                         fps: frameRate > 0 ? frameRate : nil,
                         bitrate: format.fileBitRate > 0 ? Int(format.fileBitRate) : nil, hdr: hdr)
    }
}

public enum VideoFacts {
    /// FFmpeg's codec name as people say it: `hevc` → `HEVC`, `h264` → `H.264`, `prores` → `ProRes`.
    public static func codec(_ name: String) -> String {
        switch name.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "prores": "ProRes"
        case "mpeg4": "MPEG-4"
        case "mpeg2video": "MPEG-2"
        case "mjpeg": "MJPEG"
        case "wmv3": "WMV"
        default: name.uppercased()
        }
    }

    /// Only the facts (the header is read and the streams probed, nothing decoded): a poster that came from the cache.
    public static func probe(url: URL) -> FileFacts? {
        (try? MediaSource(url: url))?.facts
    }
}
