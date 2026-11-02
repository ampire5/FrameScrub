import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FolderChangeMonitorTests {
    @Test func changesAreDeliveredAndStopSuppressesFurtherDelivery() throws {
        let folder: URL
        if let root = ProcessInfo.processInfo.environment["FRAMESCRUB_WATCH_TEST_ROOT"] {
            folder = URL(fileURLWithPath: root).appendingPathComponent("FrameScrub-watch-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } else { folder = makeTemporaryDirectory() }
        defer { try? FileManager.default.removeItem(at: folder) }
        let changed = DispatchSemaphore(value: 0)
        let monitor = FolderChangeMonitor(callbackQueue: DispatchQueue(label: "test.folder-change"))
        monitor.watch(folder) { changed.signal() }
        #expect(changed.wait(timeout: .now() + 2) == .success) // descriptor armed; reconcile the open race
        let video = folder.appendingPathComponent("video.mp4")
        try Data([1]).write(to: video)
        #expect(changed.wait(timeout: .now() + 2) == .success)
        try FileManager.default.moveItem(at: video, to: folder.appendingPathComponent("renamed.mp4"))
        #expect(changed.wait(timeout: .now() + 2) == .success)
        monitor.stop()
        try Data([2]).write(to: folder.appendingPathComponent("after-stop.mp4"))
        #expect(changed.wait(timeout: .now() + 0.5) == .timedOut)
    }
}
