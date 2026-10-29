import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct TimelineLensTests {
    @Test func nearbySecondsStayPreciseAndTheEndsAreReachable() {
        let lens = TimelineLens(duration: 2400, center: 720, halfWidth: 400, secondsPerPoint: 1.0 / 64)
        #expect(abs(lens.time(at: -64) - 719) < 0.000001)
        #expect(abs(lens.time(at: 64) - 721) < 0.000001)
        #expect(abs(lens.time(at: -400)) < 0.000001)
        #expect(abs(lens.time(at: 400) - 2400) < 0.000001)
    }

    @Test func lensIsMonotonicAndReversibleOnUnequalSides() {
        let lens = TimelineLens(duration: 2400, center: 720, halfWidth: 400, secondsPerPoint: 1.0 / 64)
        var previous = -1.0
        for x in stride(from: -400.0, through: 400, by: 2) {
            let time = lens.time(at: x)
            #expect(time >= previous)
            #expect(abs(lens.offset(for: time) - x) < 0.00001)
            previous = time
        }
    }

    @Test func theExhaustedSideIsEmptyInsteadOfDuplicatingFrames() {
        let start = TimelineLens(duration: 100, center: 0, halfWidth: 300, secondsPerPoint: 1.0 / 60)
        #expect(start.unclampedTime(at: -60) == -1)
        #expect(start.time(at: -60) == 0)
        #expect(start.offset(for: 0) == 0)
        let end = TimelineLens(duration: 100, center: 100, halfWidth: 300, secondsPerPoint: 1.0 / 60)
        #expect(end.unclampedTime(at: 60) == 101)
        #expect(end.time(at: 60) == 100)
    }

    @Test func shortAndEmptyFilesNeverInventMoreTime() {
        let short = TimelineLens(duration: 0.25, center: 0.125, halfWidth: 300, secondsPerPoint: 1.0 / 60)
        #expect(short.time(at: -300) == 0)
        #expect(short.time(at: 300) == 0.25)
        let empty = TimelineLens(duration: .nan, center: .infinity, halfWidth: 0, secondsPerPoint: 0)
        #expect(empty.time(at: 100).isFinite)
        #expect(empty.time(at: 100) == 0)
        #expect(empty.offset(for: .nan) == 0)
    }

    @Test func aFrozenScaleKeepsTheSameMomentUnderTheFinger() {
        let frozen = TimelineLens(duration: 2400, center: 720, halfWidth: 400, secondsPerPoint: 1.0 / 64)
        let target = frozen.time(at: 250)
        let recentered = TimelineLens(duration: 2400, center: target, halfWidth: 400, secondsPerPoint: 1.0 / 64)
        #expect(abs(recentered.time(at: 0) - target) < 0.000001)
        #expect(abs(frozen.offset(for: target) - 250) < 0.00001)
    }

    @Test func mathematicalEndpointsSurviveFloatingPointRoundoffButNotRealOverscroll() {
        let cell = 876.0 / 9
        let lens = TimelineLens(duration: 3000, center: 0, halfWidth: (876 - cell) / 2, secondsPerPoint: 1 / cell)
        #expect(lens.visibleTime(at: (876 - cell) / 2) == 3000)
        #expect(lens.visibleTime(at: -cell) == nil)
        let end = TimelineLens(duration: 3000, center: 2999.0, halfWidth: 400, secondsPerPoint: 1.0 / 64)
        #expect(end.visibleTime(at: -400) == 0)
        #expect(end.visibleTime(at: 128) == nil)
    }
}
