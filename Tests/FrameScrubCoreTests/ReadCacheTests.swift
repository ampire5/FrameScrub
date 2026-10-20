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

    @Test func zeroBudgetReadsExactlyWhatIsAsked() throws {
        let source = try CountingByteSource(url: Fixtures.url(Fixtures.h264))
        let cache = try ReadCache(url: Fixtures.url(Fixtures.h264), budgetBytes: 0, source: source)
        var cursor = ReadCursor()
        var buffer = [UInt8](repeating: 0, count: 10)
        _ = try buffer.withUnsafeMutableBytes { try cache.read(at: 5, count: 10, into: $0.baseAddress!, cached: true, cursor: &cursor) }
        #expect(cache.stats.bytesFromFile == 10)
        #expect(cache.stats.text.contains("cache off"))
    }
}
