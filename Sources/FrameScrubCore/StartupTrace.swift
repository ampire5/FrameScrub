import Foundation
import os

/// The launch and file-open timeline (scripts/measure-startup.sh prints it). With `FRAMESCRUB_STARTUP_TRACE` set, each mark
/// goes to stderr, in ms since the process started and since the last open began, and to Instruments as a Points of
/// Interest signpost. Without it every call returns at once.
public enum StartupTrace {
    public static let enabled = ProcessInfo.processInfo.environment["FRAMESCRUB_STARTUP_TRACE"] != nil
    private static let signposter = OSSignposter(subsystem: "local.framescrub", category: .pointsOfInterest)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var openStart: Double?
    nonisolated(unsafe) private static var marked = Set<String>()

    /// When the kernel created the process, so dyld and everything before `main` count too.
    private static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let started = info.kp_proc.p_un.__p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1e6
    }()

    /// A file starts opening: later marks also count from here, and `markOnce` marks may come again.
    public static func beginOpen(_ name: String) {
        guard enabled else { return }
        lock.withLock {
            openStart = Date().timeIntervalSince1970
            marked.removeAll()
        }
        mark("open: \(name)")
    }

    public static func mark(_ label: String) {
        guard enabled else { return }
        let now = Date().timeIntervalSince1970
        let sinceOpen = lock.withLock { openStart.map { String(format: " (+%7.1f)", (now - $0) * 1000) } ?? "" }
        signposter.emitEvent("startup", "\(label, privacy: .public)")
        let line = String(format: "[startup] %7.1f ms%@  %@  %@\n", (now - processStart) * 1000, sinceOpen,
                          Thread.isMainThread ? "main" : "bg  ", label)
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The first time `key` happens after an open (the first decoded frame, the first picture on screen).
    public static func markOnce(_ key: String) {
        guard enabled, lock.withLock({ marked.insert(key).inserted }) else { return }
        mark(key)
    }
}
