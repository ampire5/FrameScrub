import Foundation
import FrameScrubCore
import CoreGraphics

/// One utility request at a time and at most one screenful waiting.
@MainActor final class FilmstripPreviewLoader {
    var mayRead: (() -> Bool)?
    var mayReuse: (() -> Bool)?
    var mayShowStoryboard: (() -> Bool)?
    var mayPrewarm: ((_ readyOnly: Bool) -> Bool)?
    var onImage: ((CGImage, Double) -> Void)?
    private let provider: PreviewProvider
    private let storyboardSource: StashStoryboard.Source?
    private let width: Int
    private var storyboard: StashStoryboard?
    private var storyboardUnavailable = false
    private var providerUnavailable = false
    private var storyboardTask: Task<Void, Never>?
    private var readyAttempt: Double?
    private var readyMisses: Set<Double> = []
    private var pending: [Double] = []
    private var visibleReadyOnly = false
    private var navigationTimes: [Double]?
    private var navigationDwell: DispatchWorkItem?
    private var warming: [Double] = []
    private var warmReadyOnly = true
    private let networkWarmBudget: TimeInterval?
    private var coldWarmStartedAt: TimeInterval?
    private var coldWarmTime: Double?
    private var coldWarmDelivered = false
    private var coldVisibleTime: Double?
    private var deferredForForeground = false
    private var inFlight = false
    private var usesStoryboard: Bool { storyboardSource != nil && !storyboardUnavailable }
    var isReading: Bool { inFlight || storyboardTask != nil }
    var decodeCount: Int { provider.decodeCount }

    init(url: URL, index: FrameIndex, rotation: Int, width: Int, cache: ReadCache?, policy: NetworkPolicy,
         imagePool: PreviewImagePool? = nil, frameCache: FrameCache? = nil, exactSample: Bool = false,
         storyboardSource: StashStoryboard.Source? = nil, shouldYield: (@Sendable () -> Bool)? = nil) {
        self.storyboardSource = storyboardSource
        self.width = width
        networkWarmBudget = policy.isNetwork ? policy.previewSettle : nil
        // SeekBarView already waits once for the whole visible batch. Paying the pointer dwell again
        // for each serial cell adds 250 ms per image on network volumes (see timeline bench).
        var settledPolicy = policy
        settledPolicy.previewSettle = 0
        settledPolicy.sideReadAhead = false
        provider = PreviewProvider(url: url, index: index, rotationClockwise: rotation, widthPixels: width,
                                   readCache: cache, policy: settledPolicy, qos: .utility,
                                   imagePool: imagePool, frameCache: frameCache, exactSample: exactSample,
                                   shouldYield: policy.isNetwork ? nil : shouldYield)
        provider.onDeferred = { [weak self] in
            MainActor.assumeIsolated { self?.deferredForForeground = true }
        }
        provider.onImage = { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readyAttempt = nil
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
                if let time = self.readyAttempt {
                    if self.pending.contains(time) { self.readyMisses.insert(time) }
                    self.readyAttempt = nil
                }
                if let time = self.coldVisibleTime, !self.deferredForForeground {
                    self.pending.removeAll { $0 == time }
                }
                self.coldVisibleTime = nil
                if let time = self.coldWarmTime, !self.deferredForForeground {
                    self.warming.removeAll { $0 == time }
                }
                self.coldWarmTime = nil
                if !self.deferredForForeground, let start = self.coldWarmStartedAt,
                   !self.coldWarmDelivered || ProcessInfo.processInfo.systemUptime - start >= (self.networkWarmBudget ?? .infinity) {
                    // Keep serving cached frames after a failed sample or a slow network request.
                    self.warmReadyOnly = true
                    self.warming = self.warming.filter { self.provider.canReuse(seconds: $0) }
                }
                self.coldWarmStartedAt = nil
                self.coldWarmDelivered = false
                self.deferredForForeground = false
                self.inFlight = false
                self.advance()
            }
        }
        provider.onUnavailable = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.providerUnavailable = true
                self.warming = []
                if !self.usesStoryboard { self.stop() }
            }
        }
    }
    func request(_ times: [Double], readyOnly: Bool = false) {
        resetNavigationRequest()
        replacePending(times, readyOnly: readyOnly)
    }

    func requestNavigation(_ times: [Double], readyOnly: Bool = false, settle: TimeInterval) {
        guard !times.isEmpty else { cancelNavigation(); return }
        guard navigationTimes != times || readyOnly != visibleReadyOnly else { return }
        let newTimes = navigationTimes.map { old in times.contains { !old.contains($0) } } ?? true
        navigationTimes = times
        // Cache hits can run during the same network dwell used for the open filmstrip.
        // A moving window replaces the batch without postponing its first deadline.
        if newTimes, settle > 0, navigationDwell == nil, !readyOnly {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                navigationDwell = nil
                advance()
            }
            navigationDwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        }
        replacePending(times, readyOnly: readyOnly)
    }

    func cancelNavigation() {
        guard navigationTimes != nil else { return }
        cancelVisible()
        advance()
    }

    private func resetNavigationRequest() {
        navigationTimes = nil
        navigationDwell?.cancel()
        navigationDwell = nil
    }

    private func replacePending(_ times: [Double], readyOnly: Bool) {
        // One adaptive screenful; narrowing cells increases density, never decode concurrency.
        pending = Array(times.prefix(TimelineFilmLayout.maximumCells))
        readyMisses.formIntersection(pending)
        visibleReadyOnly = readyOnly
        if pending.isEmpty, mayShowStoryboard?() != true { cancelVisible() }
        advance()
    }
    /// Replace the previous snapshot. While paused, prepare misses one by one as long as reads remain responsive.
    func prewarm(_ times: [Double], paused: Bool) {
        guard !providerUnavailable else { return }
        warmReadyOnly = !paused || usesStoryboard
        let samples = times.prefix(TimelineFilmLayout.maximumCells)
        warming = warmReadyOnly ? samples.filter { provider.canReuse(seconds: $0) } : Array(samples)
        advance()
    }
    func updateIndex(_ index: FrameIndex) { warming = []; provider.updateIndex(index) }
    /// A foreground frame became ready; retry deferred work without polling or requiring pointer input.
    func resume() { advance() }

    func cancelVisible() {
        resetNavigationRequest()
        pending = []
        readyMisses = []
        storyboardTask?.cancel()
    }

    func stop() {
        cancelVisible()
        storyboard = nil
        warming = []
        provider.stop()
        onImage = nil
    }

    private func advance() {
        guard !isReading else { return }
        if pending.isEmpty {
            guard !warming.isEmpty, mayPrewarm?(warmReadyOnly) == true else { return }
            let ready = warming.firstIndex { provider.canReuse(seconds: $0) }
            let slot = ready ?? warming.startIndex
            let readyOnly = warmReadyOnly || ready != nil
            let seconds = readyOnly ? warming.remove(at: slot) : warming[slot]
            if !readyOnly {
                coldWarmTime = seconds
                coldWarmStartedAt = ProcessInfo.processInfo.systemUptime
            }
            inFlight = true
            provider.request(seconds: seconds, readyOnly: readyOnly, speculative: true)
            return
        }
        let isNavigation = navigationTimes != nil
        let mayRead = self.mayRead?() == true && navigationDwell == nil
        let canReuse = (visibleReadyOnly || isNavigation) && mayReuse?() == true
        guard mayRead || canReuse else { return }
        // Reuse a ready picture/frame before a disk seek. The remaining misses retain centre-first order.
        let reusable = providerUnavailable ? nil : pending.firstIndex { !readyMisses.contains($0) && provider.canReuse(seconds: $0) }
        let readyOnly = visibleReadyOnly || !mayRead
        if readyOnly && reusable == nil { return }
        let tryReuseFirst = (isNavigation && readyOnly && !visibleReadyOnly) || (usesStoryboard && !readyOnly)
        if tryReuseFirst, let reusable {
            // Keep this time queued for the normal path if the source is evicted on the worker.
            readyAttempt = pending[reusable]
            inFlight = true
            provider.request(seconds: pending[reusable], readyOnly: true)
        } else if usesStoryboard, !readyOnly {
            advanceStoryboard(at: pending[0])
        } else {
            let ready = reusable ?? pending.startIndex
            let seconds = readyOnly ? pending.remove(at: ready) : pending[ready]
            if !readyOnly { coldVisibleTime = seconds }
            inFlight = true
            provider.request(seconds: seconds, readyOnly: readyOnly)
        }
    }

    private func advanceStoryboard(at seconds: Double) {
        if let storyboard {
            let width = width
            storyboardTask = Task(priority: .utility) { [weak self] in
                let image = await storyboard.image(at: seconds, fitting: width)
                guard let self else { return }
                storyboardTask = nil
                if !Task.isCancelled, mayShowStoryboard?() == true, pending.contains(seconds) {
                    if let image {
                        pending.removeAll { $0 == seconds }
                        onImage?(image, seconds)
                    } else if !providerUnavailable {
                        if navigationDwell == nil, mayRead?() == true {
                            coldVisibleTime = seconds
                            inFlight = true
                            provider.request(seconds: seconds)
                        }
                    } else { pending.removeAll { $0 == seconds } }
                }
                advance()
            }
        } else if let storyboardSource {
            storyboardTask = Task(priority: .utility) { [weak self] in
                let loaded = try? await storyboardSource.load()
                guard let self else { return }
                storyboardTask = nil
                if !Task.isCancelled {
                    storyboard = loaded
                    storyboardUnavailable = loaded == nil
                }
                advance()
            }
        }
    }
}
