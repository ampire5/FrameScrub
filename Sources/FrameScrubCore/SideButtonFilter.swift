import Foundation

/// Which presses reach `ButtonGestures` when the same side button can come two ways (`side-buttons`): as AppKit's
/// other-mouse events and as the mouse's own HID++ events (watched or taken). Port of Loupe's `AppKitButtonFilter`.
///
/// - AppKit: a side button the mouse link hears (its control ID in `heard`) comes from the mouse's own events, so its
///   AppKit press is dropped. A release goes where its press went: one whose press passed before the watch was
///   confirmed still passes (or the press would stay held), one whose press was dropped stays dropped.
/// - Mouse: the watch can be confirmed by the very press it reports (or its reply comes after AppKit's events), so
///   AppKit's press may already have passed: a mouse press of a side button whose AppKit press passed less than
///   `duplicateWindow` ago, or is still held, is the same press and is dropped. A watched press also counts only while
///   the pointer is over one of FrameScrub's windows: the system delivers the button to the window under the pointer
///   too. A dropped mouse press drops its release. The `MX_*` buttons (and a taken side button) always pass.
/// - A passed mouse press of a side button is released by whichever comes first, AppKit's up or the mouse's release
///   (the other is then dropped): a watch that dies mid-press never sends its release, and the button would stay held.
public struct SideButtonFilter: Sendable {
    /// How long after AppKit's press of a side button the mouse's report of a press is taken for the same press.
    public static let duplicateWindow = 0.1

    /// The buttons AppKit pressed and whether each press was passed on.
    private var held: [MouseButton: Bool] = [:]
    /// When AppKit's last passed press of each side button came (NSEvent's clock).
    private var passedAt: [MouseButton: Double] = [:]
    /// The mouse presses dropped, whose releases are dropped too.
    private var mouseDropped: Set<MouseButton> = []
    /// The side buttons held by a passed mouse press: AppKit's up releases them too.
    private var mouseHeld: Set<MouseButton> = []
    /// The mouse presses AppKit's up already released: the mouse's own release, if it comes, is dropped.
    private var releasedByAppKit: Set<MouseButton> = []

    public init() {}

    /// Whether an AppKit event of `b` is dropped right now: the mouse link brings that button itself.
    public static func drops(_ b: MouseButton, heard: Set<UInt16>) -> Bool {
        b.sideCID.map(heard.contains) ?? false
    }

    /// An AppKit button down at `t` (NSEvent's clock): true when it goes on.
    public mutating func down(_ b: MouseButton, heard: Set<UInt16>, at t: Double) -> Bool {
        let pass = !Self.drops(b, heard: heard)
        held[b] = pass
        if pass { passedAt[b] = t }
        return pass
    }

    /// An AppKit button up: true when it goes on. While a mouse press holds the button it is that press's release.
    public mutating func up(_ b: MouseButton, heard: Set<UInt16>) -> Bool {
        let appKit = held.removeValue(forKey: b)
        if mouseHeld.remove(b) != nil {
            releasedByAppKit.insert(b)
            return true
        }
        return appKit ?? !Self.drops(b, heard: heard)
    }

    /// A press from the mouse's own events at `t` (the same clock as `down`). `watched`: the link hears the button
    /// without taking it (the system gets it too); `overOwnWindow`: the pointer is over one of FrameScrub's windows.
    /// True when it goes on.
    public mutating func mousePress(_ b: MouseButton, at t: Double, watched: Bool, overOwnWindow: Bool) -> Bool {
        var pass = true
        if b.sideCID != nil {
            let duplicate = held[b] == true || passedAt[b].map { t - $0 < Self.duplicateWindow } ?? false
            pass = !duplicate && (!watched || overOwnWindow)
        }
        releasedByAppKit.remove(b)   // a release that never came: this is a new press
        if pass { mouseDropped.remove(b) } else { mouseDropped.insert(b) }
        if pass && b.sideCID != nil { mouseHeld.insert(b) } else { mouseHeld.remove(b) }
        return pass
    }

    /// A release from the mouse's own events: true when it goes on (its press did, and AppKit's up did not release
    /// it already).
    public mutating func mouseRelease(_ b: MouseButton) -> Bool {
        mouseHeld.remove(b)
        if releasedByAppKit.remove(b) != nil { return false }
        return mouseDropped.remove(b) == nil
    }

    /// Forgets the presses in flight (with `ButtonGestures.cancelAll`).
    public mutating func reset() {
        held = [:]
        passedAt = [:]
        mouseDropped = []
        mouseHeld = []
        releasedByAppKit = []
    }

    /// What a press from the mouse's own events does while the start screen is shown (no file to act on).
    public enum HomePress: Equatable, Sendable {
        /// On to the filter and the recogniser, as over a video.
        case pass
        /// Nothing: the page or Home's browser gets the button through AppKit itself.
        case drop
        /// Back / forward in the Stash page's (or a plugin page's) history: a taken button never reaches it through AppKit.
        case pageBack, pageForward
        /// Back / forward in Home's browser history, for the same reason.
        case browserBack, browserForward
    }

    /// Back and forward run no binding on Home: they go through its history (the browser's, or the Stash page's while
    /// it shows). A watched button reaches them through AppKit, so the mouse's own copy is dropped; a taken one only
    /// from here. Other buttons pass.
    public static func homePress(_ b: MouseButton, mode: SideButtonsMode, stashPageShown: Bool) -> HomePress {
        guard b == .back || b == .forward else { return .pass }
        guard mode == .take else { return .drop }
        if stashPageShown { return b == .back ? .pageBack : .pageForward }
        return b == .back ? .browserBack : .browserForward
    }

    /// A press from the mouse's own events with the pointer over a plugin page: back and forward are the page's
    /// history, never the player's binding. Taken buttons navigate it from here; watched ones (and the system's) reach
    /// it through AppKit, so the mouse's own copy is dropped. Other buttons pass.
    public static func pluginPagePress(_ b: MouseButton, mode: SideButtonsMode) -> HomePress {
        guard b == .back || b == .forward else { return .pass }
        guard mode == .take else { return .drop }
        return b == .back ? .pageBack : .pageForward
    }
}
