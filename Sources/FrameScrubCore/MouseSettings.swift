import LogiHIDPP

/// What the mouse's haptic panel can buzz for: one `haptic-<name>` key each (mouse spec §6, §7.1). Only input from the
/// keyboard and the mouse plays them (not the trackpad, the seek bar or the menus); `done` and `error` of a write
/// play whenever the write ends.
/// Where the input running now came from, for the mouse's haptics (mouse spec §6).
public enum HapticSource: Sendable {
    case keyboard, mouse, trackpad, menu

    /// Whether an event is played while `source` runs (nil: outside any input, e.g. a frame written later). Only the
    /// keyboard and the mouse vibrate the mouse, and outside any input an event plays; `mouseOnly` (a seek's `.step`)
    /// plays for the mouse alone (its side wheel, a button), never for a key or its auto-repeat.
    public static func plays(during source: HapticSource?, mouseOnly: Bool = false) -> Bool {
        if mouseOnly { return source == .mouse }
        return source != .trackpad && source != .menu
    }
}

public enum HapticEvent: String, CaseIterable, Sendable {
    /// A step of the speed, the volume or the auto-colour strength; a ±10 s jump from the mouse (not from a key).
    case step
    /// The speed landing on or passing 1×; the auto-colour strength landing on or passing 25 / 50 / 75 %.
    case detent
    /// A setting stepped against an end of its range; a `scrub-edge` edge arriving at its bound.
    case limit
    /// A button with chords held to the long-press threshold: releasing now is its long press.
    case longArmed = "long-armed"
    /// A `toggle-*` / `cycle-*` command switched something (not `cycle pause`, see `Command.isToggle`).
    case toggle
    /// The first or last frame pushed against (scrub, step, jump), or the first / last file of the playlist.
    case end
    /// A plain wheel scrub, or a `scrub-edge` edge, passing a keyframe.
    case keyframe
    /// A plain wheel scrub passing a mark's start or end, A or B.
    case mark
    /// A frame or a clip written to disk.
    case done
    /// A command refused (`No mark before`, no exact index for `mark-snap`…), or a write failed.
    case error

    /// The `framescrub.conf` key.
    public var configKey: String { "haptic-" + rawValue }
}

/// The pattern each `HapticEvent` plays; a nil choice is `none`.
public struct HapticSettings: Equatable, Sendable {
    public var choices: [HapticEvent: HapticChoice?] = [
        .step: HapticChoice(pattern: .whisperCollision),
        .detent: HapticChoice(pattern: .dampCollision),
        .limit: HapticChoice(pattern: .sharpCollision),
        .longArmed: HapticChoice(pattern: .dampStateChange),
        .toggle: HapticChoice(pattern: .sharpStateChange),
        .end: HapticChoice(pattern: .sharpCollision, strong: true),
        .keyframe: HapticChoice(pattern: .whisperCollision),
        .mark: HapticChoice(pattern: .subtleCollision),
        .done: HapticChoice(pattern: .completed),
        .error: HapticChoice(pattern: .angryAlert),
    ]

    public init() {}

    /// What `e` plays; nil for `none`.
    public func choice(for e: HapticEvent) -> HapticChoice? { choices[e].flatMap { $0 } }
}

/// `mx-panel-force`: how hard the MX Master 4's haptic panel must be pressed. `0…100` goes linearly over the mouse's
/// range (0, the default as in Loupe, the lightest it takes, 100 the stiffest), `default` writes the mouse's factory
/// value, `keep` never writes it.
public enum PanelForceSetting: Equatable, Sendable {
    case keep, factoryDefault, percent(Int)

    /// The force to write, in the mouse's units, given what the mouse reports; nil for `keep`.
    public func value(range: ClosedRange<UInt16>, defaultValue: UInt16) -> UInt16? {
        switch self {
        case .keep: return nil
        case .factoryDefault: return defaultValue
        case .percent(let p):
            let span = Double(range.upperBound - range.lowerBound)
            return range.lowerBound + UInt16((Double(min(max(p, 0), 100)) * span / 100).rounded())
        }
    }

    /// The value as framescrub.conf spells it.
    public var text: String {
        switch self {
        case .keep: return "keep"
        case .factoryDefault: return "default"
        case .percent(let p): return String(p)
        }
    }

    /// `keep`, `default` (any case) or a whole number 0…100; nil otherwise.
    public static func parse(_ text: String) -> PanelForceSetting? {
        switch text.lowercased() {
        case "keep": return .keep
        case "default": return .factoryDefault
        default:
            guard let p = Int(text), (0...100).contains(p) else { return nil }
            return .percent(p)
        }
    }
}

/// `mx-side-buttons`: how FrameScrub gets the MX Master's back and forward buttons. A mouse utility such as Mac Mouse
/// Fix takes them from the system before any app sees them, but the mouse still reports each press over HID++.
/// - `watch` (default): listen to the mouse; the system and the utility still get the buttons.
/// - `take`: divert them, FrameScrub's alone while it is in front.
/// - `system`: AppKit's events only.
public enum SideButtonsMode: String, CaseIterable, Sendable {
    case watch, take, system
}
