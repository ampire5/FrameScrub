import Testing
@testable import FrameScrubCore

@Suite struct GestureRouterTests {
    private func sample(_ dx: Double, _ dy: Double, precise: Bool = true, momentum: Bool = false,
                        began: Bool = false, t: Double = 0, mods: Modifiers = []) -> ScrollSample {
        ScrollSample(deltaX: dx, deltaY: dy, precise: precise, momentum: momentum, began: began, time: t, modifiers: mods)
    }

    private func frames(_ actions: [GestureAction]) -> Int {
        actions.reduce(0) { total, action in
            if case let .scrubFrames(n, _) = action { return total + n }
            return total
        }
    }

    private func router(_ extra: String = "") -> GestureRouter {
        var map = InputMap()
        map.apply(extra)
        return GestureRouter(inputMap: map, scrubSettings: ScrubSettings())
    }

    @Test func trackpadHorizontalScrubs() {
        let r = router()
        let total = (0..<40).reduce(0) { $0 + frames(r.route(sample(-2, 0, t: Double($1) * 0.016))) }
        #expect(total == 10)
    }

    @Test func shiftTrackpadScrubsFast() {
        let r = router()
        let total = (0..<40).reduce(0) { $0 + frames(r.route(sample(-2, 0, t: Double($1) * 0.016, mods: .shift))) }
        #expect(total == 100)
    }

    @Test func rightButtonScrollScrubsFastOnEitherAxis() {
        func total(_ dx: Double, _ dy: Double, precise: Bool = true) -> Int {
            let r = router()
            return (0..<40).reduce(0) {
                let s = ScrollSample(deltaX: dx, deltaY: dy, precise: precise, momentum: false, began: false,
                                     time: Double($1) * 0.016, modifiers: [], rightButton: true)
                return $0 + frames(r.route(s))
            }
        }
        #expect(total(-2, 0) == 100)          // same as Shift+trackpad
        #expect(total(0, -2) == 100)          // vertical scroll scrubs too (volume binding is bypassed)
        #expect(total(2, 0) == -100)
        #expect(total(0, 1, precise: false) < 0)
    }

    @Test func rightButtonScrollFollowsItsBindings() {
        let r = router("MBTN_RIGHT+WHEEL_LEFT step-speed down\nMBTN_RIGHT+WHEEL_RIGHT step-speed up")
        func wheel(_ dx: Double, _ dy: Double, _ t: Double) -> [GestureAction] {
            r.route(ScrollSample(deltaX: dx, deltaY: dy, precise: false, momentum: false, began: false, time: t,
                                 modifiers: [], rightButton: true))
        }
        #expect(wheel(0.1, 0, 0) == [.command(.stepSpeed(-1))])        // one notch, one step
        #expect(wheel(-7.6, 0, 0.02) == [.command(.stepSpeed(1))])
        #expect(frames(wheel(0, -1, 0.5)) > 1)                           // vertical still scrubs fast
    }

    @Test func rightButtonScrollHonoursSettingsMultiplier() {
        var settings = ScrubSettings()
        settings.fastMultiplier = 20
        let r = GestureRouter(inputMap: InputMap(), scrubSettings: settings)
        let total = (0..<40).reduce(0) {
            $0 + frames(r.route(ScrollSample(deltaX: -2, deltaY: 0, precise: true, momentum: false, began: false,
                                             time: Double($1) * 0.016, modifiers: [], rightButton: true)))
        }
        #expect(total == 200)
    }

    @Test func trackpadVerticalChangesVolumeEvery40Points() {
        let r = router()
        var actions: [GestureAction] = []
        for i in 0..<10 { actions += r.route(sample(0, 10, t: Double(i) * 0.016)) }
        #expect(actions == [.command(.addVolume(2)), .command(.addVolume(2))])
    }

    @Test func momentumNeverFiresDiscreteCommands() {
        #expect(router().route(sample(0, 100, momentum: true)) == [])
    }

    @Test func mouseWheelFiresOncePerNotch() {
        let r = router()
        #expect(r.route(sample(0, 1, precise: false, mods: .alt)) == [.command(.addVolume(2))])
        #expect(r.route(sample(0, -1, precise: false, mods: .alt)) == [.command(.addVolume(-2))])
        #expect(r.route(sample(0.1, 0, precise: false)) == [.command(.seek(-10, .byConfig))])    // the side wheel
        #expect(r.route(sample(-0.1, 0, precise: false)) == [.command(.seek(10, .byConfig))])
    }

    @Test func plainWheelScrubsByDefault() {
        let r = router()
        #expect(r.route(sample(0, 1, precise: false, t: 0)) == [.scrubFrames(-1, ticks: true)])    // wheel up goes back, like the old WHEEL_LEFT
        #expect(r.route(sample(0, -1, precise: false, t: 5)) == [.scrubFrames(1, ticks: true)])
    }

    /// Keyframe / mark ticks only for a plain wheel scrub: not the trackpad, not `scrub fast`, not an accelerated spin.
    @Test func onlyAPlainWheelScrubTicks() {
        func ticks(_ actions: [GestureAction]) -> [Bool] {
            actions.compactMap { if case let .scrubFrames(_, ticks) = $0 { ticks } else { nil } }
        }
        #expect(ticks(router().route(sample(0, -1, precise: false, t: 0))) == [true])
        #expect(ticks(router().route(sample(-1, 0, precise: false, t: 0, mods: [.shift, .alt]))) == [false])   // scrub fast
        let trackpad = router()
        #expect(ticks((0..<40).flatMap { trackpad.route(sample(-2, 0, t: Double($0) * 0.016)) }).allSatisfy { !$0 })
        let spin = router()
        let spun = ticks((0..<20).flatMap { spin.route(sample(0, -1, precise: false, t: Double($0) * 0.01)) })
        #expect(spun.first == true && spun.last == false)   // the spin speeds up: its multiplier leaves 1
        #expect(spin.scrubber.lastMultiplier > 1)
    }

    @Test func heldButtonsJoinTheChord() {
        let r = router()
        let volume = ScrollSample(deltaX: 0, deltaY: 1, precise: false, momentum: false, began: false, time: 0,
                                  modifiers: [], heldButtons: .gestureButton)
        #expect(r.route(volume) == [.command(.addVolume(2))])
        let strength = ScrollSample(deltaX: 0, deltaY: -1, precise: false, momentum: false, began: false, time: 1,
                                    modifiers: [], heldButtons: .panelButton)
        #expect(r.route(strength) == [.command(.addAutoColorStrength(-0.05))])
        #expect(ScrollSample(deltaX: 0, deltaY: 0, precise: true, momentum: false, began: false, time: 0,
                             modifiers: []).heldButtons == [])
    }

    /// Back/Forward + wheel drag a mark edge through the same ScrubController path as a plain scrub.
    @Test func scrubEdgeIsRoutedLikeScrub() {
        func run(_ held: Modifiers, precise: Bool) -> [GestureAction] {
            let r = router()
            return (0..<40).flatMap { i in
                r.route(ScrollSample(deltaX: 0, deltaY: 1, precise: precise, momentum: false, began: false,
                                     time: Double(i) * 0.016, modifiers: [], heldButtons: held))
            }
        }
        let wheelPlain = frames(run([], precise: false))
        #expect(wheelPlain < 0)
        let start = run(.backButton, precise: false)
        #expect(!start.isEmpty)
        var total = 0
        for case let .scrubEdge(edge, frames: n) in start {
            #expect(edge == .start)
            total += n
        }
        #expect(total == wheelPlain)
        var endTotal = 0
        for case let .scrubEdge(edge, frames: n) in run(.forwardButton, precise: false) {
            #expect(edge == .end)
            endTotal += n
        }
        #expect(endTotal == wheelPlain)
        #expect(frames(start) == 0)    // not reported as plain scrubFrames
        let one = router().route(ScrollSample(deltaX: 0, deltaY: 1, precise: false, momentum: false, began: false,
                                              time: 0, modifiers: [], heldButtons: .backButton))
        #expect(one == [.scrubEdge(.start, frames: -1)])
    }

    @Test func shiftWheelScrubsAndShiftAltIsFast() {
        let r = router()
        #expect(r.route(sample(-1, 0, precise: false, t: 0, mods: .shift)) == [.scrubFrames(1, ticks: true)])
        #expect(r.route(sample(-1, 0, precise: false, t: 5, mods: [.shift, .alt])) == [.scrubFrames(10, ticks: false)])
    }

    @Test func metaScrollZooms() {
        #expect(router().route(sample(0, 40, mods: .meta)) == [.command(.zoom(0.25))])
        #expect(router().route(sample(0, -1, precise: false, mods: .meta)) == [.command(.zoom(-0.25))])
    }

    @Test func pinchIsContinuousZoom() {
        #expect(router().routePinch(magnification: 0.05, modifiers: []) == [.zoomBy(0.05)])
        #expect(router().routePinch(magnification: -0.02, modifiers: []) == [.zoomBy(-0.02)])
    }

    @Test func discretePinchBindingFiresPerStep() {
        let r = router("PINCH_OUT set window-scale 2\nPINCH_IN set window-scale 0.5")
        #expect(r.routePinch(magnification: 0.06, modifiers: []) == [])
        #expect(r.routePinch(magnification: 0.06, modifiers: []) == [.command(.windowScale(2))])
    }

    @Test func customBindingsAndInvert() {
        let r = router("TRACKPAD_UP seek 5\nTRACKPAD_DOWN seek -5\nTRACKPAD_LEFT scrub invert\nTRACKPAD_RIGHT scrub invert")
        #expect(r.route(sample(0, 40)) == [.command(.seek(5, .byConfig))])
        let total = (0..<40).reduce(0) { $0 + frames(r.route(sample(-2, 0, t: 10 + Double($1) * 0.016))) }
        #expect(total == -10)
    }

    @Test func unboundGestureDoesNothing() {
        #expect(router("WHEEL_UP ignore").route(sample(0, 1, precise: false)) == [])
    }

    /// While FrameScrub has the high-resolution wheel on, the vertical wheel sends ~6 events a notch: a scrub
    /// takes every event, other commands fire once a notch, and the horizontal wheel is unchanged.
    @Test func highResolutionWheelEventsPerNotch() {
        let r = router("WHEEL_UP scrub\nWHEEL_DOWN scrub\nWHEEL_LEFT seek -10\nWHEEL_RIGHT seek 10")
        r.wheelEventsPerNotch = GestureRouter.precisionEventsPerNotch
        let scrubbed = (0..<6).reduce(0) { $0 + frames(r.route(sample(0, -0.1 * Double($1 + 1), precise: false, t: Double($1) * 0.02))) }
        #expect(scrubbed == 6)
        #expect(r.route(sample(0.1, 0, precise: false, t: 1)) == [.command(.seek(-10, .byConfig))])   // horizontal: one a notch

        let volume = router()
        volume.wheelEventsPerNotch = GestureRouter.precisionEventsPerNotch
        let up = (0..<12).flatMap { _ in volume.route(sample(0, 1, precise: false, mods: .alt)) }
        #expect(up == [.command(.addVolume(2)), .command(.addVolume(2))])
        // A reversal starts a new notch rather than finishing the old one.
        _ = (0..<3).map { _ in volume.route(sample(0, 1, precise: false, mods: .alt)) }
        let down = (0..<6).flatMap { _ in volume.route(sample(0, -1, precise: false, mods: .alt)) }
        #expect(down == [.command(.addVolume(-2))])
    }
}
