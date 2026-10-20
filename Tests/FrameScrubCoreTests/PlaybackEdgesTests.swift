import Testing
@testable import FrameScrubCore

@Suite struct PlaybackEdgesTests {
    private func decide(_ n: Int, from position: Int, _ direction: Int, loop: ClosedRange<Int>? = nil, _ mode: ABLoopMode = .loop,
                        marks: [CutSegment]? = nil, pastStart: Bool = false, pastEnd: Bool = false) -> EdgeAction {
        PlaybackEdges.decide(target: n, pastStart: pastStart, pastEnd: pastEnd, position: position, direction: direction,
                             loop: loop, mode: mode, marks: marks, frameCount: 600)
    }

    @Test func fileEdges() {
        #expect(decide(0, from: 3, -1, pastStart: true) == .startOfFile)
        #expect(decide(599, from: 598, 1, pastEnd: true) == .endOfFile)
        #expect(decide(100, from: 102, -1) == .none)
        #expect(decide(100, from: 98, 1) == .none)
    }

    @Test func loopModesForward() {
        #expect(decide(21, from: 19, 1, loop: 10...20, .loop) == .jump(10))
        #expect(decide(21, from: 19, 1, loop: 10...20, .once) == .pause(at: 20))
        #expect(decide(21, from: 19, 1, loop: 10...20, .pingPong) == .turn(at: 20))
        #expect(decide(31, from: 30, 1, loop: 10...20, .once) == .none)   // started past B: plays on
        #expect(decide(599, from: 598, 1, loop: 590...599, .once, pastEnd: true) == .pause(at: 599))
    }

    @Test func loopModesBackward() {
        #expect(decide(9, from: 11, -1, loop: 10...20, .loop) == .jump(20))
        #expect(decide(9, from: 11, -1, loop: 10...20, .once) == .pause(at: 10))
        #expect(decide(9, from: 11, -1, loop: 10...20, .pingPong) == .turn(at: 10))
        #expect(decide(4, from: 5, -1, loop: 10...20, .once) == .none)   // started below A: plays on
        #expect(decide(25, from: 26, -1, loop: 10...20, .pingPong) == .none)   // above B: not in the loop yet
        #expect(decide(0, from: 1, -1, loop: 0...20, .once, pastStart: true) == .pause(at: 0))
    }

    @Test func marksForward() {
        let marks = [CutSegment(start: 10, end: 20), CutSegment(start: 40, end: 50)]
        #expect(decide(21, from: 19, 1, marks: marks) == .jump(40))
        #expect(decide(51, from: 49, 1, marks: marks) == .pause(at: 50))
        #expect(decide(30, from: 29, 1, marks: marks) == .jump(40))   // in a gap: the next mark
        #expect(decide(15, from: 14, 1, marks: marks) == .none)
    }

    @Test func marksBackward() {
        let marks = [CutSegment(start: 10, end: 20), CutSegment(start: 40, end: 50)]
        #expect(decide(39, from: 41, -1, marks: marks) == .jump(20))
        #expect(decide(9, from: 11, -1, marks: marks) == .pause(at: 10))
        #expect(decide(30, from: 31, -1, marks: marks) == .jump(20))   // in a gap: the mark below
        #expect(PlaybackEdges.markStart(position: 5, direction: -1, marks: marks) == 50)   // below all: wraps to the last
        #expect(PlaybackEdges.markStart(position: 30, direction: 1, marks: marks) == 40)
        #expect(PlaybackEdges.markStart(position: 50, direction: 1, marks: marks) == 10)   // at the end of the last: again
        #expect(PlaybackEdges.markStart(position: 10, direction: -1, marks: marks) == 50)  // at the start of the first
        #expect(PlaybackEdges.markStart(position: 15, direction: 1, marks: marks) == nil)  // inside a mark
    }

    @Test func pingPongCyclesAfterOnce() {
        #expect(ABLoopMode.loop.next == .once && ABLoopMode.once.next == .pingPong && ABLoopMode.pingPong.next == .loop)
        #expect(Config.parse("ab-loop=ping-pong").0.abLoop == .pingPong)
        #expect(ABLoopMode.pingPong.title == "Back and forth")
    }
}
