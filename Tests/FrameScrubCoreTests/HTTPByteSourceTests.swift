import Foundation
import Testing
@testable import FrameScrubCore

@Suite(.serialized) @MainActor struct HTTPByteSourceTests {
    private func bytes(_ source: HTTPByteSource, at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let n = try data.withUnsafeMutableBytes { try source.read(at: offset, count: count, into: $0.baseAddress!) }
        data.count = n
        return data
    }

    @Test func sizeComesFromAOneByteRangeRequest() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
        #expect(source.size == server.size)
        #expect(server.requests == [RangeServer.Request(method: "GET", path: "/file", range: 0...0, headers: server.requests[0].headers)])
        #expect(server.requests[0].headers["accept-encoding"] == "identity")
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
        #expect(server.requests.count == 4)   // one GET per read
    }

    @Test func readsStopAtTheEnd() throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.scenes))
        defer { server.stop() }
        let source = try HTTPByteSource(url: server.url)
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

    /// A video opens through the server like a file: the demuxer reads it in blocks and a frame decodes.
    @Test func aVideoOpensAndDecodesOverHTTP() async throws {
        let server = try RangeServer(file: Fixtures.url(Fixtures.withAudio))
        defer { server.stop() }
        let source = try MediaSource(url: server.url)
        #expect(source.width == 640)
        #expect(source.readCache.source is HTTPByteSource)
        let before = server.requests.count
        #expect(try MediaSource(url: server.url, cached: false).buildIndex().frameCount == 100)
        // The index scan reads a block's worth at a time: the 387 KB file comes in one request, not one per 64 KiB.
        #expect(server.requests.dropFirst(before).contains { $0.range == 0...(server.size - 1) })

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
