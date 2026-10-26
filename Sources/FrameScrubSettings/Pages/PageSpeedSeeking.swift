import FrameScrubCore
import SettingsKit

extension SettingsPanel {
    /// Speed, seeking, the scene search and the sound of scrubbing.
    static var speed: SettingsPage {
        SettingsPage("speed", "Speed & Seeking", symbol: "gauge.with.dots.needle.67percent", sections: [
            SettingsSection("Speed", rows: [
                .number("hold-speed", "Speed while the hold key is held", unit: "×", step: 0.25, symbol: "hare",
                        description: "0.1–16, default 2."),
                .number("speed-step", "Speed step ([ ])", unit: "×", step: 0.05, symbol: "plusminus",
                        description: "0.01–4, default 0.25."),
                .toggle("keep-speed", "Keep the speed for the next video", symbol: "arrow.right.circle",
                        description: "Default on."),
            ]),
            SettingsSection("Seeking", rows: [
                .choice("seek-mode", "Relative seeks and seek bar", [
                    (word: "keyframe", title: "Nearest keyframe"), (word: "exact", title: "Exact frame"),
                ], symbol: "arrow.left.and.right",
                description: "Keyframe seeks are instant; exact ones decode up to the frame. Default Nearest keyframe."),
            ]),
            SettingsSection("Scenes", rows: [
                .number("scene-threshold", "Scene cut threshold", step: 1, symbol: "scissors",
                        description: "How different two frames must be to count as a cut: lower finds more. "
                            + "0–255, default 45."),
                .number("scene-lookahead", "Scenes searched ahead", unit: "keyframes", step: 10, symbol: "binoculars",
                        description: "0–1000, default 30."),
                .number("scene-check-time", "Frame-by-frame checks per press", unit: "s", step: 0.5,
                        symbol: "magnifyingglass",
                        description: "How long a press may look at every frame near a cut; 0 is off. 0–30, default 1."),
                .number("scene-search-time", "Longest wait per press", unit: "s", step: 1, symbol: "timer",
                        description: "0.5–120, default 4."),
            ]),
            SettingsSection("Scrub audio", rows: [
                .toggle("scrub-audio", "Sound on every frame change in pause (⌥M)", symbol: "waveform",
                        description: "Default on.",
                        nested: [
                            .choice("scrub-audio-pitch", "Pitch (⇧⌥M)", [
                                (word: "tape", title: "Tape (follows the speed)"), (word: "natural", title: "Natural"),
                            ], description: "Default Tape."),
                            .number("scrub-audio-length", "Length", unit: "ms", step: 10,
                                    description: "20–500, default 80."),
                        ]),
            ]),
        ])
    }
}
