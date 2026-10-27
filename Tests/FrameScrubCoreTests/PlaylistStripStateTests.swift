import Testing
@testable import FrameScrubCore

private func state(_ count: Int = 20, playing: Int? = 4, delay: Double = 3) -> PlaylistStripState {
    var s = PlaylistStripState(returnDelay: delay)
    s.rowsChanged(count: count, playing: playing, map: [:])
    return s
}

@Suite struct PlaylistStripStateTests {
    @Test func browseArmsReturn() {
        var s = state()
        #expect(s.browsed == 4 && s.playing == 4)
        s.browse(to: 7, now: 10, inGesture: false)
        #expect(s.browsed == 7 && s.returnDeadline == 13)
        let early = s.fire(now: 12.9), due = s.fire(now: 13)
        #expect(!early && due)
        #expect(s.browsed == 4 && s.returnDeadline == nil)
    }

    @Test func zeroNeverReturns() {
        var s = state(delay: 0)
        s.browse(to: 7, now: 10, inGesture: false)
        let fired = s.fire(now: 100)
        #expect(s.returnDeadline == nil && !fired && s.browsed == 7)
    }

    @Test func gestureHolds() {
        var s = state()
        s.browse(to: 7, now: 10, inGesture: true)
        #expect(s.returnDeadline == nil)
        s.activity(now: 20, inGesture: false)
        #expect(s.returnDeadline == 23)
    }

    /// Browsed on the playing row: nothing to go back to, nothing armed.
    @Test func onPlayingNothingArmed() {
        var s = state()
        s.browse(to: 4, now: 10, inGesture: false)
        #expect(s.returnDeadline == nil)
    }

    @Test func openedDisarms() {
        var s = state()
        s.browse(to: 7, now: 10, inGesture: false)
        s.opened(7)
        #expect(s.playing == 7 && s.browsed == 7 && s.returnDeadline == nil)
    }

    /// The filter hides the playing file: browsed goes to the first row; the return has nothing to go to.
    @Test func returnWhenPlayingHidden() {
        var s = state()
        s.browse(to: 7, now: 10, inGesture: false)
        s.rowsChanged(count: 5, playing: nil, map: [:])
        #expect(s.playing == nil && s.browsed == 0 && s.returnDeadline == nil)
        s.browse(to: 3, now: 20, inGesture: false)
        let fired = s.fire(now: 30)
        #expect(s.returnDeadline == nil && !fired && s.browsed == 3)
    }

    /// The next file starts while the fingers are on the strip: browsed stays under them; the return goes to the new one.
    @Test func playingChangesDuringGesture() {
        var s = state()
        s.browse(to: 9, now: 10, inGesture: true)
        s.rowsChanged(count: 20, playing: 5, map: Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, $0) }))
        #expect(s.playing == 5 && s.browsed == 9)
        s.activity(now: 11, inGesture: false)
        let fired = s.fire(now: 14)
        #expect(fired && s.browsed == 5)
    }

    @Test func stateEmptyRows() {
        var s = state(0, playing: nil)
        #expect(s.browsed == nil && s.playing == nil)
        s.browse(to: 0, now: 1, inGesture: false)
        s.activity(now: 2, inGesture: false)
        s.opened(0)
        let fired = s.fire(now: 10)
        #expect(s.browsed == nil && s.playing == nil && s.returnDeadline == nil && !fired)
    }

    @Test func mapKeepsBrowsed() {
        var s = state()
        s.browse(to: 7, now: 10, inGesture: false)
        s.rowsChanged(count: 10, playing: 2, map: [7: 3, 4: 2])
        #expect(s.browsed == 3 && s.playing == 2)
        s.rowsChanged(count: 10, playing: 2, map: [2: 2])
        #expect(s.browsed == 2)
    }

    /// Opening from elsewhere (keys, autoadvance) with no gesture: the strip follows the playing video.
    @Test func playingMovesBrowsedAtRest() {
        var s = state()
        s.rowsChanged(count: 20, playing: 6, map: Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, $0) }))
        #expect(s.browsed == 6)
    }
}
