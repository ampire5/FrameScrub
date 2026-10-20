import Testing
@testable import FrameScrubCore

@Suite struct ReorderQueueTests {
    @Test func emitsInPresentationOrderWithDepth() {
        var q = ReorderQueue<Int64>(depth: 2)
        var out: [Int64] = []
        for pts in [0, 3, 1, 2, 6, 4, 5] as [Int64] { q.insert(pts, pts: pts); while let e = q.pop() { out.append(e) } }
        while let e = q.popAll() { out.append(e) }
        #expect(out == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test func holdsDepthFrames() {
        var q = ReorderQueue<Int64>(depth: 2)
        q.insert(0, pts: 0); q.insert(1, pts: 1)
        #expect(q.pop() == nil)
        q.insert(2, pts: 2)
        #expect(q.pop() == 0)
    }

    @Test func depthZeroPassesThrough() {
        var q = ReorderQueue<Int64>(depth: 0)
        q.insert(7, pts: 7)
        #expect(q.pop() == 7)
    }

    @Test func lateFrameIsDroppedAndDepthGrows() {
        var q = ReorderQueue<Int64>(depth: 0)
        q.insert(5, pts: 5); #expect(q.pop() == 5)
        q.insert(3, pts: 3)
        #expect(q.count == 0 && q.depth == 1)
    }

    @Test func removeAllForgetsTheLastEmitted() {
        var q = ReorderQueue<Int64>(depth: 0)
        q.insert(5, pts: 5); _ = q.pop()
        q.removeAll()
        q.insert(1, pts: 1)
        #expect(q.pop() == 1 && q.depth == 0)   // after a seek lower pts are normal
    }
}
