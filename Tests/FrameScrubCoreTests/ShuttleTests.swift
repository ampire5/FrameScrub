import Testing
@testable import FrameScrubCore

@Suite struct ShuttleTests {
    private func s(_ paused: Bool, _ direction: Int, _ speed: Double) -> PlayState {
        PlayState(paused: paused, direction: direction, speed: speed)
    }

    @Test func followsTheSpecTable() {
        let cases: [(PlayState, ShuttleKey, PlayState)] = [
            (s(true, 1, 1), .back, s(false, -1, 1)), (s(true, -1, 3), .forward, s(false, 1, 1)),
            (s(false, 1, 1), .back, s(false, -1, 1)), (s(false, 1, 1), .forward, s(false, 1, 2)),
            (s(false, 1, 2), .forward, s(false, 1, 4)), (s(false, 1, 4), .forward, s(false, 1, 8)),
            (s(false, 1, 8), .forward, s(false, 1, 8)), (s(false, 1, 4), .back, s(false, -1, 1)),
            (s(false, -1, 1), .back, s(false, -1, 2)), (s(false, -1, 2), .back, s(false, -1, 4)),
            (s(false, -1, 4), .back, s(false, -1, 8)), (s(false, -1, 8), .back, s(false, -1, 8)),
            (s(false, -1, 4), .forward, s(false, 1, 1)), (s(false, 1, 2), .stop, s(true, 1, 2)),
            (s(true, -1, 1), .stop, s(true, -1, 1)),
        ]
        for (before, key, after) in cases { #expect(Shuttle.press(key, in: before) == after, "\(before) \(key)") }
    }

    @Test func aSpeedBetweenStepsGoesToTheNextStepUp() {
        #expect(Shuttle.press(.forward, in: s(false, 1, 1.21)).speed == 2)
        #expect(Shuttle.press(.back, in: s(false, -1, 2.5)).speed == 4)
        #expect(Shuttle.press(.forward, in: s(false, 1, 0.5)).speed == 1)
        #expect(Shuttle.press(.forward, in: s(false, 1, 9)).speed == 8)
    }
}
