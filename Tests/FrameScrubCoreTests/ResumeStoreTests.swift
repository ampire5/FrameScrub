import Foundation
import Darwin
import Testing
@testable import FrameScrubCore

@Suite struct ResumeStoreTests {
    private func store(limit: Int = 500) -> ResumeStore {
        ResumeStore(url: makeTemporaryDirectory().appendingPathComponent("positions.json"), limit: limit)
    }

    /// Simulate another process: read only durable bytes under the same sidecar protocol, never
    /// construct a ResumeStore (which would join this process's shared snapshot).
    private func externalTransaction(at url: URL, _ edit: (inout [String: ResumeEntry]) -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        var entries = (try? durableEntries(at: url)) ?? [:]
        edit(&entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    private func durableEntries(at url: URL) throws -> [String: ResumeEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: ResumeEntry].self, from: Data(contentsOf: url))
    }

    private func videoCopy() throws -> URL {
        let url = makeTemporaryDirectory().appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: Fixtures.url(Fixtures.withAudio), to: url)
        return url
    }

    @Test func roundTripsThroughTheFile() async throws {
        let s = store()
        let video = try videoCopy()
        let entry = ResumeEntry(position: 12.5, loopA: 1, loopB: 2, duration: 40, updated: Date(timeIntervalSince1970: 1_000_000))
        s.save(entry, for: video)
        await s.flush()
        // Copy durable bytes to a new URL: reopening must exercise bootloading, not the shared cache.
        let reopenedURL = makeTemporaryDirectory().appendingPathComponent("positions.json")
        try Data(contentsOf: s.url).write(to: reopenedURL)
        let reloaded = ResumeStore(url: reopenedURL)
        await reloaded.flush()
        #expect(reloaded.entry(for: video) == entry)
    }

    @Test func marksRoundTripAndAreOptional() throws {
        let s = store()
        let video = try videoCopy()
        let entry = ResumeEntry(position: 3, marks: [[1, 2], [5]], updated: Date(timeIntervalSince1970: 1_000_000))
        s.save(entry, for: video)
        #expect(ResumeStore(url: s.url).entry(for: video)?.marks == [[1, 2], [5]])
        let bare = #"{"position": 3, "updated": 0}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ResumeEntry.self, from: bare).marks == nil)
        #expect(try JSONDecoder().decode(ResumeEntry.self, from: bare).duration == nil)
    }

    @Test func aSaveKeepsWhatAnotherStoreWroteMeanwhile() throws {
        let player = store()
        let other = ResumeStore(url: player.url)
        let (a, b) = (try videoCopy(), try videoCopy())
        player.save(ResumeEntry(position: 1), for: a)
        player.save(ResumeEntry(position: 2), for: b)
        other.save(ResumeEntry(position: 3, duration: 4), for: a)
        player.save(ResumeEntry(position: 5, duration: 4), for: b)
        #expect(ResumeStore(url: player.url).entry(for: a)?.position == 3)
    }

    @Test func aKnownSizeFindsTheSameEntryWithoutAskingTheFile() throws {
        let s = store()
        let video = try videoCopy()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber).int64Value
        s.save(ResumeEntry(position: 7), for: video)
        #expect(s.entry(for: video, size: size)?.position == 7)
        #expect(s.entry(for: video, size: size + 1) == nil)
        s.save(ResumeEntry(position: 9), for: video, size: size)
        #expect(ResumeStore(url: s.url).entry(for: video)?.position == 9)
    }

    @Test func aDifferentFileUnderTheSameNameStartsFresh() throws {
        let s = store()
        let video = try videoCopy()
        s.save(ResumeEntry(position: 3), for: video)
        let handle = try FileHandle(forWritingTo: video)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 1, 2]))
        try handle.close()
        #expect(s.entry(for: video) == nil)
    }

    @Test func keepsOnlyTheMostRecentEntries() throws {
        let s = store(limit: 2)
        let videos = try (0..<3).map { _ in try videoCopy() }
        for (i, video) in videos.enumerated() {
            s.save(ResumeEntry(position: Double(i), updated: Date(timeIntervalSince1970: Double(i) * 86_400)), for: video)
        }
        let reloaded = ResumeStore(url: s.url, limit: 2)
        #expect(reloaded.entry(for: videos[0]) == nil)
        #expect(reloaded.entry(for: videos[1])?.position == 1)
        #expect(reloaded.entry(for: videos[2])?.position == 2)
    }

    @Test func corruptFileIsIgnoredAndReplaced() async throws {
        let url = makeTemporaryDirectory().appendingPathComponent("positions.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let s = ResumeStore(url: url)
        await s.flush()
        let video = try videoCopy()
        #expect(s.entry(for: video) == nil)
        s.save(ResumeEntry(position: 4), for: video)
        await s.flush()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let durable = try decoder.decode([String: ResumeEntry].self, from: Data(contentsOf: url))
        #expect(durable[ResumeStore.key(for: video)!]?.position == 4)
    }

    @Test func colorRoundTrips() throws {
        let s = store()
        let video = try videoCopy()
        let values = ["auto-color": "yes", "auto-color-strength": "0.65"]
        s.save(ResumeEntry(position: 3), for: video)
        s.setColor(values, for: video)
        #expect(ResumeStore(url: s.url).color(for: video) == values)
        #expect(ResumeStore(url: s.url).entry(for: video)?.position == 3)
    }

    @Test func entryWithoutColorDecodes() throws {
        let bare = #"{"position": 3, "updated": 0}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ResumeEntry.self, from: bare).color == nil)
    }

    @Test func setColorWorksWithoutAnEntry() throws {
        let s = store()
        let video = try videoCopy()
        #expect(s.color(for: video) == nil)
        s.setColor(["vibrance-on": "yes"], for: video)
        let reloaded = ResumeStore(url: s.url)
        #expect(reloaded.color(for: video) == ["vibrance-on": "yes"])
        #expect(reloaded.entry(for: video)?.position == 0)
    }

    @Test func setColorNilRemovesOnlyColor() throws {
        let s = store()
        let video = try videoCopy()
        s.save(ResumeEntry(position: 8, loopA: 1, loopB: 2, marks: [[1, 2]], duration: 40), for: video)
        s.setColor(["vibrance": "0.5"], for: video)
        s.setColor(nil, for: video)
        let entry = try #require(ResumeStore(url: s.url).entry(for: video))
        #expect(entry.color == nil)
        #expect(entry.position == 8 && entry.loopA == 1 && entry.loopB == 2 && entry.marks == [[1, 2]] && entry.duration == 40)
        s.setColor(["vibrance": "0.5"], for: video)
        s.setColor([:], for: video)
        #expect(ResumeStore(url: s.url).color(for: video) == nil)
    }

    @Test func clearingColorThatIsNotThereWritesNothing() throws {
        let s = store()
        let video = try videoCopy()
        s.setColor(nil, for: video)                  // no entry: no new entry, no file
        s.setColor([:], for: video)
        #expect(!FileManager.default.fileExists(atPath: s.url.path))
        let saved = Date(timeIntervalSince1970: 1_000)
        s.save(ResumeEntry(position: 8, updated: saved), for: video)
        s.setColor(nil, for: video)                  // entry without colour: untouched, `updated` too
        s.setColor([:], for: video)
        #expect(ResumeStore(url: s.url).entry(for: video)?.updated == saved)
    }

    @Test func setColorWithoutAReadableSizeDoesNothing() {
        let s = store()
        let missing = makeTemporaryDirectory().appendingPathComponent("gone.mp4")
        s.setColor(["vibrance-on": "yes"], for: missing)
        #expect(s.color(for: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: s.url.path))
    }
    @Test func colourEditDoesNotChangeLastViewed() throws {
        let dir = makeTemporaryDirectory()
        let video = dir.appendingPathComponent("clip.mp4")
        try Data([1]).write(to: video)
        let store = ResumeStore(url: dir.appendingPathComponent("positions.json"))
        let viewed = Date(timeIntervalSince1970: 1_000)
        store.save(ResumeEntry(position: 2, lastViewedAt: viewed), for: video)
        store.setColor(["vibrance": "1"], for: video)
        #expect(ResumeStore(url: store.url).entry(for: video)?.lastViewedAt == viewed)
    }
    @Test func viewHistoryMergesWithoutChangingResumeOrColor() throws {
        let s = store()
        let video = try videoCopy()
        let initial = ResumeEntry(position: 8, loopA: 1, loopB: 2, marks: [[1, 2]],
                                  duration: 40, color: ["vibrance": "0.5"])
        s.save(initial, for: video, size: 1)
        let first = Date(timeIntervalSince1970: 1000)
        let last = Date(timeIntervalSince1970: 2000)
        s.recordView(for: video, size: 1, at: first)
        s.recordView(for: video, size: 1, at: last)
        s.recordView(for: video, size: 1, at: first) // out-of-order work cannot regress history
        s.flushViews()
        let entry = try #require(ResumeStore(url: s.url).entry(for: video, size: 1))
        #expect(entry.lastViewedAt == last)
        #expect(entry.position == initial.position && entry.marks == initial.marks)
        #expect(entry.loopA == 1 && entry.loopB == 2 && entry.duration == 40)
        #expect(entry.color == initial.color)
        // An open that never displayed a frame saves no new viewing date.
        s.save(initial, for: video, size: 1)
        #expect(s.entry(for: video, size: 1)?.lastViewedAt == last)
    }

    @Test func viewHistoryCreatesEntryWithoutResumeAndRefreshesOtherInstances() throws {
        let s = store()
        let reader = ResumeStore(url: s.url)
        let video = try videoCopy()
        #expect(reader.entry(for: video, size: 1) == nil)
        let viewed = Date(timeIntervalSince1970: 1000)
        s.recordView(for: video, size: 1, at: viewed)
        s.flushViews()
        #expect(reader.entry(for: video, size: 1)?.lastViewedAt == viewed)
        #expect(reader.entry(for: video, size: 1)?.position == 0)
    }

    @Test func addressedViewLookupUsesKnownSizesAndNeverFallsBackToUpdated() throws {
        let s = store()
        let video = try videoCopy()
        let legacy = try videoCopy()
        let viewed = Date(timeIntervalSince1970: 1000)
        s.save(ResumeEntry(position: 1, lastViewedAt: viewed), for: video, size: 12)
        s.save(ResumeEntry(position: 2), for: legacy, size: 34)
        #expect(s.lastViewedAt(for: [video: 12, legacy: 34]) == [video: viewed])
        #expect(s.lastViewedAt(for: [video: 13]).isEmpty)
        #expect(s.lastViewedAt(for: [:]).isEmpty)
    }

    @Test func concurrentHistoryAndColorTransactionsPreserveBoth() throws {
        let s = store()
        let other = ResumeStore(url: s.url)
        let video = try videoCopy()
        let viewed = Date(timeIntervalSince1970: 1000)
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            if i.isMultiple(of: 2) { s.recordView(for: video, size: 1, at: viewed) }
            else { other.setColor(["vibrance": "0.5"], for: video, size: 1) }
        }
        s.flushViews()
        let entry = try #require(other.entry(for: video, size: 1))
        #expect(entry.lastViewedAt == viewed)
        #expect(entry.color == ["vibrance": "0.5"])
    }

    @Test func snapshotsStayCachedUntilAnotherInstanceWrites() throws {
        let s = store()
        let video = try videoCopy()
        s.save(ResumeEntry(position: 1), for: video, size: 12)
        let reader = ResumeStore(url: s.url)
        #expect(reader.entry(for: video, size: 12)?.position == 1)
        // Changing bytes behind the in-process store does not trigger stats or repeated JSON reads.
        try Data("not JSON".utf8).write(to: s.url)
        for _ in 0..<20 { #expect(reader.entry(for: video, size: 12)?.position == 1) }
        s.save(ResumeEntry(position: 2), for: video, size: 12)
        #expect(reader.entry(for: video, size: 12)?.position == 2)
        #expect(reader.entry(for: video, size: 12)?.position == 2)
    }

    /// Decode the actual durable bytes, not another instance's shared memory snapshot.
    @Test func backgroundSaveIsDurableOnReturn() async throws {
        let s = store()
        let video = try videoCopy()
        let saved = ResumeEntry(position: 3, marks: [[1, 2]], color: ["vibrance": "0.5"],
                                lastViewedAt: Date(timeIntervalSince1970: 1000),
                                updated: Date(timeIntervalSince1970: 2000))
        await Task.detached { s.save(saved, for: video, size: 1) }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bytes = try Data(contentsOf: s.url)
        let durable = try decoder.decode([String: ResumeEntry].self, from: bytes)
        #expect(durable[ResumeStore.key(for: video, size: 1)!] == saved)
    }

    @Test @MainActor func foregroundMutationsAreVisibleAcrossInstancesBeforeFlush() async throws {
        let s = store()
        let reader = ResumeStore(url: s.url)
        let video = try videoCopy()
        let date = Date(timeIntervalSince1970: 1000)
        s.recordView(for: video, size: 1, at: date)
        s.setColor(["vibrance": "0.5"], for: video, size: 1)
        s.save(ResumeEntry(position: 7, marks: [[1, 2]], color: ["vibrance": "0.5"]), for: video, size: 1)
        #expect(reader.entry(for: video, size: 1)?.lastViewedAt == date)
        #expect(reader.entry(for: video, size: 1)?.marks == [[1, 2]])
        await Task.detached { s.flushViews() }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let durable = try decoder.decode([String: ResumeEntry].self, from: Data(contentsOf: s.url))
        let entry = try #require(durable[ResumeStore.key(for: video, size: 1)!])
        #expect(entry.position == 7 && entry.marks == [[1, 2]])
        #expect(entry.color == ["vibrance": "0.5"] && entry.lastViewedAt == date)
    }

    @Test @MainActor func stalledWriterDoesNotBlockForegroundSnapshotsOrMutations() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stateURL = makeTemporaryDirectory().appendingPathComponent("positions.json")
        let s = ResumeStore(url: stateURL, write: { data, url in
            entered.signal()
            // A timeout prevents a lock regression from hanging the entire suite.
            _ = release.wait(timeout: .now() + 5)
            try data.write(to: url, options: .atomic)
        })
        let video = stateURL.deletingLastPathComponent().appendingPathComponent("clip.mp4")
        let viewed = Date(timeIntervalSince1970: 1000)
        s.recordView(for: video, size: 1, at: viewed)
        let started = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        defer { release.signal() }
        #expect(started)
        let start = Date()
        let reader = ResumeStore(url: stateURL)
        #expect(reader.entry(for: video, size: 1)?.lastViewedAt == viewed)
        s.setColor(["vibrance": "0.5"], for: video, size: 1)
        s.save(ResumeEntry(position: 7, marks: [[1, 2]], color: ["vibrance": "0.5"]), for: video, size: 1)
        let unrelated = store()
        unrelated.save(ResumeEntry(position: 2), for: video, size: 1)
        #expect(unrelated.entry(for: video, size: 1)?.position == 2)
        // Deliberately loose: detects waiting for the five-second disk gate, not a UI microbenchmark.
        #expect(Date().timeIntervalSince(start) < 1)
        release.signal()
        // All later writes are allowed through too.
        release.signal()
        await Task.detached { s.flushViews() }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let durable = try decoder.decode([String: ResumeEntry].self, from: Data(contentsOf: stateURL))
        let entry = try #require(durable[ResumeStore.key(for: video, size: 1)!])
        #expect(entry.position == 7 && entry.marks == [[1, 2]])
        #expect(entry.color == ["vibrance": "0.5"] && entry.lastViewedAt == viewed)
    }

    @Test func failedWriteRetainsSnapshotAndNextMutationRetriesDurableState() async throws {
        let root = makeTemporaryDirectory()
        let parent = root.appendingPathComponent("state")
        try Data([1]).write(to: parent) // A file where the state directory should be.
        let s = ResumeStore(url: parent.appendingPathComponent("positions.json"))
        let video = root.appendingPathComponent("clip.mp4")
        await Task.detached {
            s.save(ResumeEntry(position: 7, marks: [[1, 2]]), for: video, size: 1)
        }.value
        #expect(s.entry(for: video, size: 1)?.position == 7)
        try FileManager.default.removeItem(at: parent)
        await Task.detached { s.setColor(["vibrance": "0.5"], for: video, size: 1) }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let durable = try decoder.decode([String: ResumeEntry].self, from: Data(contentsOf: s.url))
        let entry = try #require(durable[ResumeStore.key(for: video, size: 1)!])
        #expect(entry.position == 7 && entry.marks == [[1, 2]])
        #expect(entry.color == ["vibrance": "0.5"])
    }

    @Test func staleProcessAddsHistoryWithoutDiscardingAnotherProcessesEntries() async throws {
        let s = store()
        await s.flush() // This process booted before the other process's first write.
        let root = s.url.deletingLastPathComponent()
        let a = root.appendingPathComponent("a.mp4"), b = root.appendingPathComponent("b.mp4")
        let keyA = try #require(ResumeStore.key(for: a, size: 1))
        let keyB = try #require(ResumeStore.key(for: b, size: 1))
        let first = Date(timeIntervalSince1970: 1000)
        try externalTransaction(at: s.url) { $0[keyA] = ResumeEntry(position: 12, lastViewedAt: first) }
        s.recordView(for: b, size: 1, at: Date(timeIntervalSince1970: 2000))
        await s.flush()
        let durable = try durableEntries(at: s.url)
        #expect(durable[keyA]?.position == 12 && durable[keyA]?.lastViewedAt == first)
        #expect(durable[keyB]?.lastViewedAt == Date(timeIntervalSince1970: 2000))
        #expect(s.entry(for: a, size: 1)?.position == 12)
    }

    @Test func viewOnlyDeltaPreservesExternalResumeMarksAndColour() async throws {
        let s = store()
        let video = s.url.deletingLastPathComponent().appendingPathComponent("clip.mp4")
        let key = try #require(ResumeStore.key(for: video, size: 1))
        s.save(ResumeEntry(position: 1, color: ["vibrance": "0.2"]), for: video, size: 1)
        await s.flush()
        let external = ResumeEntry(position: 22, loopA: 2, loopB: 8, marks: [[3, 7]], duration: 40,
                                   color: ["vibrance": "0.9"], lastViewedAt: Date(timeIntervalSince1970: 3000))
        try externalTransaction(at: s.url) { $0[key] = external }
        s.recordView(for: video, size: 1, at: Date(timeIntervalSince1970: 2000))
        await s.flush()
        let entry = try #require(durableEntries(at: s.url)[key])
        #expect(entry.position == 22 && entry.loopA == 2 && entry.loopB == 8)
        #expect(entry.marks == [[3, 7]] && entry.duration == 40)
        #expect(entry.color == external.color && entry.lastViewedAt == external.lastViewedAt)
        #expect(s.entry(for: video, size: 1)?.color == external.color)
    }

    @Test func positionSaveDoesNotRestoreCarriedStaleColourAndExplicitClearWins() async throws {
        let s = store()
        let video = s.url.deletingLastPathComponent().appendingPathComponent("clip.mp4")
        let key = try #require(ResumeStore.key(for: video, size: 1))
        let oldColour = ["vibrance": "0.2"]
        s.save(ResumeEntry(position: 1, color: oldColour), for: video, size: 1)
        await s.flush()
        try externalTransaction(at: s.url) {
            $0[key]?.color = ["vibrance": "0.9"]
            $0[key]?.lastViewedAt = Date(timeIntervalSince1970: 3000)
        }
        s.save(ResumeEntry(position: 9, marks: [[2, 4]], color: oldColour), for: video, size: 1)
        await s.flush()
        let saved = try #require(durableEntries(at: s.url)[key])
        #expect(saved.position == 9 && saved.marks == [[2, 4]])
        #expect(saved.color == ["vibrance": "0.9"] && saved.lastViewedAt == Date(timeIntervalSince1970: 3000))
        s.setColor(nil, for: video, size: 1)
        await s.flush()
        #expect(try durableEntries(at: s.url)[key]?.color == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func stalePositionSaveCannotUndoColourClear(flushClearFirst: Bool) async throws {
        let s = store()
        let video = s.url.deletingLastPathComponent().appendingPathComponent("clip.mp4")
        let key = try #require(ResumeStore.key(for: video, size: 1))
        let staleColour = ["vibrance": "0.7"]
        s.save(ResumeEntry(position: 1, color: staleColour), for: video, size: 1)
        await s.flush()
        s.setColor(nil, for: video, size: 1)
        if flushClearFirst { await s.flush() }
        // A known record whose colour is nil remains a known record, not a seedable new key.
        s.save(ResumeEntry(position: 9, marks: [[2, 4]], color: staleColour), for: video, size: 1)
        #expect(s.entry(for: video, size: 1)?.color == nil)
        await s.flush()
        let entry = try #require(durableEntries(at: s.url)[key])
        #expect(entry.position == 9 && entry.marks == [[2, 4]])
        #expect(entry.color == nil)
    }

    @Test @MainActor func coalescedPositionSavesKeepMaximumUpdatedDate() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let url = makeTemporaryDirectory().appendingPathComponent("positions.json")
        let s = ResumeStore(url: url, write: { data, url in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            try data.write(to: url, options: .atomic)
        })
        let root = url.deletingLastPathComponent()
        s.recordView(for: root.appendingPathComponent("blocker.mp4"), size: 1,
                     at: Date(timeIntervalSince1970: 1000))
        let started = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        defer { release.signal() }
        #expect(started)
        let video = root.appendingPathComponent("clip.mp4")
        // The blocked writer guarantees both saves occupy the same pending batch.
        s.save(ResumeEntry(position: 1, updated: Date(timeIntervalSince1970: 2000)), for: video, size: 1)
        s.save(ResumeEntry(position: 2, updated: Date(timeIntervalSince1970: 1000)), for: video, size: 1)
        release.signal()
        release.signal()
        await s.flush()
        let key = try #require(ResumeStore.key(for: video, size: 1))
        let entry = try #require(durableEntries(at: url)[key])
        #expect(entry.position == 2)
        #expect(entry.updated == Date(timeIntervalSince1970: 2000))
    }

}
