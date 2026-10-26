import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct MouseProfileTests {
    private func command(_ map: InputMap, _ key: String) -> Command? { map.command(for: KeyChord(key: key)) }

    @Test func twoProfilesInTurn() {
        #expect(MouseProfile.allCases == [.viewing, .editing])
        #expect(MouseProfile.viewing.next == .editing && MouseProfile.editing.next == .viewing)
        #expect(MouseProfile.viewing.title == "Viewing" && MouseProfile.editing.title == "Editing")
        #expect(MouseProfile.editing.fileName == "input-editing.conf")
    }

    /// Viewing is the bindings as they were; Editing puts play, frames, clips and marks under the buttons.
    @Test func editingPutsTheEditorsCommandsUnderTheButtons() {
        let viewing = InputMap.build(layout: .classic, profile: .viewing)
        #expect(command(viewing, "MX_GESTURE") == .screenshot && command(viewing, "MX_PANEL") == .toggleAutoColor)
        let editing = InputMap.build(layout: .classic, profile: .editing)
        #expect(command(editing, "MX_GESTURE") == .cyclePause)
        #expect(command(editing, "MX_GESTURE_LONG") == .saveClip)
        #expect(command(editing, "MX_PANEL") == .screenshot)
        #expect(command(editing, "MX_PANEL_LONG") == .exportRange)
        #expect(command(editing, "MBTN_MID") == .playMarks)
        #expect(command(editing, "MBTN_BACK") == .markIn && command(editing, "MBTN_FORWARD") == .markOut)
        #expect(command(editing, "m") == .cycleMute)   // the keys are the same in both
    }

    /// input.conf, then the profile's own lines, then the user's input-<profile>.conf.
    @Test func theUsersProfileFileWins() {
        let user = "MX_GESTURE cycle mute\nMBTN_MID cycle fullscreen"
        let mine = "MX_PANEL mark-loop"
        let editing = InputMap.build(layout: .classic, userText: user, profile: .editing, profileText: mine)
        #expect(command(editing, "MX_GESTURE") == .cyclePause)   // the profile is on top of input.conf
        #expect(command(editing, "MX_PANEL") == .markLoop)       // and the user's profile file on top of it
        let viewing = InputMap.build(layout: .classic, userText: user, profile: .viewing, profileText: "")
        #expect(command(viewing, "MX_GESTURE") == .cycleMute && command(viewing, "MBTN_MID") == .cycleFullscreen)
    }

    @Test func aCommandSwitchesIt() {
        #expect(Command.parse("cycle-mouse-profile") == .cycleMouseProfile)
        #expect(Command.cycleMouseProfile.configText == "cycle-mouse-profile")
    }

    @Test func configRemembersIt() {
        #expect(Config().mouseProfile == .viewing)
        let (c, warnings) = Config.parse("mouse-profile=editing")
        #expect(warnings.isEmpty && c.mouseProfile == .editing)
        #expect(c.text(forKey: "mouse-profile") == "editing")
        #expect(Config.parse("mouse-profile=gaming").0.mouseProfile == .viewing)
        #expect(Config.keys.contains("mouse-profile"))
    }

    /// The SmartShift button pressed twice in a row (two wheel mode changes by the button) switches the profile; a
    /// single press stays the wheel's own.
    @Test func aDoublePressIsTwoPressesClose() {
        var presses = DoublePress(window: 0.6)
        let answers = [10.0, 10.4, 10.5, 20.0, 20.7].map { presses.press(at: $0) }
        // the second press of a pair says so; a third starts again; presses too far apart are no pair
        #expect(answers == [false, true, false, false, false])
    }

    @Test func thePreferencesFollowTheProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "MX_PANEL mark-loop".write(to: dir.appendingPathComponent("input-editing.conf"), atomically: true, encoding: .utf8)
        let prefs = GesturePreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic)
        nonisolated(unsafe) var told: InputMap?
        prefs.addObserver { told = $0 }
        prefs.profile = .editing
        let map = try #require(told)
        #expect(command(map, "MX_PANEL") == .markLoop)
        #expect(command(map, "MX_GESTURE") == .cyclePause)
    }
}
