import Foundation
import FrameScrubCore
import Testing

@Suite struct DurationStoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("durations-\(UUID().uuidString)/durations.json")
    }

    @Test func lengthsSurviveARelaunch() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DurationStore(url: url)
        #expect(store.all().isEmpty)
        store.set(65, for: "/v/a.mp4")
        store.save()
        #expect(DurationStore(url: url).all() == ["/v/a.mp4": 65])
    }

    @Test func pastTheLimitTheOldestGo() {
        let store = DurationStore(url: file(), limit: 4)
        for i in 0..<5 { store.set(Double(i), for: "/v/\(i).mp4") }
        let kept = store.all()
        #expect(kept.count <= 4 && kept["/v/4.mp4"] == 4 && kept["/v/0.mp4"] == nil)
    }
}
