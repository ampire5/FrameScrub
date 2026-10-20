import Testing
@testable import FrameScrubCore

struct EdgeDragTests {
    private let marks = CutMarks(segments: [CutSegment(start: 100, end: 200), CutSegment(start: 300, end: 400)])

    @Test func boundsAreThePairAndTheNeighbours() {
        #expect(EdgeDrag(edge: .start, marks: marks, position: 150, frameCount: 1000).allowed == 0...199)
        #expect(EdgeDrag(edge: .end, marks: marks, position: 150, frameCount: 1000).allowed == 101...298)
        #expect(EdgeDrag(edge: .start, marks: marks, position: 350, frameCount: 1000).allowed == 202...399)
        #expect(EdgeDrag(edge: .end, marks: marks, position: 350, frameCount: 1000).allowed == 301...999)
    }

    @Test func theEdgeFollowsTheFrameWithinTheBounds() {
        let start = EdgeDrag(edge: .start, marks: marks, position: 150, frameCount: 1000)
        #expect(start.original == marks)
        #expect(start.marks(at: 120).segments == [CutSegment(start: 120, end: 200), CutSegment(start: 300, end: 400)])
        #expect(start.marks(at: 250).segments[0] == CutSegment(start: 199, end: 200))   // clamped: never past its end
        let end = EdgeDrag(edge: .end, marks: marks, position: 150, frameCount: 1000)
        #expect(end.marks(at: 299).segments == [CutSegment(start: 100, end: 298), CutSegment(start: 300, end: 400)])
        #expect(end.marks(at: 50).segments[0] == CutSegment(start: 100, end: 101))
    }

    @Test func oneFrameSegmentKeepsItsEdge() {
        let one = CutMarks(segments: [CutSegment(start: 100, end: 100)])
        #expect(EdgeDrag(edge: .start, marks: one, position: 100, frameCount: 1000).allowed == 0...100)
        #expect(EdgeDrag(edge: .end, marks: one, position: 100, frameCount: 1000).allowed == 100...999)
    }

    @Test func openStartDragMovesTheOpenStart() {
        let withOpen = CutMarks(segments: marks.segments, open: 600)
        let drag = EdgeDrag(edge: .start, marks: withOpen, position: 650, frameCount: 1000)
        #expect(drag.allowed == 0...999)
        let moved = drag.marks(at: 620)
        #expect(moved.open == 620 && moved.segments == marks.segments)
    }

    @Test func withoutASegmentItIsAPlainScrub() {
        for edge in [MarkEdge.start, .end] {
            let drag = EdgeDrag(edge: edge, marks: marks, position: 250, frameCount: 1000)
            #expect(drag.allowed == 0...999)
            #expect(drag.marks(at: 260) == marks)
        }
        // The open start is not an end to drag.
        let withOpen = CutMarks(segments: marks.segments, open: 600)
        #expect(EdgeDrag(edge: .end, marks: withOpen, position: 650, frameCount: 1000).marks(at: 620) == withOpen)
    }
}
