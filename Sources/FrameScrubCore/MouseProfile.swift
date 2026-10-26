import Foundation

/// What the mouse's buttons do (`mouse-profile`): Viewing is the layout's bindings; Editing puts play, frames, clips
/// and marks under the buttons. Each profile's lines go on top of input.conf, and the user's
/// `input-<profile>.conf` on top of them. A double press of the SmartShift button, the `cycle-mouse-profile` command
/// or View › Mouse Profile switches it.
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

    /// The profile's own lines: none for Viewing (the layout's buttons).
    public var defaultConfig: String {
        switch self {
        case .viewing:
            ""
        case .editing:
            """
            MX_GESTURE cycle pause
            MX_GESTURE_LONG save-clip
            MX_PANEL screenshot
            MX_PANEL_LONG export-range
            MBTN_MID play-marks
            MBTN_BACK mark-in
            MBTN_BACK_LONG mark-snap
            MBTN_FORWARD mark-out
            MBTN_FORWARD_LONG mark-delete
            """
        }
    }
}

/// Two presses within `window` seconds: the second one says so; a third starts again.
public struct DoublePress: Sendable {
    public let window: Double
    private var last: Double?

    public init(window: Double = 0.6) { self.window = window }

    public mutating func press(at time: Double) -> Bool {
        if let last, time - last <= window {
            self.last = nil
            return true
        }
        last = time
        return false
    }
}

extension InputMap {
    /// The bindings in effect: the layout's, input.conf (`userText`), the profile's own lines, then the user's
    /// `input-<profile>.conf` (`profileText`).
    public static func build(layout: KeyLayout, userText: String = "", profile: MouseProfile,
                             profileText: String = "") -> InputMap {
        var map = InputMap(layout: layout)
        map.apply(userText)
        map.apply(profile.defaultConfig, source: profile.rawValue)
        map.apply(profileText, source: profile.fileName)
        return map
    }

    /// The bindings from the files in `Config.directory`, with their warnings.
    public static func load(layout: KeyLayout, profile: MouseProfile) -> (InputMap, [String]) {
        let read = { (name: String) in
            (try? String(contentsOf: Config.directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        var map = InputMap(layout: layout)
        var warnings = map.apply(read("input.conf"))
        map.apply(profile.defaultConfig, source: profile.rawValue)
        warnings += map.apply(read(profile.fileName), source: profile.fileName)
        return (map, warnings)
    }
}
