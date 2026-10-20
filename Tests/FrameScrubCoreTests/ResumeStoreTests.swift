import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ResumeStoreTests {
    private func store(limit: Int = 500) -> ResumeStore {
        ResumeStore(url: makeTemporaryDirectory().appendingPathComponent("positions.json"), limit: limit)
    }

    private func videoCopy() throws -> URL {
        let url = makeTemporaryDirectory().appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: Fixtures.url(Fixtures.withAudio), to: url)
        return url
    }

    @Test func roundTripsThroughTheFile() throws {
        let s = store()
        let video = try videoCopy()
        let entry = ResumeEntry(position: 12.5, loopA: 1, loopB: 2, duration: 40, updated: Date(timeIntervalSince1970: 1_000_000))
        s.save(entry, for: video)
        let reloaded = ResumeStore(url: s.url)
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

    @Test func corruptFileIsIgnoredAndReplaced() throws {
        let s = store()
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: s.url, atomically: true, encoding: .utf8)
        let video = try videoCopy()
        #expect(s.entry(for: video) == nil)
        s.save(ResumeEntry(position: 4), for: video)
        #expect(ResumeStore(url: s.url).entry(for: video)?.position == 4)
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
}
