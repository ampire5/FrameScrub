import Foundation
import StashKit
import Testing
@testable import FrameScrubCore

/// A page's details of an item it opens (`info`), shown and used for names as a Stash scene's are.
@Suite struct SceneInfoTests {
    private func posted(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func reason(_ json: [String: Any]) -> String? {
        if case let .failure(failure) = PluginMessage.parse(json) { return failure.reason }
        return nil
    }

    private let full = SceneInfo(title: "Hot Blonde: Test", studio: "Studio A", performers: ["Ann", "Bea"],
                                 date: "2026-10-25", code: "5367369", url: URL(string: "https://example.com/s/1"))

    @Test func playlistItemsCarryInfo() {
        let json = posted(#"""
        {"cmd":"setPlaylist","index":1,"items":[
          {"url":"http://h/stream/1?kind=trailer","title":"A"},
          {"url":"http://h/stream/2?kind=trailer","info":{"title":"Hot Blonde: Test","studio":"Studio A",
           "performers":["Ann","Bea"],"date":"2026-10-25","code":"5367369","url":"https://example.com/s/1"}},
          {"path":"/v/a.mp4","info":{"title":"Local"}}]}
        """#)
        #expect(reason(json) == nil)
        let infos = PluginMessage.sceneInfos(json)
        #expect(infos.count == 2)
        #expect(infos[URL(string: "http://h/stream/2?kind=trailer")!] == full)
        #expect(infos[URL(filePath: "/v/a.mp4", directoryHint: .notDirectory)] == SceneInfo(title: "Local"))
        // the items themselves are as before
        guard case let .setPlaylist(items, index, _) = PluginMessage(json: json) else { Issue.record("not parsed"); return }
        #expect(items.count == 3 && index == 1)
    }

    @Test func openCarriesInfo() {
        let json = posted(#"{"cmd":"open","url":"http://h/stream/2","info":{"title":"T","performers":["Ann"]}}"#)
        #expect(PluginMessage.sceneInfos(json) == [URL(string: "http://h/stream/2")!: SceneInfo(title: "T", performers: ["Ann"])])
        #expect(PluginMessage.sceneInfos(posted(#"{"cmd":"open","url":"http://h/stream/2"}"#)).isEmpty)
    }

    @Test func badInfoRefusesTheMessage() {
        #expect(reason(posted(#"{"cmd":"open","url":"http://h/s","info":{"date":"25.10.2026"}}"#))
                == "open: info: date must be YYYY-MM-DD")
        #expect(reason(posted(#"{"cmd":"open","url":"http://h/s","info":{"performers":"Ann"}}"#))
                == "open: info: performers must be a list of strings")
        #expect(reason(posted(#"{"cmd":"open","url":"http://h/s","info":"x"}"#)) == "open: info must be an object")
        let long = String(repeating: "x", count: 501)
        #expect(reason(posted(#"{"cmd":"enqueue","items":[{"url":"http://h/s","info":{"title":"\#(long)"}}]}"#))
                == "enqueue: items[0]: info: title is longer than 500 characters")
        #expect(reason(posted(#"{"cmd":"open","url":"http://h/s","info":{"url":"ftp://x"}}"#)) == "open: info: url must be http(s)")
    }

    @Test func theTitleReadsAsAStashScenes() {
        var json: [String: Any] = ["id": "1", "title": "Hot Blonde: Test", "date": "2026-10-25"]
        json["studio"] = ["name": "Studio A"]
        let stash = StashSceneDetails(json: json)!
        #expect(full.displayTitle(fallback: "2") == StashTitle.text(details: stash, fileName: "2"))
        #expect(SceneInfo(studio: "S").displayTitle(fallback: "2") == "2 — S")
    }

    @Test func exportsAreNamedAfterTheScene() {
        let stream = URL(string: "http://127.0.0.1:8793/stream/5367369?kind=trailer")!
        #expect(full.fileStem == "2026-10-25 [5367369] Hot Blonde - Test (Ann, Bea)")
        let named = full.namingURL(for: stream)!
        let naming = FrameNaming(directoryTemplate: "%{video-dir}", fileTemplate: "%{video-name}_%{frame:06}")
        #expect(naming.fileName(forVideo: named, frame: 12, seconds: 0.5, format: .jpeg)
                == "2026-10-25 [5367369] Hot Blonde - Test (Ann, Bea)_000012.jpg")
        #expect(FrameNaming.fallbackDirectory(forVideo: named, root: URL(filePath: "/r/")).lastPathComponent
                == "2026-10-25 [5367369] Hot Blonde - Test (Ann, Bea)")
        #expect(SceneInfo(title: "Only").fileStem == "Only")
        #expect(SceneInfo(studio: "S").namingURL(for: stream) == nil)   // nothing to name it by: the stream's own name
        #expect(full.namingURL(for: URL(filePath: "/v/a.mp4")) == nil)   // a file keeps its own name, as a Stash scene's does
    }
}
