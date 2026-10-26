import Foundation

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

    /// For the playlist panel's menu.
    public var shortTitle: String {
        switch self {
        case .name: "Name"
        case .date: "Newest"
        case .size: "Largest"
        }
    }
}

/// The videos in the current file's folder, sorted, and narrowed by a name filter. The current file is always part of it.
public struct Playlist: Equatable, Sendable {
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mts", "m2ts", "ts", "mpg", "mpeg", "wmv", "flv", "3gp",
    ]

    public let files: [URL]
    public let currentIndex: Int
    /// The folder's videos before the filter.
    public let totalCount: Int

    /// `filter`: a case- and accent-insensitive part of the name; blank keeps every file.
    public init(current: URL, sort: PlaylistSort = .name, filter: String = "", fileManager: FileManager = .default) {
        self.init(current: current, sort: sort, filter: filter,
                  listing: FolderListing.read(current.standardizedFileURL.deletingLastPathComponent(), fileManager: fileManager))
    }

    /// Sorts and filters a listing read earlier (`FolderListing.read` can take seconds on a NAS). `ascending` turns the
    /// sort's own direction (names A–Z, the newest and the largest first) around, as Home's sort can; equal dates or
    /// sizes stay by name either way.
    public init(current: URL, sort: PlaylistSort = .name, ascending: Bool? = nil, filter: String = "",
                listing: FolderListing) {
        let me = current.standardizedFileURL
        let attributes = listing.videos
        var videos = Array(attributes.keys)
        if !videos.contains(me) { videos.append(me) }
        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        switch sort {
        case .name:
            videos.sort(by: ascending ?? true ? byName : { byName($1, $0) })
        case .date:
            let date = { attributes[$0]?.date ?? .distantPast }, up = ascending ?? false
            videos.sort { date($0) != date($1) ? (date($0) < date($1)) == up : byName($0, $1) }
        case .size:
            let size = { attributes[$0]?.size ?? 0 }, up = ascending ?? false
            videos.sort { size($0) != size($1) ? (size($0) < size($1)) == up : byName($0, $1) }
        }
        totalCount = videos.count
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            videos = videos.filter { $0 == me || $0.lastPathComponent.localizedStandardContains(needle) }
        }
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

/// The videos of one folder with their dates and sizes: the slow part of a playlist, read once and sorted later.
public struct FolderListing: Equatable, Sendable {
    public let folder: URL
    let videos: [URL: VideoAttributes]

    struct VideoAttributes: Equatable, Sendable {
        let date: Date
        let size: Int
    }

    public var count: Int { videos.count }

    /// A folder not read yet: a playlist made from it holds only its current file.
    public static func empty(_ folder: URL) -> FolderListing {
        FolderListing(folder: folder.standardizedFileURL, videos: [:])
    }

    /// The same listing without `file` (moved to the Trash or deleted since the read).
    public func removing(_ file: URL) -> FolderListing {
        var videos = videos
        videos[file.standardizedFileURL] = nil
        return FolderListing(folder: folder, videos: videos)
    }

    /// One directory read, also on a NAS; an unreadable folder gives an empty listing.
    public static func read(_ folder: URL, fileManager: FileManager = .default) -> FolderListing {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles])) ?? []
        // Dates and sizes come from the listing's own URLs, which carry the prefetched values.
        var videos: [URL: VideoAttributes] = [:]
        for url in contents where Playlist.videoExtensions.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            videos[url.standardizedFileURL] = VideoAttributes(date: values?.contentModificationDate ?? .distantPast,
                                                             size: values?.fileSize ?? 0)
        }
        return FolderListing(folder: folder.standardizedFileURL, videos: videos)
    }
}
