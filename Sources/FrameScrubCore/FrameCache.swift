import Foundation

/// Thread-safe store of decoded frames keyed by frame number, bounded by a byte budget.
/// Over budget it evicts the frames farthest from the focus: distance behind the focus is
/// divided by `backShare` and distance ahead by `1 - backShare`, so a larger share keeps more
/// history. The focus frame itself is never evicted.
public final class FrameCache {
    private let lock = NSLock()
    private var frames: [Int: DecodedFrame] = [:]
    private var undecodable = Set<Int>()
    private var budget: Int
    private var used = 0
    private var focus = 0
    private var backShare = 0.6

    public init(budgetBytes: Int) {
        budget = budgetBytes
    }

    public var budgetBytes: Int {
        get { lock.withLock { budget } }
        set { lock.withLock { budget = newValue; evictLocked() } }
    }

    public var usedBytes: Int { lock.withLock { used } }
    public var count: Int { lock.withLock { frames.count } }

    /// Average size of the frames cached now, or nil when empty. Computed from the current
    /// contents so sizes from a previously opened file never leak into planning for the next.
    public var averageFrameBytes: Int? {
        lock.withLock { frames.isEmpty ? nil : used / frames.count }
    }

    public func setFocus(_ n: Int, backShare share: Double) {
        lock.withLock {
            focus = n
            backShare = min(max(share, 0.05), 0.95)
            evictLocked()
        }
    }

    public func frame(_ n: Int) -> DecodedFrame? { lock.withLock { frames[n] } }
    public func contains(_ n: Int) -> Bool { lock.withLock { frames[n] != nil } }
    public func isUndecodable(_ n: Int) -> Bool { lock.withLock { undecodable.contains(n) } }

    /// Cached or known to be undecodable: either way there is nothing left to decode.
    public func isResolved(_ n: Int) -> Bool { lock.withLock { resolvedLocked(n) } }

    public func insert(_ frame: DecodedFrame) {
        lock.withLock {
            if let old = frames.updateValue(frame, forKey: frame.number) { used -= old.byteSize }
            used += frame.byteSize
            undecodable.remove(frame.number)
            evictLocked()
        }
    }

    public func markUndecodable(_ n: Int) {
        lock.withLock { if frames[n] == nil { undecodable.insert(n) } }
    }

    /// The cached frame closest to `n`; ties go to the lower frame number.
    public func nearestAvailable(to n: Int) -> DecodedFrame? {
        lock.withLock {
            var best: DecodedFrame?
            for (k, frame) in frames {
                guard let current = best else { best = frame; continue }
                let d = abs(k - n), bestDistance = abs(current.number - n)
                if d < bestDistance || (d == bestDistance && k < current.number) { best = frame }
            }
            return best
        }
    }

    /// The cached frame in `range` closest to `n` (playback skipping frames shows the nearest one it has).
    public func nearest(to n: Int, within range: ClosedRange<Int>) -> DecodedFrame? {
        lock.withLock {
            var best: DecodedFrame?
            for (k, frame) in frames where range.contains(k) {
                if best.map({ abs(k - n) < abs($0.number - n) || (abs(k - n) == abs($0.number - n) && k < $0.number) }) ?? true {
                    best = frame
                }
            }
            return best
        }
    }

    /// The maximal run of resolved frame numbers containing `n`, or nil if `n` is unresolved.
    public func resolvedRun(around n: Int) -> ClosedRange<Int>? {
        lock.withLock {
            guard resolvedLocked(n) else { return nil }
            var lower = n, upper = n
            while resolvedLocked(lower - 1) { lower -= 1 }
            while resolvedLocked(upper + 1) { upper += 1 }
            return lower...upper
        }
    }

    /// Runs of cached (decoded) frames, for the seek bar.
    public func cachedRanges() -> [ClosedRange<Int>] {
        let keys = lock.withLock { frames.keys.sorted() }
        var ranges: [ClosedRange<Int>] = []
        for k in keys {
            if let last = ranges.last, last.upperBound + 1 == k {
                ranges[ranges.count - 1] = last.lowerBound...k
            } else {
                ranges.append(k...k)
            }
        }
        return ranges
    }

    public func removeAll() {
        lock.withLock {
            frames.removeAll()
            undecodable.removeAll()
            used = 0
        }
    }

    /// Evicts frames outside `kept`, farthest from the focus first, until `bytes` more fit in the budget; false when
    /// they still do not.
    public func makeRoom(forBytes bytes: Int, keeping kept: [ClosedRange<Int>]) -> Bool {
        lock.withLock {
            guard used + bytes > budget else { return true }
            let victims = frames.keys.filter { k in k != focus && !kept.contains { $0.contains(k) } }
                .sorted { score($0) > score($1) }
            for k in victims {
                guard used + bytes > budget else { break }
                if let frame = frames.removeValue(forKey: k) { used -= frame.byteSize }
            }
            return used + bytes <= budget
        }
    }

    private func resolvedLocked(_ n: Int) -> Bool { frames[n] != nil || undecodable.contains(n) }

    private func evictLocked() {
        guard used > budget else { return }
        let victims = frames.keys.filter { $0 != focus }.sorted { score($0) > score($1) }
        for k in victims {
            guard used > budget else { break }
            if let frame = frames.removeValue(forKey: k) { used -= frame.byteSize }
        }
    }

    private func score(_ k: Int) -> Double {
        let d = Double(k - focus)
        return d < 0 ? -d / backShare : d / (1 - backShare)
    }
}
