import Foundation

/// FrameScrub's ordered folder paths. Membership and ordering do not depend on whether a volume is mounted.
@MainActor public final class FolderFavorites {
    private static let key = "homeFavoriteFolders"
    private let defaults: UserDefaults
    private var paths: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = Self.unique(defaults.stringArray(forKey: Self.key) ?? [])
    }

    public var folders: [URL] {
        paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public func contains(_ folder: URL) -> Bool {
        folder.isFileURL && paths.contains(folder.standardizedFileURL.path)
    }

    @discardableResult public func add(_ folder: URL) -> Bool {
        guard folder.isFileURL, !contains(folder) else { return false }
        return save(paths + [folder.standardizedFileURL.path])
    }

    @discardableResult public func remove(_ folder: URL) -> Bool {
        guard folder.isFileURL else { return false }
        let path = folder.standardizedFileURL.path
        return save(paths.filter { $0 != path })
    }

    @discardableResult public func move(_ folder: URL, before other: URL?) -> Bool {
        guard folder.isFileURL, other?.isFileURL != false else { return false }
        let path = folder.standardizedFileURL.path
        guard let old = paths.firstIndex(of: path) else { return false }
        var reordered = paths
        reordered.remove(at: old)
        if let other {
            guard let index = reordered.firstIndex(of: other.standardizedFileURL.path) else { return false }
            reordered.insert(path, at: index)
        } else {
            reordered.append(path)
        }
        return save(reordered)
    }

    @discardableResult public func rename(_ folder: URL, to destination: URL) -> Bool {
        guard folder.isFileURL, destination.isFileURL else { return false }
        let old = folder.standardizedFileURL.path
        let new = destination.standardizedFileURL.path
        guard old != "/", old != new else { return false }
        let moves = Dictionary(uniqueKeysWithValues: paths.compactMap { path -> (String, String)? in
            if path == old { return (path, new) }
            if path.hasPrefix(old + "/") { return (path, new + path.dropFirst(old.count)) }
            return nil
        })
        let destinations = Set(moves.values)
        return save(paths.compactMap { path in
            if let moved = moves[path] { return moved }
            return destinations.contains(path) ? nil : path
        })
    }

    private func save(_ updated: [String]) -> Bool {
        guard paths != updated else { return false }
        paths = updated
        defaults.set(paths, forKey: Self.key)
        return true
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
}
