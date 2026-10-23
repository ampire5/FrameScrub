import Foundation
import QuartzCore

public enum FillMode: Sendable { case playing, paused, reversing }

/// Keeps a FrameCache filled around the focus frame with two background decoders, each with
/// its own demuxer:
/// - forward: decodes sequentially from the focus upward (this also feeds playback);
/// - backward (paused and reversing): decodes chunks that end just below the cached run containing the
///   focus, starting from the chunk's keyframe, so stepping backwards never waits on a decode. While playing backward
///   (reverse playback spec §4) the chunks follow one another down the file and may skip frames (§5).
public final class CacheFiller {
    public let cache: FrameCache
    /// Called on a worker thread after a frame has been inserted into the cache.
    public var onInsert: ((Int) -> Void)?
    /// Called on a worker thread with the first decoding error (later ones only update `lastError`).
    public var onError: ((Error) -> Void)?
    /// Called on the forward worker's thread with a `requestKeyframe` id and the frame it landed on
    /// (the request's `from` when it failed).
    public var onLanded: ((_ id: Int, _ frame: Int) -> Void)?

    private let url: URL
    private let readCache: ReadCache?
    private var hardwarePreferred: Bool
    private let estimatedFrameBytes: Int
    private let playbackLookahead: Int
    private let condition = NSCondition()
    private let finished = DispatchGroup()
    private var index: FrameIndex
    private var indexVersion = 0
    private var focus = 0
    /// The A–B loop while one is active: the window stays inside it (see `windowLocked`).
    private var loop: ClosedRange<Int>?
    private var mode = FillMode.paused
    private var direction = 0
    private var running = false
    private var backend: DecoderBackendKind?
    private var codec = ""
    private var error: Error?
    private var creationAttempts = 0
    private var forwardSeekCount = 0
    private var poolReleaseCount = 0
    /// The chunk the backward worker is decoding: the forward worker leaves its frames alone.
    private var backwardChunk: ClosedRange<Int>?
    private var keyframeRequest: (id: Int, target: Int, from: Int, direction: Int)?
    /// Reversing: the last frame of the next chunk (the one below the chunk planned last).
    private var reverseNext: Int?
    private var reverseSpeed = 1.0
    private var reverseFrameRate = 30.0
    private var level: ReverseLevel?
    /// Per level, frames of video a chunk got through per second of decoding (exponential average over chunks) and
    /// when it was last measured: a level not measured for `measurementLifetime` is tried again for a new speed.
    private var coverage: [ReverseLevel: (value: Double, at: Double)] = [:]
    static let measurementLifetime = 10.0
    /// Reversing jumps (a seek, the loop, a turn, a new index): a chunk given up for one is not a slow chunk.
    private var reverseJumps = 0
    /// Seconds a reversing chunk takes (exponential average): how far playback moves while one decodes.
    private var chunkSeconds: Double?
    /// Tests: a level that never changes.
    var fixedReverseLevel: ReverseLevel?
    private let now: () -> Double
    /// The last jump: a focus move onto a frame not in the cache, other than a short step backward.
    private var jumpedAt = -Double.infinity
    private var jumpFocus: Int?

    /// Gaps up to this many frames are decoded through instead of seeking.
    private static let sequentialGap = 48
    /// Windows are filled to this fraction of the budget so eviction never fights the fillers.
    private static let fillRatio = 0.9
    /// Largest backward chunk, as a fraction of the budget.
    private static let chunkRatio = 0.4
    /// A hardware decoder whose pool keeps more unused buffers than this share of the budget (at least
    /// `minPoolSurplus` frames) is replaced where that costs nothing: before a seek and while its worker waits.
    /// Otherwise each worker's pool keeps as many frames as it ever held in the cache: playing 4K and then stepping
    /// back, VTDecoderXPCService held 2.4× the budget (1.2× with this).
    private static let poolSurplusRatio = 0.1
    private static let minPoolSurplus = 8
    /// After this many consecutive failures to create a decoder, a worker stops trying (and
    /// marks what it was asked for undecodable) until the index changes.
    static let maxCreationFailures = 3
    /// Spec §3.3: after a jump the backward worker waits this long (and for the focus frame), so the file is
    /// read for the frame the user wants first.
    static let jumpSettle = 0.25
    /// Reversing: frames kept decoded above the focus, so pausing and stepping forward do not wait.
    public static let reverseAhead = 8

    public init(url: URL, index: FrameIndex, cache: FrameCache, estimatedFrameBytes: Int,
                playbackLookahead: Int, preferHardware: Bool = true, readCache: ReadCache? = nil,
                now: @escaping () -> Double = CACurrentMediaTime) {
        self.url = url
        self.now = now
        self.readCache = readCache
        self.index = index
        self.cache = cache
        self.estimatedFrameBytes = estimatedFrameBytes
        self.playbackLookahead = playbackLookahead
        hardwarePreferred = preferHardware
    }

    public var decoderStatus: (codec: String, backend: DecoderBackendKind)? {
        condition.withLock { backend.map { (codec, $0) } }
    }

    public var lastError: Error? { condition.withLock { error } }

    /// VideoToolbox or software (`hwdec`). A worker replaces its decoder where that costs nothing: before a seek or
    /// at a keyframe.
    public var preferHardware: Bool {
        get { condition.withLock { hardwarePreferred } }
        set { condition.withLock { hardwarePreferred = newValue } }
    }

    /// True while the workers run and the focus frame is neither cached nor known to be undecodable
    /// (the index scan yields meanwhile, spec §2.2).
    public var hasUnresolvedFocus: Bool {
        condition.withLock { running && !cache.isResolved(clampedFocusLocked()) }
    }

    /// Decoder creations attempted by both workers (for tests).
    var decoderCreationAttempts: Int { condition.withLock { creationAttempts } }

    /// Seeks by the forward worker (for tests).
    var forwardSeeks: Int { condition.withLock { forwardSeekCount } }

    /// Decoders given up for the buffers their pools kept (for tests).
    var poolReleases: Int { condition.withLock { poolReleaseCount } }

    public func start() {
        condition.withLock { running = true }
        for body in [forwardLoop, backwardLoop] {
            finished.enter()
            let thread = Thread { [finished] in
                body()
                finished.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Stops the workers. With `waitForExit: false` it returns at once; bumping `indexVersion`
    /// makes any in-flight result be discarded, so the shared cache can be cleared right away.
    public func stop(waitForExit: Bool = true) {
        condition.withLock {
            running = false
            indexVersion += 1
            condition.broadcast()
        }
        if waitForExit { finished.wait() }
    }

    public func setFocus(_ n: Int, mode: FillMode, direction: Int = 0) {
        condition.withLock {
            // Reversing restarts at the new focus after a jump (a seek, the loop, starting to play backward). When the
            // focus only passed below the next chunk, decoding fell behind: the next chunk starts below the focus by the
            // frames playback passes while it decodes, and the frames on the way are skipped.
            if self.mode == .reversing && mode != .reversing { reverseJumps += 1 }   // a turn or a pause
            if mode == .reversing {
                let maxChunk = max(1, Int(Double(framesInBudgetLocked()) * Self.chunkRatio))
                if self.mode != .reversing || reverseNext.map({ n > focus + Self.reverseAhead || $0 - n > maxChunk }) ?? true {
                    reverseNext = n
                    reverseJumps += 1
                } else if let next = reverseNext, n < next {
                    // At most what leaves a whole chunk inside the window below the focus.
                    let room = Int(Double(framesInBudgetLocked()) * Self.fillRatio) - Self.reverseAhead - maxChunk
                    let lead = min(Int((chunkSeconds ?? 0) * reverseSpeed * reverseFrameRate), max(0, room))
                    reverseNext = max(0, Self.reverseChunkEnd(cursor: next, focus: n, leadFrames: lead))
                }
            }
            // Stepping back a few frames is what the backward worker is for: it must not wait then, even
            // right after a jump.
            if direction < 0 && (1...Self.sequentialGap).contains(focus - n) {
                jumpedAt = -.infinity
            } else if !cache.isResolved(n) && !(direction < 0 && n == focus) {
                jumpedAt = now()
                jumpFocus = n
            }
            focus = n
            self.mode = mode
            self.direction = direction
            cache.setFocus(n, backShare: backShareLocked())
            condition.broadcast()
        }
    }

    /// Confines the window to an A–B loop (nil: no loop). Forward decoding stops at the loop's end; backward decoding goes
    /// down to the keyframe at or before its start, which decoding the start needs, and no further. In flight, a frame
    /// or a chunk finishes; nothing outside the window is started afterwards. A focus outside the loop (a seek away
    /// from it) gets the normal window, so the loop never starves the frame on screen.
    public func setLoop(_ range: ClosedRange<Int>?) {
        condition.withLock {
            guard loop != range else { return }
            loop = range
            condition.broadcast()
        }
    }

    /// Reversing: the speed (magnitude) and the file's frame rate, so the backward worker can choose how many frames to
    /// decode (spec §5). The level restarts from the measured decode rate, or from the speed when there is none.
    public func setReverseDemand(speed: Double, framesPerSecond: Double) {
        condition.withLock {
            reverseSpeed = speed
            reverseFrameRate = framesPerSecond
            level = ReverseLevel.best(coverage: coverageLocked, needed: speed * framesPerSecond, speedMagnitude: speed)
        }
    }

    /// The level reverse playback decodes at; nil when not playing backward.
    public var reverseLevel: ReverseLevel? {
        condition.withLock { mode == .reversing ? reverseLevelLocked() : nil }
    }

    /// Spec §2.3: the forward worker seeks the demuxer to a keyframe beyond `current` in `direction`, near
    /// `target`, decodes it and reports it through `onLanded`. A newer request replaces a pending one.
    public func requestKeyframe(id: Int, toward target: Int, from current: Int, direction: Int) {
        condition.withLock {
            keyframeRequest = (id, target, current, direction)
            condition.broadcast()
        }
    }

    /// Switches to a new index. VFR video renumbers frames, so the caller clears the cache then.
    public func updateIndex(_ newIndex: FrameIndex, clearCache: Bool) {
        condition.withLock {
            index = newIndex
            indexVersion += 1
            if mode == .reversing {   // the chunk in flight is dropped: start again at the focus, leaving no hole
                reverseNext = nil
                reverseJumps += 1
            }
            if clearCache { cache.removeAll() }
            condition.broadcast()
        }
    }

    // MARK: Planning (callers hold `condition`)

    private func backShareLocked() -> Double {
        if mode == .playing { return 0.5 }
        if mode == .reversing { return 0.95 }
        return direction < 0 ? 0.75 : direction > 0 ? 0.25 : 0.6
    }

    private func clampedFocusLocked() -> Int { min(max(focus, 0), max(index.frameCount - 1, 0)) }

    private func framesInBudgetLocked() -> Int {
        cache.budgetBytes / max(1, cache.averageFrameBytes ?? estimatedFrameBytes)
    }

    private func windowLocked() -> ClosedRange<Int> {
        // The whole window (behind + focus + ahead) must fit in the budget, or eviction would
        // discard window-edge frames and the fillers would re-decode them forever.
        let capacity = max(1, framesInBudgetLocked() - 1)
        let total = min(max(4, Int(Double(framesInBudgetLocked()) * Self.fillRatio)), capacity) - 1
        let room = max(0, total)
        let share = backShareLocked()
        var ahead = min(room, max(2, Int(Double(room) * (1 - share))))
        if mode == .playing { ahead = min(ahead, playbackLookahead) }
        if mode == .reversing { ahead = min(room, Self.reverseAhead) }
        let behind = mode == .playing ? 0 : mode == .reversing ? room - ahead : min(room - ahead, Int(Double(room) * share))
        let f = clampedFocusLocked()
        var lower = max(0, f - behind)
        var upper = min(max(index.frameCount - 1, 0), f + ahead)
        // A loop wider than the budget is cut the same way: the window around the focus, inside the loop's bounds.
        if let loop, loop.contains(f) {
            lower = max(lower, index.keyframe(atOrBefore: loop.lowerBound))
            upper = min(upper, loop.upperBound)
        }
        return lower...upper
    }

    /// Spec §3.3: after a jump the backward worker waits, so the file is read for the focus frame first.
    private func backwardSettledLocked() -> Bool {
        if mode == .reversing { return true }   // the first chunk is the frame on screen
        return now() - jumpedAt >= Self.jumpSettle && (clampedFocusLocked() != jumpFocus || cache.isResolved(clampedFocusLocked()))
    }

    /// Scrubbing backward past the cached run, the backward worker decodes the focus with the frames below it,
    /// together with the frames the steps passed over up to the run: the forward worker would seek to the same GOP
    /// and pre-roll it a second time. Returns those frames, or nil.
    private func backwardOwnedGapLocked() -> ClosedRange<Int>? {
        guard mode == .paused, direction < 0, backwardSettledLocked() else { return nil }
        let f = clampedFocusLocked()
        guard !cache.isResolved(f) else { return nil }
        let limit = min(windowLocked().upperBound, f + Self.sequentialGap)
        var end = f
        while end < limit && !cache.isResolved(end + 1) { end += 1 }
        return f...end
    }

    private func nextForwardFrameLocked() -> Int? {
        let window = windowLocked()
        var n = clampedFocusLocked()
        if let gap = backwardOwnedGapLocked() { n = gap.upperBound + 1 }
        if mode == .reversing {
            // The focus comes with the backward worker's chunk. Above it only every frame is worth filling: while
            // frames are skipped each would cost the forward worker a seek and a keyframe pre-roll.
            guard reverseLevelLocked() == .all else { return nil }
            n += 1
        }
        while n <= window.upperBound {
            if !cache.isResolved(n) && backwardChunk?.contains(n) != true { return n }
            n += 1
        }
        return nil
    }

    private func nextBackwardChunkLocked() -> (range: ClosedRange<Int>, level: ReverseLevel?)? {
        if mode == .reversing { return nextReverseChunkLocked() }
        guard mode == .paused else { return nil }
        let f = clampedFocusLocked()
        guard backwardSettledLocked() else { return nil }
        let window = windowLocked()
        let end = backwardOwnedGapLocked()?.upperBound ?? (cache.resolvedRun(around: f)?.lowerBound ?? f) - 1
        guard end >= window.lowerBound else { return nil }
        let maxChunk = max(1, Int(Double(framesInBudgetLocked()) * Self.chunkRatio))
        let gopStart = index.isExact ? index.keyframe(atOrBefore: end) : end - maxChunk + 1
        return (max(gopStart, end - maxChunk + 1, window.lowerBound)...end, nil)
    }

    /// Reversing (spec §4): the chunk ending at the cursor, started only once all of it fits in the window below the
    /// focus, so a chunk is never cut short and its keyframe pre-roll paid for a few frames. Keyframes level: from the
    /// keyframe at or before the cursor, of which only the keyframe is kept.
    private func nextReverseChunkLocked() -> (range: ClosedRange<Int>, level: ReverseLevel?)? {
        let window = windowLocked()
        let maxChunk = max(1, Int(Double(framesInBudgetLocked()) * Self.chunkRatio))
        var end = min(reverseNext ?? clampedFocusLocked(), clampedFocusLocked())
        while end >= window.lowerBound && cache.isResolved(end) { end -= 1 }
        guard end >= window.lowerBound else { return nil }
        var level = reverseLevelLocked()
        if level == .keyframes && !index.isExact { level = .references }   // keyframes are not known yet
        let lower: Int
        if level == .keyframes {
            lower = index.keyframe(atOrBefore: end)
        } else {
            let gopStart = index.isExact ? index.keyframe(atOrBefore: end) : end - maxChunk + 1
            lower = max(gopStart, end - maxChunk + 1)
            guard lower >= window.lowerBound || window.lowerBound == 0 else { return nil }
        }
        reverseNext = lower - 1
        return (max(lower, 0)...end, level)
    }

    /// Where the next reversing chunk ends: at the cursor, unless decoding fell behind the focus; then `leadFrames`
    /// below the focus, the frames playback passes while the chunk decodes, so it is not behind again when it is done.
    static func reverseChunkEnd(cursor: Int?, focus: Int, leadFrames: Int) -> Int {
        min(cursor ?? focus, focus - leadFrames)
    }

    private func reverseLevelLocked() -> ReverseLevel {
        fixedReverseLevel ?? level ?? ReverseLevel.initial(speedMagnitude: reverseSpeed)
    }

    /// After a reversing chunk, also one given up before its end: `covered` frames of video in `seconds`. The
    /// level's coverage and the chunk time are updated and the level chosen again; a chunk that got through nothing
    /// counts as a coverage of 0.
    /// `afterJump`: the chunk was given up for a jump, a turn or a new index; it says nothing about speed.
    func measured(_ chunk: ClosedRange<Int>, level: ReverseLevel, covered: Int, seconds: Double, afterJump: Bool = false) {
        guard seconds > 0, !afterJump else { return }
        condition.withLock {
            let sample = Double(covered) / seconds
            let previous = coverageLocked(level)
            coverage[level] = (previous.map { ($0 + sample) / 2 } ?? sample, now())
            chunkSeconds = chunkSeconds.map { ($0 + seconds) / 2 } ?? seconds
            guard mode == .reversing, fixedReverseLevel == nil else { return }
            self.level = ReverseLevel.next(current: reverseLevelLocked(), coverage: coverageLocked,
                                           needed: reverseSpeed * reverseFrameRate)
        }
    }

    private func coverageLocked(_ level: ReverseLevel) -> Double? {
        coverage[level].flatMap { now() - $0.at <= Self.measurementLifetime ? $0.value : nil }
    }

    /// The jump count, for telling a chunk given up for a jump from a slow one.
    private var reverseJumpsNow: Int { condition.withLock { reverseJumps } }

    private func chunkStillWanted(_ chunk: ClosedRange<Int>, version: Int) -> Bool {
        condition.withLock {
            running && (mode == .paused || mode == .reversing) && version == indexVersion && chunk.overlaps(windowLocked())
        }
    }

    // MARK: Results

    private func store(_ frame: DecodedFrame, version: Int) {
        let stored = condition.withLock { () -> Bool in
            guard version == indexVersion else { return false }
            if !cache.contains(frame.number) { cache.insert(frame) }
            return true
        }
        if stored { onInsert?(frame.number) }
    }

    private func markUndecodable<S: Sequence>(_ numbers: S, version: Int) where S.Element == Int {
        condition.withLock {
            guard version == indexVersion else { return }
            for n in numbers { cache.markUndecodable(n) }
        }
    }

    private func record(_ decoder: VideoDecoder) {
        condition.withLock {
            backend = decoder.backendKind
            codec = decoder.codecName
        }
    }

    private func record(_ failure: Error) {
        let first = condition.withLock { () -> Bool in
            defer { error = failure }
            return error == nil
        }
        if first { onError?(failure) }
    }

    /// A worker's decoder and how it was made.
    private struct DecoderSlot {
        var decoder: VideoDecoder?
        var version = -1            // index version the decoder uses
        var hardware = true         // made with this `preferHardware`
        var failures = 0            // consecutive creation failures…
        var failuresVersion = -1    // …counted for this index version
    }

    /// Returns a decoder that uses `index`, creating or re-indexing it as needed, or nil while
    /// creation keeps failing (retried after the next index change). A decoder of the other kind than
    /// `hardware` is replaced only when `mayReplace` (a replaced decoder starts over with a seek).
    private func prepare(_ slot: inout DecoderSlot, index currentIndex: FrameIndex, currentVersion: Int,
                         hardware: Bool, mayReplace: Bool = true) throws -> (VideoDecoder, reset: Bool)? {
        if slot.failuresVersion != currentVersion {
            slot.failures = 0
            slot.failuresVersion = currentVersion
        }
        if let existing = slot.decoder, mayReplace {
            if slot.hardware != hardware {
                slot.decoder = nil
                slot.failures = 0
            } else if existing.poolSurplus > condition.withLock({ poolSurplusLimitLocked() }) {
                slot.decoder = nil
                condition.withLock { poolReleaseCount += 1 }
            }
        }
        if let existing = slot.decoder, slot.version == currentVersion { return (existing, false) }
        if let existing = slot.decoder {
            existing.index = currentIndex
        } else {
            guard slot.failures < Self.maxCreationFailures else { return nil }
            condition.withLock { creationAttempts += 1 }
            do {
                slot.decoder = try VideoDecoder(source: MediaSource(url: url, readCache: readCache), index: currentIndex,
                                                preferHardware: hardware)
                slot.hardware = hardware
                slot.failures = 0
            } catch {
                slot.failures += 1
                throw error
            }
        }
        slot.version = currentVersion
        return (slot.decoder!, true)
    }

    private func poolSurplusLimitLocked() -> Int {
        max(Self.minPoolSurplus, Int(Double(framesInBudgetLocked()) * Self.poolSurplusRatio))
    }

    /// A waiting worker gives its pool back (its frames went to the other worker); its next frame starts with a seek.
    private func dropIfPoolKeepsTooMuch(_ slot: inout DecoderSlot, limit: Int) {
        if let decoder = slot.decoder, decoder.poolSurplus > limit {
            slot.decoder = nil
            condition.withLock { poolReleaseCount += 1 }
        }
    }

    // MARK: Workers

    private func forwardLoop() {
        var slot = DecoderSlot()
        var lastDecoded: Int?
        while true {
            condition.lock()
            guard running else { condition.unlock(); return }
            if let request = keyframeRequest {
                keyframeRequest = nil
                let currentIndex = index
                let version = indexVersion
                condition.unlock()
                lastDecoded = autoreleasepool { land(request, slot: &slot, index: currentIndex, version: version) }
                continue
            }
            guard let target = nextForwardFrameLocked() else {
                let limit = poolSurplusLimitLocked()
                condition.wait(until: Date().addingTimeInterval(0.1))
                condition.unlock()
                dropIfPoolKeepsTooMuch(&slot, limit: limit)
                continue
            }
            let currentIndex = index
            let version = indexVersion
            let hardware = hardwarePreferred
            condition.unlock()

            // One autorelease pool per frame: objects the decoder leaves autoreleased hold its frames (IOSurfaces
            // of VTDecoderXPCService) until the pool drains, and this loop runs as long as the file is open.
            autoreleasepool {
                do {
                    // Switching decoders mid-GOP would decode it again from its keyframe: wait for a seek or a keyframe.
                    let wouldSeek = lastDecoded.map { target <= $0 || target - $0 > Self.sequentialGap } ?? true
                    let mayReplace = wouldSeek || (currentIndex.isExact && currentIndex.isKeyframe(target))
                    guard let (d, reset) = try prepare(&slot, index: currentIndex, currentVersion: version,
                                                       hardware: hardware, mayReplace: mayReplace) else {
                        markUndecodable([target], version: version)   // no decoder: nothing to wait for
                        return
                    }
                    if reset { lastDecoded = nil }
                    let needsSeek = lastDecoded.map { target <= $0 || target - $0 > Self.sequentialGap } ?? true
                    if needsSeek {
                        condition.withLock { forwardSeekCount += 1 }
                        try d.seek(toFrame: target)
                    }
                    // Catching up with a focus that moved ahead (fast scrubbing): frames it passed are not needed.
                    d.skipNonReference(before: needsSeek ? nil : target)
                    record(d)
                    guard let frame = try d.nextFrame() else {
                        markUndecodable([target], version: version)   // past the real end of the stream
                        lastDecoded = nil
                        return
                    }
                    let expected = needsSeek ? target : max(lastDecoded! + 1, target)   // skipped frames are not missing
                    if frame.number > expected { markUndecodable(expected..<frame.number, version: version) }
                    store(frame, version: version)
                    StartupTrace.markOnce("first frame decoded")
                    lastDecoded = frame.number
                } catch {
                    record(error)
                    markUndecodable([target], version: version)
                    slot.decoder = nil
                    lastDecoded = nil
                }
            }
        }
    }

    /// Serves a keyframe request; returns the frame decoded (the forward worker continues from it).
    private func land(_ request: (id: Int, target: Int, from: Int, direction: Int), slot: inout DecoderSlot,
                      index currentIndex: FrameIndex, version: Int) -> Int? {
        var landed: Int?
        do {
            let hardware = condition.withLock { hardwarePreferred }
            if let (d, _) = try prepare(&slot, index: currentIndex, currentVersion: version, hardware: hardware) {
                try d.seekToKeyframe(toward: request.target, from: request.from, direction: request.direction)
                record(d)
                if let frame = try d.nextFrame() {
                    store(frame, version: version)
                    landed = frame.number
                }
            }
        } catch {
            record(error)
            slot.decoder = nil
        }
        if let landed { moveFocusToLanding(landed, from: request.target) }
        onLanded?(request.id, landed ?? request.from)
        return landed
    }

    /// The player moves the focus to the landing too, but only once the main thread gets to it; until then the
    /// forward worker would decode from the stale target, seeking a whole GOP away (spec §2.3). A newer request
    /// or focus wins.
    private func moveFocusToLanding(_ landed: Int, from target: Int) {
        condition.withLock {
            guard keyframeRequest == nil, focus == target else { return }
            focus = landed
            jumpFocus = landed
            cache.setFocus(landed, backShare: backShareLocked())
        }
    }

    private func backwardLoop() {
        var slot = DecoderSlot()
        while true {
            condition.lock()
            guard running else { condition.unlock(); return }
            guard let (chunk, level) = nextBackwardChunkLocked() else {
                let limit = poolSurplusLimitLocked()
                condition.wait(until: Date().addingTimeInterval(0.1))
                condition.unlock()
                dropIfPoolKeepsTooMuch(&slot, limit: limit)
                continue
            }
            let currentIndex = index
            let version = indexVersion
            let hardware = hardwarePreferred   // every chunk starts with a seek
            let jumps = reverseJumps
            backwardChunk = chunk
            condition.unlock()
            defer { condition.withLock { backwardChunk = nil } }

            autoreleasepool {   // per chunk and per frame, as in `forwardLoop`
                let started = now()
                var covered = 0
                do {
                    guard let (d, _) = try prepare(&slot, index: currentIndex, currentVersion: version, hardware: hardware) else {
                        markUndecodable(chunk, version: version)
                        return
                    }
                    if level == .keyframes {
                        // Only the keyframe; the frames above it are skipped, not missing.
                        d.skipNonReference(before: nil)
                        try d.seek(toFrame: chunk.lowerBound)
                        record(d)
                        if let frame = try autoreleasepool(invoking: { try d.nextFrame() }), frame.number == chunk.lowerBound {
                            store(frame, version: version)
                            covered = chunk.count
                        } else {
                            markUndecodable([chunk.lowerBound], version: version)
                        }
                    } else {
                        // References level: frames nothing refers to are not decoded and not missing either.
                        let skipping = level == .references
                        d.skipNonReference(before: skipping ? chunk.upperBound + 1 : nil)
                        try d.seek(toFrame: chunk.lowerBound)
                        record(d)
                        var expected = chunk.lowerBound
                        var completed = true
                        while expected <= chunk.upperBound {
                            guard let frame = try autoreleasepool(invoking: { try d.nextFrame() }),
                                  frame.number <= chunk.upperBound else { break }
                            if frame.number > expected && !skipping { markUndecodable(expected..<frame.number, version: version) }
                            store(frame, version: version)
                            expected = max(expected, frame.number + 1)
                            covered = expected - chunk.lowerBound
                            if !chunkStillWanted(chunk, version: version) {
                                completed = false
                                break
                            }
                        }
                        if completed && expected <= chunk.upperBound && !skipping {
                            markUndecodable(expected...chunk.upperBound, version: version)
                        }
                        if completed { covered = chunk.count }
                    }
                    if let level {
                        measured(chunk, level: level, covered: covered, seconds: now() - started,
                                 afterJump: reverseJumpsNow != jumps)
                    }
                } catch {
                    record(error)
                    markUndecodable([chunk.upperBound], version: version)
                    slot.decoder = nil
                }
            }
        }
    }
}
