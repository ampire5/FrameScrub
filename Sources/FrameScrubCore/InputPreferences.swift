import Foundation

/// Which of the user's binding files an edit goes to.
public enum InputFile: Sendable {
    /// input.conf.
    case main
    /// `input-<profile>.conf` of the current profile, beside input.conf.
    case profile
}

/// The one owner of the live bindings and of the user's binding files (input.conf and `input-<profile>.conf`): the
/// settings window's tables and the gesture table edit through it. Like `PreferencesStore`, an edit is applied in
/// memory (and observers told) first, then written; a write error is thrown afterwards.
public final class InputPreferences {
    public private(set) var inputMap: InputMap
    /// input.conf.
    public let url: URL
    private var observers: [(InputMap) -> Void] = []

    /// The default bindings the file applies to (`key-layout`); a change rebuilds the map and tells the observers.
    public var layout: KeyLayout {
        didSet {
            guard layout != oldValue else { return }
            inputMap = map(from: read(.main))
            for observer in observers { observer(inputMap) }
        }
    }

    /// The mouse profile whose lines go on top (`mouse-profile`); a change rebuilds the map and tells the observers.
    public var profile: MouseProfile = .viewing {
        didSet {
            guard profile != oldValue else { return }
            inputMap = map(from: read(.main))
            for observer in observers { observer(inputMap) }
        }
    }

    public init(url: URL = Config.directory.appendingPathComponent("input.conf"), layout: KeyLayout = .classic,
                profile: MouseProfile = .viewing) {
        self.url = url
        self.layout = layout
        self.profile = profile
        inputMap = InputMap(layout: layout)
        inputMap = map(from: read(.main))
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

    /// Where `file` is: input.conf, or the current profile's file beside it.
    public func url(of file: InputFile) -> URL {
        switch file {
        case .main: url
        case .profile: url.deletingLastPathComponent().appendingPathComponent(profile.fileName)
        }
    }

    /// Writes what `transform` makes of `file`'s text (empty when there is none yet): the map is rebuilt and the
    /// observers told first, then the file is written; a write error is thrown after.
    public func edit(_ file: InputFile, _ transform: (String) -> String) throws {
        let target = url(of: file)
        let existing = FileManager.default.fileExists(atPath: target.path) ? try String(contentsOf: target, encoding: .utf8) : ""
        let edited = transform(existing)
        inputMap = file == .main ? map(from: edited) : map(from: read(.main), profileText: edited)
        for observer in observers { observer(inputMap) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try edited.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Reads both files again (an edit in a text editor); true, and the observers told, when the map changed.
    @discardableResult
    public func reloadFiles() -> Bool {
        let fresh = map(from: read(.main))
        guard fresh != inputMap else { return false }
        inputMap = fresh
        for observer in observers { observer(inputMap) }
        return true
    }

    private func edit(_ transform: (String) -> String) throws {
        try edit(.main, transform)
    }

    private func read(_ file: InputFile) -> String {
        (try? String(contentsOf: url(of: file), encoding: .utf8)) ?? ""
    }

    /// The layout, input.conf (`text`), the profile's lines and the user's `input-<profile>.conf` (`profileText`, read
    /// from beside input.conf when nil).
    private func map(from text: String, profileText: String? = nil) -> InputMap {
        InputMap.build(layout: layout, userText: text, profile: profile, profileText: profileText ?? read(.profile))
    }
}
