import Foundation

public struct ResumeEntry: Codable, Equatable, Sendable {
    public var position: Double
    public var loopA: Double?
    public var loopB: Double?
    /// Cut marks in seconds: `[start, end]` per segment, `[start]` for the open one (cut marks spec §6).
    public var marks: [[Double]]?
    /// The file's length in seconds, for the progress bar on the start screen (nil when unknown).
    public var duration: Double?
    /// The file's own colour values (`auto-color`, `auto-color-strength`, `vibrance-on`, `vibrance`), as the config spells them (colour memory spec §4).
    public var color: [String: String]?
    public var updated: Date

    public init(position: Double, loopA: Double? = nil, loopB: Double? = nil, marks: [[Double]]? = nil,
                duration: Double? = nil, color: [String: String]? = nil, updated: Date = Date()) {
        self.position = position
        self.loopA = loopA
        self.loopB = loopB
        self.marks = marks
        self.duration = duration
        self.color = color
        self.updated = updated
    }
}

/// Remembers where each file was left (and its A–B range) in a small JSON file. Keys are the path
/// plus the file size, so a different file saved under the same name starts fresh. Entries beyond
/// `limit` are dropped, oldest first. A missing or corrupt file behaves as an empty store.
public final class ResumeStore {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameScrub/positions.json")

    public let url: URL
    public let limit: Int
    private var entries: [String: ResumeEntry]?

    public init(url: URL = ResumeStore.defaultURL, limit: Int = 500) {
        self.url = url
        self.limit = limit
    }

    /// `size`: the file's size when the caller has it open already (asking a NAS for it can take 0.2 s).
    public func entry(for video: URL, size: Int64? = nil) -> ResumeEntry? {
        Self.key(for: video, size: size).flatMap { load()[$0] }
    }

    public func save(_ entry: ResumeEntry, for video: URL, size: Int64? = nil) {
        guard let key = Self.key(for: video, size: size) else { return }
        entries = nil   // re-read: the start screen may have filled a length since this store last looked
        var all = load()
        all[key] = entry
        trim(&all)
        entries = all
        persist(all)
    }

    private func trim(_ all: inout [String: ResumeEntry]) {
        guard all.count > limit else { return }
        for (stale, _) in all.sorted(by: { $0.value.updated < $1.value.updated }).prefix(all.count - limit) {
            all[stale] = nil
        }
    }

    /// The file's colour values; nil when none or the size can't be read.
    public func color(for video: URL, size: Int64? = nil) -> [String: String]? {
        entry(for: video, size: size)?.color
    }

    /// Replaces the file's colour values (nil / empty removes them; nothing to remove is a no-op), keeping or creating its entry (new entry: position 0).
    /// Written at once and independent of `resume-playback`: a colour edit must not wait for the position to be saved.
    public func setColor(_ values: [String: String]?, for video: URL, size: Int64? = nil) {
        guard let key = Self.key(for: video, size: size) else { return }
        entries = nil
        var all = load()
        // Clearing what is not there changes nothing: no new entry, no `updated` bump, no write.
        if values?.isEmpty != false, all[key]?.color == nil { return }
        var entry = all[key] ?? ResumeEntry(position: 0)
        entry.color = values?.isEmpty == false ? values : nil
        entry.updated = Date()
        all[key] = entry
        trim(&all)
        entries = all
        persist(all)
    }

    static func key(for video: URL, size known: Int64? = nil) -> String? {
        let size = known ?? ((try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? NSNumber)?.int64Value
        guard let size else { return nil }
        return "\(video.standardizedFileURL.path)|\(size)"
    }

    private func load() -> [String: ResumeEntry] {
        if let entries { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: ResumeEntry].self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }

    /// Positions are a convenience: failing to store them must never interrupt playback.
    private func persist(_ all: [String: ResumeEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
