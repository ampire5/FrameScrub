import FrameScrubCore
import LogiHIDPP
import SettingsKit
import SwiftUI

extension SettingsPanel {
    /// The `haptic-*` patterns as framescrub.conf spells them: none, every pattern, then every pattern at the strong
    /// strength.
    static let hapticChoices: [(word: String, title: String)] = {
        let plain = HapticPattern.all.map { (word: $0.configName, title: $0.name.prefix(1).uppercased() + $0.name.dropFirst()) }
        return [(word: "none", title: "None")] + plain + plain.map { (word: $0.word + " strong", title: $0.title + ", strong") }
    }()

    /// What each `haptic-*` key plays on, in `HapticEvent` order.
    private static let hapticRows: [(event: HapticEvent, title: String, text: String)] = [
        (.step, "Step", "A step of the speed, the volume or the auto colour strength; a ±10 s jump from the mouse."),
        (.detent, "Detent", "The speed landing on or passing 1×; the auto colour strength on 25, 50 or 75 %."),
        (.limit, "Limit", "A setting stepped against an end of its range; a mark edge dragged to its bound."),
        (.longArmed, "Long press armed", "A button with chords held to Long press: let go now for its long action."),
        (.toggle, "Switch", "A key or button switched something (not play / pause)."),
        (.end, "First or last", "The first or last frame pushed against, or the first or last video of the folder."),
        (.keyframe, "Keyframe", "A plain wheel scrub passing a keyframe."),
        (.mark, "Mark", "A plain wheel scrub passing a mark's start or end, A or B."),
        (.done, "Done", "A frame or a clip written to disk."),
        (.error, "Error", "A command refused, or a write failed."),
    ]

    /// Mouse & Trackpad: the button profile, the MX Master's haptics and buttons, and the gesture table.
    static var mouse: SettingsPage {
        let defaults = Config()
        let haptics: [SettingsRow] = hapticRows.map { row in
            let key = row.event.configKey
            let word = defaults.text(forKey: key) ?? "none"
            let title = hapticChoices.first { $0.word == word }?.title ?? word
            return .choice(key, row.title, hapticChoices, description: row.text + " Default \(title).")
        }
        return SettingsPage("mouse", "Mouse & Trackpad", symbol: "computermouse", sections: [
            SettingsSection("Buttons", rows: [
                .choice("mouse-profile", "Profile", MouseProfile.allCases.map { ($0.rawValue, $0.title) },
                        symbol: "button.programmable",
                        description: "Editing: the gesture button plays and pauses (hold: save a clip), the panel "
                            + "saves the frame (hold: export the range), back and forward set marks. Viewing leaves the "
                            + "marks alone. Hold the SmartShift button to switch. Lines of your own for a profile go to "
                            + "input-viewing.conf or input-editing.conf. Default Viewing."),
                .number("mouse-long-press", "Long press", unit: "ms", step: 50, symbol: "hand.tap",
                        description: "A press held this long is a long one. 150–2000, default 400."),
            ]),
            SettingsSection("Haptics", rows: [
                .toggle("mouse-haptics", "MX Master haptics", symbol: "waveform",
                        description: "The MX Master 4's vibration, through the Bolt receiver, without Logi Options+. "
                            + "A pattern per event, or None. Default on.",
                        nested: haptics + [
                            .number("haptic-strength", "Strength", step: 5,
                                    description: "The mouse's normal vibration strength. 0–100, or keep (default): "
                                        + "the mouse's own setting stays."),
                            .number("haptic-strong-strength", "Strong strength", step: 5,
                                    description: "For the patterns marked strong. 0–100, default 80."),
                        ]),
            ]),
            SettingsSection("MX Master", rows: [
                .number("mx-panel-force", "Panel force", step: 5, symbol: "hand.point.down",
                        description: "How hard the haptic panel must be pressed: 0 the lightest the mouse takes, 100 "
                            + "the stiffest; default writes the factory value, keep leaves it alone. Default 0."),
                .choice("mx-side-buttons", "Back / forward", [
                    (word: "watch", title: "Watch"), (word: "take", title: "Take"), (word: "system", title: "System only"),
                ], symbol: "arrow.left.arrow.right.circle",
                description: "Watch: listen to the mouse, so Mac Mouse Fix and the system keep Back / Forward; Take: "
                    + "they are FrameScrub's alone while it is in front; System only: no HID++, the buttons come "
                    + "through macOS as usual. Default Watch."),
            ]),
            SettingsSection("Gestures", rows: [gestureTable]),
        ])
    }

    /// The wheel, trackpad and pinch pairs; filled in by the gesture table.
    static var gestureTable: SettingsRow {
        .custom("Gestures") { EmptyView() }
    }
}
