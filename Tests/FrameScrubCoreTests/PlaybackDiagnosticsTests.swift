import Testing
@testable import FrameScrubCore

@Suite struct PlaybackDiagnosticsTests {
    @Test func boundedSamplesKeepLifetimeCountsAndRecentPercentiles() {
        var samples = DiagnosticSamples(capacity: 3)
        for x in [1.0, 2, 3, 40, 50] { samples.add(x) }
        samples.add(.nan)
        let s = samples.summary()
        #expect(s.count == 5)
        #expect(s.retained == 3)
        #expect(s.over20 == 2)
        #expect(s.p50 == 40)
        #expect(s.p95 == 50)
    }

    @Test func redrawsAndLateCallbacksDoNotInflatePresentedFrames() {
        var ledger = PresentationLedger()
        let a = ledger.arrive(at: 1, playing: true)
        let b = ledger.arrive(at: 1.02, playing: true)
        #expect(ledger.replacedBeforeSubmission == 1)
        ledger.submit(b)
        ledger.submit(b)
        #expect(abs(ledger.present(b, at: 1.04)! - 20) < 0.0001)
        #expect(ledger.present(b, at: 1.05) == nil)
        #expect(ledger.present(a, at: 1.06) == nil)
        #expect(ledger.presented == 1)
        #expect(ledger.submitted == 1)
    }

    @Test func resetRejectsCallbacksFromPreviousFile() {
        var ledger = PresentationLedger()
        let old = ledger.arrive(at: 1, playing: true)
        ledger.reset()
        #expect(ledger.present(old, at: 3) == nil)
        #expect(ledger.presented == 0)
        let next = ledger.arrive(at: 4, playing: false)
        #expect(ledger.present(next, at: 4.02) != nil)
        #expect(ledger.presented == 1)
    }
}

extension PlaybackDiagnosticsTests {
    @Test func latePrePauseTicketCannotSeedTheResumedPlaybackInterval() {
        var ledger = PresentationLedger()
        let old = ledger.arrive(at: 1, playing: true)
        ledger.advancePlaybackPeriod() // pause
        ledger.advancePlaybackPeriod() // resume
        #expect(!ledger.isCurrentPlaybackPeriod(old))
        let resumed = ledger.arrive(at: 4, playing: true)
        #expect(ledger.isCurrentPlaybackPeriod(resumed))
    }
}
