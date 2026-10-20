import Foundation
import Testing
@testable import FrameScrubCore

/// scenes.mp4: 175 frames at 25 fps, keyframes every 25; scenes start at 0, 50 (black), 75 and 125.
@Suite struct SceneSearchTests {
    private func makeSearch(_ name: String = Fixtures.scenes, approximate: Bool = false, lookahead: Int = 8,
                            threshold: Double = 45) throws -> SceneSearch {
        let url = Fixtures.url(name)
        let index = approximate ? try MediaSource(url: url).approximateIndex() : try MediaSource(url: url).buildIndex()
        #expect(index.isExact == !approximate)
        // Generous limits: under a full parallel test run a GOP check of the fixture may take over a second.
        return SceneSearch(url: url, index: index, rotationClockwise: 0, readCache: nil, threshold: threshold,
                           lookahead: lookahead, checkTime: 60, searchTime: 120, preferHardware: true)
    }

    private func find(_ search: SceneSearch, from position: Int, direction: Int, scenes: Int = 1) async -> SceneSearch.Result {
        await withCheckedContinuation { continuation in
            search.find(from: position, direction: direction, scenes: scenes) { continuation.resume(returning: $0) }
        }
    }

    @Test func findsForward() async throws {
        let search = try makeSearch()
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        #expect(await find(search, from: 75, direction: 1) == .found(125))
        #expect(await find(search, from: 125, direction: 1) == .none)
        search.close()
    }

    private func expectFindsBackward(_ search: SceneSearch) async {
        #expect(await find(search, from: 170, direction: -1) == .found(125))
        #expect(await find(search, from: 125, direction: -1) == .found(75))
        #expect(await find(search, from: 80, direction: -1) == .found(0))   // 80 is within 1 s of 75
        #expect(await find(search, from: 10, direction: -1) == .none)
    }

    @Test func findsBackward() async throws {
        let search = try makeSearch()
        await expectFindsBackward(search)
        search.close()
    }

    @Test func findsBackwardWithAnApproximateIndex() async throws {
        let search = try makeSearch(approximate: true)
        await expectFindsBackward(search)
        search.close()
    }

    @Test func findsSeveralScenesAtOnce() async throws {
        let search = try makeSearch()
        #expect(await find(search, from: 0, direction: 1, scenes: 2) == .found(125))
        search.close()
    }

    @Test func findsWithAnApproximateIndex() async throws {
        let search = try makeSearch(approximate: true)
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        #expect(await find(search, from: 75, direction: 1) == .found(125))
        #expect(await find(search, from: 125, direction: 1) == .none)
        search.close()
    }

    @Test func aNewFindCancelsTheOldOne() async throws {
        let search = try makeSearch()
        let results: [SceneSearch.Result] = await withCheckedContinuation { continuation in
            let collected = Collected()
            let done: @Sendable (Int, SceneSearch.Result) -> Void = { slot, result in
                if let all = collected.set(slot, result) { continuation.resume(returning: all) }
            }
            search.find(from: 0, direction: 1, scenes: 1) { done(0, $0) }
            search.find(from: 0, direction: 1, scenes: 1) { done(1, $0) }
        }
        #expect(results == [.cancelled, .found(75)])
        search.close()
    }

    @Test func cancelledFindReportsCancelled() async throws {
        let search = try makeSearch()
        let result: SceneSearch.Result = await withCheckedContinuation { continuation in
            search.find(from: 0, direction: 1, scenes: 1) { continuation.resume(returning: $0) }
            search.cancel()
        }
        #expect(result == .cancelled)
        search.close()
    }

    /// The search has finished and its completion is queued on main when the user cancels: the result is stale.
    @MainActor @Test func aCancelAfterTheWorkFinishedStillReportsCancelled() async throws {
        let search = try makeSearch()
        let result: SceneSearch.Result = await withCheckedContinuation { continuation in
            search.find(from: 0, direction: 1, scenes: 1) { continuation.resume(returning: $0) }
            search.waitUntilIdle()   // main is blocked here, so the completion cannot have run yet
            search.cancel()
        }
        #expect(result == .cancelled)
        search.close()
    }

    /// A file that cannot be opened (a NAS hiccup) is tried again by the next find.
    @Test func retriesOpeningTheFileOnTheNextFind() async throws {
        let fixture = Fixtures.url(Fixtures.scenes)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scenes.mp4")
        let search = SceneSearch(url: url, index: try MediaSource(url: fixture).buildIndex(), rotationClockwise: 0,
                                 readCache: nil, threshold: 45, lookahead: 8, preferHardware: true)
        guard case .failed(let reason) = await find(search, from: 0, direction: 1) else {
            Issue.record("a missing file is a failure, not the edge of the file")
            return
        }
        #expect(reason.contains("open"))
        try FileManager.default.copyItem(at: fixture, to: url)
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        search.close()
    }

    /// A file that is not a video: the search fails, it does not report the edge of the file.
    @Test func anUnreadableFileFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scenes.mp4")
        try Data(repeating: 0x5A, count: 100_000).write(to: url)
        let search = SceneSearch(url: url, index: try MediaSource(url: Fixtures.url(Fixtures.scenes)).buildIndex(),
                                 rotationClockwise: 0, readCache: nil, threshold: 45, lookahead: 8, preferHardware: true)
        guard case .failed(let reason) = await find(search, from: 0, direction: 1) else {
            Issue.record("an unreadable file is a failure")
            return
        }
        #expect(!reason.isEmpty)
        search.close()
    }

    @Test func completionComesOnTheMainQueue() async throws {
        let search = try makeSearch()
        let onMain: Bool = await withCheckedContinuation { continuation in
            search.find(from: 0, direction: 1, scenes: 1) { _ in continuation.resume(returning: Thread.isMainThread) }
        }
        #expect(onMain)
        search.close()
    }

    /// From 0 the find looks at 0, 25, 50 (dark) and 75; the prefetch from 75 then decodes at most `lookahead` more.
    @Test(arguments: [1, 2])
    func prefetchStopsAtTheLookahead(lookahead: Int) async throws {
        let search = try makeSearch(lookahead: lookahead)
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        search.waitUntilIdle()
        #expect(search.cachedLookCount <= 4 + lookahead)
        #expect(search.cachedLookCount > 4)
        search.close()
    }

    @Test func statusText() async throws {
        let search = try makeSearch()
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        #expect(search.statusText.wholeMatch(of: #/Scenes: \d+ keyframes seen, \d+ cuts, \d+ GOPs checked · threshold 45/#) != nil)
        search.close()
    }

    /// scenes_midgop.mp4: keyframes 0, 50, 100; testsrc until 59, smptebars from 60.
    @Test(arguments: [false, true])
    func findsACutInsideAGOP(approximate: Bool) async throws {
        let search = try makeSearch(Fixtures.scenesMidGOP, approximate: approximate)
        #expect(await find(search, from: 0, direction: 1) == .found(60))
        #expect(await find(search, from: 120, direction: -1) == .found(60))
        #expect(await find(search, from: 60, direction: 1) == .none)
        #expect(await find(search, from: 60, direction: -1) == .found(0))
        search.close()
    }

    /// Backwards from inside the GOP that holds the cut: the cut between the keyframe before and the playhead counts.
    @Test func findsACutBehindThePlayheadInItsOwnGOP() async throws {
        let search = try makeSearch(Fixtures.scenesMidGOP)
        #expect(await find(search, from: 95, direction: -1) == .found(60))
        #expect(await find(search, from: 80, direction: -1) == .found(0))   // 80 is within 1 s of 60
        search.close()
    }

    private func checkedGOPs(_ search: SceneSearch) throws -> Int {
        let match = try #require(search.statusText.firstMatch(of: #/(\d+) GOPs checked/#))
        return Int(match.1)!
    }

    /// No time for GOP checks: the cut inside the GOP is judged by the keyframes around it alone.
    @Test func withoutCheckTimeTheKeyframesDecide() async throws {
        let search = try makeSearch(Fixtures.scenesMidGOP, lookahead: 0)
        search.checkTime = 0
        #expect(await find(search, from: 0, direction: 1) != .found(60))
        #expect(try checkedGOPs(search) == 0)
        search.checkTime = 5
        #expect(await find(search, from: 0, direction: 1) == .found(60))
        search.close()
    }

    /// Out of search time the press stops where it got to; the next one goes on from the looks already cached.
    @Test func outOfSearchTimeSaysHowFarItLooked() async throws {
        let search = try makeSearch(lookahead: 0)
        search.searchTime = 0
        #expect(await find(search, from: 0, direction: 1) == .notWithin(0))
        search.searchTime = 10
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        search.close()
    }

    /// Threshold 0 makes every pair of pictures a candidate: from 0 the find checks the GOP 0-25 and lands on 75 (dark
    /// between); the prefetch from 75 checks the GOPs ending at 100 and 125 and finds the cut at 125.
    @Test func prefetchVerifiesAtMostTwoGOPs() async throws {
        let alone = try makeSearch(lookahead: 0, threshold: 0)
        #expect(await find(alone, from: 0, direction: 1) == .found(75))
        alone.waitUntilIdle()
        let own = try checkedGOPs(alone)
        alone.close()
        let search = try makeSearch(lookahead: 100, threshold: 0)
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        search.waitUntilIdle()
        let checked = try checkedGOPs(search)
        #expect(checked > own)
        #expect(checked <= own + 2)
        search.close()
        // The prefetch from 75 needs two checks (100 and 125) to find the next scene: with one allowed it stops after one.
        let capped = try makeSearch(lookahead: 100, threshold: 0)
        capped.prefetchVerifications = 1
        #expect(await find(capped, from: 0, direction: 1) == .found(75))
        capped.waitUntilIdle()
        #expect(try checkedGOPs(capped) == own + 1)
        capped.close()
    }

    /// A permanent delete follows the waiting close at once: the decoder must have let go of the file by then.
    @Test func aWaitingCloseLetsGoOfTheDecoderBeforeItReturns() async throws {
        let search = try makeSearch(lookahead: 100)
        #expect(await find(search, from: 0, direction: 1) == .found(75))   // the prefetch may still be running
        search.close(wait: true)
        #expect(!search.hasDecoder)
    }

    @Test func aNewThresholdAppliesToCachedLooks() async throws {
        let search = try makeSearch()
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        search.threshold = 1000
        #expect(await find(search, from: 0, direction: 1) == .none)
        search.close()
    }

    @Test func aReplacedIndexIsUsedByTheNextFind() async throws {
        let url = Fixtures.url(Fixtures.scenes)
        let search = try makeSearch(approximate: true)
        #expect(await find(search, from: 0, direction: 1) == .found(75))
        search.updateIndex(try MediaSource(url: url).buildIndex())
        #expect(await find(search, from: 75, direction: 1) == .found(125))
        search.close()
    }
}

/// Results of two finds, in slot order once both have arrived.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: SceneSearch.Result] = [:]

    func set(_ slot: Int, _ result: SceneSearch.Result) -> [SceneSearch.Result]? {
        lock.withLock {
            results[slot] = result
            return results.count == 2 ? [results[0]!, results[1]!] : nil
        }
    }
}
