import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct SlotSettingsTests {
    @Test func textRoundTrip() throws {
        let text = "plugin:Media Library, overlay, clear, mouse-leaves, 560, shown, at-once"
        let s = try #require(SlotSetting(text: text))
        #expect(s.content == .plugin(name: "Media Library"))
        #expect(s.mode == .overlay)
        #expect(s.backdrop == .clear)
        #expect(s.autoHide == .mouseLeaves)
        #expect(s.size == 560)
        #expect(s.shown)
        #expect(s.text == text)
    }

    @Test func revealRoundTrip() throws {
        let text = "plugin:Notes, overlay, glass, mouse-leaves, 400, hidden, tongue"
        let s = try #require(SlotSetting(text: text))
        #expect(s.reveal == .tongue)
        #expect(s.content == .plugin(name: "Notes") && s.size == 400 && !s.shown)
        #expect(s.text == text)
        #expect(try #require(SlotSetting(text: "playlist, overlay, glass, mouse-leaves, 400, hidden, at-once")).reveal == .atOnce)
    }

    @Test func revealFieldIsRequired() throws {
        #expect(SlotSetting(text: "playlist, overlay, glass, mouse-leaves, 400, hidden") == nil)
        #expect(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden, sideways") == nil)
        #expect(try #require(SlotSetting(text: "playlist, overlay, glass, manual, 400, hidden, at-once")).autoHide == .manual)
        #expect(try #require(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden, at-once")).autoHide
                == .afterChoice)
    }

    @Test func defaultHidesWhenThePointerLeaves() {
        #expect(SlotSetting.default(for: .right).autoHide == .mouseLeaves)
        #expect(SlotSetting.default(for: .right).reveal == .atOnce)
    }

    @Test func emptyAndPlaylist() throws {
        let empty = try #require(SlotSetting(text: "empty, pinned, dark, manual, 300, hidden, at-once"))
        #expect(empty.content == .empty && empty.mode == .pinned && empty.backdrop == .dark)
        #expect(empty.autoHide == .manual && empty.size == 300 && !empty.shown)
        let playlist = try #require(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden, at-once"))
        #expect(playlist.content == .playlist && playlist.autoHide == .afterChoice)
    }

    @Test func badTextIsNil() {
        #expect(SlotSetting(text: "plugin:, overlay, glass, after-choice, 560, shown, at-once") == nil)
        #expect(SlotSetting(text: "playlist, sideways, glass, after-choice, 560, shown, at-once") == nil)
        #expect(SlotSetting(text: "playlist, overlay, glass, after-choice, abc, shown") == nil)
        #expect(SlotSetting(text: "playlist, overlay, glass") == nil)
    }

    @Test func sizeIsClamped() throws {
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 50, hidden, at-once")).clamped(for: .left).size == 240)
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 5000, hidden, at-once")).clamped(for: .right).size == 1200)
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 50, hidden, at-once")).clamped(for: .bottom).size == 120)
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 5000, hidden, at-once")).clamped(for: .bottom).size == 900)
    }

    @Test func backdropCycles() {
        #expect(SlotBackdrop.dark.next == .glass)
        #expect(SlotBackdrop.glass.next == .clear)
        #expect(SlotBackdrop.clear.next == .dark)
    }

    @Test func pluginLineWithPipeInURL() throws {
        let entry = try #require(PluginEntry(line: "Notes | http://h/x?a=1|2"))
        #expect(entry.name == "Notes")
        #expect(entry.url.query(percentEncoded: false) == "a=1|2")
    }

    @Test func pluginLineNeedsNameAndURL() {
        #expect(PluginEntry(line: "Notes") == nil)
        #expect(PluginEntry(line: " | http://h") == nil)
        #expect(PluginEntry(line: "Notes | not a url") == nil)
        #expect(PluginEntry(line: "Notes | file:///Users/me/notes.html") != nil)
    }

    @Test func standardDefaults() {
        let slots = SlotDefaults.standard
        #expect(slots[.right] == SlotSetting(content: .playlist, mode: .overlay, backdrop: .glass, autoHide: .mouseLeaves,
                                             size: 400, shown: false))
        #expect(slots[.left] == .default(for: .left))
        #expect(slots[.bottom] == .default(for: .bottom))
    }

    // MARK: Tabs (contents as a list)

    private static let tail = ", overlay, glass, mouse-leaves, 400, hidden, at-once"

    @Test func severalContentsRoundTrip() throws {
        let text = "playlist + plugin:Stash" + Self.tail
        let s = try #require(SlotSetting(text: text))
        #expect(s.contents == [.playlist, .plugin(name: "Stash")])
        #expect(s.text == text)
    }

    @Test func singleContentWritesTheOldText() throws {
        let text = "plugin:Notes, overlay, glass, mouse-leaves, 560, hidden, at-once"
        let s = try #require(SlotSetting(text: text))
        #expect(s.contents == [.plugin(name: "Notes")])
        #expect(s.text == text)
    }

    @Test func emptyIsNoContents() throws {
        let s = try #require(SlotSetting(text: "empty" + Self.tail))
        #expect(s.contents == [])
        #expect(s.content == .empty)
        #expect(s.text == "empty" + Self.tail)
    }

    @Test func pluginNameMayHoldPlus() throws {
        #expect(try #require(SlotSetting(text: "plugin:A+B" + Self.tail)).contents == [.plugin(name: "A+B")])
    }

    @Test func emptyInsideAListIsDropped() throws {
        #expect(try #require(SlotSetting(text: "playlist + empty" + Self.tail)).contents == [.playlist])
    }

    @Test func duplicateIsDropped() throws {
        #expect(try #require(SlotSetting(text: "playlist + playlist" + Self.tail)).contents == [.playlist])
    }

    @Test func aBadEntryRejectsTheSetting() {
        #expect(SlotSetting(text: "playlist + nonsense" + Self.tail) == nil)
    }
}
