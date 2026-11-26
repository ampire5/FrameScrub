import Foundation
import FrameScrubCore

/// Owns the blocking preparations for a window's ordinary opens. The controller owns cancellation
/// and decides whether to apply each answer on the main actor.
@MainActor final class FileOpenPreparation {
    typealias Answer = (result: Result<PreparedOpen, Error>, facts: URL?)

    private struct Request {
        let work: @Sendable () -> Answer
        let discardPending: () -> Void
        let complete: (Answer?) -> Void
    }
    private struct Active {
        var complete: ((Answer?) -> Void)?
    }

    private let queue = DispatchQueue(label: "framescrub.file-open", qos: .userInitiated, attributes: .concurrent)
    // Two slots let the latest open get past one blocked filesystem call. See docs/bench/2026-11-26-window-lifecycle.md.
    private let limit: Int
    private var active: [UUID: Active] = [:]
    private var pending: Request?

    init(limit: Int = 2) { self.limit = limit }

    func submit(_ work: @escaping @Sendable () -> Answer, discardPending: @escaping () -> Void,
                complete: @escaping (Answer?) -> Void) {
        cancelPending()
        pending = Request(work: work, discardPending: discardPending, complete: complete)
        startNext()
    }

    func cancel() {
        cancelPending()
        for id in Array(active.keys) {
            guard let complete = active[id]?.complete else { continue }
            active[id]?.complete = nil
            supersede(complete)
        }
    }

    private func cancelPending() {
        guard let request = pending else { return }
        pending = nil
        request.discardPending()
        supersede(request.complete)
    }

    private func supersede(_ complete: @escaping (Answer?) -> Void) {
        // Preserve asynchronous completion so a callback cannot reenter a half-finished open or close.
        DispatchQueue.main.async { complete(nil) }
    }

    private func startNext() {
        guard active.count < limit, let request = pending else { return }
        pending = nil
        let id = UUID(), work = request.work
        active[id] = Active(complete: request.complete)
        queue.async {
            let answer = autoreleasepool(invoking: work)
            DispatchQueue.main.async {
                let complete = self.active.removeValue(forKey: id)?.complete
                self.startNext()
                if let complete { complete(answer) } else { try? answer.result.get().discard() }
            }
        }
    }
}
