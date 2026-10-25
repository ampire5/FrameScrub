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

    @Test func olderTextRevealsAtOnce() throws {
        // Written before the reveal field: six fields, revealed at once.
        // after-choice was their default: such a slot now hides when the pointer leaves, as new ones do.
        let s = try #require(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden"))
        #expect(s.reveal == .atOnce)
        #expect(s.text == "playlist, overlay, glass, mouse-leaves, 400, hidden, at-once")
        #expect(try #require(SlotSetting(text: "playlist, overlay, glass, manual, 400, hidden")).autoHide == .manual)
        #expect(try #require(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden, at-once")).autoHide
                == .afterChoice)
        #expect(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden, sideways") == nil)
    }

    @Test func defaultHidesWhenThePointerLeaves() {
        #expect(SlotSetting.default(for: .right).autoHide == .mouseLeaves)
        #expect(SlotSetting.default(for: .right).reveal == .atOnce)
    }

    @Test func emptyAndPlaylist() throws {
        let empty = try #require(SlotSetting(text: "empty, pinned, dark, manual, 300, hidden"))
        #expect(empty.content == .empty && empty.mode == .pinned && empty.backdrop == .dark)
        #expect(empty.autoHide == .manual && empty.size == 300 && !empty.shown)
        let playlist = try #require(SlotSetting(text: "playlist, overlay, glass, after-choice, 400, hidden, at-once"))
        #expect(playlist.content == .playlist && playlist.autoHide == .afterChoice)
    }

    @Test func badTextIsNil() {
        #expect(SlotSetting(text: "plugin:, overlay, glass, after-choice, 560, shown") == nil)
        #expect(SlotSetting(text: "playlist, sideways, glass, after-choice, 560, shown") == nil)
        #expect(SlotSetting(text: "playlist, overlay, glass, after-choice, abc, shown") == nil)
        #expect(SlotSetting(text: "playlist, overlay, glass") == nil)
    }

    @Test func sizeIsClamped() throws {
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 50, hidden")).clamped(for: .left).size == 240)
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 5000, hidden")).clamped(for: .right).size == 1200)
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 50, hidden")).clamped(for: .bottom).size == 120)
        #expect(try #require(SlotSetting(text: "empty, pinned, dark, manual, 5000, hidden")).clamped(for: .bottom).size == 900)
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

    @Test func defaultsWithoutPlugin() {
        let slots = SlotDefaults.migrate(pluginURL: "")
        #expect(slots[.right] == SlotSetting(content: .playlist, mode: .overlay, backdrop: .glass, autoHide: .mouseLeaves,
                                             size: 400, shown: false))
        #expect(slots[.left]?.content == .empty)
        #expect(slots[.bottom]?.content == .empty)
    }

    @Test func defaultsWithPlugin() {
        let slots = SlotDefaults.migrate(pluginURL: "http://h/p")
        #expect(slots[.right]?.content == .plugin(name: "Plugin"))
        #expect(slots[.right]?.mode == .pinned)
        #expect(slots[.right]?.size == 400)
        #expect(slots[.bottom]?.content == .playlist)
        #expect(slots[.bottom]?.mode == .overlay)
    }
}
