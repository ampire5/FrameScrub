import SettingsKit

extension SettingsPanel {
    /// Memory for decoded frames and reads, decoding, and files on network volumes.
    static var performance: SettingsPage {
        SettingsPage("performance", "Performance", symbol: "speedometer", sections: [
            SettingsSection("Memory", rows: [
                .number("cache-size", "Frame cache", unit: "MiB", step: 256, symbol: "memorychip",
                        description: "Decoded frames kept for scrubbing back and forth. 64–1048576, default 2048."),
                .number("read-cache", "Read cache", unit: "MiB", step: 64, symbol: "internaldrive",
                        description: "The file read ahead into memory; 0 is off. Applies to the next file. 0–4096, "
                            + "default 256."),
            ]),
            SettingsSection("Thumbnail storage", rows: [
                .number("thumbnail-poster-size", "Folder poster size", unit: "px", step: 64, symbol: "photo",
                        description: "Long side, 128–1920 px; default 480. Applies after restarting."),
                .number("thumbnail-recent-size", "Last-frame thumbnail size", unit: "px", step: 64, symbol: "photo.on.rectangle",
                        description: "Long side, 128–1920 px; default 1280. Applies after restarting."),
                .choice("thumbnail-format", "Thumbnail format", [
                    (word: "jpeg", title: "JPEG"), (word: "heic", title: "HEIC"), (word: "avif", title: "AVIF"),
                ], symbol: "photo", description: "Default JPEG. Applies after restarting. Unavailable encoders use JPEG."),
                .number("thumbnail-quality", "Thumbnail quality", unit: "%", step: 5, symbol: "slider.horizontal.3",
                        description: "10–100, default 80. Applies after restarting; quality differs between formats."),
                .number("thumbnail-cache-mib", "Thumbnail store limit", unit: "MiB", step: 64, symbol: "internaldrive",
                        description: "16–65536, default 256. Applies after restarting. Oldest cached images are removed first."),
                .custom("Media cache", searchTexts: { ["Cache", "Database", "Clear", "Thumbnails"] }) { MediaCacheView() },
            ]),
            SettingsSection("Decoding", rows: [
                .choice("hwdec", "Video decoding", [
                    (word: "auto", title: "Auto (VideoToolbox)"), (word: "yes", title: "Hardware (VideoToolbox)"),
                    (word: "no", title: "Software"),
                ], symbol: "cpu", description: "Default Auto."),
                .choice("network-mode", "Network volumes", [
                    (word: "auto", title: "Read gently (automatic)"), (word: "yes", title: "Always read gently"),
                    (word: "no", title: "Never"),
                ], symbol: "network",
                description: "Gently: fewer, larger reads, so a share keeps up. Default Read gently (automatic)."),
            ]),
        ])
    }
}
