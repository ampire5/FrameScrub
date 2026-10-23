import Foundation

/// What a plugin page asks the player to open: a local file, or a Stash scene whose file is found on the shares (or
/// streamed); `paths` is empty when the page gave none and they are to be asked of Stash.
public enum PluginOpen: Equatable, Sendable {
    case file(URL, landing: LinkTarget)
    case stashScene(id: String, paths: [String], landing: LinkTarget)

    public var landing: LinkTarget {
        switch self {
        case let .file(_, landing), let .stashScene(_, _, landing): landing
        }
    }
}

/// A command from a plugin page, decoded from the JSON object its `window.framescrub` bridge posts: `cmd` plus the
/// command's arguments. Anything malformed is refused as a whole, with a reason: a missing or mistyped argument, a
/// negative time, a segment that does not go forward, a relative path, an unknown command.
public enum PluginMessage: Equatable, Sendable {
    case seek(Double)
    case play
    case pause
    /// Frames forward (negative: backward).
    case step(Int)
    /// A new A-B loop, or nil to clear it.
    case loop(ClosedRange<Double>?)
    case open(PluginOpen)
    /// Keys go to the player again.
    case focusPlayer
    /// Requests with an answer (`PluginInfo`, `PluginMarks`, `PluginPlaylist`, `PluginFrame`); they need a file open.
    case info
    case marks
    case playlist
    case frame(PluginFrameRequest)

    /// Why a message was refused; the text reaches the page (a rejected promise, or an `error` event).
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    public init?(json: [String: Any]) {
        guard case let .success(message) = Self.parse(json) else { return nil }
        self = message
    }

    public static func parse(_ json: [String: Any]) -> Result<PluginMessage, Failure> {
        guard let cmd = json["cmd"] as? String else { return .failure(Failure("cmd must be a string")) }
        do {
            return .success(try parse(cmd, json))
        } catch {
            return .failure(Failure("\(cmd): \(error.reason)"))
        }
    }

    private static func parse(_ cmd: String, _ json: [String: Any]) throws(Failure) -> PluginMessage {
        let args = Arguments(json)
        switch cmd {
        case "seek":
            return .seek(try args.time("t"))
        case "play":
            return .play
        case "pause":
            return .pause
        case "step":
            let n = try args.number("n")
            guard abs(n) < Double(Int32.max) else { throw Failure("n is out of range") }
            return .step(Int(n))
        case "loop":
            if json["a"] == nil && json["b"] == nil { return .loop(nil) }
            return .loop(try args.segment("a", "b"))
        case "open":
            return .open(try PluginOpen(args))
        case "focusPlayer":
            return .focusPlayer
        case "info":
            return .info
        case "marks":
            return .marks
        case "playlist":
            return .playlist
        case "frame":
            return .frame(try PluginFrameRequest(args))
        default:
            throw Failure("unknown command")
        }
    }
}

/// The JSON arguments of a message, read with the checks every command shares.
struct Arguments {
    let json: [String: Any]
    init(_ json: [String: Any]) { self.json = json }

    typealias Failure = PluginMessage.Failure

    func has(_ key: String) -> Bool { json[key] != nil }

    /// A finite number; nil when absent.
    func optionalNumber(_ key: String) throws(Failure) -> Double? {
        guard let value = json[key] else { return nil }
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw Failure("\(key) must be a number") }
        return number.doubleValue
    }

    func number(_ key: String) throws(Failure) -> Double {
        guard let value = try optionalNumber(key) else { throw Failure("\(key) is missing") }
        return value
    }

    /// A position in seconds: finite, not negative.
    func time(_ key: String) throws(Failure) -> Double {
        guard let time = LinkTarget.time(try number(key)) else { throw Failure("\(key) must not be negative") }
        return time
    }

    func optionalTime(_ key: String) throws(Failure) -> Double? {
        try has(key) ? time(key) : nil
    }

    /// `a...b` from two numbers.
    func segment(_ a: String, _ b: String) throws(Failure) -> ClosedRange<Double> {
        guard let segment = LinkTarget.segment(try number(a), try number(b)) else {
            throw Failure("\(b) must be above \(a), and \(a) not negative")
        }
        return segment
    }

    /// `a...b` from a `[a, b]` pair; nil when absent.
    func optionalSegmentPair(_ key: String) throws(Failure) -> ClosedRange<Double>? {
        guard let value = json[key] else { return nil }
        guard let pair = value as? [NSNumber], pair.count == 2,
              let segment = LinkTarget.segment(pair[0].doubleValue, pair[1].doubleValue) else {
            throw Failure("\(key) must be [a, b] with b above a")
        }
        return segment
    }

    func string(_ key: String) throws(Failure) -> String {
        guard let value = json[key] else { throw Failure("\(key) is missing") }
        guard let text = value as? String else { throw Failure("\(key) must be a string") }
        return text
    }
}

extension PluginOpen {
    /// `{path, t?, seg?: [a, b]}` or `{scene, paths?, t?, seg?: [a, b]}`; a scene's id may come as a number.
    init(_ args: Arguments) throws(PluginMessage.Failure) {
        let landing = LinkTarget(time: try args.optionalTime("t"), segments: try args.optionalSegmentPair("seg").map { [$0] } ?? [])
        if let scene = args.json["scene"] {
            let id: String
            switch scene {
            case let text as String: id = text
            case let number as NSNumber: id = number.stringValue
            default: throw PluginMessage.Failure("scene must be a string or a number")
            }
            guard !id.isEmpty else { throw PluginMessage.Failure("scene is empty") }
            var paths: [String] = []
            if let given = args.json["paths"], !(given is NSNull) {
                guard let list = given as? [String] else { throw PluginMessage.Failure("paths must be an array of strings") }
                paths = list
            }
            self = .stashScene(id: id, paths: paths, landing: landing)
        } else if args.has("path") {
            let path = try args.string("path")
            guard path.hasPrefix("/") else { throw PluginMessage.Failure("path must be absolute") }
            self = .file(URL(fileURLWithPath: path), landing: landing)
        } else {
            throw PluginMessage.Failure("path or scene is missing")
        }
    }
}

/// A message with the id the page's `request()` gave it; a message sent with a verb has none and expects no reply.
public struct PluginRequest: Equatable, Sendable {
    public var id: Int?
    public var message: PluginMessage

    public init(id: Int? = nil, message: PluginMessage) {
        self.id = id
        self.message = message
    }

    /// The id of a posted object, when it carries one (`id` as a number).
    public static func id(of json: [String: Any]) -> Int? {
        guard let number = json["id"] as? NSNumber, number.doubleValue.isFinite,
              abs(number.doubleValue) < Double(Int32.max) else { return nil }
        return number.intValue
    }
}

/// The answer to a `request()`: its id with a result (JSON text, or nothing) or a reason it failed.
public struct PluginReply: Equatable, Sendable {
    public let id: Int
    public let result: String?
    public let error: String?

    public static func success(_ id: Int, result: String? = nil) -> PluginReply {
        PluginReply(id: id, result: result, error: nil)
    }

    public static func failure(_ id: Int, _ reason: String) -> PluginReply {
        PluginReply(id: id, result: nil, error: reason)
    }
}

/// What the player tells the page besides its state: `framescrub.on<name>` and a `framescrub<name>` window event.
public enum PluginEvent: Equatable, Sendable {
    /// The panel took the keyboard / gave it back to the player.
    case focus
    case blur
    /// A file is open (after an `open`, a link, or the user's own choice); `source` says whether it is read from a
    /// file or from Stash's stream.
    case fileOpened(path: String?, scene: String?, source: PluginSource)
    /// A command sent without an id failed.
    case error(String)

    public var name: String {
        switch self {
        case .focus: "focus"
        case .blur: "blur"
        case .fileOpened: "fileopened"
        case .error: "error"
        }
    }

    /// The event's detail as JSON; nil for an event without one.
    public var detail: String? {
        switch self {
        case .focus, .blur:
            return nil
        case let .fileOpened(path, scene, source):
            return PluginJSON.encode(FileOpened(path: path, scene: scene, source: source))
        case let .error(reason):
            return PluginJSON.encode(reason)
        }
    }

    private struct FileOpened: Encodable {
        var path: String?
        var scene: String?
        var source: PluginSource

        enum CodingKeys: String, CodingKey { case path, scene, source }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)   // nil as null, not an absent key
            try c.encode(scene, forKey: .scene)
            try c.encode(source, forKey: .source)
        }
    }
}

/// Where the open file's bytes come from, as the page hears it (`fileopened`, `info`).
public enum PluginSource: String, Codable, Equatable, Sendable {
    case file
    case stream

    /// `stream` for a URL read over HTTP.
    public init(url: URL) {
        self = ByteSources.isRemote(url) ? .stream : .file
    }
}

/// JSON as the bridge sends it: sorted keys, slashes as they are; nil when a number is not finite.
public enum PluginJSON {
    public static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
