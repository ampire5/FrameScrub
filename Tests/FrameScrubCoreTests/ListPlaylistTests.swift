import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ListPlaylistTests {
    private func items(_ n: Int) -> [PlaylistItem] { (0..<n).map { .scene(id: String($0), title: nil) } }

    @Test func startsAtIndex() throws {
        let list = try #require(ListPlaylist(items: items(3), index: 1, name: "Chapters"))
        #expect(list.currentIndex == 1)
        #expect(list.current == .scene(id: "1", title: nil))
        #expect(list.name == "Chapters")
    }

    @Test func emptyIsNil() { #expect(ListPlaylist(items: []) == nil) }

    @Test func indexOutOfRangeIsNil() {
        #expect(ListPlaylist(items: items(2), index: 2) == nil)
        #expect(ListPlaylist(items: items(2), index: -1) == nil)
    }

    @Test func nextAtEndIsNil() throws {
        var list = try #require(ListPlaylist(items: items(2), index: 1))
        #expect(list.next == nil)
        #expect(list.advance() == nil)
        #expect(list.currentIndex == 1)
    }

    @Test func previousAtStartIsNil() throws {
        var list = try #require(ListPlaylist(items: items(2)))
        #expect(list.previous == nil)
        #expect(list.goBack() == nil)
        #expect(list.currentIndex == 0)
    }

    @Test func advanceMovesCurrent() throws {
        var list = try #require(ListPlaylist(items: items(3)))
        #expect(list.advance() == .scene(id: "1", title: nil))
        #expect(list.currentIndex == 1)
        #expect(list.goBack() == .scene(id: "0", title: nil))
        #expect(list.currentIndex == 0)
    }

    @Test func appendWhileAtEndThenNext() throws {
        var list = try #require(ListPlaylist(items: items(2), index: 1))
        let url = URL(fileURLWithPath: "/v/a.mp4")
        #expect(list.append([.file(url, title: "A"), .scene(id: "9", title: nil)]) == 2)
        #expect(list.next == .file(url, title: "A"))
        #expect(list.items.count == 4)
    }

    @Test func appendStopsAtMax() throws {
        var list = try #require(ListPlaylist(items: items(1999)))
        #expect(list.append(items(5)) == 1)
        #expect(list.items.count == ListPlaylist.maxItems)
    }

    @Test func selectOutOfRangeIsNil() throws {
        var list = try #require(ListPlaylist(items: items(3)))
        #expect(list.select(3) == nil)
        #expect(list.currentIndex == 0)
        #expect(list.select(2) == .scene(id: "2", title: nil))
        #expect(list.currentIndex == 2)
    }

    @Test func titles() {
        #expect(PlaylistItem.scene(id: "1", title: "A").title == "A")
        #expect(PlaylistItem.file(URL(fileURLWithPath: "/a.mp4"), title: nil).title == nil)
    }

    @Test func positionText() throws {
        let list = try #require(ListPlaylist(items: items(10), index: 2))
        #expect(list.positionText == "3 / 10")
    }

    @Test func rowsNameTheItems() {
        #expect(PlaylistRow(PlaylistItem.scene(id: "7", title: "Intro")) == PlaylistRow(title: "Intro", subtitle: nil))
        #expect(PlaylistRow(PlaylistItem.scene(id: "7", title: nil)).title == "Scene 7")
        #expect(PlaylistRow(PlaylistItem.file(URL(fileURLWithPath: "/v/a.mp4"), title: nil)).title == "a.mp4")
        #expect(PlaylistRow(PlaylistItem.file(URL(fileURLWithPath: "/v/a.mp4"), title: "Take 1")).title == "Take 1")
        #expect(PlaylistRow(file: URL(fileURLWithPath: "/v/b.mov")).title == "b.mov")
        #expect(PlaylistRow(PlaylistItem.stream(URL(string: "http://h/x/trailer.mp4?q=best")!, title: nil)).title == "trailer.mp4")
        #expect(PlaylistRow(PlaylistItem.stream(URL(string: "http://h/x/trailer.mp4")!, title: "T")).title == "T")
        #expect(PlaylistRow(PlaylistItem.stream(URL(string: "http://h/")!, title: nil)).title == "h")
        #expect(PlaylistRow(PlaylistItem.stream(URL(string: "http://h")!, title: nil)).title == "h")
    }

    @Test func blankTitleFallsBackToName() {
        #expect(PlaylistRow(PlaylistItem.scene(id: "7", title: "  ")).title == "Scene 7")
    }

    @Test func enqueueOntoListAppends() throws {
        let list = try #require(ListPlaylist(items: items(2), index: 1, name: "Q"))
        let more = try #require(ListPlaylist.enqueue(items(1), onto: list, current: nil))
        #expect(more.items.count == 3)
        #expect(more.currentIndex == 1)
        #expect(more.name == "Q")
    }

    @Test func enqueueInFolderModeStartsWithTheCurrentFile() throws {
        let file = PlaylistItem.file(URL(fileURLWithPath: "/v/a.mp4"), title: nil)
        let list = try #require(ListPlaylist.enqueue(items(2), onto: nil, current: file))
        #expect(list.items == [file] + items(2))
        #expect(list.currentIndex == 0)
    }

    @Test func enqueueInFolderModeKeepsAPageStreamAsAStream() throws {
        let u = URL(string: "http://h/s/1")!, v = URL(string: "http://h/s/2")!
        let list = try #require(ListPlaylist.enqueue([.stream(u, title: nil)], onto: nil, current: .stream(v, title: "B")))
        #expect(list.items == [.stream(v, title: "B"), .stream(u, title: nil)])
        #expect(list.currentIndex == 0)
    }

    @Test func enqueueWithNothingOpenIsJustTheItems() throws {
        let list = try #require(ListPlaylist.enqueue(items(2), onto: nil, current: nil))
        #expect(list.items == items(2))
    }

    @Test func enqueuePastMaxIsRefusedWhole() throws {
        let list = try #require(ListPlaylist(items: items(1999)))
        #expect(ListPlaylist.enqueue(items(2), onto: list, current: nil) == nil)
        #expect(ListPlaylist.enqueue(items(2000), onto: nil, current: .scene(id: "x", title: nil)) == nil)
        #expect(ListPlaylist.enqueue([], onto: nil, current: nil) == nil)
    }

    @Test func filterKeepsMatchesAndTheCurrentItem() throws {
        let list = try #require(ListPlaylist(items: [
            .scene(id: "1", title: "Beach day"), .scene(id: "2", title: "City"), .scene(id: "3", title: "Été plage"),
            .file(URL(fileURLWithPath: "/v/beach2.mp4"), title: nil),
        ], index: 1))
        #expect(list.indices(matching: "beach") == [0, 1, 3])
        #expect(list.indices(matching: "ete") == [1, 2])
        #expect(list.indices(matching: "  ") == [0, 1, 2, 3])
    }
}
