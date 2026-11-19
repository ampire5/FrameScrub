import Foundation

/// Runs bounded background work with one replaceable pending request. When a slot opens, only the latest
/// submission waiting for it runs.
public final class LatestOnlyWorker<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable (Value) -> Void
    private let limit: Int
    private let canRunTogether: @Sendable (Value, Value) -> Bool
    private let lock = NSLock()
    private var pending: Value?
    private var active: [UUID: Value] = [:]

    public init(label: String, qos: DispatchQoS.QoSClass = .userInitiated, limit: Int = 1,
                canRunTogether: @escaping @Sendable (Value, Value) -> Bool = { _, _ in true },
                handler: @escaping @Sendable (Value) -> Void) {
        self.limit = limit
        self.canRunTogether = canRunTogether
        queue = DispatchQueue(label: label, qos: DispatchQoS(qosClass: qos, relativePriority: 0),
                              attributes: limit > 1 ? .concurrent : [])
        self.handler = handler
    }

    /// Whether a newer value is waiting (a handler that sleeps first can drop its own work).
    public var hasPending: Bool { lock.withLock { pending != nil } }

    public func submit(_ value: Value) {
        let next = lock.withLock {
            pending = value
            return takePending()
        }
        start(next)
    }

    /// Called under the lock. A blocked request cannot take the only pending slot from a later submission.
    private func takePending() -> (UUID, Value)? {
        guard let value = pending, active.count < limit, active.values.allSatisfy({ canRunTogether($0, value) }) else {
            return nil
        }
        let id = UUID()
        active[id] = value
        pending = nil
        return (id, value)
    }

    private func start(_ request: (UUID, Value)?) {
        guard let (id, value) = request else { return }
        queue.async {
            // Release decoded frames (VTDecoderXPCService IOSurfaces) before starting another request.
            autoreleasepool { self.handler(value) }
            let next = self.lock.withLock {
                self.active[id] = nil
                return self.takePending()
            }
            self.start(next)
        }
    }
}
