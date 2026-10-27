import Foundation
import HomeScreenModel

/// The facts of videos learned while making their posters (size, codec, rate, length: `FileFacts`), by path, so a
/// folder's cards show them after a relaunch (the position store has lengths only for files that were played). One
/// small JSON file; past `limit` entries the file keeps the newest half.
public final class FileFactsStore: @unchecked Sendable {
    public static let defaultURL = ThumbnailStore.defaultDirectory.appendingPathComponent("posters/facts.json")
    /// The app's one store: Home's cards and the playlist strip read and write the same file.
    public static let shared = FileFactsStore()

    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    /// The facts, and the order they came in (oldest first) for trimming.
    private var facts: [String: FileFacts]?
    private var order: [String] = []

    public init(url: URL = FileFactsStore.defaultURL, limit: Int = 5000) {
        self.url = url
        self.limit = limit
    }

    /// Every file's facts, read from the file the first time (a missing or broken file is an empty store).
    public func all() -> [String: FileFacts] {
        lock.withLock { loadedLocked() }
    }

    public func set(_ new: FileFacts, for path: String) {
        lock.withLock {
            var facts = loadedLocked()
            if facts[path] == nil { order.append(path) }
            facts[path] = new
            if facts.count > limit {
                let dropped = order.prefix(facts.count - limit / 2)
                for path in dropped { facts[path] = nil }
                order.removeFirst(dropped.count)
            }
            self.facts = facts
        }
    }

    /// Writes the file (atomically); failures are ignored, as the facts are a convenience.
    public func save() {
        let facts = lock.withLock { loadedLocked() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(facts).write(to: url, options: .atomic)
    }

    private func loadedLocked() -> [String: FileFacts] {
        if let facts { return facts }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: FileFacts].self, from: $0) } ?? [:]
        facts = loaded
        order = Array(loaded.keys)
        return loaded
    }
}
