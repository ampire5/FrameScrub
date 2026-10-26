import SettingsKit
import SwiftUI

extension SettingsPanel {
    /// Key Bindings: the keys and mouse buttons of input.conf and the profile's file, each a table in its own card.
    /// The window's search finds a table by its rows' inputs and actions. The keyboard table also lists the menus'
    /// shortcuts, read-only.
    static var keyBindings: SettingsPage {
        SettingsPage("key-bindings", "Key Bindings", symbol: "keyboard", sections: [
            SettingsSection("Keyboard", rows: [bindingTable(mouse: false)]),
            SettingsSection("Mouse", rows: [bindingTable(mouse: true)]),
        ])
    }

    private static func bindingTable(mouse: Bool) -> SettingsRow {
        .custom(mouse ? "Mouse bindings" : "Keyboard bindings",
                searchTexts: { bindingSource?.searchTexts(mouse: mouse) ?? [] }) {
            if let source = bindingSource {
                KeyBindingTable(source: source, mouse: mouse,
                                note: mouse ? source.profileNote : InputBindingSource.menuNote)
            }
        }
    }
}
