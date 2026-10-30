import Foundation
import Testing
@testable import FrameScrubCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_CATALOG_BENCH"] == "1"))
struct MediaCatalogBench {
    @Test func addressedReadsAndImageStorage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try MediaSource(url: Fixtures.url(Fixtures.h264))
        let payload = try JSONEncoder().encode(source.metadata)
        // A real fixture frame, encoded by the production store, is the JPEG payload for both storage candidates.
        let result = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.h264), at: nil))
        let store = ThumbnailStore(directory: dir.appendingPathComponent("seed"), limit: 10, maxSide: 480)
        store.save(result.picture, for: Fixtures.url(Fixtures.h264), context: .init(options: nil))
        let imageCatalog = MediaCatalog(url: store.directory.appendingPathComponent("catalog.sqlite"))
        let seed = try #require(MediaFileIdentity.read(Fixtures.url(Fixtures.h264)))
        let jpeg = try #require(try imageCatalog.image(seed, variant: "seed-480-v3-jpeg-q80"))
        let catalog = MediaCatalog(url: dir.appendingPathComponent("bench.sqlite"))
        var ids: [MediaFileIdentity] = []
        for i in 0..<256 {
            let file = dir.appendingPathComponent("clip-\(i).mp4")
            try Data([0]).write(to: file)
            ids.append(try #require(MediaFileIdentity.read(file)))
        }
        func measure(_ name: String, _ work: () throws -> Void) rethrows {
            let start = Date(), cpu = StartupTrace.threadCPU()
            try work()
            print("CATALOG_BENCH \(name): wall=\(Date().timeIntervalSince(start)*1000)ms cpu=\(StartupTrace.threadCPU()-cpu)ms")
        }
        try measure("batch metadata write 256") {
            try catalog.put(ids.map { .init(identity: $0, readerVersion: MediaMetadata.readerVersion, payload: payload) })
        }
        try measure("JPEG blobs write 256") {
            for id in ids { try catalog.putImage(jpeg, identity: id, variant: "poster", limit: 256) }
        }
        try measure("JPEG files write 256") {
            for i in ids.indices { try jpeg.write(to: dir.appendingPathComponent("image-\(i).jpg"), options: .atomic) }
        }
        let fresh = MediaCatalog(url: dir.appendingPathComponent("bench.sqlite"))
        try measure("first addressed metadata + JPEG read") {
            _ = try fresh.records([ids[0]], readerVersion: MediaMetadata.readerVersion)
            _ = try fresh.image(ids[0], variant: "poster")
        }
        for round in 1...5 {
            try measure("round \(round) addressed metadata + JPEG 256") {
                _ = try fresh.records(ids, readerVersion: MediaMetadata.readerVersion)
                for id in ids { _ = try fresh.image(id, variant: "poster") }
            }
            try measure("round \(round) JPEG files read 256") {
                for i in ids.indices { _ = try Data(contentsOf: dir.appendingPathComponent("image-\(i).jpg")) }
            }
        }
        print("CATALOG_BENCH jpegBytes=\(jpeg.count), metadataBytes=\(payload.count)")
    }
    @Test func productionWritesAtCapacity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("capacity.sqlite")
        let catalog = MediaCatalog(url: db)
        _ = try catalog.records([], readerVersion: 1) // initialize schema
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seed.arguments = [db.path, "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<50000) INSERT INTO metadata SELECT 'cached-'||n, 'identity', 1, X'7B7D', n FROM seq;"]
        try seed.run(); seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)
        let url = dir.appendingPathComponent("clip.mp4")
        try Data([0]).write(to: url)
        let identity = try #require(MediaFileIdentity.read(url))
        let snapshot = try MediaSource(url: Fixtures.url(Fixtures.h264)).metadata
        let facade = FileFactsStore(url: db)
        for round in 1...5 {
            let start = Date(), cpu = StartupTrace.threadCPU()
            for _ in 0..<100 {
                facade.store(snapshot, identity: identity)
                facade.flushWrites() // worst case: no burst coalescing, as isolated foreground opens
            }
            print("CATALOG_BENCH capacity round \(round), 100 isolated stores: wall=\(Date().timeIntervalSince(start)*1000)ms cpu=\(StartupTrace.threadCPU()-cpu)ms")
        }
    }
}
