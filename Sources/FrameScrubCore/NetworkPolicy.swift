import Foundation

/// `network-mode`: whether files on network volumes (SMB, NFS, AFP, WebDAV…) are read gently.
public enum NetworkMode: String, Sendable {
    case auto, yes, no
}

/// How much of a slow link the background work may take (docs/reference.md, "Network files"). On a share that delivers a
/// few MB/s every reader divides the same bandwidth, so playback gets what the others leave. `local` is the full
/// behaviour; `network` plays first and looks around later:
/// - only the reader that plays reads ahead, and far enough (`readAheadSeconds`) to ride out a stall of the share;
/// - the seek-bar preview, the black-bar sampler, the backward decoder and the other side readers read what they
///   need and no more (`sideReadAhead`), and the preview waits until the pointer rests (`previewSettle`);
/// - black bars are looked for on a few keyframes, a while after the file opened;
/// - paused, the decoded window around the playhead stays small, so the file is not read for frames nobody asked for.
public struct NetworkPolicy: Equatable, Sendable {
    /// Seconds of video the playing reader loads ahead of itself (capped by half the read cache).
    public var readAheadSeconds: Double
    /// Whether side readers (preview, black bars, scene looks, plugin frames, backward) load further blocks ahead too.
    public var sideReadAhead: Bool
    /// Seconds the pointer rests on the seek bar before a preview is read for it.
    public var previewSettle: Double
    /// Keyframes the black-bar sampler looks at, and how long after the file opened it starts.
    public var barSamples: Int
    public var barsDelay: Double
    /// Seconds of decoded frames kept above and below the playhead when not playing (nil = what the cache budget allows).
    public var frameAheadSeconds: Double?
    public var frameBehindSeconds: Double?
    /// The read cache is at least this large (MiB), or the deeper read-ahead has no room.
    public var minReadCacheMiB: Int
    public var isNetwork: Bool

    public static let local = NetworkPolicy(readAheadSeconds: 3, sideReadAhead: true, previewSettle: 0, barSamples: 10,
                                            barsDelay: 0, frameAheadSeconds: nil, frameBehindSeconds: nil,
                                            minReadCacheMiB: 0, isNetwork: false)
    public static let network = NetworkPolicy(readAheadSeconds: 40, sideReadAhead: false, previewSettle: 0.25, barSamples: 4,
                                              barsDelay: 20, frameAheadSeconds: 8, frameBehindSeconds: 3,
                                              minReadCacheMiB: 512, isNetwork: true)

    /// The policy for `url` under `mode`; `auto` asks the volume.
    public static func resolve(_ mode: NetworkMode, url: URL) -> NetworkPolicy {
        switch mode {
        case .yes: return .network
        case .no: return .local
        case .auto: return isOnNetworkVolume(url) ? .network : .local
        }
    }

    /// True for an http(s) address, and for a file whose volume is not local (`MNT_LOCAL` clear in `statfs`).
    public static func isOnNetworkVolume(_ url: URL) -> Bool {
        if ByteSources.isRemote(url) { return true }
        guard url.isFileURL else { return false }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_LOCAL) == 0
    }
}
