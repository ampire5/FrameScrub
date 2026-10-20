import Testing
@testable import FrameScrubCore

@Suite struct KeyframeLensTests {
    /// 30 fps, 3000 frames (100 s), keyframes every 90 frames (3 s): 0, 90, 180, …
    private let index = FrameIndex(pts: (0..<3000).map(Int64.init), keyframePTS: Set(stride(from: 0, to: 3000, by: 90).map(Int64.init)),
                                   timeBase: 1.0 / 30)

    @Test func showsTheKeyframesWithinTheSpanAroundTheFrame() throws {
        let lens = try #require(KeyframeLens(index: index, frame: 1000, spanSeconds: 5))
        #expect(lens.range == 850...1150)
        #expect(lens.keyframes == [900, 990, 1080])
        #expect(lens.frame == 1000)
    }

    @Test func theSpanIsClampedToTheFile() throws {
        let start = try #require(KeyframeLens(index: index, frame: 30, spanSeconds: 5))
        #expect(start.range == 0...180)
        #expect(start.keyframes == [0, 90, 180])
        let end = try #require(KeyframeLens(index: index, frame: 2990, spanSeconds: 5))
        #expect(end.range == 2840...2999)
        #expect(end.keyframes == [2880, 2970])
    }

    @Test func labelsTheDistanceToTheNeighbouringKeyframes() throws {
        #expect(try #require(KeyframeLens(index: index, frame: 990)).label == "K")
        #expect(try #require(KeyframeLens(index: index, frame: 1014)).label == "K −0.80 s / +2.20 s")
        #expect(try #require(KeyframeLens(index: index, frame: 2990)).label == "K −0.67 s")
    }

    @Test func noLensWithoutKnownKeyframes() {
        let approximate = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 1, frameCount: 3000, timeBase: 1.0 / 30)
        #expect(KeyframeLens(index: approximate, frame: 1000) == nil)
    }

    @Test func stepsGoFromTheKeyframeThePreviewShows() {
        // Between 990 and 1080 the preview shows 990: a step back goes to the keyframe before it.
        #expect(KeyframeLens.step(index, from: 1014, by: 1) == 1080)
        #expect(KeyframeLens.step(index, from: 1014, by: -1) == 900)
        #expect(KeyframeLens.step(index, from: 990, by: -1) == 900)
        #expect(KeyframeLens.step(index, from: 990, by: 2) == 1170)
        #expect(KeyframeLens.step(index, from: 990, by: -2) == 810)
        #expect(KeyframeLens.step(index, from: 40, by: -3) == 0)
        #expect(KeyframeLens.step(index, from: 2990, by: 1) == 2970)
    }

    @Test func stepsNeedAnExactIndex() {
        let approximate = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 1, frameCount: 3000, timeBase: 1.0 / 30)
        #expect(KeyframeLens.step(approximate, from: 1000, by: 1) == nil)
    }
}

@Suite struct LensScrollTests {
    private func sample(_ dx: Double, _ dy: Double, precise: Bool = true, momentum: Bool = false, began: Bool = false) -> ScrollSample {
        ScrollSample(deltaX: dx, deltaY: dy, precise: precise, momentum: momentum, began: began, time: 0, modifiers: [])
    }

    @Test func aWheelNotchIsOneStep() {
        var scroll = LensScroll()
        #expect(scroll.steps(for: sample(0, 1, precise: false)) == 1)      // wheel up: forward
        #expect(scroll.steps(for: sample(0, -3, precise: false)) == -1)
    }

    @Test func trackpadTravelStepsEveryFortyPoints() {
        var scroll = LensScroll()
        #expect(scroll.steps(for: sample(0, 25, began: true)) == 0)
        #expect(scroll.steps(for: sample(0, 25)) == 1)
        #expect(scroll.steps(for: sample(0, 70)) == 2)
        #expect(scroll.steps(for: sample(0, -20)) == 0)   // turning back drops what was saved up
        #expect(scroll.steps(for: sample(0, -20)) == -1)
    }

    @Test func horizontalSwipesFollowScrubbing() {
        var scroll = LensScroll()
        #expect(scroll.steps(for: sample(-40, 5, began: true)) == 1)      // like a scrub: content pulled left = forward
        var inverted = LensScroll(invertX: true)
        #expect(inverted.steps(for: sample(-40, 5, began: true)) == -1)
    }

    @Test func momentumIsIgnored() {
        var scroll = LensScroll()
        #expect(scroll.steps(for: sample(0, 80, momentum: true)) == 0)
    }
}
