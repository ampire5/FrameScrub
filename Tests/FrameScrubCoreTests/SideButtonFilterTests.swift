import Testing
@testable import FrameScrubCore

/// Ported from Loupe's `SideButtonsTests` (the `AppKitButtonFilter` cases): when AppKit's events of a side button are
/// dropped because the mouse's own events already bring it, and when the mouse's press is AppKit's again.
@Suite struct SideButtonFilterTests {
    @Test func appKitEventOfAHeardButtonIsDropped() {
        let heard: Set<UInt16> = [0x53, 0x56]
        #expect(SideButtonFilter.drops(.back, heard: heard))
        #expect(SideButtonFilter.drops(.forward, heard: heard))
        #expect(!SideButtonFilter.drops(.mid, heard: heard))
        #expect(!SideButtonFilter.drops(.back, heard: []))
        #expect(!SideButtonFilter.drops(.back, heard: [0x56]))
        #expect(SideButtonFilter.drops(.forward, heard: [0x56]))
    }

    @Test func filterPassesPressesWhileNothingIsHeard() {
        var f = SideButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)
        #expect(f.up(.back, heard: []) == true)
        #expect(f.down(.mid, heard: [0x53, 0x56], at: 0) == true)
        #expect(f.up(.mid, heard: [0x53, 0x56]) == true)
    }

    @Test func filterDropsBothEventsOfAHeardButton() {
        var f = SideButtonFilter()
        #expect(f.down(.forward, heard: [0x56], at: 0) == false)
        #expect(f.up(.forward, heard: [0x56]) == false)
        // Heard at the press, not any more at the release: still dropped, the press never reached the recogniser.
        #expect(f.down(.back, heard: [0x53], at: 0) == false)
        #expect(f.up(.back, heard: []) == false)
    }

    @Test func releaseOfAPassedPressPassesEvenOnceTheButtonIsHeard() {
        var f = SideButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)     // before the mouse confirmed the watch
        #expect(f.up(.back, heard: [0x53]) == true)          // the recogniser holds that press: it gets its release
        #expect(f.up(.back, heard: [0x53]) == false)         // a second release is the mouse's again
    }

    @Test func resetForgetsPassedPresses() {
        var f = SideButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)
        f.reset()
        #expect(f.up(.back, heard: [0x53]) == false)
    }

    // MARK: Presses from the mouse's own events

    @Test func mousePressRightAfterAPassedAppKitPressIsADuplicate() {
        var f = SideButtonFilter()
        #expect(SideButtonFilter.duplicateWindow == 0.1)
        #expect(f.down(.back, heard: [], at: 10) == true)    // before the watch was confirmed: AppKit's tap
        #expect(f.up(.back, heard: []) == true)
        #expect(f.mousePress(.back, at: 10.05, watched: true, overOwnWindow: true) == false)
        #expect(f.mouseRelease(.back) == false)              // its release goes with it
        #expect(f.mousePress(.back, at: 10.15, watched: true, overOwnWindow: true) == true)   // a new press
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func mousePressLongAfterTheAppKitPressIsKept() {
        var f = SideButtonFilter()
        #expect(f.down(.forward, heard: [], at: 10) == true)
        #expect(f.up(.forward, heard: []) == true)
        #expect(f.mousePress(.forward, at: 10.15, watched: true, overOwnWindow: true) == true)
        #expect(f.mouseRelease(.forward) == true)
    }

    @Test func mousePressWhileTheAppKitPressIsHeldIsADuplicate() {
        var f = SideButtonFilter()
        #expect(f.down(.back, heard: [], at: 10) == true)
        #expect(f.mousePress(.back, at: 10.5, watched: true, overOwnWindow: true) == false)   // a long hold
        #expect(f.up(.back, heard: [0x53]) == true)          // AppKit's release ends AppKit's press
        #expect(f.mouseRelease(.back) == false)
    }

    @Test func aDroppedAppKitPressIsNoReasonToDropTheMousePress() {
        var f = SideButtonFilter()
        #expect(f.down(.back, heard: [0x53], at: 10) == false)
        #expect(f.mousePress(.back, at: 10.01, watched: true, overOwnWindow: true) == true)
        #expect(f.mouseRelease(.back) == true)               // the mouse's release came first
        #expect(f.up(.back, heard: [0x53]) == false)         // AppKit's then has nothing to release
    }

    @Test func appKitUpReleasesAMousePressWhoseReleaseNeverComes() {
        var f = SideButtonFilter()
        #expect(f.down(.back, heard: [0x53], at: 10) == false)
        #expect(f.mousePress(.back, at: 10.01, watched: true, overOwnWindow: true) == true)
        // The watch died mid-press: no release from the mouse; AppKit's up (no longer heard) is that press's release.
        #expect(f.up(.back, heard: []) == true)
        #expect(f.mouseRelease(.back) == false)              // a late release from the mouse, if it comes, is dropped
        #expect(f.mouseRelease(.back) == true)               // only that one: a stray release passes as before
    }

    @Test func appKitUpFirstThenTheMouseReleaseCountsOnce() {
        var f = SideButtonFilter()
        #expect(f.down(.forward, heard: [0x56], at: 10) == false)
        #expect(f.mousePress(.forward, at: 10.01, watched: true, overOwnWindow: true) == true)
        #expect(f.up(.forward, heard: [0x56]) == true)
        #expect(f.mouseRelease(.forward) == false)
        // The next press is a fresh one: its own release passes.
        #expect(f.down(.forward, heard: [0x56], at: 11) == false)
        #expect(f.mousePress(.forward, at: 11.01, watched: true, overOwnWindow: true) == true)
        #expect(f.mouseRelease(.forward) == true)
        #expect(f.up(.forward, heard: [0x56]) == false)
    }

    @Test func aMouseReleaseThatNeverCameDoesNotSwallowTheNextPressRelease() {
        var f = SideButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: true, overOwnWindow: true) == true)
        #expect(f.up(.back, heard: []) == true)              // released by AppKit; the mouse's release is lost
        #expect(f.mousePress(.back, at: 2, watched: true, overOwnWindow: true) == true)
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func aTakenButtonHasNoAppKitUpAndKeepsItsMouseRelease() {
        var f = SideButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: false, overOwnWindow: false) == true)
        #expect(f.mouseRelease(.back) == true)
        #expect(f.mousePress(.panel, at: 2, watched: false, overOwnWindow: true) == true)
        #expect(f.up(.panel, heard: []) == true)             // not a side button: AppKit's own (no MX_* comes that way)
        #expect(f.mouseRelease(.panel) == true)
    }

    @Test func resetForgetsMouseHeldPresses() {
        var f = SideButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: true, overOwnWindow: true) == true)
        f.reset()
        #expect(f.up(.back, heard: [0x53]) == false)
        #expect(f.mouseRelease(.back) == true)
    }

    // MARK: The start screen

    @Test func backAndForwardRunNoBindingOnTheStartScreen() {
        for mode in SideButtonsMode.allCases {
            #expect(SideButtonFilter.startScreenPress(.back, mode: mode, stashPageShown: false) == .drop, "\(mode)")
            #expect(SideButtonFilter.startScreenPress(.forward, mode: mode, stashPageShown: false) == .drop, "\(mode)")
        }
        // Watched: the Stash page gets AppKit's event itself.
        #expect(SideButtonFilter.startScreenPress(.back, mode: .watch, stashPageShown: true) == .drop)
        #expect(SideButtonFilter.startScreenPress(.forward, mode: .watch, stashPageShown: true) == .drop)
    }

    @Test func takenBackAndForwardNavigateTheStashPage() {
        #expect(SideButtonFilter.startScreenPress(.back, mode: .take, stashPageShown: true) == .pageBack)
        #expect(SideButtonFilter.startScreenPress(.forward, mode: .take, stashPageShown: true) == .pageForward)
    }

    @Test func otherButtonsPassOnTheStartScreen() {
        for b in [MouseButton.mid, .panel, .gesture, .shift] {
            #expect(SideButtonFilter.startScreenPress(b, mode: .take, stashPageShown: true) == .pass, "\(b)")
            #expect(SideButtonFilter.startScreenPress(b, mode: .watch, stashPageShown: false) == .pass, "\(b)")
        }
    }

    @Test func watchedPressCountsOnlyOverOwnWindows() {
        var f = SideButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: true, overOwnWindow: false) == false)
        #expect(f.mouseRelease(.back) == false)
        // Taken (`take`): the system never gets it, wherever the pointer is.
        #expect(f.mousePress(.back, at: 2, watched: false, overOwnWindow: false) == true)
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func divertedMXButtonsAlwaysPass() {
        var f = SideButtonFilter()
        for b in [MouseButton.panel, .gesture, .shift] {
            #expect(f.mousePress(b, at: 1, watched: false, overOwnWindow: false) == true, "\(b)")
            #expect(f.mouseRelease(b) == true, "\(b)")
        }
    }

    @Test func resetForgetsDroppedMousePresses() {
        var f = SideButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: true, overOwnWindow: false) == false)
        f.reset()
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func overAPluginPageBackAndForwardAreThePagesHistory() {
        // taken: only the mouse's events bring them, so they navigate here
        #expect(SideButtonFilter.pluginPagePress(.back, mode: .take) == .pageBack)
        #expect(SideButtonFilter.pluginPagePress(.forward, mode: .take) == .pageForward)
        // watched or the system's: AppKit brings them to the page itself; the player's binding must not run as well
        for mode in [SideButtonsMode.watch, .system] {
            #expect(SideButtonFilter.pluginPagePress(.back, mode: mode) == .drop, "\(mode)")
            #expect(SideButtonFilter.pluginPagePress(.forward, mode: mode) == .drop, "\(mode)")
        }
        #expect(SideButtonFilter.pluginPagePress(.mid, mode: .take) == .pass)
    }
}
