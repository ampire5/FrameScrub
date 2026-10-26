import SettingsKit

extension SettingsPanel {
    /// Vibrance and auto colour: the defaults a video or its folder can override (c, v, ⇧C, ⌥C); a row whose key the
    /// open video's file or folder sets shows that level.
    static var colour: SettingsPage {
        SettingsPage("colour", "Colour", symbol: "paintpalette", sections: [
            SettingsSection("Vibrance", rows: [
                .toggle("vibrance-on", "Vibrance", symbol: "drop",
                        description: "The default; V switches it for the video, a folder save keeps it for the "
                            + "folder. Default off.",
                        nested: [
                            .number("vibrance", "Strength", step: 0.05, description: "0–1, default 0.5."),
                        ], off: []),
            ]),
            SettingsSection("Auto colour", rows: [
                .toggle("auto-color", "Auto colour, for scenes that need it", symbol: "wand.and.rays",
                        description: "The default; C switches it for the video. Default off.",
                        nested: [
                            .number("auto-color-strength", "Strength", step: 0.05, description: "0–1, default 1."),
                            .number("auto-color-threshold", "Correct scenes from", unit: "Δ", step: 1,
                                    description: "How far off a scene's colour must be to be corrected; 0: always. "
                                        + "0–50, default 6."),
                            .number("auto-color-full", "Full strength from", unit: "Δ", step: 1,
                                    description: "At or below the threshold: at once. 0–50, default 12."),
                            .number("auto-color-interval", "Recompute every", unit: "s", step: 1,
                                    description: "0: only on C. 0–600, default 0."),
                            .flags("auto-color-filters", "Corrections", [
                                (word: "curve", title: "Tone curve (contrast)"),
                                (word: "shadows", title: "Shadows and highlights"),
                                (word: "vibrance", title: "Vibrance"),
                            ], description: "Default all three."),
                            .number("auto-color-vibrance-gain", "Auto vibrance gain", unit: "×", step: 0.5,
                                    description: "1–8, default 1."),
                        ], off: []),
            ]),
        ])
    }
}
