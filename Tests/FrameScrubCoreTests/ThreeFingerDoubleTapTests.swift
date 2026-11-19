import CoreGraphics
import Testing
@testable import FrameScrubCore

@Suite struct ThreeFingerDoubleTapTests {
    private let fingers = [1: CGPoint(x: 0.4, y: 0.5), 2: CGPoint(x: 0.5, y: 0.5), 3: CGPoint(x: 0.6, y: 0.5)]

    @Test func staggeredTouchesToggleOnlyOnEverySecondTap() {
        var gesture = ThreeFingerDoubleTap<Int>()
        for tap in 0..<4 {
            let time = Double(tap) * 0.2
            #expect(gesture.update([1: fingers[1]!], at: time, interval: 0.5) == false)
            #expect(gesture.update(fingers, at: time + 0.03, interval: 0.5) == false)
            #expect(gesture.update([3: fingers[3]!], at: time + 0.06, interval: 0.5) == false)
            #expect(gesture.update([:], at: time + 0.08, interval: 0.5) == (tap % 2 == 1))
        }
    }

    @Test func unrelatedContactsBreakTheTapPair() {
        let invalidTouches = [
            [1: fingers[1]!, 2: fingers[2]!],
            fingers.merging([4: CGPoint.zero]) { first, _ in first },
            [1: CGPoint(x: 0.35, y: 0.5), 2: fingers[2]!, 3: CGPoint(x: 0.65, y: 0.5)],
        ]
        for (index, touches) in invalidTouches.enumerated() {
            var gesture = ThreeFingerDoubleTap<Int>()
            #expect(gesture.update(fingers, at: 0, interval: 0.5) == false)
            #expect(gesture.update([:], at: 0.05, interval: 0.5) == false)
            if index == 2 { #expect(gesture.update(fingers, at: 0.1, interval: 0.5) == false) }
            #expect(gesture.update(touches, at: 0.15, interval: 0.5) == false)
            #expect(gesture.update([:], at: 0.2, interval: 0.5) == false)
            #expect(gesture.update(fingers, at: 0.25, interval: 0.5) == false)
            #expect(gesture.update([:], at: 0.3, interval: 0.5) == false)
        }
    }

    @Test func heldSlowAndCancelledContactsCannotCompleteTheGesture() {
        var gesture = ThreeFingerDoubleTap<Int>()
        #expect(gesture.update(fingers, at: 0, interval: 0.5) == false)
        #expect(gesture.update([:], at: 0.4, interval: 0.5) == false)
        #expect(gesture.update(fingers, at: 0.5, interval: 0.5) == false)
        #expect(gesture.update([:], at: 0.55, interval: 0.5) == false)
        #expect(gesture.update(fingers, at: 1.1, interval: 0.5) == false)
        #expect(gesture.update([:], at: 1.15, interval: 0.5) == false)
        #expect(gesture.update(fingers, at: 1.2, interval: 0.5) == false)
        gesture.cancel()
        #expect(gesture.update(fingers, at: 1.23, interval: 0.5) == false)
        #expect(gesture.update([:], at: 1.24, interval: 0.5) == false)
        #expect(gesture.update(fingers, at: 1.3, interval: 0.5) == false)
        #expect(gesture.update([:], at: 1.35, interval: 0.5) == false)
    }
}
