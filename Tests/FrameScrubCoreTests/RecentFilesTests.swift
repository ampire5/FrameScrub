import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct RecentFilesTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/videos/\(name)") }

    @Test func missingFilesAreDropped() {
        let urls = ["a.mp4", "gone.mp4", "b.mp4"].map(url)
        #expect(RecentFiles.existing(urls, fileExists: { $0.lastPathComponent != "gone.mp4" }) == [url("a.mp4"), url("b.mp4")])
    }

    @Test func atMostTenKeepingTheOrder() {
        let urls = (0..<15).map { url("v\($0).mp4") }
        #expect(RecentFiles.existing(urls, fileExists: { _ in true }) == Array(urls.prefix(10)))
        #expect(RecentFiles.existing(urls, limit: 3, fileExists: { _ in true }) == Array(urls.prefix(3)))
    }

    @Test func missingFilesDoNotCountAgainstTheLimit() {
        let urls = (0..<6).map { url("v\($0).mp4") }
        let kept = RecentFiles.existing(urls, limit: 3, fileExists: { $0.lastPathComponent != "v0.mp4" })
        #expect(kept == [url("v1.mp4"), url("v2.mp4"), url("v3.mp4")])
    }

    @Test func duplicatesAreShownOnce() {
        let urls = [url("a.mp4"), url("b.mp4"), url("a.mp4")]
        #expect(RecentFiles.existing(urls, fileExists: { _ in true }) == [url("a.mp4"), url("b.mp4")])
    }

    @Test func positionText() {
        #expect(RecentFiles.positionText(7.9) == "0:07")
        #expect(RecentFiles.positionText(754) == "12:34")
        #expect(RecentFiles.positionText(3723) == "1:02:03")
    }

    @Test func progressIsThePositionOverTheLength() {
        #expect(RecentFiles.progress(position: 15, duration: 60) == 0.25)
        #expect(RecentFiles.progress(position: 70, duration: 60) == 1)
        #expect(RecentFiles.progress(position: 0, duration: 60) == nil)   // never moved: no bar
        #expect(RecentFiles.progress(position: 15, duration: nil) == nil)  // an entry from before lengths were kept
    }

    @Test func timeTextShowsThePositionAndTheLengthWhenKnown() {
        #expect(RecentFiles.timeText(position: 754, duration: 2710) == "12:34 / 45:10")
        #expect(RecentFiles.timeText(position: 754, duration: nil) == "12:34")
        #expect(RecentFiles.timeText(position: 0, duration: 2710) == "45:10")
        #expect(RecentFiles.timeText(position: nil, duration: nil) == nil)
    }

    @Test func shownKeepsMissingFilesAndDropsHiddenOnes() {
        let urls = [url("a.mp4"), url("gone.mp4"), url("hidden.mp4"), url("a.mp4")]
        #expect(RecentFiles.shown(urls, hidden: ["/videos/hidden.mp4"]) == [url("a.mp4"), url("gone.mp4")])
        #expect(RecentFiles.shown((0..<15).map { url("v\($0).mp4") }, hidden: []).count == 10)
    }

    @Test func existingLeavesHiddenOut() {
        let urls = [url("a.mp4"), url("b.mp4")]
        #expect(RecentFiles.existing(urls, hidden: ["/videos/a.mp4"], fileExists: { _ in true }) == [url("b.mp4")])
    }

    @Test func hiddenRecentHidesRevealsAndClears() {
        let defaults = UserDefaults(suiteName: "framescrub.tests.hidden-recent")!
        defaults.removePersistentDomain(forName: "framescrub.tests.hidden-recent")
        var hidden = HiddenRecent(defaults: defaults)
        hidden.hide(url("a.mp4"))
        #expect(HiddenRecent(defaults: defaults).paths == ["/videos/a.mp4"])
        hidden.reveal(url("a.mp4"))
        #expect(HiddenRecent(defaults: defaults).paths.isEmpty)
        for i in 0..<201 { hidden.hide(url("v\(i).mp4")) }
        let kept = HiddenRecent(defaults: defaults).paths
        #expect(kept.count == 200 && !kept.contains("/videos/v0.mp4") && kept.contains("/videos/v200.mp4"))
        hidden.hide(url("v5.mp4"))   // already hidden: no duplicate
        #expect(HiddenRecent(defaults: defaults).paths.count == 200)
        hidden.clear()
        #expect(HiddenRecent(defaults: defaults).paths.isEmpty)
        defaults.removePersistentDomain(forName: "framescrub.tests.hidden-recent")
    }
}
