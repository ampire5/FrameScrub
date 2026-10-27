import Foundation

/// One entry of a list a plugin page gave as the playlist: a media-server scene, a local file or an http(s) stream.
/// `time` (seconds) is where it starts whenever it is opened, over the remembered position; nil leaves that.
public enum PlaylistItem: Equatable, Sendable {
    case scene(id: String, title: String?, time: Double? = nil)
    case file(URL, title: String?, time: Double? = nil)
    case stream(URL, title: String?, time: Double? = nil)

    public var title: String? {
        switch self {
        case .scene(_, let title, _), .file(_, let title, _), .stream(_, let title, _): title
        }
    }

    public var time: Double? {
        switch self {
        case .scene(_, _, let time), .file(_, _, let time), .stream(_, _, let time): time
        }
    }
}

/// The playlist as an ordered list (a plugin's `playlist(...)`), instead of the open file's folder. Next / previous
/// stop at the ends.
public struct ListPlaylist: Equatable, Sendable {
    public static let maxItems = 2000

    public private(set) var items: [PlaylistItem]
    public private(set) var currentIndex: Int
    public var name: String?

    /// Nil when `items` is empty or `index` is not one of them; items past `maxItems` are dropped.
    public init?(items: [PlaylistItem], index: Int = 0, name: String? = nil) {
        let items = Array(items.prefix(Self.maxItems))
        guard items.indices.contains(index) else { return nil }
        self.items = items
        currentIndex = index
        self.name = name
    }

    public var current: PlaylistItem { items[currentIndex] }
    public var next: PlaylistItem? { items.indices.contains(currentIndex + 1) ? items[currentIndex + 1] : nil }
    public var previous: PlaylistItem? { currentIndex > 0 ? items[currentIndex - 1] : nil }

    /// Moves to the next item; nil (staying put) at the end.
    public mutating func advance() -> PlaylistItem? { select(currentIndex + 1) }

    /// Moves to the previous item; nil (staying put) at the start.
    public mutating func goBack() -> PlaylistItem? { select(currentIndex - 1) }

    /// Moves to `index`; nil (staying put) when there is no such item.
    public mutating func select(_ index: Int) -> PlaylistItem? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        return items[index]
    }

    /// Adds `more` at the end, up to `maxItems`; returns how many were added.
    public mutating func append(_ more: [PlaylistItem]) -> Int {
        let taken = more.prefix(Self.maxItems - items.count)
        items += taken
        return taken.count
    }

    /// "3 / 10".
    public var positionText: String { "\(currentIndex + 1) / \(items.count)" }

    /// The items whose row title holds `filter` (case- and accent-insensitive), and the current one; blank keeps all.
    public func indices(matching filter: String) -> [Int] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(items.indices) }
        return items.indices.filter { $0 == currentIndex || PlaylistRow(items[$0]).title.localizedStandardContains(needle) }
    }

    /// A page's `enqueue(more)`: added to the end of `list`, or, with the folder as the playlist, a new list of the
    /// `current` item (none open: nothing) and `more`. Nil when nothing would be in it or it would pass `maxItems`:
    /// the call is refused whole.
    public static func enqueue(_ more: [PlaylistItem], onto list: ListPlaylist?, current: PlaylistItem?) -> ListPlaylist? {
        guard var list else {
            let items = (current.map { [$0] } ?? []) + more
            return items.count <= maxItems ? ListPlaylist(items: items) : nil
        }
        guard list.items.count + more.count <= maxItems else { return nil }
        _ = list.append(more)
        return list
    }
}

/// One line of the playlist panel.
public struct PlaylistRow: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    /// The local file, for its picture and facts; nil for a scene or a stream.
    public let url: URL?

    public init(title: String, subtitle: String? = nil, url: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.url = url
    }

    /// A folder's file: its name.
    public init(file: URL) { self.init(title: file.lastPathComponent, url: file) }

    /// A list item: the title the page gave, else the file's name, "Scene <id>", or the stream's last path component
    /// (its host when the path has none).
    public init(_ item: PlaylistItem) {
        let given = item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch item {
        case let .scene(id, _, _): self.init(title: given ?? "Scene \(id)")
        case let .file(url, _, _): self.init(title: given ?? url.lastPathComponent, url: url)
        case let .stream(url, _, _):
            let name = url.lastPathComponent
            self.init(title: given ?? (name.isEmpty || name == "/" ? url.host ?? url.absoluteString : name))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

