import StashKit
import Testing
@testable import FrameScrubCore

@Suite struct StashTitleTests {
    private func details(title: String? = nil, studio: String? = nil, date: String? = nil) -> StashSceneDetails {
        var json: [String: Any] = ["id": "1"]
        if let title { json["title"] = title }
        if let studio { json["studio"] = ["name": studio] }
        if let date { json["date"] = date }
        return StashSceneDetails(json: json)!
    }

    @Test func titleStudioDate() {
        #expect(StashTitle.text(details: details(title: "Title", studio: "Studio", date: "2024-05-01"), fileName: "a.mp4") == "Title — Studio · 2024-05-01")
    }

    @Test func partsLeftOutWhenMissing() {
        #expect(StashTitle.text(details: details(title: "Title", date: "2024-05-01"), fileName: "a.mp4") == "Title · 2024-05-01")
        #expect(StashTitle.text(details: details(title: "Title", studio: "Studio"), fileName: "a.mp4") == "Title — Studio")
        #expect(StashTitle.text(details: details(title: "Title"), fileName: "a.mp4") == "Title")
    }

    @Test func fileNameStandsInForTheTitle() {
        #expect(StashTitle.text(details: details(studio: "Studio", date: "2024-05-01"), fileName: "a.mp4") == "a.mp4 — Studio · 2024-05-01")
    }

    @Test func fileNameAlone() {
        #expect(StashTitle.text(details: nil, fileName: "a.mp4") == "a.mp4")
        #expect(StashTitle.text(details: details(), fileName: "a.mp4") == "a.mp4")
    }
}
