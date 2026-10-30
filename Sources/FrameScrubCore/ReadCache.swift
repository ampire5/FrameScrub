import Foundation
import QuartzCore

/// What `ReadCache` has done since the file was opened (spec §5).
public struct ReadStats: Equatable, Sendable {
    public var bytesFromFile: Int64 = 0
    public var requests = 0          // AVIOContext reads by cached readers
    public var hits = 0              // of those, served from cached blocks
    public var bytesPerSecond = 0.0  // over the last 2 s of file reads
    public var cacheEnabled = false

    public var text: String {
        let mb = Double(bytesFromFile) / 1_000_000
        let rate = String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
        guard cacheEnabled else { return String(format: "Read: %.0f MB from file, cache off, ", mb) + rate }
        let share = requests > 0 ? 100 * hits / requests : 0
        return String(format: "Read: %.0f MB from file, cache hits %d%%, ", mb, share) + rate
    }
}

/// Reads one file for every demuxer of a playback session (spec §4). Thread-safe.
///
/// The file is read in aligned 2 MiB blocks kept in LRU order within the budget; a block another thread is
/// loading is waited for instead of read twice, and a reader that moves through consecutive blocks gets the
/// next `readAheadBytes` loaded in the background. With a budget below one block every request is passed
/// to the file as is. From a source whose bytes arrive gradually (HTTP) a block loads on its own thread and a reader
/// gets the bytes at its offset as soon as they are in, not when the whole block is.
public final class ReadCache: @unchecked Sendable {
    public let url: URL
    public let fileSize: Int64
    let source: ByteSource
    let lock = NSCondition()
    var budget: Int
    var counters = ReadStats()
    private var recent: [(time: Double, bytes: Int)] = []
    private struct Block { var data: Data; var lastUse: UInt64 }
    private var blocks: [Int64: Block] = [:]
    private var loading: [Int64: PartialBlock] = [:]
    private var queued = Set<Int64>()   // read-ahead blocks waiting on `prefetchQueue`
    private var generation = 0          // bumped by `cancelReadAhead`; older queued loads are skipped
    private var clock: UInt64 = 0
    private var closed = false
    private var readAhead = 2 * blockSize
    private let prefetchQueue = DispatchQueue(label: "framescrub.readahead", qos: .utility)
    /// Loads of blocks readers wait for, from a source whose bytes arrive gradually, at the waiting reader's QoS. A
    /// reader may move on before its block is complete (a seek), so at most `maxGradualLoads` run here; past that a
    /// reader loads on its own thread, as from a file.
    private let loadQueue = DispatchQueue(label: "framescrub.blockload", qos: .userInitiated, attributes: .concurrent)
    private var gradualLoads = 0
    static let maxGradualLoads = 4
    private var streamProbe: StreamProbe?

    /// The file's stream parameters from its first open, for every later `MediaSource` of the session (set once,
    /// before the other readers start).
    public var probe: StreamProbe? {
        get { lock.withLock { streamProbe } }
        set { lock.withLock { streamProbe = newValue } }
    }

    public static let blockSize = 2 << 20

    public init(url: URL, budgetBytes: Int, source: ByteSource? = nil) throws {
        self.url = url
        self.source = try source ?? ByteSources.open(url)
        fileSize = self.source.size
        budget = max(0, budgetBytes)
    }

    public var budgetBytes: Int {
        get { lock.withLock { budget } }
        set {
            lock.withLock {
                budget = max(0, newValue)
                evictLocked()
            }
        }
    }

    /// Bytes to keep loaded ahead of a sequential reader (PlayerCore: ~3 s of the file's bit rate).
    public var readAheadBytes: Int {
        get { lock.withLock { readAhead } }
        set { lock.withLock { readAhead = max(2 * Self.blockSize, newValue) } }
    }

    /// Drops the read-ahead queued so far (a jump makes it useless); a block already loading finishes.
    public func cancelReadAhead() {
        lock.withLock {
            generation += 1
            queued.removeAll()
        }
    }

    var cachedBytes: Int { lock.withLock { blocks.values.reduce(0) { $0 + $1.data.count } } }

    func isCached(block b: Int64) -> Bool { lock.withLock { blocks[b] != nil } }

    public var stats: ReadStats {
        lock.withLock {
            var s = counters
            let now = CACurrentMediaTime()
            s.bytesPerSecond = Double(recent.filter { now - $0.time <= 2 }.reduce(0) { $0 + $1.bytes }) / 2
            s.cacheEnabled = budget >= Self.blockSize
            return s
        }
    }

    /// Releases memory; block reads after this fail (and so do readers waiting for a load).
    public func close() {
        lock.withLock {
            closed = true
            blocks.removeAll()
            lock.broadcast()
        }
    }

    /// Serves one `AVIOContext` read: up to `count` bytes at `offset`, at most to the end of its block.
    /// `cached: false` (the index scan) goes straight to the file so it does not evict useful blocks.
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer, cached: Bool,
              cursor: inout ReadCursor, readAhead: Bool = true) throws -> Int {
        let useBlocks = lock.withLock { () -> Bool in
            if cached { counters.requests += 1 }   // the hit rate is about readers that use the cache
            return cached && budget >= Self.blockSize
        }
        guard useBlocks else { return try readFile(at: offset, count: count, into: buffer) }
        let b = offset / Int64(Self.blockSize)
        let n = try copy(block: b, from: Int(offset - b * Int64(Self.blockSize)), count: count, into: buffer)
        guard n > 0 else { return 0 }
        if b == cursor.lastBlock + 1 { cursor.run += 1 } else if b != cursor.lastBlock { cursor.run = 0 }
        cursor.lastBlock = b
        if cursor.run >= 1, readAhead { prefetch(after: b) }
        return n
    }

    /// Up to `count` of the block's bytes from `start`: from memory, from a load in progress (as soon as some bytes
    /// at `start` are in), or from a load started now. Returns 0 past the block's end.
    private func copy(block b: Int64, from start: Int, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        lock.lock()
        var waitingOn: PartialBlock?   // the load this reader waits for; its failure is this reader's
        var started = false
        while true {
            if closed { lock.unlock(); throw POSIXError(.ECANCELED) }
            if let partial = waitingOn, partial.done {
                if let failure = partial.failure {
                    // From a file a reader that only waited loads again itself, as before partial blocks.
                    guard started || source.arrivesGradually else { waitingOn = nil; continue }
                    lock.unlock()
                    throw failure
                }
                // Its own bytes, even if the block was evicted since (a budget below one block evicts at once).
                if !started { counters.hits += 1 }
                lock.unlock()
                let n = min(count, partial.filled - start)
                guard n > 0 else { return 0 }
                buffer.copyMemory(from: partial.storage + start, byteCount: n)
                return n
            }
            if var hit = blocks[b] {
                clock += 1
                hit.lastUse = clock
                blocks[b] = hit
                if !started { counters.hits += 1 }
                lock.unlock()
                let n = min(count, hit.data.count - start)
                guard n > 0 else { return 0 }
                hit.data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + start, byteCount: n) }
                return n
            }
            if let partial = loading[b] {
                waitingOn = partial
                if partial.filled > start {
                    if !started { counters.hits += 1 }
                    lock.unlock()
                    // Bytes below `filled` are written once and never again; the reference keeps them alive.
                    let n = min(count, partial.filled - start)
                    buffer.copyMemory(from: partial.storage + start, byteCount: n)
                    return n
                }
                lock.wait()
                continue
            }
            let partial = PartialBlock(length: Int(max(0, min(Int64(Self.blockSize), fileSize - b * Int64(Self.blockSize)))))
            loading[b] = partial
            waitingOn = partial
            started = true
            if source.arrivesGradually, gradualLoads < Self.maxGradualLoads {
                gradualLoads += 1
                loadQueue.async(flags: .inheritQoS) {
                    self.load(b, into: partial)
                    self.lock.withLock { self.gradualLoads -= 1 }
                }
                lock.wait()
            } else {
                lock.unlock()
                load(b, into: partial)
                lock.lock()
            }
        }
    }

    /// Fills `partial` from the source, telling waiting readers of every step; then it becomes a whole block, or
    /// carries the failure for the readers that waited for it.
    private func load(_ b: Int64, into partial: PartialBlock) {
        let result = Result {
            guard partial.length > 0 else { return 0 }
            return try readFile(at: b * Int64(Self.blockSize), count: partial.length, into: partial.storage) { [weak self] n in
                guard let self else { return false }
                return self.lock.withLock {
                    partial.filled = n
                    self.lock.broadcast()
                    return !self.closed   // a closed cache stops its downloads
                }
            }
        }
        lock.withLock {
            if loading[b] === partial { loading[b] = nil }
            partial.done = true
            switch result {
            case let .success(n):
                partial.filled = n
                if !closed {
                    clock += 1
                    // The block keeps the partial's buffer (no copy); readers holding either keep it alive.
                    let data = Data(bytesNoCopy: partial.storage, count: n, deallocator: .custom { _, _ in
                        withExtendedLifetime(partial) {}
                    })
                    blocks[b] = Block(data: data, lastUse: clock)
                    evictLocked()
                }
            case let .failure(error):
                partial.failure = error
            }
            lock.broadcast()
        }
    }

    /// Loads block `b` on this thread unless it is in memory or loading (read-ahead).
    private func loadIfNeeded(_ b: Int64) {
        let partial = lock.withLock { () -> PartialBlock? in
            guard !closed, blocks[b] == nil, loading[b] == nil else { return nil }
            let partial = PartialBlock(length: Int(max(0, min(Int64(Self.blockSize), fileSize - b * Int64(Self.blockSize)))))
            loading[b] = partial
            return partial
        }
        if let partial { load(b, into: partial) }
    }

    /// Drops least recently used blocks over the budget. A reader that already holds a block's `Data`
    /// keeps its copy alive, so a block being read is never pulled from under it.
    private func evictLocked() {
        var total = blocks.values.reduce(0) { $0 + $1.data.count }
        while total > budget, let victim = blocks.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= victim.value.data.count
            blocks.removeValue(forKey: victim.key)
        }
    }

    private func prefetch(after b: Int64) {
        let (wanted, current) = lock.withLock { () -> ([Int64], Int) in
            let count = Int64((readAhead + Self.blockSize - 1) / Self.blockSize)
            let last = (fileSize - 1) / Int64(Self.blockSize)
            guard b + 1 <= last else { return ([], generation) }
            let wanted = (b + 1...min(b + count, last)).filter {
                blocks[$0] == nil && loading[$0] == nil && !queued.contains($0)
            }
            queued.formUnion(wanted)
            return (wanted, generation)
        }
        for n in wanted {
            prefetchQueue.async { [weak self] in
                guard let self else { return }
                let live = self.lock.withLock { () -> Bool in
                    guard self.generation == current else { return false }
                    self.queued.remove(n)
                    return true
                }
                guard live else { return }
                self.loadIfNeeded(n)
            }
        }
    }

    /// One read of the underlying file, counted.
    func readFile(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer,
                  progress: (@Sendable (Int) -> Bool)? = nil) throws -> Int {
        guard !lock.withLock({ closed }) else { throw POSIXError(.ECANCELED) }
        let n = try progress.map { try source.read(at: offset, count: count, into: buffer, progress: $0) }
            ?? source.read(at: offset, count: count, into: buffer)
        guard !lock.withLock({ closed }) else { throw POSIXError(.ECANCELED) }
        lock.withLock {
            counters.bytesFromFile += Int64(n)
            let now = CACurrentMediaTime()
            recent.append((now, n))
            recent.removeAll { now - $0.time > 2 }
        }
        return n
    }
}

/// A block being loaded: its bytes go into `storage` in order, `filled` of them so far; `done` once the load ended,
/// with its `failure` if it failed (all guarded by the cache's lock).
private final class PartialBlock: @unchecked Sendable {
    let storage: UnsafeMutableRawPointer
    let length: Int
    var filled = 0
    var done = false
    var failure: Error?

    init(length: Int) {
        self.length = length
        storage = .allocate(byteCount: max(1, length), alignment: 16)
    }

    deinit { storage.deallocate() }
}

/// Per-reader sequential-access tracking for read-ahead.
struct ReadCursor {
    var lastBlock: Int64 = -2
    var run = 0
}
