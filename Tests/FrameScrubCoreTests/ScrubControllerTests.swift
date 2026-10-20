import Testing
@testable import FrameScrubCore

@Suite struct ScrubControllerTests {
    /// Sends `count` events of `dx` points spaced `interval` seconds apart; returns total frames.
    private func gesture(_ scrub: ScrubController, dx: Double, count: Int, interval: Double) -> Int {
        (0..<count).reduce(0) { $0 + scrub.preciseDelta(dx, at: Double($1) * interval, isMomentum: false) }
    }

    @Test func slowSwipeMovesOneFramePerEightPoints() {
        let scrub = ScrubController()
        #expect(gesture(scrub, dx: -2, count: 40, interval: 0.016) == 10)   // 80 pt left = 10 frames forward
    }

    /// `scrub-accel=no`: a fast swipe moves exactly its distance in frames, a fast wheel one frame per notch.
    @Test func withoutAccelerationSpeedDoesNotMultiply() {
        var settings = ScrubSettings()
        settings.accelerate = false
        let swipe = ScrubController(settings: settings)
        #expect(gesture(swipe, dx: -40, count: 20, interval: 0.008) == 100)   // 800 pt at 5000 pt/s = 100 frames
        let wheel = ScrubController(settings: settings)
        let notches = (0..<30).map { wheel.wheelTick(deltaSign: -1, at: Double($0) * 0.01) }
        #expect(notches.allSatisfy { $0 == 1 })
        #expect(wheel.lastMultiplier == 1)
        #expect(wheel.wheelTick(deltaSign: -1, at: 0.31, boost: 10) == 10)   // fast scrub still multiplies
    }

    /// `lastMultiplier`: the acceleration of the last wheel tick (the boost of a fast scrub not counted).
    @Test func lastMultiplierIsTheLastWheelTicksAcceleration() {
        let wheel = ScrubController()
        #expect(wheel.lastMultiplier == 1)
        _ = wheel.wheelTick(deltaSign: -1, at: 0)
        #expect(wheel.lastMultiplier == 1)
        for i in 1..<30 { _ = wheel.wheelTick(deltaSign: -1, at: Double(i) * 0.01) }
        #expect(wheel.lastMultiplier > 1)
        _ = wheel.wheelTick(deltaSign: -1, at: 5, boost: 10)   // after a pause: plain speed, boosted
        #expect(wheel.lastMultiplier == 1)
        let precise = ScrubController()
        for i in 0..<30 { _ = precise.wheelTick(deltaSign: -1, at: Double(i) * 0.002, eventsPerNotch: 6) }
        #expect(precise.lastMultiplier > 1)                   // the high-resolution wheel too
    }

    @Test func invertFlipsDirection() {
        let scrub = ScrubController(settings: ScrubSettings(invert: true))
        #expect(gesture(scrub, dx: -2, count: 40, interval: 0.016) == -10)
    }

    @Test func swipeRightGoesBackward() {
        #expect(gesture(ScrubController(), dx: 2, count: 40, interval: 0.016) == -10)
    }

    @Test func momentumIsIgnored() {
        let scrub = ScrubController()
        #expect(scrub.preciseDelta(-100, at: 0, isMomentum: true) == 0)
    }

    /// Acceleration in frames/s of the plain scrub: none up to `scrub-accel-from` (20), then the step grows with the
    /// speed (twice as fast, twice the steps) until the scrub reaches `scrub-accel-max` (240); never slower.
    @Test func multiplierFollowsScrubSpeed() {
        let scrub = ScrubController()
        #expect(scrub.multiplier(forFramesPerSecond: 10) == 1)
        #expect(scrub.multiplier(forFramesPerSecond: 20) == 1)
        #expect(scrub.multiplier(forFramesPerSecond: 40) == 2)
        #expect(scrub.multiplier(forFramesPerSecond: 60) == 3)
        #expect(scrub.multiplier(forFramesPerSecond: 100) == 2.4)   // 240 fps at most
        #expect(scrub.multiplier(forFramesPerSecond: 400) == 1)     // already faster than the ceiling
    }

    @Test func fastSwipeCoversMoreFramesForSameDistance() {
        let slow = gesture(ScrubController(), dx: -2, count: 150, interval: 0.016)   // 300 pt at 125 pt/s: 15.6 fps
        let fast = gesture(ScrubController(), dx: -6, count: 50, interval: 0.016)    // 300 pt at 375 pt/s: 47 fps
        #expect(slow == 37)
        #expect(fast > slow * 2)
    }

    /// The wheel's speed is notches/s × frames a notch: Precision Scroll at 6 frames a notch accelerates from
    /// 3.3 notches/s, a regular wheel only from 20.
    @Test func wheelAccelerationCountsFrames() {
        let regular = ScrubController()
        let slowNotches = (0..<6).map { regular.wheelTick(deltaSign: -1, at: Double($0) * 0.067) }   // 15 notches/s
        #expect(slowNotches.allSatisfy { $0 == 1 })
        let precise = ScrubController()
        // 24 events (4 notches) in 0.3 s: 13.3 notches/s, 80 fps; ×4 by speed, but at most 240 fps → ×3
        let events = (0..<48).map { precise.wheelTick(deltaSign: -1, at: Double($0) * 0.013, eventsPerNotch: 6) }
        #expect(events.suffix(6).reduce(0, +) == 18)
    }

    @Test func directionChangeResetsAccumulator() {
        let scrub = ScrubController()
        #expect(scrub.preciseDelta(-6, at: 0, isMomentum: false) == 0)
        #expect(scrub.preciseDelta(6, at: 0.016, isMomentum: false) == 0)   // reset, not cancelled to 0
        #expect(scrub.preciseDelta(2, at: 0.032, isMomentum: false) == -1)
    }

    @Test func wheelTicksAccelerate() {
        let scrub = ScrubController()
        #expect(scrub.wheelTick(deltaSign: -1, at: 0) == 1)
        let rapid = (1...10).map { scrub.wheelTick(deltaSign: -1, at: 1 + Double($0) * 0.03) }
        #expect(rapid.last == 2)                   // 10 ticks in 0.3 s → 33 fps → ×1.67
        #expect(scrub.wheelTick(deltaSign: 1, at: 5) == -1)
    }

    @Test func boostAndInvertApplyPerCall() {
        let scrub = ScrubController()
        let boosted = (0..<40).reduce(0) { $0 + scrub.preciseDelta(-2, at: Double($1) * 0.016, isMomentum: false, boost: 10) }
        #expect(boosted == 100)
        let inverted = (0..<40).reduce(0) { $0 + scrub.preciseDelta(-2, at: 10 + Double($1) * 0.016, isMomentum: false, invert: true) }
        #expect(inverted == -10)
        #expect(scrub.wheelTick(deltaSign: -1, at: 100, boost: 10) == 10)
        #expect(scrub.wheelTick(deltaSign: -1, at: 200, invert: true) == -1)
    }

    /// High-resolution wheel (~6 events a notch): a plain scrub moves a frame per event, a fast one keeps its
    /// frames per notch, and acceleration counts notches, not events.
    @Test func highResolutionWheelSteps() {
        var settings = ScrubSettings()
        settings.accelerate = false
        let plain = ScrubController(settings: settings)
        let events = (0..<12).map { plain.wheelTick(deltaSign: -1, at: Double($0) * 0.02, eventsPerNotch: 6) }
        #expect(events == Array(repeating: 1, count: 12))

        let fast = ScrubController(settings: settings)
        let fastEvents = (0..<12).map { fast.wheelTick(deltaSign: -1, at: Double($0) * 0.02, boost: 15, eventsPerNotch: 6) }
        #expect(fastEvents.reduce(0, +) == 30)           // 15 a notch, two notches
        #expect(fastEvents.allSatisfy { $0 == 2 || $0 == 3 })
        #expect(fast.wheelTick(deltaSign: 1, at: 1, boost: 15, eventsPerNotch: 6) == -2)   // the carry does not cross a reversal
        let gentle = ScrubController(settings: settings)
        let gentleEvents = (0..<6).map { gentle.wheelTick(deltaSign: -1, at: Double($0) * 0.02, boost: 3, eventsPerNotch: 6) }
        #expect(gentleEvents == Array(repeating: 1, count: 6))   // a small fast multiplier is never slower than plain

        let accelerating = ScrubController(settings: ScrubSettings())
        // 6 events in 0.3 s is one notch at ~3.3/s, 20 fps: where acceleration starts.
        let slow = (0..<6).map { accelerating.wheelTick(deltaSign: -1, at: Double($0) * 0.05, eventsPerNotch: 6) }
        #expect(slow == Array(repeating: 1, count: 6))
    }

    /// `wheel-precision-frames` slows the plain high-resolution scrub smoothly: a notch (6 events) moves that many
    /// frames, the fraction carried between events; fast scrub keeps its frames per notch.
    @Test func highResolutionWheelFramesPerNotch() {
        func frames(_ perNotch: Double, events: Int, boost: Double = 1) -> [Int] {
            var settings = ScrubSettings()
            settings.accelerate = false
            settings.precisionFramesPerNotch = perNotch
            let scrubber = ScrubController(settings: settings)
            return (0..<events).map { scrubber.wheelTick(deltaSign: -1, at: Double($0) * 0.02, boost: boost, eventsPerNotch: 6) }
        }
        #expect(frames(6, events: 12) == Array(repeating: 1, count: 12))
        #expect(frames(3, events: 6) == [0, 1, 0, 1, 0, 1])
        #expect(frames(1, events: 12) == [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1])
        #expect(frames(0.5, events: 24).reduce(0, +) == 2)     // four notches, two frames
        #expect(frames(2.5, events: 12).reduce(0, +) == 5)
        #expect(frames(1, events: 12, boost: 15).reduce(0, +) == 30)   // fast scrub: 15 a notch whatever the setting
        #expect(frames(6, events: 6, boost: 3) == Array(repeating: 1, count: 6))   // never slower than plain

        var settings = ScrubSettings()
        settings.accelerate = false
        settings.precisionFramesPerNotch = 3
        let reversing = ScrubController(settings: settings)
        #expect(reversing.wheelTick(deltaSign: -1, at: 0, eventsPerNotch: 6) == 0)
        #expect(reversing.wheelTick(deltaSign: 1, at: 0.02, eventsPerNotch: 6) == 0)   // the half frame is dropped
        #expect(reversing.wheelTick(deltaSign: 1, at: 0.04, eventsPerNotch: 6) == -1)

        settings.precisionFramesPerNotch = 1
        let regular = ScrubController(settings: settings)
        #expect(regular.wheelTick(deltaSign: -1, at: 0) == 1)   // a regular wheel keeps a frame a notch
    }

    /// `wheel-precision-mode=fps`: a notch covers `wheel-precision-time` of video, turned into frames by the file's
    /// frame rate; still a scrub, so never more than a frame per event and never under half a frame a notch.
    @Test func highResolutionWheelTimePerNotch() {
        func notchFrames(ms: Double, fps: Double, notches: Int = 10) -> Int {
            var settings = ScrubSettings()
            settings.accelerate = false
            settings.precisionMode = .fps
            settings.precisionFramesPerNotch = 6   // the frames mode's value plays no part
            settings.precisionMsPerNotch = ms
            let scrubber = ScrubController(settings: settings)
            scrubber.videoFPS = fps
            return (0..<notches * 6).map { scrubber.wheelTick(deltaSign: -1, at: Double($0) * 0.02, eventsPerNotch: 6) }
                .reduce(0, +)
        }
        #expect(notchFrames(ms: 100, fps: 30) == 30)
        #expect(notchFrames(ms: 100, fps: 60) == 60)
        #expect(notchFrames(ms: 100, fps: 24) == 24)
        #expect(notchFrames(ms: 100, fps: 120) == 60)   // capped at a frame per event
        #expect(notchFrames(ms: 20, fps: 24) == 5)      // floored at half a frame a notch
        #expect(notchFrames(ms: 50, fps: 29.97, notches: 100) == 149)
    }
}
