import Foundation
import Synchronization

/// Which recent files can be reached now, without letting a share that does not answer hold the start screen. The
/// same check as Loupe's Home (`HomeGrid.availability`).
public enum PathAvailability {
    /// Whether each of `paths` exists, by `check` run off the caller, all at once: true or false, or nil when the
    /// answer took longer than `timeout` (a share that does not answer). Never waits beyond it.
    public static func check(_ paths: [String], timeout: Duration,
                                    check: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        async -> [String: Bool?] {
        await withTaskGroup(of: (String, Bool?).self) { group in
            for path in paths {
                group.addTask { (path, await answer(path, timeout: timeout, check: check)) }
            }
            var result: [String: Bool?] = [:]
            for await (path, answer) in group { result[path] = .some(answer) }
            return result
        }
    }

    /// `check(path)` on a thread of its own, or nil once `timeout` passes first.
    private static func answer(_ path: String, timeout: Duration,
                               check: @escaping @Sendable (String) -> Bool) async -> Bool? {
        return await withCheckedContinuation { c in
            let once = Once(c)
            // A thread of its own: GCD's pool may be busy (or stuck on that share) and would hold the answer back.
            Thread.detachNewThread { once.resume(check(path)) }
            // A thread too: a busy pool (GCD's or the concurrency one) must not hold the deadline back.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
                once.resume(nil)
            }
        }
    }

    /// The number of blocking reads is capped at Loupe’s measured budget: three batches of 24 checks with
    /// 20 ms deadlines and 400 ms reads left 72 workers without admission control, four with it (2026-11-05).
    private static let directoryChecks: DirectoryChecks = {
        var cores: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) != 0 { cores = 1 }
        return DirectoryChecks(limit: min(4, max(1, Int(cores) / 2)))
    }()

    /// Checks directories on a shared utility budget. A missing result keeps the last known state when a check
    /// could not start. A path whose blocking read misses the deadline is reported unavailable.
    public static func checkDirectories(_ paths: [String], timeout: Duration) async -> [String: Bool] {
        await directoryChecks.check(paths, timeout: timeout) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    final class DirectoryChecks: Sendable {
        private let active = Mutex<Set<String>>([])
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func check(_ paths: [String], timeout: Duration, read: @escaping @Sendable (String) -> Bool) async -> [String: Bool] {
            let deadline = ContinuousClock.now + timeout
            var seen = active.withLock { $0 }
            let slots = limit - seen.count
            let pending = paths.filter { seen.insert($0).inserted }
            return await withTaskGroup(of: (String, Bool?).self) { group in
                var remaining = pending.makeIterator()
                func enqueue() {
                    guard !Task.isCancelled, ContinuousClock.now < deadline, let path = remaining.next() else { return }
                    group.addTask { (path, await self.read(path, before: deadline, using: read)) }
                }
                for _ in 0..<min(slots, pending.count) { enqueue() }
                var results: [String: Bool] = [:]
                for await (path, available) in group {
                    if let available { results[path] = available }
                    enqueue()
                }
                return results
            }
        }

        private func read(_ path: String, before deadline: ContinuousClock.Instant,
                          using probe: @escaping @Sendable (String) -> Bool) async -> Bool? {
            guard !Task.isCancelled, ContinuousClock.now < deadline, active.withLock({ paths in
                paths.count < limit && paths.insert(path).inserted
            }) else { return nil }
            return await withCheckedContinuation { continuation in
                let once = Once(continuation)
                let timer = Task.detached(priority: .utility) {
                    guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                    once.resume(false)
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    let available = ContinuousClock.now < deadline ? probe(path) : nil
                    // A timed-out read keeps its slot until the filesystem call actually returns.
                    _ = active.withLock { $0.remove(path) }
                    once.resume(ContinuousClock.now < deadline ? available : false)
                    timer.cancel()
                }
            }
        }
    }

    private final class Once: Sendable {
        private let waiter: Mutex<CheckedContinuation<Bool?, Never>?>

        init(_ continuation: CheckedContinuation<Bool?, Never>) { waiter = Mutex(continuation) }

        func resume(_ value: Bool?) {
            waiter.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }?.resume(returning: value)
        }
    }
}
