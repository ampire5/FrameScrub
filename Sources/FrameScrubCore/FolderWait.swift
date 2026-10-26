import Foundation

/// Commands that need the whole folder (next or previous file, delete, Return in the filter) while its read is still
/// running: the command runs when the read ends, and the window answers meanwhile (a folder on a share can take
/// seconds). A later command replaces one still waiting: the user's last wish is the one that counts.
public struct FolderWait {
    private var pending: (() -> Void)?

    public init() {}

    /// `action` to run now when no read is running (`reading` false), else nil and `action` kept for `readEnded`. The
    /// caller runs it once this call is over: the action opens a file, and the open cancels the wait, which inside this
    /// mutating call would be a second access to the same wait.
    public mutating func take(reading: Bool, _ action: @escaping () -> Void) -> (() -> Void)? {
        if reading {
            pending = action
            return nil
        }
        pending = nil
        return action
    }

    /// The read is over: the command that waited for it, to run once the listing is applied.
    public mutating func readEnded() -> (() -> Void)? {
        defer { pending = nil }
        return pending
    }

    /// Another file opened or the window left the file: what waited is no longer wanted.
    public mutating func cancel() { pending = nil }

    /// The file the playlist is built around: the open one, the one being opened (› while a file on a share is still
    /// being read steps from it, not from nothing), or the one whose open failed.
    public static func anchor(open: URL?, opening: URL?, failed: URL?) -> URL? { open ?? opening ?? failed }
}
