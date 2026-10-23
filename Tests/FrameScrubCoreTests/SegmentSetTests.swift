import Testing
@testable import FrameScrubCore

private let s = SegmentSet(frames: [100...199, 300...399, 500...599], frameCount: 1000)

@Suite struct SegmentSetTests {
    @Test func normalises() {
        let set = SegmentSet(frames: [300...350, 100...120, 340...400, 401...410, 990...1200, 2000...2100], frameCount: 1000)
        #expect(set.ranges == [100...120, 300...410, 990...999])
    }

    @Test func insideMovesAreUntouched() {
        #expect(s.glued(from: 150, to: 170) == 170)
        #expect(s.glued(from: 170, to: 150) == 150)
    }

    @Test func forwardCarriesIntoNext() {
        #expect(s.glued(from: 190, to: 210) == 310)
    }

    @Test func forwardAcrossSeveral() {
        #expect(s.glued(from: 190, to: 300) == 500)
        #expect(s.glued(from: 190, to: 420) == 599)
    }

    @Test func backwardMirrors() {
        #expect(s.glued(from: 305, to: 295) == 195)
        #expect(s.glued(from: 105, to: 0) == 100)
    }

    @Test func nearest() {
        #expect(s.nearest(250) == 300)
        #expect(s.nearest(249) == 199)
        #expect(s.nearest(150) == 150)
    }

    @Test func fromOutsideStartsAtNearest() {
        #expect(s.glued(from: 250, to: 260) == 310)
    }

    @Test func nearestTieGoesEarlier() {
        // 15 is 6 frames from both 9 and 21: a true tie, resolved to the earlier range's edge.
        #expect(SegmentSet(frames: [0...9, 21...29], frameCount: 100).nearest(15) == 9)
        // With 20...29 it is no tie (6 from 9, 5 from 20), so the nearer edge wins.
        #expect(SegmentSet(frames: [0...9, 20...29], frameCount: 100).nearest(15) == 20)
    }

    @Test func indexContaining() {
        #expect(s.index(containing: 350) == 1)
        #expect(s.index(containing: 250) == nil)
    }

    @Test func emptySet() {
        let empty = SegmentSet(frames: [], frameCount: 10)
        #expect(empty.isEmpty)
        #expect(empty.glued(from: 3, to: 7) == 7)
        #expect(empty.nearest(4) == 4)
    }

    @Test func zeroDeltaReturnsNearest() {
        #expect(s.glued(from: 250, to: 250) == 300)
        #expect(s.glued(from: 150, to: 150) == 150)
    }

    @Test func advanceRawValuesAreTheContract() {
        #expect(SegmentAdvance.repeating.rawValue == "repeat")
        #expect(SegmentAdvance.next.rawValue == "next")
    }
}
