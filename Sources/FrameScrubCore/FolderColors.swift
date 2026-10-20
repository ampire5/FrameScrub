import Foundation
import os

/// Colour values (key → text value, as in `framescrub.conf`) that apply to a folder and everything below it, so
/// a folder of one shoot can be corrected differently from the next (colour memory spec §3–4). A folder's chain is
/// its own values, then each ancestor's; the caller picks the nearest per key. Keyed by standardized folder path,
/// the least recently touched folder dropped beyond `capacity`, kept in `folder-colors.json` across launches.
/// Changing is synchronous; the file is written once `writeDelay` after the last change and by `flush()` (the app
/// calls it on quit). Nothing is ever written into the video folders themselves. Main thread only.
public final class FolderColors {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameScrub/folder-colors.json")

    private struct Entry: Codable { var values: [String: String]; var touched: Int }

    private static let logger = Logger(subsystem: "local.framescrub", category: "FolderColors")

    private let url: URL?
    private let capacity: Int
    private let writeDelay: Double
    private let schedule: (Double, @escaping () -> Void) -> Void
    private var entries: [String: Entry] = [:]
    private var tick = 0
    /// Changed since the last successful write; a failed write leaves it set for the next one.
    private var dirty = false
    private var writeScheduled = false
    private var failureLogged = false
    /// How many times the file was written (for tests: debouncing coalesces).
    private(set) var writes = 0

    /// Loads the newest `capacity` folders from `url` (none when it is missing); a file that can't be read as
    /// the store is set aside as `<name>.broken-<unix time>` and the store starts empty. nil keeps everything in
    /// memory and never touches the disk.
    public init(url: URL? = FolderColors.defaultURL, capacity: Int = 1000, writeDelay: Double = 2,
                schedule: @escaping (Double, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.url = url
        self.capacity = max(1, capacity)
        self.writeDelay = writeDelay
        self.schedule = schedule
        guard let url, let data = try? Data(contentsOf: url) else { return }
        guard let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).broken-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            Self.logger.error("folder-colors.json could not be read, set aside as \(aside.lastPathComponent, privacy: .public)")
            return
        }
        entries = loaded.filter { !$0.value.values.isEmpty }
        tick = entries.values.map(\.touched).max() ?? 0
        for (path, _) in entries.sorted(by: { $0.value.touched > $1.value.touched }).dropFirst(self.capacity) {
            entries[path] = nil
        }
    }

    /// How many folders have values of their own.
    public var count: Int { entries.count }

    /// Nearest-first: the folder itself, then its ancestors (stopping at /Volumes/<name>), each folder's own values.
    public func chain(for folder: URL) -> [[String: String]] {
        Self.ancestors(of: folder).map { entries[$0]?.values ?? [:] }
    }

    /// Only what `folder` itself records, nothing inherited.
    public func own(for folder: URL) -> [String: String] {
        entries[folder.standardizedFileURL.path]?.values ?? [:]
    }

    /// Records `values` in `folder`, replacing the same keys and keeping the others.
    public func set(_ values: [String: String], for folder: URL) {
        change(folder) { $0.merge(values) { _, new in new } }
    }

    /// Removes `keys` from `folder`. A folder left with no values is forgotten.
    public func clear(_ keys: [String], for folder: URL) {
        change(folder) { values in for key in keys { values[key] = nil } }
    }

    /// Writes pending changes now; for quitting.
    public func flush() {
        write()
    }

    /// `folder` itself, then each parent up to the root; under `/Volumes/<name>` up to that volume only.
    public static func ancestors(of folder: URL) -> [String] {
        let components = folder.standardizedFileURL.pathComponents      // ["/", "Volumes", "share", …]
        let floor = components.count > 2 && components[1] == "Volumes" ? 3 : 1
        var chain: [String] = []
        var depth = components.count
        while depth >= floor {
            chain.append(depth == 1 ? "/" : "/" + components[1..<depth].joined(separator: "/"))
            depth -= 1
        }
        return chain
    }

    private func change(_ folder: URL, _ edit: (inout [String: String]) -> Void) {
        let key = folder.standardizedFileURL.path
        let before = entries[key]?.values ?? [:]
        var after = before
        edit(&after)
        guard after != before else { return }
        if after.isEmpty {
            entries[key] = nil
        } else {
            tick += 1
            entries[key] = Entry(values: after, touched: tick)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.touched < $1.value.touched }) {
                entries[oldest.key] = nil
            }
        }
        dirty = true
        guard url != nil, !writeScheduled else { return }
        writeScheduled = true
        schedule(writeDelay) { [weak self] in
            self?.writeScheduled = false
            self?.write()
        }
    }

    /// Colours are a convenience: a failed write keeps the values in memory, is logged once and is tried again
    /// with the next write (spec §8).
    private func write() {
        guard let url, dirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            dirty = false
            failureLogged = false
            writes += 1
        } catch {
            guard !failureLogged else { return }
            failureLogged = true
            Self.logger.error("folder-colors.json not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
