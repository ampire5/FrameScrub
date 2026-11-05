import Foundation
import StashKit

/// One server write at a time, including the quit barrier. Unsent saves for one scene are coalesced: their
/// durations add up and only the newest resume point is retained. Waiting batches do not create network tasks.
@MainActor public final class StashActivityQueue {
    public typealias Send = @Sendable (StashActivityRequest, String) async throws -> Void
    public typealias Completion = @MainActor @Sendable (StashActivityRequest, Bool) -> Void
    private struct Batch {
        let sceneID: String
        var requests: [StashActivityRequest]
        var completion: Completion
    }
    private let send: Send
    private var pending: [Batch] = []
    private var worker: Task<Void, Never>?

    public init(send: @escaping Send) { self.send = send }

    /// Unknown tracking settings are treated as unavailable, including at shutdown.
    @discardableResult public func enqueue(_ requests: [StashActivityRequest], sceneID: String, tracking: Bool?,
                                          completion: @escaping Completion = { _, _ in }) -> Bool {
        guard tracking == true, !requests.isEmpty else { return false }
        if let index = pending.firstIndex(where: { $0.sceneID == sceneID }) {
            pending[index].requests = Self.merged(pending[index].requests, requests)
            pending[index].completion = completion
        } else {
            pending.append(Batch(sceneID: sceneID, requests: requests, completion: completion))
        }
        if worker == nil {
            worker = Task { await run() }
        }
        return true
    }

    /// A snapshot used by the application's asynchronous termination barrier. It includes already queued saves
    /// even when the final sample has no additional watched time.
    public var pendingWork: Task<Void, Never>? { worker }

    public func drain() async {
        while let worker { await worker.value }
    }

    private func run() async {
        while !pending.isEmpty {
            let batch = pending.removeFirst()
            for request in batch.requests {
                do {
                    try await send(request, batch.sceneID)
                    batch.completion(request, true)
                } catch {
                    batch.completion(request, false)
                }
            }
        }
        worker = nil
    }

    private static func merged(_ earlier: [StashActivityRequest], _ later: [StashActivityRequest]) -> [StashActivityRequest] {
        var position: Double?, duration = 0.0, plays = 0
        for request in earlier + later {
            switch request {
            case let .save(resumeTime, playDuration): position = resumeTime; duration += playDuration
            case .addPlay: plays += 1
            }
        }
        var result: [StashActivityRequest] = []
        if let position { result.append(.save(resumeTime: position, playDuration: duration)) }
        result.append(contentsOf: repeatElement(.addPlay, count: plays))
        return result
    }
}
