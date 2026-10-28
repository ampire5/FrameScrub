import Foundation

/// A place at the window's edge that holds views as tabs: the playlist, plugin pages (`slot-left` / `slot-right` /
/// `slot-bottom`).
public enum SlotEdge: String, CaseIterable, Sendable, Codable {
    case left, right, bottom

    /// The config key of this slot's setting.
    public var key: String { "slot-\(rawValue)" }

    /// Points the slot may take: its width for the sides, its height for the bottom.
    public var sizeRange: ClosedRange<Int> { self == .bottom ? 120...900 : 240...1200 }
}

/// A pinned slot takes its room from the video; an overlay slot lies over the video, which keeps its size.
public enum SlotMode: String, Sendable, Codable {
    case pinned, overlay
}

/// What an overlay slot shows behind its view. Pinned slots are always dark.
public enum SlotBackdrop: String, CaseIterable, Sendable, Codable {
    case dark, glass, clear

    public var next: SlotBackdrop {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// When an overlay slot goes away by itself.
public enum SlotAutoHide: String, CaseIterable, Sendable, Codable {
    /// Once its page starts something playing (or asks to hide); also Esc, ✕ and a click on the video.
    case afterChoice = "after-choice"
    /// The pointer left the slot a moment ago, as the Dock does.
    case mouseLeaves = "mouse-leaves"
    /// Only Esc, ✕, the slot's chord or a click on the video.
    case manual
}

/// How a hidden overlay slot comes back from its edge.
public enum SlotReveal: String, CaseIterable, Sendable, Codable {
    /// The pointer touching the edge brings it.
    case atOnce = "at-once"
    /// A tongue fades in as the pointer nears the edge; a click on it brings the slot.
    case tongue
}

/// The view a slot holds.
public enum SlotContent: Hashable, Sendable {
    case empty
    case playlist
    case plugin(name: String)

    init?(text: String) {
        switch text {
        case "empty": self = .empty
        case "playlist": self = .playlist
        case _ where text.hasPrefix("plugin:"):
            let name = Self.unescaped(String(text.dropFirst("plugin:".count))).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .plugin(name: name)
        default: return nil
        }
    }

    var text: String {
        switch self {
        case .empty: "empty"
        case .playlist: "playlist"
        case .plugin(let name): "plugin:\(Self.escaped(name))"
        }
    }

    /// A plugin's name holds the list's separator ` + ` as `%2B` (and `%` as `%25`), so it reads back as one entry.
    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " + ", with: " %2B ")
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "%2B", with: "+").replacingOccurrences(of: "%25", with: "%")
    }
}

/// One slot's saved state, written as `contents, mode, backdrop, auto-hide, size, shown|hidden, reveal`, e.g.
/// `plugin:Notes, overlay, glass, mouse-leaves, 560, hidden, at-once`. The contents are the slot's tabs joined by ` + `
/// (`playlist + plugin:Stash`), the shown one first; one tab is written as before, none as `empty`.
public struct SlotSetting: Equatable, Sendable {
    /// The tabs, the shown one first; never `.empty`, no duplicates.
    public var contents: [SlotContent]
    /// The shown tab, `.empty` for none. Setting it makes it the only tab (`.empty`: none).
    public var content: SlotContent {
        get { contents.first ?? .empty }
        set { contents = newValue == .empty ? [] : [newValue] }
    }
    public var mode: SlotMode
    public var backdrop: SlotBackdrop
    public var autoHide: SlotAutoHide
    /// Width for the side slots, height for the bottom one, in points.
    public var size: Int
    public var shown: Bool
    public var reveal: SlotReveal

    public init(content: SlotContent, mode: SlotMode, backdrop: SlotBackdrop, autoHide: SlotAutoHide, size: Int,
                shown: Bool, reveal: SlotReveal = .atOnce) {
        contents = content == .empty ? [] : [content]
        self.mode = mode
        self.backdrop = backdrop
        self.autoHide = autoHide
        self.size = size
        self.shown = shown
        self.reveal = reveal
    }

    /// An empty, hidden overlay slot.
    public static func `default`(for edge: SlotEdge) -> SlotSetting {
        SlotSetting(content: .empty, mode: .overlay, backdrop: .glass, autoHide: .mouseLeaves,
                    size: edge == .bottom ? 240 : 400, shown: false)
    }

    public init?(text: String) {
        // The last six fields are fixed; whatever comes before them is the content, so a plugin's name may hold a comma.
        var fields = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let reveal = fields.last.flatMap({ SlotReveal(rawValue: $0.lowercased()) }) else { return nil }
        fields.removeLast()
        guard fields.count >= 6 else { return nil }
        let tail = Array(fields.suffix(5))
        guard let contents = Self.contents(text: fields.dropLast(5).joined(separator: ",")),
              let mode = SlotMode(rawValue: tail[0].lowercased()),
              let backdrop = SlotBackdrop(rawValue: tail[1].lowercased()),
              let autoHide = SlotAutoHide(rawValue: tail[2].lowercased()),
              let size = Int(tail[3]) else { return nil }
        let shown: Bool
        switch tail[4].lowercased() {
        case "shown": shown = true
        case "hidden": shown = false
        default: return nil
        }
        self.init(content: .empty, mode: mode, backdrop: backdrop, autoHide: autoHide, size: size, shown: shown,
                  reveal: reveal)
        self.contents = contents
    }

    /// `playlist + plugin:Stash`: each entry must read; `empty` and repeats are dropped.
    private static func contents(text: String) -> [SlotContent]? {
        var list: [SlotContent] = []
        for part in text.components(separatedBy: " + ") {
            guard let content = SlotContent(text: part.trimmingCharacters(in: .whitespaces)) else { return nil }
            if content != .empty && !list.contains(content) { list.append(content) }
        }
        return list
    }

    public var text: String {
        [contents.isEmpty ? SlotContent.empty.text : contents.map(\.text).joined(separator: " + "), mode.rawValue, backdrop.rawValue, autoHide.rawValue, String(size), shown ? "shown" : "hidden",
         reveal.rawValue]
            .joined(separator: ", ")
    }

    /// This setting with its size inside the edge's range.
    public func clamped(for edge: SlotEdge) -> SlotSetting {
        var s = self
        s.size = min(max(size, edge.sizeRange.lowerBound), edge.sizeRange.upperBound)
        return s
    }
}

/// A plugin page the slots can show (`plugin=Name | URL`, repeatable).
public struct PluginEntry: Equatable, Sendable {
    public var name: String
    public var url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// `Name | URL`, split at the first ` | ` only (a URL's query may hold `|`). The URL is http(s) with a host or `file:`.
    public init?(line: String) {
        guard let bar = line.range(of: " | ") else { return nil }
        let name = line[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
        let address = line[bar.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let url = URL(string: address) else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https": guard url.host != nil else { return nil }
        case "file": break
        default: return nil
        }
        self.init(name: name, url: url)
    }
}

/// The slots of a config without `slot-*` keys.
public enum SlotDefaults {
    /// The name a `framescrub://` link's page is listed under.
    public static let linkPluginName = "Plugin"

    /// The playlist in the right slot, over the video; the others as `SlotSetting.default(for:)`.
    public static let standard: [SlotEdge: SlotSetting] = {
        var slots = Dictionary(uniqueKeysWithValues: SlotEdge.allCases.map { ($0, SlotSetting.default(for: $0)) })
        slots[.right]!.content = .playlist
        return slots
    }()
}
