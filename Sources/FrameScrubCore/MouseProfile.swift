import Foundation

/// What the mouse's buttons do (`mouse-profile`): Editing is the layout's bindings (marks under back and forward);
/// Viewing, the default, leaves the marks alone. Each profile's lines go on top of input.conf, and the user's
/// `input-<profile>.conf` on top of them. Holding the SmartShift button (`SmartShiftPress`), the `cycle-mouse-profile` command or
/// View › Mouse Buttons for Editing switches it.
public enum MouseProfile: String, CaseIterable, Sendable {
    case viewing, editing

    public var title: String {
        switch self {
        case .viewing: "Viewing"
        case .editing: "Editing"
        }
    }

    public var next: MouseProfile { self == .viewing ? .editing : .viewing }

    /// The user's lines for this profile, next to input.conf.
    public var fileName: String { "input-\(rawValue).conf" }

    /// The profile's own lines. Editing has none: the layout's buttons, marks and their edges under back and forward.
    /// Viewing (the default) leaves the marks: back shows the file's info, forward does nothing for now; the gesture
    /// button, the panel and the middle button are the layout's in both.
    public var defaultConfig: String {
        switch self {
        case .viewing:
            """
            MBTN_BACK script-binding stats/display-stats
            MBTN_BACK_LONG ignore
            MBTN_BACK+WHEEL_UP ignore
            MBTN_BACK+WHEEL_DOWN ignore
            MBTN_FORWARD ignore
            MBTN_FORWARD_LONG ignore
            MBTN_FORWARD+WHEEL_UP ignore
            MBTN_FORWARD+WHEEL_DOWN ignore
            """
        case .editing:
            ""
        }
    }
}

/// The SmartShift button while FrameScrub takes it over (it sets the wheel mode then): a short press switches the
/// wheel between free spin and ratchet, as the mouse itself would; held `threshold` seconds it switches the mouse
/// profile, once, at the threshold (where the click is felt), and its release then leaves the wheel alone.
public struct SmartShiftPress: Sendable {
    public enum Outcome: Equatable, Sendable { case none, short, long }

    public let threshold: Double
    private var pressedAt: Double?
    private var fired = false

    public init(threshold: Double = 0.6) { self.threshold = threshold }

    public mutating func press(at time: Double) {
        pressedAt = time
        fired = false
    }

    /// While held: `.long` once the threshold is reached.
    public mutating func tick(at time: Double) -> Outcome {
        guard let pressedAt, !fired, time - pressedAt >= threshold else { return .none }
        fired = true
        return .long
    }

    /// `.short` before the threshold; `.long` past it if no tick said so yet; nothing after a long press.
    public mutating func release(at time: Double) -> Outcome {
        guard let start = pressedAt else { return .none }
        pressedAt = nil
        if fired { return .none }
        return time - start >= threshold ? .long : .short
    }

    /// The press is void (FrameScrub left the front with the button down).
    public mutating func cancel() {
        pressedAt = nil
        fired = false
    }
}

extension InputMap {
    /// The bindings in effect: the layout's, input.conf (`userText`), the profile's own lines, then the user's
    /// `input-<profile>.conf` (`profileText`).
    public static func build(layout: KeyLayout, userText: String = "", profile: MouseProfile,
                             profileText: String = "") -> InputMap {
        var map = InputMap(layout: layout)
        map.apply(userText)
        map.apply(profile.defaultConfig, source: profile.rawValue, layer: .profile(profile))
        map.apply(profileText, source: profile.fileName, layer: .profileFile(profile))
        return map
    }

    /// The bindings from the files in `Config.directory`, with their warnings.
    public static func load(layout: KeyLayout, profile: MouseProfile) -> (InputMap, [String]) {
        let read = { (name: String) in
            (try? String(contentsOf: Config.directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        var map = InputMap(layout: layout)
        var warnings = map.apply(read("input.conf"))
        map.apply(profile.defaultConfig, source: profile.rawValue, layer: .profile(profile))
        warnings += map.apply(read(profile.fileName), source: profile.fileName, layer: .profileFile(profile))
        return (map, warnings)
    }
}
