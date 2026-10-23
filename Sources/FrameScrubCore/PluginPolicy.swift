import Foundation

/// A web origin as the browser sees it: scheme, host and port, the port left out when it is the scheme's own.
/// Two pages share an origin when all three agree; the path never matters. `file:` pages share one origin, "file://".
public struct PluginOrigin: Hashable, Sendable, CustomStringConvertible {
    /// Lower case.
    public let scheme: String
    /// Lower case; empty for `file:`.
    public let host: String
    /// Nil for the scheme's default port (80 for http, 443 for https) and for schemes without one.
    public let port: Int?

    /// Nil without a scheme, or with a scheme that is not a web page's (http, https, file).
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        self.init(scheme: scheme, host: url.host ?? "", port: url.port ?? 0)
    }

    /// From the parts a browser reports; `port` 0 (or the scheme's own) means the default.
    public init?(scheme: String, host: String, port: Int) {
        let scheme = scheme.lowercased()
        guard ["http", "https", "file"].contains(scheme) else { return nil }
        self.scheme = scheme
        self.host = host.lowercased()
        switch (scheme, port) {
        case (_, 0), ("http", 80), ("https", 443), ("file", _): self.port = nil
        default: self.port = port
        }
    }

    /// The origin as written in `plugin-open-allowed` and shown to the user: "http://host:8000", "file://".
    public init?(string: String) {
        guard let url = URL(string: string), url.path.isEmpty || url.path == "/" else { return nil }
        self.init(url: url)
    }

    public var description: String {
        "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }
}

/// What a plugin page may do. Only pages from a trusted origin get the `window.framescrub` bridge and are heard: the
/// configured plugin URL and the `plugin=` of an opened link make an origin trusted. Opening a local file is a step
/// further: the file must be a video the player would show, and the user allows each origin once (kept in
/// `plugin-open-allowed`).
public struct PluginPolicy: Equatable, Sendable {
    public var trusted: Set<PluginOrigin>
    public var openAllowed: Set<PluginOrigin>

    public init(trusted: Set<PluginOrigin> = [], openAllowed: Set<PluginOrigin> = []) {
        self.trusted = trusted
        self.openAllowed = openAllowed
    }

    /// From the remembered origins ("plugin-open-allowed"); unreadable entries are dropped.
    public init(trusted: Set<PluginOrigin> = [], openAllowedStrings: [String]) {
        self.init(trusted: trusted, openAllowed: Set(openAllowedStrings.compactMap(PluginOrigin.init(string:))))
    }

    /// Trusts the origin of a plugin page about to be shown. False when the URL has no web origin.
    @discardableResult
    public mutating func trust(_ pageURL: URL) -> Bool {
        guard let origin = PluginOrigin(url: pageURL) else { return false }
        trusted.insert(origin)
        return true
    }

    public func isTrusted(_ origin: PluginOrigin) -> Bool { trusted.contains(origin) }

    public func isTrusted(_ pageURL: URL) -> Bool { PluginOrigin(url: pageURL).map(isTrusted) ?? false }

    /// A file the player would list in a folder: by extension, as the playlist and the open panel decide.
    public static func isMediaFile(_ url: URL) -> Bool {
        url.isFileURL && Playlist.videoExtensions.contains(url.pathExtension.lowercased())
    }

    public enum OpenDecision: Equatable, Sendable {
        /// Open it.
        case allowed
        /// Ask the user first; `allowOpening(from:)` then remembers the answer.
        case needsConsent
        /// Not a video file: refuse.
        case notMedia
        /// The page is not trusted: refuse.
        case untrusted
    }

    /// Whether the page at `origin` may open the local `file` now.
    public func decision(forOpening file: URL, from origin: PluginOrigin) -> OpenDecision {
        guard isTrusted(origin) else { return .untrusted }
        guard Self.isMediaFile(file) else { return .notMedia }
        return openAllowed.contains(origin) ? .allowed : .needsConsent
    }

    public mutating func allowOpening(from origin: PluginOrigin) {
        openAllowed.insert(origin)
    }

    /// The remembered origins for "plugin-open-allowed", in a stable order.
    public var openAllowedStrings: [String] { openAllowed.map(\.description).sorted() }

    /// The same as the `plugin-open-allowed` value: comma-separated.
    public var openAllowedText: String { openAllowedStrings.joined(separator: ",") }

    /// From the `plugin-open-allowed` value; spaces around the commas are fine, unreadable entries are dropped.
    public init(trusted: Set<PluginOrigin> = [], openAllowedText: String) {
        self.init(trusted: trusted, openAllowedStrings: openAllowedText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The question to ask before the first `open` from an origin.
    public static func consentQuestion(for origin: PluginOrigin) -> String {
        "Allow \(origin) to open files in FrameScrub?"
    }
}
