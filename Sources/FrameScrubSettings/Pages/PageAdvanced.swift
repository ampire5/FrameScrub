import AppKit
import FrameScrubCore
import SettingsKit

extension SettingsPanel {
    /// The plugin pages' permission to open local videos, and the files behind this window.
    static var advanced: SettingsPage {
        SettingsPage("advanced", "Advanced", symbol: "wrench.and.screwdriver", sections: [
            SettingsSection("Plugins", rows: [
                .text("plugin-open-allowed", "Pages that may open local videos", placeholder: "http://localhost:8080",
                      symbol: "puzzlepiece.extension",
                      description: "Origins (http://host:port, comma-separated) whose plugin pages may open videos on "
                        + "this Mac. Default empty: none."),
            ]),
            SettingsSection("Files", rows: [
                .button("Settings file", "Show in Finder", symbol: "doc.text",
                        description: "framescrub.conf: every setting of this window, with your comments.") {
                    reveal(Config.fileURL)
                },
                .button("Key bindings file", "Show in Finder", symbol: "keyboard",
                        description: "input.conf and the profiles' input-viewing.conf and input-editing.conf.") {
                    reveal(Config.directory.appendingPathComponent("input.conf"))
                },
            ]),
        ])
    }

    /// Selects `url` in Finder, or opens its folder when the file is not there yet.
    private static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
