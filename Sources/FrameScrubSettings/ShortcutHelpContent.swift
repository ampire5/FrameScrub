import FrameScrubCore
import SettingsKit

/// Supplies FrameScrub's live bindings and its fixed video gestures to the shared HUD.
public enum ShortcutHelpContent {
    public static func sheet(
        for map: InputMap, pluginActions: [PluginAction], menuRows: [(input: String, title: String)]
    ) -> CheatSheetView.Sheet {
        typealias Section = CheatSheetView.Sheet.Section
        let sections = KeyHelp.sections(for: map, plugin: pluginActions, keyLimit: .max)
        func bindings(_ groups: [KeyHelp.Section]) -> [Section] {
            groups.compactMap { group in
                guard let entries = sections.first(where: { $0.section == group })?.entries else { return nil }
                return Section(title: group.title, rows: entries.map { ($0.keys.joined(separator: "  "), $0.action) })
            }
        }
        return CheatSheetView.Sheet(columns: [
            bindings([.playback, .frames, .navigation, .audio]),
            bindings([.picture, .saving, .plugin]),
            bindings([.window]) + [
                Section(title: "Menu Shortcuts", rows: menuRows.map { ($0.input, $0.title) }),
                Section(title: "Mouse & Trackpad", rows: fixedGestures),
            ],
        ])
    }

    // Scrolls, pinches and mouse clicks that use InputMap are already shown with their effective actions.
    private static let fixedGestures: [(keys: String, title: String)] = [
        ("Hold a trackpad click and swipe with three fingers", "Swipe left for the next video, right for the previous one"),
        ("Two-finger double tap", "Toggle Fit / 100% at the pointer"),
        ("Three-finger double tap", "Enter or leave full screen"),
        ("Force Click", "Show or hide video information"),
        ("Drag the picture", "Pan when zoomed in, otherwise move the window"),
        ("Right-button drag up / down", "Zoom at the press point"),
    ]
}
