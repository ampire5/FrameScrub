import CoreGraphics
import Testing
@testable import FrameScrubCore

@Suite struct SlotLayoutTests {
    private let container = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func layout(_ slots: [SlotEdge: (mode: SlotMode, size: CGFloat)], order: [SlotEdge]? = nil,
                        in container: CGRect? = nil) -> SlotLayout {
        SlotLayout.compute(.init(container: container ?? self.container, slots: slots,
                                 order: order ?? SlotEdge.allCases.filter { slots[$0] != nil }))
    }

    @Test func noSlotsVideoIsContainer() {
        let l = layout([:])
        #expect(l.video == container)
        #expect(l.slots.isEmpty)
        #expect(l.seekBarBottomInset == 0)
    }

    @Test func pinnedRightShrinksVideo() {
        let l = layout([.right: (.pinned, 400)])
        #expect(l.video == CGRect(x: 0, y: 0, width: 1200, height: 900))
        #expect(l.slots[.right] == CGRect(x: 1200, y: 0, width: 400, height: 900))
        #expect(l.effectiveMode[.right] == .pinned)
    }

    @Test func pinnedBottomBetweenPinnedSides() {
        let l = layout([.left: (.pinned, 300), .right: (.pinned, 400), .bottom: (.pinned, 200)])
        #expect(l.slots[.bottom] == CGRect(x: 300, y: 0, width: 900, height: 200))
        #expect(l.video == CGRect(x: 300, y: 200, width: 900, height: 700))
        #expect(l.slots[.left] == CGRect(x: 0, y: 0, width: 300, height: 900))
        #expect(l.seekBarBottomInset == 0)
    }

    @Test func sidesKeepTheTopBandClearVideoAndBottomDoNot() {
        let slots: [SlotEdge: (mode: SlotMode, size: CGFloat)] = [.left: (.overlay, 300), .right: (.pinned, 400),
                                                                  .bottom: (.pinned, 200)]
        let l = SlotLayout.compute(.init(container: container, slots: slots, order: [.left, .right, .bottom],
                                         topInset: 52))
        #expect(l.slots[.left] == CGRect(x: 0, y: 200, width: 300, height: 648))
        #expect(l.slots[.right] == CGRect(x: 1200, y: 0, width: 400, height: 848))
        #expect(l.slots[.bottom] == CGRect(x: 0, y: 0, width: 1200, height: 200))
        #expect(l.video == CGRect(x: 0, y: 200, width: 1200, height: 700))
    }

    @Test func overlayDoesNotMoveVideo() {
        let l = layout([.right: (.overlay, 500)])
        #expect(l.video == container)
        #expect(l.slots[.right] == CGRect(x: 1100, y: 0, width: 500, height: 900))
    }

    @Test func overlayBottomBetweenOverlaySides() {
        let l = layout([.right: (.overlay, 500), .bottom: (.overlay, 250)])
        #expect(l.slots[.bottom] == CGRect(x: 0, y: 0, width: 1100, height: 250))
        #expect(l.seekBarBottomInset == 250)
    }

    @Test func pinnedThenOverlay() {
        let l = layout([.left: (.pinned, 300), .bottom: (.overlay, 200)])
        #expect(l.video == CGRect(x: 300, y: 0, width: 1300, height: 900))
        #expect(l.slots[.bottom] == CGRect(x: 300, y: 0, width: 1300, height: 200))
    }

    @Test func demotesWhenVideoWouldBeTooSmall() {
        let l = layout([.left: (.pinned, 300), .right: (.pinned, 300)], order: [.left, .right],
                       in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(l.demoted == [.right])
        #expect(l.effectiveMode[.right] == .overlay)
        #expect(l.video == CGRect(x: 300, y: 0, width: 700, height: 600))
        #expect(l.slots[.right] == CGRect(x: 700, y: 0, width: 300, height: 600))
    }

    @Test func demotesNewestFirstByShowOrder() {
        let l = layout([.left: (.pinned, 300), .right: (.pinned, 300)], order: [.right, .left],
                       in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(l.demoted == [.left])
    }

    @Test func allThreePinnedInSmallWindow() {
        let l = layout([.left: (.pinned, 300), .right: (.pinned, 300), .bottom: (.pinned, 200)],
                       order: [.left, .right, .bottom], in: CGRect(x: 0, y: 0, width: 800, height: 500))
        #expect(l.video.width >= SlotLayout.minVideo.width && l.video.height >= SlotLayout.minVideo.height)
        #expect(l.demoted == [.bottom, .right])
        #expect(l.effectiveMode[.left] == .pinned)
    }

    @Test func windowTooSmallForVideoDemotesEverything() {
        let l = layout([.left: (.pinned, 300)], in: CGRect(x: 0, y: 0, width: 400, height: 200))
        #expect(l.demoted == [.left])
        #expect(l.video == CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    @Test func overlayNeverWiderThanVideo() {
        let l = layout([.right: (.overlay, 900)], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(l.slots[.right]?.width == 600)
    }

    @Test func containerOffsetIsKept() {
        let l = layout([.bottom: (.pinned, 200)], in: CGRect(x: 10, y: 20, width: 1000, height: 800))
        #expect(l.slots[.bottom] == CGRect(x: 10, y: 20, width: 1000, height: 200))
        #expect(l.video == CGRect(x: 10, y: 220, width: 1000, height: 600))
    }
}
