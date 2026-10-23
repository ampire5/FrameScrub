import Foundation
import QuartzCore
import Testing
@testable import FrameScrubCore

/// The segment lock in the player (segment lock spec §1): two segments, 1–2 s and 4–5 s, of the 30 fps fixture.
@Suite(.serialized) @MainActor struct SegmentLockPlayerTests {
    private let twoSegments: [ClosedRange<Double>] = [1.0...2.0, 4.0...5.0]

    private func makePlayer(now: @escaping () -> Double = CACurrentMediaTime,
                            configure: (inout Config) -> Void = { _ in }, fixture: String = Fixtures.h264,
                            beforeOpen: (PlayerCore) -> Void = { _ in }) throws -> (PlayerCore, RecordingDelegate) {
        var config = Config()
        config.cacheSizeMiB = 400
        configure(&config)
        let player = PlayerCore(config: config, enableAudio: false,
                                fallbackRoot: makeTemporaryDirectory().appendingPathComponent("fallback"), now: now)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        beforeOpen(player)
        try player.open(Fixtures.url(fixture))
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

        let gap = index.frameNumber(forSeconds: 3.0)
        let glued = segments.glued(from: player.position, to: gap)
        player.seek(toSeconds: 3.0)
        #expect(player.position == glued)
        #expect(ranges[1].contains(player.position))

        player.perform(.seek(-60, .exact))
        #expect(player.position == ranges[0].lowerBound)

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

    /// Review focus 2: a keyframe seek before the exact index lands where the decoder found the keyframe; that landing
    /// is held inside the segments too.
    @Test func keyframeLandingIsConstrained() async throws {
        let (player, delegate) = try makePlayer(configure: { $0.seekMode = .keyframe },
                                                beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        player.setSegments(seconds: twoSegments)
        let index = try #require(player.index)
        #expect(!index.isExact)
        delegate.messages.removeAll()
        player.seekFromBar(toFrame: index.frameNumber(forSeconds: 3.1))
        #expect(player.currentSegment != nil)
        #expect(await eventually { delegate.messages.last?.hasSuffix(" K") == true })   // landed on a keyframe (0/250/500)
        #expect(player.currentSegment != nil)
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
}
