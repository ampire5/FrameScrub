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
            ]),
            SettingsSection("Apple low-latency effects (SDR)", rows: [
                .choice("ll-sr", "Super resolution", [
                    (word: "off", title: "Off"), (word: "auto", title: "Automatic for screen size"),
                    (word: "1.5", title: "1.5×"), (word: "2", title: "2×"), (word: "4", title: "4×"),
                ], symbol: "sparkles", description: "Off by default. Available sizes depend on this Mac and the source. Unsupported video keeps the original; the status panel explains why."),
                .choice("ll-interpolation", "Frame interpolation", [
                    (word: "1", title: "Off"), (word: "2", title: "2× frame rate"), (word: "4", title: "4× frame rate"),
                ], symbol: "film.stack", description: "Off by default. Forward playback at normal speed only; requires the next cached frame. Scrubbing keeps exact original frames."),
            ]),
            SettingsSection("Apple Temporal Noise Filter", rows: [
                .toggle("temporal-noise", "Reduce temporal noise", symbol: "sparkles",
                        description: "Off by default. Native resolution, including 4K and HDR when supported. Uses cached neighbors. Frame interpolation is bypassed while noise reduction is processing."),
                .choice("temporal-noise-mode", "Apply noise reduction", [
                    (word: "paused", title: "After stopping / on pause"),
                    (word: "always", title: "Playback and pause (experimental)"),
                ], description: "Default after stopping. Refines once the frame settles; continuous 4K processing may miss presentation deadlines."),
                .number("temporal-noise-strength", "Noise reduction strength", step: 0.1,
                        description: "0–1, default 0.5. Higher may smooth fine texture; this is a noise filter, not a dedicated deblocker."),
            ]),
            SettingsSection("Experimental Filter Lab (SDR)", rows: [
                .toggle("artifact-enabled", "Enable experimental filters", symbol: "camera.filters", description: "Default enabled, all modes off. A/B bypass keeps your selected scaler and sharpening. N toggles filters; Option-N opens the compact slot panel. View menu also offers A/B."),
                .choice("artifact-compare", "Comparison", [(word: "processed", title: "Processed"), (word: "bypass", title: "Bypass filters"), (word: "split", title: "Original left / filtered right"), (word: "changes", title: "Changed pixels (red)")], description: "Default Processed. Split/changes also render an unfiltered upscale for comparison."),
                .choice("artifact-antiring", "Edge cleanup", [(word: "off", title: "Off"), (word: "luma", title: "Local luma limit"), (word: "edge", title: "Coherent edges"), (word: "directional", title: "Directional constrained cleanup")], description: "Default off. Luma/edge limits require MetalFX. Directional cleanup works with any scaler; spatial only."),
                .number("artifact-antiring-strength", "Anti-ringing strength", step: 0.1, description: "0–1, default 1."),
                .choice("artifact-deband", "Deband", [(word: "off", title: "Off"), (word: "single", title: "Four-sample threshold"), (word: "double", title: "Two passes"), (word: "adaptive", title: "Adaptive / texture protection"), (word: "reference", title: "libplacebo logic / reference"), (word: "window", title: "Adaptive window")], description: "Default off. Start with Adaptive window: bounded neighbourhood, local texture protection, smoother gradients. Adaptive samples is more conservative. Two passes smooths more; libplacebo logic is an alternative without the explicit texture guard. Runs before upscaling. Strong settings can remove texture."),
                .number("artifact-deband-strength", "Deband strength", step: 0.1, description: "0–1, default 0.5."),
                .number("artifact-deband-threshold", "Deband threshold", step: 1, description: "0.1–32 RGB8 code values, default 9. Adaptive, window and reference modes; larger values accept stronger color differences."),
                .number("artifact-deband-radius", "Deband radius", unit: "px", step: 1, description: "1–64 input pixels, default 24. Adaptive, window and reference modes."),
                .number("artifact-deband-iterations", "Reference iterations", step: 1, description: "1–4, default 1. Reference mode only; each iteration samples the original input texture."),
                .number("artifact-texture-protection", "Adaptive texture protection", step: 0.1, description: "0–1, default 1. Protects alternating luminance and color detail; 0 disables this guard."),
                .choice("artifact-chroma", "Chroma cleanup", [(word: "off", title: "Off"), (word: "bilateral", title: "Luma-guided bilateral 3×3"), (word: "wide", title: "Luma-guided bilateral 5×5"), (word: "median", title: "Median 3×3")], description: "Default off. Before upscaling; filters color channels while retaining luminance. Spatial only; not motion compensation."),
                .number("artifact-chroma-strength", "Chroma strength", step: 0.1, description: "0–1, default 0.5."),
                .choice("artifact-grain", "Perceptual grain", [(word: "off", title: "Off"), (word: "white", title: "Uncorrelated / comparison"), (word: "fine", title: "Fine"), (word: "soft", title: "Soft"), (word: "av1", title: "AV1-style / fine texture"), (word: "particles", title: "Particles / clustered texture")], description: "Default off. Monochrome texture after scaling and sharpening, stable on pause. AV1-style and particles use prepared patterns, not full film reconstruction. SDR only."),
                .number("artifact-grain-amount", "Grain amount", step: 0.5, description: "0–12, default 0.65. Approximate RGB8 RMS before masking. Try 6 for visible texture; 12 is a strong comparison setting. Existing structure protection remains adjustable."),
                .number("artifact-grain-size", "Grain size", unit: "px", step: 0.25, description: "0.5–4 output pixels, default 1. Larger grain is more visible at normal viewing distance."),
                .number("artifact-grain-base", "Grain in smooth areas", step: 0.1, description: "0–1, default 0.25. Baseline in initially smooth areas; more may be added where cleanup removes weak texture."),
                .number("artifact-grain-adaptation", "Grain structure protection", step: 0.1, description: "0–1, default 1. Full adaptation protects existing edges and texture. Zero gives uniform grain for comparison."),
                .number("artifact-dither", "Output dither", step: 0.1, description: "0–1, default off. Very small fixed noise before display conversion; may help residual quantization steps."),
            ]),
            SettingsSection("Seek bar preview", rows: [
                .toggle("preview", "Show a picture above the seek bar", symbol: "photo.on.rectangle",
                        description: "Default on. Controls the hover picture only; filmstrip thumbnails are independent.",
                        nested: [
                            .number("preview-width", "Picture width", unit: "pt", step: 20,
                                    description: "80–640, default 240."),
                        ]),
            ]),
        ])
    }
}
