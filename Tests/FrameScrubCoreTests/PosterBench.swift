import Foundation
import Testing
@testable import FrameScrubCore

/// How many posters at a time (docs/bench/2026-10-26-posters.md): `FRAMESCRUB_POSTER_BENCH=1 swift test --filter
/// PosterBench`. Off otherwise: it takes a while and its numbers are the machine's.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_POSTER_BENCH"] != nil))
struct PosterBench {
    @Test func postersPerSecond() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("posterbench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [URL] = []
        for i in 0..<24 {
            let source = Fixtures.url(i % 2 == 0 ? Fixtures.h264 : Fixtures.hevc10)
            let copy = dir.appendingPathComponent("v\(i).\(source.pathExtension)")
            try FileManager.default.copyItem(at: source, to: copy)
            files.append(copy)
        }
        _ = KeyframeThumbnail.make(url: files[0], at: nil)   // warm-up: decoders and libraries loaded
        var lines: [String] = []
        for workers in [1, 2, 3, 4, 6] {
            let start = Date()
            let next = NSLock()
            var index = 0
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while true {
                    let i: Int? = next.withLock { defer { index += 1 }; return index < files.count ? index : nil }
                    guard let i else { return }
                    autoreleasepool { _ = KeyframeThumbnail.make(url: files[i], at: nil) }
                }
            }
            let seconds = Date().timeIntervalSince(start)
            lines.append(String(format: "%d workers: %.2f s, %.1f posters/s", workers, seconds, Double(files.count) / seconds))
        }
        print("[posterbench] " + lines.joined(separator: "\n[posterbench] "))
    }
}
