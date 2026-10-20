import Testing
@testable import FrameScrubCore

@Suite struct SeekTimerTests {
    @Test func measuresFromTheLastStartAndKeepsTen() {
        var timer = SeekTimer()
        #expect(timer.text == nil)
        timer.start(at: 1.0)
        timer.start(at: 1.1)          // a series: measured from the last command
        timer.finish(at: 1.25)
        #expect(!timer.isRunning)
        #expect(abs(timer.recent.last! - 0.15) < 1e-9)
        timer.finish(at: 2)           // not running: ignored
        #expect(timer.recent.count == 1)
        for i in 0..<12 { timer.start(at: Double(i)); timer.finish(at: Double(i) + 0.1) }
        #expect(timer.recent.count == 10)
        #expect(timer.text == "Seek: 100 ms (median of last 10: 100 ms)")
    }
}
