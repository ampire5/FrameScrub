import Foundation

/// Finds where the next or previous scene starts, in the background, for the scene jumps. Keyframes that differ enough
/// are candidates, checked frame by frame inside their GOP. Keeps the looks of the keyframes it decoded and the verdicts
/// of the GOPs it checked for the file, so jumping back and forth is quick, and after a find looks one scene further
/// ahead (at most `lookahead` new keyframes and `prefetchVerifications` GOP checks). One serial queue does all the
/// decoding.
public final class SceneSearch: @unchecked Sendable {
    public enum Result: Equatable, Sendable {
        case found(Int)
        /// No scene start that way: the edge of the file.
        case none
        /// Out of `searchTime`: no scene start up to this keyframe (the next find goes on from what it looked at).
        case notWithin(Int)
        case cancelled
        /// The file could not be opened or decoded; the reason is short, for the OSD.
        case failed(String)
    }

    private let url: URL
    private let rotationClockwise: Int
    private let readCache: ReadCache?
    private let preferHardware: Bool
    private let queue = DispatchQueue(label: "framescrub.scenesearch", qos: .userInitiated)

    // Guarded by `lock`: shared between the caller and the queue.
    private let lock = NSLock()
    private var currentThreshold: Double
    private var currentLookahead: Int
    private var currentPrefetchVerifications = 2
    private var currentCheckTime: Double
    private var currentSearchTime: Double
    private var latestIndex: FrameIndex
    private var indexChanged = false
    private var current: CancellationFlag?
    private var closed = false
    /// A copy of the cached looks for `statusText`.
    private var seen: [Int: KeyframeLook] = [:]
    /// A copy of `verified` for `statusText`.
    private var checked: [Int: [Int]] = [:]

    // Only touched on `queue`.
    private var looks: KeyframeLooks?
    /// The hard cuts found in the GOP of each checked candidate, keyed by its later keyframe (empty: none).
    private var verified: [Int: [Int]] = [:]


    public init(url: URL, index: FrameIndex, rotationClockwise: Int, readCache: ReadCache?,
                threshold: Double, lookahead: Int, checkTime: Double = 1, searchTime: Double = 4, preferHardware: Bool,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.url = url
        self.rotationClockwise = rotationClockwise
        self.readCache = readCache
        self.preferHardware = preferHardware
        currentThreshold = threshold
        currentLookahead = lookahead
        currentCheckTime = checkTime
        currentSearchTime = searchTime
        latestIndex = index
        self.now = now
    }

    private let now: @Sendable () -> Double

    /// Seconds a find may spend checking GOPs frame by frame (0.2–1.5 s each for 4K from the NAS), counted over its
    /// checks only; after that its candidates are judged by their keyframes alone. 0: keyframes only.
    public var checkTime: Double {
        get { lock.withLock { currentCheckTime } }
        set { lock.withLock { currentCheckTime = newValue } }
    }

    /// Seconds a find may search before it gives up with `.notWithin`.
    public var searchTime: Double {
        get { lock.withLock { currentSearchTime } }
        set { lock.withLock { currentSearchTime = newValue } }
    }

    /// The cache keeps looks, not decisions: a new threshold applies at once.
    public var threshold: Double {
        get { lock.withLock { currentThreshold } }
        set { lock.withLock { currentThreshold = newValue } }
    }

    /// How many new keyframes the prefetch after a find may decode.
    public var lookahead: Int {
        get { lock.withLock { currentLookahead } }
        set { lock.withLock { currentLookahead = newValue } }
    }

    /// How many GOPs the prefetch after a find may check: a check on a 4K file from the NAS takes 0.2 to 1.5 s.
    var prefetchVerifications: Int {
        get { lock.withLock { currentPrefetchVerifications } }
        set { lock.withLock { currentPrefetchVerifications = newValue } }
    }

    /// The exact index replaces the approximate one; the queue takes it before its next find.
    public func updateIndex(_ index: FrameIndex) {
        lock.withLock {
            latestIndex = index
            indexChanged = true
        }
    }

    /// "Scenes: 42 keyframes seen, 7 cuts, 3 GOPs checked · threshold 45". Cuts are the ones known among adjacent
    /// cached keyframes: the hard cuts of checked GOPs, and candidates taken at the keyframe (dark keyframes between,
    /// or a checked GOP without a hard cut whose keyframes differ by `SceneNavigator.transitionThreshold`).
    public var statusText: String {
        let (looks, verified, threshold) = lock.withLock { (seen, checked, currentThreshold) }
        var cuts = 0
        var previous: SceneSignature?
        var darkBetween = false
        for frame in looks.keys.sorted() {
            guard case .picture(let b) = looks[frame]! else {
                darkBetween = previous != nil
                continue
            }
            if let a = previous {
                let difference = a.difference(b)
                if difference >= threshold {
                    if darkBetween {
                        cuts += 1
                    } else if let found = verified[frame] {
                        cuts += found.isEmpty ? (difference >= SceneNavigator.transitionThreshold ? 1 : 0) : found.count
                    }
                }
            }
            previous = b
            darkBetween = false
        }
        let shown = threshold.isFinite && threshold == threshold.rounded() && abs(threshold) < 1e9
            ? String(Int(threshold)) : String(format: "%.1f", threshold)
        return "Scenes: \(looks.count) keyframes seen, \(cuts) cuts, \(verified.count) GOPs checked · threshold \(shown)"
    }

    /// The scene start `scenes` scenes away from `position` in `direction` (+1 later, -1 earlier). Completion is
    /// called once, on the main queue. A new `find` or `cancel()` ends the previous one with `.cancelled`.
    public func find(from position: Int, direction: Int, scenes: Int, completion: @escaping @Sendable (Result) -> Void) {
        let flag = CancellationFlag()
        let isClosed: Bool = lock.withLock {
            current?.cancel()
            current = flag
            return closed
        }
        if isClosed { flag.cancel() }
        queue.async {
            let result = self.run(position: position, direction: direction, scenes: scenes, flag: flag)
            // Callers cancel on main: a cancel that comes after the search finished still makes its result stale.
            DispatchQueue.main.async { completion(flag.isCancelled ? .cancelled : result) }
            if case .found(let start) = result { self.prefetch(from: start, direction: direction, flag: flag) }
        }
    }

    public func cancel() {
        lock.withLock { current?.cancel() }
    }

    /// Cancels the search and lets go of the decoder. With `wait`, returns only once the decoder is gone (the file is
    /// closed): a cancelled search stops within one frame or keyframe decode. For a delete; opens and shutdowns don't wait.
    public func close(wait: Bool = false) {
        lock.withLock {
            closed = true
            current?.cancel()
        }
        if wait {
            queue.sync { looks = nil }
        } else {
            queue.async { self.looks = nil }
        }
    }

    /// Blocks until the queue has finished what was submitted so far (for tests).
    func waitUntilIdle() {
        queue.sync {}
    }

    /// Whether the decoder is still open (for tests).
    var hasDecoder: Bool { queue.sync { looks != nil } }

    /// The number of keyframe looks cached (for tests).
    var cachedLookCount: Int { lock.withLock { seen.count } }

    // MARK: - On the queue

    private func run(position: Int, direction: Int, scenes: Int, flag: CancellationFlag) -> Result {
        guard !flag.isCancelled else { return .cancelled }
        do {
            let started = now()
            let (checkTime, searchTime) = lock.withLock { (currentCheckTime, currentSearchTime) }
            let looks = try preparedLooks()
            switch try search(looks, position: position, direction: direction, scenes: scenes, budget: nil,
                              verificationBudget: nil, checkTime: checkTime, searchUntil: started + searchTime,
                              flag: flag) {
            case .found(let frame): return .found(frame)
            case .none: return .none
            case .stopped(let frame): return .notWithin(frame)
            }
        } catch {
            // The edge of the file is `.none`; this is a file that cannot be opened or read.
            return flag.isCancelled || error is CancellationError ? .cancelled : .failed(String(describing: error))
        }
    }

    /// One more scene in the same direction, decoding at most `lookahead` new keyframes and checking at most
    /// `prefetchVerifications` GOPs; the next find cancels it.
    private func prefetch(from start: Int, direction: Int, flag: CancellationFlag) {
        guard let looks, lookahead > 0 else { return }
        _ = try? search(looks, position: start, direction: direction, scenes: 1, budget: lookahead,
                        verificationBudget: prefetchVerifications, checkTime: nil, searchUntil: nil, flag: flag)
    }

    /// The looks for the file, created on first use, with the latest index applied.
    private func preparedLooks() throws -> KeyframeLooks {
        let (index, changed): (FrameIndex, Bool) = lock.withLock {
            defer { indexChanged = false }
            return (latestIndex, indexChanged)
        }
        if let looks {
            if changed {
                // Frame numbers of an approximate index are estimates: the verdicts filed under them go with the looks.
                if index.isExact != looks.index.isExact { verified.removeAll() }
                looks.index = index
                publish(looks)
            }
            return looks
        }
        // A file that fails to open (a network hiccup) is tried again by the next find.
        let opened = try KeyframeLooks(url: url, index: index, rotationClockwise: rotationClockwise, readCache: readCache,
                                       preferHardware: preferHardware)
        looks = opened
        return opened
    }

    private enum Outcome {
        case found(Int)
        case none
        /// A budget or deadline ran out with the chain at this keyframe.
        case stopped(Int)
    }

    /// Walks keyframes from the one at or before `position` until the navigator decides, checking the GOPs of the
    /// candidates it names. With a `budget`, stops rather than decode more than that many keyframes not yet cached; with
    /// a `verificationBudget`, rather than check more than that many GOPs. Once its checks took `checkTime` seconds no
    /// GOP is checked (one under way is given up) and the keyframes decide; past `searchUntil` (uptime) it stops before
    /// the next keyframe.
    private func search(_ looks: KeyframeLooks, position: Int, direction: Int, scenes: Int, budget: Int?,
                        verificationBudget: Int?, checkTime: Double?, searchUntil: Double?,
                        flag: CancellationFlag) throws -> Outcome {
        var decoded = 0
        var verifications = 0
        var checkLeft = checkTime ?? .infinity
        var mayVerify = checkLeft > 0
        func look(at frame: Int) throws -> KeyframeLook? {
            if let known = looks.cached[frame] { return known }
            if let budget, decoded >= budget { return nil }
            guard !flag.isCancelled else { throw CancellationError() }
            decoded += 1
            let look = try autoreleasepool { try looks.look(at: frame) }
            publish(looks)
            return look
        }
        guard !flag.isCancelled else { throw CancellationError() }
        let index = looks.index
        // Each decoding call drains its own autorelease pool (as `KeyframeLooks` does inside): the frames that Core
        // Image / CoreVideo objects hold are IOSurfaces of VTDecoderXPCService, which a long search piled up by gigabytes.
        let k0 = try autoreleasepool { try looks.keyframe(atOrBefore: position) }
        guard let first = try look(at: k0) else { return .stopped(k0) }
        var chain: [(frame: Int, look: KeyframeLook)] = [(k0, first)]
        // Backwards, a cut between k0 and the playhead lies in the GOP after k0: the chain starts at the keyframe after it.
        // Within `minBackSeconds` of k0 no such cut would count.
        if direction < 0, index.seconds(forFrame: position) - index.seconds(forFrame: k0) > SceneNavigator.defaultMinBackSeconds,
           let k1 = try autoreleasepool(invoking: { try looks.neighbour(of: k0, direction: 1) }) {
            guard let k1Look = try look(at: k1) else { return .stopped(k0) }
            chain.insert((k1, k1Look), at: 0)
        }
        var atEdge = false
        while true {
            let navigator = SceneNavigator(threshold: threshold)
            switch navigator.step(position: position, direction: direction, scenes: scenes, chain: chain, atEdge: atEdge,
                                  verified: verified, mayVerify: mayVerify, seconds: { index.seconds(forFrame: $0) }) {
            case .found(let frame):
                guard !flag.isCancelled else { throw CancellationError() }
                return .found(frame)
            case .none:
                return .none
            case .needVerification(let from, let through):
                guard !flag.isCancelled else { throw CancellationError() }
                if let verificationBudget, verifications >= verificationBudget { return .stopped(chain.last!.frame) }
                verifications += 1
                let checkUntil = now() + checkLeft
                // A check that fails (a decode error) or runs out of time is not filed: the next find tries again.
                do {
                    verified[through] = try autoreleasepool {
                        try looks.cuts(from: from, through: through, isCancelled: { flag.isCancelled || self.now() >= checkUntil })
                    }
                } catch is CancellationError where !flag.isCancelled {
                    mayVerify = false
                }
                checkLeft = checkUntil - now()
                if checkLeft <= 0 { mayVerify = false }
                publish(looks)
            case .needNeighbour(let frame, let towards):
                guard !flag.isCancelled else { throw CancellationError() }
                // A spent prefetch budget costs no further seek.
                if let budget, decoded >= budget { return .stopped(frame) }
                if let searchUntil, now() >= searchUntil { return .stopped(frame) }
                if let next = try autoreleasepool(invoking: { try looks.neighbour(of: frame, direction: towards) }) {
                    guard let nextLook = try look(at: next) else { return .stopped(frame) }
                    chain.append((next, nextLook))
                } else {
                    atEdge = true
                }
            }
        }
    }

    private func publish(_ looks: KeyframeLooks) {
        let (cached, verified) = (looks.cached, verified)
        lock.withLock {
            seen = cached
            checked = verified
        }
    }
}
