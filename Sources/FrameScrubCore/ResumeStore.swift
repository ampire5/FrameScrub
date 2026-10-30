import Foundation
import Darwin

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
    /// Actual viewing time, independent of colour edits or background probes. Absent in legacy user records.
    public var lastViewedAt: Date?
    public var updated: Date

    public init(position: Double, loopA: Double? = nil, loopB: Double? = nil, marks: [[Double]]? = nil,
                duration: Double? = nil, color: [String: String]? = nil, lastViewedAt: Date? = nil, updated: Date = Date()) {
        self.position = position
        self.loopA = loopA
        self.loopB = loopB
        self.marks = marks
        self.duration = duration
        self.color = color
        self.updated = updated
        self.lastViewedAt = lastViewedAt
    }
}

/// Remembers where each file was left (and its A–B range) in a small JSON file. Keys are the path
/// plus the file size, so a different file saved under the same name starts fresh. Entries beyond
/// `limit` are dropped, oldest first. A missing or corrupt file behaves as an empty store.
public final class ResumeStore: @unchecked Sendable {
    /// The registry lock only selects a shared in-process snapshot. Never do I/O under it.
    private static let registryLock = NSLock()
    private final class WeakState {
        weak var value: State?
        init(_ value: State) { self.value = value }
    }
    private static var states: [URL: WeakState] = [:]

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let queue = DispatchQueue(label: "framescrub.resume-persistence", qos: .utility)
        let url: URL
        let write: @Sendable (Data, URL) throws -> Void
        var entries: [String: ResumeEntry] = [:]

        /// Only owned fields are written back. A position save carries a colour snapshot for the UI,
        /// but only setColor owns colour changes to an existing record (including a nil colour).
        struct Mutation {
            var saved: ResumeEntry?
            var colorWasSet = false
            var color: [String: String]?
            var colorUpdated: Date?
            var viewedAt: Date?

            var updated: Date {
                [saved?.updated, colorUpdated, viewedAt].compactMap { $0 }.max() ?? .distantPast
            }

            func followed(by newer: Mutation) -> Mutation {
                var result = self
                if var saved = newer.saved {
                    // Newer position fields win, while recency must not move backwards.
                    saved.updated = max(saved.updated, result.saved?.updated ?? saved.updated)
                    result.saved = saved
                }
                if newer.colorWasSet {
                    result.colorWasSet = true
                    result.color = newer.color
                    result.colorUpdated = newer.colorUpdated
                }
                result.viewedAt = [viewedAt, newer.viewedAt].compactMap { $0 }.max()
                return result
            }

            func applying(to baseline: ResumeEntry?) -> ResumeEntry? {
                // Clearing a colour that does not exist creates neither an entry nor an updated bump.
                guard saved != nil || viewedAt != nil || color != nil || baseline != nil else { return nil }
                var entry = baseline ?? ResumeEntry(position: 0, updated: updated)
                if let saved {
                    entry.position = saved.position
                    entry.loopA = saved.loopA
                    entry.loopB = saved.loopB
                    entry.marks = saved.marks
                    entry.duration = saved.duration
                    // A first save may seed colour. An existing disk entry owns its colour until setColor.
                    if baseline == nil { entry.color = saved.color }
                    entry.updated = max(entry.updated, saved.updated)
                }
                if colorWasSet, color != nil || entry.color != nil {
                    entry.color = color
                    entry.updated = max(entry.updated, colorUpdated ?? entry.updated)
                }
                entry.lastViewedAt = [entry.lastViewedAt, saved?.lastViewedAt, viewedAt].compactMap { $0 }.max()
                if let viewedAt { entry.updated = max(entry.updated, viewedAt) }
                return entry
            }
        }

        // Always retain field deltas, including after bootload. At most limit keys plus one in-flight batch.
        var pending: [String: Mutation] = [:]
        var loaded = false
        var started = false
        var limit: Int
        var scheduled = false

        init(url: URL, limit: Int, write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.url = url
            self.limit = limit
            self.write = write
        }

        private func readDisk() throws -> [String: ResumeEntry] {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { return [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([String: ResumeEntry].self, from: data)) ?? [:]
        }

        private static func bounded(_ entries: [String: ResumeEntry], to limit: Int) -> [String: ResumeEntry] {
            guard entries.count > limit else { return entries }
            return Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.updated > $1.value.updated }
                .prefix(limit).map { ($0.key, $0.value) })
        }

        private func overlay(_ mutations: [String: Mutation], on baseline: [String: ResumeEntry]) -> [String: ResumeEntry] {
            var result = baseline
            for (key, mutation) in mutations { result[key] = mutation.applying(to: result[key]) }
            return result
        }

        func start() {
            lock.withLock {
                guard !started else { return }
                started = true
                queue.async { self.bootstrap() }
            }
        }

        private func bootstrap() {
            let disk = (try? readDisk()) ?? [:]
            let baselineLimit = lock.withLock { limit }
            let baseline = Self.bounded(disk, to: baselineLimit)
            lock.withLock {
                entries = overlay(pending, on: baseline)
                trim(to: limit)
                loaded = true
            }
        }

        func awaitLoaded() {
            guard !Thread.isMainThread, !lock.withLock({ loaded }) else { return }
            queue.sync {} // Main never waits for bootload, flock or disk.
        }

        func trim(to limit: Int) {
            self.limit = limit
            entries = Self.bounded(entries, to: limit)
            if pending.count > limit {
                pending = Dictionary(uniqueKeysWithValues: pending.sorted { $0.value.updated > $1.value.updated }
                    .prefix(limit).map { ($0.key, $0.value) })
            }
        }

        func changed() {
            guard !scheduled else { return }
            scheduled = true
            queue.async { self.drain() }
        }

        /// Sidecar inode is stable across atomic replacement of positions.json. All participating
        /// processes hold it for the entire read/merge/replace transaction, only on their utility worker.
        private func withDiskTransaction<T>(_ body: () throws -> T) throws -> T {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }

        @discardableResult private func persistBatch() -> Bool {
            // Remove before any I/O. Foreground mutations now accumulate in a fresh bounded batch.
            let (batch, batchLimit) = lock.withLock {
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                return (batch, limit)
            }
            guard !batch.isEmpty else { return true }
            do {
                let durable = try withDiskTransaction {
                    let baseline = try readDisk()
                    let merged = Self.bounded(overlay(batch, on: baseline), to: batchLimit)
                    if merged != baseline {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        try write(encoder.encode(merged), url)
                    }
                    return Self.bounded(merged, to: batchLimit)
                }
                lock.withLock {
                    entries = overlay(pending, on: durable)
                    trim(to: limit)
                }
                return true
            } catch {
                lock.withLock {
                    // Failed older fields precede newer edits; nil colour clears must survive too.
                    for (key, older) in batch {
                        pending[key] = older.followed(by: pending[key] ?? Mutation())
                    }
                    trim(to: limit)
                }
                return false // Retry only on a later mutation or explicit flush, never a disk-error loop.
            }
        }

        func drain() {
            let succeeded = persistBatch()
            lock.withLock {
                if succeeded, !pending.isEmpty { queue.async { self.drain() } }
                else { scheduled = false }
            }
        }

        func flush() { _ = queue.sync { persistBatch() } }

        func flushAsync() async {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.persistBatch()
                    continuation.resume()
                }
            }
        }
    }

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameScrub/positions.json")
    public let url: URL
    public let limit: Int
    private let state: State

    public convenience init(url: URL = ResumeStore.defaultURL, limit: Int = 500) {
        self.init(url: url, limit: limit, write: { data, url in try data.write(to: url, options: .atomic) })
    }

    /// The writer belongs to the shared state, runs only on its utility queue, and must replace atomically.
    init(url: URL, limit: Int = 500, write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.url = url
        self.limit = max(0, limit)
        let key = url.standardizedFileURL
        if let existing = Self.registryLock.withLock({ Self.states[key]?.value }) {
            state = existing
        } else {
            let candidate = State(url: key, limit: self.limit, write: write)
            state = Self.registryLock.withLock {
                if let existing = Self.states[key]?.value { return existing }
                Self.states = Self.states.filter { $0.value.value != nil }
                Self.states[key] = WeakState(candidate)
                return candidate
            }
        }
        state.start()
        state.awaitLoaded()
    }

    /// Worker preparation warms persisted resume/colour data before the main actor opens the video.
    func prepare() { state.awaitLoaded() }

    /// `size`: the file's size when the caller has it open already (asking a NAS for it can take 0.2 s).
    /// Resolve unknown sizes before touching shared memory. UI callers should always supply the open-file size.
    public func entry(for video: URL, size: Int64? = nil) -> ResumeEntry? {
        guard let key = Self.key(for: video, size: size) else { return nil }
        state.awaitLoaded()
        return state.lock.withLock { state.entries[key] }
    }

    /// A single memory snapshot, with no media stats or state-file I/O.
    public func lastViewedAt(for files: [URL: Int64]) -> [URL: Date] {
        let keys = files.compactMap { video, size in Self.key(for: video, size: size).map { (video, $0) } }
        state.awaitLoaded()
        let snapshot = state.lock.withLock { state.entries }
        var result: [URL: Date] = [:]
        for (video, key) in keys { result[video] = snapshot[key]?.lastViewedAt }
        return result
    }

    /// Immediately visible across instances. Background saves are durable on return; main-thread saves
    /// enqueue a bounded, coalesced write and never wait for the persistence worker. Use flushViews()
    /// off-main when a caller needs a durability barrier (including tests checking the actual JSON).
    public func save(_ entry: ResumeEntry, for video: URL, size: Int64? = nil) {
        guard let key = Self.key(for: video, size: size) else { return }
        state.lock.withLock {
            var entry = entry
            entry.lastViewedAt = [entry.lastViewedAt, state.entries[key]?.lastViewedAt].compactMap { $0 }.max()
            if state.entries[key] == entry { return }
            // A carried snapshot cannot undo an authoritative clear. Presence of the record, not
            // presence of a colour value, decides whether save may seed colour in foreground memory.
            if let previous = state.entries[key] {
                entry.color = previous.color
                entry.updated = max(entry.updated, previous.updated)
            }
            let mutation = State.Mutation(saved: entry, viewedAt: entry.lastViewedAt)
            state.pending[key] = (state.pending[key] ?? State.Mutation()).followed(by: mutation)
            state.entries[key] = entry
            state.trim(to: limit)
            state.changed()
        }
        if !Thread.isMainThread { state.flush() }
    }

    public func color(for video: URL, size: Int64? = nil) -> [String: String]? {
        entry(for: video, size: size)?.color
    }

    /// Colour edits are visible immediately, independently of resumePlayback. Same durability policy as save.
    public func setColor(_ values: [String: String]?, for video: URL, size: Int64? = nil) {
        guard let key = Self.key(for: video, size: size) else { return }
        let changed = state.lock.withLock {
            var entry = state.entries[key] ?? ResumeEntry(position: 0)
            entry.color = values?.isEmpty == false ? values : nil
            entry.updated = Date()
            state.entries[key] = entry
            var mutation = state.pending[key] ?? State.Mutation()
            mutation.colorWasSet = true
            mutation.color = entry.color
            mutation.colorUpdated = entry.updated
            state.pending[key] = mutation
            state.trim(to: limit)
            state.changed()
            return true
        }
        if changed, !Thread.isMainThread { state.flush() }
    }

    /// First actual display and latest observed display on leave. The snapshot is updated immediately;
    /// only disk work is deferred. One writer per state URL coalesces all instances, bounded by limit.
    public func recordView(for video: URL, size: Int64, at date: Date = Date()) {
        guard limit > 0, let key = Self.key(for: video, size: size) else { return }
        state.lock.withLock {
            var entry = state.entries[key] ?? ResumeEntry(position: 0)
            if let previous = entry.lastViewedAt, previous >= date { return }
            entry.lastViewedAt = max(entry.lastViewedAt ?? date, date)
            entry.updated = max(entry.updated, date)
            state.entries[key] = entry
            var mutation = state.pending[key] ?? State.Mutation()
            mutation.viewedAt = max(mutation.viewedAt ?? date, date)
            state.pending[key] = mutation
            state.trim(to: limit)
            state.changed()
        }
    }

    /// Await after the final close/save before allowing application termination. The caller's actor
    /// stays responsive while the worker finishes all mutations visible when the barrier executes.
    /// Like save, persistence is best effort; an unavailable volume must not interrupt playback.
    public func flush() async { await state.flushAsync() }

    /// Worker/test synchronization for all writes, not just history. Never wait for disk on main.
    func flushViews() {
        precondition(!Thread.isMainThread, "Flush resume persistence on a worker")
        state.flush()
    }

    static func key(for video: URL, size known: Int64? = nil) -> String? {
        let size = known ?? ((try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? NSNumber)?.int64Value
        guard let size else { return nil }
        return "\(video.standardizedFileURL.path)|\(size)"
    }
}
