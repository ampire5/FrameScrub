import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct GestureBindingsTests {
    private func binding(_ device: GestureDevice, _ axis: GestureAxis, _ modifiers: Modifiers = [],
                         _ action: GestureActionKind, invert: Bool = false) -> GestureBinding {
        GestureBinding(device: device, axis: axis, modifiers: modifiers, action: action, invert: invert)
    }

    @Test func signedActionsWriteOneLinePerSide() {
        let b = binding(.trackpad, .vertical, [.shift], .seek(5, .keyframes))
        #expect(b.lines.map { "\($0.chord) \($0.command)" } == ["Shift+TRACKPAD_UP seek 5 keyframes", "Shift+TRACKPAD_DOWN seek -5 keyframes"])
        let inverted = binding(.wheel, .vertical, [], .volume(2), invert: true)
        #expect(inverted.lines.map { "\($0.chord) \($0.command)" } == ["WHEEL_UP add volume -2", "WHEEL_DOWN add volume 2"])
    }

    @Test func scrubAndIgnoreRepeatOnBothSides() {
        #expect(binding(.trackpad, .horizontal, [.shift], .scrubFast, invert: true).lines.map(\.command) == ["scrub fast invert", "scrub fast invert"])
        #expect(binding(.wheel, .horizontal, [], .ignore).lines.map(\.command) == ["ignore", "ignore"])
    }

    @Test func speedAndPlaylistAndPinch() {
        let speed = binding(.wheel, .vertical, [.alt], .speed(1.1))
        #expect(speed.commands.0 == .multiplySpeed(1.1))
        if case let .multiplySpeed(f) = speed.commands.1 { #expect(abs(f - 1 / 1.1) < 1e-12) } else { Issue.record("not a speed command") }
        #expect(binding(.trackpad, .horizontal, [], .playlist).commands == (.playlistNext, .playlistPrev))
        #expect(binding(.pinch, .horizontal, [], .zoomContinuous).lines.map { "\($0.chord)" } == ["PINCH_OUT", "PINCH_IN"])
    }

    @Test func speedStepAndTheRightButtonModifierWriteTheirLines() {
        let b = binding(.wheel, .horizontal, [.rightButton], .speedStep, invert: true)
        #expect(b.lines.map { "\($0.chord) \($0.command)" }
                == ["MBTN_RIGHT+WHEEL_LEFT step-speed down", "MBTN_RIGHT+WHEEL_RIGHT step-speed up"])
    }

    @Test func rightButtonRowsComeFromTheDefaults() {
        let rows = GestureBinding.bindings(in: InputMap())
        #expect(rows.contains(binding(.wheel, .vertical, [.rightButton], .scrubFast)))
        #expect(rows.contains(binding(.wheel, .horizontal, [.rightButton], .speedStep, invert: true)))
        for device in [GestureDevice.trackpad] {
            for axis in [GestureAxis.horizontal, .vertical] {
                #expect(rows.contains(binding(device, axis, [.rightButton], .scrubFast)), "\(device) \(axis)")
            }
        }
    }

    @Test func heldButtonChordsAreNotTableRows() {
        for layout in [KeyLayout.classic, .leftHand] {
            let rows = GestureBinding.bindings(in: InputMap(layout: layout))
            #expect(!rows.isEmpty)
            #expect(rows.allSatisfy { $0.modifiers.isDisjoint(with: .heldButtons) }, "\(layout)")
            #expect(rows.contains(binding(.wheel, .vertical, [.alt], .volume(2))))
            #expect(rows.contains(binding(.wheel, .vertical, [], .scrub)))
        }
        var map = InputMap()
        map.apply("MX_PANEL+WHEEL_UP seek 5\nMX_PANEL+WHEEL_DOWN seek -5\nMBTN_BACK+Shift+TRACKPAD_UP ignore\nMBTN_BACK+Shift+TRACKPAD_DOWN ignore")
        #expect(GestureBinding.bindings(in: map).allSatisfy { $0.modifiers.isDisjoint(with: .heldButtons) })
    }

    @Test func everyKindRoundTripsThroughItsCommands() {
        let kinds: [GestureActionKind] = [.scrub, .scrubFast, .seek(5, .byConfig), .seek(1, .exact), .seek(60, .keyframes),
                                          .volume(2), .speed(1.1), .speedStep, .playlist, .zoom(0.25), .zoomContinuous, .ignore]
        for kind in kinds {
            for invert in [false, true] {
                let original = binding(.wheel, .vertical, [.meta], kind, invert: invert)
                if (kind == .ignore || kind == .zoomContinuous) && invert { continue }    // no direction to invert
                let decoded = GestureBinding.decode(device: .wheel, axis: .vertical, modifiers: [.meta],
                                                    primary: original.commands.0, secondary: original.commands.1)
                #expect(decoded == original, "\(kind) invert=\(invert)")
            }
        }
    }

    @Test func asymmetricPairsAreNotDecodable() {
        #expect(GestureBinding.decode(device: .wheel, axis: .vertical, modifiers: [], primary: .addVolume(2), secondary: .addVolume(-3)) == nil)
        #expect(GestureBinding.decode(device: .wheel, axis: .vertical, modifiers: [], primary: .cyclePause, secondary: .cyclePause) == nil)
    }

    @Test func theDefaultMapDecodesToTheSpecTable() {
        let rows = GestureBinding.bindings(in: InputMap())
        func has(_ b: GestureBinding) -> Bool { rows.contains(b) }
        #expect(has(binding(.trackpad, .horizontal, [], .scrub)))
        #expect(has(binding(.trackpad, .horizontal, [.shift], .scrubFast)))
        #expect(has(binding(.trackpad, .vertical, [], .volume(2))))
        #expect(has(binding(.trackpad, .vertical, [.meta], .zoom(0.25))))
        #expect(has(binding(.pinch, .horizontal, [], .zoomContinuous)))
        #expect(has(binding(.wheel, .vertical, [], .scrub)))
        #expect(has(binding(.wheel, .vertical, [.alt], .volume(2))))
        #expect(has(binding(.wheel, .horizontal, [], .seek(10, .byConfig), invert: true)))
        #expect(has(binding(.wheel, .horizontal, [.shift], .scrub)))
        #expect(has(binding(.wheel, .horizontal, [.shift, .alt], .scrubFast)))
        #expect(has(binding(.wheel, .vertical, [.meta], .zoom(0.25))))
        #expect(rows.count == 15)   // including the right button + scroll rows (wheel and trackpad, both axes)
    }

    @Test func rowsCoverEveryGestureLineOfTheDefaults() {
        let rows = GestureBinding.bindings(in: InputMap())
        let chords = Set(rows.flatMap { $0.lines.map(\.chord) })
        let gestureChords = Set(InputMap().bindings.keys.filter { GestureBindingEditor.isGestureChord($0) })
        #expect(chords == gestureChords)
    }

    @Test func settingARowRewritesItsLinesInPlace() {
        let text = "SPACE cycle pause\nshift+trackpad_up add volume 2 # mine\n"
        let out = GestureBindingEditor.setting(binding(.trackpad, .vertical, [.shift], .seek(5, .byConfig)), in: text)
        #expect(out == "SPACE cycle pause\nShift+TRACKPAD_UP seek 5 # mine\nShift+TRACKPAD_DOWN seek -5\n")
    }

    @Test func resettingRemovesOnlyGestureLines() {
        let text = "SPACE cycle pause\nTRACKPAD_UP seek 5\nWHEEL_LEFT ignore\nPINCH_IN zoom\nq quit\n"
        #expect(GestureBindingEditor.resetting(text) == "SPACE cycle pause\nq quit\n")
    }

    @Test func resettingKeepsLinesWithAHeldButton() {
        let text = "MX_PANEL+WHEEL_UP add auto-color-strength 0.05\nMBTN_BACK+WHEEL_UP scrub-edge start\nMBTN_FORWARD+WHEEL_DOWN scrub-edge end\nMX_GESTURE+WHEEL_UP add volume 2\nMBTN_RIGHT+WHEEL_UP scrub fast\nWHEEL_UP scrub\n"
        #expect(GestureBindingEditor.resetting(text) == "MX_PANEL+WHEEL_UP add auto-color-strength 0.05\nMBTN_BACK+WHEEL_UP scrub-edge start\nMBTN_FORWARD+WHEEL_DOWN scrub-edge end\nMX_GESTURE+WHEEL_UP add volume 2\n")
    }

    // MARK: InputPreferences

    private func preferences(_ text: String? = nil) throws -> (InputPreferences, URL) {
        let url = makeTemporaryDirectory().appendingPathComponent("input.conf")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return (InputPreferences(url: url), url)
    }

    @Test func settingAppliesInMemoryAndWritesTheFile() throws {
        let (prefs, url) = try preferences("SPACE ignore\n")
        var heard = 0
        prefs.addObserver { _ in heard += 1 }
        try prefs.set(binding(.trackpad, .vertical, [], .seek(5, .byConfig)))
        #expect(prefs.inputMap.command(for: KeyChord.parse("TRACKPAD_UP")!) == .seek(5, .byConfig))
        #expect(prefs.inputMap.command(for: KeyChord.parse("TRACKPAD_DOWN")!) == .seek(-5, .byConfig))
        #expect(prefs.inputMap.command(for: KeyChord.parse("SPACE")!) == nil)          // user's own line kept
        #expect(try String(contentsOf: url, encoding: .utf8) == "SPACE ignore\nTRACKPAD_UP seek 5\nTRACKPAD_DOWN seek -5\n")
        #expect(heard == 1)
    }

    @Test func movingARowSilencesTheOldGestureAndBindsTheNewOne() throws {
        let (prefs, _) = try preferences()
        let old = binding(.wheel, .vertical, [], .volume(2))
        try prefs.replace(old, with: binding(.wheel, .vertical, [.shift], .volume(2)))
        #expect(prefs.inputMap.command(for: KeyChord.parse("WHEEL_UP")!) == nil)                  // ignore
        #expect(prefs.inputMap.command(for: KeyChord.parse("Shift+WHEEL_UP")!) == .addVolume(2))
    }

    @Test func replacingWithTheSameGestureIsAnOrdinaryEdit() throws {
        let (prefs, url) = try preferences()
        try prefs.replace(binding(.wheel, .vertical, [], .volume(2)), with: binding(.wheel, .vertical, [], .volume(5)))
        #expect(prefs.inputMap.command(for: KeyChord.parse("WHEEL_UP")!) == .addVolume(5))
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("ignore"))
    }

    @Test func resetRestoresTheDefaultsAndKeepsOtherLines() throws {
        let (prefs, url) = try preferences("q ignore\nTRACKPAD_UP seek 5\n")
        #expect(prefs.inputMap.command(for: KeyChord.parse("TRACKPAD_UP")!) == .seek(5, .byConfig))
        try prefs.resetGestures()
        #expect(prefs.inputMap.command(for: KeyChord.parse("TRACKPAD_UP")!) == .addVolume(2))
        #expect(prefs.inputMap.command(for: KeyChord.parse("q")!) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "q ignore\n")
    }

    @Test func aFailedWriteStillAppliesInMemory() throws {
        let blocker = makeTemporaryDirectory().appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let prefs = InputPreferences(url: blocker.appendingPathComponent("sub/input.conf"))
        #expect(throws: (any Error).self) { try prefs.set(binding(.wheel, .vertical, [], .volume(9))) }
        #expect(prefs.inputMap.command(for: KeyChord.parse("WHEEL_UP")!) == .addVolume(9))
    }

    @Test func gesturePreferencesFollowTheLayout() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".conf")
        defer { try? FileManager.default.removeItem(at: url) }
        try "WHEEL_UP scrub\n".write(to: url, atomically: true, encoding: .utf8)
        let prefs = InputPreferences(url: url, layout: .classic)
        var seen: [InputMap] = []
        prefs.addObserver { seen.append($0) }
        #expect(prefs.inputMap.command(for: KeyChord(key: "l")) == .abLoop)
        prefs.layout = .leftHand
        #expect(prefs.inputMap.command(for: KeyChord(key: "f")) == .abLoop)
        #expect(prefs.inputMap.command(for: KeyChord(key: "WHEEL_UP")) == .scrub(fast: false, invert: false))
        #expect(seen.count == 1)
        prefs.layout = .leftHand
        #expect(seen.count == 1)   // the same layout: nothing rebuilt
    }
}
