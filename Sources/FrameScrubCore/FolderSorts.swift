import Foundation
import HomeScreenModel

/// Each folder's own order (`BrowserSort.text`), kept across launches in `folder-sorts.json`: Home's grid and the
/// player's list read and change the same one, so a video opened from Finder goes in the order Home shows its folder.
/// Not inherited: a folder without one takes `playlist-sort`'s (`PlaylistSort.defaultSort`). The store is
/// `FolderColors`' (debounced writes, the newest 1 000 folders, an unreadable file set aside). Main thread only.
public final class FolderSorts {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameScrub/folder-sorts.json")

    private static let key = "browser-sort"
    private let store: FolderColors

    /// nil keeps everything in memory and never touches the disk.
    public init(url: URL? = FolderSorts.defaultURL, writeDelay: Double = 2,
                schedule: @escaping (Double, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        store = FolderColors(url: url, writeDelay: writeDelay, schedule: schedule)
    }

    public func sort(for folder: URL) -> BrowserSort? {
        store.own(for: folder)[Self.key].flatMap(BrowserSort.init(text:))
    }

    public func set(_ sort: BrowserSort, for folder: URL) {
        store.set([Self.key: sort.text], for: folder)
    }

    /// Writes pending changes now; for quitting.
    public func flush() { store.flush() }
}
