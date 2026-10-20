import CoreImage
import Foundation

public protocol StillUpscaling: Sendable {
    func availability(width: Int, height: Int) -> MLAvailability
    func downloadModel() async throws
    func upscale4x(_ image: CIImage) async throws -> CIImage
}

/// The real thing: Apple's super-resolution through `MLUpscaler`.
public struct SystemStillUpscaling: StillUpscaling {
    private let context = CIContext()
    public init() {}
    public func availability(width: Int, height: Int) -> MLAvailability { MLUpscaler.availability(width: width, height: height) }
    public func downloadModel() async throws { try await MLUpscaler.downloadModel() }
    public func upscale4x(_ image: CIImage) async throws -> CIImage { try await MLUpscaler.upscale4x(image, context: context) }
}

public enum ModelDownloadChoice: Sendable { case download, notNow, never }

@MainActor public protocol StillEnhancerDelegate: AnyObject {
    /// Ask the user whether to download Apple's model; call `decide` exactly once.
    func stillEnhancer(_ enhancer: StillEnhancer, requestModelDownload decide: @escaping (ModelDownloadChoice) -> Void)
    func stillEnhancer(_ enhancer: StillEnhancer, didEnhanceFrame number: Int, pts: Int64, image: CIImage)
    func stillEnhancer(_ enhancer: StillEnhancer, message: String)
    /// The user chose "Never": persist `sr-still=no`.
    func stillEnhancerDidDisable(_ enhancer: StillEnhancer)
}

/// Redraws a paused frame with the neural upscaler (spec §11.2). Main thread only: the view
/// feeds it every shown frame and state change; it settles, computes in the background, and
/// reports a 4x image (or the cached one at once). Stale results are dropped.
@MainActor public final class StillEnhancer {
    public weak var delegate: StillEnhancerDelegate?
    public var isEnabled = true { didSet { if !isEnabled { cancel() } } }
    public private(set) var isWorking = false

    private let upscaler: StillUpscaling
    private let settleDelay: TimeInterval
    private let minimumRatio: Double
    private let cacheLimit: Int
    /// A frame is identified by number AND pts: the index can renumber frames when it is refined.
    private struct FrameKey: Equatable { let number: Int; let pts: Int64 }
    private var cache: [(key: FrameKey, image: CIImage)] = []
    private var generation = 0
    private var pendingFrame: FrameKey?
    private var settleWork: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var askedThisSession = false
    private var reportedDownloadingThisSession = false

    public init(upscaler: StillUpscaling, settleDelay: TimeInterval = 0.3, minimumRatio: Double = 1.2, cacheLimit: Int = 8) {
        self.upscaler = upscaler
        self.settleDelay = settleDelay
        self.minimumRatio = minimumRatio
        self.cacheLimit = cacheLimit
    }

    /// Call whenever the shown frame, the pause state or the on-screen ratio changes.
    public func update(frame: DecodedFrame?, isPaused: Bool, rotationClockwise: Int, ratio: Double) {
        // The network is display-referred SDR; HDR stills keep the HDR display path.
        guard isEnabled, isPaused, let frame, frame.dynamicRange == .sdr, ratio > minimumRatio else { cancel(); return }
        let key = FrameKey(number: frame.number, pts: frame.pts)
        if let hit = cache.firstIndex(where: { $0.key == key }) {
            let entry = cache.remove(at: hit)
            cache.append(entry)    // most recently used goes last
            cancel()
            delegate?.stillEnhancer(self, didEnhanceFrame: frame.number, pts: frame.pts, image: entry.image)
            return
        }
        if pendingFrame == key { return }    // already scheduled or running for this frame
        cancel()
        pendingFrame = key
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(frame, rotationClockwise: rotationClockwise, generation: current) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    /// A new file was opened: forget everything.
    public func reset() {
        cancel()
        cache.removeAll()
    }

    /// The system is short of memory: drop the cached 4x pictures (each is ~265 MB for 1080p). A running
    /// calculation continues; frames are recomputed when they are needed again.
    public func purgeCache() {
        cache.removeAll()
    }

    private func cancel() {
        generation += 1
        pendingFrame = nil
        settleWork?.cancel()
        settleWork = nil
        task?.cancel()
        task = nil
        isWorking = false
    }

    private func start(_ frame: DecodedFrame, rotationClockwise: Int, generation current: Int) {
        guard current == generation else { return }
        let image = FrameImageRenderer.image(for: frame, rotationClockwise: rotationClockwise, toneMapToSDR: true)
        let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
        isWorking = true
        task = Task { [weak self, upscaler] in
            guard let self else { return }
            var state = upscaler.availability(width: width, height: height)
            if case .modelNotReady(let downloading) = state {
                guard await self.prepareModel(downloading: downloading, width: width, height: height, generation: current) else { return }
                state = upscaler.availability(width: width, height: height)
            }
            guard state == .ready, current == self.generation else { self.finishIfCurrent(current); return }
            do {
                let result = try await upscaler.upscale4x(image)
                guard current == self.generation, !Task.isCancelled else { return }
                self.store(FrameKey(number: frame.number, pts: frame.pts), result)
                self.isWorking = false
                self.delegate?.stillEnhancer(self, didEnhanceFrame: frame.number, pts: frame.pts, image: result)
                self.delegate?.stillEnhancer(self, message: "SR")
            } catch {
                self.finishIfCurrent(current)
            }
        }
    }

    private func finishIfCurrent(_ current: Int) {
        if current == generation {
            isWorking = false
            pendingFrame = nil    // a later update of the same frame may retry
        }
    }

    /// Asks (once per session), downloads and reports. Returns whether the model can be used now.
    private func prepareModel(downloading: Bool, width: Int, height: Int, generation current: Int) async -> Bool {
        if let running = downloadTask {    // join the download in flight instead of starting another
            await running.value
            return finishDownload(width: width, height: height, generation: current)
        }
        if downloading {
            if !reportedDownloadingThisSession {
                reportedDownloadingThisSession = true
                delegate?.stillEnhancer(self, message: "SR model is downloading…")
            }
            finishIfCurrent(current)
            return false
        }
        guard !askedThisSession else { finishIfCurrent(current); return false }
        askedThisSession = true
        let choice: ModelDownloadChoice = await withCheckedContinuation { continuation in
            guard let delegate else { continuation.resume(returning: .notNow); return }
            delegate.stillEnhancer(self, requestModelDownload: { continuation.resume(returning: $0) })
        }
        switch choice {
        case .notNow:
            finishIfCurrent(current)
            return false
        case .never:
            isEnabled = false
            delegate?.stillEnhancerDidDisable(self)
            return false
        case .download:
            if downloadTask == nil {
                delegate?.stillEnhancer(self, message: "Downloading the image-enhancement model…")
                // Owned by the enhancer, not by the per-frame task: moving to another frame must not cancel it.
                downloadTask = Task { [upscaler] in
                    var failure: String?
                    do {
                        try await upscaler.downloadModel()
                    } catch is CancellationError {
                    } catch {
                        // The system can throw even though the model ended up installed.
                        if case .ready = upscaler.availability(width: width, height: height) {} else {
                            failure = (error as? MLUpscaleError)?.description ?? error.localizedDescription
                        }
                    }
                    if let failure { self.delegate?.stillEnhancer(self, message: "SR model download failed: \(failure)") }
                    self.downloadTask = nil
                }
            }
            await downloadTask?.value
            return finishDownload(width: width, height: height, generation: current)
        }
    }

    private func finishDownload(width: Int, height: Int, generation current: Int) -> Bool {
        if current == generation, case .ready = upscaler.availability(width: width, height: height) { return true }
        finishIfCurrent(current)    // stale or failed: the model stays available for the next update
        return false
    }

    private func store(_ key: FrameKey, _ image: CIImage) {
        cache.removeAll { $0.key == key }
        cache.append((key, image))
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
    }
}
