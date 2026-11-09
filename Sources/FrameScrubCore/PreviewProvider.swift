import CoreGraphics
import Foundation

public struct PreviewImage: @unchecked Sendable {
    public let image: CGImage
    public let requestedSeconds: Double
    public let frameSeconds: Double
    public let requestedAt: Double
    public let readyAt: Double
    public let sourceFrame: DecodedFrame?
}

/// Thumbnails for the seek bar (spec §7.3): a background decoder with its own demuxer returns the keyframe
/// at or before the requested time. Requests collapse to the latest. Ready images and matching playback
/// keyframes are reused before opening the decoder; thumbnail rendering stays on this provider's worker.
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
    private let softwareThreads: Int32
    private let diagnosticGroup: String
    private lazy var renderer = FrameImageRenderer() // worker-only, including Core Image context creation
    private let imagePool: PreviewImagePool
    private let frameCache: FrameCache?
    private let lock = NSLock()
    private var index: FrameIndex
    private var decoder: VideoDecoder?
    private var failed = false
    private var stopped = false
    private var decodes = 0
    private var requestedGeneration = 0
    private var deliveredGeneration = 0
    private struct Request: Sendable {
        let seconds: Double
        let readyOnly: Bool
        let speculative: Bool
        let generation: Int
        let at: Double
    }
    private var worker: LatestOnlyWorker<Request>!
    private let exactSample: Bool
    private let retainsSourceFrame: Bool

    public init(url: URL, index: FrameIndex, rotationClockwise: Int, widthPixels: Int, readCache: ReadCache? = nil,
                policy: NetworkPolicy = .local, qos: DispatchQoS.QoSClass = .userInitiated,
                imagePool: PreviewImagePool? = nil, frameCache: FrameCache? = nil, exactSample: Bool = false,
                retainsSourceFrame: Bool = false) {
        self.url = url
        self.readCache = readCache
        self.index = index
        self.imagePool = imagePool.flatMap { $0.matches(url: url, rotationClockwise: rotationClockwise) ? $0 : nil }
            ?? PreviewImagePool(url: url, rotationClockwise: rotationClockwise)
        self.frameCache = frameCache
        self.exactSample = exactSample
        self.retainsSourceFrame = retainsSourceFrame
        rotation = rotationClockwise
        self.widthPixels = max(1, widthPixels)
        readThrottle = PreviewReadThrottle(interval: policy.previewSettle)
        readAhead = policy.sideReadAhead
        // A filmstrip samples one keyframe at a time. Its software fallback stays within the serial utility budget.
        softwareThreads = qos == .utility || qos == .background ? 1 : 0
        diagnosticGroup = policy.isNetwork ? "preview.network" : "preview.local"
        worker = LatestOnlyWorker<Request>(label: "framescrub.preview", qos: qos) { [weak self] in self?.handle($0) }
    }

    public func request(seconds: Double, readyOnly: Bool = false, speculative: Bool = false) {
        let (generation, current, skip) = lock.withLock { () -> (Int, FrameIndex, Bool) in
            requestedGeneration += 1
            return (requestedGeneration, index, stopped || failed)
        }
        guard !skip else { finishRequest(); return }
        let request = Request(seconds: seconds, readyOnly: readyOnly, speculative: speculative,
                              generation: generation, at: PlaybackDiagnostics.enabled ? PlaybackDiagnostics.now() : 0)
        // Shared ready images bypass a worker waiting on a cold-read deadline or decoding.
        if current.isExact {
            let key = current.pts(forFrame: sampleFrame(seconds, index: current))
            if let image = imagePool.image(pts: key, widthPixels: widthPixels) {
                if PlaybackDiagnostics.enabled { PlaybackDiagnostics.shared.record("cache_hit", 1, group: diagnosticGroup) }
                deliver(image, request: request, frameSeconds: current.seconds(forPTS: key))
                finishRequest()
                return
            }
        }
        worker.submit(request)
    }

    /// The exact index arrived: later requests use it.
    public func updateIndex(_ newIndex: FrameIndex) { lock.withLock { index = newIndex } }

    /// Cheap readiness check for the bounded film scheduler: no I/O, rendering or full-cache scan.
    public func canReuse(seconds: Double) -> Bool {
        let current = lock.withLock { index }
        guard current.isExact else { return false }
        let n = sampleFrame(seconds, index: current)
        let pts = current.pts(forFrame: n)
        return imagePool.contains(pts: pts, widthPixels: widthPixels) || frameCache?.frame(n)?.pts == pts
    }

    private func sampleFrame(_ seconds: Double, index: FrameIndex) -> Int {
        let frame = index.frameNumber(forSeconds: seconds)
        return exactSample ? frame : index.keyframe(atOrBefore: frame)
    }

    public func stop() {
        lock.withLock { stopped = true }
        onImage = nil
        onUnavailable = nil
        onRequestFinished = nil
    }

    private func handle(_ request: Request) {
        let seconds = request.seconds
        defer { finishRequest() }
        let report = PlaybackDiagnostics.shared
        func measure(_ name: String, since start: Double) {
            if PlaybackDiagnostics.enabled { report.record(name, (PlaybackDiagnostics.now() - start) * 1000, group: diagnosticGroup) }
        }
        measure("request_queue_ms", since: request.at)
        let (current, skip) = lock.withLock { (index, stopped || failed) }
        guard !skip else { return }
        let n = current.frameNumber(forSeconds: seconds)
        let sample = sampleFrame(seconds, index: current)
        let key: Int64? = current.isExact ? current.pts(forFrame: sample) : nil
        if let key, let hit = imagePool.image(pts: key, widthPixels: widthPixels) {
            if PlaybackDiagnostics.enabled { report.record("cache_hit", 1, group: diagnosticGroup) }
            deliver(hit, request: request, frameSeconds: current.seconds(forPTS: key))
            return
        }
        if let key {
            if let frame = frameCache?.frame(sample), frame.pts == key,
               let image = renderer.thumbnail(for: frame, rotationClockwise: rotation, width: widthPixels) {
                imagePool.set(image, pts: frame.pts, widthPixels: widthPixels)
                deliver(image, request: request, frameSeconds: current.seconds(forPTS: frame.pts))
                return
            }
        }
        // A speculative reuse may lose its source frame to eviction before this worker runs. Never turn it
        // into a new read/decode.
        guard !request.readyOnly else { return }
        // Limit cold reads without starving a moving pointer; ready-only work never reaches this path.
        let delay = readThrottle.delay(at: ProcessInfo.processInfo.systemUptime)
        if delay > 0 {
            let start = PlaybackDiagnostics.now()
            Thread.sleep(forTimeInterval: delay)
            measure("read_throttle_ms", since: start)
            if worker.hasPending { return }
        }
        guard lock.withLock({ !stopped && request.generation == requestedGeneration }) else { return }
        readThrottle.started(at: ProcessInfo.processInfo.systemUptime)
        if decoder == nil {
            let start = PlaybackDiagnostics.now()
            defer { measure("decoder_open_ms", since: start) }
            do {
                decoder = try VideoDecoder(source: MediaSource(url: url, readCache: readCache, readAhead: readAhead),
                                           index: current, preferHardware: true, allowVideoToolboxBackend: true,
                                           softwareThreads: softwareThreads)
            } catch {
                // A folded filmstrip may hit a temporary read failure before the user asks for previews.
                guard !request.speculative else { return }
                lock.withLock { failed = true }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.lock.withLock({ self.stopped }) else { return }
                    self.onUnavailable?()
                }
                return
            }
        }
        do {
            let decoder = decoder!
            decoder.diagnosticRole = "preview"
            decoder.index = current
            let seekStart = PlaybackDiagnostics.now()
            if exactSample { try decoder.seek(toFrame: n) }
            else { try decoder.seekToKeyframe(near: n) }
            guard let frame = try decoder.nextFrame() else { return }
            measure("seek_decode_ms", since: seekStart)
            let renderStart = PlaybackDiagnostics.now()
            guard let image = renderer.thumbnail(for: frame, rotationClockwise: rotation, width: widthPixels) else { return }
            measure("thumbnail_render_ms", since: renderStart)
            lock.withLock { decodes += 1 }
            imagePool.set(image, pts: frame.pts, widthPixels: widthPixels)
            deliver(image, request: request, frameSeconds: current.seconds(forPTS: frame.pts),
                    sourceFrame: retainsSourceFrame ? frame : nil)
        } catch {
            decoder = nil      // a transient seek/decode error drops this request; the next one reopens the file
        }
    }

    private func finishRequest() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            self.onRequestFinished?()
        }
    }

    private func deliver(_ image: CGImage, request: Request, frameSeconds: Double, sourceFrame: DecodedFrame? = nil) {
        let ready = PlaybackDiagnostics.enabled ? PlaybackDiagnostics.now() : 0
        let result = PreviewImage(image: image, requestedSeconds: request.seconds, frameSeconds: frameSeconds,
                                  requestedAt: request.at, readyAt: ready, sourceFrame: sourceFrame)
        let group = diagnosticGroup
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let deliverable = self.lock.withLock { () -> Bool in
                // A slow cold result is useful until a newer ready image has actually been delivered.
                guard !self.stopped, request.generation > self.deliveredGeneration else { return false }
                self.deliveredGeneration = request.generation
                return true
            }
            guard deliverable else { return }
            if PlaybackDiagnostics.enabled {
                PlaybackDiagnostics.shared.record("ready_to_callback_ms", (PlaybackDiagnostics.now() - ready) * 1000, group: group)
                PlaybackDiagnostics.shared.record("request_to_callback_ms", (PlaybackDiagnostics.now() - request.at) * 1000, group: group)
            }
            self.onImage?(result)
        }
    }
}
