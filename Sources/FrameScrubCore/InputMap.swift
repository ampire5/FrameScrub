import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let ctrl = Modifiers(rawValue: 2)
    public static let alt = Modifiers(rawValue: 4)
    public static let meta = Modifiers(rawValue: 8)
    /// The right mouse button is held: `MBTN_RIGHT+WHEEL_UP`, `MBTN_RIGHT+MBTN_MID`.
    public static let rightButton = Modifiers(rawValue: 16)
    /// Another button is held: `MBTN_BACK+WHEEL_UP`, `MX_PANEL+WHEEL_UP`, `MBTN_MID+WHEEL_UP`.
    public static let backButton = Modifiers(rawValue: 32)
    public static let forwardButton = Modifiers(rawValue: 64)
    public static let panelButton = Modifiers(rawValue: 128)
    public static let gestureButton = Modifiers(rawValue: 256)
    public static let midButton = Modifiers(rawValue: 512)
    /// The buttons held next to the pointer and wheel; the right button is separate (it has table rows of its own).
    public static let heldButtons: Modifiers = [.backButton, .forwardButton, .panelButton, .gestureButton, .midButton]

    /// The names of the held buttons in `description` order, with the modifier of each.
    static let heldButtonNames: [(name: String, modifier: Modifiers)] = [
        ("MBTN_RIGHT", .rightButton), ("MBTN_BACK", .backButton), ("MBTN_FORWARD", .forwardButton),
        ("MBTN_MID", .midButton), ("MX_PANEL", .panelButton), ("MX_GESTURE", .gestureButton),
    ]
}

/// A key or mouse input in mpv naming. Named keys are upper-case ("SPACE", "LEFT", "WHEEL_UP",
/// "MBTN_RIGHT"); character keys are the character itself with Shift folded in ("S", "<").
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers = []) {
        if key.count == 1 {
            self.key = modifiers.contains(.shift) ? key.uppercased() : key
            self.modifiers = modifiers.subtracting(.shift)
        } else {
            self.key = key.uppercased()
            self.modifiers = modifiers
        }
    }

    public var description: String {
        var parts: [String] = []
        for (name, modifier) in Modifiers.heldButtonNames where modifiers.contains(modifier) { parts.append(name) }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.ctrl) { parts.append("Ctrl") }
        if modifiers.contains(.alt) { parts.append("Alt") }
        if modifiers.contains(.meta) { parts.append("Meta") }
        return (parts + [key]).joined(separator: "+")
    }

    /// A mouse button, wheel, swipe or pinch, or any chord needing a mouse button held: no keyboard key.
    public var isPointerChord: Bool {
        isPointer || !modifiers.isDisjoint(with: Modifiers.heldButtons.union(.rightButton))
    }

    /// The ⌘ chords owned by the app's menu items: AppKit gives the menu the key before the player sees it, so no
    /// binding, the page's included, could ever fire.
    public static let menuOwned: Set<KeyChord> = {
        var set: Set<KeyChord> = []
        for key in [",", "q", "o", "c", "w", "z", "x", "v", "a", "m", "g", "f", "1", "2", "3", "4", "BS"] {
            set.insert(KeyChord(key: key, modifiers: .meta))
        }
        set.insert(KeyChord(key: "o", modifiers: [.meta, .shift]))
        set.insert(KeyChord(key: "z", modifiers: [.meta, .shift]))
        set.insert(KeyChord(key: "c", modifiers: [.meta, .alt]))
        set.insert(KeyChord(key: "p", modifiers: [.meta, .alt]))
        set.insert(KeyChord(key: "l", modifiers: .meta))
        set.insert(KeyChord(key: "l", modifiers: [.meta, .alt]))
        set.insert(KeyChord(key: "p", modifiers: [.meta, .alt, .ctrl]))
        set.insert(KeyChord(key: "f", modifiers: [.meta, .ctrl]))
        for key in ["LEFT", "RIGHT", "DOWN"] {   // View › Slots
            set.insert(KeyChord(key: key, modifiers: [.meta, .ctrl]))
        }
        return set
    }()

    /// Parses mpv key syntax: "Shift+LEFT", "Ctrl+s", "S", "Ctrl++"; `MBTN_RIGHT+`, `MBTN_BACK+`, `MX_PANEL+`… hold a button.
    public static func parse(_ spec: String) -> KeyChord? {
        var modifiers: Modifiers = []
        var rest = Substring(spec)
        while let plus = rest.firstIndex(of: "+"), plus != rest.startIndex {
            switch rest[..<plus].lowercased() {
            case "shift": modifiers.insert(.shift)
            case "ctrl": modifiers.insert(.ctrl)
            case "alt": modifiers.insert(.alt)
            case "meta", "cmd": modifiers.insert(.meta)
            case let name:
                guard let held = Modifiers.heldButtonNames.first(where: { $0.name.lowercased() == name }) else { return nil }
                modifiers.insert(held.modifier)
            }
            rest = rest[rest.index(after: plus)...]
        }
        guard !rest.isEmpty else { return nil }
        return KeyChord(key: String(rest), modifiers: modifiers)
    }

    /// `characters` is what the key types with Shift applied and other modifiers ignored (read through a Latin
    /// layout when the current one is not, see `KeyboardLayout`).
    public static func fromKeyEvent(keyCode: UInt16, characters: String?, modifiers: Modifiers) -> KeyChord? {
        if let name = namedKeys[keyCode] { return KeyChord(key: name, modifiers: modifiers) }
        guard let characters, characters.count == 1 else { return nil }
        return KeyChord(key: characters, modifiers: modifiers)
    }

    private static let namedKeys: [UInt16: String] = [
        123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP", 49: "SPACE", 51: "BS", 53: "ESC",
        36: "ENTER", 76: "ENTER", 48: "TAB", 117: "DEL", 115: "HOME", 119: "END", 116: "PGUP", 121: "PGDWN",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

public enum SeekPrecision: Equatable, Sendable { case byConfig, exact, keyframes }

public enum Command: Equatable, Sendable {
    case cyclePause
    case seek(Double, SeekPrecision)
    case frameStep, frameBackStep
    case keyframeStep, keyframeBackStep
    case sceneStep, sceneBackStep
    case revertSeek
    case scrub(fast: Bool, invert: Bool)
    case multiplySpeed(Double), setSpeed(Double)
    /// One `speed-step` up (+1) or down (−1), onto the step grid.
    case stepSpeed(Int)
    case addVolume(Double), cycleMute
    /// `add auto-color-strength 0.05`: the strength of auto colour, up or down.
    case addAutoColorStrength(Double)
    /// `scrub-edge start|end`: the wheel drags the start or the end of the mark under the position.
    case scrubEdge(MarkEdge)
    case cycleFullscreen, setFullscreen(Bool)
    case cycleOntop
    case showProgress, stats
    case abLoop, cycleABLoopMode
    case toggleSegmentLock
    case markIn, markOut, markPrev, markNext, markSnap, markLoop, markDelete, markClear, playMarks
    case shuttleBack, shuttleStop, shuttleForward
    case screenshot, exportRange, saveClip
    case zoom(Double?), zoomReset
    case playlistPrev, playlistNext, togglePlaylist, cyclePlaylistSort, playlistFilter
    case deleteFile, closeFile
    /// `show-in-folder`: Home's Folders on the video's folder, the video selected.
    case showInFolder
    case toggleUpscaler, cycleUpscaler
    /// The other mouse profile (`MouseProfile`).
    case cycleMouseProfile
    case toggleVibrance, toggleAutoColor
    /// `save-auto-color [folder]` / `save-vibrance [folder]`: the effective values of the set become the default (`framescrub.conf`) or the folder's.
    case saveAutoColor(folder: Bool), saveVibrance(folder: Bool)
    /// `reset-color file|folder`: drop the colour values of the file or of its folder.
    case resetColor(ColorLevel)
    case toggleScrubAudio, toggleScrubAudioPitch
    case cycleAspect
    case windowScale(Double), windowFit
    case copyFrame, revealFrames
    case goTo
    case holdSpeed
    case showKeys
    case quit
    /// `plugin-action <name>`: runs the plugin page's declared action `name` (see `PluginAction`).
    case pluginAction(String)
    case ignore

    /// Whether the command is about the window or the app, not the video: the only ones run while Home is in the
    /// window (a space, an arrow or a wheel binding there must not pause, seek or show the player's icons).
    public var worksWithoutPlayer: Bool {
        switch self {
        case .cycleFullscreen, .setFullscreen, .cycleOntop, .quit, .cycleMouseProfile, .toggleUpscaler, .cycleUpscaler,
             .pluginAction, .ignore:
            return true
        default:
            return false
        }
    }

    /// Whether holding the key down repeats the command. Toggles and one-shot actions would
    /// flicker or fire many times; seeking, stepping, speed, volume and zoom are meant to repeat.
    public var repeatsWhenHeld: Bool {
        switch self {
        case .seek, .frameStep, .frameBackStep, .keyframeStep, .keyframeBackStep, .markPrev, .markNext, .scrub, .multiplySpeed, .setSpeed, .stepSpeed, .addVolume, .addAutoColorStrength, .scrubEdge, .zoom, .ignore:
            return true
        default:
            return false
        }
    }

    /// A `toggle-*` or `cycle …` / `cycle-*` command that plays `haptic-toggle` when run from a key or a mouse button
    /// (mouse spec §5.6): it switches something on, off or to its next state. Except `cycle pause`: play / pause is
    /// pressed all the time and has its own feedback on screen, so it stays silent.
    public var isToggle: Bool {
        guard self != .cyclePause else { return false }
        return configText.hasPrefix("toggle-") || configText.hasPrefix("cycle ") || configText.hasPrefix("cycle-")
    }

    /// The input.conf text of the command; `Command.parse(c.configText) == c`.
    public var configText: String {
        switch self {
        case .cyclePause: return "cycle pause"
        case let .seek(amount, precision):
            return "seek \(formatNumber(amount))" + (precision == .exact ? " exact" : precision == .keyframes ? " keyframes" : "")
        case .frameStep: return "frame-step"
        case .frameBackStep: return "frame-back-step"
        case .keyframeStep: return "keyframe-step"
        case .keyframeBackStep: return "keyframe-back-step"
        case .sceneStep: return "scene-step"
        case .sceneBackStep: return "scene-back-step"
        case .revertSeek: return "revert-seek"
        case let .scrub(fast, invert): return (["scrub"] + (fast ? ["fast"] : []) + (invert ? ["invert"] : [])).joined(separator: " ")
        case let .multiplySpeed(factor): return "multiply speed \(formatNumber(factor))"
        case let .setSpeed(value): return "set speed \(formatNumber(value))"
        case let .stepSpeed(direction): return "step-speed \(direction < 0 ? "down" : "up")"
        case let .addVolume(delta): return "add volume \(formatNumber(delta))"
        case let .addAutoColorStrength(delta): return "add auto-color-strength \(formatNumber(delta))"
        case let .scrubEdge(edge): return "scrub-edge \(edge == .start ? "start" : "end")"
        case .cycleMute: return "cycle mute"
        case .cycleFullscreen: return "cycle fullscreen"
        case .cycleOntop: return "cycle ontop"
        case let .setFullscreen(on): return "set fullscreen \(on ? "yes" : "no")"
        case .showProgress: return "show-progress"
        case .stats: return "script-binding stats/display-stats"
        case .abLoop: return "ab-loop"
        case .cycleABLoopMode: return "cycle-ab-loop-mode"
        case .toggleSegmentLock: return "toggle-segment-lock"
        case .markIn: return "mark-in"
        case .markOut: return "mark-out"
        case .markPrev: return "mark-prev"
        case .markNext: return "mark-next"
        case .markSnap: return "mark-snap"
        case .markLoop: return "mark-loop"
        case .markDelete: return "mark-delete"
        case .markClear: return "mark-clear"
        case .playMarks: return "play-marks"
        case .shuttleBack: return "shuttle-back"
        case .shuttleStop: return "shuttle-stop"
        case .shuttleForward: return "shuttle-forward"
        case .screenshot: return "screenshot"
        case .exportRange: return "export-range"
        case .saveClip: return "save-clip"
        case let .zoom(step): return step.map { "zoom \(formatNumber($0))" } ?? "zoom"
        case .zoomReset: return "zoom-reset"
        case .playlistPrev: return "playlist-prev"
        case .playlistNext: return "playlist-next"
        case .togglePlaylist: return "toggle-playlist"
        case .cyclePlaylistSort: return "cycle-playlist-sort"
        case .playlistFilter: return "playlist-filter"
        case .deleteFile: return "delete-file"
        case .closeFile: return "close-file"
        case .showInFolder: return "show-in-folder"
        case .toggleUpscaler: return "toggle-upscaler"
        case .cycleMouseProfile: return "cycle-mouse-profile"
        case .cycleUpscaler: return "cycle-upscaler"
        case .toggleVibrance: return "toggle-vibrance"
        case .toggleScrubAudio: return "toggle-scrub-audio"
        case .toggleScrubAudioPitch: return "toggle-scrub-audio-pitch"
        case .toggleAutoColor: return "toggle-auto-color"
        case let .saveAutoColor(folder): return folder ? "save-auto-color folder" : "save-auto-color"
        case let .saveVibrance(folder): return folder ? "save-vibrance folder" : "save-vibrance"
        case let .resetColor(level): return level == .file ? "reset-color file" : "reset-color folder"
        case .cycleAspect: return "cycle-aspect"
        case let .windowScale(scale): return "set window-scale \(formatNumber(scale))"
        case .windowFit: return "window-fit"
        case .copyFrame: return "copy-frame"
        case .revealFrames: return "reveal-frames"
        case .goTo: return "go-to"
        case .holdSpeed: return "hold-speed"
        case .showKeys: return "show-keys"
        case .quit: return "quit"
        case let .pluginAction(name): return "plugin-action \(name)"
        case .ignore: return "ignore"
        }
    }

    /// mpv prefixes that only affect OSD behaviour; accepted and ignored.
    private static let prefixes: Set<String> = ["no-osd", "osd-auto", "osd-bar", "osd-msg", "osd-msg-bar", "raw", "async", "sync"]

    public static func parse(_ text: String) -> Command? {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, prefixes.contains(first) { words.removeFirst() }
        guard let name = words.first else { return nil }
        let args = Array(words.dropFirst())
        func number(_ s: String) -> Double? {
            let parts = s.split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
            return Double(s)
        }
        func numberArg(_ i: Int) -> Double? { args.count > i ? number(args[i]) : nil }

        switch (name, args.first) {
        case ("cycle", "pause"): return .cyclePause
        case ("cycle", "mute"): return .cycleMute
        case ("cycle", "fullscreen"): return .cycleFullscreen
        case ("cycle", "ontop"): return .cycleOntop
        case ("seek", .some):
            guard let amount = numberArg(0) else { return nil }
            let precision: SeekPrecision = args.contains("exact") ? .exact : args.contains("keyframes") ? .keyframes : .byConfig
            return .seek(amount, precision)
        case ("frame-step", nil): return .frameStep
        case ("frame-back-step", nil): return .frameBackStep
        case ("keyframe-step", nil): return .keyframeStep
        case ("keyframe-back-step", nil): return .keyframeBackStep
        case ("scene-step", nil): return .sceneStep
        case ("scene-back-step", nil): return .sceneBackStep
        case ("revert-seek", nil): return .revertSeek
        case ("scrub", _):
            let flags = Set(args)
            guard flags.isSubset(of: ["fast", "invert"]) else { return nil }
            return .scrub(fast: flags.contains("fast"), invert: flags.contains("invert"))
        case ("multiply", "speed"): return numberArg(1).map { .multiplySpeed($0) }
        case ("step-speed", "up"): return .stepSpeed(1)
        case ("step-speed", "down"): return .stepSpeed(-1)
        case ("set", "speed"): return numberArg(1).map { .setSpeed($0) }
        case ("set", "fullscreen"):
            guard args.count > 1 else { return nil }
            return ["yes", "true"].contains(args[1]) ? .setFullscreen(true)
                : ["no", "false"].contains(args[1]) ? .setFullscreen(false) : nil
        case ("add", "volume"): return numberArg(1).map { .addVolume($0) }
        case ("add", "auto-color-strength"): return numberArg(1).map { .addAutoColorStrength($0) }
        case ("scrub-edge", "start"): return args.count == 1 ? .scrubEdge(.start) : nil
        case ("scrub-edge", "end"): return args.count == 1 ? .scrubEdge(.end) : nil
        case ("show-progress", nil): return .showProgress
        case let ("script-binding", binding?) where binding.hasPrefix("stats"): return .stats
        case ("ab-loop", nil): return .abLoop
        case ("cycle-ab-loop-mode", nil): return .cycleABLoopMode
        case ("toggle-segment-lock", nil): return .toggleSegmentLock
        case ("mark-in", nil): return .markIn
        case ("mark-out", nil): return .markOut
        case ("mark-prev", nil): return .markPrev
        case ("mark-next", nil): return .markNext
        case ("mark-snap", nil): return .markSnap
        case ("mark-loop", nil): return .markLoop
        case ("mark-delete", nil): return .markDelete
        case ("mark-clear", nil): return .markClear
        case ("play-marks", nil): return .playMarks
        case ("shuttle-back", nil): return .shuttleBack
        case ("shuttle-stop", nil): return .shuttleStop
        case ("shuttle-forward", nil): return .shuttleForward
        case ("screenshot", _): return .screenshot
        case ("export-range", nil): return .exportRange
        case ("save-clip", nil): return .saveClip
        case ("zoom", nil): return .zoom(nil)
        case ("zoom", .some): return numberArg(0).map { .zoom($0) }
        case ("zoom-reset", nil): return .zoomReset
        case ("playlist-prev", nil): return .playlistPrev
        case ("playlist-next", nil): return .playlistNext
        case ("toggle-playlist", nil): return .togglePlaylist
        case ("cycle-playlist-sort", nil): return .cyclePlaylistSort
        case ("playlist-filter", nil): return .playlistFilter
        case ("delete-file", nil): return .deleteFile
        case ("close-file", nil): return .closeFile
        case ("show-in-folder", nil): return .showInFolder
        case ("toggle-upscaler", nil): return .toggleUpscaler
        case ("cycle-mouse-profile", nil): return .cycleMouseProfile
        case ("cycle-upscaler", nil): return .cycleUpscaler
        case ("toggle-vibrance", nil): return .toggleVibrance
        case ("toggle-scrub-audio", nil): return .toggleScrubAudio
        case ("toggle-scrub-audio-pitch", nil): return .toggleScrubAudioPitch
        case ("toggle-auto-color", nil): return .toggleAutoColor
        case ("save-auto-color", nil): return .saveAutoColor(folder: false)
        case ("save-auto-color", "folder"): return args.count == 1 ? .saveAutoColor(folder: true) : nil
        case ("save-vibrance", nil): return .saveVibrance(folder: false)
        case ("save-vibrance", "folder"): return args.count == 1 ? .saveVibrance(folder: true) : nil
        case ("reset-color", "file"): return args.count == 1 ? .resetColor(.file) : nil
        case ("reset-color", "folder"): return args.count == 1 ? .resetColor(.folder) : nil
        case ("cycle-aspect", nil): return .cycleAspect
        case ("set", "window-scale"): return numberArg(1).flatMap { $0 > 0 ? .windowScale($0) : nil }
        case ("window-fit", nil): return .windowFit
        case ("copy-frame", nil): return .copyFrame
        case ("reveal-frames", nil): return .revealFrames
        case ("go-to", nil): return .goTo
        case ("hold-speed", nil): return .holdSpeed
        case ("show-keys", nil): return .showKeys
        case ("quit", _): return .quit
        case let ("plugin-action", name?): return args.count == 1 && PluginActions.isValidName(name) ? .pluginAction(name) : nil
        case ("ignore", nil): return .ignore
        default: return nil
        }
    }
}

/// Where a binding of the map comes from: the layout, the mouse profile's own lines, or one of the user's files.
public enum InputLayer: Equatable, Sendable {
    /// The classic layout, and the pointer lines every layout shares.
    case builtIn
    /// The left-hand layout's keys (its second keys included).
    case leftHand
    /// `MouseProfile.defaultConfig`.
    case profile(MouseProfile)
    /// input.conf.
    case file
    /// The user's `input-<profile>.conf`.
    case profileFile(MouseProfile)
}

/// Key bindings: a default layout (`key-layout`: left-hand, or the mpv-compatible classic one) plus
/// ~/.config/framescrub/input.conf overrides.
public struct InputMap: Equatable {
    public private(set) var bindings: [KeyChord: Command] = [:]
    /// The layer that bound each chord last.
    private var layers: [KeyChord: InputLayer] = [:]

    /// `key-layout=classic`: the mpv-style keys FrameScrub started with.
    public static let defaultConfig = """
    SPACE cycle pause
    p cycle pause
    MBTN_RIGHT cycle pause
    LEFT seek -5
    RIGHT seek 5
    UP seek 60
    DOWN seek -60
    Shift+LEFT seek -1 exact
    Shift+RIGHT seek 1 exact
    , frame-back-step
    . frame-step
    Ctrl+LEFT keyframe-back-step
    Ctrl+RIGHT keyframe-step
    Alt+LEFT keyframe-back-step
    Alt+RIGHT keyframe-step
    Shift+UP scene-step
    Shift+DOWN scene-back-step
    Shift+BS revert-seek
    TRACKPAD_LEFT scrub
    TRACKPAD_RIGHT scrub
    Shift+TRACKPAD_LEFT scrub fast
    Shift+TRACKPAD_RIGHT scrub fast
    TRACKPAD_UP add volume 2
    TRACKPAD_DOWN add volume -2
    Meta+TRACKPAD_UP zoom 0.25
    Meta+TRACKPAD_DOWN zoom -0.25
    PINCH_IN zoom
    PINCH_OUT zoom
    WHEEL_UP scrub
    WHEEL_DOWN scrub
    Alt+WHEEL_UP add volume 2
    Alt+WHEEL_DOWN add volume -2
    WHEEL_LEFT seek -10
    WHEEL_RIGHT seek 10
    Shift+WHEEL_LEFT scrub
    Shift+WHEEL_RIGHT scrub
    Shift+Alt+WHEEL_LEFT scrub fast
    Shift+Alt+WHEEL_RIGHT scrub fast
    Meta+WHEEL_UP zoom 0.25
    Meta+WHEEL_DOWN zoom -0.25
    [ step-speed down
    ] step-speed up
    BS set speed 1.0
    9 add volume -2
    0 add volume 2
    m cycle mute
    f cycle fullscreen
    MBTN_LEFT_DBL show-in-folder
    MBTN_MID cycle fullscreen
    MBTN_MID+WHEEL_UP add volume 5
    MBTN_MID+WHEEL_DOWN add volume -5
    MBTN_RIGHT+WHEEL_UP scrub fast
    MBTN_RIGHT+WHEEL_DOWN scrub fast
    MBTN_RIGHT+WHEEL_LEFT step-speed down
    MBTN_RIGHT+WHEEL_RIGHT step-speed up
    MBTN_RIGHT+TRACKPAD_UP scrub fast
    MBTN_RIGHT+TRACKPAD_DOWN scrub fast
    MBTN_RIGHT+TRACKPAD_LEFT scrub fast
    MBTN_RIGHT+TRACKPAD_RIGHT scrub fast
    MX_GESTURE+WHEEL_UP add volume 2
    MX_GESTURE+WHEEL_DOWN add volume -2
    MX_PANEL toggle-auto-color
    MX_PANEL_LONG toggle-vibrance
    MX_PANEL+WHEEL_UP add auto-color-strength 0.05
    MX_PANEL+WHEEL_DOWN add auto-color-strength -0.05
    MX_GESTURE screenshot
    MX_GESTURE_LONG save-clip
    MBTN_BACK mark-in
    MBTN_BACK_LONG mark-snap
    MBTN_BACK+WHEEL_UP scrub-edge start
    MBTN_BACK+WHEEL_DOWN scrub-edge start
    MBTN_FORWARD mark-out
    MBTN_FORWARD_LONG mark-delete
    MBTN_FORWARD+WHEEL_UP scrub-edge end
    MBTN_FORWARD+WHEEL_DOWN scrub-edge end
    T cycle ontop
    ESC set fullscreen no
    o show-progress
    i script-binding stats/display-stats
    l ab-loop
    L cycle-ab-loop-mode
    Alt+l toggle-segment-lock
    s screenshot
    S export-range
    C save-auto-color
    V save-vibrance
    Alt+c save-auto-color folder
    Alt+v save-vibrance folder
    Meta+C save-clip
    I mark-in
    O mark-out
    { mark-prev
    } mark-next
    k mark-snap
    M mark-loop
    x mark-delete
    X mark-clear
    P play-marks
    < playlist-prev
    > playlist-next
    PGUP playlist-prev
    PGDWN playlist-next
    F8 toggle-playlist
    F9 cycle-playlist-sort
    Meta+f playlist-filter
    Meta+BS delete-file
    Meta+w close-file
    ENTER show-in-folder
    Meta+UP show-in-folder
    u toggle-upscaler
    U cycle-upscaler
    v toggle-vibrance
    Alt+m toggle-scrub-audio
    Alt+M toggle-scrub-audio-pitch
    c toggle-auto-color
    a cycle-aspect
    Meta+1 set window-scale 0.5
    Meta+2 set window-scale 1
    Meta+3 set window-scale 2
    Meta+4 window-fit
    Meta+c copy-frame
    Meta+O reveal-frames
    Meta+g go-to
    / hold-speed
    ? show-keys
    Meta+= zoom 0.25
    Meta+- zoom -0.25
    Meta+0 zoom-reset
    q quit
    Ctrl+j shuttle-back
    Ctrl+k shuttle-stop
    Ctrl+l shuttle-forward
    """

    /// `key-layout=left-hand`: everything frequent under the left hand (pairs: the left key goes back, the right one
    /// forward), while the right hand stays on the mouse or TourBox.
    public static let leftHandConfig = """
    SPACE cycle pause
    q frame-back-step
    e frame-step
    Q keyframe-back-step
    E keyframe-step
    w hold-speed
    z seek -5
    c seek 5
    Z seek -60
    C seek 60
    Alt+z seek -1 exact
    Alt+c seek 1 exact
    Alt+Z scene-back-step
    Alt+C scene-step
    x revert-seek
    g go-to
    f ab-loop
    F cycle-ab-loop-mode
    Alt+F toggle-segment-lock
    r mark-in
    t mark-out
    R mark-prev
    T mark-next
    Alt+r mark-snap
    Alt+f mark-loop
    X mark-delete
    Alt+x mark-clear
    B play-marks
    b save-clip
    v screenshot
    V export-range
    Meta+c copy-frame
    Meta+O reveal-frames
    1 playlist-prev
    2 playlist-next
    3 step-speed down
    4 step-speed up
    5 set speed 1.0
    TAB toggle-playlist
    F9 cycle-playlist-sort
    Meta+f playlist-filter
    Meta+BS delete-file
    Meta+w close-file
    ENTER show-in-folder
    Meta+UP show-in-folder
    ` cycle fullscreen
    ESC set fullscreen no
    Meta+t cycle ontop
    Alt+a cycle-aspect
    Alt+v toggle-vibrance
    Alt+m toggle-scrub-audio
    Alt+M toggle-scrub-audio-pitch
    Alt+V toggle-auto-color
    u toggle-upscaler
    U cycle-upscaler
    9 add volume -2
    0 add volume 2
    m cycle mute
    i script-binding stats/display-stats
    o show-progress
    ? show-keys
    Meta+g go-to
    Meta+1 set window-scale 0.5
    Meta+2 set window-scale 1
    Meta+3 set window-scale 2
    Meta+4 window-fit
    Meta+= zoom 0.25
    Meta+- zoom -0.25
    Meta+0 zoom-reset
    a shuttle-back
    s shuttle-stop
    d shuttle-forward
    """

    /// The right-half keys of the classic layout kept in `left-hand` for when both hands are on the keyboard;
    /// key hints show them after the left-hand key.
    public static let leftHandSecondaryConfig = """
    LEFT seek -5
    RIGHT seek 5
    UP seek 60
    DOWN seek -60
    Shift+LEFT seek -1 exact
    Shift+RIGHT seek 1 exact
    Shift+UP scene-step
    Shift+DOWN scene-back-step
    Ctrl+LEFT keyframe-back-step
    Ctrl+RIGHT keyframe-step
    Alt+LEFT keyframe-back-step
    Alt+RIGHT keyframe-step
    , frame-back-step
    . frame-step
    / hold-speed
    Shift+BS revert-seek
    < playlist-prev
    > playlist-next
    PGUP playlist-prev
    PGDWN playlist-next
    [ step-speed down
    ] step-speed up
    BS set speed 1.0
    F8 toggle-playlist
    j shuttle-back
    k shuttle-stop
    l shuttle-forward
    """

    /// Mouse, wheel, trackpad and pinch lines of the classic layout: the same in every layout.
    public static var pointerConfig: String {
        defaultConfig.split(separator: "\n").filter { line in
            line.split(separator: " ").first.flatMap { KeyChord.parse(String($0)) }?.isPointer == true
        }.joined(separator: "\n")
    }

    /// Chords bound by a secondary text and not rebound since.
    private var secondary: Set<KeyChord> = []

    public init(layout: KeyLayout = .classic) {
        switch layout {
        case .classic:
            apply(Self.defaultConfig, source: "default", layer: .builtIn)
        case .leftHand:
            apply(Self.leftHandConfig, source: "left-hand", layer: .leftHand)
            apply(Self.leftHandSecondaryConfig, source: "left-hand", secondary: true, layer: .leftHand)
            apply(Self.pointerConfig, source: "default", layer: .builtIn)
        }
    }

    /// Whether `chord` is one of the layout's second keys for its command (shown after the main key).
    public func isSecondary(_ chord: KeyChord) -> Bool { secondary.contains(chord) }

    /// Applies `KEY command` lines on top of the current bindings; returns warnings. `secondary` marks the chords as
    /// second keys; any other apply that binds a chord unmarks it. `layer` is recorded for each chord bound.
    @discardableResult
    public mutating func apply(_ text: String, source: String = "input.conf", secondary: Bool = false,
                               layer: InputLayer = .file) -> [String] {
        var warnings: [String] = []
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(raw)
            guard !line.isEmpty else { continue }
            let location = "\(source):\(number + 1)"
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let chord = KeyChord.parse(String(parts[0])) else {
                warnings.append("\(location): cannot parse '\(line)'")
                continue
            }
            guard let command = Command.parse(String(parts[1])) else {
                warnings.append("\(location): unsupported command '\(parts[1])'")
                continue
            }
            bindings[chord] = command
            layers[chord] = layer
            if secondary { self.secondary.insert(chord) } else { self.secondary.remove(chord) }
        }
        return warnings
    }

    /// The layer that bound `chord` (an `ignore` included); nil for a chord nothing binds.
    public func layer(of chord: KeyChord) -> InputLayer? { layers[chord] }

    /// Every binding, `ignore` included, in the order of the chords' names.
    public var allBindings: [(chord: KeyChord, command: Command)] {
        bindings.map { (chord: $0.key, command: $0.value) }.sorted { $0.chord.description < $1.chord.description }
    }

    public func command(for chord: KeyChord) -> Command? {
        guard let command = bindings[chord], command != .ignore else { return nil }
        return command
    }

    public static func load(layout: KeyLayout) -> (InputMap, [String]) {
        var map = InputMap(layout: layout)
        let url = Config.directory.appendingPathComponent("input.conf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (map, []) }
        let warnings = map.apply(text)
        return (map, warnings)
    }
}

extension InputMap {
    /// Whether `button` has a binding under its own name: `""` the tap, `"_LONG"` the hold, `"_DBL"` the double tap
    /// (with any keyboard modifiers).
    public func binds(_ b: MouseButton, suffix: String = "") -> Bool {
        let name = b.rawValue + suffix
        return bindings.contains { $0.key.key == name && $0.value != .ignore }
    }

    /// Whether any binding needs `b` held down: a chord with its modifier.
    public func hasChords(heldWith b: MouseButton) -> Bool {
        guard let modifier = b.modifier else { return false }
        return bindings.contains { $0.key.modifiers.contains(modifier) && $0.value != .ignore }
    }

    /// The map with the page's action keys added where free: a chord with any binding (even `ignore`) refuses the page
    /// key (`key taken`), a name the map already binds keeps that key instead (`user binding`), and a ⌘ chord of a menu item
    /// is `key taken` too, and a mouse button, wheel, swipe or pinch is no key (`not a key`). Actions without a key are in neither list: only the user's bindings
    /// reach them.
    public func merging(_ actions: [PluginAction]) -> (map: InputMap, bound: [PluginBinding], refused: [PluginBinding]) {
        var map = self
        var bound: [PluginBinding] = [], refused: [PluginBinding] = []
        for action in actions {
            guard let key = action.key else { continue }
            if key.isPointerChord {
                refused.append(PluginBinding(name: action.name, key: key, reason: "not a key"))
            } else if bindings.values.contains(.pluginAction(action.name)) {
                refused.append(PluginBinding(name: action.name, key: key, reason: "user binding"))
            } else if map.bindings[key] != nil || KeyChord.menuOwned.contains(key) {
                refused.append(PluginBinding(name: action.name, key: key, reason: "key taken"))
            } else {
                map.bindings[key] = .pluginAction(action.name)
                bound.append(PluginBinding(name: action.name, key: key, reason: nil))
            }
        }
        return (map, bound, refused)
    }

    /// The control IDs of the Logitech buttons with any binding: those are taken over from macOS while bound.
    public var divertedCIDs: Set<UInt16> {
        Set(MouseButton.allCases.compactMap { button in
            guard let cid = button.cid else { return nil }
            let bound = ["", "_LONG", "_DBL"].contains { binds(button, suffix: $0) } || hasChords(heldWith: button)
            return bound ? cid : nil
        })
    }
}
