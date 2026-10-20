import CFFmpeg
import CoreVideo

/// Which decoder turns packets into pictures; the raw value is what the stats show.
public enum DecoderBackendKind: String, Sendable {
    /// Our own asynchronous VTDecompressionSession (H.264/HEVC).
    case videoToolbox = "VideoToolbox"
    /// FFmpeg's VideoToolbox hwaccel.
    case ffmpegVideoToolbox = "FFmpeg VideoToolbox"
    case software

    public var isHardware: Bool { self != .software }
}

/// A picture as a backend outputs it: `VideoDecoder` numbers it.
struct BackendFrame {
    /// The stream's pts; `cff_nopts()` when the decoder did not say.
    let pts: Int64
    let pixelBuffer: CVPixelBuffer
    let dynamicRange: DynamicRange
    let pictureType: Character?
}

enum BackendResult {
    case frame(BackendFrame)
    /// Nothing ready: send another packet.
    case needsInput
    /// Drained: no more frames until a flush.
    case ended
}

enum BackendError: Error {
    /// One frame could not be decoded; the stream goes on.
    case corruptFrame(Int32)
    /// The decoder itself is gone (sleep, GPU change): it has to be recreated.
    case sessionLost(Int32)
    case fatal(Error)
}

/// Decodes packets of one video stream; `VideoDecoder` does demuxing, seeking and numbering around it.
protocol DecoderBackend: AnyObject {
    var kind: DecoderBackendKind { get }
    /// For the stats.
    var codecName: String { get }
    /// Packets the backend has decoded since it was created, including ones it did not output.
    var decodedCount: Int { get }
    /// `output: false` — the picture is only needed as a reference (pre-roll); `mayDrop` — a non-reference picture
    /// need not be decoded at all.
    func send(_ packet: UnsafePointer<AVPacket>, output: Bool, mayDrop: Bool) throws
    func receive() throws -> BackendResult
    /// End of stream: the frames still held come out, then `.ended`.
    func drain() throws
    /// Before a seek: everything held or in flight is forgotten.
    func flush()
}
