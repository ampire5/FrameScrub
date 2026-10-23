import Foundation
import QuartzCore
import Testing
@testable import FrameScrubCore

/// The segment lock in the player (segment lock spec §1): two segments, 1–2 s and 4–5 s, of the 30 fps fixture.
@Suite(.serialized) @MainActor struct SegmentLockPlayerTests {
    private let twoSegments: [ClosedRange<Double>] = [1.0...2.0, 4.0...5.0]

    private func makePlayer(now: @escaping () -> Double = CACurrentMediaTime,
                            configure: (inout Config) -> Void = { _ in }, fixture: String = Fixtures.h264,
                            resumeStore: ResumeStore? = nil, fallbackPosition: Double? = nil,
                            beforeOpen: (PlayerCore) -> Void = { _ in }) throws -> (PlayerCore, RecordingDelegate) {
        var config = Config()
        config.cacheSizeMiB = 400
        configure(&config)
        let player = PlayerCore(config: config, enableAudio: false,
                                fallbackRoot: makeTemporaryDirectory().appendingPathComponent("fallback"), now: now,
                                resumeStore: resumeStore)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        beforeOpen(player)
        try player.open(Fixtures.url(fixture), fallbackPosition: fallbackPosition)
        return (player, delegate)
    }

    /// The frame ranges `twoSegments` stand for under the player's index.
    private func frames(_ player: PlayerCore) throws -> [ClosedRange<Int>] {
        let index = try #require(player.index)
        return twoSegments.map { index.frameNumber(forSeconds: $0.lowerBound)...index.frameNumber(forSeconds: $0.upperBound) }
    }

    private func ready(_ player: PlayerCore) async -> Bool {
        await eventually { player.index?.isExact == true && player.displayedFrame != nil }
    }

    @Test func settingSegmentsLandsInTheFirst() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        #expect(player.segments?.ranges == ranges)
        #expect(player.position == ranges[0].lowerBound)
        #expect(player.currentSegment == 0)
        #expect(player.segmentsLocked)
        #expect(player.segmentAdvance == .repeating)   // from the config
    }

    @Test func seeksCannotLeave() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        let segments = try #require(player.segments)
        let index = try #require(player.index)

        // An absolute seek into the gap takes the nearest edge (Ruling R21): 3.4 s is nearer to 4 s than to 2 s. Glued,
        // 1.4 s past the end of the first segment would have run on into the second.
        let gap = index.frameNumber(forSeconds: 3.4)
        #expect(segments.glued(from: player.position, to: gap) != ranges[1].lowerBound)
        player.seek(toSeconds: 3.4)
        #expect(player.position == ranges[1].lowerBound)
        player.seek(toSeconds: 0)
        player.goTo(.seconds(2.6))                    // nearer to 2 s
        #expect(player.position == ranges[0].upperBound)
        player.seek(toSeconds: 4.5)

        player.perform(.seek(-60, .exact))
        #expect(player.position == ranges[0].lowerBound)

        player.seek(toSeconds: 0)
        player.seekFromBar(toFrame: index.frameNumber(forSeconds: 3.1))   // nearer to 4 s than to 2 s
        #expect(player.position == ranges[1].lowerBound)

        player.goTo(.seconds(4.5))   // a target inside a segment is kept
        #expect(player.position == index.frameNumber(forSeconds: 4.5))

        // `seek-mode=keyframe` (the default): the keyframe at 250 lies outside, so the 5 s are counted along the segments.
        player.perform(.seek(5, .byConfig))
        #expect(player.position == ranges[1].upperBound)
    }

    @Test func stepAcrossTheGap() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        player.seek(toFrame: ranges[0].upperBound)
        #expect(player.position == ranges[0].upperBound)
        player.step(frames: 1)
        #expect(player.position == ranges[1].lowerBound)
        player.step(frames: -1)
        #expect(player.position == ranges[0].upperBound)
        player.scrub(by: 1)
        #expect(player.position == ranges[1].lowerBound)
    }

    /// A scene jump searches from the playhead, so a cut found in the gap is counted along the segments: from the end of
    /// a segment it runs on into the next one, never back onto the edge it started from (the nearest edge would).
    @Test func sceneJumpsAreGlued() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        let segments = try #require(player.segments)
        let index = try #require(player.index)

        let forwardCut = index.frameNumber(forSeconds: 2.4)   // first half of the gap: nearer to 2 s
        player.seek(toFrame: ranges[0].upperBound)
        let forward = segments.glued(from: player.position, to: forwardCut)
        #expect(ranges[1].contains(forward))
        player.jumpToScene(frame: forwardCut)
        #expect(player.position == forward)
        #expect(player.position != ranges[0].upperBound)

        let backwardCut = index.frameNumber(forSeconds: 3.6)  // second half of the gap: nearer to 4 s
        player.seek(toFrame: ranges[1].lowerBound)
        let backward = segments.glued(from: player.position, to: backwardCut)
        #expect(ranges[0].contains(backward))
        player.jumpToScene(frame: backwardCut)
        #expect(player.position == backward)
        #expect(player.position != ranges[1].lowerBound)
    }

    /// Review focus 2: a keyframe seek before the exact index lands where the decoder found the keyframe; that landing
    /// is held inside the segments too.
    @Test func keyframeLandingIsConstrained() async throws {
        let (player, delegate) = try makePlayer(configure: { $0.seekMode = .keyframe },
                                                beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        player.setSegments(seconds: twoSegments)
        let index = try #require(player.index)
        #expect(!index.isExact)
        let ranges = try frames(player)
        delegate.messages.removeAll()
        player.seekFromBar(toFrame: index.frameNumber(forSeconds: 3.1))   // nearer to 4 s
        #expect(player.position == ranges[1].lowerBound)
        // The decoder's landing on keyframe 0 or 250 (outside both segments) is ignored: the held target stays.
        _ = await eventually(timeout: 0.5) { false }
        player.landed(player.landingID, 250, session: player.session)
        #expect(player.position == ranges[1].lowerBound)
        #expect(!delegate.messages.contains { $0.hasSuffix(" K") })
        // A landing inside a segment is taken.
        player.landed(player.landingID, ranges[1].lowerBound + 10, session: player.session)
        #expect(player.position == ranges[1].lowerBound + 10)
        #expect(delegate.messages.last?.hasSuffix(" K") == true)
    }

    /// Review focus 1: the segments are kept as seconds and built again from them when the exact index arrives.
    @Test func exactIndexKeepsSegmentsInSeconds() throws {
        let (player, _) = try makePlayer(fixture: Fixtures.vfr, beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        let duration = player.durationSeconds
        let seconds = [duration * 0.2...duration * 0.35, duration * 0.6...duration * 0.75]
        player.setSegments(seconds: seconds)
        let before = player.segmentsSeconds
        var announced: FrameIndex?
        player.onIndexReady = { announced = $0 }
        let exact = try MediaSource(url: Fixtures.url(Fixtures.vfr)).buildIndex()
        player.indexReady(exact, session: player.session, status: .scanned(seconds: 0))
        #expect(announced != nil)
        let frameDuration = 1 / (player.info?.frameRate ?? 30)
        let after = player.segmentsSeconds
        #expect(after.count == before.count)
        for (a, b) in zip(before, after) {
            #expect(abs(a.lowerBound - b.lowerBound) <= frameDuration && abs(a.upperBound - b.upperBound) <= frameDuration)
        }
        #expect(player.segments?.ranges == seconds.map { exact.frameNumber(forSeconds: $0.lowerBound)...exact.frameNumber(forSeconds: $0.upperBound) })
        #expect(player.currentSegment != nil)
    }

    /// Segments given before the file is open (no index yet) apply once it opens.
    @Test func segmentsSetBeforeOpeningApplyOnOpen() throws {
        var config = Config()
        config.cacheSizeMiB = 400
        let player = PlayerCore(config: config, enableAudio: false,
                                fallbackRoot: makeTemporaryDirectory().appendingPathComponent("fallback"))
        defer { player.close() }
        player.setSegments(seconds: twoSegments, advance: .next)
        #expect(player.segments == nil)
        #expect(player.setSegmentLock(true) == false)
        try player.open(Fixtures.url(Fixtures.h264))
        let ranges = try frames(player)
        #expect(player.segments?.ranges == ranges)
        #expect(player.segmentsLocked && player.segmentAdvance == .next)
        #expect(player.position == ranges[0].lowerBound)
    }

    /// Segments given before opening are announced once, after the file opens, without a `(nil, false)` in between.
    @Test func segmentsSetBeforeOpeningAreAnnouncedOnce() throws {
        let player = PlayerCore(config: Config(), enableAudio: false,
                                fallbackRoot: makeTemporaryDirectory().appendingPathComponent("fallback"))
        defer { player.close() }
        var calls: [(Int?, Bool)] = []
        player.onSegmentChange = { calls.append(($0, $1)) }
        player.setSegments(seconds: twoSegments)
        let before = calls.count
        try player.open(Fixtures.url(Fixtures.h264))
        let after = calls[before...]
        #expect(after.count == 1)
        #expect(after.first.map { $0.0 == 0 && $0.1 } == true)
    }

    @Test func clearingSegmentsUnlocksAndAnnounces() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        var calls: [(Int?, Bool)] = []
        player.onSegmentChange = { calls.append(($0, $1)) }
        player.setSegments(seconds: [])
        #expect(player.segments == nil)
        #expect(!player.segmentsLocked)
        #expect(calls.last.map { $0.0 == nil && $0.1 == false } == true)
    }

    @Test func segmentsPastTheEndDoNotLock() throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        player.setSegments(seconds: [100.0...200.0])   // the file lasts 20 s
        #expect(player.segments == nil && !player.segmentsLocked)
    }

    @Test func lockingClearsALoopAcrossTheGap() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setLoop(seconds: 1.5...4.5)
        player.setSegments(seconds: twoSegments)
        #expect(player.loopA == nil && player.loopB == nil)

        #expect(player.setSegmentLock(false))
        player.setLoop(seconds: 1.5...4.5)
        #expect(player.setSegmentLock(true))
        #expect(player.loopA == nil && player.loopB == nil)

        player.setLoop(seconds: 4.2...4.8)                   // inside one segment: kept
        #expect(player.setSegmentLock(false) && player.setSegmentLock(true))
        #expect(player.loopA != nil && player.loopB != nil)
    }

    @Test func playingFromTheFileEndStaysInTheSegments() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        let last = player.frameCount - 1
        let end = player.durationSeconds
        for advance in [SegmentAdvance.repeating, .next] {
            player.pause()
            player.setSegments(seconds: [1.0...2.0, end - 2...end + 1], advance: advance)
            let ranges = try #require(player.segments?.ranges)
            #expect(ranges[1].upperBound == last)
            player.seek(toFrame: last)
            #expect(player.position == last)
            player.play()
            #expect(player.position == (advance == .next ? ranges[0].lowerBound : ranges[1].lowerBound))
        }
    }

    @Test func closingClearsTheSegments() throws {
        let (player, _) = try makePlayer()
        player.setSegments(seconds: twoSegments)
        player.close()
        #expect(player.segments == nil && !player.segmentsLocked && player.segmentsSeconds.isEmpty)
        try player.open(Fixtures.url(Fixtures.h264))
        defer { player.close() }
        #expect(player.segments == nil && player.position == 0)
    }

    @Test func unlockFreesAndRelockReturns() async throws {
        let (player, delegate) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        let index = try #require(player.index)
        #expect(player.setSegmentLock(false))
        #expect(!player.segmentsLocked)
        player.seek(toSeconds: 3.0)
        #expect(player.position == index.frameNumber(forSeconds: 3.0))
        #expect(player.setSegmentLock(true))
        #expect(player.position == ranges[0].upperBound)   // 3.0 s is as near to 2 s as to 4 s: the earlier edge

        player.perform(.toggleSegmentLock)
        #expect(!player.segmentsLocked && delegate.messages.last == "Segments unlocked (2)")
        player.perform(.toggleSegmentLock)
        #expect(player.segmentsLocked && delegate.messages.last == "Segments locked: 1/2")
    }

    @Test func abLoopAcrossSegmentsIsRefused() async throws {
        let (player, delegate) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        player.perform(.abLoop)                       // A in the first segment
        #expect(player.goSegment(1))
        player.perform(.abLoop)                       // B in the second
        #expect(delegate.messages.last == "A-B must be inside one segment")
        #expect(player.loopA == nil && player.loopB == nil)

        player.perform(.abLoop)                       // both in the second: allowed
        player.seek(toFrame: ranges[1].lowerBound + 10)
        player.perform(.abLoop)
        #expect(player.loopA == ranges[1].lowerBound && player.loopB == ranges[1].lowerBound + 10)
    }

    @Test func segmentChangeIsAnnounced() async throws {
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        var calls: [(Int?, Bool)] = []
        player.onSegmentChange = { calls.append(($0, $1)) }
        player.setSegments(seconds: twoSegments)
        #expect(calls.last.map { $0.0 == 0 && $0.1 } == true)
        #expect(player.goSegment(1))
        #expect(calls.last.map { $0.0 == 1 && $0.1 } == true)
        #expect(!player.goSegment(2))
        let count = calls.count
        player.step(frames: 1)                        // still in segment 1: nothing new
        #expect(calls.count == count)
        #expect(player.setSegmentLock(false))
        #expect(calls.last.map { $0.0 == 1 && !$0.1 } == true)
    }

    @Test func repeatModeLoopsTheCurrentSegment() async throws {
        var now = 1000.0
        let (player, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        player.seek(toFrame: ranges[0].upperBound - 5)
        player.perform(.cyclePause)
        now += 0.5                                    // 15 frames on: past the end of the first segment
        player.tick()
        #expect(player.position == ranges[0].lowerBound)
    }

    @Test func nextModeWrapsDuringPlayback() async throws {
        var now = 1000.0
        let (player, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: twoSegments, advance: .next)
        let ranges = try frames(player)
        player.seek(toFrame: ranges[0].upperBound - 5)
        player.perform(.cyclePause)
        now += 0.5                                    // past the end of the first: on to the second
        player.tick()
        #expect(player.position == ranges[1].lowerBound)
        player.perform(.cyclePause)
        player.seek(toFrame: ranges[1].upperBound - 5)
        player.perform(.cyclePause)
        now += 0.5                                    // past the end of the last: back to the first
        player.tick()
        #expect(player.position == ranges[0].lowerBound)
    }

    @Test func nextModeWrapsBackwardDuringPlayback() async throws {
        var now = 1000.0
        let (player, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: twoSegments, advance: .next)
        let ranges = try frames(player)
        player.seek(toFrame: ranges[1].lowerBound + 5)
        player.perform(.shuttleBack)                  // backward at 1×
        #expect(!player.isPaused && player.direction == -1)
        now += 0.5                                    // before the start of the second: back to the end of the first
        player.tick()
        #expect(player.position == ranges[0].upperBound)
        now += 1.5                                    // before the start of the first: round to the end of the last
        player.tick()
        #expect(player.position == ranges[1].upperBound)
    }

    @Test func playbackIntoASegmentIsAnnounced() async throws {
        var now = 1000.0
        let (player, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        #expect(player.setSegmentLock(false))
        player.seek(toFrame: ranges[1].lowerBound - 5)   // unlocked: in the gap
        var calls: [(Int?, Bool)] = []
        player.onSegmentChange = { calls.append(($0, $1)) }
        player.perform(.cyclePause)
        now += 0.5                                    // 15 frames on: inside the second segment
        player.tick()
        #expect(player.currentSegment == 1)
        #expect(calls.count == 1 && calls.last.map { $0.0 == 1 && !$0.1 } == true)
    }

    @Test func noSegmentsToggleRefuses() throws {
        let (player, delegate) = try makePlayer()
        defer { player.close() }
        player.perform(.toggleSegmentLock)
        #expect(delegate.messages.last == "No segments")
        #expect(!player.setSegmentLock(true))
        player.setSegments(seconds: twoSegments)
        player.setSegments(seconds: [])               // an empty list clears them
        #expect(player.segments == nil && !player.segmentsLocked)
        player.perform(.toggleSegmentLock)
        #expect(delegate.messages.last == "No segments")
    }

    // Segments 270...300 and 540...570 (keyframes 250 and 500) fit a 1 GiB cache: both are cached, the gap is not;
    // unlocked, the normal window comes back.
    @Test func lockedSegmentsAreTheCacheRegions() async throws {
        let (player, _) = try makePlayer(configure: { $0.cacheSizeMiB = 1024 })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: [9.0...10.0, 18.0...19.0])
        #expect(await eventually { (250...300).allSatisfy(player.cache.contains) && (500...570).allSatisfy(player.cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(301...499).contains(where: player.cache.contains))
        #expect(player.setSegmentLock(false))
        #expect(await eventually { (301...360).allSatisfy(player.cache.contains) })
    }
    private func temporaryStore() -> ResumeStore {
        ResumeStore(url: makeTemporaryDirectory().appendingPathComponent("positions.json"))
    }

    /// Ruling R19: a landing with segments and no time starts at the first segment, over a remembered position inside
    /// the second (and over Stash's resume point); the remembered position is not announced on the way.
    @Test func landingStartsAtTheFirstSegmentOverTheResumePosition() throws {
        for lock in [true, false] {
            let store = temporaryStore()
            store.save(ResumeEntry(position: 4.5), for: Fixtures.url(Fixtures.h264))
            let (player, _) = try makePlayer(resumeStore: store)
            defer { player.close() }
            #expect(player.position == player.index?.frameNumber(forSeconds: 4.5))
            var calls: [(Int?, Bool)] = []
            player.onSegmentChange = { calls.append(($0, $1)) }
            player.applyLanding(LinkTarget(segments: [4.0...5.0, 1.0...2.0], lock: lock))   // not in order
            let ranges = try frames(player)
            #expect(player.position == ranges[0].lowerBound)
            #expect(player.segmentsLocked == lock)
            #expect(calls.count == 1 && calls.last.map { $0.0 == 0 && $0.1 == lock } == true)
        }
        let (stash, _) = try makePlayer(resumeStore: temporaryStore(), fallbackPosition: 4.5)
        defer { stash.close() }
        stash.applyLanding(LinkTarget(segments: twoSegments, advance: .next))
        #expect(try stash.position == frames(stash)[0].lowerBound && stash.segmentAdvance == .next)
    }

    /// A landing's time wins over the first segment; in a gap it takes the nearest edge; alone it is a plain seek.
    @Test func landingTimeIsHeldToTheNearestEdge() throws {
        let store = temporaryStore()
        store.save(ResumeEntry(position: 1.5), for: Fixtures.url(Fixtures.h264))
        let (player, _) = try makePlayer(resumeStore: store)
        defer { player.close() }
        let index = try #require(player.index)
        player.applyLanding(LinkTarget(time: 4.5, segments: twoSegments))
        #expect(player.position == index.frameNumber(forSeconds: 4.5))
        player.applyLanding(LinkTarget(time: 3.4, segments: twoSegments))
        #expect(try player.position == frames(player)[1].lowerBound)
        player.applyLanding(LinkTarget(segments: []))
        #expect(player.segments != nil)               // nothing to apply: the set stays
        player.setSegments(seconds: [])
        player.applyLanding(LinkTarget(time: 7))
        #expect(player.position == index.frameNumber(forSeconds: 7) && player.segments == nil)
    }

    /// Segments given before opening and a remembered position in the gap with a loop across it: the loop goes, the
    /// position takes the nearest edge (not counted along the segments from the first).
    @Test func pendingSegmentsHoldTheResumePosition() throws {
        let store = temporaryStore()
        store.save(ResumeEntry(position: 3.4, loopA: 1.5, loopB: 4.5), for: Fixtures.url(Fixtures.h264))
        let (player, _) = try makePlayer(resumeStore: store, beforeOpen: { $0.setSegments(seconds: twoSegments) })
        defer { player.close() }
        let ranges = try frames(player)
        #expect(player.segmentsLocked)
        #expect(player.loopA == nil && player.loopB == nil)
        #expect(player.position == ranges[1].lowerBound)
    }

    /// Segments given before opening that all fall past the end of the file leave nothing locked.
    @Test func pendingSegmentsPastTheEndDoNotLock() throws {
        let (player, _) = try makePlayer(beforeOpen: { $0.setSegments(seconds: [100.0...200.0]) })
        defer { player.close() }
        #expect(player.segments == nil && !player.segmentsLocked)
    }

    /// `setSegments` says whether anything of the set falls inside the open file (the plugin's request fails when not).
    @Test func setSegmentsReportsASetOutsideTheFile() throws {
        let unopened = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory())
        #expect(unopened.setSegments(seconds: [100.0...200.0]))   // no file yet: it waits for one
        let (player, _) = try makePlayer()
        defer { player.close() }
        #expect(!player.setSegments(seconds: [100.0...200.0]))
        #expect(player.setSegments(seconds: [1.0...2.0, 100.0...200.0]))
        #expect(player.setSegments(seconds: []))
    }

    /// Repeat with `ab-loop=once`: playback pauses at the end of the segment; playing on starts it over.
    @Test func repeatWithOncePausesAtTheSegmentEnd() async throws {
        var now = 1000.0
        let (player, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .once })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        player.seek(toFrame: ranges[0].upperBound - 5)
        player.perform(.cyclePause)
        now += 0.5                                    // 15 frames on: past the end of the first segment
        player.tick()
        #expect(player.position == ranges[0].upperBound && player.isPaused)
        player.perform(.cyclePause)                   // from the end: over again from the start
        #expect(player.position == ranges[0].lowerBound && !player.isPaused)
    }

    /// Repeat with `ab-loop=ping-pong`: playback turns at both ends of the segment.
    @Test func repeatWithPingPongTurnsAtTheSegmentEnds() async throws {
        var now = 1000.0
        let (player, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .pingPong })
        defer { player.close() }
        #expect(await ready(player))
        player.setSegments(seconds: twoSegments)
        let ranges = try frames(player)
        player.seek(toFrame: ranges[0].upperBound - 5)
        player.perform(.cyclePause)
        now += 0.5                                    // past the end: turn there
        player.tick()
        #expect(player.position == ranges[0].upperBound && player.direction == -1 && !player.isPaused)
        now += 1.5                                    // 45 frames back: before the start, turn there
        player.tick()
        #expect(player.position == ranges[0].lowerBound && player.direction == 1 && !player.isPaused)
    }

    /// An A–B loop inside a locked segment is the cache's only region: the other segment is not cached (spec §3).
    @Test func anABLoopIsCachedInsteadOfTheSegments() async throws {
        let (player, _) = try makePlayer(configure: { $0.cacheSizeMiB = 1024 })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toSeconds: 18.5)                  // in the loop: the cache's focus
        player.setLoop(seconds: 18.2...18.8)          // frames 546...564, keyframe 500
        player.setSegments(seconds: [9.0...10.0, 18.0...19.0])
        #expect(player.currentSegment == 1 && player.loopA != nil)
        #expect(await eventually { (500...564).allSatisfy(player.cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(250...300).contains(where: player.cache.contains))
        #expect(!(565...570).contains(where: player.cache.contains))
    }
}
