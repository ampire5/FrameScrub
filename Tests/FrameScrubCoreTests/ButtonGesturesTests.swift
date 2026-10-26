import Testing
@testable import FrameScrubCore

/// Ported from Loupe's `ButtonGesturesTests` (without its `+MOVE`, thumb-wheel, wheel-step and right-drag cases: the
/// stepping is `GestureRouter`'s, the right button is `VideoView`'s), plus the `_DBL` cases of the old `ButtonPresses`.
@Suite struct ButtonGesturesTests {
    /// The default map with every mouse-button binding switched off, then `text` on top.
    static func map(_ text: String) -> InputMap {
        var map = InputMap()
        let mouse = map.bindings.keys.filter { chord in
            MouseButton.allCases.contains { chord.key.hasPrefix($0.rawValue) } || !chord.modifiers.isDisjoint(with: .heldButtons)
        }
        map.apply(mouse.map { "\($0) ignore" }.joined(separator: "\n"))
        map.apply(text)
        return map
    }

    static func gestures(_ text: String) -> ButtonGestures {
        ButtonGestures(map: map(text), longPress: 0.4, doubleInterval: 0.3)
    }

    /// Loupe's `make()`: the panel has a tap, a long press and chords; the forward button only a tap; the middle one a
    /// tap, a long press and the right chord.
    func make() -> ButtonGestures {
        Self.gestures("""
        MX_PANEL screenshot
        MX_PANEL_LONG screenshot
        MX_PANEL+WHEEL_UP screenshot
        MBTN_FORWARD screenshot
        MBTN_MID screenshot
        MBTN_MID_LONG screenshot
        MBTN_RIGHT+MBTN_MID screenshot
        """)
    }

    /// A button with a long press and no chords: the timer fires it.
    func plainLong() -> ButtonGestures {
        Self.gestures("MBTN_MID screenshot\nMBTN_MID_LONG screenshot")
    }

    let panel = KeyChord(key: "MX_PANEL")
    let panelLong = KeyChord(key: "MX_PANEL_LONG")
    let mid = KeyChord(key: "MBTN_MID")
    let midLong = KeyChord(key: "MBTN_MID_LONG")
    let back = KeyChord(key: "MBTN_BACK")
    let forward = KeyChord(key: "MBTN_FORWARD")
    let forwardLong = KeyChord(key: "MBTN_FORWARD_LONG")
    let forwardDouble = KeyChord(key: "MBTN_FORWARD_DBL")

    @Test func tapFiresOnReleaseBeforeThreshold() {
        var g = make()
        #expect(g.press(.panel, keys: [], rightHeld: false, at: 0) == [])
        #expect(g.release(.panel, at: 0.3) == [panel])
    }

    @Test func longFiresAtThresholdAndReleaseIsQuiet() {
        var g = plainLong()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        #expect(g.nextDeadline == 0.4)
        #expect(g.tick(at: 0.39).fires == [])
        #expect(g.tick(at: 0.4).fires == [midLong])
        #expect(g.tick(at: 0.5).fires == [])
        #expect(g.nextDeadline == nil)
        #expect(g.release(.mid, at: 1.0) == [])
    }

    @Test func lateReleaseWithoutTickStillFiresLongNotTap() {
        var g = plainLong()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        #expect(g.release(.mid, at: 0.9) == [midLong])
    }

    @Test func longPressDeadlineIsConsistentWithRealTimestamps() {
        var g = plainLong()
        for base in [123456.789, 98765.4321, 500000.123456] {
            _ = g.press(.mid, keys: [], rightHeld: false, at: base)
            let d = g.nextDeadline!
            #expect(g.tick(at: d).fires == [midLong])
            #expect(g.release(.mid, at: d + 1) == [])
            _ = g.press(.mid, keys: [], rightHeld: false, at: base)
            #expect(g.release(.mid, at: g.nextDeadline!) == [midLong])
        }
    }

    @Test func longOnAButtonWithChordsWaitsForTheRelease() {
        for chord in ["MX_PANEL+WHEEL_UP", "MX_PANEL+WHEEL_LEFT", "MX_PANEL+TRACKPAD_DOWN"] {
            var g = Self.gestures("MX_PANEL screenshot\nMX_PANEL_LONG screenshot\n\(chord) screenshot")
            _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
            #expect(g.nextDeadline == 0.4, "\(chord)")          // only to report it armed, not to fire the long press
            #expect(g.tick(at: 5).fires == [], "\(chord)")
            #expect(g.release(.panel, at: 0.4) == [panelLong], "\(chord)")
            _ = g.press(.panel, keys: [], rightHeld: false, at: 10)
            #expect(g.release(.panel, at: 10.39) == [panel], "\(chord)")
        }
    }

    @Test func chordButtonTapFiresOnRelease() {
        var g = Self.gestures("MBTN_BACK screenshot\nMBTN_BACK+WHEEL_UP screenshot")
        #expect(g.press(.back, keys: [], rightHeld: false, at: 0) == [])
        #expect(g.nextDeadline == nil)
        #expect(g.release(.back, at: 2) == [back])
    }

    // MARK: Long armed (release now and the long press counts)

    @Test func longOnReleaseButtonIsArmedOnceAtTheDeadline() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.nextDeadline == 0.4)
        let early = g.tick(at: 0.39)
        #expect(early.fires == [] && early.armed == [])
        let due = g.tick(at: 0.4)
        #expect(due.fires == [] && due.armed == [.panel])
        #expect(g.nextDeadline == nil)
        let again = g.tick(at: 0.5)
        #expect(again.fires == [] && again.armed == [])
        #expect(g.release(.panel, at: 0.6) == [panelLong])
    }

    @Test func armedOnceAtDeadlineForChordButton() {
        var g = ButtonGestures(map: InputMap(), longPress: 0.4, doubleInterval: 0.3)    // MX_PANEL, _LONG, +WHEEL_*
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.tick(at: 0.4).armed == [.panel])
        #expect(g.tick(at: 0.4).armed == [])
        #expect(g.release(.panel, at: 0.5) == [panelLong])
    }

    @Test func wheelStepBeforeTheDeadlineMeansNeverArmed() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        _ = g.wheel(hasDelta: true, momentum: false, at: 0.2)
        #expect(g.nextDeadline == nil)
        let due = g.tick(at: 0.5)
        #expect(due.fires == [] && due.armed == [])
    }

    @Test func driftBeforeTheDeadlineMeansNeverArmed() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        g.move(dx: 0, dy: 8)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.5).armed == [])
    }

    @Test func wheelStepAfterArmedCancelsTheLongPress() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.tick(at: 0.4).armed == [.panel])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.5) == .panelButton)
        #expect(g.tick(at: 0.6).armed == [])
        #expect(g.release(.panel, at: 1.0) == [])
    }

    @Test func plainLongButtonIsNeverArmed() {
        var g = plainLong()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        let due = g.tick(at: 0.4)
        #expect(due.fires == [midLong] && due.armed == [])
    }

    @Test func buttonWithoutALongPressIsNeverArmed() {
        var g = Self.gestures("MX_PANEL screenshot\nMX_PANEL+WHEEL_UP screenshot")
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.nextDeadline == nil && g.tick(at: 5).armed == [])
    }

    @Test func chordPressIsNeverArmed() {
        var g = Self.gestures("""
        MX_PANEL screenshot
        MX_PANEL_LONG screenshot
        MX_PANEL+WHEEL_UP screenshot
        MBTN_RIGHT+MX_PANEL screenshot
        """)
        #expect(g.press(.panel, keys: [], rightHeld: true, at: 0.1) == [KeyChord(key: "MX_PANEL", modifiers: .rightButton)])
        #expect(g.nextDeadline == nil && g.tick(at: 5).armed == [])
    }

    @Test func holdThenScrollNeverTogglesOnRelease() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.tick(at: 0.5).fires == [])                       // a timer would have fired the long press here
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.6) == .panelButton)
        #expect(g.release(.panel, at: 1.0) == [])
    }

    @Test func holdThenDriftNeverTogglesOnRelease() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        g.move(dx: 0, dy: 8)
        #expect(g.release(.panel, at: 1.0) == [])
    }

    @Test func smallJitterDuringALongHoldStillFiresLongOnRelease() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        g.move(dx: 1, dy: 2)
        #expect(g.release(.panel, at: 0.7) == [panelLong])
    }

    @Test func tapOnlyButtonFiresOnPress() {
        var g = Self.gestures("MX_GESTURE screenshot")
        #expect(g.press(.gesture, keys: [], rightHeld: false, at: 0) == [KeyChord(key: "MX_GESTURE")])
        #expect(g.release(.gesture, at: 5) == [])
        #expect(g.nextDeadline == nil)
    }

    /// Back and forward are clicks: other apps drag with them (Mac Mouse Fix switches the Space with Back held), so
    /// even a tap-only one waits for the release, and a drag before it is no click.
    @Test func tapOnlySideButtonFiresOnRelease() {
        var g = make()
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 0) == [])
        #expect(g.nextDeadline == nil)
        #expect(g.release(.forward, at: 5) == [forward])
        var b = Self.gestures("MBTN_BACK screenshot")
        #expect(b.press(.back, keys: [], rightHeld: false, at: 0) == [])
        #expect(b.release(.back, at: 0.1) == [back])
    }

    @Test func dragWithATapOnlySideButtonIsNoClick() {
        var g = Self.gestures("MBTN_BACK screenshot")
        _ = g.press(.back, keys: [], rightHeld: false, at: 0)
        g.move(dx: -478, dy: -102)   // a Space swipe: the pointer frozen, the deltas still come
        #expect(g.release(.back, at: 0.8) == [])
        _ = g.press(.back, keys: [], rightHeld: false, at: 1)
        g.move(dx: 3, dy: -2)        // a tremble
        #expect(g.release(.back, at: 1.1) == [back])
    }

    @Test func tapWithoutLongIgnoresDuration() {
        var g = Self.gestures("MX_PANEL screenshot\nMX_PANEL+WHEEL_UP screenshot")
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.nextDeadline == nil)
        #expect(g.release(.panel, at: 3) == [panel])
    }

    @Test func firedChordsCarryTheKeysOfThePress() {
        var g = make()
        _ = g.press(.forward, keys: .alt, rightHeld: false, at: 0)
        #expect(g.release(.forward, at: 0.1) == [KeyChord(key: "MBTN_FORWARD", modifiers: .alt)])
        _ = g.press(.panel, keys: [.meta, .shift], rightHeld: false, at: 1)
        #expect(g.release(.panel, at: 1.1) == [KeyChord(key: "MX_PANEL", modifiers: [.meta, .shift])])
        _ = g.press(.panel, keys: .ctrl, rightHeld: false, at: 2)
        #expect(g.release(.panel, at: 3) == [KeyChord(key: "MX_PANEL_LONG", modifiers: .ctrl)])
        _ = g.press(.mid, keys: .ctrl, rightHeld: false, at: 4)
        #expect(g.tick(at: 4.4).fires == [KeyChord(key: "MBTN_MID_LONG", modifiers: .ctrl)])
        _ = g.release(.mid, at: 5)
        #expect(g.press(.mid, keys: .alt, rightHeld: true, at: 6) == [KeyChord(key: "MBTN_MID", modifiers: [.alt, .rightButton])])
    }

    // MARK: Wheel

    @Test func wheelWhileHeldReturnsItsModifierAndCancelsTap() {
        var g = ButtonGestures(map: InputMap(), longPress: 0.4, doubleInterval: 0.3)    // MBTN_BACK, _LONG, +WHEEL_*
        _ = g.press(.back, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == .backButton)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.2) == .backButton)
        #expect(g.release(.back, at: 0.3) == [])
        #expect(g.tick(at: 0.5).fires == [])
        #expect(g.nextDeadline == nil)
    }

    /// The default middle button: a tap is full screen on the release, a scroll while it is held is volume and no tap.
    @Test func defaultMiddleTapsOnReleaseAndScrollsVolumeWhileHeld() {
        var g = ButtonGestures(map: InputMap(), longPress: 0.4, doubleInterval: 0.3)    // MBTN_MID, +WHEEL_UP/DOWN
        #expect(g.press(.mid, keys: [], rightHeld: false, at: 0) == [])
        #expect(g.release(.mid, at: 0.1) == [mid])
        _ = g.press(.mid, keys: [], rightHeld: false, at: 1)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 1.1) == .midButton)
        #expect(g.release(.mid, at: 1.2) == [])
        #expect(g.tick(at: 2).fires == [])
    }

    @Test func scrollTailAfterReleaseKeepsModifierUntilGap() {
        var g = ButtonGestures(map: InputMap(), longPress: 0.4, doubleInterval: 0.3)
        _ = g.press(.back, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == .backButton)
        #expect(g.release(.back, at: 0.15) == [])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.2) == .backButton)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.5) == [])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.6) == [])
    }

    @Test func wheelWithoutHoldOrChordsReturnsNothing() {
        var g = make()
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0) == [])
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == [])
    }

    @Test func wheelCancelsButtonWithoutChords() {
        var g = make()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == [])
        #expect(g.release(.mid, at: 0.2) == [])
    }

    @Test func wheelGoesToTheMostRecentButtonWithChords() {
        var g = Self.gestures("MX_PANEL+WHEEL_UP screenshot\nMX_GESTURE+WHEEL_UP screenshot")
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        _ = g.press(.gesture, keys: [], rightHeld: false, at: 0.1)
        #expect(g.held == [.panel, .gesture])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.2) == .gestureButton)
        _ = g.release(.gesture, at: 0.3)
        #expect(g.held == [.panel])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.4) == .panelButton)
    }

    @Test func releaseMidScrollAbsorbsTheTailOfTheGesture() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == .panelButton)
        _ = g.release(.panel, at: 0.2)
        // Same scroll: non-momentum events, then momentum, each within 0.25 s of the previous one.
        for (t, momentum) in [(0.3, false), (0.4, false), (0.5, true), (0.6, true), (0.7, true)] {
            #expect(g.wheel(hasDelta: true, momentum: momentum, at: t) == .panelButton, "\(t)")
        }
        #expect(g.wheel(hasDelta: true, momentum: false, at: 1.0) == [])
        #expect(g.wheel(hasDelta: true, momentum: true, at: 1.05) == [])
    }

    @Test func momentumWhileHeldKeepsThePressAlive() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: true, at: 0.1) == .panelButton)
        #expect(g.release(.panel, at: 0.2) == [panel])
    }

    @Test func momentumIsNotAbsorbedWithoutAHeldButton() {
        var g = make()
        #expect(g.wheel(hasDelta: true, momentum: true, at: 0) == [])
    }

    @Test func momentumDuringAPressLeavesItsTapAndLongAlive() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: true, at: 0.05) == .panelButton)
        #expect(g.release(.panel, at: 0.2) == [panel])
        _ = g.press(.panel, keys: [], rightHeld: false, at: 1)
        _ = g.wheel(hasDelta: true, momentum: true, at: 1.05)
        #expect(g.release(.panel, at: 1.5) == [panelLong])
    }

    @Test func wheelCancelsAHeldButtonWithoutChords() {
        // Tap.
        var g = Self.gestures("MBTN_BACK screenshot\nMBTN_BACK_LONG screenshot\nMBTN_FORWARD screenshot\n"
                              + "MBTN_FORWARD_LONG screenshot\nMBTN_FORWARD+MBTN_MID screenshot")
        _ = g.press(.back, keys: [], rightHeld: false, at: 0)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == [])
        #expect(g.release(.back, at: 0.2) == [])
        // Long at the deadline.
        _ = g.press(.back, keys: [], rightHeld: false, at: 1)
        _ = g.wheel(hasDelta: true, momentum: false, at: 1.1)
        #expect(g.nextDeadline == nil && g.tick(at: 1.5).fires == [])
        #expect(g.release(.back, at: 2) == [])
        // Long on release and its armed report.
        _ = g.press(.forward, keys: [], rightHeld: false, at: 3)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 3.1) == .forwardButton)
        #expect(g.nextDeadline == nil && g.tick(at: 3.5).armed == [])
        #expect(g.release(.forward, at: 4) == [])
    }

    @Test func wheelMomentumOrNoDeltaLeavesAButtonWithoutChords() {
        var g = Self.gestures("MBTN_BACK screenshot\nMBTN_BACK_LONG screenshot")
        _ = g.press(.back, keys: [], rightHeld: false, at: 0)
        _ = g.wheel(hasDelta: true, momentum: true, at: 0.1)       // the tail of a scroll begun before the press
        _ = g.wheel(hasDelta: false, momentum: false, at: 0.15)    // a phase event with no delta
        #expect(g.release(.back, at: 0.2) == [back])
    }

    @Test func aPhaseEventWithoutDeltaCancelsOnlyTheChordButton() {
        var g = Self.gestures("MBTN_BACK screenshot\nMBTN_FORWARD screenshot\nMBTN_FORWARD+WHEEL_UP screenshot\n"
                              + "MBTN_BACK_LONG screenshot")
        _ = g.press(.back, keys: [], rightHeld: false, at: 0)
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0.05)
        #expect(g.wheel(hasDelta: false, momentum: false, at: 0.1) == .forwardButton)   // the scroll begins
        #expect(g.release(.forward, at: 0.2) == [])
        #expect(g.release(.back, at: 0.2) == [back])
    }

    @Test func wheelGoesToTheChordButtonAndCancelsTheOtherHeldOne() {
        var g = Self.gestures("MBTN_BACK screenshot\nMBTN_FORWARD screenshot\nMBTN_FORWARD+WHEEL_UP screenshot")
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0)
        _ = g.press(.back, keys: [], rightHeld: false, at: 0.05)
        #expect(g.release(.back, at: 0.06) == [back])     // a side button: on the release, even tap-only
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0.07)                      // unbound: not held at all
        #expect(g.held == [.forward])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.1) == .forwardButton)
    }

    // MARK: The right chord

    @Test func rightHeldPressFiresRightChordAtOnce() {
        var g = make()
        #expect(g.press(.mid, keys: [], rightHeld: true, at: 0.1) == [KeyChord(key: "MBTN_MID", modifiers: .rightButton)])
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 1).fires == [])
        #expect(g.release(.mid, at: 1.2) == [])
    }

    @Test func rightChordComesBeforeTheDouble() {
        var g = Self.gestures("""
        MBTN_FORWARD screenshot
        MBTN_FORWARD_DBL ab-loop
        MBTN_RIGHT+MBTN_FORWARD export-range
        """)
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 0) == [])
        #expect(g.release(.forward, at: 0.05) == [])                     // waits for a second press
        #expect(g.press(.forward, keys: [], rightHeld: true, at: 0.1)
                == [forward, KeyChord(key: "MBTN_FORWARD", modifiers: .rightButton)])
        #expect(g.release(.forward, at: 0.2) == [])
        #expect(g.nextDeadline == nil && g.tick(at: 1).fires == [])
    }

    @Test func chordPressIsDeadForTheWheel() {
        var g = Self.gestures("MBTN_BACK screenshot\nMBTN_RIGHT+MBTN_BACK screenshot\nMBTN_BACK+WHEEL_UP screenshot")
        _ = g.press(.back, keys: [], rightHeld: true, at: 0.1)
        #expect(g.wheel(hasDelta: true, momentum: false, at: 0.2) == [])
    }

    @Test func rightHeldWithoutARightChordIsAnOrdinaryPress() {
        var g = make()
        #expect(g.press(.panel, keys: [], rightHeld: true, at: 0) == [])
        #expect(g.release(.panel, at: 0.1) == [panel])
    }

    @Test func midWithoutRightIsNotAChord() {
        var g = make()
        #expect(g.press(.mid, keys: [], rightHeld: false, at: 0) == [])
        #expect(g.nextDeadline == 0.4)
    }

    @Test func cancelAllDropsEverything() {
        var g = make()
        _ = g.press(.panel, keys: [], rightHeld: false, at: 0)
        _ = g.wheel(hasDelta: true, momentum: false, at: 0.1)
        _ = g.press(.mid, keys: [], rightHeld: true, at: 0.2)
        g.cancelAll()
        #expect(g.held.isEmpty)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 1).fires == [])
        #expect(g.release(.panel, at: 1.1) == [])
        #expect(g.release(.mid, at: 1.1) == [])
        #expect(g.wheel(hasDelta: true, momentum: true, at: 1.2) == [])
        #expect(g.wheel(hasDelta: true, momentum: false, at: 1.2) == [])
    }

    @Test func cancelAllDropsHeldWithoutFiring() {
        var g = Self.gestures("MBTN_FORWARD screenshot\nMBTN_FORWARD_DBL screenshot\nMBTN_MID screenshot\nMBTN_MID_LONG screenshot")
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0)
        _ = g.release(.forward, at: 0.05)                         // waits for a second press
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0.1)    // the waiting single fires here
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0.2)
        #expect(g.held == [.mid, .forward])
        g.cancelAll()
        #expect(g.held.isEmpty && g.nextDeadline == nil)
        let t = g.tick(at: 2)
        #expect(t.fires == [] && t.armed == [])
        #expect(g.release(.mid, at: 2.1) == [] && g.release(.forward, at: 2.1) == [])
    }

    // MARK: A press that moved is not a press

    /// The middle button fires its long press at the deadline, the forward one on release (it has chords).
    func drifting() -> ButtonGestures {
        Self.gestures("""
        MBTN_MID screenshot
        MBTN_MID_LONG screenshot
        MBTN_FORWARD screenshot
        MBTN_FORWARD_LONG screenshot
        MBTN_FORWARD+WHEEL_UP screenshot
        """)
    }

    @Test func drift8ptCancels() {
        #expect(ButtonGestures.driftPoints == 8)
        for (dx, dy) in [(8.0, 0.0), (0.0, -8.0), (5.0, 5.0)] {
            var g = drifting()
            _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
            g.move(dx: dx, dy: dy / 2)
            g.move(dx: 0, dy: dy / 2)
            let cancelled = max(abs(dx), abs(dy)) >= 8
            #expect(g.release(.mid, at: 0.1) == (cancelled ? [] : [mid]), "\(dx) \(dy)")
        }
    }

    @Test func driftBelowEightPointsKeepsThePress() {
        var g = drifting()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        g.move(dx: 7.9, dy: -7.9)
        #expect(g.release(.mid, at: 0.1) == [mid])
        _ = g.press(.mid, keys: [], rightHeld: false, at: 1)
        g.move(dx: -7.9, dy: 7.9)
        #expect(g.nextDeadline == 1.4)
        #expect(g.tick(at: 1.4).fires == [midLong])
        _ = g.release(.mid, at: 2)
        _ = g.press(.forward, keys: [], rightHeld: false, at: 3)
        g.move(dx: 0, dy: 7.9)
        #expect(g.tick(at: 3.4).armed == [.forward])
        #expect(g.release(.forward, at: 3.5) == [forwardLong])
    }

    @Test func driftCancelsTheLongAtTheDeadline() {
        var g = drifting()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        g.move(dx: 0, dy: 8)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.5).fires == [])
        #expect(g.release(.mid, at: 1) == [])
    }

    @Test func driftCancelsTheLongOnReleaseAndItsArmedReport() {
        var g = drifting()
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0)
        g.move(dx: -8, dy: 0)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.5).armed == [])
        #expect(g.release(.forward, at: 1) == [])
        // After the report: the drift still cancels the long press the release would give.
        _ = g.press(.forward, keys: [], rightHeld: false, at: 2)
        #expect(g.tick(at: 2.4).armed == [.forward])
        g.move(dx: 0, dy: -8)
        #expect(g.release(.forward, at: 3) == [])
    }

    @Test func driftCountsFromTheButtonsOwnPress() {
        var g = drifting()
        _ = g.press(.mid, keys: [], rightHeld: false, at: 0)
        g.move(dx: 0, dy: 7)
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0.1)
        g.move(dx: 0, dy: 7)                                      // middle 14 pt, forward 7 pt
        #expect(g.release(.mid, at: 0.2) == [])
        #expect(g.release(.forward, at: 0.2) == [forward])
    }

    // MARK: Double press (`_DBL`, was `ButtonPresses`)

    func double() -> ButtonGestures {
        Self.gestures("MBTN_FORWARD screenshot\nMBTN_FORWARD_DBL screenshot\nMBTN_MID screenshot")
    }

    @Test func aButtonWithoutADoubleBindingFiresAtOnce() {
        var g = double()
        #expect(g.press(.mid, keys: [], rightHeld: false, at: 1) == [mid])
        _ = g.release(.mid, at: 1.05)
        #expect(g.press(.mid, keys: [], rightHeld: false, at: 1.1) == [mid])
        #expect(g.nextDeadline == nil)
    }

    @Test func aSinglePressWaitsForTheIntervalWhenADoubleIsBound() {
        var g = double()
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 1) == [])
        #expect(g.release(.forward, at: 1.05) == [])
        #expect(g.nextDeadline == 1.35)
        #expect(g.tick(at: 1.3).fires == [])
        #expect(g.tick(at: 1.35).fires == [forward])
        #expect(g.tick(at: 1.4).fires == [])
        #expect(g.nextDeadline == nil)
    }

    @Test func doubleWaitExpiresIntoSingle() {
        var g = double()
        _ = g.press(.forward, keys: .alt, rightHeld: false, at: 5)
        _ = g.release(.forward, at: 5.1)
        #expect(g.tick(at: 5.1 + 0.3).fires == [KeyChord(key: "MBTN_FORWARD", modifiers: .alt)])
    }

    @Test func aSecondPressInTimeIsTheDoubleAndTheSingleNeverFires() {
        var g = double()
        _ = g.press(.forward, keys: [], rightHeld: false, at: 1)
        _ = g.release(.forward, at: 1.05)
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 1.2) == [forwardDouble])
        #expect(g.nextDeadline == nil)
        #expect(g.release(.forward, at: 1.25) == [])
        #expect(g.tick(at: 2).fires == [])
    }

    @Test func theDoubleKeepsTheModifiers() {
        var g = double()
        _ = g.press(.forward, keys: .alt, rightHeld: false, at: 1)
        _ = g.release(.forward, at: 1.05)
        #expect(g.press(.forward, keys: .alt, rightHeld: false, at: 1.1) == [KeyChord(key: "MBTN_FORWARD_DBL", modifiers: .alt)])
    }

    @Test func otherModifiersOnTheSecondPressAreANewSingle() {
        var g = double()
        _ = g.press(.forward, keys: [], rightHeld: false, at: 1)
        _ = g.release(.forward, at: 1.05)
        #expect(g.press(.forward, keys: .alt, rightHeld: false, at: 1.1) == [forward])
        #expect(g.release(.forward, at: 1.15) == [])
        #expect(g.tick(at: 1.45).fires == [KeyChord(key: "MBTN_FORWARD", modifiers: .alt)])
    }

    @Test func anotherButtonFiresThePendingSingleFirst() {
        var g = double()
        _ = g.press(.forward, keys: [], rightHeld: false, at: 1)
        _ = g.release(.forward, at: 1.05)
        #expect(g.press(.mid, keys: [], rightHeld: false, at: 1.1) == [forward, mid])
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 2).fires == [])
    }

    @Test func aLatePressIsANewSingle() {
        var g = double()
        _ = g.press(.forward, keys: [], rightHeld: false, at: 1)
        _ = g.release(.forward, at: 1.05)
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 1.5) == [forward])   // the wait ran out, no tick yet
        #expect(g.release(.forward, at: 1.55) == [])
        #expect(g.nextDeadline == 1.85)
    }

    @Test func doubleWithLongFiresDoubleOnSecondPress() {
        var g = Self.gestures("MBTN_FORWARD screenshot\nMBTN_FORWARD_LONG screenshot\nMBTN_FORWARD_DBL screenshot")
        _ = g.press(.forward, keys: [], rightHeld: false, at: 0)
        #expect(g.release(.forward, at: 0.1) == [])
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 0.2) == [forwardDouble])
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.7).fires == [])
        #expect(g.release(.forward, at: 0.8) == [])
        // A long first press is the long press: no wait for a second one.
        _ = g.press(.forward, keys: [], rightHeld: false, at: 1)
        #expect(g.tick(at: 1.4).fires == [forwardLong])
        #expect(g.release(.forward, at: 1.5) == [])
        #expect(g.nextDeadline == nil)
        #expect(g.press(.forward, keys: [], rightHeld: false, at: 1.6) == [])
    }
}
