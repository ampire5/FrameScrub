import CFFmpeg
import Foundation

/// Why a file did not open, in plain words for the window, plus the technical text underneath.
public struct OpenFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case notFound, noAccess, network, readError, damaged, noVideo, other
    }

    public let kind: Kind
    public let detail: String
    /// A reason worded by the caller (a Stash scene whose share cannot be found, Stash spec §2.3).
    private let ownReason: String?

    public init(reason: String, detail: String) {
        kind = .other
        self.detail = detail
        ownReason = reason
    }

    public init(_ error: Error) {
        ownReason = nil
        detail = String(describing: error)
        if let ffmpeg = error as? FFmpegError {
            kind = Self.kind(code: ffmpeg.code)
        } else if let posix = error as? POSIXError {
            kind = Self.kind(code: -posix.code.rawValue)
        } else {
            kind = .other
        }
    }

    /// `code` is an FFmpeg error: a negated errno or an AVERROR tag.
    private static func kind(code: Int32) -> Kind {
        switch code {
        case -ENOENT, -ENOTDIR: .notFound
        case -EACCES: .noAccess   // not EPERM: it is -1, which FFmpegError also uses for "allocation failed"
        case -ETIMEDOUT, -EHOSTDOWN, -EHOSTUNREACH, -ENETDOWN, -ENETUNREACH, -ENETRESET, -ENOTCONN, -ECONNRESET,
             -ECONNREFUSED, -ESTALE: .network
        case -EIO: .readError
        case cff_averror_invaliddata(): .damaged
        case cff_averror_stream_not_found(): .noVideo
        default: .other
        }
    }

    public var reason: String {
        if let ownReason { return ownReason }
        return switch kind {
        case .notFound: "The file is no longer there."
        case .noAccess: "No permission to read the file."
        case .network: "The network drive is not responding."
        case .readError: "The file could not be read — the drive may be disconnected or failing."
        case .damaged: "This is not a video FrameScrub can read, or the file is damaged."
        case .noVideo: "The file has no video track."
        case .other: "The file could not be opened."
        }
    }
}
