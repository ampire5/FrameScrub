import FrameScrubCore
import SettingsKit

extension SettingsPanel {
    /// Home, the text sizes of the panels, and the side slots.
    static var home: SettingsPage {
        SettingsPage("home", "Home & Interface", symbol: "house", sections: [
            SettingsSection("Home", rows: [
                .number("home-card-size", "Card size (⌘= / ⌘−)", unit: "pt", step: 20, symbol: "square.grid.2x2",
                        description: "60–480, default 220."),
                .toggle("home-sidebar", "Sidebar (⌃⌘S)", symbol: "sidebar.left", description: "Default on."),
                .choice("icon-set", "Icons", IconSet.allCases.map { ($0.rawValue, $0.title) }, symbol: "star",
                        description: "The set the line icons are drawn from. Takes effect at the next launch. "
                            + "Default Lucide."),
                .number("recent-count", "Recent videos", step: 5, symbol: "clock",
                        description: "How many videos Recent keeps. 1–200, default 50."),
            ]),
            SettingsSection("Text", rows: [
                .number("playlist-font-size", "Playlist text size (F8)", unit: "pt", step: 1, symbol: "list.bullet",
                        description: "9–32, default 14."),
                .choice("playlist-view", "Playlist", [("list", "List"), ("strip", "Strip")], symbol: "film.stack",
                        description: "The playlist as a list of names, or as a strip of pictures. Default List."),
                .number("playlist-strip-return", "Strip goes back after", unit: "s", step: 1, symbol: "arrow.uturn.backward",
                        description: "Seconds before the strip goes back to the playing video after browsing. "
                            + "0–30, default 3; 0: never."),
                .number("stats-font-size", "Stats text size (I)", unit: "pt", step: 1, symbol: "info.circle",
                        description: "8–40, default 12."),
            ]),
            SettingsSection("Slots", rows: [
                .number("slot-reveal-distance", "Side slots come within", unit: "pt", step: 2,
                        symbol: "rectangle.lefthalf.inset.filled",
                        description: "How near the window's left or right edge the pointer brings a hidden slot "
                            + "(View › Slots sets what each holds). 2–60, default 12."),
            ]),
        ])
    }
}
