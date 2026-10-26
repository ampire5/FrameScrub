import AppKit
import FrameScrubCore
import SettingsKit

/// The Key Bindings tables' source: the keys and mouse buttons of the live map (`InputPreferences`), each with the
/// layer it comes from, and edits written where they take effect: a chord the current mouse profile sets goes to the
/// profile's own file (`input-<profile>.conf`, which the profile's lines cannot hide), any other to input.conf. The
/// wheel, trackpad and pinch pairs are the gesture table's and not rows here. After every change of the map — its own
/// edits, a profile or layout switch, an edit in a text editor noticed when the app becomes active — it posts
/// `.settingsStoreDidChange` with itself as the object.
@MainActor
public final class InputBindingSource: KeyBindingSource {
    private let preferences: InputPreferences
    private let translateKey: (UInt16, Bool) -> String?
    private let menuRows: @MainActor () -> [(input: String, title: String)]
    private nonisolated(unsafe) var activeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - translateKey: the Latin character a key code types with or without Shift on the ASCII-capable layout, so a
    ///     letter records by its Latin letter on any input language; nil keeps the event's own character.
    ///   - menuRows: the menus' shortcuts, shown after the keys and not edited here.
    public init(preferences: InputPreferences, translateKey: @escaping (UInt16, Bool) -> String?,
                menuRows: @escaping @MainActor () -> [(input: String, title: String)] = { [] }) {
        self.preferences = preferences
        self.translateKey = translateKey
        self.menuRows = menuRows
        preferences.addObserver { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.announce() }
            } else {
                DispatchQueue.main.async { self?.announce() }
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.preferences.reloadFiles() }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    private func announce() {
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": ["input.conf"]])
    }

    /// Under the keyboard table: where the menu rows are changed.
    public static let menuNote = "Menu shortcuts: System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts"

    /// Under the mouse table: which file a button's edit goes to.
    public var profileNote: String {
        let profile = preferences.profile
        return "Profile: \(profile.title). Buttons the profile sets are written to \(profile.fileName)."
    }

    // MARK: Rows

    private struct Row {
        let chord: KeyChord
        let command: Command
        let layer: InputLayer?
    }

    private func bindingRows() -> [Row] {
        let map = preferences.inputMap
        let gestures = Set(GestureBinding.bindings(in: map).flatMap { [$0.chords.0, $0.chords.1] })
        return map.allBindings.filter { !gestures.contains($0.chord) }
            .map { Row(chord: $0.chord, command: $0.command, layer: map.layer(of: $0.chord)) }
    }

    public func rows() -> [KeyBindingRowModel] {
        let menu = menuRows().map { row in
            KeyBindingRowModel(id: Self.menuPrefix + row.input, input: row.input, action: row.title, source: "menu",
                               isMouse: false, canRemove: false, isEditable: false)
        }
        let rows = bindingRows().map { row in
            let off = row.command == .ignore
            return KeyBindingRowModel(
                id: row.chord.description, input: row.chord.displayName, action: off ? "—" : Self.title(of: row.command),
                source: off ? "off" : Self.sourceName(row.layer), isMouse: row.chord.isPointerChord,
                actionID: off ? nil : Self.actionID(of: row.command), step: Self.step(of: row.command),
                canRestore: Self.isFromFile(row.layer), canRemove: !off)
        }
        return rows.filter { !$0.isMouse } + menu + rows.filter(\.isMouse)
    }

    /// A menu row's id: no chord is spelled so, so `remove` and `restoreBuiltIn` pass it by.
    private static let menuPrefix = "menu "

    static func sourceName(_ layer: InputLayer?) -> String {
        switch layer {
        case .builtIn, nil: "built-in"
        case .leftHand: "left-hand"
        case .profile(let profile): "\(profile.rawValue) profile"
        case .file: "input.conf"
        case .profileFile(let profile): profile.fileName
        }
    }

    /// A line of one of the user's files (input.conf or the profile's).
    static func isFromFile(_ layer: InputLayer?) -> Bool {
        switch layer {
        case .file, .profileFile: true
        default: false
        }
    }

    /// The row's action as the `?` cheat sheet names it; the file's words for a command it leaves out.
    static func title(of command: Command) -> String {
        KeyHelp.describe(command)?.action ?? command.configText
    }

    /// What the window's search finds a table by: each row's input (as shown and as the file writes it) and action.
    func searchTexts(mouse: Bool) -> [String] {
        let rows = bindingRows().filter { $0.chord.isPointerChord == mouse }.flatMap { row in
            [row.chord.displayName, row.chord.description, Self.title(of: row.command), row.command.configText]
        }
        return mouse ? rows : rows + menuRows().flatMap { [$0.input, $0.title] }
    }

    /// The file an edit of a chord in `layer` goes to: the profile's own file for what the profile sets, else
    /// input.conf.
    static func file(for layer: InputLayer?) -> InputFile {
        switch layer {
        case .profile, .profileFile: .profile
        default: .main
        }
    }

    // MARK: Actions

    /// An action that takes a number: its pop-up item, title and step, and the command it makes.
    private struct Stepped {
        let id: String
        let title: String
        let section: KeyHelp.Section
        let rule: KeyBindingStep
        let make: (Double) -> Command
    }

    private static let stepped: [Stepped] = [
        Stepped(id: "seek", title: "Seek (seconds)", section: .navigation,
                rule: KeyBindingStep(range: 0.01...3600, defaultValue: 5, signed: true)) { .seek($0, .byConfig) },
        Stepped(id: "seek exact", title: "Seek exactly (seconds)", section: .navigation,
                rule: KeyBindingStep(range: 0.01...3600, defaultValue: 1, signed: true)) { .seek($0, .exact) },
        Stepped(id: "seek keyframes", title: "Seek by keyframes (seconds)", section: .navigation,
                rule: KeyBindingStep(range: 0.01...3600, defaultValue: 10, signed: true)) { .seek($0, .keyframes) },
        Stepped(id: "multiply speed", title: "Speed: multiply by", section: .playback,
                rule: KeyBindingStep(range: 0.1...10, defaultValue: 1.1, signed: false)) { .multiplySpeed($0) },
        Stepped(id: "set speed", title: "Speed: set to", section: .playback,
                rule: KeyBindingStep(range: 0.05...16, defaultValue: 1, signed: false)) { .setSpeed($0) },
        Stepped(id: "add volume", title: "Volume: change by", section: .audio,
                rule: KeyBindingStep(range: 0.1...100, defaultValue: 2, signed: true)) { .addVolume($0) },
        Stepped(id: "add auto-color-strength", title: "Auto colour strength: change by", section: .picture,
                rule: .standard) { .addAutoColorStrength($0) },
        Stepped(id: "set window-scale", title: "Window: scale to", section: .window,
                rule: KeyBindingStep(range: 0.1...8, defaultValue: 1, signed: false)) { .windowScale($0) },
    ]

    /// The commands without a number the sheet offers, as the file writes them. Zoom is left out: it is not
    /// available yet.
    private static let plain = [
        "cycle pause", "hold-speed", "step-speed down", "step-speed up", "ab-loop", "cycle-ab-loop-mode",
        "toggle-segment-lock", "shuttle-back", "shuttle-stop", "shuttle-forward",
        "frame-back-step", "frame-step", "scrub", "scrub fast", "keyframe-back-step", "keyframe-step",
        "revert-seek", "go-to", "scene-back-step", "scene-step", "playlist-prev", "playlist-next", "playlist-filter",
        "cycle-playlist-sort", "delete-file",
        "screenshot", "copy-frame", "export-range", "reveal-frames", "mark-in", "mark-out", "mark-prev", "mark-next",
        "mark-snap", "mark-loop", "mark-delete", "mark-clear", "play-marks", "save-clip", "scrub-edge start",
        "scrub-edge end",
        "toggle-vibrance", "toggle-auto-color", "toggle-upscaler", "cycle-upscaler", "cycle-aspect", "save-auto-color",
        "save-auto-color folder", "save-vibrance", "save-vibrance folder", "reset-color file", "reset-color folder",
        "cycle fullscreen", "set fullscreen no", "window-fit", "cycle ontop", "toggle-playlist", "show-progress",
        "script-binding stats/display-stats", "show-keys", "cycle-mouse-profile", "close-file", "quit",
        "cycle mute", "toggle-scrub-audio", "toggle-scrub-audio-pitch",
    ]

    /// The cheat sheet's sections in its order, each with its actions in its order; the actions with a number last.
    public func actionGroups() -> [(group: String, actions: [(id: String, title: String, takesStep: Bool)])] {
        typealias Item = (id: String, title: String, takesStep: Bool)
        var items: [KeyHelp.Section: [(rank: Int, item: Item)]] = [:]
        for text in Self.plain {
            guard let command = Command.parse(text), let described = KeyHelp.describe(command) else { continue }
            items[described.section, default: []].append((described.rank, (text, described.action, false)))
        }
        for action in Self.stepped {
            items[action.section, default: []].append((Int.max, (action.id, action.title, true)))
        }
        return KeyHelp.Section.allCases.compactMap { section in
            guard let list = items[section], !list.isEmpty else { return nil }
            return (section.title, list.sorted { $0.rank < $1.rank }.map(\.item))
        }
    }

    public func stepRule(for actionID: String) -> KeyBindingStep {
        Self.stepped.first { $0.id == actionID }?.rule ?? .standard
    }

    /// The pop-up item of a command: its words in the file, those of a command with a number without the number.
    static func actionID(of command: Command) -> String {
        switch command {
        case .seek(_, .byConfig): "seek"
        case .seek(_, .exact): "seek exact"
        case .seek(_, .keyframes): "seek keyframes"
        case .multiplySpeed: "multiply speed"
        case .setSpeed: "set speed"
        case .addVolume: "add volume"
        case .addAutoColorStrength: "add auto-color-strength"
        case .windowScale: "set window-scale"
        default: command.configText
        }
    }

    /// The number of a command that takes one (its pop-up item steps by it).
    static func step(of command: Command) -> Double? {
        switch command {
        case .seek(let v, _), .multiplySpeed(let v), .setSpeed(let v), .addVolume(let v), .addAutoColorStrength(let v),
             .windowScale(let v): v
        default: nil
        }
    }

    /// The command a pop-up item and step stand for; nil for an unknown item or a missing step.
    static func command(_ id: String, step: Double?) -> Command? {
        if let action = stepped.first(where: { $0.id == id }) { return step.map(action.make) }
        guard id != "ignore" else { return nil }
        return Command.parse(id)
    }

    // MARK: Sheet

    public func mouseButtons() -> [(id: String, title: String)] {
        MouseButton.allCases.map { button in
            let title = switch button {
            case .mid: "Middle"
            case .back: "Back"
            case .forward: "Forward"
            case .panel: "Panel"
            case .gesture: "Gesture button"
            case .shift: "SmartShift button"
            }
            return (button.rawValue, title)
        }
    }

    /// Tap, hold, double tap, the wheel turned while it is held, with the right button held. A button that cannot be
    /// held with other input (SmartShift) takes no wheel.
    public func pressKinds(for button: String) -> [(id: String, title: String, enabled: Bool)] {
        guard let b = MouseButton(rawValue: button) else { return [] }
        let held = b.modifier != nil
        let kinds = [(button, "Tap", true), (button + "_LONG", "Hold", true), (button + "_DBL", "Double tap", true),
                     (button + "+WHEEL_UP", "+ wheel up", held), (button + "+WHEEL_DOWN", "+ wheel down", held),
                     ("MBTN_RIGHT+" + button, "With the right button", true)]
        return kinds.map { (id: $0.0, title: $0.1, enabled: $0.2 && KeyChord.parse($0.0) != nil) }
    }

    public func keyToken(for event: NSEvent) -> Result<String, KeyBindingRefusal> {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.ctrl) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.meta) }
        let characters = translateKey(event.keyCode, flags.contains(.shift)) ?? event.charactersIgnoringModifiers
        guard let chord = KeyChord.fromKeyEvent(keyCode: event.keyCode, characters: characters, modifiers: modifiers) else {
            return .failure(KeyBindingRefusal("Not a key FrameScrub can bind"))
        }
        if KeyChord.menuOwned.contains(chord) { return .failure(KeyBindingRefusal("Belongs to a menu item")) }
        return .success(chord.description)
    }

    public func conflict(input: String) -> String? {
        guard let chord = KeyChord.parse(input), let command = preferences.inputMap.command(for: chord) else { return nil }
        return Self.title(of: command)
    }

    // MARK: Writes

    /// A problem with what the sheet asked for (it offers only good inputs and actions).
    struct Refused: LocalizedError {
        let errorDescription: String?
    }

    public func bind(input: String, action: String, step: Double?) throws {
        guard let chord = KeyChord.parse(input) else { throw Refused(errorDescription: "\(input) is not an input") }
        guard let command = Self.command(action, step: step) else {
            throw Refused(errorDescription: "\(action) is not an action input.conf takes")
        }
        try preferences.edit(Self.file(for: preferences.inputMap.layer(of: chord))) {
            ConfigText.settingBindings([(chord: chord, command: command.configText)], in: $0)
        }
    }

    /// The layout's or the profile's binding gets an `ignore` line in the file that beats it; a line of a file is
    /// commented out (the binding below it applies again). An input that is off already is left alone.
    public func remove(rowID: String) throws {
        guard let chord = KeyChord.parse(rowID), let command = preferences.inputMap.bindings[chord],
              command != .ignore else { return }
        let layer = preferences.inputMap.layer(of: chord)
        if Self.isFromFile(layer) {
            try restoreBuiltIn(rowID: rowID)
            return
        }
        try preferences.edit(Self.file(for: layer)) {
            ConfigText.settingBindings([(chord: chord, command: Command.ignore.configText)], in: $0)
        }
    }

    /// The line of the file the row comes from is commented out.
    public func restoreBuiltIn(rowID: String) throws {
        guard let chord = KeyChord.parse(rowID) else { return }
        let file: InputFile
        switch preferences.inputMap.layer(of: chord) {
        case .file: file = .main
        case .profileFile: file = .profile
        default: return
        }
        try preferences.edit(file) { ConfigText.commentingOutBindings(for: [chord], in: $0) }
    }
}
