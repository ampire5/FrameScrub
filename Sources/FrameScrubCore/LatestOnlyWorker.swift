import Foundation

/// Runs `handler` on its own queue for the most recently submitted value only: while the handler is busy,
/// newer submissions overwrite older ones that have not started.
public final class LatestOnlyWorker<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable (Value) -> Void
    private let lock = NSLock()
    private var pending: Value?
    private var running = false

    public init(label: String, handler: @escaping @Sendable (Value) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.handler = handler
    }

    public func submit(_ value: Value) {
        let start: Bool = lock.withLock {
            pending = value
            if running { return false }
            running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let next: Value? = lock.withLock {
                guard let value = pending else { running = false; return nil }
                pending = nil
                return value
            }
            guard let value = next else { return }
            // Its own pool per value: the drain can loop for as long as submissions keep coming, and the Core Image /
            // CoreVideo objects a handler leaves autoreleased hold decoded frames (VTDecoderXPCService IOSurfaces).
            autoreleasepool { handler(value) }
        }
    }
}
