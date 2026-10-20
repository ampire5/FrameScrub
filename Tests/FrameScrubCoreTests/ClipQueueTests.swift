import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ClipQueueTests {
    private func job(_ name: String) -> ClipJob {
        ClipJob(source: URL(fileURLWithPath: "/fake/\(name).mp4"), startPTS: 0, endPTS: 10, keyframePTS: 0,
                directory: URL(fileURLWithPath: "/fake"), fallbackDirectory: URL(fileURLWithPath: "/fake"),
                template: "x", aFrame: 0, aSeconds: 0, endSeconds: 1, readLimit: 0)
    }

    /// Waits for a semaphore signalled by the fake writer; times out so a broken queue fails instead of hanging.
    private func acquire(_ semaphore: DispatchSemaphore) {
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    private func result(_ job: ClipJob) -> ClipResult {
        ClipResult(url: job.source.deletingLastPathComponent().appendingPathComponent("out.mp4"), leadIn: 0)
    }

    /// Thread-safe log shared between the fake writer (worker thread) and the test (main / cooperative thread).
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        private var finished: [(ClipJob, Bool)] = []
        private var idleCount = 0
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var entries: [String] { lock.withLock { items } }
        func finish(_ job: ClipJob, ok: Bool) { lock.withLock { finished.append((job, ok)) } }
        var finishedJobs: [(ClipJob, Bool)] { lock.withLock { finished } }
        func idle() { lock.withLock { idleCount += 1 } }
        var idles: Int { lock.withLock { idleCount } }
    }

    private func attach(_ queue: ClipQueue, _ log: Log) {
        queue.onFinished = { job, result in
            if case .success = result { log.finish(job, ok: true) } else { log.finish(job, ok: false) }
        }
        queue.onIdle = { log.idle() }
    }

    @Test func runsOneAtATimeInOrder() async {
        let log = Log()
        let active = ManagedAtomicCounter()
        let queue = ClipQueue { job, _ in
            log.add("start \(job.source.lastPathComponent)")
            if active.increment() > 1 { log.add("overlap") }
            Thread.sleep(forTimeInterval: 0.01)
            active.decrement()
            log.add("end \(job.source.lastPathComponent)")
            return self.result(job)
        }
        attach(queue, log)
        let jobs = ["1", "2", "3"].map(job)
        jobs.forEach(queue.enqueue)
        #expect(await eventually { log.idles >= 1 })
        #expect(log.entries == ["start 1.mp4", "end 1.mp4", "start 2.mp4", "end 2.mp4", "start 3.mp4", "end 3.mp4"])
        #expect(log.finishedJobs.map(\.0) == jobs)
        #expect(log.idles == 1)
        #expect(!queue.isBusy)
    }

    @Test func countsWaiting() async {
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queue = ClipQueue { job, _ in
            started.signal()
            release.wait()
            return self.result(job)
        }
        attach(queue, log)
        let a1 = job("a"), a2 = job("a"), b1 = job("b")
        queue.enqueue(a1)
        acquire(started)
        queue.enqueue(b1)
        queue.enqueue(a2)
        #expect(queue.waitingCount == 2)
        #expect(queue.isBusy)
        #expect(queue.pendingCount(for: a1.source) == 2)
        #expect(queue.pendingCount(for: b1.source) == 1)
        #expect(queue.pendingCount(for: URL(fileURLWithPath: "/fake/none.mp4")) == 0)
        release.signal(); acquire(started)
        release.signal(); acquire(started)
        release.signal()
        #expect(await eventually { log.idles == 1 })
        #expect(queue.waitingCount == 0)
        #expect(!queue.isBusy)
    }

    @Test func cancelForSource() async {
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let cancelledSeen = DispatchSemaphore(value: 0)
        let queue = ClipQueue { job, isCancelled in
            log.add("start \(job.source.lastPathComponent)")
            if job.source.lastPathComponent == "a.mp4" {
                started.signal()
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.001) }
                cancelledSeen.signal()
                throw CancellationError()
            }
            return self.result(job)
        }
        attach(queue, log)
        let a1 = job("a"), b1 = job("b"), a2 = job("a")
        queue.enqueue(a1); queue.enqueue(b1); queue.enqueue(a2)
        acquire(started)
        queue.cancel(for: a1.source)
        acquire(cancelledSeen)
        #expect(await eventually { log.idles == 1 })
        #expect(log.entries == ["start a.mp4", "start b.mp4"])
        #expect(log.finishedJobs.map(\.0) == [b1])
    }

    @Test func cancelAllEmptiesTheQueueAndGoesIdle() async {
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let queue = ClipQueue { job, isCancelled in
            started.signal()
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.001) }
            throw CancellationError()
        }
        attach(queue, log)
        queue.enqueue(job("a")); queue.enqueue(job("b"))
        acquire(started)
        queue.cancelAll()
        #expect(await eventually { log.idles == 1 })
        #expect(log.finishedJobs.isEmpty)
        #expect(!queue.isBusy)
    }

    @Test func failureContinues() async {
        struct Boom: Error {}
        let log = Log()
        let queue = ClipQueue { job, _ in
            if job.source.lastPathComponent == "1.mp4" { throw Boom() }
            return self.result(job)
        }
        attach(queue, log)
        let first = job("1"), second = job("2")
        queue.enqueue(first); queue.enqueue(second)
        #expect(await eventually { log.idles >= 1 })
        let finished = log.finishedJobs
        #expect(finished.map(\.0) == [first, second])
        #expect(finished.map(\.1) == [false, true])
        #expect(log.idles == 1)
    }
}

/// Counts concurrent writers so the test can see an overlap.
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    func decrement() { lock.withLock { value -= 1 } }
}
