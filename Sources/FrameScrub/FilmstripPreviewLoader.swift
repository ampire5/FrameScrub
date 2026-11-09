import Foundation
import FrameScrubCore
import CoreGraphics

/// One utility decoder, at most one screenful waiting; foreground playback always wins the next request.
@MainActor final class FilmstripPreviewLoader {
    var mayRead: (() -> Bool)?
    var mayPrewarm: ((_ readyOnly: Bool) -> Bool)?
    var onImage: ((CGImage, Double) -> Void)?
    private let provider: PreviewProvider
    private var pending: [Double] = []
    private var visibleReadyOnly = false
    private var warming: [Double] = []
    private var warmReadyOnly = true
    private let networkWarmBudget: TimeInterval?
    private var coldWarmStartedAt: TimeInterval?
    private var coldWarmDelivered = false
    private var inFlight = false
    var isReading: Bool { inFlight }
    var decodeCount: Int { provider.decodeCount }

    init(url: URL, index: FrameIndex, rotation: Int, width: Int, cache: ReadCache?, policy: NetworkPolicy,
         imagePool: PreviewImagePool? = nil, frameCache: FrameCache? = nil, exactSample: Bool = false) {
        networkWarmBudget = policy.isNetwork ? policy.previewSettle : nil
        // SeekBarView already waits once for the whole visible batch. Paying the pointer dwell again
        // for each serial cell adds 250 ms per image on network volumes (see timeline bench).
        var settledPolicy = policy
        settledPolicy.previewSettle = 0
        settledPolicy.sideReadAhead = false
        provider = PreviewProvider(url: url, index: index, rotationClockwise: rotation, widthPixels: width,
                                   readCache: cache, policy: settledPolicy, qos: .utility,
                                   imagePool: imagePool, frameCache: frameCache, exactSample: exactSample)
        provider.onImage = { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coldWarmDelivered = self.coldWarmStartedAt != nil
                self.pending.removeAll { $0 == result.requestedSeconds }
                self.warming.removeAll { $0 == result.requestedSeconds }
                // A playback tick may have moved the visible samples while this one was decoding.
                // Keep the completed picture in the bounded view cache instead of discarding useful work.
                self.onImage?(result.image, result.requestedSeconds)
            }
        }
        provider.onRequestFinished = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let start = self.coldWarmStartedAt,
                   !self.coldWarmDelivered || ProcessInfo.processInfo.systemUptime - start >= (self.networkWarmBudget ?? .infinity) {
                    // Keep serving cached frames after a failed sample or a slow network request.
                    self.warmReadyOnly = true
                    self.warming = self.warming.filter { self.provider.canReuse(seconds: $0) }
                }
                self.coldWarmStartedAt = nil
                self.coldWarmDelivered = false
                self.inFlight = false
                self.advance()
            }
        }
        provider.onUnavailable = { [weak self] in MainActor.assumeIsolated { self?.stop() } }
    }
    func request(_ times: [Double], readyOnly: Bool = false) {
        // One adaptive screenful; narrowing cells increases density, never decode concurrency.
        pending = Array(times.prefix(TimelineFilmLayout.maximumCells))
        visibleReadyOnly = readyOnly
        advance()
    }
    /// Replace the previous snapshot. While paused, prepare misses one by one as long as reads remain responsive.
    func prewarm(_ times: [Double], paused: Bool) {
        warmReadyOnly = !paused
        let samples = times.prefix(TimelineFilmLayout.maximumCells)
        warming = warmReadyOnly ? samples.filter { provider.canReuse(seconds: $0) } : Array(samples)
        advance()
    }
    func updateIndex(_ index: FrameIndex) { warming = []; provider.updateIndex(index) }
    /// A foreground frame became ready; retry deferred work without polling or requiring pointer input.
    func resume() { advance() }
    func stop() { pending = []; warming = []; provider.stop(); onImage = nil }
    private func advance() {
        guard !inFlight else { return }
        if pending.isEmpty {
            guard !warming.isEmpty, mayPrewarm?(warmReadyOnly) == true else { return }
            let ready = warming.firstIndex { provider.canReuse(seconds: $0) }
            let seconds = warming.remove(at: ready ?? warming.startIndex)
            let readyOnly = warmReadyOnly || ready != nil
            if !readyOnly { coldWarmStartedAt = ProcessInfo.processInfo.systemUptime }
            inFlight = true
            provider.request(seconds: seconds, readyOnly: readyOnly, speculative: true)
            return
        }
        guard mayRead?() == true else { return }
        // Reuse a ready picture/frame before a disk seek. The remaining misses retain centre-first order.
        let reusable = pending.firstIndex { provider.canReuse(seconds: $0) }
        if visibleReadyOnly && reusable == nil { return }
        let ready = reusable ?? pending.startIndex
        let seconds = pending.remove(at: ready)
        inFlight = true
        provider.request(seconds: seconds, readyOnly: visibleReadyOnly)
    }
}
