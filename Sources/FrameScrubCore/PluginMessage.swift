import Foundation

/// What a plugin page asks the player to open: a local file, or a Stash scene whose file is found on the shares.
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
/// command's arguments. Anything malformed is refused as a whole: a missing or mistyped argument, a negative time, a
/// segment that does not go forward, a relative path, an unknown command.
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

    public init?(json: [String: Any]) {
        guard let cmd = json["cmd"] as? String else { return nil }
        let number = { (key: String) -> Double? in
            guard let value = json[key] else { return nil }
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return .nan }
            return number.doubleValue
        }
        switch cmd {
        case "seek":
            guard let t = number("t"), let time = LinkTarget.time(t) else { return nil }
            self = .seek(time)
        case "play":
            self = .play
        case "pause":
            self = .pause
        case "step":
            guard let n = number("n"), n.isFinite, abs(n) < Double(Int32.max) else { return nil }
            self = .step(Int(n))
        case "loop":
            if json["a"] == nil && json["b"] == nil {
                self = .loop(nil)
            } else {
                guard let a = number("a"), let b = number("b"), let segment = LinkTarget.segment(a, b) else { return nil }
                self = .loop(segment)
            }
        case "open":
            guard let open = PluginOpen(json: json) else { return nil }
            self = .open(open)
        case "focusPlayer":
            self = .focusPlayer
        default:
            return nil
        }
    }
}

extension PluginOpen {
    /// `{path, t?, seg?: [a, b]}` or `{scene, paths, t?, seg?: [a, b]}`; a scene's id may come as a number.
    init?(json: [String: Any]) {
        var landing = LinkTarget()
        if let t = json["t"] {
            guard let number = t as? NSNumber, let time = LinkTarget.time(number.doubleValue) else { return nil }
            landing.time = time
        }
        if let seg = json["seg"] {
            guard let pair = seg as? [NSNumber], pair.count == 2,
                  let segment = LinkTarget.segment(pair[0].doubleValue, pair[1].doubleValue) else { return nil }
            landing.segment = segment
        }
        if let scene = json["scene"] {
            let id: String
            switch scene {
            case let text as String: id = text
            case let number as NSNumber: id = number.stringValue
            default: return nil
            }
            guard !id.isEmpty, let paths = json["paths"] as? [String], !paths.isEmpty else { return nil }
            self = .stashScene(id: id, paths: paths, landing: landing)
        } else if let path = json["path"] {
            guard let path = path as? String, path.hasPrefix("/") else { return nil }
            self = .file(URL(fileURLWithPath: path), landing: landing)
        } else {
            return nil
        }
    }
}
