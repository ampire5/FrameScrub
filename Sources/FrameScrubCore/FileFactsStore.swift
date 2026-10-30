import Foundation
import HomeScreenModel

/// Addressed facade over the disposable catalog. No whole-library loading and no JSON import. These synchronous
/// methods run on picture/inspector workers; the main actor keeps only the facts of its current view.
public final class FileFactsStore: @unchecked Sendable {
    public static let defaultURL = MediaCatalog.defaultURL
    public static let shared = FileFactsStore()
    private let catalog: MediaCatalog
    private let writes = DispatchQueue(label: "framescrub.catalog-writes", qos: .utility)
    private let pendingLock = NSLock()
    private var pending: [String: MediaCatalog.Record] = [:]
    private var inFlight: [String: MediaCatalog.Record] = [:]
    private var scheduled = false
    // At most 128 snapshots (32 MiB at the per-record cap); one timer and one writer, regardless of input rate.
    private static let pendingLimit = 128
    public init(url: URL = FileFactsStore.defaultURL, limit: Int = 50_000) {
        catalog = url == Self.defaultURL ? .shared : MediaCatalog(url: url, limits: .init(metadataEntries: limit))
    }
    public func metadata(for url: URL) -> MediaMetadata? {
        guard let id = MediaFileIdentity.read(url) else { return nil }
        return metadata(for: [id])[id]
    }
    public func metadata(for identities: [MediaFileIdentity]) -> [MediaFileIdentity: MediaMetadata] {
        var result: [MediaFileIdentity: MediaMetadata] = [:]
        for start in stride(from: 0, to: identities.count, by: 128) {
            let ids = Array(identities[start..<min(start + 128, identities.count)])
            // Snapshot the handoff buffers before reading SQL: a commit/removal between those steps cannot create
            // a false miss. New pending records take precedence over a batch currently being written.
            let buffered = pendingLock.withLock { () -> [MediaFileIdentity: MediaCatalog.Record] in
                var buffered: [MediaFileIdentity: MediaCatalog.Record] = [:]
                for id in ids {
                    if let record = pending[id.path] ?? inFlight[id.path], record.identity == id { buffered[id] = record }
                }
                return buffered
            }
            var found = (try? catalog.records(ids, readerVersion: MediaMetadata.readerVersion)) ?? [:]
            found.merge(buffered) { _, buffered in buffered }
            for (id, record) in found {
                if let value = try? JSONDecoder().decode(MediaMetadata.self, from: record.payload),
                   value.readerVersion == MediaMetadata.readerVersion { result[id] = value }
            }
        }
        return result
    }
    public func facts(for urls: [URL]) -> [String: FileFacts] {
        let ids = urls.compactMap(MediaFileIdentity.read)
        return Dictionary(metadata(for: ids).map { ($0.key.path, $0.value.facts) }, uniquingKeysWith: { a, _ in a })
    }
    public func store(_ value: MediaMetadata, identity: MediaFileIdentity) {
        guard value.readerVersion == MediaMetadata.readerVersion,
              let bytes = try? JSONEncoder().encode(value), bytes.count <= 256 * 1024 else { return }
        let schedule = pendingLock.withLock {
            if pending.count >= Self.pendingLimit, pending[identity.path] == nil, let oldest = pending.keys.first {
                pending[oldest] = nil   // disposable cache: bound memory rather than stall a foreground open
            }
            pending[identity.path] = .init(identity: identity, readerVersion: value.readerVersion, payload: bytes)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule {
            writes.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
                drain()
                pendingLock.withLock { scheduled = false }
                // An arrival while draining remains queued for the next read or this final drain.
                drain()
            }
        }
    }
    /// Worker-only read barrier, also used before disposing an explicitly scoped store in tests/maintenance.
    public func flushWrites() { writes.sync { drain() } }

    private func drain() {
        let batch = pendingLock.withLock { () -> [MediaCatalog.Record] in
            let values = Array(pending.values)
            inFlight = pending
            pending.removeAll(keepingCapacity: true)
            return values
        }
        defer { pendingLock.withLock { inFlight.removeAll(keepingCapacity: true) } }
        guard !batch.isEmpty else { return }
        do { try catalog.put(batch) }
        catch MediaCatalog.Failure.stale {
            // One replaced file must not discard independent valid snapshots from the same burst.
            for record in batch { try? catalog.put([record]) }
        } catch { /* A disposable cache failure must not prevent playback. */ }
    }
}
