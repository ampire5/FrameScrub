import Foundation
import FrameScrubCore
import SettingsKit
import Testing
@testable import FrameScrubSettings

@MainActor struct ShortcutHelpContentTests {
    @Test func usesCurrentBindingsAndListsFixedGesturesAndAvailablePluginActions() throws {
        var input = InputMap(layout: .leftHand)
        input.apply("MBTN_RIGHT ignore")
        input.apply("TRACKPAD_LEFT ignore")
        input.apply("PINCH_OUT add volume 2")
        input.apply("F13 plugin-action review")
        let actions = [
            PluginAction(name: "review", label: "Review item", key: KeyChord.parse("F14")),
            PluginAction(name: "skip", label: "Skip item", key: nil),
        ]
        let sheet = ShortcutHelpContent.sheet(for: input.merging(actions).map, pluginActions: actions,
                                             menuRows: [("⌘O", "Open…")])
        let sections = sheet.columns.flatMap { $0 }
        let rows = sections.flatMap(\.rows)
        #expect(!rows.contains { $0.keys.components(separatedBy: "  ").contains("Right click") })
        #expect(!rows.contains { $0.keys.components(separatedBy: "  ").contains("Swipe ←") })
        #expect(rows.contains { $0.keys.contains("Pinch out") && $0.title == "Volume up" })
        #expect(rows.contains { $0.keys == "⌘O" && $0.title == "Open…" })
        let gestures = try #require(sections.first { $0.title == "Mouse & Trackpad" })
        #expect(gestures.rows.contains { $0.keys == "Right-button drag up / down" })
        #expect(!gestures.rows.contains { $0.keys.contains("Pinch") || $0.keys.contains("Scroll") })
        let plugin = try #require(sections.first { $0.title == "Plugin" })
        #expect(plugin.rows.map(\.keys) == ["F13", ""])
        #expect(plugin.rows.map(\.title) == ["Review item", "Skip item"])
    }

    @Test func followsTheSelectedMouseProfile() {
        func backActions(_ profile: MouseProfile) -> [String] {
            let input = InputMap.build(layout: .classic, profile: profile)
            return ShortcutHelpContent.sheet(for: input, pluginActions: [], menuRows: [])
                .columns.flatMap { $0 }.flatMap(\.rows)
                .filter { $0.keys.components(separatedBy: "  ").contains("Back button") }
                .map(\.title)
        }
        #expect(backActions(.viewing) == ["Stats"])
        #expect(backActions(.editing) == ["Mark in"])
    }

    @Test func includesEveryKeyForAnActionInTheSearchText() throws {
        var input = InputMap(bindings: [:])
        input.apply("a add volume 2\nb add volume 2\nc add volume 2\nd add volume 2")
        let sheet = ShortcutHelpContent.sheet(for: input, pluginActions: [], menuRows: [])
        let row = try #require(sheet.columns.flatMap { $0 }.flatMap(\.rows).first { $0.title == "Volume up" })
        #expect(row.keys == "a  b  c  d")
    }
}
