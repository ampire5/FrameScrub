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
/// to the file as is.
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
    private var loading = Set<Int64>()
    private var queued = Set<Int64>()   // read-ahead blocks waiting on `prefetchQueue`
    private var generation = 0          // bumped by `cancelReadAhead`; older queued loads are skipped
    private var clock: UInt64 = 0
    private var closed = false
    private var readAhead = 2 * blockSize
    private let prefetchQueue = DispatchQueue(label: "framescrub.readahead", qos: .utility)
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
              cursor: inout ReadCursor) throws -> Int {
        let useBlocks = lock.withLock { () -> Bool in
            if cached { counters.requests += 1 }   // the hit rate is about readers that use the cache
            return cached && budget >= Self.blockSize
        }
        guard useBlocks else { return try readFile(at: offset, count: count, into: buffer) }
        let b = offset / Int64(Self.blockSize)
        let data = try block(b, countHit: true)
        let start = Int(offset - b * Int64(Self.blockSize))
        let n = min(count, data.count - start)
        guard n > 0 else { return 0 }
        data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + start, byteCount: n) }
        if b == cursor.lastBlock + 1 { cursor.run += 1 } else if b != cursor.lastBlock { cursor.run = 0 }
        cursor.lastBlock = b
        if cursor.run >= 1 { prefetch(after: b) }
        return n
    }

    /// The block's bytes: from memory, from a load another thread is doing, or read now.
    private func block(_ b: Int64, countHit: Bool) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if closed { throw POSIXError(.ECANCELED) }
            if var hit = blocks[b] {
                clock += 1
                hit.lastUse = clock
                blocks[b] = hit
                if countHit { counters.hits += 1 }
                return hit.data
            }
            guard loading.contains(b) else { break }
            lock.wait()
        }
        loading.insert(b)
        lock.unlock()
        let result = Result { try fetch(b) }
        lock.lock()
        loading.remove(b)
        if case let .success(data) = result, !closed {
            clock += 1
            blocks[b] = Block(data: data, lastUse: clock)
            evictLocked()
        }
        lock.broadcast()
        return try result.get()
    }

    private func fetch(_ b: Int64) throws -> Data {
        let start = b * Int64(Self.blockSize)
        let length = Int(min(Int64(Self.blockSize), fileSize - start))
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let n = try data.withUnsafeMutableBytes { try readFile(at: start, count: length, into: $0.baseAddress!) }
        if n < length { data.count = n }
        return data
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
                blocks[$0] == nil && !loading.contains($0) && !queued.contains($0)
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
                _ = try? self.block(n, countHit: false)
            }
        }
    }

    /// One read of the underlying file, counted.
    func readFile(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        let n = try source.read(at: offset, count: count, into: buffer)
        lock.withLock {
            counters.bytesFromFile += Int64(n)
            let now = CACurrentMediaTime()
            recent.append((now, n))
            recent.removeAll { now - $0.time > 2 }
        }
        return n
    }
}

/// Per-reader sequential-access tracking for read-ahead.
struct ReadCursor {
    var lastBlock: Int64 = -2
    var run = 0
}
