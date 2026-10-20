import Foundation

/// Removes a video: to the Trash when its volume has one, else for good after asking (SMB shares usually have none).
public enum FileRemoval {
    public enum Outcome: Equatable, Sendable {
        case trashed, deleted, cancelled
        case failed(String)
    }

    /// `release` closes the file before a permanent delete (a share may refuse to delete an open file); moving to the
    /// Trash works on an open file, and a cancelled delete leaves it open.
    public static func remove(_ url: URL,
                              trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                              confirmDelete: () -> Bool,
                              release: () -> Void,
                              delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Outcome {
        do {
            try trash(url)
            return .trashed
        } catch {}
        guard confirmDelete() else { return .cancelled }
        release()
        do {
            try delete(url)
            return .deleted
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
