import Testing
@testable import FrameScrubCore

@Suite struct ScrubAudioPickerTests {
    /// A picker with every time ready unless listed in `notReady`.
    private struct Harness {
        var picker = ScrubAudioPicker()
        var notReady: Set<Double> = []
        mutating func send(_ event: ScrubAudioPicker.Event) -> Double? {
            let blocked = notReady
            return picker.handle(event) { !blocked.contains($0) }
        }
    }

    @Test func quietUntilTheUserActs() {
        var h = Harness()
        #expect(h.send(.fileOpened) == nil)
        #expect(h.send(.frameShown(1)) == nil)
        #expect(h.send(.userActed) == nil)
        #expect(h.send(.frameShown(2)) == 2)
    }

    @Test func firstStepAfterPauseSounds() {
        var h = Harness()
        _ = h.send(.userActed)
        _ = h.send(.playbackStarted)
        #expect(h.send(.frameShown(3)) == nil)
        _ = h.send(.userActed)          // the pause key
        _ = h.send(.playbackStopped)
        #expect(h.send(.frameShown(3.04)) == nil)
        _ = h.send(.userActed)
        #expect(h.send(.frameShown(3.08)) == 3.08)
    }

    @Test func latestFrameWinsWhenAPieceEnds() {
        var h = Harness()
        _ = h.send(.userActed)
        #expect(h.send(.frameShown(1)) == 1)
        #expect(h.send(.frameShown(1.04)) == nil)
        #expect(h.send(.frameShown(1.08)) == nil)
        #expect(h.send(.snippetEnded) == 1.08)
        #expect(h.send(.snippetEnded) == nil)
    }

    @Test func readyAudioPlaysOnlyTheFrameStillShown() {
        var h = Harness()
        _ = h.send(.userActed)
        h.notReady = [10, 20]
        #expect(h.send(.frameShown(10)) == nil)
        #expect(h.send(.frameShown(20)) == nil)
        h.notReady = [20]
        #expect(h.send(.audioReady) == nil)
        h.notReady = []
        #expect(h.send(.audioReady) == 20)
        #expect(h.send(.audioReady) == nil)
    }

    @Test func nothingWhilePlaying() {
        var h = Harness()
        _ = h.send(.userActed)
        _ = h.send(.playbackStarted)
        #expect(h.send(.frameShown(5)) == nil)
        #expect(h.send(.snippetEnded) == nil)
        #expect(h.send(.audioReady) == nil)
    }

    @Test func endedPieceDoesNotRepeatTheSameFrame() {
        var h = Harness()
        _ = h.send(.userActed)
        #expect(h.send(.frameShown(1)) == 1)
        #expect(h.send(.frameShown(1)) == nil)
        #expect(h.send(.snippetEnded) == nil)
    }

    @Test func aFrameHeardOnTheTapeIsNotReplayedAsAPiece() {
        var h = Harness()
        _ = h.send(.userActed)
        #expect(h.send(.frameShown(1)) == 1)
        _ = h.send(.heardOnTape(1.04))
        #expect(h.send(.snippetEnded) == nil)
        #expect(h.picker.canSound)
        _ = h.send(.playbackStarted)
        #expect(!h.picker.canSound)
    }

    @Test func aNewFileForgetsThePendingFrame() {
        var h = Harness()
        _ = h.send(.userActed)
        #expect(h.send(.frameShown(1)) == 1)
        #expect(h.send(.frameShown(2)) == nil)
        _ = h.send(.fileOpened)
        #expect(h.send(.snippetEnded) == nil)
    }
}
