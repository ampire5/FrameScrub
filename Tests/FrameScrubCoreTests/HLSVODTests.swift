import CFFmpeg
import Foundation
import Testing
@testable import FrameScrubCore

@Suite(.serialized) @MainActor struct HLSVODTests {
    private func fixture(_ segmentType: String) throws -> [String: Data] {
        let directory = Fixtures.directory.appendingPathComponent("hls-\(segmentType)")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ("/" + $0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    @Test(arguments: ["mpegts", "fmp4"])
    func opensVODAndSeeksToUncachedFrame(segmentType: String) async throws {
        var resources = try fixture(segmentType)
        resources["/master.m3u8"] = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3000000\nmedia.m3u8\n".utf8)
        let server = try RangeServer(resources: resources, path: "/master.m3u8")
        server.rangesSupported = false
        var config = Config()
        config.autoplay = false
        config.cacheSizeMiB = 16
        if runsUnderRosetta { config.hwdec = .no }
        let player = PlayerCore(config: config, enableAudio: false, cacheCompression: false)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        defer { player.close() }
        let prepare = player.preparation(for: server.url)
        let opened = try await Task.detached { try prepare() }.value
        let audioStart = Double(opened.source.startPTS) * opened.source.timeBase
        player.open(opened)
        #expect(await eventually { player.displayedFrame == 0 })
        #expect(await eventually { player.cache.hasReadyFrame(3) })
        player.seek(toFrame: 3)
        #expect(await eventually { player.displayedFrame == 3 })
        player.seek(toFrame: 1)
        #expect(await eventually { player.displayedFrame == 1 })
        #expect(!player.cache.contains(78))
        player.seek(toFrame: 78)
        #expect(await eventually { player.displayedFrame == 78 })
        #expect(delegate.frames.last.map { readFrameNumber($0.pixelBuffer) } == 78)
        player.seek(toFrame: 50)
        #expect(await eventually { player.displayedFrame == 50 })
        player.perform(.keyframeBackStep)
        #expect(await eventually { player.displayedFrame == 25 && player.position == 25 })

        let decodedAudioTime = try await Task.detached {
            let audio = try AudioDecoder(url: server.url, zeroSeconds: audioStart)
            try audio.seek(toSeconds: 2.6)
            return try audio.nextBuffer()?.startSeconds
        }.value
        let audioTime = try #require(decodedAudioTime)
        #expect(abs(audioTime - 2.6) < 0.05)
    }

    @Test func cancellingAnOpenInterruptsAStalledPlaylist() async throws {
        let server = try RangeServer(resources: fixture("mpegts"), path: "/media.m3u8")
        server.trickle = (bytes: 20, delay: 0.3)
        let player = PlayerCore(config: Config(), enableAudio: false)
        let cancellation = OpenCancellation()
        let prepare = player.preparation(for: server.url, cancellation: cancellation)
        let pending = Task.detached { try prepare() }
        #expect(await eventually { !server.requests.isEmpty })
        let cancelledAt = ContinuousClock.now
        cancellation.cancel()
        switch await pending.result {
        case .success(let opened):
            opened.discard()
            Issue.record("A cancelled HLS open returned a prepared source")
        case .failure:
            #expect(ContinuousClock.now - cancelledAt < .seconds(2))
        }
    }

    @Test func distantJumpsReuseDownloadedSegmentsAndKeepPreroll() async throws {
        let server = try RangeServer(resources: fixture("fmp4"), path: "/media.m3u8")
        server.responseDelays = ["/init.mp4": 0.08, "/segment01.m4s": 0.08, "/segment03.m4s": 0.08]
        var config = Config()
        config.autoplay = false
        config.cacheSizeMiB = 4
        let player = PlayerCore(config: config, enableAudio: false, cacheCompression: false)
        defer { player.close() }
        let prepare = player.preparation(for: server.url)
        let opened = try await Task.detached { try prepare() }.value
        player.open(opened)
        #expect(await eventually { player.displayedFrame == 0 })

        for target in [38, 88, 38] {
            #expect(!player.cache.hasReadyFrame(target))
            let start = ContinuousClock.now
            player.seek(toFrame: target)
            try #require(await eventually { player.displayedFrame == target })
            let landing = ContinuousClock.now - start
            try #require(await eventually { (target...target + 3).allSatisfy(player.cache.hasReadyFrame) })
            let ahead = ContinuousClock.now - start
            let behind = (target - 3..<target).filter(player.cache.hasReadyFrame).count
            print("HLS jump \(target): landing=\(landing), +3=\(ahead), behind=\(behind)/3")
            #expect(behind == 3)
        }
        for path in ["/init.mp4", "/segment01.m4s", "/segment03.m4s"] {
            let reads = server.requests.filter { $0.path == path }.count
            print("HLS jump \(path): \(reads) requests")
            #expect(reads == 1)
        }
    }

    @Test func byteRangeSegmentsSharingOneAddressKeepTheirOwnOffsets() async throws {
        let resources = try fixture("fmp4")
        var movie = try #require(resources["/init.mp4"])
        var playlist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:1
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="shared.mp4",BYTERANGE="\(movie.count)@0"

            """
        for n in 0..<4 {
            let part = try #require(resources["/segment0\(n).m4s"])
            playlist += "#EXTINF:1,\n#EXT-X-BYTERANGE:\(part.count)@\(movie.count)\nshared.mp4\n"
            movie.append(part)
        }
        playlist += "#EXT-X-ENDLIST\n"
        let server = try RangeServer(resources: ["/media.m3u8": Data(playlist.utf8), "/shared.mp4": movie],
                                     path: "/media.m3u8")
        var config = Config()
        config.autoplay = false
        config.cacheSizeMiB = 4
        let player = PlayerCore(config: config, enableAudio: false, cacheCompression: false)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        defer { player.close() }
        let prepare = player.preparation(for: server.url)
        let opened = try await Task.detached { try prepare() }.value
        player.open(opened)
        try #require(await eventually { player.displayedFrame == 0 })
        player.seek(toFrame: 88)
        try #require(await eventually { player.displayedFrame == 88 })
        #expect(delegate.frames.last.map { readFrameNumber($0.pixelBuffer) } == 88)
        let segmentRequests = server.requests.filter { $0.path == "/shared.mp4" }
        let offsets = Set(segmentRequests.compactMap { $0.range?.lowerBound })
        #expect(offsets.count >= 2)
        #expect(segmentRequests.allSatisfy { $0.headers["connection"]?.lowercased() == "close" })
    }

    @Test func switchingInitSectionsSurvivesATemporaryHTTPFailure() async throws {
        var resources = try fixture("fmp4")
        let initialization = try #require(resources["/init.mp4"])
        resources["/second-init.mp4"] = initialization
        var playlist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:1
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="init.mp4"

            """
        for number in 0..<4 {
            if number == 3 { playlist += "#EXT-X-MAP:URI=\"second-init.mp4\"\n" }
            let name = "segment0\(number).m4s"
            let length = try #require(resources["/" + name]).count
            // Explicit ranges leave the media reads on FFmpeg's native HTTP path.
            playlist += "#EXTINF:1,\n#EXT-X-BYTERANGE:\(length)@0\n\(name)\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        resources["/media.m3u8"] = Data(playlist.utf8)
        let server = try RangeServer(resources: resources, path: "/media.m3u8")
        try await Task.detached {
            let source = try MediaSource(url: server.url)
            let packet = try #require(av_packet_alloc())
            defer { var allocated: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&allocated) }
            server.failRequests(to: "/second-init.mp4", count: 100)
            var result: Int32 = 0
            for _ in 0..<1_000 {
                result = source.read(into: packet)
                av_packet_unref(packet)
                if result < 0 { break }
            }
            try #require(result < 0)
            try #require(server.requests.contains { $0.path == "/second-init.mp4" })
            _ = source.read(into: packet)
            av_packet_unref(packet)

            server.failRequests(to: "/second-init.mp4", count: 0)
            let lastSegment = source.startPTS + Int64(3.5 / source.timeBase)
            try check(source.seek(stream: source.videoStreamIndex, toPTS: lastSegment), "seek after HLS failure")
            try check(source.read(into: packet), "read after HLS failure")
        }.value
    }

    @Test func aNewSeekInterruptsAStalledSegment() async throws {
        let server = try RangeServer(resources: fixture("mpegts"), path: "/media.m3u8")
        server.responseDelays = ["/segment03.ts": 4]
        var config = Config()
        config.autoplay = false
        config.cacheSizeMiB = 4
        let player = PlayerCore(config: config, enableAudio: false, cacheCompression: false)
        defer { player.close() }
        let prepare = player.preparation(for: server.url)
        let opened = try await Task.detached { try prepare() }.value
        player.open(opened)
        #expect(await eventually { player.displayedFrame == 0 })

        player.seek(toFrame: 95)
        #expect(await eventually { server.requests.contains { $0.path == "/segment03.ts" } })
        player.seek(toFrame: 25)
        #expect(await eventually(timeout: 2) { player.displayedFrame == 25 })
    }

    @Test func aRepeatedSeekCanReadARecoveredSegment() async throws {
        let server = try RangeServer(resources: fixture("mpegts"), path: "/media.m3u8")
        server.failRequests(to: "/segment01.ts", count: 100)
        var config = Config()
        config.autoplay = false
        config.cacheSizeMiB = 4
        let player = PlayerCore(config: config, enableAudio: false, cacheCompression: false)
        defer { player.close() }
        let prepare = player.preparation(for: server.url)
        let opened = try await Task.detached { try prepare() }.value
        player.open(opened)
        #expect(await eventually { player.displayedFrame == 0 })

        player.seek(toFrame: 25)
        #expect(await eventually { player.cache.isUndecodable(25) })
        server.failRequests(to: "/segment01.ts", count: 0)
        player.seek(toFrame: 25)
        #expect(await eventually { player.displayedFrame == 25 })
    }
}
