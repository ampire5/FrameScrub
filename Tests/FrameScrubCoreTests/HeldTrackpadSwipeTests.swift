import CoreGraphics
import FrameScrubCore
import Testing

@Suite struct HeldTrackpadSwipeTests {
    @Test func ordinaryTwoFingerScrollAndMousePressPassThrough() {
        var swipe = HeldTrackpadSwipe()
        let pressed = swipe.beginPress()
        #expect(!pressed)
        #expect(swipe.touches(count: 2, center: nil, primaryDown: true) == nil)
        #expect(swipe.scroll(x: -100, y: 0, begins: true) == .pass)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.6, y: 0.5), primaryDown: false) == nil)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.4, y: 0.5), primaryDown: false) == nil)
    }

    @Test func joiningFingersStartAFreshBaselineAndLeftGoesNext() {
        var swipe = HeldTrackpadSwipe()
        _ = swipe.touches(count: 1, center: nil, primaryDown: false)
        let pressed = swipe.beginPress()
        #expect(pressed)
        #expect(swipe.scroll(x: -85, y: 0, begins: true) == .consume)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.75, y: 0.5), primaryDown: true) == nil)
        #expect(swipe.ownsPress)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.65, y: 0.5), primaryDown: true) == .next)
        #expect(swipe.scroll(x: 180, y: 0) == .consume)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.5, y: 0.5), primaryDown: true) == nil)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.56, y: 0.5), primaryDown: true) == nil)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.6, y: 0.5), primaryDown: true) == .previous)
    }

    @Test func preciseScrollFallbackOwnsPressAndReversesFromTheExtreme() {
        var swipe = HeldTrackpadSwipe()
        _ = swipe.touches(count: 3, center: CGPoint(x: 0.5, y: 0.5), primaryDown: false)
        let pressed = swipe.beginPress()
        #expect(pressed)
        #expect(swipe.scroll(x: 43, y: 5, begins: true) == .step(.previous))
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.3, y: 0.5), primaryDown: true) == nil)
        #expect(swipe.scroll(x: 55, y: 0) == .consume)
        #expect(swipe.scroll(x: -30, y: 0) == .consume)
        #expect(swipe.scroll(x: -15, y: 0) == .step(.next))
    }

    @Test func aVerticalSwipeNeverStepsSideways() {
        var swipe = HeldTrackpadSwipe()
        _ = swipe.touches(count: 3, center: CGPoint(x: 0.5, y: 0.5), primaryDown: false)
        _ = swipe.beginPress()
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.51, y: 0.65), primaryDown: true) == nil)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.2, y: 0.65), primaryDown: true) == nil)
        #expect(swipe.scroll(x: -65, y: 0) == .consume)
    }

    @Test func releasingClickConsumesTheTailAndItsMomentumUntilANewGesture() {
        var swipe = HeldTrackpadSwipe()
        _ = swipe.touches(count: 3, center: CGPoint(x: 0.5, y: 0.5), primaryDown: false)
        _ = swipe.beginPress()
        #expect(swipe.scroll(x: -44, y: 0, begins: true) == .step(.next))
        let owned = swipe.endPress()
        #expect(owned)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.8, y: 0.5), primaryDown: false) == nil)
        #expect(swipe.scroll(x: 70, y: 0, primaryDown: false) == .consume)
        _ = swipe.touches(count: 0, center: nil, primaryDown: false)
        #expect(swipe.scroll(x: 70, y: 0, momentum: true, primaryDown: false) == .consume)
        _ = swipe.touches(count: 2, center: nil, primaryDown: false)
        #expect(swipe.scroll(x: 12, y: 0, begins: true, primaryDown: false) == .pass)
    }

    @Test func aChangedFingerCountCannotManufactureAReversal() {
        var swipe = HeldTrackpadSwipe()
        _ = swipe.touches(count: 3, center: CGPoint(x: 0.75, y: 0.5), primaryDown: false)
        _ = swipe.beginPress()
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.6, y: 0.5), primaryDown: true) == .next)
        _ = swipe.touches(count: 4, center: nil, primaryDown: true)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.85, y: 0.5), primaryDown: true) == nil)
        #expect(swipe.touches(count: 3, center: CGPoint(x: 0.96, y: 0.5), primaryDown: true) == .previous)
    }
}
