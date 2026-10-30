import CSQLite
import Darwin
import Foundation

/// A snapshot taken before reading a file. Device and inode catch replacement even when size and dates are copied.
/// Read on a worker; URLs keep their reached path, so aliases do not silently change user-facing locations.
public struct MediaFileIdentity: Codable, Hashable, Sendable {
    public let path: String
    public let device: Int64
    public let inode: Int64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public static func read(_ url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        var value = stat()
        guard fstatat(AT_FDCWD, url.path, &value, 0) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        return Self(path: url.standardizedFileURL.path, device: Int64(value.st_dev), inode: Int64(bitPattern: value.st_ino),
                    size: value.st_size, modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
    var key: String { "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)" }
    var isCurrent: Bool { Self.read(URL(fileURLWithPath: path)) == self }
}

/// Disposable SQLite cache. All synchronous methods are worker-only: callers use their existing bounded utility
/// queues. Opening is lazy; there is no scan of media or old JSON, nor any dependency on user-state storage.
public final class MediaCatalog: @unchecked Sendable {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/FrameScrub/media.sqlite")
    public static let shared = MediaCatalog(limits: .init(imageBytes: configuredImageLimitMiB() * 1024 * 1024))
    public static func configuredImageLimitMiB(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: "thumbnail-cache-mib") != nil else { return 256 }
        return min(65536, max(16, defaults.integer(forKey: "thumbnail-cache-mib")))
    }
    public struct Limits: Sendable {
        public var metadataEntries: Int
        public var metadataTotalBytes: Int
        public var metadataBytes: Int
        public var imageBytes: Int
        public var imageEntryBytes: Int
        // Disk budgets, not allocation targets. Each decoded image remains owned by the visible UI only.
        public init(metadataEntries: Int = 50_000, metadataBytes: Int = 256 * 1024, metadataTotalBytes: Int = 64 * 1024 * 1024,
                    imageBytes: Int = 256 * 1024 * 1024, imageEntryBytes: Int = 4 * 1024 * 1024) {
            self.metadataEntries = max(1, metadataEntries); self.metadataBytes = max(1, metadataBytes)
            self.metadataTotalBytes = max(1, metadataTotalBytes)
            self.imageBytes = max(1, imageBytes); self.imageEntryBytes = max(1, imageEntryBytes)
        }
    }
    public struct Record: Sendable {
        public let identity: MediaFileIdentity
        public let readerVersion: Int
        public let payload: Data
        public init(identity: MediaFileIdentity, readerVersion: Int, payload: Data) {
            self.identity = identity; self.readerVersion = readerVersion; self.payload = payload
        }
    }
    public enum Failure: Error { case sqlite(Int32, String), stale, oversized, newerSchema }
    private let url: URL
    private let limits: Limits
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL = MediaCatalog.defaultURL, limits: Limits = .init()) { self.url = url; self.limits = limits }
    deinit { if let db { sqlite3_close(db) } }

    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try connect() } catch Failure.sqlite(let code, _) where code == SQLITE_NOTADB || code == SQLITE_CORRUPT {
            if let db { sqlite3_close(db); self.db = nil }
            // Move only this disposable cache's files. Do not touch user state or unrelated files.
            let suffix = ".corrupt-last" // retain at most one disposable recovery snapshot
            for tail in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + tail)
                let backup = URL(fileURLWithPath: url.path + suffix + tail)
                if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.moveItem(at: file, to: backup)
                }
            }
            try connect()
        } catch {
            if let db { sqlite3_close(db); self.db = nil }
            throw error
        }
    }
    private func connect() throws {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        db = connection
        guard code == SQLITE_OK else { throw failure(code) }
        sqlite3_busy_timeout(db, 200)
        try sql("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA journal_size_limit=4194304;")
        let version = try scalar("PRAGMA user_version")
        guard version <= 1 else { throw Failure.newerSchema }
        try sql("""
        CREATE TABLE IF NOT EXISTS metadata(path TEXT PRIMARY KEY, identity TEXT NOT NULL, reader INTEGER NOT NULL,
          payload BLOB NOT NULL, used REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS metadata_used ON metadata(used);
        CREATE TABLE IF NOT EXISTS images(path TEXT NOT NULL, identity TEXT NOT NULL, variant TEXT NOT NULL,
          payload BLOB NOT NULL, bytes INTEGER NOT NULL, used REAL NOT NULL, PRIMARY KEY(path, variant));
        CREATE INDEX IF NOT EXISTS images_used ON images(used);
        CREATE TABLE IF NOT EXISTS totals(kind TEXT PRIMARY KEY, bytes INTEGER NOT NULL);
        INSERT OR IGNORE INTO totals VALUES('images',0),('metadata',0);
        CREATE TRIGGER IF NOT EXISTS image_add AFTER INSERT ON images BEGIN UPDATE totals SET bytes=bytes+NEW.bytes WHERE kind='images'; END;
        CREATE TRIGGER IF NOT EXISTS image_remove AFTER DELETE ON images BEGIN UPDATE totals SET bytes=bytes-OLD.bytes WHERE kind='images'; END;
        CREATE TRIGGER IF NOT EXISTS metadata_add AFTER INSERT ON metadata BEGIN UPDATE totals SET bytes=bytes+length(NEW.payload) WHERE kind='metadata'; END;
        CREATE TRIGGER IF NOT EXISTS metadata_remove AFTER DELETE ON metadata BEGIN UPDATE totals SET bytes=bytes-length(OLD.payload) WHERE kind='metadata'; END;
        CREATE TABLE IF NOT EXISTS counts(kind TEXT PRIMARY KEY, entries INTEGER NOT NULL);
        INSERT INTO counts SELECT 'metadata',(SELECT COUNT(*) FROM metadata)
          WHERE NOT EXISTS(SELECT 1 FROM counts WHERE kind='metadata');
        INSERT INTO counts SELECT 'images',(SELECT COUNT(*) FROM images)
          WHERE NOT EXISTS(SELECT 1 FROM counts WHERE kind='images');
        CREATE TRIGGER IF NOT EXISTS image_count_add AFTER INSERT ON images BEGIN UPDATE counts SET entries=entries+1 WHERE kind='images'; END;
        CREATE TRIGGER IF NOT EXISTS image_count_remove AFTER DELETE ON images BEGIN UPDATE counts SET entries=entries-1 WHERE kind='images'; END;
        CREATE TRIGGER IF NOT EXISTS metadata_count_add AFTER INSERT ON metadata BEGIN UPDATE counts SET entries=entries+1 WHERE kind='metadata'; END;
        CREATE TRIGGER IF NOT EXISTS metadata_count_remove AFTER DELETE ON metadata BEGIN UPDATE counts SET entries=entries-1 WHERE kind='metadata'; END;
        PRAGMA recursive_triggers=ON;
        PRAGMA user_version=1;
        """)
    }
    private func failure(_ code: Int32) -> Failure { .sqlite(code, db.map { String(cString: sqlite3_errmsg($0)) } ?? "open") }
    private func sql(_ text: String) throws {
        let code = sqlite3_exec(db, text, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }
    private func statement(_ text: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        let code = sqlite3_prepare_v2(db, text, -1, &s, nil)
        guard code == SQLITE_OK, let s else { throw failure(code) }
        return s
    }
    private func bind(_ text: String, _ index: Int32, _ s: OpaquePointer) { sqlite3_bind_text(s, index, text, -1, transient) }
    private func bind(_ data: Data, _ index: Int32, _ s: OpaquePointer) {
        if data.isEmpty { sqlite3_bind_zeroblob(s, index, 0) }
        else { _ = data.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32(data.count), transient) } }
    }
    private func done(_ s: OpaquePointer) throws {
        let code = sqlite3_step(s); guard code == SQLITE_DONE else { throw failure(code) }
    }
    private func data(_ s: OpaquePointer, _ column: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(s, column))
        guard n > 0, let bytes = sqlite3_column_blob(s, column) else { return Data() }
        return Data(bytes: bytes, count: n)
    }
    private func scalar(_ text: String) throws -> Int {
        let s = try statement(text); defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s); guard code == SQLITE_ROW else { throw failure(code) }
        return Int(sqlite3_column_int64(s, 0))
    }

    /// Exact identities only; each indexed lookup touches one record, irrespective of catalog size. Empty results
    /// mean missing/stale/unprobed, whereas an encoded metadata object with nil fields is a completed probe.
    public func records(_ identities: [MediaFileIdentity], readerVersion: Int) throws -> [MediaFileIdentity: Record] {
        try lock.withLock {
            try open()
            let s = try statement("SELECT payload FROM metadata WHERE path=? AND identity=? AND reader=?")
            defer { sqlite3_finalize(s) }
            var result: [MediaFileIdentity: Record] = [:]
            for id in identities {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                bind(id.path, 1, s); bind(id.key, 2, s); sqlite3_bind_int64(s, 3, Int64(readerVersion))
                let code = sqlite3_step(s)
                if code == SQLITE_ROW { result[id] = Record(identity: id, readerVersion: readerVersion, payload: data(s, 0)) }
                else if code != SQLITE_DONE { throw failure(code) }
            }
            return result
        }
    }
    /// A bounded batch is one transaction. Recheck each source after probing: never label old bytes as a new file.
    public func put(_ records: [Record]) throws {
        guard records.count <= 256 else { throw Failure.oversized }
        // Stat can wait on a disconnected share. Do it before the SQL lock, so independent local reads can proceed.
        for record in records {
            guard record.payload.count <= limits.metadataBytes else { throw Failure.oversized }
            guard record.identity.isCurrent else { throw Failure.stale }
        }
        try lock.withLock {
            try open(); try sql("BEGIN IMMEDIATE")
            do {
                let s = try statement("INSERT OR REPLACE INTO metadata VALUES(?,?,?,?,?)")
                defer { sqlite3_finalize(s) }
                for record in records {
                    sqlite3_reset(s); sqlite3_clear_bindings(s)
                    bind(record.identity.path, 1, s); bind(record.identity.key, 2, s)
                    sqlite3_bind_int64(s, 3, Int64(record.readerVersion)); bind(record.payload, 4, s)
                    sqlite3_bind_double(s, 5, Date().timeIntervalSince1970); try done(s)
                }
                let excess = try scalar("SELECT entries FROM counts WHERE kind='metadata'") - limits.metadataEntries
                if excess > 0 {
                    try sql("DELETE FROM metadata WHERE path IN (SELECT path FROM metadata ORDER BY used LIMIT \(excess))")
                }
                while try scalar("SELECT bytes FROM totals WHERE kind='metadata'") > limits.metadataTotalBytes {
                    try sql("DELETE FROM metadata WHERE path=(SELECT path FROM metadata ORDER BY used LIMIT 1)")
                }
                try sql("COMMIT")
            } catch { try? sql("ROLLBACK"); throw error }
        }
    }
    public func image(_ id: MediaFileIdentity, variant: String) throws -> Data? {
        try lock.withLock {
            try open()
            let s = try statement("SELECT payload FROM images WHERE path=? AND identity=? AND variant=?")
            defer { sqlite3_finalize(s) }
            bind(id.path, 1, s); bind(id.key, 2, s); bind(variant, 3, s)
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw failure(code) }
            return data(s, 0)
        }
    }
    public func hasImage(_ id: MediaFileIdentity, variant: String) throws -> Bool {
        try lock.withLock {
            try open()
            let s = try statement("SELECT 1 FROM images WHERE path=? AND identity=? AND variant=?")
            defer { sqlite3_finalize(s) }
            bind(id.path, 1, s); bind(id.key, 2, s); bind(variant, 3, s)
            let code = sqlite3_step(s)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw failure(code) }
            return code == SQLITE_ROW
        }
    }
    public func putImage(_ bytes: Data, identity id: MediaFileIdentity, variant: String, limit: Int) throws {
        guard bytes.count <= limits.imageEntryBytes, bytes.count <= limits.imageBytes else { throw Failure.oversized }
        guard id.isCurrent else { throw Failure.stale }
        try lock.withLock {
            try open()
            try sql("BEGIN IMMEDIATE")
            do {
                let s = try statement("INSERT OR REPLACE INTO images VALUES(?,?,?,?,?,?)")
                defer { sqlite3_finalize(s) }
                bind(id.path, 1, s); bind(id.key, 2, s); bind(variant, 3, s); bind(bytes, 4, s)
                sqlite3_bind_int64(s, 5, Int64(bytes.count)); sqlite3_bind_double(s, 6, Date().timeIntervalSince1970)
                try done(s)
                let prune = try statement("DELETE FROM images WHERE rowid IN (SELECT rowid FROM images WHERE variant=? ORDER BY used DESC LIMIT -1 OFFSET ?)")
                defer { sqlite3_finalize(prune) }
                bind(variant, 1, prune); sqlite3_bind_int64(prune, 2, Int64(max(1, limit))); try done(prune)
                while try scalar("SELECT bytes FROM totals WHERE kind='images'") > limits.imageBytes {
                    try sql("DELETE FROM images WHERE rowid=(SELECT rowid FROM images ORDER BY used LIMIT 1)")
                }
                try sql("COMMIT")
            } catch { try? sql("ROLLBACK"); throw error }
        }
    }
    public func imageBytes() throws -> Int {
        try lock.withLock { try open(); return try scalar("SELECT bytes FROM totals WHERE kind='images'") }
    }
    public struct Statistics: Sendable {
        public let images: Int
        public let metadata: Int
        public let imageBytes: Int
        public let diskBytes: Int64
    }
    public func statistics() throws -> Statistics {
        let counts = try lock.withLock {
            try open()
            return (try scalar("SELECT entries FROM counts WHERE kind='images'"), try scalar("SELECT entries FROM counts WHERE kind='metadata'"),
                    try scalar("SELECT bytes FROM totals WHERE kind='images'"))
        }
        let disk = ["", "-wal", "-shm"].reduce(Int64(0)) { total, tail in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path + tail)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return Statistics(images: counts.0, metadata: counts.1, imageBytes: counts.2, diskBytes: disk)
    }
    public func clearImages() async throws {
        try await clearTables(["images"])
    }
    private func lastRow(in table: String) throws -> Int64 {
        try lock.withLock { try open(); return Int64(try scalar("SELECT COALESCE(MAX(rowid),0) FROM \(table)")) }
    }
    private func clearBatch(_ table: String, after cursor: Int64, through last: Int64) throws -> Int64? {
        try lock.withLock {
            try open()
            // At most 8 image payloads (4 MiB each) or 128 metadata records per transaction.
            let count = table == "images" ? 8 : 128
            let query = try statement("SELECT rowid FROM \(table) WHERE rowid>? AND rowid<=? ORDER BY rowid LIMIT \(count)")
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int64(query, 1, cursor); sqlite3_bind_int64(query, 2, last)
            var ids: [Int64] = []
            while true {
                let code = sqlite3_step(query)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw failure(code) }
                ids.append(sqlite3_column_int64(query, 0))
            }
            guard let next = ids.last else { return nil }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let deletion = try statement("DELETE FROM \(table) WHERE rowid IN (\(placeholders))")
            defer { sqlite3_finalize(deletion) }
            for (offset, id) in ids.enumerated() { sqlite3_bind_int64(deletion, Int32(offset + 1), id) }
            try done(deletion)
            try sql("PRAGMA wal_checkpoint(PASSIVE)")
            return next
        }
    }
    private func clearTables(_ tables: [String]) async throws {
        for table in tables {
            let last = try lastRow(in: table)
            var cursor: Int64 = 0
            // Advance even if another writer reuses a deleted rowid: a clear is a finite snapshot operation.
            while let next = try clearBatch(table, after: cursor, through: last) {
                cursor = next
                await Task.yield()
            }
        }
        try maintain()
    }
    /// Explicit cleanup only. Offline and network volumes are skipped: absence there does not prove deletion.
    /// Read at most 128 rows at once, with filesystem checks outside the SQL lock.
    public func cleanUpLocalFiles() async throws -> Int {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) ?? []
        var devices: [Int64: URL] = [:]
        for volume in volumes where (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
            var st = stat()
            if fstatat(AT_FDCWD, volume.path, &st, 0) == 0 { devices[Int64(st.st_dev)] = volume }
        }
        var removed = 0
        for table in ["images", "metadata"] {
            let lastRow: Int64 = try lock.withLock { try open(); return Int64(try scalar("SELECT COALESCE(MAX(rowid),0) FROM \(table)")) }
            var cursor: Int64 = 0
            while true {
                let batch: [(Int64, String, String)] = try lock.withLock {
                    try open()
                    let count = table == "images" ? 8 : 128
                    let query = try statement("SELECT rowid,path,identity FROM \(table) WHERE rowid>? AND rowid<=? ORDER BY rowid LIMIT \(count)")
                    defer { sqlite3_finalize(query) }
                    sqlite3_bind_int64(query, 1, cursor); sqlite3_bind_int64(query, 2, lastRow)
                    var rows: [(Int64, String, String)] = []
                    while true {
                        let code = sqlite3_step(query)
                        if code == SQLITE_DONE { break }
                        guard code == SQLITE_ROW else { throw failure(code) }
                        rows.append((sqlite3_column_int64(query, 0), String(cString: sqlite3_column_text(query, 1)),
                                     String(cString: sqlite3_column_text(query, 2))))
                    }
                    return rows
                }
                guard let last = batch.last else { break }
                cursor = last.0
                let stale = batch.filter { row in
                    guard let deviceText = row.2.split(separator: ":").first, let device = Int64(deviceText), let volume = devices[device] else { return false }
                    var st = stat()
                    let result = fstatat(AT_FDCWD, row.1, &st, 0)
                    let lookupError = errno
                    var root = stat()
                    guard fstatat(AT_FDCWD, volume.path, &root, 0) == 0 && Int64(root.st_dev) == device else { return false }
                    if result != 0 {
                        return lookupError == ENOENT || lookupError == ENOTDIR
                    }
                    guard let actual = MediaFileIdentity.read(URL(fileURLWithPath: row.1)) else { return false }
                    return actual.key != row.2
                }
                try lock.withLock {
                    let deletion = try statement("DELETE FROM \(table) WHERE rowid=? AND identity=? AND path=?")
                    defer { sqlite3_finalize(deletion) }
                    for row in stale {
                        sqlite3_reset(deletion); sqlite3_clear_bindings(deletion)
                        sqlite3_bind_int64(deletion, 1, row.0); bind(row.2, 2, deletion); bind(row.1, 3, deletion)
                        try done(deletion); removed += Int(sqlite3_changes(db))
                    }
                    if !stale.isEmpty { try sql("PRAGMA wal_checkpoint(PASSIVE)") }
                }
                await Task.yield()
            }
        }
        try maintain()
        return removed
    }
    /// Reclaim reusable pages in bounded steps; invoke after an explicit cache cleanup or an idle batch.
    public func maintain() throws {
        try lock.withLock { try open(); try sql("PRAGMA wal_checkpoint(PASSIVE); PRAGMA incremental_vacuum(128)") }
    }
    /// Explicit cleanup reclaims in chunks. Return true only when another step can make progress.
    /// Callers yield between steps so a foreground lookup can acquire the connection.
    public func reclaimStep(allowLegacyRebuild: Bool = false) throws -> Bool {
        try lock.withLock {
            try open()
            // The initial experimental schema enabled auto-vacuum after WAL created the file, which SQLite
            // ignores. An explicit clear is the only place we convert that disposable legacy cache. SQLite
            // uses its disk-backed temporary database; no media decoding or in-memory payload copy is involved.
            if allowLegacyRebuild, try scalar("PRAGMA auto_vacuum") == 0 {
                try sql("PRAGMA auto_vacuum=INCREMENTAL; VACUUM")
            }
            let before = try scalar("PRAGMA freelist_count")
            if before > 0 { try sql("PRAGMA incremental_vacuum(256)") }
            try sql("PRAGMA wal_checkpoint(TRUNCATE)")
            let after = try scalar("PRAGMA freelist_count")
            return after > 0 && after < before
        }
    }
    public func clear() async throws {
        try await clearTables(["images", "metadata"])
    }
}
