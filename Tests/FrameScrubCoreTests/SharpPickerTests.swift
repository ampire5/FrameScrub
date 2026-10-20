import Testing
@testable import FrameScrubCore

@Suite struct SharpPickerTests {
    /// Feeds (window, frame, score) in order, then finishes; returns every decision.
    private func run(threshold: Double = 0.6, neighbours: Int = 3,
                     _ frames: [(Int, Int, Double?)]) -> [SharpPicker<Int>.Decision] {
        var picker = SharpPicker<Int>(threshold: threshold, neighbours: neighbours)
        var decisions = frames.flatMap { picker.add(window: $0.0, score: $0.2, payload: $0.1) }
        decisions += picker.finish()
        return decisions
    }

    /// One frame per window (frame number = window number) with these scores.
    private func single(_ scores: [Double?]) -> [(Int, Int, Double?)] {
        scores.enumerated().map { ($0.offset, $0.offset, $0.element) }
    }

    @Test func picksTheSharpestFrameOfEachWindow() {
        let decisions = run(threshold: 0, [(0, 0, 5), (0, 1, 9), (0, 2, 9), (1, 3, 2), (1, 4, 1)])
        #expect(decisions.map(\.window) == [0, 1])
        #expect(decisions.map(\.payload) == [1, 3])          // equal scores keep the earlier frame
        #expect(decisions.allSatisfy { $0.write })
    }

    @Test func skipsAWindowBelowTheThresholdOfItsNeighboursMedian() {
        let decisions = run(single([100, 100, 50, 100, 100]))
        #expect(decisions.map(\.write) == [true, true, false, true, true])
    }

    @Test func edgesUseTheNeighboursThatExist() {
        let decisions = run(neighbours: 5, single([10, 100, 100]))
        #expect(decisions.map(\.write) == [false, true, true])   // median of 10, 100, 100 is 100
    }

    @Test func aRangeShorterThanTheNeighbourhoodUsesItAll() {
        let decisions = run(neighbours: 7, single([100, 50]))     // median 75, 0.6 × 75 = 45
        #expect(decisions.map(\.write) == [true, true])
    }

    @Test func decisionsWaitForLaterNeighbours() {
        var picker = SharpPicker<Int>(threshold: 0.6, neighbours: 3)
        #expect(picker.add(window: 0, score: 1, payload: 0).isEmpty)
        #expect(picker.add(window: 1, score: 1, payload: 1).isEmpty)     // window 0 needs window 1 complete
        #expect(picker.add(window: 2, score: 1, payload: 2).map(\.window) == [0])
        #expect(picker.finish().map(\.window) == [1, 2])
    }

    @Test func unmeasuredWindowsAreWrittenAndLeftOutOfMedians() {
        let decisions = run(threshold: 0.8, single([100, nil, 50, 100]))
        // window 2: median of 50 and 100 (window 1 has no score) is 75; 0.8 × 75 = 60 > 50
        #expect(decisions.map(\.write) == [true, true, false, true])
        let mixed = run(threshold: 0, [(0, 0, nil), (0, 1, 5)])
        #expect(mixed.map(\.payload) == [1])
    }
}
