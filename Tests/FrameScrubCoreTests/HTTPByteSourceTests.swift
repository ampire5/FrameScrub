import Foundation
import QuartzCore
import Testing
@testable import FrameScrubCore

@Suite(.serialized) @MainActor struct HTTPByteSourceTests {
    private func bytes(_ source: HTTPByteSource, at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let n = try data.withUnsafeMutableBytes { try source.read(at: offset, count: count, into: $0.baseAddress!) }
        data.count = n
        return data
    }

    /// Opening asks for the first block, not for one byte: the size comes with its answer, and the first read of the
    /// start is that answer (one request fewer per stream open, ~0.4 s on a slow server).
    @Test func theSizeComesWithTheFirstBlocksAnswer() throws {
        let file = Fixtures.url(Fixtures.scenes)
        let server = try RangeServer(file: file)
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        #expect(source.size == server.size)
        let first = RangeServer.Request(method: "GET", path: "/file", range: 0...Int64(ReadCache.blockSize - 1),
                                        headers: server.requests[0].headers)
        #expect(server.requests == [first])
        #expect(server.requests[0].headers["accept-encoding"] == "identity")
        #expect(try bytes(source, at: 0, count: Int(source.size)) == Data(contentsOf: file))
        #expect(server.requests.count == 1)   // the open's answer was the read
    }

    /// The first block's body comes to its reader as it arrives, while the open returned with the headers.
    @Test func theFirstBlockArrivesGraduallyToItsReader() throws {
        let file = Fixtures.url(Fixtures.withAudio)
        let expected = try Data(contentsOf: file)
        let server = try RangeServer(file: file)
        defer { server.stop() }
        server.trickle = (bytes: 16 << 10, delay: 0.05)
        let opened = CACurrentMediaTime()
        let source = try HTTPByteSource(url: server.url)
        let openTook = CACurrentMediaTime() - opened
        let count = 128 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { buffer.deallocate() }
        nonisolated(unsafe) let base = buffer
        let reports = Reports()
        let n = try source.read(at: 0, count: count, into: buffer) { filled in
            reports.add(filled, matches: Data(bytes: base, count: filled) == expected[0..<filled], at: CACurrentMediaTime())
            return true
        }
        let readDone = CACurrentMediaTime() - opened
        #expect(n == count)
        #expect(reports.values.count > 2 && reports.values == reports.values.sorted() && reports.values.last == count)
        #expect(reports.allMatched)
        #expect(openTook < readDone / 2)   // the open did not wait for the body
        #expect(server.requests.count == 1)
    }

    /// A report answered false stops the open's request too.
    @Test func aReportAnsweredFalseStopsTheFirstBlock() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.withAudio))
        defer { server.stop() }
        server.trickle = (bytes: 16 << 10, delay: 0.2)
        let source = try HTTPByteSource(url: server.url)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128 << 10, alignment: 16)
        defer { buffer.deallocate() }
        let started = CACurrentMediaTime()
        let error = #expect(throws: POSIXError.self) {
            try source.read(at: 0, count: 128 << 10, into: buffer) { _ in false }
        }
        #expect(error?.code == .ECANCELED)
        #expect(CACurrentMediaTime() - started < 0.8)
    }

    /// A 206 without `Content-Range`: a file shorter than the block asked for is its body; a longer one has no size.
    @Test func anAnswerWithoutContentRange() throws {
        let file = Fixtures.url(Fixtures.scenes)
        let server = try RangeServer(file: file)
        defer { server.stop() }
        server.sendsContentRange = false
        let source = try HTTPByteSource(url: server.url)
        #expect(source.size == server.size)
        #expect(try bytes(source, at: 0, count: Int(source.size)) == Data(contentsOf: file))
        let error = #expect(throws: FFmpegError.self) { try HTTPByteSource(url: server.url, firstRead: 1024) }
        #expect(error?.description.contains("Content-Range") == true)
    }

    /// A first read elsewhere is its own request; the open's block is not kept for later.
    @Test func aFirstReadElsewhereAsksForItself() throws {
        let file = Fixtures.url(Fixtures.scenes)
        let expected = try Data(contentsOf: file)
        let server = try RangeServer(file: file)
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url, firstRead: 1024)
        #expect(try bytes(source, at: 5000, count: 100) == expected[5000..<5100])
        #expect(try bytes(source, at: 0, count: 100) == expected[0..<100])
        #expect(server.requests.count == 3)
    }

    @Test func readsAtOffsetsMatchTheFile() throws {
        let file = Fixtures.url(Fixtures.scenes)
        let expected = try Data(contentsOf: file)
        let server = try RangeServer(file: file)
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        #expect(try bytes(source, at: 0, count: 8) == expected[0..<8])
        #expect(try bytes(source, at: 1000, count: 300) == expected[1000..<1300])
        #expect(try bytes(source, at: source.size - 5, count: 5) == expected[(expected.count - 5)...])
        #expect(server.requests.last?.range == (source.size - 5)...(source.size - 1))
        #expect(server.requests.count == 3)   // the open's answer, then one GET per read
    }

    @Test func readsStopAtTheEnd() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        _ = try bytes(source, at: 0, count: 1)   // the open's answer
        #expect(try bytes(source, at: source.size - 3, count: 100).count == 3)   // clipped to the file
        #expect(try bytes(source, at: source.size, count: 10).isEmpty)
        #expect(try bytes(source, at: source.size + 50, count: 10).isEmpty)
        #expect(server.requests.count == 2)   // past the end nothing is asked
    }

    @Test func extraHeadersGoWithEveryRequest() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        server.requiredHeader = ("ApiKey", "secret")
        #expect(throws: FFmpegError.self) { try HTTPByteSource(url: server.url) }
        let source = try HTTPByteSource(url: server.url, headers: ["ApiKey": "secret"])
        _ = try bytes(source, at: 0, count: 10)   // the open's answer
        _ = try bytes(source, at: 10, count: 10)
        #expect(server.requests.count == 3)
        #expect(server.requests.dropFirst().allSatisfy { $0.headers["apikey"] == "secret" })
    }

    @Test func failuresReadLikeFFmpegsOwn() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        let missing = server.url.deletingLastPathComponent().appendingPathComponent("elsewhere")
        let notFound = #expect(throws: FFmpegError.self) { try HTTPByteSource(url: missing) }
        #expect(notFound?.code == -ENOENT)
        #expect(OpenFailure(notFound!).kind == .notFound)
        server.rangesSupported = false
        let noRanges = #expect(throws: FFmpegError.self) { try HTTPByteSource(url: server.url) }
        #expect(noRanges?.description.contains("Range") == true)
        let refused = #expect(throws: FFmpegError.self) { try HTTPByteSource(url: URL(string: "http://127.0.0.1:1/x")!) }
        #expect(OpenFailure(refused!).kind == .network)
    }

    @Test func contentRangeTotal() {
        #expect(HTTPByteSource.total(fromContentRange: "bytes 0-0/12345") == 12345)
        #expect(HTTPByteSource.total(fromContentRange: "bytes 0-0/*") == nil)
        #expect(HTTPByteSource.total(fromContentRange: nil) == nil)
    }

    @Test func byteSourcesPickTheSourceByScheme() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        #expect(try ByteSources.open(server.url) is HTTPByteSource)
        #expect(try ByteSources.open(Fixtures.url(Fixtures.scenes)) is FileByteSource)
        #expect(ByteSources.isRemote(server.url))
        #expect(!ByteSources.isRemote(Fixtures.url(Fixtures.scenes)))
    }

    /// A read's body is handed over as it arrives: reports rise to the read's length, the first one long before the
    /// read returns, and the bytes up to each report are the file's.
    @Test func readsReportBytesAsTheyArrive() throws {
        let file = Fixtures.url(Fixtures.withAudio)
        let expected = try Data(contentsOf: file)
        let server = try RangeServer(file: file)
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        _ = try bytes(source, at: 0, count: 1)   // the open's answer: the read below is a request of its own
        server.trickle = (bytes: 16 << 10, delay: 0.05)
        let count = 128 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { buffer.deallocate() }
        nonisolated(unsafe) let base = buffer
        let reports = Reports()
        let started = CACurrentMediaTime()
        let n = try source.read(at: 1000, count: count, into: buffer) { filled in
            let matches = Data(bytes: base, count: filled) == expected[1000..<(1000 + filled)]
            reports.add(filled, matches: matches, at: CACurrentMediaTime())
            return true
        }
        let returned = CACurrentMediaTime()
        #expect(n == count)
        #expect(reports.values.count > 2)
        #expect(reports.values == reports.values.sorted() && Set(reports.values).count == reports.values.count)
        #expect(reports.values.last == count)
        #expect(reports.allMatched)
        #expect(try #require(reports.firstAt) - started < (returned - started) / 2)
    }

    /// A report answered false stops the request: the read throws `ECANCELED` without waiting for the rest.
    @Test func aReportAnsweredFalseStopsTheRead() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.withAudio))
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        _ = try bytes(source, at: 0, count: 1)   // the open's answer
        server.trickle = (bytes: 16 << 10, delay: 0.2)   // the whole read would take ~1.6 s
        let count = 128 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { buffer.deallocate() }
        let started = CACurrentMediaTime()
        let error = #expect(throws: POSIXError.self) {
            try source.read(at: 0, count: count, into: buffer) { _ in false }
        }
        #expect(error?.code == .ECANCELED)
        #expect(CACurrentMediaTime() - started < 0.8)
    }

    /// An answer that is not the range asked for hands nothing over.
    @Test func aRefusedReadReportsNothing() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        _ = try bytes(source, at: 0, count: 1)   // the open's answer
        server.requiredHeader = ("ApiKey", "secret")   // 401 from now on
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 100, alignment: 16)
        defer { buffer.deallocate() }
        let reports = Reports()
        #expect(throws: POSIXError.self) {
            try source.read(at: 0, count: 100, into: buffer) { reports.add($0, matches: true, at: 0); return true }
        }
        #expect(reports.values.isEmpty)
    }

    /// A video opens through the server like a file: the demuxer reads it in blocks and a frame decodes.
    @Test func aVideoOpensAndDecodesOverHTTP() async throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.withAudio))
        defer { server.stop() }
        let source = try MediaSource(url: server.url)
        #expect(source.width == 640)
        #expect(source.readCache.source is HTTPByteSource)
        let before = server.requests.count
        #expect(try MediaSource(url: server.url, cached: false).buildIndex().frameCount == 100)
        // The index scan reads a block's worth at a time: the 387 KB file comes in one request (the open's, which asks
        // for a whole block), not one per 64 KiB.
        let scan = Array(server.requests.dropFirst(before))
        #expect(scan.count == 1 && scan.first?.range == 0...Int64(ReadCache.blockSize - 1))

        var config = Config()
        config.cacheSizeMiB = 200
        let player = PlayerCore(config: config, enableAudio: false)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        try player.open(server.url)
        #expect(await eventually { !delegate.frames.isEmpty })
        #expect(delegate.frames.first.map { readFrameNumber($0.pixelBuffer) } == 0)
        #expect(player.readCache?.source is HTTPByteSource)
        player.close()
    }
}

/// Progress reports collected from the session's delegate queue.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []
    private var mismatch = false
    private var first: Double?
    func add(_ filled: Int, matches: Bool, at time: Double) {
        lock.withLock {
            list.append(filled)
            if !matches { mismatch = true }
            if first == nil { first = time }
        }
    }
    var values: [Int] { lock.withLock { list } }
    var allMatched: Bool { lock.withLock { !mismatch } }
    var firstAt: Double? { lock.withLock { first } }
}
