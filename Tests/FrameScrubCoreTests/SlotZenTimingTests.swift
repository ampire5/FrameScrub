import Foundation
import Testing
@testable import FrameScrubCore

/// Zen's compact-mode rules (zen-browser/desktop 7133db8, src/zen/compact-mode/) as the slots take them.
@Suite struct SlotZenTimingTests {
    private func entered() -> AutoHideClock {
        var clock = AutoHideClock(mode: .mouseLeaves)
        clock.shown(pointerInside: true, now: -1)
        return clock
    }

    @Test func outsideTheWindowHidesAfterASecond() {
        var clock = entered()
        clock.pointerOutsideWindow(now: 0)
        #expect(!clock.shouldHide(now: 0.99))
        #expect(clock.shouldHide(now: 1.0))
        #expect(AutoHideClock.outsideDelay == 1.0)
    }

    @Test func comingBackCancelsTheOutsideHide() {
        var clock = entered()
        clock.pointerOutsideWindow(now: 0)
        clock.pointerInside(true, now: 0.5)
        #expect(!clock.shouldHide(now: 2))
    }

    @Test func aLeaveInsideTheWindowKeepsItsShortDelay() {
        var clock = entered()
        clock.pointerInside(false, now: 0)
        clock.pointerOutsideWindow(now: 0.05)
        #expect(clock.shouldHide(now: 0.15))
    }

    @Test func afterAMenuThePointerMustComeBack() {
        var clock = entered()
        clock.menuClosed(pointerInside: false, now: 0)
        #expect(!clock.shouldHide(now: 5))
        clock.pointerInside(true, now: 5)
        clock.pointerInside(false, now: 5.1)
        #expect(clock.shouldHide(now: 5.25))
    }

    @Test func resignHidesOverlayOnly() {
        #expect(AutoHideClock.hidesOnResign(mode: .overlay))
        #expect(!AutoHideClock.hidesOnResign(mode: .pinned))
    }

    @Test func capsuleFadesOutAfterTheDelay() {
        var capsule = CapsuleClock()
        #expect(!capsule.isVisible(now: 0))
        capsule.pointerInside(true, now: 0)
        #expect(capsule.isVisible(now: 0))
        capsule.pointerInside(false, now: 1)
        #expect(capsule.isVisible(now: 1.59))
        #expect(!capsule.isVisible(now: 1.6))
        #expect(capsule.nextChange(now: 1) == 1.6)
        #expect(capsule.nextChange(now: 2) == nil)
        #expect(CapsuleClock.outDelay == 0.6 && CapsuleClock.fadeIn == 0.15)
    }

    @Test func capsuleHeldWhileBusy() {
        var capsule = CapsuleClock()
        capsule.pointerInside(true, now: -1)
        capsule.setBusy(true, now: -0.5)
        capsule.pointerInside(false, now: 0)
        #expect(capsule.isVisible(now: 10))
        #expect(capsule.nextChange(now: 10) == nil)
        capsule.setBusy(false, now: 10)
        #expect(capsule.isVisible(now: 10.59))
        #expect(!capsule.isVisible(now: 10.6))
    }

    @Test func capsuleShownByKeyWaitsForThePointer() {
        var capsule = CapsuleClock()
        capsule.shownByKey()
        #expect(capsule.isVisible(now: 100))
        capsule.pointerInside(true, now: 100)
        capsule.pointerInside(false, now: 101)
        #expect(capsule.isVisible(now: 101.59))
        #expect(!capsule.isVisible(now: 101.6))
    }

    /// The spring's closed form (mass 1), sampled every millisecond.
    private func spring(at t: Double) -> Double {
        let w = SlotMotion.stiffness.squareRoot(), z = SlotMotion.damping / (2 * w), wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    @Test func springSettlesInAQuarterSecondWithAboutOnePercent() {
        #expect(SlotMotion.mass == 1)
        var peak = 0.0, peakAt = 0.0, settled = 0.0
        for i in 1...3000 {
            let t = Double(i) / 1000, x = spring(at: t)
            if x > peak { peak = x; peakAt = t }
            if abs(x - 1) > 0.005 { settled = t }
        }
        #expect(abs(settled - SlotMotion.duration) <= 0.03, "settled at \(settled)")
        #expect(peak > 1.005 && peak < 1.015, "peak \(peak)")
        #expect(peakAt >= 0.15 && peakAt <= 0.2, "peak at \(peakAt)")
        #expect(SlotMotion.duration == 0.25 && SlotMotion.fade == 0.15 && SlotMotion.flash == 0.8)
    }

    @Test func flashOnlyForAutoadvanceAndKeys() {
        #expect(SlotFlash.shouldFlash(enabled: true, slotShown: false, cause: .autoadvance))
        #expect(SlotFlash.shouldFlash(enabled: true, slotShown: false, cause: .key))
        #expect(!SlotFlash.shouldFlash(enabled: true, slotShown: true, cause: .key))
        #expect(!SlotFlash.shouldFlash(enabled: false, slotShown: false, cause: .autoadvance))
        #expect(!SlotFlash.shouldFlash(enabled: true, slotShown: false, cause: .playlistClick))
        #expect(!SlotFlash.shouldFlash(enabled: true, slotShown: false, cause: .open))
    }

    /// Final review I3: the flash's end leaves a slot the user has started using.
    @Test func flashEndKeepsASlotInUse() {
        #expect(SlotFlash.endHides(pointerInside: false, menuOpen: false, inUse: false))
        #expect(!SlotFlash.endHides(pointerInside: true, menuOpen: false, inUse: false))
        #expect(!SlotFlash.endHides(pointerInside: false, menuOpen: true, inUse: false))
        #expect(!SlotFlash.endHides(pointerInside: false, menuOpen: false, inUse: true))
    }
}
