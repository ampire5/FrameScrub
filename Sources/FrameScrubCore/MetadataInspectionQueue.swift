import Foundation

/// Latest-request-only inspector worker: one active probe plus one replaceable pending request. A cancelled probe's
/// ReadCache is closed so it cannot issue further reads. An already-running filesystem syscall returns on the OS's
/// schedule; the worker stays bounded to one and never holds the catalog lock across that read.
public final class MetadataInspectionQueue: @unchecked Sendable {
    public static let shared = MetadataInspectionQueue()
    private struct Job {
        let url: URL
        let flag = CancellationFlag()
        let cancellation = OpenCancellation()
        let reading: @Sendable () -> Void
        let completed: @Sendable (MediaMetadata?) -> Void
        func cancel() { flag.cancel(); cancellation.cancel() }
    }
    private let queue = DispatchQueue(label: "framescrub.inspector", qos: .utility)
    private let lock = NSLock()
    private var current: Job?
    private var pending: Job?
    private var running = false

    private let cached: @Sendable (URL) -> MediaMetadata?
    private let probe: @Sendable (URL, OpenCancellation, CancellationFlag) -> MediaMetadata?
    public convenience init() {
        self.init(cached: { FileFactsStore.shared.metadata(for: $0) }, probe: Self.read)
    }
    init(cached: @escaping @Sendable (URL) -> MediaMetadata?,
         probe: @escaping @Sendable (URL, OpenCancellation, CancellationFlag) -> MediaMetadata?) {
        self.cached = cached; self.probe = probe
    }
    public func inspect(_ url: URL, reading: @escaping @Sendable () -> Void,
                        completed: @escaping @Sendable (MediaMetadata?) -> Void) {
        let job = Job(url: url, reading: reading, completed: completed)
        let state = lock.withLock { () -> (Job?, Job?, Bool) in
            let old = pending, active = current
            pending = job
            let start = !running
            running = true
            return (old, active, start)
        }
        state.0?.cancel(); state.1?.cancel()
        if state.2 { queue.async { self.run() } }
    }
    public func cancel() {
        let jobs = lock.withLock { () -> (Job?, Job?) in
            defer { pending = nil }
            return (current, pending)
        }
        jobs.0?.cancel(); jobs.1?.cancel()
    }
    private func run() {
        while true {
            let job = lock.withLock { () -> Job? in
                guard let next = pending else { running = false; current = nil; return nil }
                pending = nil; current = next
                return next
            }
            guard let job else { return }
            if job.flag.isCancelled { continue }
            var value = cached(job.url)
            if value == nil, !job.flag.isCancelled {
                job.reading()
                value = autoreleasepool { probe(job.url, job.cancellation, job.flag) }
            }
            if !job.flag.isCancelled { job.completed(value) }
        }
    }
    private static func read(_ url: URL, cancellation: OpenCancellation, flag: CancellationFlag) -> MediaMetadata? {
        do {
            let identity = MediaFileIdentity.read(url)
            let cache = try ReadCache(url: url, budgetBytes: 0)
            try cancellation.watch(cache)
            let source = try MediaSource(url: url, readCache: cache)
            guard !flag.isCancelled, let identity, MediaFileIdentity.read(url) == identity else { return nil }
            let metadata = source.metadata
            FileFactsStore.shared.store(metadata, identity: identity)
            return metadata
        } catch { return nil }
    }
}
