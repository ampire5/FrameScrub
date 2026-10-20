import Testing
@testable import FrameScrubCore

@Suite struct ReverseLevelTests {
    private func coverage(_ values: [ReverseLevel: Double]) -> (ReverseLevel) -> Double? { { values[$0] } }

    @Test func cheaperWhenBehindCostlierOnlyOnItsOwnMeasurement() {
        #expect(ReverseLevel.next(current: .all, coverage: coverage([.all: 100]), needed: 100) == .references)  // 100 < 110
        #expect(ReverseLevel.next(current: .all, coverage: coverage([.all: 120]), needed: 100) == .all)
        #expect(ReverseLevel.next(current: .references, coverage: coverage([.all: 140, .references: 300]), needed: 100) == .references)  // 140 < 150
        #expect(ReverseLevel.next(current: .references, coverage: coverage([.all: 160, .references: 300]), needed: 100) == .all)
        #expect(ReverseLevel.next(current: .references, coverage: coverage([.references: 300]), needed: 100) == .references)  // all unmeasured
        #expect(ReverseLevel.next(current: .references, coverage: coverage([.references: 90]), needed: 100) == .keyframes)
        // Keyframes cover a lot, but that says nothing about references: no swinging back.
        #expect(ReverseLevel.next(current: .keyframes, coverage: coverage([.references: 120, .keyframes: 5000]), needed: 400) == .keyframes)
        #expect(ReverseLevel.next(current: .keyframes, coverage: coverage([.keyframes: 10]), needed: 400) == .keyframes)
    }

    @Test func startingLevel() {
        #expect(ReverseLevel.initial(speedMagnitude: 1) == .all && ReverseLevel.initial(speedMagnitude: 2) == .all)
        #expect(ReverseLevel.initial(speedMagnitude: 4) == .references && ReverseLevel.initial(speedMagnitude: 8) == .keyframes)
        #expect(ReverseLevel.best(coverage: coverage([.all: 150]), needed: 100, speedMagnitude: 2) == .all)
        #expect(ReverseLevel.best(coverage: coverage([.all: 100]), needed: 100, speedMagnitude: 2) == .references)  // try the next
        #expect(ReverseLevel.best(coverage: coverage([.all: 50, .references: 90]), needed: 100, speedMagnitude: 2) == .keyframes)
        #expect(ReverseLevel.best(coverage: coverage([:]), needed: 400, speedMagnitude: 8) == .keyframes)   // nothing measured
    }
}
