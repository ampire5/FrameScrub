import AppKit
import FrameScrubCore
import SettingsKit
import StashKit

extension SettingsPanel {
    /// Stash: the server whose library Home shows, its key, the path rules, how scenes play, and a check of all of it.
    static var stash: SettingsPage {
        SettingsPage("stash", "Stash", symbol: "books.vertical", sections: [
            SettingsSection("Library", rows: [
                .text("stash-url", "Address", placeholder: "http://localhost:9999", symbol: "network",
                      description: "The Stash server: its library is in Home's sidebar. Empty (default): no Stash."),
                .text("stash-api-key", "API key", symbol: "key",
                      description: "Stash's API key (Settings › Security in Stash) when Stash has a login; default "
                        + "empty."),
                .text("stash-path-map", "Path rules", placeholder: #"S:\Videos=/Volumes/Media/Videos"#,
                      symbol: "arrow.triangle.branch",
                      description: #"Where Stash's paths are on this Mac, as stashPrefix=localPrefix separated by ";", "#
                        + #"tried before the mounted shares (drive letters go to the PC's S$ shares, \\server\share "#
                        + "to the same share). Default empty."),
                .choice("stash-stream", "Play from Stash's stream", StashStreaming.allCases.map { ($0.rawValue, $0.title) },
                        symbol: "play.tv",
                        description: "Instead of the scene's file on a share. Default When the file is on no share."),
                .button("Connection", "Check", symbol: "checkmark.seal",
                        description: "Asks Stash for its version and finds its first scene's file on this Mac.") {
                    checkStash()
                },
            ]),
        ])
    }

    /// The Check button: Stash's version and its first scene's file, mapped as a play would map it.
    private static func checkStash() {
        guard let store else { return }
        let address = store.value(forKey: "stash-url") ?? ""
        guard let url = URL(string: address), url.host != nil else {
            alert("No Stash address", "Set the address first.")
            return
        }
        let client = StashClient(baseURL: url, apiKey: store.value(forKey: "stash-api-key") ?? "")
        let rules = store.value(forKey: "stash-path-map") ?? ""
        Task { @MainActor in
            do {
                let version = try await client.version()
                guard let path = try await client.firstScenePath() else {
                    alert("Stash answers", "Stash \(version) · no scenes yet")
                    return
                }
                let map = StashPathMap(mounts: SMBMount.current(), rules: StashPathRule.parse(rules))
                let place: String
                switch map.resolve(path) {
                case .local(let file):
                    place = file.path + (FileManager.default.fileExists(atPath: file.path) ? "" : " (not found)")
                case .needsMount(let share):
                    place = "\(unc(share)) is not mounted; it will be on play"
                case .unmapped:
                    place = "no share for it"
                }
                alert("Stash answers", "Stash \(version)\n\(path) → \(place)")
            } catch {
                alert("Stash does not answer", error.localizedDescription)
            }
        }
    }

    /// `smb://host/share/…` as Windows writes it: `\\host\share`.
    private static func unc(_ smbURL: URL) -> String {
        let share = smbURL.path.split(separator: "/").first.map(String.init)?.removingPercentEncoding ?? ""
        return #"\\"# + (smbURL.host ?? "") + #"\"# + share
    }

    static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
