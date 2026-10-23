import Foundation

/// The `framescrub://open?path=<percent-encoded absolute path>` link: other programs open a video in FrameScrub with
/// it. `scene=<id>` in place of `path` opens that Stash scene (its file paths are asked of Stash). Optional parameters:
/// - `t=<seconds>`: start there instead of the remembered position;
/// - `seg=<a>-<b>`: play and scrub inside that range (an A-B loop), starting at `a` unless `t` says otherwise;
/// - `plugin=<http(s) URL>`: show that page in the plugin panel.
public enum OpenLink {
    /// What a link names: a file, or a Stash scene by id.
    public enum Subject: Equatable, Sendable {
        case file(URL)
        case stashScene(id: String)
    }

    public struct Target: Equatable, Sendable {
        public var subject: Subject
        /// The position and segment to land on once the file is open.
        public var landing: LinkTarget
        public var plugin: URL?

        public init(subject: Subject, landing: LinkTarget = LinkTarget(), plugin: URL? = nil) {
            self.subject = subject
            self.landing = landing
            self.plugin = plugin
        }

        public init(file: URL, landing: LinkTarget = LinkTarget(), plugin: URL? = nil) {
            self.init(subject: .file(file), landing: landing, plugin: plugin)
        }

        /// The file named; nil for a Stash scene.
        public var file: URL? {
            if case let .file(url) = subject { return url }
            return nil
        }

        /// The Stash scene's id; nil for a file.
        public var sceneID: String? {
            if case let .stashScene(id) = subject { return id }
            return nil
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
    /// path of an `open` link, nil for anything else (another host, no path, a relative path, a Stash scene).
    public static func fileURL(from url: URL) -> URL? {
        target(from: url)?.file
    }

    /// The whole link: the file or scene plus the optional position, segment and plugin page. A `path` wins over a
    /// `scene` when both are given; a scene's id is any non-empty text.
    public static func target(from url: URL) -> Target? {
        if url.isFileURL { return Target(file: url) }
        guard url.scheme?.lowercased() == "framescrub", url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let item = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        let subject: Subject
        if let path = item("path") {
            guard path.hasPrefix("/") else { return nil }
            subject = .file(URL(fileURLWithPath: path))
        } else if let scene = item("scene")?.trimmingCharacters(in: .whitespaces), !scene.isEmpty {
            subject = .stashScene(id: scene)
        } else {
            return nil
        }
        let landing = LinkTarget(time: item("t").flatMap(Double.init).flatMap(LinkTarget.time),
                                 segment: item("seg").flatMap(LinkTarget.segment(from:)))
        let plugin = item("plugin").flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return Target(subject: subject, landing: landing, plugin: plugin)
    }

    /// "12.5-18" → 12.5...18; nil when malformed or empty. The same parser as `LinkTarget.segment(from:)`.
    public static func segment(from text: String) -> ClosedRange<Double>? {
        LinkTarget.segment(from: text)
    }
}
