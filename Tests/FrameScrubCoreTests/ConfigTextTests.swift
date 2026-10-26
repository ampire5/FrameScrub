import Testing
@testable import FrameScrubCore

@Suite struct ConfigTextTests {
    @Test func replacesValueInPlaceKeepingCommentsAndOrder() {
        let text = "# my settings\njpeg-quality=90  # sharp enough\n\nunknown-key=1\nvolume=50\n"
        let out = ConfigText.setting([("jpeg-quality", "80"), ("volume", "70")], in: text)
        #expect(out == "# my settings\njpeg-quality=80 # sharp enough\n\nunknown-key=1\nvolume=70\n")
    }

    @Test func appendsMissingKeysBeforeTrailingNewline() {
        #expect(ConfigText.setting([("seek-mode", "exact")], in: "volume=50\n") == "volume=50\nseek-mode=exact\n")
    }

    @Test func commentedOutKeyIsNotTouched() {
        #expect(ConfigText.setting([("volume", "70")], in: "# volume=50\n") == "# volume=50\nvolume=70\n")
    }

    @Test func emptyTextGetsHeader() {
        #expect(ConfigText.setting([("volume", "70")], in: "") == ConfigText.header + "\nvolume=70\n")
    }

    @Test func keyMatchingIgnoresCaseAndSpaces() {
        #expect(ConfigText.setting([("volume", "70")], in: "  Volume = 50\n") == "volume=70\n")
    }

    @Test func rewritesAndRemovesGestureBindings() {
        let text = "shift+trackpad_left scrub fast # mine\nSPACE cycle pause\nTRACKPAD_UP add volume 2\n"
        let set = ConfigText.settingBindings([(KeyChord.parse("Shift+TRACKPAD_LEFT")!, "seek -5"),
                                              (KeyChord.parse("PINCH_IN")!, "zoom")], in: text)
        #expect(set == "Shift+TRACKPAD_LEFT seek -5 # mine\nSPACE cycle pause\nTRACKPAD_UP add volume 2\nPINCH_IN zoom\n")
        let removed = ConfigText.removingBindings(for: [KeyChord.parse("TRACKPAD_UP")!,
                                                        KeyChord.parse("Shift+TRACKPAD_LEFT")!], in: set)
        #expect(removed == "SPACE cycle pause\nPINCH_IN zoom\n")
    }

    @Test func stripCommentTrimsAndKeepsHashInsideValues() {
        #expect(stripComment("  frame-dir=/Users/me/C#/x  ") == "frame-dir=/Users/me/C#/x")
        #expect(stripComment("volume=5\t# loud") == "volume=5")
        #expect(stripComment("# all comment") == "")
    }

    @Test func commentingOutKeepsTheLineForLater() {
        let text = "SPACE frame-step  # mine\nF13 cycle pause\n# SPACE ignore\n"
        let out = ConfigText.commentingOutBindings(for: [KeyChord(key: "SPACE")], in: text)
        #expect(out == "# SPACE frame-step  # mine\nF13 cycle pause\n# SPACE ignore\n")
        #expect(ConfigText.commentingOutBindings(for: [KeyChord(key: "F14")], in: text) == text)
    }
}
