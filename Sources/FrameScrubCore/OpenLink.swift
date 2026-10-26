import Foundation

/// The `framescrub://open?path=<percent-encoded absolute path>` link: other programs open a video in FrameScrub with
/// it. `scene=<id>` in place of `path` opens that Stash scene (its file paths are asked of Stash). Optional parameters:
/// - `t=<seconds>`: start there instead of the remembered position;
/// - `seg=<a>-<b>[,<a>-<b>…]`: lock playback and scrubbing to those segments (seconds), starting at the first one's
///   start unless `t` says otherwise; one malformed item drops the whole list;
/// - `lock=0|1`: whether the segments lock playback (default 1);
/// - `adv=repeat|next`: at a segment's end, play it again or go to the next one (default from the configuration);
/// - `plugin=<http(s) URL>`: show that page in the plugin panel.
public enum OpenLink {
    /// What a link names: a file, or a Stash scene by id.
    public enum Subject: Equatable, Sendable {
        case file(URL)
        case stashScene(id: String)
    }

    public struct Target: Equatable, Sendable {
        public var subject: Subject
        /// The position and segments to land on once the file is open.
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

        public init(file: URL, time: Double? = nil, segments: [ClosedRange<Double>] = [], plugin: URL? = nil) {
            self.init(file: file, landing: LinkTarget(time: time, segments: segments), plugin: plugin)
        }

        public var time: Double? {
            get { landing.time }
            set { landing.time = newValue }
        }
        public var segments: [ClosedRange<Double>] {
            get { landing.segments }
            set { landing.segments = newValue }
        }

        /// Where to land: `t`, else the first segment's start.
        public var start: Double? { landing.start }
    }

    /// The file to open for a link the system handed to the app: the URL itself when it is a `file:` URL, the decoded
    /// path of an `open` link, nil for anything else (another host, no path, a relative path, a Stash scene).
    public static func fileURL(from url: URL) -> URL? {
        target(from: url)?.file
    }

    /// The whole link: the file or scene plus the optional position, segments and plugin page. A `path` wins over a
    /// `scene` when both are given; a scene's id is any non-empty text.
    public static func target(from url: URL) -> Target? {
        if url.isFileURL { return Target(file: url) }
        guard url.scheme?.lowercased() == "framescrub", url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let item = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        let subject: Subject
        if let path = item("path") {
            guard path.hasPrefix("/") else { return nil }
            subject = .file(URL(filePath: path, directoryHint: .notDirectory))   // not looked up: a share answers over the network
        } else if let scene = item("scene")?.trimmingCharacters(in: .whitespaces), !scene.isEmpty {
            subject = .stashScene(id: scene)
        } else {
            return nil
        }
        let landing = LinkTarget(time: item("t").flatMap(Double.init).flatMap(LinkTarget.time),
                                 segments: item("seg").flatMap(LinkTarget.segments(from:)) ?? [],
                                 lock: item("lock").flatMap { ["0": false, "1": true][$0] },
                                 advance: item("adv").flatMap { SegmentAdvance(rawValue: $0.lowercased()) })
        let plugin = item("plugin").flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return Target(subject: subject, landing: landing, plugin: plugin)
    }

    /// "12.5-18" → 12.5...18; nil when malformed or empty. The same parser as `LinkTarget.segment(from:)`.
    public static func segment(from text: String) -> ClosedRange<Double>? {
        LinkTarget.segment(from: text)
    }
}
