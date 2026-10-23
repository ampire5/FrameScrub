import Foundation
import Synchronization
import Testing
@testable import FrameScrubCore

@Suite(.serialized) struct CacheFillerTests {
    private func makeFiller(_ name: String, budgetMiB: Int) throws -> (CacheFiller, FrameCache) {
        let (source, index) = try openIndexed(name)
        let cache = FrameCache(budgetBytes: budgetMiB << 20)
        let filler = CacheFiller(url: source.url, index: index, cache: cache,
                                 estimatedFrameBytes: source.estimatedFrameBytes, playbackLookahead: 30)
        return (filler, cache)
    }

    @Test func fillsBothSidesOfFocusWhilePaused() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)   // ~130 frames of 1080p NV12
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .paused)
        #expect(await eventually { (270...330).allSatisfy(cache.contains) })
        for n in 270...330 {
            if let frame = cache.frame(n) { #expect(readFrameNumber(frame.pixelBuffer) == n) }
        }
        #expect(cache.usedBytes <= 400 << 20)
    }

    // The h264 fixture has keyframes at 0, 250 and 500; 400 MiB holds ~130 frames, a paused window ~70 behind the focus
    // and ~46 ahead of it.

    @Test func loopEndStopsForwardFilling() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.setRegions([300...315], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .playing, direction: 1)   // the lookahead alone would reach 330
        #expect(await eventually { (300...315).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!cache.contains(316))
        filler.setFocus(310, mode: .paused)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!cache.contains(316))
    }

    @Test func loopStartLimitsBackwardFillingToItsKeyframe() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.setRegions([300...320], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(310, mode: .paused)
        #expect(await eventually { (250...320).allSatisfy(cache.contains) })   // 250: the keyframe that decodes 300
        try await Task.sleep(for: .milliseconds(300))
        #expect(!cache.contains(249))
        #expect(!cache.contains(321))
    }

    @Test func settingTheLoopOnARunningFillerConfinesNewWork() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        defer { filler.stop() }
        filler.setRegions([300...320], advance: .repeating)
        filler.setFocus(310, mode: .paused)
        #expect(await eventually { (250...320).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!cache.contains(321))
        #expect(!cache.contains(249))
    }

    @Test func clearingTheLoopRestoresTheNormalWindow() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.setRegions([300...320], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(310, mode: .paused)
        #expect(await eventually { (250...320).allSatisfy(cache.contains) })
        filler.setRegions([], advance: .repeating)
        #expect(await eventually { (240...350).allSatisfy(cache.contains) })
    }

    @Test func loopWiderThanTheCacheKeepsTheWindowAroundTheFocus() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 100)   // ~33 frames: far less than the loop
        filler.setRegions([0...599], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .paused)
        #expect(await eventually { (290...310).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(500))
        #expect(cache.usedBytes <= 100 << 20)
        #expect(!cache.contains(100) && !cache.contains(500))
        filler.setFocus(450, mode: .paused)   // the window follows the focus through the loop
        #expect(await eventually { (440...460).allSatisfy(cache.contains) })
    }

    @Test func aFocusOutsideTheLoopGetsTheNormalWindow() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.setRegions([300...320], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(100, mode: .paused)
        #expect(await eventually { (70...130).allSatisfy(cache.contains) })
    }

    // 1 GiB holds ~330 frames: room for 0...130 and 250...330 (each region down to its keyframe), not the gap between.
    @Test func allRegionsFitAreAllCached() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 1024)
        filler.setRegions([100...130, 300...330], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(110, mode: .paused)
        #expect(await eventually { (0...130).allSatisfy(cache.contains) && (250...330).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(131...249).contains(where: cache.contains))
        #expect(!cache.contains(331))
    }

    @Test func regionsTooBigKeepTheFocusRegion() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)   // room ~116 < 0...240 and 250...450
        filler.setRegions([100...240, 300...450], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(200, mode: .paused)
        #expect(await eventually { (140...240).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(500))
        #expect(!(241...599).contains(where: cache.contains))
    }

    @Test func nextModePrefetchesTheNextStart() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.setRegions([100...240, 300...450], advance: .next)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(230, mode: .playing, direction: 1)   // the lookahead (30) reaches past the region's end
        #expect(await eventually { (230...240).allSatisfy(cache.contains) && (250...280).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(281...450).contains(where: cache.contains))   // 241...249 may be decoded through on the way to 250
    }

    @Test func clearingRegionsRestoresTheNormalWindow() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 1024)
        filler.setRegions([100...130, 300...330], advance: .repeating)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(110, mode: .paused)
        #expect(await eventually { (250...330).allSatisfy(cache.contains) })
        filler.setRegions([], advance: .repeating)
        #expect(await eventually { (131...220).allSatisfy(cache.contains) })
    }

    // Frames cached before the regions (the window around 400) must not push a far region out as it is decoded, or it
    // would be decoded again forever: they make way for it.
    @Test func framesOutsideTheRegionsMakeWayForThem() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .paused)
        #expect(await eventually { (340...440).allSatisfy(cache.contains) })
        filler.setRegions([260...280, 510...530], advance: .repeating)   // 250...280 and 500...530
        filler.setFocus(520, mode: .paused)
        #expect(await eventually { (500...530).allSatisfy(cache.contains) && (250...280).allSatisfy(cache.contains) })
        let seeks = filler.forwardSeeks
        try await Task.sleep(for: .milliseconds(500))
        #expect((500...530).allSatisfy(cache.contains) && (250...280).allSatisfy(cache.contains))
        #expect(filler.forwardSeeks == seeks)
        #expect(cache.usedBytes <= 400 << 20)
    }

    @Test func nonBlockingStopInsertsNothingMore() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        filler.setFocus(300, mode: .paused)
        #expect(await eventually { cache.count > 0 })
        filler.stop(waitForExit: false)
        cache.removeAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(cache.count == 0)
        filler.stop()   // joins the workers
    }

    @Test func steppingBackwardAlwaysYieldsTheRightFrame() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        defer { filler.stop() }
        for start in [599, 260, 251, 40, 520] {
            filler.setFocus(start, mode: .paused)
            for n in stride(from: start, through: max(start - 60, 0), by: -1) {
                filler.setFocus(n, mode: .paused, direction: -1)
                #expect(await eventually(timeout: 5) { cache.contains(n) }, "frame \(n)")
                if let frame = cache.frame(n) { #expect(readFrameNumber(frame.pixelBuffer) == n) }
            }
        }
        #expect(cache.usedBytes <= 400 << 20)
    }

    @Test func steppingBackwardThroughOpenGOPHEVC() async throws {
        let (filler, cache) = try makeFiller(Fixtures.hevc10, budgetMiB: 1500)   // 4K P010 ≈ 25 MB/frame
        filler.start()
        defer { filler.stop() }
        for n in stride(from: 119, through: 0, by: -1) {
            filler.setFocus(n, mode: .paused, direction: -1)
            #expect(await eventually(timeout: 5) { cache.contains(n) }, "frame \(n)")
            if let frame = cache.frame(n) { #expect(readFrameNumber(frame.pixelBuffer) == n) }
        }
        #expect((0..<120).allSatisfy { !cache.isUndecodable($0) })
    }

    /// A worker's VideoToolbox pool keeps the buffers of its evicted frames until its session goes: playing fills the
    /// cache from the forward worker, stepping back then fills it from the backward one.
    @Test func aWorkerWhoseFramesWentToTheOtherGivesItsPoolBack() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 100)   // ~33 frames of 1080p NV12
        filler.start()
        defer { filler.stop() }
        for n in 100...160 {
            filler.setFocus(n, mode: .playing, direction: 1)
            #expect(await eventually(timeout: 5) { cache.contains(n) })
        }
        for n in stride(from: 160, through: 110, by: -1) {
            filler.setFocus(n, mode: .paused, direction: -1)
            #expect(await eventually(timeout: 5) { cache.contains(n) })
        }
        #expect(await eventually { filler.poolReleases >= 1 })   // the forward worker's
    }

    @Test func steppingForwardKeepsTheDecoders() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 100)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .paused)
        #expect(await eventually { (295...305).allSatisfy(cache.contains) })
        let before = filler.decoderCreationAttempts
        for n in 301...340 {
            filler.setFocus(n, mode: .paused, direction: 1)
            #expect(await eventually(timeout: 5) { cache.contains(n + 5) })
        }
        #expect(filler.decoderCreationAttempts == before)   // the forward worker keeps its decoder
    }

    @Test func playingModeDecodesAheadOnly() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(100, mode: .playing, direction: 1)
        #expect(await eventually { (100...130).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!cache.contains(99))    // no backward filling while playing
        #expect(!cache.contains(140))   // lookahead capped at 30 frames
    }

    @Test func renumbersFramesWhenExactIndexArrives() async throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.vfr))
        let cache = FrameCache(budgetBytes: 300 << 20)
        let filler = CacheFiller(url: source.url, index: source.approximateIndex(), cache: cache,
                                 estimatedFrameBytes: source.estimatedFrameBytes, playbackLookahead: 30)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(80, mode: .paused)
        #expect(await eventually { cache.count > 10 })
        filler.updateIndex(try MediaSource(url: source.url).buildIndex(), clearCache: true)
        #expect(await eventually { (70...90).allSatisfy(cache.contains) })
        for n in 70...90 {
            if let frame = cache.frame(n) { #expect(readFrameNumber(frame.pixelBuffer) == n) }
        }
    }

    @Test func tinyBudgetDoesNotRedecodeForever() async throws {
        let (filler, cache) = try makeFiller(Fixtures.hevc10, budgetMiB: 64)   // fits only ~2 frames of 4K P010
        let inserts = Mutex(0)
        filler.onInsert = { _ in inserts.withLock { $0 += 1 } }
        filler.start()
        defer { filler.stop() }
        filler.setFocus(60, mode: .paused)
        #expect(await eventually { cache.contains(60) })
        try await Task.sleep(for: .milliseconds(500))
        let settled = inserts.withLock { $0 }
        try await Task.sleep(for: .milliseconds(1500))
        let extra = inserts.withLock { $0 } - settled
        #expect(extra <= 3, "re-decoded \(extra) frames after settling")
    }

    @Test func stopsRecreatingAFailingDecoderUntilTheIndexChanges() async throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.noDecoder))
        let index = source.approximateIndex()
        let cache = FrameCache(budgetBytes: 400 << 20)
        let filler = CacheFiller(url: source.url, index: index, cache: cache,
                                 estimatedFrameBytes: source.estimatedFrameBytes, playbackLookahead: 30)
        let reported = Mutex(0)
        filler.onError = { _ in reported.withLock { $0 += 1 } }
        filler.start()
        defer { filler.stop() }
        filler.setFocus(100, mode: .paused)
        #expect(await eventually { cache.isUndecodable(100) && cache.isUndecodable(99) })
        try await Task.sleep(for: .milliseconds(300))
        let limit = 2 * CacheFiller.maxCreationFailures   // two workers
        #expect(filler.decoderCreationAttempts <= limit, "\(filler.decoderCreationAttempts) attempts")
        #expect(filler.lastError != nil)
        #expect(reported.withLock { $0 } == 1)

        filler.setFocus(200, mode: .paused)   // nothing spins and nothing is retried meanwhile
        #expect(await eventually { cache.isUndecodable(200) })
        #expect(filler.decoderCreationAttempts <= limit)

        filler.updateIndex(index, clearCache: true)   // a new index retries
        #expect(await eventually { filler.decoderCreationAttempts > limit })
        #expect(await eventually { cache.isUndecodable(200) })
        #expect(filler.decoderCreationAttempts <= 2 * limit)
    }

    /// Spec §8 stress test: seeded random jumps, each followed by stepping backward then forward;
    /// every step must yield exactly the requested frame.
    private func randomJumpStress(_ name: String, jumps: Int, steps: Int, seed: UInt64) async throws {
        let (filler, cache) = try makeFiller(name, budgetMiB: 400)
        let frameCount = try openIndexed(name).1.frameCount
        filler.start()
        defer { filler.stop() }
        var state = seed
        func nextRandom(below bound: Int) -> Int {   // Knuth MMIX LCG, high bits
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<jumps {
            let jump = nextRandom(below: frameCount)
            filler.setFocus(jump, mode: .paused)
            let backward = stride(from: jump - 1, through: max(jump - steps, 0), by: -1).map { ($0, -1) }
            let forward = stride(from: jump + 1, through: min(jump + steps, frameCount - 1), by: 1).map { ($0, 1) }
            for (n, direction) in [(jump, 0)] + backward + forward {
                filler.setFocus(n, mode: .paused, direction: direction)
                #expect(await eventually(timeout: 5) { cache.contains(n) }, "jump \(jump), frame \(n)")
                if let frame = cache.frame(n) { #expect(readFrameNumber(frame.pixelBuffer) == n, "jump \(jump)") }
            }
        }
        #expect(cache.usedBytes <= 400 << 20)
    }

    @Test func randomJumpsThenSteppingYieldExactFrames() async throws {
        try await randomJumpStress(Fixtures.h264, jumps: 30, steps: 30, seed: 0x5EED_F00D)
    }

    @Test func randomJumpsThenSteppingYieldExactFramesVFR() async throws {
        try await randomJumpStress(Fixtures.vfr, jumps: 10, steps: 15, seed: 0xC0FFEE)
    }

    /// PlayerCore keeps one cache for the whole app: frame sizes learned from a 1080p file must
    /// not size the window for a 4K file opened next.
    @Test func sharedCacheDoesNotCarryFrameSizesAcrossFiles() async throws {
        let cache = FrameCache(budgetBytes: 400 << 20)
        let (h264, h264Index) = try openIndexed(Fixtures.h264)
        let first = CacheFiller(url: h264.url, index: h264Index, cache: cache,
                                estimatedFrameBytes: h264.estimatedFrameBytes, playbackLookahead: 30)
        first.start()
        first.setFocus(300, mode: .paused)
        #expect(await eventually { (270...330).allSatisfy(cache.contains) })
        first.stop()
        cache.removeAll()

        let (hevc, hevcIndex) = try openIndexed(Fixtures.hevc10)
        let second = CacheFiller(url: hevc.url, index: hevcIndex, cache: cache,
                                 estimatedFrameBytes: hevc.estimatedFrameBytes, playbackLookahead: 30)
        let inserts = Mutex(0)
        second.onInsert = { _ in inserts.withLock { $0 += 1 } }
        second.start()
        defer { second.stop() }
        second.setFocus(60, mode: .paused)
        #expect(await eventually { cache.contains(60) })
        try await Task.sleep(for: .milliseconds(1000))
        let settled = inserts.withLock { $0 }
        try await Task.sleep(for: .milliseconds(2000))
        let extra = inserts.withLock { $0 } - settled
        #expect(extra <= 3, "re-decoded \(extra) frames after settling")
    }

    @Test func backwardWorkerKeepsALeadBelowTheFocus() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .paused)
        #expect(await eventually { (270...330).allSatisfy(cache.contains) })
        for n in stride(from: 299, through: 230, by: -1) {
            filler.setFocus(n, mode: .paused, direction: -1)
            #expect(await eventually(timeout: 5) { (max(n - 20, 0)...n).allSatisfy(cache.contains) }, "lead below \(n)")
        }
    }

    /// Scrubbing backward faster than the cached run lasts: the backward worker decodes the focus with the frames
    /// below it, so the forward worker does not seek to the same GOP and pre-roll it a second time.
    @Test func fastBackwardScrubbingLeavesTheFocusToTheBackwardWorker() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)   // keyframes 0/250/500
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .paused)
        #expect(await eventually { (370...430).allSatisfy(cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        let seeks = filler.forwardSeeks
        for n in stride(from: 392, through: 160, by: -8) {
            filler.setFocus(n, mode: .paused, direction: -1)
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(await eventually(timeout: 10) { cache.contains(160) })
        #expect(readFrameNumber(cache.frame(160)!.pixelBuffer) == 160)
        #expect(filler.forwardSeeks == seeks, "forward worker seeked \(filler.forwardSeeks - seeks) times")
    }

    @Test func reportsAnUnresolvedFocus() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        #expect(!filler.hasUnresolvedFocus)          // not running yet
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .paused)
        #expect(await eventually { cache.contains(400) && !filler.hasUnresolvedFocus })
    }

    @Test func backwardDecodingWaitsAfterAJump() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let cache = FrameCache(budgetBytes: 400 << 20)
        let time = Mutex(100.0)
        let filler = CacheFiller(url: source.url, index: index, cache: cache, estimatedFrameBytes: source.estimatedFrameBytes,
                                 playbackLookahead: 30, now: { time.withLock { $0 } })
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .paused, direction: 1)
        #expect(await eventually { cache.contains(400) })
        try await Task.sleep(for: .milliseconds(400))          // real time passes, fake time does not
        #expect(!(260..<400).contains { cache.contains($0) })
        time.withLock { $0 += 0.3 }
        #expect(await eventually { (380..<400).allSatisfy(cache.contains) })
    }

    /// A keyframe seek lands past its target; until the player moves the focus there, the forward worker must
    /// go on from the landing, not seek back to the stale target (a whole GOP over the network).
    @Test func forwardFillingContinuesFromTheLanding() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)   // keyframes 0/250/500
        let cache = FrameCache(budgetBytes: 400 << 20)
        let filler = CacheFiller(url: source.url, index: index, cache: cache, estimatedFrameBytes: source.estimatedFrameBytes,
                                 playbackLookahead: 30, now: { 100 })   // frozen: the backward worker stays idle
        let landed = Mutex<Int?>(nil)
        filler.onLanded = { _, n in landed.withLock { $0 = n } }
        filler.start()
        defer { filler.stop() }
        filler.setFocus(150, mode: .paused, direction: 1)            // what PlayerCore does on the seek…
        filler.requestKeyframe(id: 1, toward: 150, from: 0, direction: 1)
        #expect(await eventually { landed.withLock { $0 } == 250 })   // …and the landing it has not handled yet
        #expect(await eventually { (251...260).allSatisfy(cache.contains) })
        #expect(!cache.contains(150))
    }

    /// Scrubbing forward faster than the decoder: catching up with the focus skips the non-reference frames the
    /// focus has already passed, without marking them undecodable, and the focus frame comes out exact.
    @Test func catchingUpWithTheFocusSkipsNonReferenceFrames() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let cache = FrameCache(budgetBytes: 64 << 20)   // ~20 frames of 1080p: a short window ahead
        let filler = CacheFiller(url: source.url, index: index, cache: cache, estimatedFrameBytes: source.estimatedFrameBytes,
                                 playbackLookahead: 30, now: { 100 })   // frozen: the backward worker stays idle
        let inserted = Mutex<[Int]>([])
        filler.onInsert = { n in inserted.withLock { $0.append(n) } }
        filler.start()
        defer { filler.stop() }
        filler.setFocus(100, mode: .paused, direction: 1)
        #expect(await eventually { cache.contains(100) })
        try await Task.sleep(for: .milliseconds(300))
        let ahead = inserted.withLock { $0.max()! }
        filler.setFocus(ahead + 40, mode: .paused, direction: 1)   // within the sequential gap
        #expect(await eventually { cache.contains(ahead + 40) })
        #expect(readFrameNumber(cache.frame(ahead + 40)!.pixelBuffer) == ahead + 40)
        let passed = inserted.withLock { $0 }.filter { (ahead + 1)..<(ahead + 40) ~= $0 }
        #expect(passed.count < 35, "decoded \(passed.count) of the 39 passed frames")
        #expect(!((ahead + 1)..<(ahead + 40)).contains { cache.isUndecodable($0) })
    }

    @Test func switchingToSoftwareReplacesTheDecoders() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)
        filler.start()
        defer { filler.stop() }
        filler.setFocus(10, mode: .paused)
        #expect(await eventually { cache.contains(10) })
        #expect(filler.decoderStatus?.backend == .videoToolbox)
        filler.preferHardware = false
        filler.setFocus(400, mode: .paused)
        #expect(await eventually { cache.contains(400) })
        #expect(filler.decoderStatus?.backend == .software)
        if let frame = cache.frame(400) { #expect(readFrameNumber(frame.pixelBuffer) == 400) }
    }

    @Test func switchingHwdecWhilePlayingWaitsForAKeyframe() async throws {
        let (filler, cache) = try makeFiller(Fixtures.h264, budgetMiB: 400)   // keyframes 0/250/500
        filler.preferHardware = false
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .paused)
        #expect(await eventually { cache.contains(300) })
        #expect(filler.decoderStatus?.backend == .software)
        filler.preferHardware = true
        // Playing on: the software decoder goes on until a keyframe, never re-decoding a GOP.
        for n in stride(from: 300, through: 480, by: 10) {
            filler.setFocus(n, mode: .playing, direction: 1)
            #expect(await eventually { cache.contains(n) })
        }
        #expect(filler.decoderStatus?.backend == .software)
        for n in stride(from: 490, through: 560, by: 10) {
            filler.setFocus(n, mode: .playing, direction: 1)
            #expect(await eventually { cache.contains(n) })
        }
        #expect(filler.decoderStatus?.backend == .videoToolbox)
        for n in 480...560 {
            if let frame = cache.frame(n) { #expect(readFrameNumber(frame.pixelBuffer) == n) }
        }
        // Paused again, a jump keeps VideoToolbox: hwdec no longer depends on playing.
        filler.setFocus(100, mode: .paused)
        #expect(await eventually { cache.contains(100) })
        #expect(filler.decoderStatus?.backend == .videoToolbox)
    }

    // MARK: Reversing (reverse playback spec §4–5)

    /// Frame numbers in the order the filler inserted them.
    final class InsertLog: Sendable {
        private let numbers = Mutex<[Int]>([])
        func append(_ n: Int) { numbers.withLock { $0.append(n) } }
        func withLock<T>(_ body: (inout [Int]) -> T) -> T { numbers.withLock { body(&$0) } }
    }

    private func makeReversingFiller(index: FrameIndex? = nil, budgetMiB: Int = 400) throws -> (CacheFiller, FrameCache, InsertLog) {
        let (source, exact) = try openIndexed(Fixtures.h264)   // 600 frames, 30 fps, keyframes 0/250/500, B-frames
        let cache = FrameCache(budgetBytes: budgetMiB << 20)
        let filler = CacheFiller(url: source.url, index: index ?? exact, cache: cache,
                                 estimatedFrameBytes: source.estimatedFrameBytes, playbackLookahead: 30)
        let inserted = InsertLog()
        filler.onInsert = { inserted.append($0) }
        filler.setReverseDemand(speed: 1, framesPerSecond: 30)
        return (filler, cache, inserted)
    }

    @Test func reversingDecodesChunksDownwardOnce() async throws {
        let (filler, cache, inserted) = try makeReversingFiller()
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { (300...400).allSatisfy(cache.contains) })
        for n in [300, 351, 400] { #expect(readFrameNumber(cache.frame(n)!.pixelBuffer) == n) }
        let numbers = inserted.withLock { $0 }
        #expect(Set(numbers).count == numbers.count, "a frame was decoded twice")
        #expect(filler.reverseLevel == .all)
        #expect(cache.usedBytes <= 400 << 20)
    }

    @Test func reversingFillsAFewFramesAboveTheFocus() async throws {
        let (filler, cache, _) = try makeReversingFiller()
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { (301...(300 + CacheFiller.reverseAhead)).allSatisfy(cache.contains) })
    }

    @Test func reversingCursorRestartsAfterAJump() async throws {
        let (filler, cache, inserted) = try makeReversingFiller()
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { cache.contains(380) })
        let before = inserted.withLock { $0.count }
        filler.setFocus(200, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { (160...200).allSatisfy(cache.contains) })
        let after = inserted.withLock { Array($0[before...]) }
        #expect(after.filter { (250...399).contains($0) }.count <= 1, "the old place kept decoding: \(after)")
    }

    @Test func referencesLevelSkipsWithoutMarkingUndecodable() async throws {
        let (filler, cache, _) = try makeReversingFiller()
        filler.fixedReverseLevel = .references
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { (300..<350).contains { cache.contains($0) } })
        try await Task.sleep(for: .milliseconds(300))
        let decoded = (300...400).filter { cache.contains($0) }.count
        #expect(decoded < 90, "references only, but \(decoded) of 101 frames decoded")
        #expect(!(300...400).contains { cache.isUndecodable($0) })
    }

    @Test func keyframesLevelDecodesOnlyKeyframes() async throws {
        let (filler, cache, inserted) = try makeReversingFiller()
        filler.fixedReverseLevel = .keyframes
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { cache.contains(250) })
        #expect(!inserted.withLock { $0 }.contains { $0 < 400 && $0 != 250 && $0 != 0 })
        #expect(!(260...399).contains { cache.isUndecodable($0) })
    }

    @Test func reversingWithAnApproximateIndexStillGoesDown() async throws {
        let (source, _) = try openIndexed(Fixtures.h264)
        let (filler, cache, _) = try makeReversingFiller(index: source.approximateIndex())
        filler.start()
        defer { filler.stop() }
        filler.setFocus(300, mode: .reversing, direction: -1)
        #expect(await eventually(timeout: 10) { (240..<300).filter { cache.contains($0) }.count >= 20 })
    }

    @Test func reversingBehindPlansTheChunkAheadOfTheFocus() {
        #expect(CacheFiller.reverseChunkEnd(cursor: 400, focus: 420, leadFrames: 50) == 370)   // behind: skip ahead
        #expect(CacheFiller.reverseChunkEnd(cursor: 300, focus: 420, leadFrames: 50) == 300)   // ahead: the cursor
        #expect(CacheFiller.reverseChunkEnd(cursor: nil, focus: 420, leadFrames: 0) == 420)
    }

    @Test func aChunkThatShowedNothingLowersTheLevel() throws {
        let (filler, _, _) = try makeReversingFiller()
        filler.setReverseDemand(speed: 4, framesPerSecond: 50)   // references, no measurement yet
        filler.setFocus(400, mode: .reversing, direction: -1)
        #expect(filler.reverseLevel == .references)
        filler.measured(350...400, level: .references, covered: 0, seconds: 1)   // abandoned before any frame
        #expect(filler.reverseLevel == .keyframes)
    }

    // MARK: Final review fixes

    @Test func aChunkGivenUpForAJumpIsNotMeasured() throws {
        let (filler, _, _) = try makeReversingFiller()
        filler.setReverseDemand(speed: 2, framesPerSecond: 50)
        filler.setFocus(400, mode: .reversing, direction: -1)
        filler.measured(350...400, level: .all, covered: 5, seconds: 0.1, afterJump: true)
        #expect(filler.reverseLevel == .all)
        filler.measured(350...400, level: .all, covered: 5, seconds: 0.1, afterJump: false)
        #expect(filler.reverseLevel == .references)
    }

    @Test func oldMeasurementsAreForgottenForANewSpeed() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        nonisolated(unsafe) var t = 0.0
        let filler = CacheFiller(url: source.url, index: index, cache: FrameCache(budgetBytes: 400 << 20),
                                 estimatedFrameBytes: source.estimatedFrameBytes, playbackLookahead: 30, now: { t })
        filler.setReverseDemand(speed: 2, framesPerSecond: 50)
        filler.setFocus(400, mode: .reversing, direction: -1)
        filler.measured(350...400, level: .all, covered: 50, seconds: 1)   // a slow moment: 50 < 110
        filler.setReverseDemand(speed: 2, framesPerSecond: 50)
        #expect(filler.reverseLevel == .references)
        t = 30
        filler.setReverseDemand(speed: 2, framesPerSecond: 50)   // long ago: tried again
        #expect(filler.reverseLevel == .all)
    }

    @Test func skippingLevelsLeaveTheFramesAboveAlone() async throws {
        let (filler, _, _) = try makeReversingFiller()
        filler.fixedReverseLevel = .references
        filler.start()
        defer { filler.stop() }
        for n in stride(from: 400, through: 340, by: -1) {
            filler.setFocus(n, mode: .reversing, direction: -1)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(filler.forwardSeeks <= 2, "the forward worker sought \(filler.forwardSeeks) times")
    }

    @Test func aNewIndexWhileReversingLeavesNoHole() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let (filler, cache, _) = try makeReversingFiller()
        _ = source
        filler.start()
        defer { filler.stop() }
        filler.setFocus(400, mode: .reversing, direction: -1)
        try await Task.sleep(for: .milliseconds(20))
        filler.updateIndex(index, clearCache: false)
        #expect(await eventually(timeout: 10) { (340...400).allSatisfy(cache.contains) })
    }
}
