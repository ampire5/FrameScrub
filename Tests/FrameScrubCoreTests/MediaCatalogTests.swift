import Foundation
import CSQLite
import Testing
@testable import FrameScrubCore

@Suite struct MediaCatalogTests {
    private func setup() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = dir.appendingPathComponent("clip.mp4")
        try Data([1, 2, 3]).write(to: media)
        return (dir.appendingPathComponent("catalog.sqlite"), media)
    }
    @Test func persistenceAndAbsentFieldsAreChecked() throws {
        let (db, url) = try setup()
        let id = try #require(MediaFileIdentity.read(url))
        let catalog = MediaCatalog(url: db)
        try catalog.put([.init(identity: id, readerVersion: 2, payload: Data("{}".utf8))])
        let reopened = MediaCatalog(url: db)
        #expect(try reopened.records([id], readerVersion: 2)[id]?.payload == Data("{}".utf8))
        #expect(try reopened.records([id], readerVersion: 3).isEmpty)
    }
    @Test func sameSizeReplacementAndMtimeInvalidate() throws {
        let (db, url) = try setup()
        let old = try #require(MediaFileIdentity.read(url))
        let c = MediaCatalog(url: db)
        try c.put([.init(identity: old, readerVersion: 1, payload: Data([1]))])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: url.path)
        let changed = try #require(MediaFileIdentity.read(url))
        #expect(old != changed)
        #expect(try c.records([changed], readerVersion: 1).isEmpty)
        try Data([4, 5, 6]).write(to: url, options: .atomic)
        let replaced = try #require(MediaFileIdentity.read(url))
        #expect(replaced != changed)
        #expect(try c.records([replaced], readerVersion: 1).isEmpty)
        #expect(throws: (any Error).self) { try c.put([.init(identity: old, readerVersion: 1, payload: Data([2]))]) }
    }
    @Test func imagesAreBoundedAndNamespaced() throws {
        let (db, url) = try setup()
        let id = try #require(MediaFileIdentity.read(url))
        let c = MediaCatalog(url: db, limits: .init(metadataEntries: 2, metadataBytes: 128, imageBytes: 20, imageEntryBytes: 12))
        try c.putImage(Data(repeating: 1, count: 10), identity: id, variant: "poster", limit: 2)
        try c.putImage(Data(repeating: 2, count: 10), identity: id, variant: "recent", limit: 2)
        #expect(try c.image(id, variant: "poster") == Data(repeating: 1, count: 10))
        #expect(throws: (any Error).self) { try c.putImage(Data(count: 13), identity: id, variant: "large", limit: 2) }
        try c.putImage(Data(count: 10), identity: id, variant: "third", limit: 2)
        #expect(try c.imageBytes() <= 20)
    }
    @Test func corruptCacheRecoversAndLeavesUserData() throws {
        let (db, url) = try setup()
        try Data("invalid sqlite".utf8).write(to: db)
        let state = db.deletingLastPathComponent().appendingPathComponent("positions.json")
        try Data("user state".utf8).write(to: state)
        let id = try #require(MediaFileIdentity.read(url))
        let c = MediaCatalog(url: db)
        try c.put([.init(identity: id, readerVersion: 1, payload: Data([3]))])
        #expect(try c.records([id], readerVersion: 1).count == 1)
        #expect(try String(contentsOf: state, encoding: .utf8) == "user state")
        #expect(FileManager.default.fileExists(atPath: db.path + ".corrupt-last"))
    }
    @Test func metadataBudgetAndBatchRollback() throws {
        let (db, url) = try setup()
        let a = try #require(MediaFileIdentity.read(url))
        let other = url.deletingLastPathComponent().appendingPathComponent("other.mp4")
        try Data([4]).write(to: other)
        let b = try #require(MediaFileIdentity.read(other))
        let c = MediaCatalog(url: db, limits: .init(metadataEntries: 1, metadataBytes: 20, metadataTotalBytes: 20))
        try c.put([.init(identity: a, readerVersion: 1, payload: Data(count: 10)),
                   .init(identity: b, readerVersion: 1, payload: Data(count: 10))])
        #expect(try c.records([a,b], readerVersion: 1).count == 1)
        #expect(throws: (any Error).self) {
            try c.put([.init(identity: a, readerVersion: 1, payload: Data(count: 10)),
                       .init(identity: b, readerVersion: 1, payload: Data(count: 21))])
        }
        #expect(try c.records([a,b], readerVersion: 1)[b]?.payload.count == 10)
    }
    @Test func initializationDoesNotCreateAFile() throws {
        let (db, _) = try setup()
        _ = MediaCatalog(url: db)
        #expect(!FileManager.default.fileExists(atPath: db.path))
    }
    @Test func clearImagesKeepsMetadataAndUserState() async throws {
        let (db, url) = try setup()
        let id = try #require(MediaFileIdentity.read(url))
        let catalog = MediaCatalog(url: db)
        let state = db.deletingLastPathComponent().appendingPathComponent("positions.json")
        try Data("history".utf8).write(to: state)
        try catalog.put([.init(identity: id, readerVersion: 2, payload: Data([7]))])
        try catalog.putImage(Data([8]), identity: id, variant: "poster", limit: 10)
        let before = try catalog.statistics()
        #expect(before.images == 1 && before.metadata == 1 && before.imageBytes == 1)
        try await catalog.clearImages()
        #expect(try catalog.statistics().images == 0)
        #expect(try catalog.records([id], readerVersion: 2).count == 1)
        try await catalog.clear()
        #expect(try catalog.statistics().metadata == 0)
        #expect(try String(contentsOf: state, encoding: .utf8) == "history")
    }
    @Test func cleanupDropsMissingLocalFilesOnly() async throws {
        let (db, url) = try setup()
        let id = try #require(MediaFileIdentity.read(url))
        let catalog = MediaCatalog(url: db)
        try catalog.put([.init(identity: id, readerVersion: 2, payload: Data([7]))])
        try catalog.putImage(Data([8]), identity: id, variant: "poster", limit: 10)
        #expect(try await catalog.cleanUpLocalFiles() == 0)
        try FileManager.default.removeItem(at: url)
        #expect(try await catalog.cleanUpLocalFiles() == 2)
        #expect(try catalog.statistics().images == 0)
        #expect(try catalog.statistics().metadata == 0)
    }

    @Test func explicitClearReclaimsDiskInBoundedSteps() async throws {
        let (db, url) = try setup()
        let id = try #require(MediaFileIdentity.read(url))
        let catalog = MediaCatalog(url: db)
        try catalog.putImage(Data(repeating: 8, count: 2 * 1024 * 1024), identity: id, variant: "poster", limit: 10)
        _ = try catalog.reclaimStep()
        let before = try catalog.statistics().diskBytes
        try await catalog.clearImages()
        var steps = 0
        while try catalog.reclaimStep() {
            steps += 1
            #expect(steps < 100)
            if steps >= 100 { break }
        }
        #expect(try catalog.statistics().diskBytes < before / 2)
    }

    @Test func legacyRebuildRequiresExplicitClearPermission() async throws {
        let (db, url) = try setup()
        var connection: OpaquePointer?
        #expect(sqlite3_open(db.path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "CREATE TABLE legacy_marker(value INTEGER)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        let id = try #require(MediaFileIdentity.read(url))
        let catalog = MediaCatalog(url: db)
        try catalog.putImage(Data(repeating: 8, count: 2 * 1024 * 1024), identity: id, variant: "poster", limit: 10)
        _ = try catalog.reclaimStep()
        let before = try catalog.statistics().diskBytes
        #expect(try await catalog.cleanUpLocalFiles() == 0)
        _ = try catalog.reclaimStep() // cleanup may not rebuild a populated legacy cache
        #expect(try catalog.statistics().images == 1)
        try await catalog.clearImages()
        while try catalog.reclaimStep(allowLegacyRebuild: true) {}
        #expect(try catalog.statistics().diskBytes < before / 2)
    }

}
