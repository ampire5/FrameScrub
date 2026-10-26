import FrameScrubCore
import SettingsKit

extension SettingsPanel {
    /// Frames, clips and the A-B range export: formats, names, sizes, and the export sheet's defaults.
    static var saving: SettingsPage {
        SettingsPage("saving", "Saving", symbol: "square.and.arrow.down", sections: [
            SettingsSection("Frames", rows: [
                .choice("frame-format", "Format", [
                    (word: "jpeg", title: "JPEG"), (word: "png", title: "PNG"), (word: "heic", title: "HEIC"),
                    (word: "tiff", title: "TIFF"),
                ], symbol: "photo", description: "Default JPEG."),
                .number("jpeg-quality", "JPEG quality", step: 1, symbol: "slider.horizontal.3",
                        description: "1–100, default 95."),
                .number("heic-quality", "HEIC quality", step: 1, symbol: "slider.horizontal.3",
                        description: "1–100, default 95."),
                .text("frame-dir", "Folder", placeholder: "%{video-dir}/%{video-name}", symbol: "folder",
                      description: "Where frames go; %{video-dir} and %{video-name} are the video's. Default "
                        + "%{video-dir}/%{video-name}."),
                .text("frame-template", "File name", placeholder: "%{video-name}_f%{frame:06}_%{time:hh-mm-ss.mmm}",
                      symbol: "textformat",
                      description: "%{video-name}, %{frame:06} (the frame number, six digits), %{time:hh-mm-ss.mmm}. "
                        + "Default %{video-name}_f%{frame:06}_%{time:hh-mm-ss.mmm}."),
                outputSize("save-scale", "Saved and copied frames", symbol: "arrow.up.left.and.arrow.down.right"),
                .choice("save-upscaler", "Enlarge with", [
                    (word: "ml", title: "Apple neural network (when possible)"), (word: "lanczos", title: "Lanczos"),
                ], symbol: "wand.and.stars", description: "Default Apple neural network."),
                .toggle("save-color", "Apply the colour to saved and copied frames", symbol: "paintpalette",
                        description: "Vibrance and auto colour as on screen. Default off."),
            ]),
            SettingsSection("Clips", rows: [
                .text("clip-template", "File name", placeholder: "%{video-name}_%{start}_%{end}", symbol: "textformat",
                      description: "%{video-name}, %{start}, %{end}. Default %{video-name}_%{start}_%{end}."),
                .choice("clip-mode", "Marks are saved as", ClipMode.allCases.map { ($0.rawValue, $0.title) },
                        symbol: "film.stack", description: "Default Separate files."),
                .toggle("clip-confirm", "Ask how to save when there are several marks", symbol: "questionmark.circle",
                        description: "Default on."),
                .number("clip-read-limit", "Read speed limit", unit: "MB/s", step: 10, symbol: "tortoise",
                        description: "How fast a clip may read its video, so playback keeps up; 0 is no limit. "
                            + "0–1000, default 40."),
            ]),
            SettingsSection("Range export", rows: [
                outputSize("export-scale", "Exported frames (A–B)", symbol: "arrow.up.left.and.arrow.down.right"),
                .number("export-threads", "Threads", step: 1, symbol: "cpu", description: "1–64, default 4."),
                .choice("export-mode", "Frames", [
                    (word: "all", title: "Every frame"), (word: "every", title: "Every Nth frame"),
                    (word: "fps", title: "At a frame rate"),
                ], symbol: "square.stack.3d.down.right",
                description: "The export sheet's choice, kept for the next export. Default Every frame.",
                nested: [
                    .number("export-every", "Every", unit: "frames", step: 1, description: "2–10000, default 10."),
                    .number("export-fps", "Frame rate", unit: "fps", step: 1, description: "0.01–240, default 1."),
                ]),
                .toggle("export-sharp", "Sharpest frame of each step", symbol: "camera.aperture",
                        description: "With every Nth frame or a frame rate: the sharpest frame of each step is saved "
                            + "instead of its first. Default off."),
                .toggle("export-skip-blurry", "Skip blurry frames", symbol: "camera.metering.unknown",
                        description: "A step whose frame is blurrier than its neighbours' is left out. Default off.",
                        nested: [
                            .number("export-sharp-threshold", "Sharpness needed", unit: "%", step: 5,
                                    description: "Of the neighbouring steps' median sharpness. 1–100, default 80."),
                            .number("export-sharp-neighbours", "Neighbours", unit: "steps", step: 2,
                                    description: "How many steps the median is taken of: an odd number, 3–31, "
                                        + "default 7."),
                        ]),
                .toggle("export-skip-duplicates", "Skip duplicate frames", symbol: "square.on.square.dashed",
                        description: "Default off.",
                        nested: [
                            .number("export-duplicate-change", "Least change", unit: "%", step: 1,
                                    description: "How much of the picture has to change since the last frame "
                                        + "saved. 1–100, default 5."),
                        ]),
            ]),
        ])
    }

    /// `save-scale` / `export-scale`: ×1, ×2, ×4, the screen, or one side in pixels, as the file writes them.
    private static func outputSize(_ key: String, _ title: String, symbol: String) -> SettingsRow {
        .text(key, title, placeholder: "1, 2, 4, fit, width:3840 or height:2160", symbol: symbol,
              description: "1, 2 or 4 times the video's size; fit: into the screen the window is on; width:N or "
                + "height:N: that many pixels on that side. Default 1.")
    }
}
