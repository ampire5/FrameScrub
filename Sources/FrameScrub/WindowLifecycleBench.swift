#if DEBUG
import AppKit
import FrameScrubCore
import Synchronization

/// Uses the real player window and local fixture copies. Only the I/O delays are injected.
final class WindowLifecycleBench: Sendable {
    enum Mode: String { case home, open, close, hover }
    let mode: Mode
    let directory: URL
    let urls: [URL]
    let delay: TimeInterval
    var openLimit: Int { ProcessInfo.processInfo.environment["FRAMESCRUB_BENCH_OPEN_LIMIT"] == "1" ? 1 : 2 }
    let gate = DispatchSemaphore(value: 0)
    struct Work {
        var active = 0, peakActive = 0, peakPending = 0, metadataReads = 0, cancelledMetadata = 0
        var started = Set<URL>()
    }
    let work = Mutex(Work())

    var config: Config {
        var config = Config()
        config.autoplay = false
        config.volume = 0
        config.singleInstance = false
        return config
    }

    init(mode: Mode, directory: URL, urls: [URL], delay: TimeInterval) {
        self.mode = mode
        self.directory = directory
        self.urls = urls
        self.delay = delay
    }

    static func fromArguments() -> WindowLifecycleBench? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--bench-window-lifecycle") else { return nil }
        let rest = Array(arguments.dropFirst(index + 1))
        guard rest.count >= 3, let mode = Mode(rawValue: rest[0]) else {
            fail("expected MODE STATE_DIRECTORY VIDEO [VIDEO...]")
        }
        guard mode != .home || rest.count >= 5 else { fail("home needs at least three files") }
        guard (mode != .open && mode != .close) || rest.count == 12 else { fail("open/close need ten files") }
        guard mode != .hover || PlaybackDiagnostics.enabled else { fail("hover needs FRAMESCRUB_PIPELINE_REPORT") }
        let directory = URL(fileURLWithPath: rest[1], isDirectory: true)
        let urls = rest.dropFirst(2).map { URL(fileURLWithPath: $0) }
        let delay = Double(ProcessInfo.processInfo.environment["FRAMESCRUB_BENCH_WRITE_DELAY"] ?? "") ?? 0
        return WindowLifecycleBench(mode: mode, directory: directory, urls: urls, delay: delay)
    }

    func startOpen(_ url: URL) {
        guard mode == .open || mode == .close else { return }
        work.withLock {
            $0.active += 1
            $0.peakActive = max($0.active, $0.peakActive)
            $0.started.insert(url)
        }
        if url == urls.first {
            _ = gate.wait(timeout: .now() + 4)
        } else if url != urls.last {
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    func finishOpen() {
        guard mode == .open || mode == .close else { return }
        work.withLock { $0.active -= 1 }
    }

    func readMetadata(cancelled: Bool) {
        guard mode == .open || mode == .close else { return }
        work.withLock {
            $0.metadataReads += 1
            if cancelled { $0.cancelledMetadata += 1 }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("window-lifecycle: \(message)\n".utf8))
        exit(1)
    }

    static func rssMiB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) >> 20
    }
}
#endif
