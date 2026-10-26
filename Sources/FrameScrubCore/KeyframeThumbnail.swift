import CoreImage
import Foundation

/// A picture for a recent file that has no saved one: the keyframe at or before where it was left, read with a
/// decoder of its own (one seek, one decoded frame).
public enum KeyframeThumbnail {
    public struct Result {
        /// Upright, SDR, square pixels (no black-bar crop), extent origin at (0, 0).
        public let picture: CIImage
        /// Where the keyframe is, in seconds from the start.
        public let seconds: Double
        /// The file's length in seconds.
        public let duration: Double
    }

    /// `seconds` nil looks 10 % into the file (the very first frame is often black). Nil when the file cannot be read.
    public static func make(url: URL, at seconds: Double?) -> Result? {
        guard let source = try? MediaSource(url: url) else { return nil }
        let index = source.approximateIndex()
        let duration = source.durationSeconds
        guard let decoder = try? VideoDecoder(source: source, index: index) else { return nil }
        let target = index.frameNumber(forSeconds: seconds ?? duration * 0.1)
        guard (try? decoder.seekToKeyframe(near: target)) != nil, let frame = (try? decoder.nextFrame()) ?? nil else { return nil }
        let upright = FrameImageRenderer.uprightSize(of: frame, rotationClockwise: source.rotationClockwise)
        let geometry = DisplayGeometry.resolve(mode: .auto, upright: upright, rotationClockwise: source.rotationClockwise,
                                               sampleAspect: source.sampleAspect, detectedCrop: nil)
        let image = FrameImageRenderer.image(for: frame, rotationClockwise: source.rotationClockwise, toneMapToSDR: true)
        return Result(picture: geometry.applied(to: image), seconds: max(0, index.seconds(forPTS: frame.pts)), duration: duration)
    }

    /// Only the file's length (the header is read, nothing decoded).
    public static func duration(url: URL) -> Double? {
        (try? MediaSource(url: url)).map(\.durationSeconds)
    }
}

/// Fills in the start screen's missing pictures one file at a time, in the background. Each picture goes to the
/// `ThumbnailStore`; `completion` then gets the file and its length. A new `start` or `cancel` drops what is left.
public final class RecentThumbnailer: @unchecked Sendable {
    public struct Job: Sendable {
        public let url: URL
        /// Where the file was left; nil when it has no position.
        public let seconds: Double?

        public init(url: URL, seconds: Double?) {
            self.url = url
            self.seconds = seconds
        }
    }

    private let store: ThumbnailStore
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "framescrub.recent-thumbnails", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var current: CancellationFlag?

    public init(store: ThumbnailStore, callbackQueue: DispatchQueue = .main) {
        self.store = store
        self.callbackQueue = callbackQueue
    }

    /// Files on this Mac's own disks are made `localWorkers` at a time; on a share (or a volume that does not say), one
    /// at a time, as its reads are the slow part.
    public func start(_ jobs: [Job], localWorkers: Int = 1, completion: @escaping @Sendable (URL, Double) -> Void) {
        let flag = CancellationFlag()
        lock.withLock {
            current?.cancel()
            current = flag
        }
        queue.async { [self] in
            let local = jobs.first.flatMap { try? $0.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal } ?? false
            let workers = max(1, min(local ? localWorkers : 1, jobs.count))
            let next = NSLock()
            var index = 0
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while !flag.isCancelled {
                    let i: Int? = next.withLock {
                        defer { index += 1 }
                        return index < jobs.count ? index : nil
                    }
                    guard let i else { return }
                    let job = jobs[i]
                    // A pool per file: the picture holds the decoded frame (an IOSurface of VTDecoderXPCService).
                    let duration: Double? = autoreleasepool {
                        guard let result = KeyframeThumbnail.make(url: job.url, at: job.seconds) else {
                            return KeyframeThumbnail.duration(url: job.url)   // no picture (no decoder), but the length is known
                        }
                        store.save(result.picture, for: job.url, context: context)
                        return result.duration
                    }
                    guard let duration else { continue }
                    callbackQueue.async { if !flag.isCancelled { completion(job.url, duration) } }
                }
            }
        }
    }

    /// Posters made at a time on this Mac's own disks: a quarter of the physical cores, 1…4. Measured on an M4 Max
    /// (14 cores; 24 posters of 1080p H.264 and 4K HEVC, docs/bench/2026-10-26-posters.md): 1 worker 57/s, 2 74/s,
    /// 3 108/s, 4 138/s, 6 103/s; so 3 there. Shares stay at one.
    public static let localWorkers: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0)
        return min(4, max(1, Int(cores) / 4))
    }()

    public func cancel() {
        lock.withLock {
            current?.cancel()
            current = nil
        }
    }
}
