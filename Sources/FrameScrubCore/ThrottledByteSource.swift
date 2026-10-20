import Foundation

/// Wraps a `ByteSource` and sleeps after reads so that, on average, no more than `bytesPerSecond`
/// pass through it (a clip copy leaves the network to playback). `bytesPerSecond <= 0` = no limit.
/// Credit saved up while idle (a stalled share) is capped at `maxCredit`, so a stall is not followed by a burst.
public final class ThrottledByteSource: ByteSource, @unchecked Sendable {
    private static let maxCredit: TimeInterval = 0.5

    private let base: ByteSource
    private let bytesPerSecond: Int
    private let lock = NSLock()
    private var started: Date?
    private var bytesRead = 0

    public var size: Int64 { base.size }

    public init(_ base: ByteSource, bytesPerSecond: Int) {
        self.base = base
        self.bytesPerSecond = bytesPerSecond
    }

    public func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        guard bytesPerSecond > 0 else { return try base.read(at: offset, count: count, into: buffer) }
        lock.withLock { if started == nil { started = Date() } }
        let n = try base.read(at: offset, count: count, into: buffer)
        // Sleeps outside the lock, so concurrent readers wait for their own share of the budget.
        let wait = lock.withLock { () -> TimeInterval in
            let now = Date()
            var elapsed = now.timeIntervalSince(started!)
            let credit = elapsed - Double(bytesRead) / Double(bytesPerSecond)
            if credit > Self.maxCredit {
                started = started!.addingTimeInterval(credit - Self.maxCredit)
                elapsed -= credit - Self.maxCredit
            }
            bytesRead += n
            return Double(bytesRead) / Double(bytesPerSecond) - elapsed
        }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return n
    }
}
