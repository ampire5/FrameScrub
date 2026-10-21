import Foundation

/// The `framescrub://open?path=<percent-encoded absolute path>` link: other programs (the Stash dedupe page) open a
/// video in FrameScrub with it.
public enum OpenLink {
    /// The file to open for a link the system handed to the app: the URL itself when it is a `file:` URL, the decoded
    /// path of an `open` link, nil for anything else (another host, no path, a relative path).
    public static func fileURL(from url: URL) -> URL? {
        if url.isFileURL { return url }
        guard url.scheme?.lowercased() == "framescrub", url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
