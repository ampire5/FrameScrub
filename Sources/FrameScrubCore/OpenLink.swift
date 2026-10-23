import Foundation

/// The `framescrub://open?path=<percent-encoded absolute path>` link: other programs open a video in FrameScrub with
/// it. Optional parameters:
/// - `t=<seconds>`: start there instead of the remembered position;
/// - `seg=<a>-<b>`: play and scrub inside that range (an A-B loop), starting at `a` unless `t` says otherwise;
/// - `plugin=<http(s) URL>`: show that page in the plugin panel.
public enum OpenLink {
    public struct Target: Equatable, Sendable {
        public var file: URL
        /// The position and segment to land on once the file is open.
        public var landing: LinkTarget
        public var plugin: URL?

        public init(file: URL, landing: LinkTarget = LinkTarget(), plugin: URL? = nil) {
            self.file = file
            self.landing = landing
            self.plugin = plugin
        }

        public init(file: URL, time: Double? = nil, segment: ClosedRange<Double>? = nil, plugin: URL? = nil) {
            self.init(file: file, landing: LinkTarget(time: time, segment: segment), plugin: plugin)
        }

        public var time: Double? {
            get { landing.time }
            set { landing.time = newValue }
        }
        public var segment: ClosedRange<Double>? {
            get { landing.segment }
            set { landing.segment = newValue }
        }

        /// Where to land: `t`, else the segment's start.
        public var start: Double? { landing.start }
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
        let landing = LinkTarget(time: item("t").flatMap(Double.init).flatMap(LinkTarget.time),
                                 segment: item("seg").flatMap(LinkTarget.segment(from:)))
        let plugin = item("plugin").flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return Target(file: URL(fileURLWithPath: path), landing: landing, plugin: plugin)
    }

    /// "12.5-18" → 12.5...18; nil when malformed or empty. The same parser as `LinkTarget.segment(from:)`.
    public static func segment(from text: String) -> ClosedRange<Double>? {
        LinkTarget.segment(from: text)
    }
}
