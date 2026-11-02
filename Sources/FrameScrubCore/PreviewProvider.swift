import CoreGraphics
import Foundation

public struct PreviewImage: @unchecked Sendable {
    public let image: CGImage
    public let requestedSeconds: Double
    public let frameSeconds: Double
}

/// Thumbnails for the seek bar (spec §7.3): a background decoder with its own demuxer returns the keyframe
/// at or before the requested time. Requests collapse to the latest; the last 200 thumbnails are cached by
/// keyframe pts (an approximate index does not know keyframes, so it only caches after decoding).
public final class PreviewProvider: @unchecked Sendable {
    public var onImage: ((PreviewImage) -> Void)?          // main queue
    public var onUnavailable: (() -> Void)?                // main queue; the file cannot be previewed
    /// Main queue, after image delivery (or failure): a serial consumer may submit its next visible thumbnail.
    public var onRequestFinished: (() -> Void)?
    public var decodeCount: Int { lock.withLock { decodes } }

    private let url: URL
    private let readCache: ReadCache?
    private let rotation: Int
    private let widthPixels: Int
    private var readThrottle: PreviewReadThrottle
    private let readAhead: Bool
    private let renderer = FrameImageRenderer()
    private let cache = LRUCache<Int64, CGImage>(capacity: 200)
    private let lock = NSLock()
    private var index: FrameIndex
    private var decoder: VideoDecoder?
    private var failed = false
    private var stopped = false
    private var decodes = 0
    private var requestedGeneration = 0
    private var deliveredGeneration = 0
    private struct Request: Sendable { let seconds: Double; let generation: Int }
    private var worker: LatestOnlyWorker<Request>!

    public init(url: URL, index: FrameIndex, rotationClockwise: Int, widthPixels: Int, readCache: ReadCache? = nil,
                policy: NetworkPolicy = .local, qos: DispatchQoS.QoSClass = .userInitiated) {
        self.url = url
        self.readCache = readCache
        self.index = index
        rotation = rotationClockwise
        self.widthPixels = max(1, widthPixels)
        readThrottle = PreviewReadThrottle(interval: policy.previewSettle)
        readAhead = policy.sideReadAhead
        worker = LatestOnlyWorker<Request>(label: "framescrub.preview", qos: qos) { [weak self] request in self?.handle(request) }
    }

    public func request(seconds: Double) {
        let generation = lock.withLock { requestedGeneration += 1; return requestedGeneration }
        let request = Request(seconds: seconds, generation: generation)
        // Cache lookup stays available even while the sole worker is waiting on
        // a cold-read deadline or decoding. Every LRU access uses this same lock.
        let cached: (CGImage, Double)? = lock.withLock {
            guard !stopped, !failed, index.isExact else { return nil }
            let key = index.pts(forFrame: index.keyframe(atOrBefore: index.frameNumber(forSeconds: seconds)))
            return cache.get(key).map { ($0, index.seconds(forPTS: key)) }
        }
        if let (image, frameSeconds) = cached {

            deliver(image, request: request, frameSeconds: frameSeconds)
            DispatchQueue.main.async { [weak self] in self?.onRequestFinished?() }
        } else { worker.submit(request) }
    }

    /// The exact index arrived: later requests use it.
    public func updateIndex(_ newIndex: FrameIndex) { lock.withLock { index = newIndex } }

    public func stop() {
        lock.withLock { stopped = true }
        onImage = nil
        onUnavailable = nil
        onRequestFinished = nil
    }

    private func handle(_ request: Request) {
        let seconds = request.seconds
        defer { DispatchQueue.main.async { [weak self] in self?.onRequestFinished?() } }
        let (current, skip) = lock.withLock { (index, stopped || failed) }
        guard !skip else { return }
        let n = current.frameNumber(forSeconds: seconds)
        let key: Int64? = current.isExact ? current.pts(forFrame: current.keyframe(atOrBefore: n)) : nil
        if let key, let hit = lock.withLock({ cache.get(key) }) {
            deliver(hit, request: request, frameSeconds: current.seconds(forPTS: key))
            return
        }
        // Limit cold reads on a share without starving the preview while the pointer moves.
        // The latest pending request takes the elapsed slot instead of restarting a debounce.
        let delay = readThrottle.delay(at: ProcessInfo.processInfo.systemUptime)
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
            if worker.hasPending { return }
        }
        guard lock.withLock({ !stopped && request.generation == requestedGeneration }) else { return }
        readThrottle.started(at: ProcessInfo.processInfo.systemUptime)
        if decoder == nil {
            do { decoder = try VideoDecoder(source: MediaSource(url: url, readCache: readCache, readAhead: readAhead), index: current) } catch {
                lock.withLock { failed = true }
                DispatchQueue.main.async { [weak self] in self?.onUnavailable?() }
                return
            }
        }
        do {
            let decoder = decoder!
            decoder.index = current
            try decoder.seekToKeyframe(near: n)
            guard let frame = try decoder.nextFrame(),
                  let image = renderer.thumbnail(for: frame, rotationClockwise: rotation, width: widthPixels) else { return }
            lock.withLock { decodes += 1 }
            lock.withLock { cache.set(key ?? frame.pts, image) }
            deliver(image, request: request, frameSeconds: current.seconds(forPTS: frame.pts))
        } catch {
            decoder = nil      // a transient seek/decode error drops this request; the next one reopens the file
        }
    }

    private func deliver(_ image: CGImage, request: Request, frameSeconds: Double) {
        let result = PreviewImage(image: image, requestedSeconds: request.seconds, frameSeconds: frameSeconds)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let deliverable = self.lock.withLock { () -> Bool in
                // A slow cold result is still useful while a newer cold request
                // waits. Only a newer image already delivered makes it obsolete.
                guard !self.stopped, request.generation > self.deliveredGeneration else { return false }
                self.deliveredGeneration = request.generation
                return true
            }
            guard deliverable else { return }
            self.onImage?(result)
        }
    }
}
