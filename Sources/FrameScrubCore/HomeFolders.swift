import Foundation
import HomeScreenModel

/// Home's folders (Home spec, Source): a folder's subfolders and videos as the browser's entries, the places (the
/// home folder and the mounted volumes) and where Up goes. Plain reads, run off the main thread by the caller.
public enum HomeFolders {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                                 .contentModificationDateKey, .fileSizeKey]

    /// The folder's subfolders and its videos (`Playlist.videoExtensions`), hidden files and packages left out, each
    /// with its date and size; a video's id is its path, as Recent's files are found by it. Throws when the folder
    /// cannot be read. A symbolic link counts as what it points to (a folder or a video), as Finder shows it.
    public static func entries(in folder: URL, fileManager: FileManager = .default) throws -> [BrowserEntry] {
        // A folder reached through a link is read where the link points, with the attributes in the same call (one
        // round trip on a share, not one per file); its entries keep the path they were reached by.
        try fileManager.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
                                            options: .skipsHiddenFiles)
            .compactMap { found in
                let url = folder.appendingPathComponent(found.lastPathComponent)
                var values = try? found.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    values = try? found.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys))
                }
                if values?.isDirectory == true {
                    guard values?.isPackage != true else { return nil }
                    return BrowserEntry(url: url, name: url.lastPathComponent, kind: .folder,
                                        date: values?.contentModificationDate, canRename: true, canTrash: true)
                }
                guard Playlist.videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
                return BrowserEntry(url: url, name: url.lastPathComponent, kind: .file, date: values?.contentModificationDate,
                                    size: values?.fileSize.map(Int64.init), canRename: true, canTrash: true)
            }
    }

    /// The home folder, then the volumes as the system lists them (the startup disk is the home folder's).
    public static func places(home: URL, volumes: [URL]) -> [BrowserEntry] {
        [BrowserEntry(url: home, name: home.lastPathComponent, kind: .place)]
            + volumes.filter { $0.path != "/" }.map { BrowserEntry(url: $0, name: $0.lastPathComponent, kind: .place) }
    }

    /// Up from a place is the places; from anything else, its parent folder.
    public static func parent(of folder: URL, places: [URL]) -> BrowserLocation {
        let path = folder.standardizedFileURL.path
        if places.contains(where: { $0.standardizedFileURL.path == path }) || path == "/" { return .places }
        return .folder(folder.deletingLastPathComponent())
    }

    /// A file's progress and length line on its card: where it was left (the position store) and its length (the
    /// store's, else one found while making its poster).
    public static func withFacts(_ entries: [BrowserEntry], resume: (URL) -> ResumeEntry?,
                                 durations: [String: Double]) -> [BrowserEntry] {
        entries.map { e in
            guard e.isFile else { return e }
            var e = e
            let entry = resume(e.url)
            let duration = entry?.duration ?? durations[e.url.path]
            e.subtitle = RecentFiles.timeText(position: entry?.position, duration: duration)
            e.progress = RecentFiles.progress(position: entry?.position, duration: duration)
            return e
        }
    }

    /// Home's sort of a folder as the playlist's order: › and ‹ go through the videos as the grid showed them.
    public static func playlistOrder(_ sort: BrowserSort) -> (sort: PlaylistSort, ascending: Bool) {
        switch sort.key {
        case .name: (.name, sort.ascending)
        case .date: (.date, sort.ascending)
        case .size: (.size, sort.ascending)
        }
    }
}
