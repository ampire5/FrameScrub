import Foundation
import FrameScrubCore
import CoreGraphics

/// One utility decoder, at most one screenful waiting; foreground playback always wins the next request.
@MainActor final class FilmstripPreviewLoader {
    var mayRead: (() -> Bool)?
    var onImage: ((CGImage, Double) -> Void)?
    private let provider: PreviewProvider
    private var pending: [Double] = []
    private var inFlight = false
    var decodeCount: Int { provider.decodeCount }

    init(url: URL, index: FrameIndex, rotation: Int, width: Int, cache: ReadCache?, policy: NetworkPolicy,
         imagePool: PreviewImagePool? = nil, frameCache: FrameCache? = nil) {
        // SeekBarView already waits once for the whole visible batch. Paying the pointer dwell again
        // for each serial cell adds 250 ms per image on network volumes (see timeline bench).
        var settledPolicy = policy
        settledPolicy.previewSettle = 0
        provider = PreviewProvider(url: url, index: index, rotationClockwise: rotation, widthPixels: width,
                                   readCache: cache, policy: settledPolicy, qos: .utility,
                                   imagePool: imagePool, frameCache: frameCache)
        provider.onImage = { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending.removeAll { $0 == result.requestedSeconds }
                // A playback tick may have moved the visible samples while this one was decoding.
                // Keep the completed picture in the bounded view cache instead of discarding useful work.
                self.onImage?(result.image, result.requestedSeconds)
            }
        }
        provider.onRequestFinished = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight = false
                self.advance()
            }
        }
        provider.onUnavailable = { [weak self] in MainActor.assumeIsolated { self?.stop() } }
    }
    func request(_ times: [Double]) {
        // One adaptive screenful; narrowing cells increases density, never decode concurrency.
        pending = Array(times.prefix(TimelineFilmLayout.maximumCells))
        advance()
    }
    func updateIndex(_ index: FrameIndex) { provider.updateIndex(index) }
    /// A foreground frame became ready; retry deferred work without polling or requiring pointer input.
    func resume() { advance() }
    func stop() { pending = []; provider.stop(); onImage = nil }
    private func advance() {
        guard !inFlight, !pending.isEmpty else { return }
        guard mayRead?() == true else { return }
        // Reuse a ready picture/frame before a disk seek. The remaining misses retain centre-first order.
        let ready = pending.firstIndex { provider.canReuse(seconds: $0) } ?? pending.startIndex
        let seconds = pending.remove(at: ready)
        inFlight = true
        provider.request(seconds: seconds)
    }
}
