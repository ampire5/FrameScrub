import Darwin
import Foundation
import Testing
@testable import FrameScrubCore

/// Posters from a folder on a share (docs/bench/2026-10-27-share-posters.md): `FRAMESCRUB_POSTER_DIR=<folder>
/// swift test --filter SharePosterBench`. Per poster: wall time, the process's CPU time and the most threads seen.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_POSTER_DIR"] != nil))
struct SharePosterBench {
    private static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static func threads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    @Test func postersFromAShare() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAMESCRUB_POSTER_DIR"]!)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            .filter { Playlist.videoExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let skip = Int(ProcessInfo.processInfo.environment["FRAMESCRUB_POSTER_SKIP"] ?? "0") ?? 0
        let workers = Int(ProcessInfo.processInfo.environment["FRAMESCRUB_POSTER_WORKERS"] ?? "1") ?? 1
        let files = names.dropFirst(skip).prefix(12).map { dir.appendingPathComponent($0) }
        var peak = Self.threads()
        let sampling = DispatchSource.makeTimerSource(queue: .global())
        let lock = NSLock()
        sampling.schedule(deadline: .now(), repeating: .milliseconds(20))
        sampling.setEventHandler { let n = Self.threads(); lock.withLock { peak = max(peak, n) } }
        sampling.resume()
        let start = Date(), cpu0 = Self.cpu()
        let next = NSLock()
        var index = 0
        var lines: [String] = []
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                let i: Int? = next.withLock { defer { index += 1 }; return index < files.count ? index : nil }
                guard let i else { return }
                let t0 = Date()
                let made = autoreleasepool { KeyframeThumbnail.make(url: files[i], at: nil) }
                let line = String(format: "%5.2f s  %@  %@", Date().timeIntervalSince(t0), made?.facts.codec ?? "-",
                                  files[i].lastPathComponent.prefix(40) as CVarArg)
                next.withLock { lines.append(line) }
            }
        }
        sampling.cancel()
        let wall = Date().timeIntervalSince(start), cpu = Self.cpu() - cpu0
        print("[sharebench] " + lines.joined(separator: "\n[sharebench] "))
        print(String(format: "[sharebench] workers %d: %d posters in %.1f s (%.2f s each), CPU %.1f s (%.0f %% of one core), peak threads %d",
                     workers, files.count, wall, wall / Double(files.count), cpu, cpu / wall * 100, lock.withLock { peak }))
    }
}
