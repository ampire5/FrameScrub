import Foundation

/// The `framescrub://open?path=<percent-encoded absolute path>` link: other programs open a video in FrameScrub with
/// it. Optional parameters:
/// - `t=<seconds>`: start there instead of the remembered position;
/// - `seg=<a>-<b>`: play and scrub inside that range (an A-B loop), starting at `a` unless `t` says otherwise;
/// - `plugin=<http(s) URL>`: show that page in the plugin panel.
public enum OpenLink {
    public struct Target: Equatable, Sendable {
        public var file: URL
        public var time: Double?
        public var segment: ClosedRange<Double>?
        public var plugin: URL?

        public init(file: URL, time: Double? = nil, segment: ClosedRange<Double>? = nil, plugin: URL? = nil) {
            self.file = file
            self.time = time
            self.segment = segment
            self.plugin = plugin
        }

        /// Where to land: `t`, else the segment's start.
        public var start: Double? { time ?? segment?.lowerBound }
    }

    /// The file to open for a link the system handed to the app: the URL itself when it is a `file:` URL, the decoded
    /// path of an `open` link, nil for anything else (another host, no path, a relative path).
    public static func fileURL(from url: URL) -> URL? {
        target(from: url)?.file
    }

    /// The whole link: the file plus the optional position, segment and plugin page.
    public static func target(from url: URL) -> Target? {
        if url.isFileURL { return Target(file: url) }
        guard url.scheme?.lowercased() == "framescrub", url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/") else { return nil }
        let item = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        var target = Target(file: URL(fileURLWithPath: path))
        target.time = item("t").flatMap(Double.init).flatMap { $0 >= 0 ? $0 : nil }
        target.segment = item("seg").flatMap(segment(from:))
        target.plugin = item("plugin").flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return target
    }

    /// "12.5-18" → 12.5...18; nil when malformed or empty.
    public static func segment(from text: String) -> ClosedRange<Double>? {
        let parts = text.split(separator: "-", maxSplits: 1).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let a = parts[0], let b = parts[1], a >= 0, b > a else { return nil }
        return a...b
    }
}
