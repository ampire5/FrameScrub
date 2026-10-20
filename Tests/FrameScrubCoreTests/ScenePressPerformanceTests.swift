import Foundation
import Testing
@testable import FrameScrubCore

/// How long scene jumps keep the user waiting on real files (FRAMESCRUB_SCENE_FILES=/Volumes/…:/Volumes/…). From
/// FRAMESCRUB_SCENE_START seconds (600): 6 presses forward, then 3 back, a second apart like a person looking.
/// FRAMESCRUB_SCENE_CHECK / FRAMESCRUB_SCENE_SEARCH set `scene-check-time` / `scene-search-time` (1 / 4);
/// FRAMESCRUB_SCENE_EXACT=1 builds the exact index first, as the player has it for an MP4 soon after opening.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_SCENE_FILES"] != nil))
struct ScenePressPerformanceTests {
    private func find(_ search: SceneSearch, from position: Int, direction: Int) async -> SceneSearch.Result {
        await withCheckedContinuation { continuation in
            search.find(from: position, direction: direction, scenes: 1) { continuation.resume(returning: $0) }
        }
    }

    @Test func realFileScenePresses() async throws {
        let environment = ProcessInfo.processInfo.environment
        let paths = environment["FRAMESCRUB_SCENE_FILES"]!.split(separator: ":").map(String.init)
        let startSeconds = environment["FRAMESCRUB_SCENE_START"].flatMap(Double.init) ?? 600
        var all: [Double] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let source = try MediaSource(url: url)
            let indexStarted = Date()
            let index = environment["FRAMESCRUB_SCENE_EXACT"] != nil ? try source.buildIndex() : source.approximateIndex()
            let indexMs = Int(Date().timeIntervalSince(indexStarted) * 1000)
            let search = SceneSearch(url: url, index: index, rotationClockwise: 0,
                                     readCache: try ReadCache(url: url, budgetBytes: 384 << 20),
                                     threshold: 45, lookahead: 30,
                                     checkTime: environment["FRAMESCRUB_SCENE_CHECK"].flatMap(Double.init) ?? 1,
                                     searchTime: environment["FRAMESCRUB_SCENE_SEARCH"].flatMap(Double.init) ?? 4,
                                     preferHardware: true)
            var position = index.frameNumber(forSeconds: startSeconds)
            var line = [String]()
            for direction in [1, 1, 1, 1, 1, 1, -1, -1, -1] {
                let started = Date()
                let result = await find(search, from: position, direction: direction)
                let ms = Date().timeIntervalSince(started) * 1000
                all.append(ms)
                if case .found(let frame) = result {
                    position = frame
                    line.append("\(direction > 0 ? "→" : "←")\(Int(ms))ms@\(String(format: "%.1f", index.seconds(forFrame: frame)))")
                } else {
                    line.append("\(direction > 0 ? "→" : "←")\(Int(ms))ms \(result)")
                }
                try await Task.sleep(for: .seconds(1))
            }
            print("SCENES \(url.lastPathComponent.prefix(24)) (index \(index.isExact ? "exact" : "approx") \(indexMs) ms): \(line.joined(separator: " ")) | \(search.statusText)")
            search.close(wait: true)
        }
        let sorted = all.sorted()
        print("SCENES presses \(sorted.count): median \(Int(sorted[sorted.count / 2])) ms, max \(Int(sorted.last!)) ms")
    }
}
