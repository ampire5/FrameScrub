import Foundation
import Testing
@testable import FrameScrubCore

private func file(_ i: Int) -> URL { URL(fileURLWithPath: "/v/\(i).mp4") }

@Suite struct PosterDwellTests {
    @Test func dueAfterDelay() {
        var dwell = PosterDwell()
        #expect(dwell.visible([file(0)], now: 0).isEmpty)
        #expect(dwell.nextDeadline == 0.3)
        #expect(dwell.visible([file(0)], now: 0.29).isEmpty)
        #expect(dwell.visible([file(0)], now: 0.3) == [file(0)])
        #expect(dwell.nextDeadline == nil)
    }

    /// A flick across the list: no row stays long enough, so nothing is made.
    @Test func flickQueuesNothing() {
        var dwell = PosterDwell()
        for i in 0..<500 { #expect(dwell.visible([file(i), file(i + 1)], now: Double(i) * 0.05).isEmpty) }
    }

    @Test func capAt24() {
        var dwell = PosterDwell()
        let urls = (0..<40).map(file)
        _ = dwell.visible(urls, now: 0)
        #expect(dwell.visible(urls, now: 0.3) == Array(urls.prefix(24)))
    }

    @Test func onlyOnce() {
        var dwell = PosterDwell()
        _ = dwell.visible([file(0)], now: 0)
        #expect(dwell.visible([file(0)], now: 0.3) == [file(0)])
        #expect(dwell.visible([file(0)], now: 1).isEmpty)
        dwell.reset()
        _ = dwell.visible([file(0)], now: 2)
        #expect(dwell.visible([file(0)], now: 2.3) == [file(0)])
    }

    /// Rows without a local file are skipped.
    @Test func dwellSkipsNil() {
        var dwell = PosterDwell()
        _ = dwell.visible([nil, file(1)], now: 0)
        #expect(dwell.visible([nil, file(1)], now: 0.3) == [file(1)])
    }

    /// A row that left the window starts its wait again when it comes back.
    @Test func leftWindowForgotten() {
        var dwell = PosterDwell()
        _ = dwell.visible([file(0)], now: 0)
        _ = dwell.visible([], now: 0.1)
        _ = dwell.visible([file(0)], now: 0.2)
        #expect(dwell.visible([file(0)], now: 0.3).isEmpty)
        #expect(dwell.visible([file(0)], now: 0.5) == [file(0)])
    }
}
