import FrameScrubCore
import MouseContract
import Testing

@Test func d100hShuttleAndFileNavigationUseSeparateButtons() {
    var profile = D100HViewingProfile()
    #expect(profile.receive(.button(.topLeft, pressed: true), at: 1) == .command(.shuttleBack))
    #expect(profile.receive(.button(.topLeft, pressed: false), at: 1.8) == nil)
    #expect(profile.receive(.button(.sideUpperLeft, pressed: true), at: 2) == nil)
    #expect(profile.receive(.button(.sideUpperLeft, pressed: false), at: 2.2) == .command(.playlistPrev))
    #expect(profile.receive(.button(.sideUpperRight, pressed: true), at: 3) == nil)
    #expect(profile.receive(.button(.sideUpperRight, pressed: false), at: 3.5) == .edge(fromEnd: true))
}

@Test func d100hFirstHeldModifierWinsAndTurnsConsumeReleaseActions() {
    var profile = D100HViewingProfile()
    #expect(profile.receive(.button(.topMiddle, pressed: true), at: 1) == nil)
    #expect(profile.receive(.button(.bottomRight, pressed: true), at: 1.1) == nil)
    #expect(profile.receive(.turn(.right, knobPressed: false), at: 1.2) == .command(.stepSpeed(1)))
    #expect(profile.receive(.turn(.left, knobPressed: true), at: 1.3) == .command(.stepSpeed(-1)))
    #expect(profile.receive(.button(.topMiddle, pressed: false), at: 2) == nil)
    #expect(profile.receive(.turn(.left, knobPressed: false), at: 2.1) == .command(.addVolume(-5)))
    #expect(profile.receive(.turn(.right, knobPressed: false), at: 2.15) == .command(.addVolume(5)))
    #expect(profile.receive(.button(.bottomRight, pressed: false), at: 2.2) == nil)
    #expect(profile.receive(.button(.bottomLeft, pressed: true), at: 3) == nil)
    #expect(profile.receive(.turn(.left, knobPressed: true), at: 3.1) == .command(.seek(-5, .keyframes)))
}

@Test func d100hUnmodifiedTurnsAndCancellation() {
    var profile = D100HViewingProfile()
    #expect(profile.receive(.turn(.left, knobPressed: false), at: 0) == .scroll(1, fast: false))
    #expect(profile.receive(.turn(.right, knobPressed: true), at: 0.2) == .scroll(-1, fast: true))
    #expect(profile.receive(.button(.topMiddle, pressed: true), at: 1) == nil)
    #expect(profile.receive(.button(.topMiddle, pressed: false), at: 1.5) == .command(.setSpeed(1)))
    #expect(profile.receive(.button(.topMiddle, pressed: true), at: 2) == nil)
    #expect(profile.receive(.button(.topMiddle, pressed: false), at: 2.1) == .command(.shuttleStop))
    #expect(profile.receive(.button(.bottomRight, pressed: true), at: 3) == nil)
    #expect(profile.receive(.cancelled, at: 4) == nil)
    #expect(profile.receive(.button(.bottomRight, pressed: false), at: 5) == nil)
}
@Test(arguments: [false, true])
func d100hClockwiseScrubsForwardAndCounterclockwiseScrubsBack(_ knobPressed: Bool) throws {
    var profile = D100HViewingProfile()
    let router = GestureRouter(inputMap: InputMap(), scrubSettings: Config().scrub)
    for (direction, sign): (D100HDirection, Int) in [(.right, 1), (.left, -1)] {
        router.resetScroll()
        let received = profile.receive(.turn(direction, knobPressed: knobPressed), at: 1)
        let action = try #require(received)
        guard case let .scroll(delta, fast) = action else { Issue.record("Expected a scroll"); continue }
        let sample = ScrollSample(deltaX: 0, deltaY: Double(delta), precise: false, momentum: false,
                                  began: false, time: 1, modifiers: [], rightButton: fast)
        let result = try #require(router.route(sample).first)
        guard case let .scrubFrames(frames, _) = result else { Issue.record("Expected a scrub"); continue }
        #expect(frames * sign > 0)
    }
}
