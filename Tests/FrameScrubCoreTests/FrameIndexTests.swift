import Testing
@testable import FrameScrubCore

@Suite struct FrameIndexTests {
    let index = FrameIndex(pts: [30, 0, 10, 20, 40, 50], keyframePTS: [0, 30], timeBase: 0.1)

    @Test func sortsAndNumbersFrames() {
        #expect(index.isExact)
        #expect(index.frameCount == 6)
        #expect(index.pts(forFrame: 3) == 30)
        #expect(index.frameNumber(forPTS: 30) == 3)
        #expect(index.frameNumber(forPTS: 35) == 3)
        #expect(index.frameNumber(forPTS: -5) == 0)
        #expect(index.frameNumber(forPTS: 999) == 5)
    }

    @Test func findsKeyframes() {
        #expect(index.keyframes == [0, 3])
        #expect(index.keyframe(atOrBefore: 2) == 0)
        #expect(index.keyframe(atOrBefore: 3) == 3)
        #expect(index.keyframe(atOrBefore: 5) == 3)
    }

    @Test func convertsSecondsBothWays() {
        #expect(abs(index.seconds(forFrame: 4) - 4.0) < 1e-9)
        for n in 0..<6 { #expect(index.frameNumber(forSeconds: index.seconds(forFrame: n)) == n) }
    }

    @Test func approximateIndexUsesFrameRate() {
        let a = FrameIndex.approximate(startPTS: 100, ticksPerFrame: 512, frameCount: 10, timeBase: 1.0 / 15360)
        #expect(!a.isExact)
        #expect(a.pts(forFrame: 3) == 100 + 1536)
        #expect(a.frameNumber(forPTS: 100 + 1536 + 10) == 3)
        #expect(a.keyframe(atOrBefore: 7) == 7)
        #expect(a.frameNumber(forSeconds: a.seconds(forFrame: 9)) == 9)
    }

    @Test func agreementDetectsVariableFrameRate() {
        let tb = 1.0 / 15360
        let cfr = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 512, frameCount: 4, timeBase: tb)
        let exactCFR = FrameIndex(pts: [0, 512, 1024, 1536], keyframePTS: [0], timeBase: tb)
        let exactVFR = FrameIndex(pts: [0, 1024, 1536, 2048], keyframePTS: [0], timeBase: tb)
        #expect(cfr.agrees(with: exactCFR))
        #expect(!cfr.agrees(with: exactVFR))
    }

    @Test func mapsToNearestFrameByPTS() {
        let tb = 0.001
        let approx = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 33.333, frameCount: 4, timeBase: tb)
        let exact = FrameIndex(pts: [0, 34, 67, 100], keyframePTS: [0], timeBase: tb)
        #expect(approx.pts(forFrame: 1) == 33)
        #expect(approx.agrees(with: exact))
        #expect(exact.frameNumber(forPTS: 33) == 0)          // "last <=" is off by one here
        #expect(exact.nearestFrameNumber(forPTS: 33) == 1)
        #expect(exact.nearestFrameNumber(forPTS: 50) == 1)
        #expect(exact.nearestFrameNumber(forPTS: 51) == 2)
        #expect(exact.nearestFrameNumber(forPTS: -10) == 0)
        #expect(exact.nearestFrameNumber(forPTS: 999) == 3)
    }

    private var gop250: FrameIndex {
        FrameIndex(pts: (0..<600).map { Int64($0) * 512 }, keyframePTS: [0, 250 * 512, 500 * 512], timeBase: 1.0 / 15360)
    }

    @Test func picksTheNearestKeyframeInTheSeekDirection() {
        let index = gop250
        #expect(index.keyframeSeekTarget(from: 0, toward: 150) == 250)
        #expect(index.keyframeSeekTarget(from: 250, toward: 400) == 500)
        #expect(index.keyframeSeekTarget(from: 500, toward: 350) == 250)
        #expect(index.keyframeSeekTarget(from: 100, toward: 60) == 0)
        #expect(index.keyframeSeekTarget(from: 260, toward: 290) == 500)   // nearest (250) is behind: next one ahead
        #expect(index.keyframeSeekTarget(from: 0, toward: 125) == 250)     // tie goes to 0, which is not ahead
        #expect(index.keyframeSeekTarget(from: 590, toward: 599) == 599)   // nothing ahead: last frame
    }

    @Test func clampedKeyframeSeekNeverMovesAgainstDirection() {
        let index = gop250
        #expect(index.keyframeSeekTarget(from: 599, toward: 599, direction: 1) == 599)
        #expect(index.keyframeSeekTarget(from: 260, toward: 260, direction: 1) != 250)
        #expect((index.keyframeSeekTarget(from: 260, toward: 260, direction: 1) ?? 0) >= 260)
        #expect(index.keyframeSeekTarget(from: 0, toward: 0, direction: -1) == 0)
        #expect(index.keyframeSeekTarget(from: 260, toward: 260, direction: -1) == 250)
    }

    @Test func knowsKeyframesOnlyWhenExact() {
        #expect(gop250.isKeyframe(250))
        #expect(!gop250.isKeyframe(251))
        let approximate = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 512, frameCount: 600, timeBase: 1.0 / 15360)
        #expect(!approximate.isKeyframe(0))
        #expect(approximate.keyframeSeekTarget(from: 0, toward: 150) == nil)
    }
}
