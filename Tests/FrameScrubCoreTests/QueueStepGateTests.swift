import Testing
@testable import FrameScrubCore
import StashKit

@Suite struct QueueStepGateTests {
    @Test func stepsDoNotOverlap() {
        var gate = QueueStepGate()
        let r1 = gate.begin(at: 10)
        #expect(r1)
        #expect(gate.isPending)
        let r2 = gate.begin(at: 11)
        #expect(!r2)   // a second PgDn while Stash has not answered the first
        gate.answered()
        #expect(!gate.isPending)
        let r3 = gate.begin(at: 12)
        #expect(r3)
    }

    @Test func timesOutAfterFiveSeconds() {
        var gate = QueueStepGate()
        let r4 = gate.begin(at: 100)
        #expect(r4)
        let r5 = gate.timedOut(at: 104.9)
        #expect(!r5)
        let r6 = gate.timedOut(at: 105)
        #expect(r6)
        #expect(!gate.isPending)
        let r7 = gate.timedOut(at: 106)
        #expect(!r7)   // reported once
        let r8 = gate.begin(at: 106)
        #expect(r8)
    }

    @Test func aStaleStepGivesWayToANewOne() {
        var gate = QueueStepGate()
        let r9 = gate.begin(at: 0)
        #expect(r9)
        let r10 = gate.begin(at: 5)
        #expect(r10)   // no answer and no timeout check in 5 s: the old step is dead
    }

    @Test func cancelForgetsThePendingStep() {
        var gate = QueueStepGate()
        let began = gate.begin(at: 0)
        #expect(began)
        gate.cancel()   // ⌘W or another file while Stash had not answered
        #expect(!gate.isPending)
        let timedOut = gate.timedOut(at: 6)
        #expect(!timedOut)
    }
}
