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
        let facts = FileFacts(width: 1920, height: 1080, duration: 65, codec: "HEVC", fps: 30, transfer: .sdr)
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

    /// A facts file of `count` entries `/f/<i>.mp4`, written as the store writes it.
    private func bigFile(_ count: Int) throws -> URL {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var facts: [String: FileFacts] = [:]
        for i in 0..<count { facts["/f/\(i).mp4"] = FileFacts(width: 1920, height: 1080, duration: Double(i), codec: "HEVC") }
        try JSONEncoder().encode(facts).write(to: url)
        return url
    }

    /// Minor 17 of the strip's review: `set` on the main thread waited for a background `all()` decoding the file.
    /// Async, with no semaphore: a test thread blocked in a wait takes a cooperative thread from the pool that
    /// `FrameUpscaler`'s `runBlocking` also waits on, and the whole suite stalled (2026-10-28).
    @Test func setDoesNotWaitForTheFirstRead() async throws {
        let url = try bigFile(50_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileFactsStore(url: url, limit: 100_000)
        let read = Task.detached { store.all().count }
        try await Task.sleep(nanoseconds: 2_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        store.set(FileFacts(duration: 1), for: "/x.mp4")
        let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        _ = await read.value
        #expect(took < 5, "set took \(took) ms")
        let all = store.all()
        #expect(all["/x.mp4"]?.duration == 1 && all["/f/49999.mp4"]?.duration == 49999)
    }

    @Test func setBeforeLoadIsKept() throws {
        let url = try bigFile(3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileFactsStore(url: url)
        store.set(FileFacts(duration: 7), for: "/f/0.mp4")
        store.set(FileFacts(duration: 8), for: "/new.mp4")
        let all = store.all()
        #expect(all.count == 4 && all["/f/0.mp4"]?.duration == 7 && all["/new.mp4"]?.duration == 8)
        #expect(all["/f/2.mp4"]?.duration == 2)
    }
}
