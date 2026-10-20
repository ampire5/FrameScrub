import Foundation

/// Runs clip jobs one at a time on a background thread so they do not disturb the player (spec §3).
/// Cancelled jobs (`cancel(for:)`, `cancelAll()`) are not reported to `onFinished`.
public final class ClipQueue: @unchecked Sendable {
    public typealias Write = @Sendable (ClipJob, () -> Bool) throws -> ClipResult

    /// Called on the main thread when a job ends, unless it was cancelled. Set it before enqueueing.
    public var onFinished: ((ClipJob, Result<ClipResult, Error>) -> Void)?
    /// Called on the main thread when the last job ends, or when cancelling empties the queue.
    public var onIdle: (() -> Void)?

    private let write: Write
    private let condition = NSCondition()
    private var waiting: [ClipJob] = []
    private var running: ClipJob?
    private var runningCancelled = false
    private var thread: Thread?

    public init(write: @escaping Write = { try ClipWriter.write($0, isCancelled: $1) }) {
        self.write = write
    }

    public func enqueue(_ job: ClipJob) {
        condition.lock()
        waiting.append(job)
        if thread == nil {
            let worker = Thread { [self] in run() }
            worker.name = "FrameScrub.ClipQueue"
            worker.qualityOfService = .utility
            thread = worker
            worker.start()
        }
        condition.signal()
        condition.unlock()
    }

    /// Jobs waiting, not counting the one being written.
    public var waitingCount: Int { condition.withLock { waiting.count } }

    /// Jobs being written or waiting.
    public var remainingCount: Int { condition.withLock { waiting.count + (running == nil ? 0 : 1) } }

    /// A job is being written or waiting.
    public var isBusy: Bool { condition.withLock { running != nil || !waiting.isEmpty } }

    public func pendingCount(for source: URL) -> Int {
        condition.withLock { waiting.filter { $0.source == source }.count + (running?.source == source ? 1 : 0) }
    }

    /// Drops the waiting jobs of `source` and cancels its running one.
    public func cancel(for source: URL) {
        let idle: Bool = condition.withLock {
            let before = waiting.count
            waiting.removeAll { $0.source == source }
            if running?.source == source { runningCancelled = true }
            return running == nil && waiting.isEmpty && before > 0
        }
        if idle { notifyIdle() }
    }

    public func cancelAll() {
        let idle: Bool = condition.withLock {
            let hadWaiting = !waiting.isEmpty
            waiting.removeAll()
            if running != nil { runningCancelled = true }
            return running == nil && hadWaiting
        }
        if idle { notifyIdle() }
    }

    private func notifyIdle() {
        DispatchQueue.main.async { [self] in onIdle?() }
    }

    private func run() {
        while true {
            condition.lock()
            while waiting.isEmpty { condition.wait() }
            let job = waiting.removeFirst()
            running = job
            runningCancelled = false
            condition.unlock()

            let result: Result<ClipResult, Error> = autoreleasepool {
                Result { try write(job) { condition.withLock { runningCancelled } } }
            }

            condition.lock()
            let cancelled = runningCancelled
            running = nil
            runningCancelled = false
            let idle = waiting.isEmpty
            condition.unlock()

            // A cancelled job is dropped whether it threw CancellationError or finished before noticing.
            if !cancelled {
                DispatchQueue.main.async { [self] in onFinished?(job, result) }
            }
            if idle { notifyIdle() }
        }
    }
}
