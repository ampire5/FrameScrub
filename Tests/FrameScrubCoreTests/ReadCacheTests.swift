import Foundation
import Testing
@testable import FrameScrubCore

/// Counts and optionally fails reads of an underlying file.
final class CountingByteSource: ByteSource, @unchecked Sendable {
    let base: FileByteSource
    private let lock = NSLock()
    private var calls = 0
    private var failures = 0
    init(url: URL) throws { base = try FileByteSource(url: url) }
    var size: Int64 { base.size }
    var readCalls: Int { lock.withLock { calls } }
    var failNext: Int {
        get { lock.withLock { failures } }
        set { lock.withLock { failures = newValue } }
    }
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        try lock.withLock {
            calls += 1
            if failures > 0 { failures -= 1; throw POSIXError(.EIO) }
        }
        return try base.read(at: offset, count: count, into: buffer)
    }
}

/// Every read takes `latency`; counts them.
final class SlowCountingSource: ByteSource, @unchecked Sendable {
    private let base: FileByteSource
    private let latency: Double
    private let lock = NSLock()
    private var calls = 0
    init(url: URL, latency: Double) throws {
        base = try FileByteSource(url: url)
        self.latency = latency
    }
    var size: Int64 { base.size }
    var readCalls: Int { lock.withLock { calls } }
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        lock.withLock { calls += 1 }
        Thread.sleep(forTimeInterval: latency)
        return try base.read(at: offset, count: count, into: buffer)
    }
}

/// A source whose bytes arrive gradually: a read delivers its first half at once, then waits for `release` before the
/// rest (or fails there while `failures` lasts).
final class GatedSource: ByteSource, @unchecked Sendable {
    private let base: FileByteSource
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var failures = 0
    init(url: URL, failures: Int = 0) throws {
        base = try FileByteSource(url: url)
        self.failures = failures
    }
    var size: Int64 { base.size }
    var arrivesGradually: Bool { true }
    var readCalls: Int { lock.withLock { calls } }
    func release() { gate.signal() }
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        try read(at: offset, count: count, into: buffer, progress: { _ in })
    }
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer,
              progress: @escaping @Sendable (Int) -> Void) throws -> Int {
        lock.withLock { calls += 1 }
        let half = try base.read(at: offset, count: count / 2, into: buffer)
        progress(half)
        gate.wait()
        if lock.withLock({ failures > 0 ? { failures -= 1; return true }() : false }) { throw POSIXError(.EIO) }
        let rest = try base.read(at: offset + Int64(half), count: count - half, into: buffer + half)
        progress(half + rest)
        return half + rest
    }
}

/// Reads on a thread of its own (a reader blocks while it waits for bytes).
private func readOffMain(_ cache: ReadCache, at offset: Int64, count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            var cursor = ReadCursor()
            var data = Data(count: count)
            do {
                let n = try data.withUnsafeMutableBytes {
                    try cache.read(at: offset, count: count, into: $0.baseAddress!, cached: true, cursor: &cursor)
                }
                data.count = n
                continuation.resume(returning: data)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@Suite struct ReadCacheTests {
    @Test func aJumpDropsQueuedReadAhead() async throws {
        let url = Fixtures.url(Fixtures.hevc10)   // ~20 MB = 10 blocks
        let source = try SlowCountingSource(url: url, latency: 0.05)
        let cache = try ReadCache(url: url, budgetBytes: 64 << 20, source: source)
        cache.readAheadBytes = 8 * ReadCache.blockSize
        var cursor = ReadCursor()
        var byte: UInt8 = 0
        for b in 0..<2 {                          // sequential: blocks 2…9 get queued
            _ = try cache.read(at: Int64(b * ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor)
        }
        cache.cancelReadAhead()
        try await Task.sleep(for: .milliseconds(600))
        #expect(source.readCalls <= 3)            // blocks 0 and 1, and at most the one already loading
        // A new sequential run reads ahead again.
        for b in 5..<7 {
            _ = try cache.read(at: Int64(b * ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor)
        }
        #expect(await eventually(timeout: 5) { cache.isCached(block: 9) })
    }

    @Test func demuxesAndDecodesThroughTheReader() throws {
        let cache = try ReadCache(url: Fixtures.url(Fixtures.h264), budgetBytes: 0)
        let source = try MediaSource(url: cache.url, readCache: cache)
        let index = try MediaSource(url: cache.url, readCache: cache).buildIndex()
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seek(toFrame: 300)
        #expect(try decoder.nextFrame().map { readFrameNumber($0.pixelBuffer) } == 300)
        #expect(cache.stats.bytesFromFile > 0)
        #expect(cache.stats.cacheEnabled == false)
    }

    @Test func readsMatchTheFileAtRandomOffsets() throws {
        let url = Fixtures.url(Fixtures.hevc10)
        let file = try Data(contentsOf: url)
        let cache = try ReadCache(url: url, budgetBytes: 64 << 20)
        var cursor = ReadCursor()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let offset = Int64.random(in: 0..<Int64(file.count), using: &rng)
            let count = Int.random(in: 1...(5 << 20), using: &rng)
            var buffer = [UInt8](repeating: 0, count: count)
            let n = try buffer.withUnsafeMutableBytes {
                try cache.read(at: offset, count: count, into: $0.baseAddress!, cached: true, cursor: &cursor)
            }
            #expect(n > 0)
            #expect(Array(buffer[..<n]) == Array(file[Int(offset)..<Int(offset) + n]))
        }
    }

    @Test func concurrentReadersOfOneBlockFetchItOnce() async throws {
        let source = try CountingByteSource(url: Fixtures.url(Fixtures.hevc10))
        let cache = try ReadCache(url: Fixtures.url(Fixtures.hevc10), budgetBytes: 64 << 20, source: source)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var cursor = ReadCursor()
                    var buffer = [UInt8](repeating: 0, count: 1000)
                    _ = try? buffer.withUnsafeMutableBytes {
                        try cache.read(at: 4096, count: 1000, into: $0.baseAddress!, cached: true, cursor: &cursor)
                    }
                }
            }
        }
        #expect(source.readCalls == 1)
        #expect(cache.stats.hits == 7)
    }

    @Test func staysWithinBudgetAndRetriesAfterAnError() throws {
        let source = try CountingByteSource(url: Fixtures.url(Fixtures.hevc10))   // ~20 MB = 10 blocks
        let cache = try ReadCache(url: Fixtures.url(Fixtures.hevc10), budgetBytes: 3 * ReadCache.blockSize, source: source)
        var cursor = ReadCursor()
        var byte: UInt8 = 0
        for b in stride(from: 0, to: 10, by: 2) {    // non-sequential: no read-ahead
            _ = try cache.read(at: Int64(b * ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor)
        }
        #expect(cache.cachedBytes <= 3 * ReadCache.blockSize)
        #expect(source.readCalls == 5)
        source.failNext = 1
        #expect(throws: (any Error).self) {
            _ = try cache.read(at: Int64(9 * ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor)
        }
        #expect(try cache.read(at: Int64(9 * ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor) == 1)
    }

    @Test func sequentialReadsPrefetchAndRandomOnesDoNot() async throws {
        let source = try CountingByteSource(url: Fixtures.url(Fixtures.hevc10))
        let cache = try ReadCache(url: Fixtures.url(Fixtures.hevc10), budgetBytes: 64 << 20, source: source)
        cache.readAheadBytes = 2 * ReadCache.blockSize
        var cursor = ReadCursor()
        var byte: UInt8 = 0
        _ = try cache.read(at: 0, count: 1, into: &byte, cached: true, cursor: &cursor)
        _ = try cache.read(at: Int64(ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor)
        #expect(await eventually { cache.isCached(block: 2) && cache.isCached(block: 3) })
        var other = ReadCursor()
        _ = try cache.read(at: Int64(7 * ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &other)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!cache.isCached(block: 8))
    }

    @Test func aReaderWithoutReadAheadLoadsOnlyWhatItAsksFor() async throws {
        let cache = try ReadCache(url: Fixtures.url(Fixtures.hevc10), budgetBytes: 64 << 20)
        cache.readAheadBytes = 4 * ReadCache.blockSize
        var cursor = ReadCursor()
        var byte: UInt8 = 0
        _ = try cache.read(at: 0, count: 1, into: &byte, cached: true, cursor: &cursor, readAhead: false)
        _ = try cache.read(at: Int64(ReadCache.blockSize), count: 1, into: &byte, cached: true, cursor: &cursor, readAhead: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!cache.isCached(block: 2))
    }

    @Test func zeroBudgetReadsExactlyWhatIsAsked() throws {
        let source = try CountingByteSource(url: Fixtures.url(Fixtures.h264))
        let cache = try ReadCache(url: Fixtures.url(Fixtures.h264), budgetBytes: 0, source: source)
        var cursor = ReadCursor()
        var buffer = [UInt8](repeating: 0, count: 10)
        _ = try buffer.withUnsafeMutableBytes { try cache.read(at: 5, count: 10, into: $0.baseAddress!, cached: true, cursor: &cursor) }
        #expect(cache.stats.bytesFromFile == 10)
        #expect(cache.stats.text.contains("cache off"))
    }

    /// From a source whose bytes arrive gradually, a reader gets what is in at its offset without waiting for the whole
    /// block; a reader beyond it waits for the rest; the block is then kept whole.
    @Test func bytesAreHandedOverAsTheyArrive() async throws {
        let url = Fixtures.url(Fixtures.withAudio)   // ~387 KB: block 0 is the whole file
        let file = try Data(contentsOf: url)
        let source = try GatedSource(url: url)
        let cache = try ReadCache(url: url, budgetBytes: 64 << 20, source: source)
        let half = file.count / 2
        #expect(try await readOffMain(cache, at: 0, count: 1000) == file[0..<1000])   // the gate is still shut
        let late = Task { try await readOffMain(cache, at: Int64(half + 100), count: 1000) }
        try await Task.sleep(for: .milliseconds(150))
        source.release()
        #expect(try await late.value == file[(half + 100)..<(half + 1100)])
        #expect(await eventually { cache.isCached(block: 0) })
        #expect(source.readCalls == 1)
        #expect(cache.stats.hits == 1)   // the late reader found the load running
    }

    /// A load that fails half way fails the reader still waiting for its bytes; the next read loads again.
    @Test func aLoadThatFailsHalfWayFailsTheReaderWaiting() async throws {
        let url = Fixtures.url(Fixtures.withAudio)
        let file = try Data(contentsOf: url)
        let source = try GatedSource(url: url, failures: 1)
        let cache = try ReadCache(url: url, budgetBytes: 64 << 20, source: source)
        let half = file.count / 2
        let late = Task { try await readOffMain(cache, at: Int64(half + 100), count: 1000) }
        try await Task.sleep(for: .milliseconds(150))
        source.release()
        await #expect(throws: POSIXError.self) { try await late.value }
        source.release()
        #expect(try await readOffMain(cache, at: Int64(half + 100), count: 1000) == file[(half + 100)..<(half + 1100)])
        #expect(source.readCalls == 2)
    }
}
