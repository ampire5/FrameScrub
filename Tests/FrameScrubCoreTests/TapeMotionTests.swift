import Testing
@testable import FrameScrubCore

@Suite struct TapeMotionTests {
    private let dt = 1.0 / 48000

    /// Frames shown every `every` seconds of host time, each `delta` media seconds after the previous one.
    private struct Scrub {
        var control = TapeControl(target: 1, shownAt: 0, frameVelocity: 0, running: true)
        var velocity = FrameVelocity()
        mutating func show(_ target: Double, at host: Double) {
            control = TapeControl(target: target, shownAt: host, frameVelocity: velocity.shown(target, at: host),
                                  running: true)
        }
    }

    /// Runs the motion sample by sample from `from` to `to` host seconds; `frame(now)` may show new frames.
    private func run(_ motion: inout TapeMotion, from: Double, to: Double, scrub: inout Scrub,
                     frame: (Double, inout Scrub) -> Void = { _, _ in }, each: (Double, Double, Double, Float) -> Void = { _, _, _, _ in }) {
        var now = from
        while now < to {
            frame(now, &scrub)
            let read = motion.step(dt: dt, now: now, control: scrub.control)
            each(now, read, motion.velocity, motion.gain)
            now += dt
        }
    }

    /// Shows a frame every 40 ms, `delta` media seconds apart, starting at media 1.0 at host 0.
    private func steady(_ delta: Double) -> (Double, inout Scrub) -> Void {
        var next = 0.0, target = 1.0
        return { now, scrub in
            if now >= next {
                scrub.show(target, at: now)
                target += delta
                next += 0.04
            }
        }
    }

    @Test func followsASteadyScrub() {
        var motion = TapeMotion(), scrub = Scrub()
        run(&motion, from: 0, to: 0.4, scrub: &scrub, frame: steady(0.08))
        let expected = scrub.control.target + scrub.control.frameVelocity * (0.4 - scrub.control.shownAt)
        #expect(abs(motion.position - expected) < 0.03)
        #expect(abs(motion.velocity - 2) < 0.3)
        #expect(motion.gain == 1)
    }

    @Test func reversesSmoothly() {
        var motion = TapeMotion(), scrub = Scrub()
        var last: Double?, biggest = 0.0
        run(&motion, from: 0, to: 0.3, scrub: &scrub, frame: steady(0.04)) { _, read, _, gain in
            if let last, gain > 0 { biggest = max(biggest, abs(read - last)) }
            last = gain > 0 ? read : nil
        }
        #expect(motion.velocity > 0)
        run(&motion, from: 0.3, to: 0.7, scrub: &scrub, frame: { now, scrub in
            let step = Int((now - 0.3) / 0.04)
            let target = 1.28 - Double(step) * 0.04
            if scrub.control.target != target { scrub.show(target, at: now) }
        }) { _, read, _, gain in
            if let last, gain > 0 { biggest = max(biggest, abs(read - last)) }
            last = gain > 0 ? read : nil
        }
        #expect(motion.velocity < 0)
        #expect(biggest <= 4 * dt * 1.01)
    }

    @Test func stopsWhenFramesStop() {
        var motion = TapeMotion(), scrub = Scrub()
        let frames = steady(0.04)
        run(&motion, from: 0, to: 0.2, scrub: &scrub, frame: { now, scrub in
            if now < 0.1 { frames(now, &scrub) }
        })
        #expect(motion.gain > 0)
        var stopped = Scrub()
        stopped.control = scrub.control
        run(&motion, from: 0.2, to: 0.45, scrub: &stopped)   // the last frame was shown before 0.1 s
        #expect(motion.gain == 0)
        #expect(abs(motion.velocity) < 0.05)
    }

    @Test func farTargetJumps() {
        var motion = TapeMotion(), scrub = Scrub()
        run(&motion, from: 0, to: 0.2, scrub: &scrub, frame: steady(0.04))
        let old = motion.position
        var between = false
        run(&motion, from: 0.2, to: 0.3, scrub: &scrub, frame: { now, scrub in
            if scrub.control.target < 3 { scrub.show(4.2, at: now) }
        }) { _, read, _, _ in
            if read > old + 0.1 && read < 4.2 - 0.1 { between = true }
        }
        #expect(!between)
        #expect(abs(motion.position - 4.2) < 0.05)
    }

    @Test func velocityIsCapped() {
        var motion = TapeMotion(), scrub = Scrub()
        var fastest = 0.0
        run(&motion, from: 0, to: 0.5, scrub: &scrub, frame: steady(0.4)) { _, _, velocity, _ in
            fastest = max(fastest, abs(velocity))
        }
        #expect(fastest <= 4)
    }

    @Test func notRunningFadesFast() {
        var motion = TapeMotion(), scrub = Scrub()
        run(&motion, from: 0, to: 0.2, scrub: &scrub, frame: steady(0.04))
        #expect(motion.gain == 1)
        scrub.control.running = false
        run(&motion, from: 0.2, to: 0.205, scrub: &scrub)
        #expect(motion.gain == 0)
    }

    /// Runs a timeline of frame deliveries `(host, target)` and reports fades during it and the worst lead/lag.
    private func timeline(_ frames: [(Double, Double)], until end: Double)
        -> (fades: Int, worst: Double, motion: TapeMotion) {
        var motion = TapeMotion(), velocity = FrameVelocity()
        var control = TapeControl(target: 0, shownAt: -10, frameVelocity: 0, running: true)
        var index = 0, now = frames[0].0, fades = 0, worst = 0.0, wasLoud = false
        while now < end {
            while index < frames.count && frames[index].0 <= now {
                let (host, target) = frames[index]
                control = TapeControl(target: target, shownAt: host, frameVelocity: velocity.shown(target, at: host),
                                      running: true)
                index += 1
            }
            let read = motion.step(dt: dt, now: now, control: control)
            if index < frames.count {          // only while frames still come
                if wasLoud && motion.gain < 1 { fades += 1 }
                if motion.gain > 0 { worst = max(worst, abs(read - control.target)) }
            }
            wasLoud = motion.gain == 1
            now += dt
        }
        return (fades, worst, motion)
    }

    @Test func burstyFramesStayNearThePicture() {
        // Average 1×: every 100 ms three frames 3 ms apart, as a decoder catching up delivers them.
        var frames: [(Double, Double)] = []
        for burst in 0..<15 {
            for i in 0..<3 { frames.append((Double(burst) * 0.1 + Double(i) * 0.003, 1 + Double(burst * 3 + i) * 0.0333)) }
        }
        let result = timeline(frames, until: 1.5)
        #expect(result.fades == 0)
        #expect(result.worst < 0.2)
    }

    @Test func duplicateDeliveryDoesNotRunAway() {
        var frames: [(Double, Double)] = (0..<40).map { (Double($0) * 0.04, 1 + Double($0) * 0.04) }
        frames.insert((0.4002, 1.44), at: 11)          // a second delivery 0.2 ms after one
        let result = timeline(frames, until: 1.6)
        #expect(result.fades == 0)
        #expect(result.worst < 0.2)
    }

    @Test func anEvenWheelSoundsContinuous() {
        // A notch every 200 ms moving 5 frames at once (25 fps): 1× on average, a staircase in detail.
        let frames: [(Double, Double)] = (0..<10).map { (Double($0) * 0.2, 1 + Double($0) * 0.2) }
        let result = timeline(frames, until: 2)
        #expect(result.fades == 0)
        #expect(result.worst < 0.25)
        #expect(abs(result.motion.velocity - 1) < 0.35)
    }

    @Test func noPitchGlideWhenTheTapeStartsOrStops() {
        // 1× by frame steps for 0.3 s, then nothing: while it sounds the speed stays near 1× — no rise from 0 at the
        // start (after the first frame pair), no drop towards 0 before the fade ends.
        var motion = TapeMotion(), velocity = FrameVelocity()
        var control = TapeControl(target: 0, shownAt: -10, frameVelocity: 0, running: true)
        var now = 0.0, next = 0.0, target = 1.0, low = Double.infinity, high = 0.0
        while now < 0.9 {
            if now < 0.3 && now >= next {
                control = TapeControl(target: target, shownAt: now, frameVelocity: velocity.shown(target, at: now),
                                      running: true)
                target += 0.04
                next += 0.04
            }
            _ = motion.step(dt: dt, now: now, control: control)
            if now > 0.05 && motion.gain > 0.05 {
                low = min(low, motion.velocity)
                high = max(high, motion.velocity)
            }
            now += dt
        }
        #expect(low > 0.7 && high < 1.3)
        #expect(motion.gain == 0)
    }

    @Test func frameVelocityEstimate() {
        var velocity = FrameVelocity()
        var v = 0.0
        for i in 0..<6 { v = velocity.shown(1 + Double(i) * 0.04, at: Double(i) * 0.04) }
        #expect(abs(v - 1) < 1e-9)
        #expect(velocity.shown(2, at: 0.2 + 0.4) == 0)      // a pause longer than the hold
        _ = velocity.shown(2.04, at: 0.64)
        #expect(velocity.shown(2.05, at: 0.6402) <= 4)      // bursts never read as more than 4×
        #expect(velocity.shown(5, at: 0.68) == 0)            // a jump is not speed
    }
}
