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

    private func chord(_ map: InputMap, _ text: String) -> Command? { map.command(for: KeyChord.parse(text)!) }

    /// Editing is the layout's buttons as they always were: marks and their edges under back and forward.
    @Test func editingIsTheLayoutsButtons() {
        let editing = InputMap.build(layout: .classic, profile: .editing)
        #expect(command(editing, "MX_GESTURE") == .screenshot && command(editing, "MX_GESTURE_LONG") == .saveClip)
        #expect(command(editing, "MX_PANEL") == .toggleAutoColor && command(editing, "MX_PANEL_LONG") == .toggleVibrance)
        #expect(command(editing, "MBTN_MID") == .cycleFullscreen)
        #expect(command(editing, "MBTN_BACK") == .markIn && command(editing, "MBTN_BACK_LONG") == .markSnap)
        #expect(chord(editing, "MBTN_BACK+WHEEL_UP") == .scrubEdge(.start))
        #expect(command(editing, "MBTN_FORWARD") == .markOut && command(editing, "MBTN_FORWARD_LONG") == .markDelete)
        #expect(chord(editing, "MBTN_FORWARD+WHEEL_DOWN") == .scrubEdge(.end))
        #expect(editing.command(for: KeyChord(key: "m")) == .cycleMute)   // the keys are the same in both
    }

    /// Viewing (the default) is the same, but back and forward leave the marks: back shows the file's info, forward does
    /// nothing for now.
    @Test func viewingLeavesTheMarksAlone() {
        let viewing = InputMap.build(layout: .classic, profile: .viewing)
        #expect(command(viewing, "MX_GESTURE") == .screenshot && command(viewing, "MX_GESTURE_LONG") == .saveClip)
        #expect(command(viewing, "MX_PANEL") == .toggleAutoColor && command(viewing, "MX_PANEL_LONG") == .toggleVibrance)
        #expect(command(viewing, "MBTN_MID") == .cycleFullscreen)
        #expect(command(viewing, "MBTN_BACK") == .stats)
        for gone in ["MBTN_BACK_LONG", "MBTN_FORWARD", "MBTN_FORWARD_LONG"] { #expect(command(viewing, gone) == nil, "\(gone)") }
        for gone in ["MBTN_BACK+WHEEL_UP", "MBTN_BACK+WHEEL_DOWN", "MBTN_FORWARD+WHEEL_UP", "MBTN_FORWARD+WHEEL_DOWN"] {
            #expect(chord(viewing, gone) == nil, "\(gone)")
        }
    }

    /// input.conf, then the profile's own lines, then the user's input-<profile>.conf.
    @Test func theUsersProfileFileWins() {
        let user = "MBTN_BACK cycle mute\nMBTN_MID cycle pause"
        let viewing = InputMap.build(layout: .classic, userText: user, profile: .viewing, profileText: "MX_PANEL mark-loop")
        #expect(command(viewing, "MBTN_BACK") == .stats)       // the profile is on top of input.conf
        #expect(command(viewing, "MBTN_MID") == .cyclePause)   // what it leaves is input.conf's
        #expect(command(viewing, "MX_PANEL") == .markLoop)     // and the user's profile file is on top of it
        let editing = InputMap.build(layout: .classic, userText: user, profile: .editing, profileText: "")
        #expect(command(editing, "MBTN_BACK") == .cycleMute)
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

    /// The SmartShift button, taken over while FrameScrub sets the wheel: a short press switches the wheel as the mouse
    /// would; held 0.6 s it switches the profile, once, at the threshold (the click is felt then), and its release then
    /// leaves the wheel alone.
    @Test func aShortPressIsTheWheelsALongOneTheProfile() {
        var p = SmartShiftPress(threshold: 0.6)
        p.press(at: 10)
        #expect(p.tick(at: 10.3) == .none)
        #expect(p.release(at: 10.15 + 0.2) == .short)
        p.press(at: 20)
        #expect(p.tick(at: 20.59) == .none)
        #expect(p.tick(at: 20.6) == .long)
        #expect(p.tick(at: 20.7) == .none)   // once
        #expect(p.release(at: 21.5) == .none)   // the wheel stays as it was
        p.press(at: 30)
        #expect(p.release(at: 30.8) == .long)   // the tick came late: the release says it
        #expect(p.release(at: 31) == .none)     // a release without a press
    }

    @Test func aCancelledPressDoesNothing() {
        var p = SmartShiftPress()
        p.press(at: 1)
        p.cancel()   // FrameScrub went to the background with the button down
        #expect(p.tick(at: 5) == .none && p.release(at: 5) == .none)
    }

    @Test func thePreferencesFollowTheProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "MX_PANEL mark-loop".write(to: dir.appendingPathComponent("input-editing.conf"), atomically: true, encoding: .utf8)
        let prefs = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic)
        nonisolated(unsafe) var told: InputMap?
        prefs.addObserver { told = $0 }
        prefs.profile = .editing
        let map = try #require(told)
        #expect(command(map, "MX_PANEL") == .markLoop)
        #expect(command(map, "MBTN_BACK") == .markIn)
    }
}
