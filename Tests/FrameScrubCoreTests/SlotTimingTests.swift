import CoreGraphics
import Testing
@testable import FrameScrubCore

@Suite struct SlotTimingTests {
    // MARK: Edge reveal

    @Test func touchingTheEdgeRevealsAtOnce() {
        var edge = EdgeReveal()
        #expect(edge.pointer(atEdge: false, buttonHeld: false) == .none)
        #expect(edge.pointer(atEdge: true, buttonHeld: false) == .revealSlot)
    }

    @Test func staysQuietUntilThePointerLeavesAfterAReveal() {
        var edge = EdgeReveal()
        #expect(edge.pointer(atEdge: true, buttonHeld: false) == .revealSlot)
        #expect(edge.pointer(atEdge: true, buttonHeld: false) == .none)
        _ = edge.pointer(atEdge: false, buttonHeld: false)
        #expect(edge.pointer(atEdge: true, buttonHeld: false) == .revealSlot)
    }

    @Test func nothingWhileAButtonIsHeld() {
        var edge = EdgeReveal()
        #expect(edge.pointer(atEdge: true, buttonHeld: true) == .none)
        // Releasing the button at the edge (a scrub that ended there) does not reveal either: leave and come back.
        #expect(edge.pointer(atEdge: true, buttonHeld: false) == .none)
        _ = edge.pointer(atEdge: false, buttonHeld: false)
        #expect(edge.pointer(atEdge: true, buttonHeld: false) == .revealSlot)
    }

    // MARK: Tongue

    @Test func tongueFadesInAsThePointerComes() {
        #expect(EdgeTongue.opacity(distance: 400) == 0)
        #expect(EdgeTongue.opacity(distance: EdgeTongue.reach) == 0)
        let far = EdgeTongue.opacity(distance: 120), near = EdgeTongue.opacity(distance: 30)
        #expect(far > 0 && far < near && near < 1)
        #expect(EdgeTongue.opacity(distance: 0) == 1)
        #expect(EdgeTongue.opacity(distance: -3) == 1)   // just past the edge
    }

    @Test func tongueFollowsThePointerAlongTheEdge() {
        // The tongue's middle sits at the pointer, kept inside the edge (and off its corners).
        #expect(EdgeTongue.center(at: 300, span: 0...800) == 300)
        #expect(EdgeTongue.center(at: 5, span: 0...800) == EdgeTongue.length / 2 + EdgeTongue.cornerGap)
        #expect(EdgeTongue.center(at: 795, span: 0...800) == 800 - EdgeTongue.length / 2 - EdgeTongue.cornerGap)
    }

    @Test func theTongueStaysUnderAClickOnIt() {
        // A press reaches the pointer monitor before the view under it: hiding the tongue then would send the click to the video.
        #expect(EdgeTongue.reaction(buttonHeld: true, overTongue: true) == .keep)
        #expect(EdgeTongue.reaction(buttonHeld: true, overTongue: false) == .hide)   // a drag elsewhere
        #expect(EdgeTongue.reaction(buttonHeld: false, overTongue: true) == .follow)
        #expect(EdgeTongue.reaction(buttonHeld: false, overTongue: false) == .follow)
    }

    // MARK: Pointer near a shown slot

    private let window = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func insideTheSlotCounts() {
        let right = CGRect(x: 600, y: 0, width: 400, height: 600)
        #expect(SlotHover.counts(CGPoint(x: 700, y: 300), slot: right, edge: .right, window: window))
        #expect(!SlotHover.counts(CGPoint(x: 500, y: 300), slot: right, edge: .right, window: window))
    }

    @Test func leavingTheWindowAcrossTheSlotsEdgeKeepsIt() {
        let right = CGRect(x: 600, y: 0, width: 400, height: 600)
        #expect(SlotHover.counts(CGPoint(x: 1150, y: 300), slot: right, edge: .right, window: window))
        #expect(SlotHover.counts(CGPoint(x: 1000 + SlotHover.outsideSide, y: 300), slot: right, edge: .right, window: window))
        #expect(!SlotHover.counts(CGPoint(x: 1000 + SlotHover.outsideSide + 1, y: 300), slot: right, edge: .right,
                                  window: window))
        // Out through another side: not the slot's.
        #expect(!SlotHover.counts(CGPoint(x: 900, y: 650), slot: right, edge: .right, window: window))
        #expect(!SlotHover.counts(CGPoint(x: 1100, y: 700), slot: right, edge: .right, window: window))

        let left = CGRect(x: 0, y: 0, width: 300, height: 600)
        #expect(SlotHover.counts(CGPoint(x: -150, y: 300), slot: left, edge: .left, window: window))
        #expect(!SlotHover.counts(CGPoint(x: -250, y: 300), slot: left, edge: .left, window: window))

        let bottom = CGRect(x: 0, y: 0, width: 1000, height: 200)
        #expect(SlotHover.counts(CGPoint(x: 500, y: -SlotHover.outsideBottom), slot: bottom, edge: .bottom, window: window))
        #expect(!SlotHover.counts(CGPoint(x: 500, y: -SlotHover.outsideBottom - 1), slot: bottom, edge: .bottom,
                                  window: window))
    }

    @Test func outsideBesideAShorterSlotDoesNotCount() {
        let bottom = CGRect(x: 300, y: 0, width: 400, height: 200)   // between two side slots
        #expect(SlotHover.counts(CGPoint(x: 500, y: -50), slot: bottom, edge: .bottom, window: window))
        #expect(!SlotHover.counts(CGPoint(x: 100, y: -50), slot: bottom, edge: .bottom, window: window))
    }

    // MARK: Auto-hide

    @Test func mouseLeavesHidesAfterTheDelay() {
        var clock = AutoHideClock(mode: .mouseLeaves)
        clock.shown(pointerInside: true, now: 1)
        #expect(!clock.shouldHide(now: 10))
        clock.pointerInside(false, now: 2)
        clock.pointerInside(false, now: 2.1)   // still out: the delay counts from the first
        #expect(!clock.shouldHide(now: 2.14))
        #expect(clock.shouldHide(now: 2 + AutoHideClock.mouseLeaveDelay))
        clock.pointerInside(true, now: 2.2)
        #expect(!clock.shouldHide(now: 9))
    }

    @Test func zenDelay() {
        #expect(AutoHideClock.mouseLeaveDelay == 0.15)
    }

    @Test func shownWithThePointerElsewhereWaitsForItToComeIn() {
        // A chord or a menu showed it: it stays until the pointer has been in it once and left.
        var clock = AutoHideClock(mode: .mouseLeaves)
        clock.shown(pointerInside: false, now: 0)
        clock.pointerInside(false, now: 1)
        #expect(!clock.shouldHide(now: 5))
        clock.pointerInside(true, now: 6)
        clock.pointerInside(false, now: 7)
        #expect(clock.shouldHide(now: 7.2))
    }

    @Test func reshownSlotForgetsTheLeaveBeforeIt() {
        var clock = AutoHideClock(mode: .mouseLeaves)
        clock.shown(pointerInside: true, now: 0)
        clock.pointerInside(false, now: 1)
        #expect(clock.shouldHide(now: 2))   // hid itself; shown again later
        clock.shown(pointerInside: false, now: 10)
        #expect(!clock.shouldHide(now: 11))
        clock.shown(pointerInside: true, now: 20)
        clock.pointerInside(false, now: 21)
        #expect(clock.shouldHide(now: 21.2))
    }

    @Test func busyBlocksHide() {
        var clock = AutoHideClock(mode: .mouseLeaves)
        clock.shown(pointerInside: true, now: 0)
        clock.pointerInside(false, now: 0)
        clock.setBusy(true)
        #expect(!clock.shouldHide(now: 5))
        clock.setBusy(false)
        #expect(clock.shouldHide(now: 5))
    }

    @Test func manualNeverHides() {
        var clock = AutoHideClock(mode: .manual)
        clock.shown(pointerInside: true, now: 0)
        clock.pointerInside(false, now: 0)
        #expect(!clock.shouldHide(now: 100))
        #expect(!clock.hidesOnChoice)
    }

    @Test func afterChoiceFlag() {
        var clock = AutoHideClock(mode: .afterChoice)
        clock.shown(pointerInside: true, now: 0)
        clock.pointerInside(false, now: 0)
        #expect(clock.hidesOnChoice)
        #expect(!clock.shouldHide(now: 100))
        #expect(!AutoHideClock(mode: .mouseLeaves).hidesOnChoice)
    }
}

@Suite struct EdgeZoneTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func aSideSlotComesBeforeThePointerTouchesTheEdge() {
        #expect(EdgeReveal.isAt(.right, CGPoint(x: 1200 - 10, y: 400), in: bounds))
        #expect(EdgeReveal.isAt(.left, CGPoint(x: 10, y: 400), in: bounds))
        #expect(!EdgeReveal.isAt(.right, CGPoint(x: 1200 - 20, y: 400), in: bounds))
        #expect(EdgeReveal.isAt(.right, CGPoint(x: 1200.5, y: 400), in: bounds))   // the last pixel, rounded out
    }

    @Test func cornersAndTheSeekBarStayOut() {
        #expect(!EdgeReveal.isAt(.right, CGPoint(x: 1199, y: 10), in: bounds))   // a corner: no edge's
        #expect(EdgeReveal.isAt(.bottom, CGPoint(x: 600, y: 1), in: bounds))
        #expect(!EdgeReveal.isAt(.bottom, CGPoint(x: 600, y: 10), in: bounds))   // above it is the seek bar's
        #expect(!EdgeReveal.isAt(.bottom, CGPoint(x: 100, y: 1), in: bounds))   // the middle third only
    }
}
