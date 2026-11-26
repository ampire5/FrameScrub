import CoreImage
import FrameScrubCore

/// Keeps a bounded set of playback frames alive until the utility writer can encode them.
@MainActor final class PlaybackThumbnailWriter {
    private struct Snapshot: Sendable {
        let image: CIImage
        let geometry: DisplayGeometry
        let url: URL
        let identity: MediaFileIdentity
    }

    private let queue = DispatchQueue(label: "framescrub.thumbnail-save", qos: .utility)
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])
    private let store: ThumbnailStore
    private let onSaved: (URL, CGImage) -> Void
    private var writing = false
    private var pending: [Snapshot] = []
    // Normal runs queued at most one frame. Keep room for two distinct recent files under a delayed write,
    // prioritizing the latest save when switching faster than disk. See docs/bench/2026-11-26-window-lifecycle.md.
    private static let pendingLimit = 2
#if DEBUG
    var bench: WindowLifecycleBench?
#endif

    init(store: ThumbnailStore, onSaved: @escaping (URL, CGImage) -> Void) {
        self.store = store
        self.onSaved = onSaved
    }

    func save(_ image: CIImage, geometry: DisplayGeometry, url: URL, identity: MediaFileIdentity) {
        pending.removeAll { $0.identity == identity }
        pending.append(Snapshot(image: image, geometry: geometry, url: url, identity: identity))
        if pending.count > Self.pendingLimit { pending.removeFirst() }
        startNext()
#if DEBUG
        bench?.work.withLock { $0.peakPending = max($0.peakPending, pending.count) }
#endif
    }

    private func startNext() {
        guard !writing, !pending.isEmpty else { return }
        writing = true
        let snapshot = pending.removeFirst()
        let store = store, url = snapshot.url, identity = snapshot.identity
#if DEBUG
        let bench = bench
#endif
        queue.async {
#if DEBUG
            if let bench, bench.delay > 0 { Thread.sleep(forTimeInterval: bench.delay) }
#endif
            let result = autoreleasepool {
                store.save(snapshot.geometry.applied(to: snapshot.image), for: url, context: Self.context, identity: identity)
            }
            DispatchQueue.main.async {
                if let result, !self.pending.contains(where: { $0.identity.path == identity.path }) {
                    self.onSaved(url, result)
                }
                self.writing = false
                self.startNext()
            }
        }
    }
}
