import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FolderColorsTests {
    private func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func fileURL() -> URL { makeTemporaryDirectory().appendingPathComponent("folder-colors.json") }

    /// Holds what the store asked to run later, so a test decides when the debounce fires.
    private final class Scheduler {
        var delays: [Double] = []
        var pending: [() -> Void] = []
        func schedule(_ delay: Double, _ work: @escaping () -> Void) { delays.append(delay); pending.append(work) }
        func fire() { let work = pending; pending = []; work.forEach { $0() } }
    }

    @Test func setOwnAndClear() {
        let s = FolderColors(url: nil)
        s.set(["auto-color": "yes", "auto-color-strength": "0.5"], for: dir("/p"))
        s.set(["auto-color-strength": "0.7", "vibrance-on": "yes"], for: dir("/p"))      // merges keys
        #expect(s.own(for: dir("/p")) == ["auto-color": "yes", "auto-color-strength": "0.7", "vibrance-on": "yes"])
        s.clear(["auto-color", "nope"], for: dir("/p"))
        #expect(s.own(for: dir("/p")) == ["auto-color-strength": "0.7", "vibrance-on": "yes"])
        #expect(s.own(for: dir("/q")).isEmpty)
    }

    @Test func chainRunsFromTheFolderToItsParents() {
        let s = FolderColors(url: nil)
        s.set(["vibrance": "0.2"], for: dir("/a"))
        s.set(["vibrance": "0.4"], for: dir("/a/b/c"))
        #expect(s.chain(for: dir("/a/b/c")) == [["vibrance": "0.4"], [:], ["vibrance": "0.2"], [:]])
        #expect(s.chain(for: dir("/a/b")) == [[:], ["vibrance": "0.2"], [:]])
        #expect(FolderColors.ancestors(of: dir("/a/b")) == ["/a/b", "/a", "/"])
    }

    @Test func aPrefixIsNotAnAncestor() {
        let s = FolderColors(url: nil)
        s.set(["vibrance": "0.2"], for: dir("/a/b"))
        #expect(s.chain(for: dir("/a/bc")).allSatisfy { $0.isEmpty })
        #expect(s.chain(for: dir("/a/bc/d")).allSatisfy { $0.isEmpty })
        #expect(s.chain(for: dir("/a/b/c")).contains(["vibrance": "0.2"]))
    }

    @Test func aVolumeRootStopsTheChain() {
        let s = FolderColors(url: nil)
        s.set(["vibrance": "0.9"], for: dir("/Volumes"))
        s.set(["vibrance": "0.8"], for: dir("/"))
        #expect(FolderColors.ancestors(of: dir("/Volumes/S$/x/y")) == ["/Volumes/S$/x/y", "/Volumes/S$/x", "/Volumes/S$"])
        #expect(s.chain(for: dir("/Volumes/S$/x/y")).allSatisfy { $0.isEmpty })
        s.set(["vibrance": "0.3"], for: dir("/Volumes/S$"))
        #expect(s.chain(for: dir("/Volumes/S$/x/y")) == [[:], [:], ["vibrance": "0.3"]])
        #expect(FolderColors.ancestors(of: dir("/Users/x")) == ["/Users/x", "/Users", "/"])      // local folders go up to /
        #expect(FolderColors.ancestors(of: dir("/Volumes/S$")) == ["/Volumes/S$"])
    }

    @Test func foldersAreKeyedStandardized() {
        let s = FolderColors(url: nil)
        s.set(["vibrance": "0.2"], for: dir("/a/./b/"))
        #expect(s.own(for: dir("/a/b")) == ["vibrance": "0.2"])
        #expect(s.own(for: dir("/a/x/../b")) == ["vibrance": "0.2"])
    }

    @Test func aFolderWithoutValuesIsRemoved() throws {
        let url = fileURL()
        let s = FolderColors(url: url, schedule: { _, _ in })
        s.set(["vibrance": "0.2"], for: dir("/p"))
        s.set(["vibrance": "0.2"], for: dir("/q"))
        #expect(s.count == 2)
        s.clear(["vibrance"], for: dir("/p"))
        s.clear(["vibrance"], for: dir("/p"))      // nothing left to clear
        #expect(s.count == 1)
        s.flush()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?.keys.sorted() == ["/q"])
    }

    @Test func theLeastRecentlyTouchedFolderIsEvicted() {
        let s = FolderColors(url: nil, capacity: 3)
        for n in 1...3 { s.set(["vibrance": "0.\(n)"], for: dir("/p/f\(n)")) }
        s.set(["auto-color": "yes"], for: dir("/p/f1"))      // touch 1: now 2 is the oldest
        s.set(["vibrance": "0.4"], for: dir("/p/f4"))
        #expect(s.own(for: dir("/p/f2")).isEmpty)
        #expect(s.own(for: dir("/p/f1")) == ["vibrance": "0.1", "auto-color": "yes"])
        #expect(s.count == 3)
    }

    @Test func the1001stFolderEvictsTheOldest() {
        let s = FolderColors(url: nil)
        for n in 1...1001 { s.set(["vibrance": "0.5"], for: dir("/p/f\(n)")) }
        #expect(s.count == 1000)
        #expect(s.own(for: dir("/p/f1")).isEmpty)
        #expect(s.own(for: dir("/p/f2")) == ["vibrance": "0.5"])
    }

    @Test func recencyAndValuesSurviveTheFile() {
        let url = fileURL()
        let s = FolderColors(url: url, capacity: 3, schedule: { _, _ in })
        for n in 1...3 { s.set(["vibrance": "0.\(n)"], for: dir("/p/f\(n)")) }
        s.set(["auto-color": "yes"], for: dir("/p/f1"))
        s.flush()
        let t = FolderColors(url: url, capacity: 3, schedule: { _, _ in })
        let u = FolderColors(url: url, capacity: 3, schedule: { _, _ in })
        #expect(t.own(for: dir("/p/f1")) == ["vibrance": "0.1", "auto-color": "yes"])
        u.set(["vibrance": "0.4"], for: dir("/p/f4"))      // the order came back: 2 was the oldest
        #expect(u.own(for: dir("/p/f2")).isEmpty)
        #expect(u.own(for: dir("/p/f1")).count == 2)
    }

    @Test func writesAreDebouncedIntoOne() throws {
        let url = fileURL()
        let clock = Scheduler()
        let s = FolderColors(url: url, writeDelay: 2, schedule: clock.schedule)
        s.set(["vibrance": "0.2"], for: dir("/p"))
        s.set(["vibrance": "0.3"], for: dir("/q"))
        #expect(clock.delays == [2])      // one write for the burst
        #expect(!FileManager.default.fileExists(atPath: url.path))
        clock.fire()
        #expect(s.writes == 1)
        let t = FolderColors(url: url, schedule: { _, _ in })
        #expect(t.own(for: dir("/p")) == ["vibrance": "0.2"])
        #expect(t.own(for: dir("/q")) == ["vibrance": "0.3"])
        s.set(["vibrance": "0.4"], for: dir("/p"))      // a later change schedules a new write
        #expect(clock.delays == [2, 2])
        clock.fire()
        #expect(s.writes == 2)
    }

    @Test func flushWritesAtOnceAndTheScheduledWriteFindsNothingLeft() {
        let url = fileURL()
        let clock = Scheduler()
        let s = FolderColors(url: url, schedule: clock.schedule)
        s.set(["vibrance": "0.2"], for: dir("/p"))
        s.flush()
        #expect(s.writes == 1)
        #expect(FolderColors(url: url, schedule: { _, _ in }).own(for: dir("/p")) == ["vibrance": "0.2"])
        clock.fire()
        #expect(s.writes == 1)
        s.flush()      // nothing changed since
        #expect(s.writes == 1)
    }

    @Test func memoryOnlyNeverTouchesTheDisk() {
        let clock = Scheduler()
        let s = FolderColors(url: nil, schedule: clock.schedule)
        s.set(["vibrance": "0.2"], for: dir("/p"))
        s.flush()
        #expect(clock.delays.isEmpty)
        #expect(s.writes == 0)
    }

    @Test func aCorruptFileIsSetAsideAndTheStoreStartsEmpty() throws {
        let url = fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let s = FolderColors(url: url, schedule: { _, _ in })
        #expect(s.count == 0)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("folder-colors.json.broken-") })
        #expect(!FileManager.default.fileExists(atPath: url.path))
        s.set(["vibrance": "0.2"], for: dir("/p"))      // and it works afterwards
        s.flush()
        #expect(FolderColors(url: url, schedule: { _, _ in }).own(for: dir("/p")) == ["vibrance": "0.2"])
    }

    @Test func aMissingFileIsAnEmptyStoreAndLeavesNothingBehind() {
        let url = fileURL()
        let s = FolderColors(url: url, schedule: { _, _ in })
        #expect(s.count == 0)
        s.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFailedWriteKeepsTheValuesAndTriesAgainOnTheNextWrite() throws {
        // The file's parent is a regular file, so the directory can't be created.
        let blocker = makeTemporaryDirectory().appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let url = blocker.appendingPathComponent("folder-colors.json")
        let clock = Scheduler()
        let s = FolderColors(url: url, schedule: clock.schedule)
        s.set(["vibrance": "0.2"], for: dir("/p"))
        clock.fire()
        #expect(s.writes == 0)
        #expect(s.own(for: dir("/p")) == ["vibrance": "0.2"])
        try FileManager.default.removeItem(at: blocker)
        s.set(["vibrance": "0.3"], for: dir("/q"))      // the next write carries both
        clock.fire()
        #expect(s.writes == 1)
        let t = FolderColors(url: url, schedule: { _, _ in })
        #expect(t.own(for: dir("/p")) == ["vibrance": "0.2"])
        #expect(t.own(for: dir("/q")) == ["vibrance": "0.3"])
    }
}
