import Testing
@testable import FrameScrubCore

@Suite struct LinkTargetTests {
    @Test func startIsTheTimeElseTheSegmentsBeginning() {
        #expect(LinkTarget(time: 12.5, segments: [10...16]).start == 12.5)
        #expect(LinkTarget(segments: [3.5...9]).start == 3.5)
        #expect(LinkTarget().start == nil)
    }

    @Test func emptyWhenNeitherIsSet() {
        #expect(LinkTarget().isEmpty)
        #expect(!LinkTarget(time: 0).isEmpty)
        #expect(!LinkTarget(segments: [1...2]).isEmpty)
    }

    @Test(arguments: [
        ("1-2", 1.0...2.0), ("1.25 - 7", 1.25...7), ("0-0.5", 0...0.5),
    ] as [(String, ClosedRange<Double>)])
    func parsesSegmentText(_ text: String, expected: ClosedRange<Double>) {
        #expect(LinkTarget.segment(from: text) == expected)
    }

    @Test func parsesSegmentLists() {
        #expect(LinkTarget.segments(from: "10-20,35.5-40") == [10...20, 35.5...40])
        #expect(LinkTarget.segments(from: "10-20") == [10...20])
        #expect(LinkTarget.segments(from: "10-20,x") == nil)
        #expect(LinkTarget.segments(from: "10-20,") == nil)
        #expect(LinkTarget.segments(from: "") == nil)
    }

    @Test func startPrefersTimeOverTheFirstSegment() {
        #expect(LinkTarget(segments: [5...8, 1...2]).start == 5)
        #expect(LinkTarget(time: 6, segments: [5...8]).start == 6)
    }

    @Test(arguments: ["", "5", "a-b", "4-4", "9-3", "-1-2", "1-", "-"])
    func rejectsSegmentText(_ text: String) {
        #expect(LinkTarget.segment(from: text) == nil)
    }

    @Test func segmentFromNumbersNeedsAnOrderedFiniteRange() {
        #expect(LinkTarget.segment(1, 2) == 1...2)
        #expect(LinkTarget.segment(2, 1) == nil)
        #expect(LinkTarget.segment(2, 2) == nil)
        #expect(LinkTarget.segment(-1, 2) == nil)
        #expect(LinkTarget.segment(0, .infinity) == nil)
        #expect(LinkTarget.segment(.nan, 1) == nil)
    }

    @Test func timeIsFiniteAndNotNegative() {
        #expect(LinkTarget.time(0) == 0)
        #expect(LinkTarget.time(12.5) == 12.5)
        #expect(LinkTarget.time(-0.1) == nil)
        #expect(LinkTarget.time(.nan) == nil)
        #expect(LinkTarget.time(.infinity) == nil)
    }
}
