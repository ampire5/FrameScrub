import Foundation

/// What the bridge reports about the keys pressed in the plugin panel (the `framescrubKeys` message handler, not a
/// bridge verb): whether the page's focus is in a place that takes typing, and a scrolling key the page let through.
///
/// A key the page leaves unhandled comes back from WebKit and goes on to the player, except the keys WebKit would use
/// to scroll the page: those are caught at the end of the page's own `keydown` dispatch, kept from scrolling, and
/// reported here instead.
public enum PluginKeyMessage: Equatable, Sendable {
    /// The focused element takes typing (a text field, textarea, select, contenteditable, a frame inside the page).
    case editing(Bool)
    /// A scrolling key no listener prevented, with its modifiers (Command chords are left to WebKit and the menus).
    case key(PluginKey)

    /// The scrolling keys by `KeyboardEvent.code`, with their macOS virtual key codes.
    public static let scrollKeys: [String: UInt16] = [
        "Space": 49, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        "PageUp": 116, "PageDown": 121, "Home": 115, "End": 119,
    ]

    /// `{editing: bool}` or `{key: code, shift?, control?, option?, repeat?}`; nil for anything else.
    public static func parse(_ body: [String: Any]) -> PluginKeyMessage? {
        if let editing = body["editing"] as? Bool { return .editing(editing) }
        guard let code = body["key"] as? String, let keyCode = scrollKeys[code] else { return nil }
        func flag(_ name: String) -> Bool { body[name] as? Bool ?? false }
        return .key(PluginKey(keyCode: keyCode, shift: flag("shift"), control: flag("control"), option: flag("option"),
                              isRepeat: flag("repeat")))
    }
}

/// A key reported by the page, as the player reads a key event.
public struct PluginKey: Equatable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public let control: Bool
    public let option: Bool
    public let isRepeat: Bool

    public init(keyCode: UInt16, shift: Bool = false, control: Bool = false, option: Bool = false,
                isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.control = control
        self.option = option
        self.isRepeat = isRepeat
    }
}

/// The keys pressed while the plugin panel has the keyboard, and whether one the page left unhandled goes on to the
/// player. WebKit answers a key-down only after the page has seen it, so the answer can come after the key is up.
public struct PluginKeyState: Equatable, Sendable {
    /// The page's focus takes typing: no key goes to the player, whatever the page did with it.
    public private(set) var editing = false
    private var down: Set<UInt16> = []

    public init() {}

    /// A key went down in the web view (its first sight, not WebKit sending an unhandled one back).
    public mutating func pressed(_ keyCode: UInt16) { down.insert(keyCode) }

    /// A key came up in the web view.
    public mutating func released(_ keyCode: UInt16) { down.remove(keyCode) }

    /// The keyboard moved away from the web view, or to it: its key-ups go elsewhere.
    public mutating func focusMoved() { down.removeAll() }

    /// A new page: its focus is not known to take typing until it says so.
    public mutating func pageReplaced() {
        editing = false
        down.removeAll()
    }

    public mutating func apply(_ message: PluginKeyMessage) {
        if case let .editing(editing) = message { self.editing = editing }
    }

    /// Whether the key is still held.
    public func isDown(_ keyCode: UInt16) -> Bool { down.contains(keyCode) }

    /// Whether a key the page left unhandled goes on to the player: never while the page's focus takes typing, and
    /// an auto-repeat only while its key is still down (one that arrives after the key-up would overshoot).
    public func forwards(_ keyCode: UInt16, isRepeat: Bool) -> Bool {
        !editing && (!isRepeat || isDown(keyCode))
    }
}
