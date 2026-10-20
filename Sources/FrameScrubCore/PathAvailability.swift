import Foundation

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
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Bool?, Never>?
            init(_ c: CheckedContinuation<Bool?, Never>) { continuation = c }
            func resume(_ value: Bool?) {
                lock.withLock { () -> CheckedContinuation<Bool?, Never>? in
                    defer { continuation = nil }
                    return continuation
                }?.resume(returning: value)
            }
        }
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
}
