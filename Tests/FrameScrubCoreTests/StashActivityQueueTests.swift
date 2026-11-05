import Foundation
import StashKit
import Testing
@testable import FrameScrubCore

private actor ActivityServer {
    var started: [StashActivityRequest] = []
    var completed: [StashActivityRequest] = []
    private var first: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func send(_ request: StashActivityRequest, sceneID: String) async throws {
        started.append(request)
        if started.count == 1 {
            await withCheckedContinuation { first = $0; arrival?.resume(); arrival = nil }
        }
        completed.append(request)
    }
    func waitForFirst() async {
        if first != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func releaseFirst() { first?.resume(); first = nil }
}

@Suite @MainActor struct StashActivityQueueTests {
    @Test func laterSavesWaitForTheEarlierSave() async {
        let server = ActivityServer()
        let queue = StashActivityQueue { try await server.send($0, sceneID: $1) }
        queue.enqueue([.save(resumeTime: 10, playDuration: 1)], sceneID: "scene", tracking: true)
        await server.waitForFirst()
        queue.enqueue([.save(resumeTime: 20, playDuration: 2)], sceneID: "scene", tracking: true)
        #expect(await server.started == [.save(resumeTime: 10, playDuration: 1)])
        await server.releaseFirst()
        await queue.drain()
        #expect(await server.completed == [.save(resumeTime: 10, playDuration: 1), .save(resumeTime: 20, playDuration: 2)])
    }

    @Test func unknownOrDisabledTrackingNeverSendsEvenAtDrain() async {
        let server = ActivityServer()
        let queue = StashActivityQueue { try await server.send($0, sceneID: $1) }
        #expect(!queue.enqueue([.save(resumeTime: 1, playDuration: 1)], sceneID: "scene", tracking: nil))
        #expect(!queue.enqueue([.save(resumeTime: 2, playDuration: 1)], sceneID: "scene", tracking: false))
        await queue.drain()
        #expect(await server.started.isEmpty)
    }

    @Test func pendingSavesCoalesceTheirDurationAndKeepTheNewestPosition() async {
        let server = ActivityServer()
        let queue = StashActivityQueue { try await server.send($0, sceneID: $1) }
        queue.enqueue([.save(resumeTime: 10, playDuration: 1)], sceneID: "scene", tracking: true)
        await server.waitForFirst()
        queue.enqueue([.save(resumeTime: 20, playDuration: 2), .addPlay], sceneID: "scene", tracking: true)
        queue.enqueue([.save(resumeTime: 30, playDuration: 3)], sceneID: "scene", tracking: true)
        await server.releaseFirst()
        await queue.drain()
        #expect(await server.completed == [.save(resumeTime: 10, playDuration: 1), .save(resumeTime: 30, playDuration: 5), .addPlay])
    }

    @Test func separatePlaysArePreservedWhenPendingSavesMerge() async {
        let server = ActivityServer()
        let queue = StashActivityQueue { try await server.send($0, sceneID: $1) }
        queue.enqueue([.save(resumeTime: 10, playDuration: 1)], sceneID: "scene", tracking: true)
        await server.waitForFirst()
        queue.enqueue([.addPlay], sceneID: "scene", tracking: true)
        queue.enqueue([.addPlay], sceneID: "scene", tracking: true)
        await server.releaseFirst()
        await queue.drain()
        #expect(await server.completed.filter { $0 == .addPlay }.count == 2)
    }

    @Test func aFailedWriteDoesNotBlockTheNextScene() async {
        enum Failure: Error { case rejected }
        var delivered: [String] = []
        var failures = 0
        let queue = StashActivityQueue { _, id in if id == "failed" { throw Failure.rejected } }
        queue.enqueue([.addPlay], sceneID: "failed", tracking: true) { _, succeeded in if !succeeded { failures += 1 } }
        queue.enqueue([.addPlay], sceneID: "next", tracking: true) { _, succeeded in if succeeded { delivered.append("next") } }
        await queue.drain()
        #expect(failures == 1)
        #expect(delivered == ["next"])
    }
}
