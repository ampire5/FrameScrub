import AppKit
import FrameScrubCore
import SettingsKit
import SwiftUI

extension SettingsPanel {
    /// Playback as a file opens and ends, the app itself, and which build this is.
    static var general: SettingsPage {
        SettingsPage("general", "General", symbol: "gearshape", sections: [
            SettingsSection("Playback", rows: [
                .number("volume", "Volume", unit: "%", step: 5, symbol: "speaker.wave.2",
                        description: "0–100, default 100."),
                .toggle("autoplay", "Start playing when a file opens", symbol: "play",
                        description: "Off: a file opens paused on its first frame (or where it was left). Default off."),
                .toggle("resume-playback", "Resume where I left off", symbol: "arrow.uturn.forward",
                        description: "A video opened again starts where it was closed. Default on."),
                .toggle("playlist-autoadvance", "Play the next video in the folder at the end", symbol: "forward.end",
                        description: "Default on."),
                .choice("playlist-sort", "Folder order", PlaylistSort.allCases.map { ($0.rawValue, $0.title) },
                        symbol: "arrow.up.arrow.down",
                        description: "The order ‹ and › step through a folder (Home's order replaces it for a video "
                            + "opened there). Default Name."),
                .toggle("activate-on-open", "Bring FrameScrub to the front when a file is opened from Finder",
                        symbol: "macwindow.on.rectangle", description: "Default on."),
                .choice("ab-loop", "At the end of the A-B range", ABLoopMode.allCases.map { ($0.rawValue, $0.title) },
                        symbol: "repeat",
                        description: "What playback does on reaching B (⇧F, or L in the classic layout, cycles it). "
                            + "Default Loop."),
                .choice("segment-advance", "At the end of a locked segment", [
                    (word: "repeat", title: "Play it again"), (word: "next", title: "Go on to the next one"),
                ], symbol: "rectangle.split.3x1", description: "Default Play it again."),
            ]),
            SettingsSection("App", rows: [
                .choice("key-layout", "Keyboard layout", KeyLayout.allCases.map { ($0.rawValue, $0.title) },
                        symbol: "keyboard",
                        description: "Left hand: the keys under the left hand, the right half kept as second keys; "
                            + "Classic: mpv's keys. Your input.conf lines go on top of either. Default Classic."),
                .toggle("single-instance", "Only one running copy", symbol: "square.on.square",
                        description: "A second launch hands its files to the first. Applies at the next launch. "
                            + "Default off."),
                .toggle("ontop", "Float on top", symbol: "pin",
                        description: "The player window stays above other apps' windows. Default off."),
                .icon("app-icon", "App icon", choices: { context?.iconChoices() ?? [] }, folder: AppIcon.userDirectory,
                      current: { value in context?.iconChoice?(value) }, symbol: "app.badge",
                      description: "The Dock's icon while FrameScrub runs (Finder keeps the bundle's): a built-in "
                        + "one or a picture of yours in ~/.config/framescrub/icons. Also View › App Icon…. Default "
                        + "horse."),
            ]),
            SettingsSection("Build", rows: [
                .custom("Build", searchTexts: { ["Build", buildLine] }) { BuildLineView(line: buildLine) },
            ]),
        ])
    }

    /// Read once: the bundle does not change while the app runs.
    static let buildLine = BuildInfo.line(of: .current)
}

/// Which build this is, to quote when something is wrong: selectable, and a button copies it.
struct BuildLineView: View {
    let line: String

    var body: some View {
        HStack {
            Text(line).textSelection(.enabled).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
        }
        .padding(12)
    }
}
