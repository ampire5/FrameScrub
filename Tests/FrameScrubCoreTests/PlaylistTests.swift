import Foundation
import HomeScreenModel
import Testing
@testable import FrameScrubCore

@Suite struct PlaylistTests {
    private func folder(_ names: [String]) throws -> URL {
        let dir = makeTemporaryDirectory()
        for name in names { try Data().write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test func listsVideosSortedLikeFinder() throws {
        let dir = try folder(["clip10.mp4", "clip2.mov", "clip1.MKV", "notes.txt", "b.webm", ".hidden.mp4"])
        let playlist = Playlist(current: dir.appendingPathComponent("clip2.mov"))
        #expect(playlist.files.map(\.lastPathComponent) == ["b.webm", "clip1.MKV", "clip2.mov", "clip10.mp4"])
        #expect(playlist.current.lastPathComponent == "clip2.mov")
        #expect(playlist.previous?.lastPathComponent == "clip1.MKV")
        #expect(playlist.next?.lastPathComponent == "clip10.mp4")
    }

    @Test func edgesHaveNoNeighbour() throws {
        let dir = try folder(["a.mp4", "b.mp4"])
        #expect(Playlist(current: dir.appendingPathComponent("a.mp4")).previous == nil)
        #expect(Playlist(current: dir.appendingPathComponent("b.mp4")).next == nil)
    }

    @Test func currentFileIsKeptEvenWithAnUnknownExtension() throws {
        let dir = try folder(["a.mp4", "odd.xyz"])
        let playlist = Playlist(current: dir.appendingPathComponent("odd.xyz"))
        #expect(playlist.files.map(\.lastPathComponent) == ["a.mp4", "odd.xyz"])
    }

    @Test func unreadableFolderGivesOneFile() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/video.mp4")
        let playlist = Playlist(current: missing)
        #expect(playlist.files == [missing.standardizedFileURL])
        #expect(playlist.previous == nil && playlist.next == nil)
    }

    @Test func unopenableFileStillHasNeighbours() throws {
        let dir = try folder(["a.mp4", "broken.mp4", "c.mp4"])
        let playlist = Playlist(current: dir.appendingPathComponent("broken.mp4"))
        #expect(playlist.previous?.lastPathComponent == "a.mp4")
        #expect(playlist.next?.lastPathComponent == "c.mp4")
    }

    @Test func listingIsReadOnceAndSortedLater() throws {
        let dir = try folder(["b.mp4", "a.mp4", "notes.txt"])
        let listing = FolderListing.read(dir)
        try Data().write(to: dir.appendingPathComponent("c.mp4"))   // after the read: not in this listing
        let playlist = Playlist(current: dir.appendingPathComponent("b.mp4"), listing: listing)
        #expect(playlist.files.map(\.lastPathComponent) == ["a.mp4", "b.mp4"])
        #expect(listing.folder == dir.standardizedFileURL)
    }

    @Test func listingWithoutTheCurrentFileStillHasIt() throws {
        let dir = try folder(["a.mp4"])
        let listing = FolderListing.read(dir)
        let playlist = Playlist(current: dir.appendingPathComponent("new.mp4"), listing: listing)
        #expect(playlist.files.map(\.lastPathComponent) == ["a.mp4", "new.mp4"])
        #expect(playlist.current.lastPathComponent == "new.mp4")
    }

    @Test func emptyListingGivesTheCurrentFileAlone() throws {
        let dir = try folder(["a.mp4", "b.mp4"])
        let current = dir.appendingPathComponent("b.mp4")
        let playlist = Playlist(current: current, listing: .empty(dir))
        #expect(playlist.files == [current.standardizedFileURL])
        #expect(playlist.totalCount == 1)
    }

    @Test func listingWithoutARemovedFile() throws {
        let dir = try folder(["a.mp4", "b.mp4", "c.mp4"])
        let listing = FolderListing.read(dir).removing(dir.appendingPathComponent("b.mp4"))
        let playlist = Playlist(current: dir.appendingPathComponent("a.mp4"), listing: listing)
        #expect(playlist.files.map(\.lastPathComponent) == ["a.mp4", "c.mp4"])
    }

    /// Files of `bytes` size, modified `age` seconds ago.
    private func folder(_ files: [(name: String, bytes: Int, age: Double)]) throws -> URL {
        let dir = makeTemporaryDirectory()
        for file in files {
            let url = dir.appendingPathComponent(file.name)
            try Data(count: file.bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -file.age)], ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func sortsByDateNewestFirst() throws {
        let dir = try folder([("old.mp4", 1, 300), ("new.mp4", 1, 10), ("mid.mp4", 1, 100)])
        let playlist = Playlist(current: dir.appendingPathComponent("mid.mp4"), sort: PlaylistSort.date.defaultSort)
        #expect(playlist.files.map(\.lastPathComponent) == ["new.mp4", "mid.mp4", "old.mp4"])
        #expect(playlist.currentIndex == 1)
    }

    @Test func sortsBySizeLargestFirstThenByName() throws {
        let dir = try folder([("b.mp4", 10, 0), ("a.mp4", 10, 0), ("big.mp4", 500, 0), ("small.mp4", 1, 0)])
        let playlist = Playlist(current: dir.appendingPathComponent("a.mp4"), sort: PlaylistSort.size.defaultSort)
        #expect(playlist.files.map(\.lastPathComponent) == ["big.mp4", "a.mp4", "b.mp4", "small.mp4"])
    }

    /// Home's sort turned around: oldest first, smallest first (ties still by name), names Z–A.
    @Test func sortsTheOtherWayRound() throws {
        let dir = try folder([("b.mp4", 10, 300), ("a.mp4", 10, 10), ("big.mp4", 500, 100), ("small.mp4", 1, 200)])
        let listing = FolderListing.read(dir)
        let current = dir.appendingPathComponent("a.mp4")
        #expect(Playlist(current: current, sort: BrowserSort(key: .date, ascending: true), listing: listing).files.map(\.lastPathComponent)
                == ["b.mp4", "small.mp4", "big.mp4", "a.mp4"])
        #expect(Playlist(current: current, sort: BrowserSort(key: .size, ascending: true), listing: listing).files.map(\.lastPathComponent)
                == ["small.mp4", "a.mp4", "b.mp4", "big.mp4"])
        #expect(Playlist(current: current, sort: BrowserSort(key: .name, ascending: false), listing: listing).files.map(\.lastPathComponent)
                == ["small.mp4", "big.mp4", "b.mp4", "a.mp4"])
    }

    @Test func filterKeepsMatchesAndTheCurrentFile() throws {
        let dir = try folder(["Beach day.mp4", "city.mp4", "beach night.mov", "forest.mp4"])
        let playlist = Playlist(current: dir.appendingPathComponent("city.mp4"), filter: "BEACH")
        #expect(playlist.files.map(\.lastPathComponent) == ["Beach day.mp4", "beach night.mov", "city.mp4"])
        #expect(playlist.totalCount == 4)
        #expect(playlist.previous?.lastPathComponent == "beach night.mov")
        #expect(playlist.next == nil)
    }

    @Test func blankFilterKeepsAll() throws {
        let dir = try folder(["a.mp4", "b.mp4"])
        let playlist = Playlist(current: dir.appendingPathComponent("a.mp4"), filter: "  ")
        #expect(playlist.files.count == 2 && playlist.totalCount == 2 && !playlist.isFiltered)
    }

    @Test func positionText() throws {
        let dir = try folder(["a1.mp4", "a2.mp4", "b.mp4", "c.mp4"])
        #expect(Playlist(current: dir.appendingPathComponent("a2.mp4")).positionText == "2 / 4")
        #expect(Playlist(current: dir.appendingPathComponent("a2.mp4"), filter: "a").positionText == "2 / 2 (4)")
    }

    @Test func neighbourAfterRemovalPrefersTheNextFile() throws {
        let dir = try folder(["a.mp4", "b.mp4", "c.mp4"])
        #expect(Playlist(current: dir.appendingPathComponent("b.mp4")).neighbourAfterRemoval?.lastPathComponent == "c.mp4")
        #expect(Playlist(current: dir.appendingPathComponent("c.mp4")).neighbourAfterRemoval?.lastPathComponent == "b.mp4")
        let single = try folder(["only.mp4"])
        #expect(Playlist(current: single.appendingPathComponent("only.mp4")).neighbourAfterRemoval == nil)
    }

    @Test func sortCyclesAndParses() {
        #expect(PlaylistSort.name.next == .date && PlaylistSort.date.next == .size && PlaylistSort.size.next == .name)
        #expect(PlaylistSort(rawValue: "date") == .date)
    }

    @Test func orderIsTheGrids() throws {   // › and ‹ go where Home's next card is, in every sort
        let dir = try folder([("b.mp4", 10, 300), ("a.mp4", 10, 300), ("clip10.mp4", 500, 100), ("clip2.mp4", 1, 200)])
        let entries = try HomeFolders.entries(in: dir)
        let current = dir.appendingPathComponent("a.mp4")
        for text in ["name", "name-desc", "date", "date-desc", "size", "size-desc"] {
            let sort = BrowserSort(text: text)!
            let grid = sort.order(entries).filter(\.isFile).map(\.url.standardizedFileURL)
            #expect(Playlist(current: current, sort: sort, listing: FolderListing.read(dir)).files == grid, "\(text)")
        }
    }

    @Test func fileWithoutDateGoesLast() {   // as in the grid, not as the oldest
        let dir = URL(fileURLWithPath: "/v")
        let entries = [BrowserEntry(url: dir.appendingPathComponent("n.mp4"), name: "n.mp4", kind: .file),
                       BrowserEntry(url: dir.appendingPathComponent("o.mp4"), name: "o.mp4", kind: .file,
                                    date: Date(timeIntervalSinceReferenceDate: 1))]
        let playlist = Playlist(current: entries[0].url, sort: BrowserSort(key: .date, ascending: true),
                                listing: FolderListing(folder: dir, entries: entries))
        #expect(playlist.files.map(\.lastPathComponent) == ["o.mp4", "n.mp4"])
    }

    @Test func defaultSortsFollowTheGridsFirstDirections() {
        #expect(PlaylistSort.name.defaultSort == .standard)
        #expect(PlaylistSort.date.defaultSort == BrowserSort(key: .date, ascending: false))
        #expect(PlaylistSort.size.defaultSort == BrowserSort(key: .size, ascending: false))
    }

    @Test func neighbourStepsPastUnreadable() throws {
        let dir = try folder(["a.mp4", "b.mp4", "c.mp4", "d.mp4"])
        let playlist = Playlist(current: dir.appendingPathComponent("b.mp4"))
        let broken: (URL) -> Bool = { ["a.mp4", "c.mp4"].contains($0.lastPathComponent) }
        #expect(playlist.neighbour(1, skipping: broken)?.lastPathComponent == "d.mp4")
        #expect(playlist.neighbour(-1, skipping: broken) == nil)
        #expect(playlist.neighbour(-1, skipping: { _ in false })?.lastPathComponent == "a.mp4")
    }
}
