import Testing
@testable import FrameScrubCore

/// 30 fps, 3000 frames (100 s), keyframes every 90 frames (3 s): 0, 90, 180, …
private let index = FrameIndex(pts: (0..<3000).map(Int64.init), keyframePTS: Set(stride(from: 0, to: 3000, by: 90).map(Int64.init)),
                               timeBase: 1.0 / 30)

@Suite struct CutMarksTests {
    @Test func markInOpensAndMarkOutCloses() {
        var m = CutMarks()
        #expect(m.markIn(at: 100) == 1 && m.open == 100)
        #expect(m.markOut(at: 200) == 1)
        #expect(m.segments == [CutSegment(start: 100, end: 200)] && m.open == nil)
    }

    @Test func markOutBeforeTheOpenStartSwaps() {
        var m = CutMarks(open: 300)
        m.markOut(at: 250)
        #expect(m.segments == [CutSegment(start: 250, end: 300)])
    }

    @Test func insideASegmentInAndOutMoveItsEdges() {
        var m = CutMarks(segments: [CutSegment(start: 100, end: 200)])
        m.markIn(at: 150)
        m.markOut(at: 180)
        #expect(m.segments == [CutSegment(start: 150, end: 180)] && m.open == nil)
    }

    @Test func markOutOutsideExtendsTheSegmentToTheLeftOrStartsAtZero() {
        var m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 500, end: 600)])
        #expect(m.markOut(at: 300) == 1)
        #expect(m.segments.first == CutSegment(start: 100, end: 300))
        var empty = CutMarks()
        empty.markOut(at: 40)
        #expect(empty.segments == [CutSegment(start: 0, end: 40)])
    }

    @Test func overlappingAndTouchingSegmentsMerge() {
        var m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 300, end: 400)])
        m.markOut(at: 299)                      // the end of the first now touches the second
        #expect(m.segments == [CutSegment(start: 100, end: 400)])
        #expect(CutMarks(segments: [CutSegment(start: 50, end: 120), CutSegment(start: 100, end: 150)]).segments
            == [CutSegment(start: 50, end: 150)])
    }

    @Test func numbersCountTheOpenStartAmongTheSegments() {
        var m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 500, end: 600)])
        #expect(m.markIn(at: 300) == 2)
        #expect(m.markIn(at: 550) == 3)         // moves the open start; 550 sorts after the starts 100 and 500
    }

    @Test func deleteAndClear() {
        var m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 500, end: 600)], open: 800)
        #expect(m.delete(at: 550) == 2)
        #expect(m.delete(at: 300) == 2)         // no segment here: the open one, numbered among what is left
        #expect(m.delete(at: 300) == nil)
        #expect(m.clear() == 1 && m.isEmpty)
    }

    @Test func startOfANumber() {
        let m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 500, end: 600)], open: 300)
        #expect(m.start(ofNumber: 2) == 300 && m.start(ofNumber: 3) == 500 && m.start(ofNumber: 4) == nil)
    }

    @Test func snapPicksTheNearerKeyframeWithinTheSegment() {
        var m = CutMarks(segments: [CutSegment(start: 1000, end: 1200)])
        #expect(m.snapStart(at: 1100, index: index) == 1)
        #expect(m.segments[0].start == 990)     // 990 is 10 frames away, 1080 is 80
        var near = CutMarks(segments: [CutSegment(start: 1070, end: 1075)])
        near.snapStart(at: 1072, index: index)
        #expect(near.segments[0].start == 990)  // 1080 is nearer but past the end
        var none = CutMarks()
        #expect(none.snapStart(at: 5, index: index) == nil)
    }

    @Test func boundariesIncludeTheOpenStart() {
        let m = CutMarks(segments: [CutSegment(start: 100, end: 200)], open: 400)
        #expect(m.boundary(before: 150) == 100 && m.boundary(after: 150) == 200)
        #expect(m.boundary(after: 200) == 400 && m.boundary(after: 400) == nil && m.boundary(before: 100) == nil)
    }

    @Test func closedAtThePlayheadOnlyAfterTheOpenStart() {
        let m = CutMarks(open: 300)
        #expect(m.closed(at: 400).segments == [CutSegment(start: 300, end: 400)])
        #expect(m.closed(at: 200) == m)
    }
}

@Suite struct CutHistoryTests {
    @Test func undoAndRedoWalkTheSteps() throws {
        var h = CutHistory()
        let a = CutMarks(), b = CutMarks(open: 10), c = CutMarks(segments: [CutSegment(start: 10, end: 20)])
        h.record(a, label: "Mark 1 in")
        h.record(b, label: "Mark 1 out")
        let u1Step = h.undo(c)
        let u1 = try #require(u1Step)
        #expect(u1.marks == b && u1.label == "Mark 1 out")
        let u2Step = h.undo(b)
        let u2 = try #require(u2Step)
        #expect(u2.marks == a && !h.canUndo)
        let r1Step = h.redo(a)
        let r1 = try #require(r1Step)
        #expect(r1.marks == b && r1.label == "Mark 1 in")
        #expect(h.canRedo)
    }

    @Test func aNewStepDropsTheRedoBranch() {
        var h = CutHistory()
        h.record(CutMarks(), label: "x")
        _ = h.undo(CutMarks(open: 1))
        h.record(CutMarks(), label: "y")
        #expect(!h.canRedo)
    }

    @Test func keepsAtMostTheLimit() {
        var h = CutHistory(limit: 3)
        for i in 0..<5 { h.record(CutMarks(open: i), label: "\(i)") }
        var undone = 0
        var current = CutMarks()
        while let step = h.undo(current) {
            current = step.marks
            undone += 1
        }
        #expect(undone == 3 && current == CutMarks(open: 2))
    }
}

@Suite struct ClipRangesTests {
    @Test func separateIsOneJobPerSegment() {
        let m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 500, end: 600)])
        #expect(m.clipRanges(.separate, index: index) == [[100...200], [500...600]])
    }

    @Test func joinedMergesRangesSharingAKeyframe() {
        let m = CutMarks(segments: [CutSegment(start: 100, end: 150), CutSegment(start: 170, end: 200),
                                    CutSegment(start: 500, end: 600)])
        // 170's keyframe is 90 ≤ 151: one range; 500's keyframe 450 > 201: a range of its own.
        #expect(m.clipRanges(.joined, index: index) == [[100...200, 500...600]])
    }

    @Test func joinedMergesWhenTheNextKeyframeIsWithinTheReorderDelay() {
        // The keyframe 180 is written with the first range already (as a reference of its last frames).
        let m = CutMarks(segments: [CutSegment(start: 100, end: 177), CutSegment(start: 185, end: 200)])
        #expect(m.clipRanges(.joined, index: index) == [[100...200]])
        let apart = CutMarks(segments: [CutSegment(start: 100, end: 170), CutSegment(start: 185, end: 200)])
        #expect(apart.clipRanges(.joined, index: index) == [[100...170, 185...200]])
    }

    @Test func joinedNeedsAnExactIndexForSeveralSegments() {
        let approximate = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 1, frameCount: 3000, timeBase: 1.0 / 30)
        let two = CutMarks(segments: [CutSegment(start: 10, end: 20), CutSegment(start: 40, end: 50)])
        #expect(two.clipRanges(.joined, index: approximate) == nil)
        #expect(CutMarks(segments: [CutSegment(start: 10, end: 20)]).clipRanges(.joined, index: approximate) == [[10...20]])
    }

    @Test func invertedStartsEachGapOnTheNextKeyframe() {
        let m = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 500, end: 600)])
        #expect(m.clipRanges(.inverted, index: index) == [[0...99, 270...499, 630...2999]])
    }

    @Test func invertedDropsGapsShorterThanTheWayToAKeyframe() {
        let m = CutMarks(segments: [CutSegment(start: 0, end: 100), CutSegment(start: 150, end: 2999)])
        #expect(m.clipRanges(.inverted, index: index) == [])
    }

    @Test func invertedNeedsAnExactIndex() {
        let approximate = FrameIndex.approximate(startPTS: 0, ticksPerFrame: 1, frameCount: 3000, timeBase: 1.0 / 30)
        #expect(CutMarks(segments: [CutSegment(start: 10, end: 20)]).clipRanges(.inverted, index: approximate) == nil)
    }

    @Test func modesNameTheirFiles() {
        #expect(ClipMode.separate.nameSuffix == "" && ClipMode.joined.nameSuffix == "_joined"
            && ClipMode.inverted.nameSuffix == "_cut")
    }
}
