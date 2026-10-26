import Foundation

/// The gesture bindings in input.conf as the Preferences table edits them. Like `PreferencesStore`, an edit is
/// applied in memory (and observers told) first, then written; a write error is thrown afterwards.
public final class GesturePreferences {
    public private(set) var inputMap: InputMap
    private let url: URL
    private var observers: [(InputMap) -> Void] = []

    /// The default bindings the file applies to (`key-layout`); a change rebuilds the map and tells the observers.
    public var layout: KeyLayout {
        didSet {
            guard layout != oldValue else { return }
            inputMap = map(from: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            for observer in observers { observer(inputMap) }
        }
    }

    /// The mouse profile whose lines go on top (`mouse-profile`); a change rebuilds the map and tells the observers.
    public var profile: MouseProfile = .viewing {
        didSet {
            guard profile != oldValue else { return }
            inputMap = map(from: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            for observer in observers { observer(inputMap) }
        }
    }

    public init(url: URL = Config.directory.appendingPathComponent("input.conf"), layout: KeyLayout = .classic,
                profile: MouseProfile = .viewing) {
        self.url = url
        self.layout = layout
        self.profile = profile
        inputMap = InputMap(layout: layout)
        inputMap = map(from: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public var bindings: [GestureBinding] { GestureBinding.bindings(in: inputMap) }

    public func addObserver(_ observer: @escaping (InputMap) -> Void) { observers.append(observer) }

    public func set(_ binding: GestureBinding) throws {
        try edit { GestureBindingEditor.setting(binding, in: $0) }
    }

    /// Edits a row. When its gesture (device, axis or modifiers) changed, the old gesture is silenced with
    /// `ignore` — a default binding cannot be deleted — and the new one is bound.
    public func replace(_ old: GestureBinding, with new: GestureBinding) throws {
        try edit { text in
            var out = text
            if !old.sameGesture(as: new) {
                var silenced = old
                silenced.action = .ignore
                silenced.invert = false
                out = GestureBindingEditor.setting(silenced, in: out)
            }
            return GestureBindingEditor.setting(new, in: out)
        }
    }

    public func resetGestures() throws {
        try edit { GestureBindingEditor.resetting($0) }
    }

    private func edit(_ transform: (String) -> String) throws {
        let existing = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        let edited = transform(existing)
        inputMap = map(from: edited)
        for observer in observers { observer(inputMap) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try edited.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The layout, input.conf (`text`), the profile's lines and the user's `input-<profile>.conf` beside input.conf.
    private func map(from text: String) -> InputMap {
        let profileURL = url.deletingLastPathComponent().appendingPathComponent(profile.fileName)
        return InputMap.build(layout: layout, userText: text, profile: profile,
                              profileText: (try? String(contentsOf: profileURL, encoding: .utf8)) ?? "")
    }
}
