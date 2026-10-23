import Testing
@testable import FrameScrubCore

@Suite struct PluginKeyMessageTests {
    @Test func editingState() {
        #expect(PluginKeyMessage.parse(["editing": true]) == .editing(true))
        #expect(PluginKeyMessage.parse(["editing": false]) == .editing(false))
    }

    @Test func aScrollingKeyWithItsModifiersAndRepeat() {
        #expect(PluginKeyMessage.parse(["key": "Space"]) == .key(PluginKey(keyCode: 49)))
        #expect(PluginKeyMessage.parse(["key": "ArrowLeft", "shift": true, "option": true, "repeat": true])
            == .key(PluginKey(keyCode: 123, shift: true, option: true, isRepeat: true)))
        #expect(PluginKeyMessage.parse(["key": "End", "control": true]) == .key(PluginKey(keyCode: 119, control: true)))
    }

    @Test func onlyTheScrollingKeysAreReported() {
        // A page could post anything here: it may only press the keys it could have let through.
        #expect(PluginKeyMessage.parse(["key": "Backspace"]) == nil)
        #expect(PluginKeyMessage.parse(["key": "KeyA"]) == nil)
        #expect(PluginKeyMessage.parse(["key": 49]) == nil)
        #expect(PluginKeyMessage.parse([:]) == nil)
        #expect(PluginKeyMessage.parse(["editing": "yes"]) == nil)
    }

    @Test func theScrollingKeysAreTheNamedKeysTheyMapTo() {
        let named = PluginKeyMessage.scrollKeys.values.compactMap {
            KeyChord.fromKeyEvent(keyCode: $0, characters: nil, modifiers: [])?.key
        }
        #expect(Set(named) == ["SPACE", "LEFT", "RIGHT", "UP", "DOWN", "PGUP", "PGDWN", "HOME", "END"])
    }
}

@Suite struct PluginKeyStateTests {
    @Test func anUnhandledKeyGoesToThePlayer() {
        var keys = PluginKeyState()
        keys.pressed(49)
        #expect(keys.forwards(49, isRepeat: false))
        keys.released(49)
        #expect(keys.forwards(49, isRepeat: false))   // a tap answered after its key-up still counts
    }

    @Test func nothingWhileTheFocusTakesTyping() {
        var keys = PluginKeyState()
        keys.apply(.editing(true))
        keys.pressed(53)
        #expect(!keys.forwards(53, isRepeat: false))
        #expect(!keys.forwards(53, isRepeat: true))
        keys.apply(.editing(false))
        #expect(keys.forwards(53, isRepeat: false))
    }

    @Test func aRepeatOnlyWhileItsKeyIsDown() {
        var keys = PluginKeyState()
        keys.pressed(124)
        #expect(keys.forwards(124, isRepeat: true))
        keys.released(124)
        #expect(!keys.forwards(124, isRepeat: true))
        #expect(!keys.forwards(123, isRepeat: true))   // never seen going down
    }

    @Test func aHoldCanStartOnlyWhileItsKeyIsDown() {
        var keys = PluginKeyState()
        keys.pressed(1)
        #expect(keys.isDown(1))
        keys.released(1)
        #expect(!keys.isDown(1))
    }

    @Test func movingTheFocusForgetsTheHeldKeysButNotTheTyping() {
        var keys = PluginKeyState()
        keys.apply(.editing(true))
        keys.pressed(1)
        keys.focusMoved()
        #expect(!keys.isDown(1))
        #expect(keys.editing)
    }

    @Test func aNewPageStartsOver() {
        var keys = PluginKeyState()
        keys.apply(.editing(true))
        keys.pressed(1)
        keys.pageReplaced()
        #expect(keys == PluginKeyState())
    }

    @Test func aKeyReportDoesNotChangeTheTyping() {
        var keys = PluginKeyState()
        keys.apply(.editing(true))
        keys.apply(.key(PluginKey(keyCode: 49)))
        #expect(keys.editing)
    }
}
