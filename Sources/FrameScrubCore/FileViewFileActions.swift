import Foundation

/// Blocking filesystem work for one File View command. The caller runs batches off the main thread.
package enum FileViewFileActions {
    package enum Command: Sendable {
        case copy(into: URL)
        case move(into: URL)
        case trash
        case delete
    }

    package struct Report: Sendable {
        package var completed = 0
        package var unchanged = 0
        package var failures = 0
        package var firstError: String?
        package var parents: Set<String> = []
        package var movedFolders: [(from: URL, to: URL)] = []
        package var needsConfirmation: [URL] = []
    }

    package static func run(_ command: Command, urls: [URL], protected: [URL] = [],
                            trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Report {
        var report = Report()
        var seen: Set<String> = []
        let protected = protected.map { $0.resolvingSymlinksInPath().path }
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            autoreleasepool {
                do {
                    switch command {
                    case .copy(let folder):
                        _ = try transfer(url, into: folder, moving: false)
                        report.parents.insert(folder.standardizedFileURL.path)
                    case .move(let folder):
                        try checkExports(url, protected: protected)
                        guard let moved = try transfer(url, into: folder, moving: true) else {
                            report.unchanged += 1
                            return
                        }
                        if moved.isFolder { report.movedFolders.append((url, moved.target)) }
                        report.parents.insert(folder.standardizedFileURL.path)
                        report.parents.insert(url.deletingLastPathComponent().standardizedFileURL.path)
                    case .trash:
                        try checkExports(url, protected: protected)
                        do {
                            try trash(url)
                        } catch let error as CocoaError where error.code == .featureUnsupported || error.code == .fileWriteVolumeReadOnly {
                            report.needsConfirmation.append(url)
                            return
                        }
                        report.parents.insert(url.deletingLastPathComponent().standardizedFileURL.path)
                    case .delete:
                        try checkExports(url, protected: protected)
                        try FileManager.default.removeItem(at: url)
                        report.parents.insert(url.deletingLastPathComponent().standardizedFileURL.path)
                    }
                    report.completed += 1
                } catch {
                    report.failures += 1
                    if report.firstError == nil { report.firstError = "\(url.lastPathComponent) — \(error.localizedDescription)" }
                }
            }
        }
        return report
    }

    private static func checkExports(_ url: URL, protected: [String]) throws {
        guard !protected.isEmpty else { return }
        let path = url.resolvingSymlinksInPath().path
        if protected.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { throw Problem.exporting }
    }

    private static func transfer(_ url: URL, into folder: URL, moving: Bool) throws -> (target: URL, isFolder: Bool)? {
        let fm = FileManager.default
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let folderLink = info.st_mode & S_IFMT == S_IFLNK && url.hasDirectoryPath
        let destination = folder.resolvingSymlinksInPath()
        if isDirectory {
            var relationship: FileManager.URLRelationship = .other
            try fm.getRelationship(&relationship, ofDirectoryAt: url.resolvingSymlinksInPath(), toItemAt: destination)
            guard relationship == .other else { throw Problem.insideSource }
        }
        var relationship: FileManager.URLRelationship = .other
        try fm.getRelationship(&relationship, ofDirectoryAt: url.deletingLastPathComponent().resolvingSymlinksInPath(),
                               toItemAt: destination)
        let sameFolder = relationship == .same
        if sameFolder, moving { return nil }

        var target = folder.appendingPathComponent(url.lastPathComponent)
        if sameFolder {
            let name = url.lastPathComponent as NSString
            let ext = isDirectory ? "" : name.pathExtension
            let stem = ext.isEmpty ? name as String : name.deletingPathExtension
            var number = 1
            repeat {
                let suffix = number == 1 ? " copy" : " copy \(number)"
                target = folder.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
                number += 1
            } while lstat(target.path, &info) == 0
        }

        guard lstat(target.path, &info) != 0 else { throw Problem.exists }
        if moving {
            try fm.moveItem(at: url, to: target)
        } else {
            // A failed recursive copy may leave a partial tree. Publish only the finished copy.
            let temporary = folder.appendingPathComponent(".framescrub-copy-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: url, to: temporary)
            try fm.moveItem(at: temporary, to: target)
        }
        return (target, isDirectory || folderLink)
    }

    private enum Problem: LocalizedError {
        case exists, insideSource, exporting

        var errorDescription: String? {
            switch self {
            case .exists: "An item with this name already exists."
            case .insideSource: "A folder can’t be copied or moved into itself."
            case .exporting: "An export is still using this item."
            }
        }
    }
}
