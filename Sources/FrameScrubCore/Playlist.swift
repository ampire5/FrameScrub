import Foundation
import HomeScreenModel

/// The playlist's order: by name like Finder, or newest / largest first (ties by name).
public enum PlaylistSort: String, CaseIterable, Sendable {
    case name, date, size

    public var next: PlaylistSort {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date (newest first)"
        case .size: "Size (largest first)"
        }
    }

    /// The folder order this stands for, in each key's first direction (as Home's sort capsule): names A–Z, the newest
    /// and the largest first. `playlist-sort` is the order of a folder that has none of its own.
    public var defaultSort: BrowserSort {
        switch self {
        case .name: .standard
        case .date: BrowserSort(key: .date, ascending: false)
        case .size: BrowserSort(key: .size, ascending: false)
        }
    }

    /// For the playlist panel's menu.
    public var shortTitle: String {
        switch self {
        case .name: "Name"
        case .date: "Newest"
        case .size: "Largest"
        }
    }
}

/// The videos in the current file's folder in the folder's `BrowserSort` order, the order Home's grid shows them in
/// (`FolderPlaylist`), narrowed by a name filter. The current file is always part of it.
public struct Playlist: Equatable, Sendable {
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mts", "m2ts", "ts", "mpg", "mpeg", "wmv", "flv", "3gp",
    ]

    public let files: [URL]
    public let currentIndex: Int
    /// The folder's videos before the filter.
    public let totalCount: Int

    /// `filter`: a case- and accent-insensitive part of the name; blank keeps every file.
    public init(current: URL, sort: BrowserSort = .standard, filter: String = "", fileManager: FileManager = .default) {
        self.init(current: current, sort: sort, filter: filter,
                  listing: FolderListing.read(current.standardizedFileURL.deletingLastPathComponent(), fileManager: fileManager))
    }

    /// Orders and filters a listing read earlier (`FolderListing.read` can take seconds on a NAS): the grid's own
    /// order of the same entries, so › and ‹ go where Home's next card is.
    public init(current: URL, sort: BrowserSort = .standard, filter: String = "", listing: FolderListing) {
        let me = current.standardizedFileURL
        let ordered = FolderPlaylist(folder: listing.folder, entries: listing.entries, sort: sort, current: me).urls
        totalCount = ordered.count
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let videos = needle.isEmpty ? ordered
            : ordered.filter { $0 == me || $0.lastPathComponent.localizedStandardContains(needle) }
        files = videos
        currentIndex = videos.firstIndex(of: me) ?? 0
    }

    public var current: URL { files[currentIndex] }
    public var previous: URL? { currentIndex > 0 ? files[currentIndex - 1] : nil }
    public var next: URL? { currentIndex + 1 < files.count ? files[currentIndex + 1] : nil }
    public var isFiltered: Bool { files.count != totalCount }

    /// "12 / 48", or "3 / 7 (48)" while a filter hides some files.
    public var positionText: String {
        "\(currentIndex + 1) / \(files.count)" + (isFiltered ? " (\(totalCount))" : "")
    }

    /// The file to show once the current one is gone: the next one, or the previous one at the end.
    public var neighbourAfterRemoval: URL? { next ?? previous }
}

/// The videos of one folder as Home lists them (`HomeFolders.entries`): the slow part of a playlist, read once and
/// ordered later.
public struct FolderListing: Equatable, Sendable {
    public let folder: URL
    /// The folder's videos, with their dates and sizes.
    public let entries: [BrowserEntry]

    public init(folder: URL, entries: [BrowserEntry]) {
        self.folder = folder.standardizedFileURL
        self.entries = entries.filter(\.isFile)
    }

    public var count: Int { entries.count }

    /// A folder not read yet: a playlist made from it holds only its current file.
    public static func empty(_ folder: URL) -> FolderListing {
        FolderListing(folder: folder, entries: [])
    }

    /// The same listing without `file` (moved to the Trash or deleted since the read).
    public func removing(_ file: URL) -> FolderListing {
        let gone = file.standardizedFileURL
        return FolderListing(folder: folder, entries: entries.filter { $0.url.standardizedFileURL != gone })
    }

    /// One directory read, also on a NAS, by the same code as Home's folders; an unreadable folder gives an empty listing.
    public static func read(_ folder: URL, fileManager: FileManager = .default) -> FolderListing {
        FolderListing(folder: folder, entries: (try? HomeFolders.entries(in: folder, fileManager: fileManager)) ?? [])
    }
}
