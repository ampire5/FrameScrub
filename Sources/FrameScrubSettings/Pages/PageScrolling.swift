import SettingsKit

extension SettingsPanel {
    /// Scrubbing with the trackpad and the wheel, and the Logitech wheel's modes.
    static var scrolling: SettingsPage {
        SettingsPage("scrolling", "Scrolling", symbol: "scroll", sections: [
            SettingsSection("Trackpad and mouse wheel scrubbing", rows: [
                .number("scrub-px-per-frame", "Points per frame", unit: "pt", step: 0.5, symbol: "ruler",
                        description: "How far a scroll goes for one frame. 0.5–500, default 8."),
                .toggle("scrub-accel", "Accelerate: faster movement takes bigger steps", symbol: "speedometer",
                        description: "Default on.",
                        nested: [
                            .number("scrub-accel-from", "Acceleration starts at", unit: "fps", step: 5,
                                    description: "5–120, default 20."),
                            .number("scrub-accel-max", "Fastest accelerated scrub", unit: "fps", step: 10,
                                    description: "30–2000, default 240."),
                        ]),
                .number("scrub-fast-multiplier", "Fast scrub", unit: "×", step: 1, symbol: "forward",
                        description: "How many times faster the fast scrub binding goes. 1–100, default 10."),
                .toggle("scrub-invert", "Invert scrub direction", symbol: "arrow.left.arrow.right",
                        description: "Default off."),
            ]),
            SettingsSection("Logitech wheel", rows: [
                .toggle("wheel-precision", "Free spin and Precision Scroll in the player", symbol: "dial.medium",
                        description: "FrameScrub sets the MX Master's wheel while the player is in front. Default off.",
                        nested: [
                            .choice(FrameScrubSettingsStore.wheelFreeSpinKey, "Wheel in the player", [
                                (word: "yes", title: "Free spin + Precision Scroll"), (word: "no", title: "Ratchet"),
                            ], description: "The SmartShift button switches it too, and it is remembered. Default "
                                + "Free spin."),
                            .choice("wheel-precision-mode", "Precision Scroll speed", [
                                (word: "frames", title: "Frames a notch"), (word: "fps", title: "Video time a notch"),
                            ], description: "Video time: a notch covers the same time whatever the frame rate. "
                                + "Default Frames a notch."),
                            .number("wheel-precision-frames", "Frames a notch", step: 0.5,
                                    description: "With Frames a notch. 0.5–6, default 6."),
                            .number("wheel-precision-time", "Video time a notch", unit: "ms", step: 10,
                                    description: "With Video time a notch. 20–250, default 100."),
                        ]),
            ]),
        ])
    }
}
