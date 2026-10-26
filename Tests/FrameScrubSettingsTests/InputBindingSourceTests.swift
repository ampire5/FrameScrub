import AppKit
import Foundation
import SettingsKit
import Testing
@testable import FrameScrubCore
@testable import FrameScrubSettings

/// The Key Bindings tables' source: the keys and buttons of the live map with where each comes from, and edits written
/// to the file that would otherwise hide them (input.conf, or the profile's own file).
@MainActor @Suite(.serialized) struct InputBindingSourceTests {
    @MainActor private struct Setup {
        let dir: URL
        let preferences: InputPreferences
        let source: InputBindingSource
        func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        func row(_ id: String) -> KeyBindingRowModel? { source.rows().first { $0.id == id } }
    }

    private func setup(input: String? = nil, viewing: String? = nil, profile: MouseProfile = .viewing) throws -> Setup {
        let dir = makeTemporaryDirectory()
        if let input { try input.write(to: dir.appendingPathComponent("input.conf"), atomically: true, encoding: .utf8) }
        if let viewing {
            try viewing.write(to: dir.appendingPathComponent("input-viewing.conf"), atomically: true, encoding: .utf8)
        }
        let preferences = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic, profile: profile)
        return Setup(dir: dir, preferences: preferences,
                     source: InputBindingSource(preferences: preferences, translateKey: { _, _ in nil }))
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    @Test func rowsCarryTheirSource() throws {
        let s = try setup(input: "F13 cycle pause\nSPACE ignore\n", viewing: "MBTN_FORWARD frame-step\n")
        #expect(s.row("F13")?.source == "input.conf")
        #expect(s.row("F13")?.actionID == "cycle pause")
        #expect(s.row("F13")?.canRestore == true)
        #expect(s.row("SPACE")?.source == "off")
        #expect(s.row("SPACE")?.actionID == nil)
        #expect(s.row("SPACE")?.canRemove == false)
        #expect(s.row("MBTN_MID")?.source == "built-in")
        #expect(s.row("MBTN_MID")?.isMouse == true)
        #expect(s.row("MBTN_MID")?.canRestore == false)
        #expect(s.row("MBTN_BACK")?.source == "viewing profile")
        #expect(s.row("MBTN_FORWARD")?.source == "input-viewing.conf")
        #expect(s.row("RIGHT")?.actionID == "seek")
        #expect(s.row("RIGHT")?.step == 5)
        #expect(s.row("RIGHT")?.action == "Seek +5 s")
        #expect(s.row("RIGHT")?.input == "→")
        #expect(s.row("RIGHT")?.isMouse == false)
    }

    @Test func gestureAxesAreNotRows() throws {
        let s = try setup()
        let gestures = Set(GestureBinding.bindings(in: s.preferences.inputMap).flatMap { [$0.chords.0, $0.chords.1] })
        #expect(!gestures.isEmpty)
        for row in s.source.rows() { #expect(!gestures.contains { $0.description == row.id }, "\(row.id)") }
    }

    @Test func aProfileChordIsWrittenToTheProfileFile() throws {
        let s = try setup()
        try s.source.bind(input: "MBTN_BACK", action: "cycle pause", step: nil)
        #expect(s.text("input-viewing.conf") == "MBTN_BACK cycle pause\n")
        #expect(s.text("input.conf") == nil)
        #expect(s.preferences.inputMap.command(for: KeyChord(key: "MBTN_BACK")) == .cyclePause)
        #expect(s.row("MBTN_BACK")?.source == "input-viewing.conf")
    }

    @Test func aKeyIsWrittenToInputConf() throws {
        let s = try setup()
        try s.source.bind(input: "F13", action: "frame-step", step: nil)
        try s.source.bind(input: "F14", action: "seek exact", step: -3)
        #expect(s.text("input.conf") == "F13 frame-step\nF14 seek -3 exact\n")
        #expect(s.text("input-viewing.conf") == nil)
        #expect(s.row("F14")?.step == -3)
    }

    @Test func removeABuiltInWritesIgnore() throws {
        let s = try setup()
        try s.source.remove(rowID: "SPACE")
        #expect(s.text("input.conf") == "SPACE ignore\n")
        #expect(s.row("SPACE")?.source == "off")
    }

    @Test func removeAProfileBindingWritesIgnoreInTheProfileFile() throws {
        let s = try setup()
        try s.source.remove(rowID: "MBTN_BACK")
        #expect(s.text("input-viewing.conf") == "MBTN_BACK ignore\n")
        #expect(s.row("MBTN_BACK")?.source == "off")
    }

    @Test func removeAFileLineCommentsItOut() throws {
        let s = try setup(input: "SPACE frame-step\n")
        try s.source.remove(rowID: "SPACE")
        #expect(s.text("input.conf") == "# SPACE frame-step\n")
        #expect(s.row("SPACE")?.source == "built-in")
        #expect(s.row("SPACE")?.actionID == "cycle pause")
    }

    @Test func restoreBuiltInCommentsOutTheLine() throws {
        let s = try setup(viewing: "MBTN_BACK cycle pause\n")
        try s.source.restoreBuiltIn(rowID: "MBTN_BACK")
        #expect(s.text("input-viewing.conf") == "# MBTN_BACK cycle pause\n")
        #expect(s.row("MBTN_BACK")?.source == "viewing profile")
    }

    @Test func menuChordsAreRefused() throws {
        let s = try setup()
        #expect(s.source.keyToken(for: key(",", code: 43, .command)) == .failure(KeyBindingRefusal("Belongs to a menu item")))
        #expect(s.source.keyToken(for: key("g", code: 5)) == .success("g"))
        #expect(s.source.keyToken(for: key("G", code: 5, .shift)) == .success("G"))
        #expect(s.source.keyToken(for: key("", code: 124, .shift)) == .success("Shift+RIGHT"))
    }

    @Test func stepRules() throws {
        let s = try setup()
        #expect(s.source.stepRule(for: "seek") == KeyBindingStep(range: 0.01...3600, defaultValue: 5, signed: true))
        #expect(s.source.stepRule(for: "add volume") == KeyBindingStep(range: 0.1...100, defaultValue: 2, signed: true))
        #expect(s.source.stepRule(for: "set window-scale").signed == false)
        #expect(s.source.stepRule(for: "add auto-color-strength") == .standard)
    }

    @Test func everyActionParses() throws {
        let s = try setup()
        for group in s.source.actionGroups() {
            #expect(!group.actions.isEmpty, "\(group.group)")
            for action in group.actions {
                let step = action.takesStep ? s.source.stepRule(for: action.id).defaultValue : nil
                let command = try #require(InputBindingSource.command(action.id, step: step), "\(action.id)")
                #expect(InputBindingSource.actionID(of: command) == action.id)
                #expect(action.title != action.id || action.id.hasPrefix("plugin-action"), "\(action.id) has no title")
            }
        }
    }

    @Test func conflictNamesTheActionNow() throws {
        let s = try setup(input: "SPACE ignore\n")
        #expect(s.source.conflict(input: "RIGHT") == "Seek +5 s")
        #expect(s.source.conflict(input: "SPACE") == nil)
        #expect(s.source.conflict(input: "F13") == nil)
    }

    @Test func aProfileSwitchMovesTheSources() throws {
        let s = try setup()
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: s.source,
                                                           queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        s.preferences.profile = .editing
        #expect(s.row("MBTN_BACK")?.source == "built-in")
        #expect(posted == 1)
        #expect(s.source.profileNote == "Profile: Editing. Buttons the profile sets are written to input-editing.conf.")
    }

    @Test func aFailedWriteThrows() throws {
        let blocker = makeTemporaryDirectory().appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)          // a file where a directory is needed
        let preferences = InputPreferences(url: blocker.appendingPathComponent("sub/input.conf"), layout: .classic,
                                           profile: .viewing)
        let source = InputBindingSource(preferences: preferences, translateKey: { _, _ in nil })
        #expect(throws: (any Error).self) { try source.bind(input: "F13", action: "frame-step", step: nil) }
    }

    @Test func menuRowsAreReadOnly() throws {
        let dir = makeTemporaryDirectory()
        let preferences = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic)
        let source = InputBindingSource(preferences: preferences, translateKey: { _, _ in nil },
                                        menuRows: { [(input: "⌘O", title: "Open…")] })
        let menu = try #require(source.rows().first { $0.input == "⌘O" })
        #expect(!menu.isEditable && !menu.canRemove && menu.source == "menu")
        #expect(source.searchTexts(mouse: false).contains("Open…"))
        #expect(source.searchTexts(mouse: false).contains("Play / pause"))
        #expect(!source.searchTexts(mouse: true).contains("Open…"))
    }
}
