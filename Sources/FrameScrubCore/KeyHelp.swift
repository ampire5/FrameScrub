import Foundation

extension KeyChord {
    /// The key as macOS shows it: modifier glyphs in the system order (⌃⌥⇧⌘), arrows as arrows, a shifted letter as ⇧S
    /// (a lower-case letter stays lower-case, so `s` and `S` differ at a glance).
    public var displayName: String {
        let letter = key.count == 1 && key.lowercased() != key.uppercased()
        let shifted = modifiers.contains(.shift) || (letter && key != key.lowercased())   // "S" is Shift+s
        var glyphs = ""
        if modifiers.contains(.ctrl) { glyphs += "⌃" }
        if modifiers.contains(.alt) { glyphs += "⌥" }
        if shifted { glyphs += "⇧" }
        if modifiers.contains(.meta) { glyphs += "⌘" }
        let held = Self.heldNames.filter { modifiers.contains($0.modifier) }.map { $0.prefix }.joined()
        return held + glyphs + (Self.keyNames[key] ?? (letter && shifted ? key.uppercased() : key))
    }

    /// Mouse buttons, scrolls and pinches, as opposed to keys.
    public var isPointer: Bool {
        ["MBTN_", "MX_", "WHEEL_", "TRACKPAD_", "PINCH_"].contains { key.hasPrefix($0) }
    }

    private static let heldNames: [(modifier: Modifiers, prefix: String)] = [
        (.rightButton, "Right button + "), (.backButton, "Back + "), (.forwardButton, "Forward + "),
        (.midButton, "Middle + "), (.panelButton, "Panel + "), (.gestureButton, "Gesture button + "),
    ]

    private static let keyNames: [String: String] = [
        "LEFT": "←", "RIGHT": "→", "UP": "↑", "DOWN": "↓", "SPACE": "Space", "BS": "⌫", "DEL": "⌦", "ESC": "Esc",
        "ENTER": "↩", "TAB": "⇥", "HOME": "Home", "END": "End", "PGUP": "PgUp", "PGDWN": "PgDn",
        "MBTN_LEFT": "Click", "MBTN_LEFT_DBL": "Double click", "MBTN_RIGHT": "Right click", "MBTN_MID": "Middle click",
        "MBTN_MID_DBL": "Middle double click", "MBTN_BACK": "Back button", "MBTN_BACK_DBL": "Back button double click",
        "MBTN_FORWARD": "Forward button", "MBTN_FORWARD_DBL": "Forward button double click",
        "WHEEL_UP": "Wheel ↑", "WHEEL_DOWN": "Wheel ↓", "WHEEL_LEFT": "Side wheel left", "WHEEL_RIGHT": "Side wheel right",
        "MX_PANEL": "Panel", "MX_PANEL_LONG": "Panel (hold)", "MX_GESTURE": "Gesture button",
        "MX_GESTURE_LONG": "Gesture button (hold)", "MX_SHIFT": "Shift button",
        "MBTN_BACK_LONG": "Back (hold)", "MBTN_FORWARD_LONG": "Forward (hold)",
        "TRACKPAD_UP": "Swipe ↑", "TRACKPAD_DOWN": "Swipe ↓", "TRACKPAD_LEFT": "Swipe ←", "TRACKPAD_RIGHT": "Swipe →",
        "PINCH_IN": "Pinch in", "PINCH_OUT": "Pinch out",
    ]
}

/// The key cheat sheet (`?`) and the key hints in the menus, built from the bindings in effect.
public enum KeyHelp {
    public enum Section: Int, CaseIterable, Sendable {
        case playback, frames, navigation, saving, picture, window, audio
        /// The plugin page's declared actions (`PluginAction`), titled by the page's labels.
        case plugin

        public var title: String {
            switch self {
            case .playback: "Playback"
            case .frames: "Frames"
            case .navigation: "Seeking"
            case .saving: "Saving"
            case .picture: "Picture"
            case .window: "Window"
            case .audio: "Sound"
            case .plugin: "Plugin"
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let keys: [String]
        public let action: String
    }

    /// Where a command goes in the cheat sheet and what it is called there; nil leaves it out.
    static func describe(_ command: Command) -> (section: Section, rank: Int, action: String)? {
        func seconds(_ amount: Double) -> String { "\(amount < 0 ? "−" : "+")\(formatNumber(abs(amount))) s" }
        switch command {
        case .cyclePause: return (.playback, 0, "Play / pause")
        case .holdSpeed: return (.playback, 1, "Hold: play faster")
        case let .multiplySpeed(factor): return (.playback, factor < 1 ? 2 : 3, factor < 1 ? "Slower" : "Faster")
        case let .stepSpeed(direction): return (.playback, direction < 0 ? 2 : 3, direction < 0 ? "Slower" : "Faster")
        case let .setSpeed(value): return (.playback, 4, value == 1 ? "Normal speed (1×)" : "Speed ×\(formatNumber(value))")
        case .abLoop: return (.playback, 5, "A-B range: start, end, clear")
        case .cycleABLoopMode: return (.playback, 6, "At B: loop, pause or turn back")
        case .toggleSegmentLock: return (.playback, 7, "Segments: lock / unlock")
        case .shuttleBack: return (.playback, 8, "Shuttle back")
        case .shuttleStop: return (.playback, 9, "Stop")
        case .shuttleForward: return (.playback, 10, "Shuttle forward")
        case .frameBackStep: return (.frames, 0, "Previous frame")
        case .frameStep: return (.frames, 1, "Next frame")
        case let .scrub(fast, _): return (.frames, fast ? 3 : 2, fast ? "Fast scrubbing" : "Step frames")
        case .keyframeBackStep: return (.frames, 4, "Previous keyframe")
        case .keyframeStep: return (.frames, 5, "Next keyframe")
        case let .seek(amount, precision):
            return (.navigation, 10_000 + Int(amount * 10), "Seek \(seconds(amount))" + (precision == .exact ? " exactly" : ""))
        case .revertSeek: return (.navigation, 100_000, "Back to before the last seek")
        case .goTo: return (.navigation, 100_001, "Go to time or frame")
        case .sceneBackStep: return (.navigation, 100_002, "Previous scene (or start of this one)")
        case .sceneStep: return (.navigation, 100_003, "Next scene")
        case .playlistPrev: return (.navigation, 100_004, "Previous video in the folder")
        case .playlistNext: return (.navigation, 100_005, "Next video in the folder")
        case .screenshot: return (.saving, 0, "Save frame")
        case .copyFrame: return (.saving, 1, "Copy frame")
        case .exportRange: return (.saving, 2, "Export the A-B range")
        case .revealFrames: return (.saving, 3, "Show saved frames in Finder")
        case .markIn: return (.saving, 10, "Mark in")
        case .markOut: return (.saving, 11, "Mark out")
        case .markPrev: return (.saving, 12, "Previous mark edge")
        case .markNext: return (.saving, 13, "Next mark edge")
        case .markSnap: return (.saving, 14, "Mark start to the nearest keyframe")
        case .markLoop: return (.saving, 15, "Add the A-B loop as a mark")
        case .markDelete: return (.saving, 16, "Delete the mark here")
        case .markClear: return (.saving, 17, "Delete all marks")
        case .playMarks: return (.saving, 18, "Play only the marks")
        case .saveClip: return (.saving, 19, "Save the marks as clips")
        case .toggleVibrance: return (.picture, 0, "Vibrance on/off (this file)")
        case .toggleAutoColor: return (.picture, 1, "Auto colour on/off (this file)")
        case let .saveAutoColor(folder): return (.picture, folder ? 8 : 7, folder ? "Save auto colour for the folder" : "Save auto colour as default")
        case let .saveVibrance(folder): return (.picture, folder ? 10 : 9, folder ? "Save vibrance for the folder" : "Save vibrance as default")
        case let .resetColor(level): return (.picture, level == .file ? 11 : 12, level == .file ? "Reset file colour" : "Reset folder colour")
        case .toggleUpscaler: return (.picture, 2, "Still-frame upscaling on / off")
        case .cycleUpscaler: return (.picture, 3, "Upscaler for saved frames")
        case .cycleAspect: return (.picture, 4, "Aspect: auto, no crop, 16:9, 4:3, 2.35:1, square pixels")
        case .cycleFullscreen: return (.window, 0, "Full screen")
        case .setFullscreen(false): return (.window, 1, "Leave full screen")
        case let .windowScale(scale): return (.window, 2 + Int(scale * 10), "Window \(formatNumber(scale * 100)) %")
        case .windowFit: return (.window, 100, "Window: fit to screen")
        case .cycleOntop: return (.window, 101, "Float on top")
        case .togglePlaylist: return (.window, 102, "Playlist")
        case .playlistFilter: return (.navigation, 100_006, "Find in the folder")
        case .cyclePlaylistSort: return (.navigation, 100_007, "Folder order: name, date, size")
        case .deleteFile: return (.navigation, 100_008, "Move the video to the Trash")
        case .showProgress: return (.window, 103, "Progress")
        case .stats: return (.window, 104, "Stats")
        case .showKeys: return (.window, 105, "These keys")
        case .closeFile: return (.window, 106, "Close the video: back to Recent or Stash")
        case .quit: return (.window, 107, "Quit")
        case let .addVolume(delta): return (.audio, delta < 0 ? 0 : 1, delta < 0 ? "Volume down" : "Volume up")
        case let .addAutoColorStrength(delta):
            return (.picture, delta < 0 ? 5 : 6, "Auto colour strength \(delta < 0 ? "−" : "+")\(formatNumber(abs(delta)))")
        case let .scrubEdge(edge): return (.saving, edge == .start ? 20 : 21, edge == .start ? "Drag the mark start" : "Drag the mark end")
        case .cycleMute: return (.audio, 2, "Mute")
        case .toggleScrubAudio: return (.audio, 3, "Scrub audio on / off")
        case .toggleScrubAudioPitch: return (.audio, 4, "Scrub pitch: tape / natural")
        case .setFullscreen(true), .zoom, .zoomReset, .ignore: return nil   // zoom is bound but not available yet
        case .pluginAction: return nil   // the plugin section lists them under the page's labels
        }
    }

    /// The bound commands by section, each with all its keys (keys first, then mouse and trackpad); last the plugin
    /// page's declared `actions` in their order, each with the keys bound to it (none when nothing reaches it).
    public static func sections(for map: InputMap, plugin actions: [PluginAction] = []) -> [(section: Section, entries: [Entry])] {
        var grouped: [String: (section: Section, rank: Int, chords: [KeyChord])] = [:]
        for (chord, command) in map.bindings {
            guard let (section, rank, action) = describe(command) else { continue }
            grouped[action, default: (section, rank, [])].chords.append(chord)
        }
        let plugin = actions.map { action in
            Entry(keys: condensed(map.bindings.filter { $0.value == .pluginAction(action.name) }.keys
                    .sorted { order($0, $1, in: map) }.map(\.displayName)),
                  action: action.label)
        }
        return Section.allCases.compactMap { section in
            if section == .plugin { return plugin.isEmpty ? nil : (section, plugin) }
            let entries = grouped.filter { $0.value.section == section }
                .sorted { ($0.value.rank, $0.key) < ($1.value.rank, $1.key) }
                .map { Entry(keys: condensed($0.value.chords.sorted { order($0, $1, in: map) }.map(\.displayName)),
                             action: $0.key) }
            return entries.isEmpty ? nil : (section, entries)
        }
    }

    /// At most `limit` names, with "Swipe ←" and "Swipe →" shown as "Swipe ←→" (and "Wheel ↓", "Wheel ↑" as "Wheel ↑↓").
    static func condensed(_ names: [String], limit: Int = 3) -> [String] {
        var result: [String] = []
        for name in names {
            if let last = result.last, last.count == name.count, last.dropLast() == name.dropLast(),
               let a = last.last, let b = name.last, "←↑".contains(a), "→↓".contains(b) {
                result[result.count - 1] = last + String(b)
            } else if let last = result.last, last.count == name.count, last.dropLast() == name.dropLast(),
                      last.last == "↓", name.last == "↑" {      // "Wheel ↓" sorts before "Wheel ↑"
                result[result.count - 1] = name + "↓"
            } else {
                result.append(name)
            }
        }
        return Array(result.prefix(limit))
    }

    /// The key to show next to a menu item: a keyboard key bound to `command`, preferring one without modifiers.
    public static func menuHint(for command: Command, in map: InputMap) -> String? {
        map.bindings.filter { $0.value == command && !$0.key.isPointer }.keys
            .sorted { order($0, $1, in: map) }.first?.displayName
    }

    /// Keys before mouse and trackpad, the layout's main keys before its second ones (left-hand: `c` before →), then
    /// by modifiers (none, ⇧, ⌥, ⌘, ⌃: ⌃-arrows are often taken by Spaces), named keys (Space, PgUp) before
    /// characters, then by name: a stable order for equal maps.
    private static func order(_ a: KeyChord, _ b: KeyChord, in map: InputMap) -> Bool {
        func weight(_ m: Modifiers) -> Int {
            (m.contains(.shift) ? 1 : 0) + (m.contains(.alt) ? 2 : 0) + (m.contains(.meta) ? 4 : 0) + (m.contains(.ctrl) ? 8 : 0)
        }
        func key(_ c: KeyChord) -> (Int, Int, Int, Int, String) {
            (c.isPointer ? 1 : 0, map.isSecondary(c) ? 1 : 0, weight(c.modifiers), c.key.count > 1 ? 0 : 1, c.key)
        }
        return key(a) < key(b)
    }
}
