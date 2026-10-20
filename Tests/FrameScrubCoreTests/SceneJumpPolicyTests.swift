import Testing
@testable import FrameScrubCore

private func decide(found: Int, direction: Int, now: Int, retries: Int = 0) -> SceneJumpPolicy.Decision {
    SceneJumpPolicy.decide(found: found, direction: direction, currentPosition: now, retries: retries)
}

@Suite struct SceneJumpPolicyTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let found: Int, direction: Int, press: Int, now: Int, playing: Bool, retries: Int
        let expected: SceneJumpPolicy.Decision
        var testDescription: String { "found \(found) dir \(direction) press \(press) now \(now) playing \(playing) retries \(retries)" }
    }

    static let cases: [Case] = [
        // Forward: ahead of what is on screen.
        Case(found: 100, direction: 1, press: 0, now: 0, playing: false, retries: 0, expected: .jump(100)),
        Case(found: 100, direction: 1, press: 0, now: 60, playing: true, retries: 0, expected: .jump(100)),
        // Playback passed the found start during the search: never rewind, look again from here.
        Case(found: 100, direction: 1, press: 0, now: 100, playing: true, retries: 0, expected: .searchAgain),
        Case(found: 100, direction: 1, press: 0, now: 130, playing: true, retries: 2, expected: .searchAgain),
        // Out of retries: nothing ahead to jump to.
        Case(found: 100, direction: 1, press: 0, now: 130, playing: true, retries: SceneJumpPolicy.maxRetries,
             expected: .noScene),
        // Backward, paused: as found.
        Case(found: 100, direction: -1, press: 300, now: 300, playing: false, retries: 0, expected: .jump(100)),
        // Backward, playing: a start behind the playhead stands, however far playback moved during the search.
        Case(found: 100, direction: -1, press: 300, now: 325, playing: true, retries: 0, expected: .jump(100)),
        Case(found: 100, direction: -1, press: 300, now: 400, playing: true, retries: 0, expected: .jump(100)),
        // Not behind the playhead: look again from here.
        Case(found: 100, direction: -1, press: 0, now: 100, playing: true, retries: 0, expected: .searchAgain),
        Case(found: 100, direction: -1, press: 300, now: 400, playing: true, retries: SceneJumpPolicy.maxRetries,
             expected: .jump(100)),
    ]

    @Test(arguments: cases)
    func decides(_ c: Case) {
        #expect(decide(found: c.found, direction: c.direction, now: c.now, retries: c.retries) == c.expected)
    }

    @Test func backwardOutOfRetriesWithNothingBehindIsNoScene() {
        #expect(decide(found: 400, direction: -1, now: 400, retries: SceneJumpPolicy.maxRetries) == .noScene)
    }
}
