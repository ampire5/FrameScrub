import Foundation
import FrameScrubCore
import HomeScreenModel
import Testing

@Suite struct HomeRecentTests {
    let a = URL(filePath: "/v/a.mp4"), b = URL(filePath: "/v/b.mkv")
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func entriesCarryProgressAndTime() {
        let entries = HomeRecent.entries([a, b], resume: { $0 == a ? ResumeEntry(position: 30, duration: 120, updated: day) : nil },
                                         durations: [:], dimmed: [])
        #expect(entries.map(\.id) == ["recent:/v/a.mp4", "recent:/v/b.mkv"])
        #expect(entries[0].kind == .file && entries[0].name == "a.mp4")
        #expect(entries[0].subtitle == RecentFiles.timeText(position: 30, duration: 120))
        #expect(entries[0].progress == 0.25)
        #expect(entries[0].date == day)
        #expect(!entries[0].canRename && !entries[0].canTrash)
        #expect(entries[1].subtitle == nil && entries[1].progress == nil && entries[1].date == nil)
    }

    /// A length the thumbnailer found (the file was never played to a position) shows before the store has one.
    @Test func durationsFillTheLength() {
        let entries = HomeRecent.entries([b], resume: { _ in nil }, durations: ["/v/b.mkv": 65], dimmed: [])
        #expect(entries[0].subtitle == "1:05")
    }

    @Test func dimsUnreachable() {
        let entries = HomeRecent.entries([a, b], resume: { _ in nil }, durations: [:], dimmed: ["/v/a.mp4"])
        #expect(entries.map(\.isDimmed) == [true, false])
    }

    @Test func hiddenAreLeftOut() {
        #expect(RecentFiles.shown([a, b, a], hidden: ["/v/b.mkv"], limit: 50) == [a])
    }

    @Test func stashTabFallsBackToRecent() {
        #expect(HomeRecent.shownTab(.stash, stashEnabled: false) == .recent)
        #expect(HomeRecent.shownTab(.stash, stashEnabled: true) == .stash)
        #expect(HomeRecent.shownTab(.recent, stashEnabled: true) == .recent)
    }

    @Test func tabsAndLocations() {
        #expect(HomeRecent.location(of: .recent) == .source("recent"))
        #expect(HomeRecent.location(of: .stash) == .source("stash"))
        #expect(HomeRecent.tab(of: .source("stash")) == .stash)
        #expect(HomeRecent.tab(of: .source("recent")) == .recent)
        #expect(HomeRecent.location(of: .folders) == nil)
        #expect(HomeRecent.tab(of: .places) == .folders)
        #expect(HomeRecent.tab(of: .folder(URL(filePath: "/v"))) == .folders)
    }

    @Test func pathOfID() {
        #expect(HomeRecent.path(ofID: "recent:/v/a.mp4") == "/v/a.mp4")
        #expect(HomeRecent.path(ofID: "session:3") == nil)
    }
}
