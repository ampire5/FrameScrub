import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FileFactsStoreTests {
    @Test func storesCompleteProbeAndInvalidatesReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: Fixtures.url(Fixtures.h264), to: media)
        let id = try #require(MediaFileIdentity.read(media))
        let value = try MediaSource(url: media).metadata
        let db = dir.appendingPathComponent("facts.sqlite")
        let store = FileFactsStore(url: db)
        store.store(value, identity: id)
        store.flushWrites()
        #expect(FileFactsStore(url: db).metadata(for: media) == value)
        #expect(store.facts(for: [media])[media.path] == value.facts)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: media.path)
        #expect(store.metadata(for: media) == nil)
    }
    @Test func oldJSONIsLeftUntouchedAndNotImported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("facts.json")
        let data = Data("{}".utf8)
        try data.write(to: old)
        _ = FileFactsStore(url: dir.appendingPathComponent("facts.sqlite")).facts(for: [])
        #expect(try Data(contentsOf: old) == data)
    }
    @Test func oneStaleSnapshotDoesNotDiscardOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.mp4")
        try Data([1]).write(to: a); try Data([2]).write(to: b)
        let ia = try #require(MediaFileIdentity.read(a)), ib = try #require(MediaFileIdentity.read(b))
        let metadata = try MediaSource(url: Fixtures.url(Fixtures.h264)).metadata
        let store = FileFactsStore(url: dir.appendingPathComponent("catalog.sqlite"))
        store.store(metadata, identity: ia)
        store.store(metadata, identity: ib)
        try Data([3,4]).write(to: a, options: .atomic)
        store.flushWrites()
        #expect(store.metadata(for: b) == metadata)
        #expect(store.metadata(for: a) == nil)
    }
}
