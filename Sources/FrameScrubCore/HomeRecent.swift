import Foundation
import HomeScreenModel

/// Home's own sources (Home spec, Source): Recent as the browser's video cards, and where each Home tab is. A card's
/// id is `recent:` and the file's path.
public enum HomeRecent {
    public static let source = "recent", stash = "stash"

    /// The recent videos as cards, in the order given: where each was left and its length (the store's, else one
    /// the thumbnailer found, by path), the progress bar, the day it was last left (Recent's date groups), dimmed when
    /// its share does not answer. Recent's cards are never renamed or trashed.
    public static func entries(_ urls: [URL], resume: (URL) -> ResumeEntry?, facts: [String: FileFacts],
                               dimmed: Set<String>) -> [BrowserEntry] {
        urls.map { url in
            let entry = resume(url)
            let known = facts[url.path]
            let duration = entry?.duration ?? known?.duration
            return BrowserEntry(url: url, name: url.lastPathComponent, kind: .file, date: entry?.updated,
                                isDimmed: dimmed.contains(url.path), canRename: false, canTrash: false,
                                key: "recent:" + url.path,
                                subtitle: RecentFiles.timeText(position: entry?.position, duration: duration),
                                progress: RecentFiles.progress(position: entry?.position, duration: duration),
                                facts: known)
        }
    }

    /// The file a Recent card stands for; nil for any other id.
    public static func path(ofID id: String) -> String? {
        id.hasPrefix("recent:") ? String(id.dropFirst("recent:".count)) : nil
    }

    /// Stash only with `stash-url` set: else Recent, whatever `home-tab` says.
    public static func shownTab(_ wanted: HomeTab, stashEnabled: Bool) -> HomeTab {
        wanted == .stash && !stashEnabled ? .recent : wanted
    }

    /// Where a Home tab is; the folders have no place of their own (the last folder browsed).
    public static func location(of tab: HomeTab) -> BrowserLocation? {
        switch tab {
        case .recent: .source(source)
        case .stash: .source(stash)
        case .folders: nil
        }
    }

    /// The Home tab a location belongs to: the places and every folder are the folders.
    public static func tab(of location: BrowserLocation) -> HomeTab {
        switch location {
        case .source(stash): .stash
        case .source: .recent
        case .places, .folder: .folders
        }
    }
}
