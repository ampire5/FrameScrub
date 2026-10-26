import Foundation

/// The lengths of videos found while making their posters, by path, so a folder's cards show them after a relaunch
/// (the position store has lengths only for files that were played). One small JSON file; past `limit` entries the
/// file keeps the newest half.
public final class DurationStore: @unchecked Sendable {
    public static let defaultURL = ThumbnailStore.defaultDirectory.appendingPathComponent("posters/durations.json")

    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    /// The lengths, and the order they came in (oldest first) for trimming.
    private var lengths: [String: Double]?
    private var order: [String] = []

    public init(url: URL = DurationStore.defaultURL, limit: Int = 5000) {
        self.url = url
        self.limit = limit
    }

    /// Every length kept, read from the file the first time (a missing or broken file is an empty store).
    public func all() -> [String: Double] {
        lock.withLock { loadedLocked() }
    }

    public func set(_ seconds: Double, for path: String) {
        lock.withLock {
            var lengths = loadedLocked()
            if lengths[path] == nil { order.append(path) }
            lengths[path] = seconds
            if lengths.count > limit {
                let dropped = order.prefix(lengths.count - limit / 2)
                for path in dropped { lengths[path] = nil }
                order.removeFirst(dropped.count)
            }
            self.lengths = lengths
        }
    }

    /// Writes the file (atomically); failures are ignored, as the lengths are a convenience.
    public func save() {
        let lengths = lock.withLock { loadedLocked() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(lengths).write(to: url, options: .atomic)
    }

    private func loadedLocked() -> [String: Double] {
        if let lengths { return lengths }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        lengths = loaded
        order = Array(loaded.keys)
        return loaded
    }
}
