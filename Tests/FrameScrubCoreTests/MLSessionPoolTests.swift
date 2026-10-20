import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

/// Counts what the pool does with its sessions (a real Apple session holds ~2 GB while it is open).
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var created = 0
    private(set) var ended = 0
    private(set) var running = 0
    private(set) var maxRunning = 0
    var failNext = false

    func created_() { lock.withLock { created += 1 } }
    func ended_() { lock.withLock { ended += 1 } }
    func begin() { lock.withLock { running += 1; maxRunning = max(maxRunning, running) } }
    func finish() { lock.withLock { running -= 1 } }
    func shouldFail() -> Bool { lock.withLock { defer { failNext = false }; return failNext } }
}

private final class FakeSession: MLSession, @unchecked Sendable {
    let log: Log
    init(log: Log) { self.log = log; log.created_() }
    func upscale(_ image: CIImage, context: CIContext) async throws -> CIImage {
        log.begin()
        defer { log.finish() }
        try await Task.sleep(for: .milliseconds(20))
        if log.shouldFail() { throw MLUpscaleError.unavailable }
        return image
    }
    func end() { log.ended_() }
}

private func pool(_ log: Log, idle: Double = 60) -> MLSessionPool {
    MLSessionPool(idleSeconds: idle) { _, _ in FakeSession(log: log) }
}

private func image(_ side: Int = 64) -> CIImage {
    CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
}

@Suite struct MLSessionPoolTests {
    @Test func oneSessionServesAllFramesOneAtATime() async throws {
        let log = Log()
        let pool = pool(log)
        let context = CIContext()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try await pool.upscale(image(), context: context) } }
            try await group.waitForAll()
        }
        #expect(log.created == 1)       // before the fix every frame opened its own ~2 GB session
        #expect(log.maxRunning == 1)    // and four export threads ran four of them at once
        #expect(await pool.sessionsCreated == 1)
    }

    @Test func aDifferentSizeReplacesTheSession() async throws {
        let log = Log()
        let pool = pool(log)
        let context = CIContext()
        _ = try await pool.upscale(image(64), context: context)
        _ = try await pool.upscale(image(64), context: context)
        _ = try await pool.upscale(image(128), context: context)
        #expect(log.created == 2)
        #expect(log.ended == 1)
    }

    @Test func anIdleSessionIsClosedAndReopenedOnDemand() async throws {
        let log = Log()
        let pool = pool(log, idle: 0.05)
        let context = CIContext()
        _ = try await pool.upscale(image(), context: context)
        #expect(await eventually { log.ended == 1 })
        _ = try await pool.upscale(image(), context: context)
        #expect(log.created == 2)
    }

    @Test func aBusyPoolIsNotClosedByTheIdleTimer() async throws {
        let log = Log()
        let pool = pool(log, idle: 0.05)
        let context = CIContext()
        for _ in 0..<6 { _ = try await pool.upscale(image(), context: context) }   // 6 x 20 ms, timer 50 ms
        #expect(log.created == 1)
        #expect(log.ended == 0)
    }

    @Test func aFailedSessionIsDroppedAndTheNextCallStartsFresh() async throws {
        let log = Log()
        let pool = pool(log)
        let context = CIContext()
        _ = try await pool.upscale(image(), context: context)
        log.failNext = true
        await #expect(throws: (any Error).self) { _ = try await pool.upscale(image(), context: context) }
        #expect(log.ended == 1)
        _ = try await pool.upscale(image(), context: context)
        #expect(log.created == 2)
    }
}
