import CoreGraphics
import Foundation

public struct PreviewImage: @unchecked Sendable {
    public let image: CGImage
    public let requestedSeconds: Double
    public let frameSeconds: Double
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
    private let settle: Double
    private let readAhead: Bool
    private lazy var renderer = FrameImageRenderer() // worker-only, including Core Image context creation
    private let imagePool: PreviewImagePool
    private let frameCache: FrameCache?
    private let lock = NSLock()
    private var index: FrameIndex
    private var decoder: VideoDecoder?
    private var failed = false
    private var stopped = false
    private var decodes = 0
    private var worker: LatestOnlyWorker<Double>!

    public init(url: URL, index: FrameIndex, rotationClockwise: Int, widthPixels: Int, readCache: ReadCache? = nil,
                policy: NetworkPolicy = .local, qos: DispatchQoS.QoSClass = .userInitiated,
                imagePool: PreviewImagePool? = nil, frameCache: FrameCache? = nil) {
        self.url = url
        self.readCache = readCache
        self.index = index
        self.imagePool = imagePool.flatMap { $0.matches(url: url, rotationClockwise: rotationClockwise) ? $0 : nil }
            ?? PreviewImagePool(url: url, rotationClockwise: rotationClockwise)
        self.frameCache = frameCache
        rotation = rotationClockwise
        self.widthPixels = max(1, widthPixels)
        settle = policy.previewSettle
        readAhead = policy.sideReadAhead
        worker = LatestOnlyWorker<Double>(label: "framescrub.preview", qos: qos) { [weak self] seconds in self?.handle(seconds) }
    }

    public func request(seconds: Double) { worker.submit(seconds) }

    /// The exact index arrived: later requests use it.
    public func updateIndex(_ newIndex: FrameIndex) { lock.withLock { index = newIndex } }

    /// Cheap readiness check for the bounded film scheduler: no I/O, rendering or full-cache scan.
    public func canReuse(seconds: Double) -> Bool {
        let current = lock.withLock { index }
        guard current.isExact else { return false }
        let n = current.keyframe(atOrBefore: current.frameNumber(forSeconds: seconds))
        let pts = current.pts(forFrame: n)
        return imagePool.contains(pts: pts, widthPixels: widthPixels) || frameCache?.frame(n)?.pts == pts
    }

    public func stop() {
        lock.withLock { stopped = true }
        onImage = nil
        onUnavailable = nil
        onRequestFinished = nil
    }

    private func handle(_ seconds: Double) {
        defer {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                self.onRequestFinished?()
            }
        }
        let (current, skip) = lock.withLock { (index, stopped || failed) }
        guard !skip else { return }
        let n = current.frameNumber(forSeconds: seconds)
        let key: Int64? = current.isExact ? current.pts(forFrame: current.keyframe(atOrBefore: n)) : nil
        if let key, let hit = imagePool.image(pts: key, widthPixels: widthPixels) {
            deliver(hit, requested: seconds, frameSeconds: current.seconds(forPTS: key))
            return
        }
        if let key {
            let keyframe = current.keyframe(atOrBefore: n)
            if let frame = frameCache?.frame(keyframe), frame.pts == key,
               let image = renderer.thumbnail(for: frame, rotationClockwise: rotation, width: widthPixels) {
                imagePool.set(image, pts: frame.pts, widthPixels: widthPixels)
                deliver(image, requested: seconds, frameSeconds: current.seconds(forPTS: frame.pts))
                return
            }
        }
        // A share reads one preview in a second or more: let the pointer rest first, and drop this request when it moved on.
        if settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            if worker.hasPending { return }
        }
        guard !lock.withLock({ stopped }) else { return }
        if decoder == nil {
            do { decoder = try VideoDecoder(source: MediaSource(url: url, readCache: readCache, readAhead: readAhead), index: current) } catch {
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
            decoder.index = current
            try decoder.seekToKeyframe(near: n)
            guard let frame = try decoder.nextFrame(),
                  let image = renderer.thumbnail(for: frame, rotationClockwise: rotation, width: widthPixels) else { return }
            lock.withLock { decodes += 1 }
            imagePool.set(image, pts: frame.pts, widthPixels: widthPixels)
            deliver(image, requested: seconds, frameSeconds: current.seconds(forPTS: frame.pts))
        } catch {
            decoder = nil      // a transient seek/decode error drops this request; the next one reopens the file
        }
    }

    private func deliver(_ image: CGImage, requested: Double, frameSeconds: Double) {
        let result = PreviewImage(image: image, requestedSeconds: requested, frameSeconds: frameSeconds)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            self.onImage?(result)
        }
    }
}
