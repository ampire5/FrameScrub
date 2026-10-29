import Foundation

public enum GestureDevice: String, CaseIterable, Sendable {
    case trackpad = "TRACKPAD", wheel = "WHEEL", pinch = "PINCH"
}

public enum GestureAxis: Int, CaseIterable, Sendable { case horizontal, vertical }

public enum GestureActionKind: Equatable, Sendable {
    case scrub, scrubFast
    case seek(Double, SeekPrecision)
    case volume(Double)
    case speed(Double)
    /// `step-speed up` / `down`: by `speed-step`.
    case speedStep
    case playlist
    case zoom(Double), zoomContinuous
    case ignore
}

/// One row of the "Mouse & trackpad" table: both sides of a gesture axis share an action.
public struct GestureBinding: Equatable, Sendable {
    public var device: GestureDevice
    public var axis: GestureAxis
    public var modifiers: Modifiers
    public var action: GestureActionKind
    public var invert: Bool

    public init(device: GestureDevice, axis: GestureAxis, modifiers: Modifiers, action: GestureActionKind, invert: Bool = false) {
        self.device = device
        self.axis = device == .pinch ? .horizontal : axis    // pinch has no axis: keep rows comparable
        self.modifiers = modifiers
        self.action = action
        self.invert = invert
    }

    public func sameGesture(as other: GestureBinding) -> Bool {
        device == other.device && axis == other.axis && modifiers == other.modifiers
    }

    /// Key names of the two sides: LEFT/RIGHT, UP/DOWN or PINCH_OUT/PINCH_IN.
    static func sideNames(_ device: GestureDevice, _ axis: GestureAxis) -> (String, String) {
        switch device {
        case .pinch: return ("PINCH_OUT", "PINCH_IN")
        default: return axis == .horizontal ? ("\(device.rawValue)_LEFT", "\(device.rawValue)_RIGHT")
                                            : ("\(device.rawValue)_UP", "\(device.rawValue)_DOWN")
        }
    }

    public var chords: (KeyChord, KeyChord) {
        let names = Self.sideNames(device, axis)
        return (KeyChord(key: names.0, modifiers: modifiers), KeyChord(key: names.1, modifiers: modifiers))
    }

    public var commands: (Command, Command) {
        func signed(_ plus: Command, _ minus: Command) -> (Command, Command) { invert ? (minus, plus) : (plus, minus) }
        switch action {
        case .scrub: return (.scrub(fast: false, invert: invert), .scrub(fast: false, invert: invert))
        case .scrubFast: return (.scrub(fast: true, invert: invert), .scrub(fast: true, invert: invert))
        case let .seek(seconds, precision): return signed(.seek(seconds, precision), .seek(-seconds, precision))
        case let .volume(step): return signed(.addVolume(step), .addVolume(-step))
        case let .zoom(step): return signed(.zoom(step), .zoom(-step))
        case let .speed(factor): return signed(.multiplySpeed(factor), .multiplySpeed(1 / factor))
        case .speedStep: return signed(.stepSpeed(1), .stepSpeed(-1))
        case .playlist: return signed(.playlistNext, .playlistPrev)
        case .zoomContinuous: return (.zoom(nil), .zoom(nil))
        case .ignore: return (.ignore, .ignore)
        }
    }

    public var lines: [(chord: KeyChord, command: String)] {
        let (chords, commands) = (self.chords, self.commands)
        return [(chords.0, commands.0.configText), (chords.1, commands.1.configText)]
    }

    /// The row a pair of commands stands for; nil when the two sides are not a symmetric pair.
    public static func decode(device: GestureDevice, axis: GestureAxis, modifiers: Modifiers,
                              primary: Command, secondary: Command) -> GestureBinding? {
        func row(_ action: GestureActionKind, _ invert: Bool = false) -> GestureBinding {
            GestureBinding(device: device, axis: axis, modifiers: modifiers, action: action, invert: invert)
        }
        func opposite(_ a: Double, _ b: Double) -> Bool { a != 0 && abs(a + b) < 1e-9 }
        switch (primary, secondary) {
        case let (.scrub(f1, i1), .scrub(f2, i2)) where f1 == f2 && i1 == i2: return row(f1 ? .scrubFast : .scrub, i1)
        case (.ignore, .ignore): return row(.ignore)
        case (.zoom(nil), .zoom(nil)): return row(.zoomContinuous)
        case let (.seek(a, p1), .seek(b, p2)) where p1 == p2 && opposite(a, b): return row(.seek(abs(a), p1), a < 0)
        case let (.addVolume(a), .addVolume(b)) where opposite(a, b): return row(.volume(abs(a)), a < 0)
        case let (.zoom(a?), .zoom(b?)) where opposite(a, b): return row(.zoom(abs(a)), a < 0)
        case let (.multiplySpeed(a), .multiplySpeed(b)) where a > 0 && b > 0 && abs(a * b - 1) < 1e-9:
            return row(.speed(a < 1 ? 1 / a : a), a < 1)
        case let (.stepSpeed(a), .stepSpeed(b)) where a != 0 && a == -b: return row(.speedStep, a < 0)
        case (.playlistNext, .playlistPrev): return row(.playlist)
        case (.playlistPrev, .playlistNext): return row(.playlist, true)
        default: return nil
        }
    }

    /// Every symmetric gesture pair in `map`, in a stable order (device, axis, modifiers).
    public static func bindings(in map: InputMap) -> [GestureBinding] {
        struct Group: Hashable { var device: GestureDevice; var axis: GestureAxis; var modifiers: Modifiers }
        var groups = Set<Group>()
        for chord in map.bindings.keys {
            guard chord.modifiers.isDisjoint(with: .heldButtons),     // button chords have their own settings
                  let device = GestureDevice.allCases.first(where: { chord.key.hasPrefix($0.rawValue + "_") }) else { continue }
            let side = String(chord.key.dropFirst(device.rawValue.count + 1))
            let axis: GestureAxis = ["UP", "DOWN"].contains(side) ? .vertical : .horizontal
            groups.insert(Group(device: device, axis: axis, modifiers: chord.modifiers))
        }
        let rows: [GestureBinding] = groups.compactMap { group in
            let names = sideNames(group.device, group.axis)
            guard let primary = map.bindings[KeyChord(key: names.0, modifiers: group.modifiers)],
                  let secondary = map.bindings[KeyChord(key: names.1, modifiers: group.modifiers)] else { return nil }
            return decode(device: group.device, axis: group.axis, modifiers: group.modifiers, primary: primary, secondary: secondary)
        }
        return rows.sorted {
            ($0.device.rawValue, $0.axis.rawValue, $0.modifiers.rawValue) < ($1.device.rawValue, $1.axis.rawValue, $1.modifiers.rawValue)
        }
    }
}

public enum GestureBindingEditor {
    /// A wheel / trackpad / pinch chord the table can show. Chords with a held MX or side button
    /// (`MX_PANEL+WHEEL_UP`, `MBTN_BACK+WHEEL_UP`) are the user's own lines, not table rows.
    public static func isGestureChord(_ chord: KeyChord) -> Bool {
        chord.modifiers.isDisjoint(with: .heldButtons)
            && GestureDevice.allCases.contains { chord.key.hasPrefix($0.rawValue + "_") }
    }

    /// Rewrites (or appends) the two lines of `binding`; the user's other lines and comments stay.
    public static func setting(_ binding: GestureBinding, in text: String) -> String {
        ConfigText.settingBindings(binding.lines.map { (chord: $0.chord, command: $0.command) }, in: text)
    }

    /// Removes every gesture line: the defaults apply again.
    public static func resetting(_ text: String) -> String {
        ConfigText.removingBindings(where: isGestureChord, in: text)
    }
}
