import Testing
@testable import FrameScrubCore

private let detents = [0.25, 0.5, 0.75]

private func adjust(_ v: Double, _ d: Double) -> (value: Double, event: HapticEvent) {
    AdjustStep.apply(v, by: d, step: 0.05, range: 0...1, detents: detents)
}

@Test func adjustPlainStep() {
    let r = adjust(0.65, 0.05)
    #expect(abs(r.value - 0.7) < 1e-9)
    #expect(r.event == .step)
}

@Test func adjustLandingOnDetent() {
    let r = adjust(0.7, 0.05)
    #expect(abs(r.value - 0.75) < 1e-9)
    #expect(r.event == .detent)
}

@Test func adjustCrossingDetentBackward() {
    let r = adjust(0.8, -0.1)
    #expect(abs(r.value - 0.7) < 1e-9)
    #expect(r.event == .detent)
}

@Test func adjustLeavingDetentIsStep() {
    #expect(adjust(0.25, 0.05).event == .step)
    #expect(adjust(0.5, -0.05).event == .step)
}

@Test func adjustLimit() {
    let a = adjust(1.0, 0.05)
    #expect(a.value == 1.0)
    #expect(a.event == .limit)
    let b = adjust(0.98, 0.05)
    #expect(b.value == 1.0)
    #expect(b.event == .limit)
    let c = adjust(0.0, -0.05)
    #expect(c.value == 0.0)
    #expect(c.event == .limit)
}

@Test func adjustArrivingAtBoundIsNotLimit() {
    let r = adjust(0.95, 0.05)
    #expect(abs(r.value - 1.0) < 1e-9)
    #expect(r.event == .step)
}

@Test func adjustLimitBeatsDetent() {
    let r = AdjustStep.apply(0.74, by: 0.5, step: 0.05, range: 0...1, detents: detents)
    #expect(r.value == 1.0)
    #expect(r.event == .limit)
}

@Test func adjustDetentEpsilon() {
    let r = AdjustStep.apply(0.1, by: 0.15, step: 0.05, range: 0...1, detents: detents)
    #expect(abs(r.value - 0.25) < 1e-9)
    #expect(r.event == .detent)
}

@Test func scrubKeyframeInRange() {
    var t = ScrubTicks()
    #expect(t.crossed(from: 8, to: 12, keyframes: [0, 10, 20], marks: [], at: 1) == .keyframe)
}

@Test func scrubRangeBounds() {
    let kf = [0, 10, 20]
    var a = ScrubTicks()
    #expect(a.crossed(from: 10, to: 15, keyframes: kf, marks: [], at: 1) == nil)   // from exclusive
    var b = ScrubTicks()
    #expect(b.crossed(from: 5, to: 10, keyframes: kf, marks: [], at: 1) == .keyframe)   // to inclusive
    var c = ScrubTicks()
    #expect(c.crossed(from: 15, to: 10, keyframes: kf, marks: [], at: 1) == .keyframe)   // backward: to inclusive
    var d = ScrubTicks()
    #expect(d.crossed(from: 10, to: 5, keyframes: kf, marks: [], at: 1) == nil)   // backward: from exclusive
    var e = ScrubTicks()
    #expect(e.crossed(from: 7, to: 7, keyframes: kf, marks: [7], at: 1) == nil)
}

@Test func scrubMarkBeatsKeyframe() {
    var t = ScrubTicks()
    #expect(t.crossed(from: 8, to: 22, keyframes: [10, 20], marks: [15], at: 1) == .mark)
}

@Test func scrubBackwardCrossing() {
    var t = ScrubTicks()
    #expect(t.crossed(from: 30, to: 14, keyframes: [10, 20], marks: [], at: 1) == .keyframe)
    var m = ScrubTicks()
    #expect(m.crossed(from: 30, to: 14, keyframes: [], marks: [29, 100], at: 1) == .mark)
}

@Test func scrubNoCrossing() {
    var t = ScrubTicks()
    #expect(t.crossed(from: 11, to: 19, keyframes: [10, 20], marks: [50], at: 1) == nil)
    #expect(t.crossed(from: 0, to: 5, keyframes: [], marks: [], at: 2) == nil)
}

@Test func scrubMinInterval() {
    var t = ScrubTicks()
    #expect(t.crossed(from: 0, to: 11, keyframes: [10, 20], marks: [], at: 1.0) == .keyframe)
    #expect(t.crossed(from: 11, to: 21, keyframes: [10, 20], marks: [], at: 1.03) == nil)
    // Measured from the last returned event, not from the suppressed one.
    #expect(t.crossed(from: 11, to: 21, keyframes: [10, 20], marks: [], at: 1.05) == .keyframe)
}

@Test func scrubSuppressedTickDoesNotRestartInterval() {
    var t = ScrubTicks()
    #expect(t.crossed(from: 0, to: 11, keyframes: [10, 20, 30], marks: [], at: 1.0) != nil)
    #expect(t.crossed(from: 11, to: 21, keyframes: [10, 20, 30], marks: [], at: 1.03) == nil)
    #expect(t.crossed(from: 21, to: 31, keyframes: [10, 20, 30], marks: [], at: 1.06) == .keyframe)
}

@Test func scrubLargeKeyframeList() {
    let kf = Array(stride(from: 0, to: 1_000_000, by: 250))
    var t = ScrubTicks()
    #expect(t.crossed(from: 499_900, to: 500_000, keyframes: kf, marks: [], at: 1) == .keyframe)
    #expect(t.crossed(from: 500_001, to: 500_200, keyframes: kf, marks: [], at: 2) == nil)
}

@Test func endBumpOncePerPush() {
    var b = EndBump()
    #expect(b.stepped(moved: true, direction: 1, fresh: true) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: true) == true)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: true) == true)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    #expect(b.stepped(moved: true, direction: -1, fresh: true) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == true)
}

@Test func endBumpOtherDirection() {
    var b = EndBump()
    #expect(b.stepped(moved: false, direction: -1, fresh: true) == true)
    #expect(b.stepped(moved: false, direction: -1, fresh: false) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == true)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    var r = EndBump()
    #expect(r.stepped(moved: false, direction: 1, fresh: false) == true)
}

@Test func endBumpWheelFreshness() {
    #expect(EndBump.isFreshNotch(at: 10, previous: nil))
    #expect(!EndBump.isFreshNotch(at: 10.1, previous: 10))
    #expect(EndBump.isFreshNotch(at: 10 + EndBump.wheelPause, previous: 10))
}

// MARK: Haptic sources

@Test func onlyTheKeyboardAndTheMouseVibrateTheMouse() {
    #expect(HapticSource.plays(during: .keyboard))
    #expect(HapticSource.plays(during: .mouse))
    #expect(!HapticSource.plays(during: .trackpad))
    #expect(!HapticSource.plays(during: .menu))
    #expect(HapticSource.plays(during: nil))          // outside any input: an asynchronous result plays
}

@Test func aSeekStepPlaysForTheMouseOnly() {
    #expect(HapticSource.plays(during: .mouse, mouseOnly: true))
    #expect(!HapticSource.plays(during: .keyboard, mouseOnly: true))   // a key's seek and its auto-repeat
    #expect(!HapticSource.plays(during: .trackpad, mouseOnly: true))
    #expect(!HapticSource.plays(during: .menu, mouseOnly: true))
    #expect(!HapticSource.plays(during: nil, mouseOnly: true))
}
