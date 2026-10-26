import SettingsKit

extension SettingsPanel {
    /// How the picture is drawn on screen, and the seek bar's preview.
    static var display: SettingsPage {
        SettingsPage("display", "Display", symbol: "display", sections: [
            SettingsSection("Picture", rows: [
                .choice("scale", "Scaling on screen", [
                    (word: "auto", title: "Automatic"), (word: "metalfx", title: "MetalFX"),
                    (word: "lanczos", title: "Lanczos"), (word: "bilinear", title: "Bilinear"),
                ], symbol: "arrow.up.left.and.arrow.down.right", description: "Default Automatic."),
                .number("sharpen", "Sharpening after enlarging", step: 0.05, symbol: "triangle.lefthalf.filled",
                        description: "0–1, default 0.3."),
                .toggle("sr-still", "Redraw a paused frame with the neural network", symbol: "sparkles",
                        description: "Default on."),
            ]),
            SettingsSection("Seek bar preview", rows: [
                .toggle("preview", "Show a picture above the seek bar", symbol: "photo.on.rectangle",
                        description: "Default on.",
                        nested: [
                            .number("preview-width", "Picture width", unit: "pt", step: 20,
                                    description: "80–640, default 240."),
                        ]),
            ]),
        ])
    }
}
