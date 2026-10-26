import Foundation
import Testing
@testable import FrameScrubCore
@testable import FrameScrubSettings

/// The gesture table's model: edits go through `InputPreferences` (the player hears them), and the window's search
/// finds the table by its rows.
@MainActor @Suite struct GestureTableModelTests {
    private func preferences() -> InputPreferences {
        InputPreferences(url: makeTemporaryDirectory().appendingPathComponent("input.conf"), layout: .classic)
    }

    @Test func editsGoThroughInputPreferences() throws {
        let prefs = preferences()
        let model = GestureTableModel(preferences: prefs)
        let row = try #require(model.rows.first { $0.device == .trackpad && $0.axis == .vertical && $0.modifiers.isEmpty })
        var new = row
        new.action = .volume(3)
        model.update(row, new)
        #expect(prefs.bindings.contains { $0.sameGesture(as: row) && $0.action == .volume(3) })
        #expect(model.rows.contains { $0.sameGesture(as: row) && $0.action == .volume(3) })
        #expect(model.errorMessage == nil)
    }

    @Test func searchTextsNameDevicesAndActions() {
        let texts = GestureTableModel.searchTexts(preferences().bindings)
        #expect(texts.contains { $0.hasPrefix("Trackpad") })
        #expect(texts.contains { $0.hasPrefix("Mouse wheel") })
        #expect(texts.contains("Scrub frames"))
    }
}
