import Foundation

/// One asynchronous operation and one replaceable pending value. Invalidation drops deliveries,
/// not the in-flight GPU buffers: their owner stays alive until the operation actually finishes.
@MainActor public final class LatestVideoWork<Input: Sendable, Output: Sendable> {
    public var onResult: ((Input, Output) -> Void)?
    private let process: @Sendable (Input) async -> Output
    private var running = false
    private var waitingForSettle = false
    private var delayedStart: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var pending: (Input, UInt64, UInt64)?

    public init(process: @escaping @Sendable (Input) async -> Output) { self.process = process }
    public func submit(_ input: Input, after delay: Double = 0) {
        revision &+= 1
        pending = (input, generation, revision)
        delayedStart?.cancel(); delayedStart = nil
        waitingForSettle = delay.isFinite && delay > 0
        if waitingForSettle {
            let serial = revision
            let action = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.revision == serial else { return }
                    self.waitingForSettle = false; self.delayedStart = nil
                    self.startNext()
                }
            }
            delayedStart = action
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        } else { startNext() }
    }
    public func invalidate() {
        generation &+= 1; revision &+= 1; pending = nil
        delayedStart?.cancel(); delayedStart = nil; waitingForSettle = false
    }
    private func startNext() {
        guard !running, !waitingForSettle, let (input, epoch, serial) = pending else { return }
        pending = nil; running = true
        let process = process
        Task.detached(priority: .userInitiated) { [weak self] in
            let output = await process(input)
            await self?.finished(input, output: output, epoch: epoch, serial: serial)
        }
    }
    private func finished(_ input: Input, output: Output, epoch: UInt64, serial: UInt64) {
        running = false
        if generation == epoch, revision == serial { onResult?(input, output) }
        startNext()
    }
}
