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
