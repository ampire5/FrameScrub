import Foundation

/// Thread-safe store of ready frames and optional lossless NV12 entries under one byte budget.
/// Over budget it evicts the frames farthest from the focus: distance behind the focus is
/// divided by `backShare` and distance ahead by `1 - backShare`, so a larger share keeps more
/// history. The focus frame itself is never evicted.
// All mutable state is guarded by lock. Migration runs on bounded serial queues outside that lock.
public final class FrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: DecodedFrame] = [:]
    private var generation = 0
    private var decodedInsertions = 0
    private var demotions = 0
    private var promotions = 0
    private var packed: [Int: PackedNV12Frame] = [:]
    private var packable = Set<Int>()
    private var packingDirty = false
    private let packsNV12: Bool
    private let packingQueue = DispatchQueue(label: "framescrub.cache.pack", qos: .utility)
    private let restoringQueue = DispatchQueue(label: "framescrub.cache.restore", qos: .userInitiated)
    private var packingScheduled = false
    private var restoringScheduled = false
    private var tierObserver: (@Sendable (Int, Bool) -> Void)?
    // Four nearby ready samples halved restore CPU in the NV12 display bench. Use
    // two on each side of the focus and leave a margin before demoting on a reversal.
    private static let readyRadius = 2
    private static let packDistance = 2 * readyRadius + 1
    private var undecodable = Set<Int>()
    private var budget: Int
    private var used = 0
    private var focus = 0
    private var backShare = 0.6

    public init(budgetBytes: Int, packsNV12: Bool = false) {
        budget = budgetBytes
        self.packsNV12 = packsNV12
    }

    /// The observer runs after publication and outside the cache lock. It wakes the
    /// filler to expand its plan, retry a failed restore, or deliver a ready frame.
    func observeTierChanges(_ observer: (@Sendable (Int, Bool) -> Void)?) {
        lock.withLock {
            generation += 1
            tierObserver = observer
            packingDirty = true
            scheduleMigrationLocked()
        }
    }

    public var budgetBytes: Int {
        get { lock.withLock { budget } }
        set { lock.withLock { budget = newValue; evictLocked(); scheduleMigrationLocked() } }
    }

    public var usedBytes: Int { lock.withLock { used } }
    public var count: Int { lock.withLock { frames.count + packed.count } }
    public var activity: (decodedInsertions: Int, demotions: Int, promotions: Int) {
        lock.withLock { (decodedInsertions, demotions, promotions) }
    }
    public var packedFrameCount: Int { lock.withLock { packed.count } }

    /// Average size of the frames cached now, or nil when empty. Computed from the current
    /// contents so sizes from a previously opened file never leak into planning for the next.
    public var averageFrameBytes: Int? {
        lock.withLock {
            let count = frames.count + packed.count
            return count == 0 ? nil : used / count
        }
    }

    public func setFocus(_ n: Int, backShare share: Double) {
        lock.withLock {
            if focus != n { packingDirty = true }
            focus = n
            backShare = min(max(share, 0.05), 0.95)
            evictLocked()
            scheduleMigrationLocked()
        }
    }

    public func frame(_ n: Int) -> DecodedFrame? { lock.withLock { frames[n] } }
    /// Whether the frame is resident in either tier.
    public func contains(_ n: Int) -> Bool { lock.withLock { storedLocked(n) } }
    public func hasReadyFrame(_ n: Int) -> Bool { lock.withLock { frames[n] != nil } }

    /// Observes both tiers at the same instant.
    public func residency(_ n: Int) -> (ready: Bool, packed: Bool) {
        lock.withLock { (frames[n] != nil, packed[n] != nil) }
    }

    /// Inspect a bounded seek corridor in one lock acquisition, in travel order.
    public func readyFilmSeekFrames(from origin: Int, to target: Int) -> [Int] {
        guard origin >= 0, target >= 0, (2...TimelineClickMotion.maximumFramePreviewDistance).contains(abs(target - origin))
        else { return [] }
        let step = target > origin ? 1 : -1
        return lock.withLock { stride(from: origin + step, to: target, by: step).filter { frames[$0] != nil } }
    }
    public func isUndecodable(_ n: Int) -> Bool { lock.withLock { undecodable.contains(n) } }

    /// Ready, packed, or known to be undecodable. Packed entries still need a worker restore.
    public func isResolved(_ n: Int) -> Bool { lock.withLock { resolvedLocked(n) } }

    public func insert(_ frame: DecodedFrame) {
        lock.withLock {
            removeLocked(frame.number)
            frames[frame.number] = frame
            if packsNV12, PackedNV12Frame.supports(frame.pixelBuffer) {
                packable.insert(frame.number)
                packingDirty = true
            }
            decodedInsertions += 1
            used += frame.byteSize
            undecodable.remove(frame.number)
            evictLocked()
            scheduleMigrationLocked()
        }
    }

    public func markUndecodable(_ n: Int) {
        lock.withLock {
            if !storedLocked(n) { undecodable.insert(n) }
            scheduleMigrationLocked()
        }
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

    /// Runs of resident frames, including packed entries, for the seek bar.
    public func cachedRanges() -> [ClosedRange<Int>] {
        let keys = lock.withLock { (Array(frames.keys) + Array(packed.keys)).sorted() }
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
            generation += 1
            decodedInsertions = 0
            demotions = 0
            promotions = 0
            frames.removeAll()
            packed.removeAll()
            packable.removeAll()
            packingDirty = false
            undecodable.removeAll()
            used = 0
        }
    }

    /// Evicts frames outside `kept`, farthest from the focus first, until `bytes` more fit in the budget; false when
    /// they still do not.
    public func makeRoom(forBytes bytes: Int, keeping kept: [ClosedRange<Int>]) -> Bool {
        lock.withLock {
            guard used + bytes > budget else { return true }
            let victims = (Array(frames.keys) + Array(packed.keys)).filter { k in k != focus && !kept.contains { $0.contains(k) } }
                .sorted { score($0) > score($1) }
            for k in victims {
                guard used + bytes > budget else { break }
                removeLocked(k)
            }
            return used + bytes <= budget
        }
    }

    private func storedLocked(_ n: Int) -> Bool { frames[n] != nil || packed[n] != nil }
    private func resolvedLocked(_ n: Int) -> Bool { storedLocked(n) || undecodable.contains(n) }

    private func removeLocked(_ n: Int) {
        if let frame = frames.removeValue(forKey: n) { used -= frame.byteSize }
        if let frame = packed.removeValue(forKey: n) { used -= frame.byteSize }
        packable.remove(n)
    }

    private var focusReadyLocked: Bool { frames[focus] != nil || undecodable.contains(focus) }

    private func nextRestoreLocked() -> Int? {
        if packed[focus] != nil { return focus }
        guard focusReadyLocked else { return nil }
        for distance in 1...Self.readyRadius {
            let first = backShare > 0.5 ? focus - distance : focus + distance
            let second = backShare > 0.5 ? focus + distance : focus - distance
            if packed[first] != nil { return first }
            if packed[second] != nil { return second }
        }
        return nil
    }

    private func nextPackLocked() -> DecodedFrame? {
        guard focusReadyLocked && !restoringScheduled else { return nil }
        return packable.lazy.filter { abs($0 - self.focus) >= Self.packDistance }
            .max { score($0) < score($1) }
            .flatMap { frames[$0] }
    }

    private func scheduleMigrationLocked() {
        guard packsNV12, tierObserver != nil else { return }
        if !restoringScheduled, nextRestoreLocked() != nil {
            restoringScheduled = true
            restoringQueue.async { [weak self] in autoreleasepool { self?.restoreOne() } }
        }
        if packingDirty, !packingScheduled, !packable.isEmpty, focusReadyLocked, !restoringScheduled {
            packingDirty = false
            packingScheduled = true
            packingQueue.async { [weak self] in autoreleasepool { self?.packOne() } }
        }
    }

    private func packOne() {
        let work = lock.withLock { (tierObserver == nil ? nil : nextPackLocked(), generation) }
        let result = work.0.flatMap(PackedNV12Frame.init)
        let notification = lock.withLock { () -> ((@Sendable (Int, Bool) -> Void), Int)? in
            packingScheduled = false
            defer { scheduleMigrationLocked() }
            guard let observer = tierObserver, work.1 == generation, let candidate = work.0, abs(candidate.number - focus) >= Self.packDistance,
                  frames[candidate.number]?.pixelBuffer === candidate.pixelBuffer else { return nil }
            packingDirty = true
            guard let result else { packable.remove(candidate.number); return nil }
            removeLocked(candidate.number)
            packed[candidate.number] = result
            demotions += 1
            used += result.byteSize
            return (observer, candidate.number)
        }
        if let (notify, number) = notification { notify(number, false) }
    }

    private func restoreOne() {
        let candidate = lock.withLock { () -> (Int, PackedNV12Frame)? in
            guard tierObserver != nil, let index = nextRestoreLocked(), let entry = packed[index] else { return nil }
            return (index, entry)
        }
        let result = candidate?.1.restore()
        let notification = lock.withLock { () -> ((@Sendable (Int, Bool) -> Void), Int, Bool)? in
            restoringScheduled = false
            defer { scheduleMigrationLocked() }
            guard let observer = tierObserver, let (number, entry) = candidate, packed[number] === entry,
                  abs(number - focus) <= Self.readyRadius else { return nil }
            removeLocked(number)
            if let result {
                frames[number] = result
                packable.insert(number)
                packingDirty = true
                used += result.byteSize
                evictLocked()
            }
            let ready = frames[number] != nil
            if ready { promotions += 1 }
            return (observer, number, ready)
        }
        if let (notify, number, ready) = notification { notify(number, ready) }
    }

    private func evictLocked() {
        guard used > budget else { return }
        let victims = (Array(frames.keys) + Array(packed.keys)).filter { $0 != focus }.sorted { score($0) > score($1) }
        for k in victims {
            guard used > budget else { break }
            removeLocked(k)
        }
    }

    private func score(_ k: Int) -> Double {
        let d = Double(k - focus)
        return d < 0 ? -d / backShare : d / (1 - backShare)
    }
}
