import Testing
@testable import FrameScrubCore

@Suite struct SkippedFrameCounterTests {
    @Test func countsOnlyFramesReplacedBeforeTheyWereDrawn() {
        var counter = SkippedFrameCounter()
        counter.frameArrived()
        counter.frameArrived()          // the first one never reached the screen
        #expect(counter.skipped == 1)
        counter.frameDrawn()
        counter.frameArrived()
        #expect(counter.skipped == 1)
    }

    @Test func redrawingTheSameFrameDuringAFadeIsNotASkip() {
        var counter = SkippedFrameCounter()
        for _ in 0..<15 {               // a colour fade keeps redrawing; frames keep coming
            counter.frameArrived()
            counter.frameDrawn()
            counter.frameDrawn()
        }
        #expect(counter.skipped == 0)
        counter.reset()
        #expect(counter.skipped == 0)
    }
}
