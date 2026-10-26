import Foundation

/// What a plugin page says about an item it opens (`info` of `open` and of playlist items): shown as a Stash scene's
/// details are (`StashTitle`'s `Title — Studio · date`), and, for a stream, which has no file name of its own, the name
/// its exported frames and clips get: `<date> [<code>] <title> (<performers>)`, the parts there are.
public struct SceneInfo: Equatable, Sendable {
    public var title: String?
    public var studio: String?
    public var performers: [String]
    /// `YYYY-MM-DD`.
    public var date: String?
    /// The page's own id of the item (a scene id, a catalogue code).
    public var code: String?
    /// Where the item lives on the page's site.
    public var url: URL?

    public init(title: String? = nil, studio: String? = nil, performers: [String] = [], date: String? = nil,
                code: String? = nil, url: URL? = nil) {
        self.title = title
        self.studio = studio
        self.performers = performers
        self.date = date
        self.code = code
        self.url = url
    }

    static let maxText = 500
    static let maxPerformers = 50

    /// As `StashTitle.text`: the title (or `fallback`), then ` — studio` and ` · date`.
    public func displayTitle(fallback: String) -> String {
        var text = title ?? fallback
        if let studio { text += " — " + studio }
        if let date { text += " · " + date }
        return text
    }

    /// A file-name stem from what there is; nil with neither a title nor a code.
    public var fileStem: String? {
        guard title != nil || code != nil else { return nil }
        var parts: [String] = []
        if let date { parts.append(date) }
        if let code { parts.append("[\(code)]") }
        if let title { parts.append(title) }
        if !performers.isEmpty { parts.append("(\(performers.joined(separator: ", ")))") }
        return Self.safeFileName(parts.joined(separator: " "))
    }

    /// The URL exports name a stream after (`%{video-name}`, the fallback folder): a file name made of `fileStem`.
    /// Nil for a file (it keeps its own name, as a Stash scene's file does) or when there is nothing to name it by.
    public func namingURL(for source: URL) -> URL? {
        guard !source.isFileURL, let stem = fileStem, !stem.isEmpty else { return nil }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        return URL(filePath: "/" + stem + "." + ext, directoryHint: .notDirectory)
    }

    /// No path separators, colons or control characters; single spaces; at most 200 characters.
    static func safeFileName(_ text: String) -> String {
        var out = text.replacingOccurrences(of: ":", with: " -").replacingOccurrences(of: "/", with: "-")
        out = String(out.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if out.count > 200 { out = String(out.prefix(200)).trimmingCharacters(in: .whitespaces) }
        return out.hasPrefix(".") ? "_" + out.dropFirst() : out
    }
}

extension SceneInfo {
    /// `{title?, studio?, performers?, date?, code?, url?}`: strings up to 500 characters, at most 50 performers, a
    /// `YYYY-MM-DD` date, an http(s) url; anything else refuses the message.
    init(_ args: Arguments) throws(PluginMessage.Failure) {
        func text(_ key: String) throws(PluginMessage.Failure) -> String? {
            guard args.given(key) else { return nil }
            let value = try args.string(key)
            guard value.count <= Self.maxText else {
                throw PluginMessage.Failure("\(key) is longer than \(Self.maxText) characters")
            }
            return value.isEmpty ? nil : value
        }
        self.init(title: try text("title"), studio: try text("studio"), date: try text("date"), code: try text("code"))
        if let date, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            throw PluginMessage.Failure("date must be YYYY-MM-DD")
        }
        if args.given("performers") {
            guard let list = args.json["performers"] as? [String], list.count <= Self.maxPerformers,
                  list.allSatisfy({ $0.count <= Self.maxText }) else {
                throw PluginMessage.Failure("performers must be a list of strings")
            }
            performers = list.filter { !$0.isEmpty }
        }
        if args.given("url") { url = try args.streamURL("url") }
    }
}

extension Arguments {
    /// `info`, when given: an object (`SceneInfo`).
    func sceneInfo() throws(Failure) -> SceneInfo? {
        guard given("info") else { return nil }
        guard let object = json["info"] as? [String: Any] else { throw Failure("info must be an object") }
        do {
            return try SceneInfo(Arguments(object))
        } catch {
            throw Failure("info: \(error.reason)")
        }
    }
}

extension PluginMessage {
    /// The `info` of an `open`, or of each item of a `playlist` / `enqueue`, by the URL it opens (a stream's, or a
    /// path's file URL); empty for anything else. For a message `parse` accepted (it checked each `info`).
    public static func sceneInfos(_ json: [String: Any]) -> [URL: SceneInfo] {
        var found: [URL: SceneInfo] = [:]
        func note(_ object: [String: Any]) {
            let args = Arguments(object)
            guard let info = try? args.sceneInfo() else { return }
            if let url = try? args.streamURL("url") {
                found[url] = info
            } else if let path = object["path"] as? String {
                found[URL(filePath: path, directoryHint: .notDirectory)] = info
            }
        }
        switch json["cmd"] as? String {
        case "open": note(json)
        case "setPlaylist", "enqueue": (json["items"] as? [[String: Any]])?.forEach(note)
        default: break
        }
        return found
    }
}
