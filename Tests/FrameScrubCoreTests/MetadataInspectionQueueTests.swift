import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct MetadataInspectionQueueTests {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var started: [String] = []
        var completed: [String] = []
        var active = 0
        var peak = 0
    }
    @Test func oneActiveAndOnlyTheLatestPendingProbe() async throws {
        let state = State(), release = DispatchSemaphore(value: 0)
        let snapshot = try MediaSource(url: Fixtures.url(Fixtures.h264)).metadata
        let worker = MetadataInspectionQueue(cached: { _ in nil }, probe: { url, _, flag in
            state.lock.withLock {
                state.started.append(url.lastPathComponent); state.active += 1
                state.peak = max(state.peak, state.active)
            }
            defer { state.lock.withLock { state.active -= 1 } }
            if url.lastPathComponent == "first" { _ = release.wait(timeout: .now() + 60) }
            return flag.isCancelled ? nil : snapshot
        })
        func submit(_ name: String) {
            worker.inspect(URL(fileURLWithPath: "/" + name), reading: {}, completed: { _ in
                state.lock.withLock { state.completed.append(name) }
            })
        }
        submit("first")
        for _ in 0..<1000 {
            if state.lock.withLock({ !state.started.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(state.lock.withLock { state.started == ["first"] })
        submit("second"); submit("third")
        release.signal()
        for _ in 0..<1000 {
            if state.lock.withLock({ state.completed == ["third"] }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(state.lock.withLock { state.peak == 1 && state.started == ["first", "third"] && state.completed == ["third"] })
        worker.cancel()
    }
}
