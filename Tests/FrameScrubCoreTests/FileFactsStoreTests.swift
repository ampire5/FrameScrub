import Foundation
import FrameScrubCore
import HomeScreenModel
import Testing

@Suite struct FileFactsStoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString)/facts.json")
    }

    @Test func factsSurviveARelaunch() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileFactsStore(url: url)
        #expect(store.all().isEmpty)
        let facts = FileFacts(width: 1920, height: 1080, duration: 65, codec: "HEVC", fps: 30, hdr: false)
        store.set(facts, for: "/v/a.mp4")
        store.save()
        #expect(FileFactsStore(url: url).all() == ["/v/a.mp4": facts])
    }

    @Test func pastTheLimitTheOldestGo() {
        let store = FileFactsStore(url: file(), limit: 4)
        for i in 0..<5 { store.set(FileFacts(duration: Double(i)), for: "/v/\(i).mp4") }
        let kept = store.all()
        #expect(kept.count <= 4 && kept["/v/4.mp4"]?.duration == 4 && kept["/v/0.mp4"] == nil)
    }
}
