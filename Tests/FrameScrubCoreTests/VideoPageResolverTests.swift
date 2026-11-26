import AVFoundation
import Foundation
import Testing
@testable import FrameScrubCore

struct VideoPageResolverTests {
    @Test func ytDLPUsesSelectedTracksAndTheirHeaders() throws {
        let json = Data(#"""
            {"title":"Example","http_headers":{"User-Agent":"Test","Accept-Encoding":"gzip"},"requested_formats":[{"url":"https://example.com/audio.webm","vcodec":"none","acodec":"opus","http_headers":{"Referer":"https://example.com/page"}},{"url":"https://example.com/video.mp4","vcodec":"av01","acodec":"none"}]}
            {"title":"Muxed","url":"https://example.com/muxed.mp4","vcodec":"h264","acodec":"aac"}
            {"title":"Live","url":"https://example.com/live.m3u8","is_live":true}
            """#.utf8)
        let items = VideoPageResolver.ytDLPItems(json)
        try #require(items.count == 2)
        #expect(items[0].video.url.lastPathComponent == "video.mp4")
        #expect(items[0].video.headers == ["User-Agent": "Test"])
        #expect(items[0].audio?.url.lastPathComponent == "audio.webm")
        #expect(items[0].audio?.headers == ["User-Agent": "Test", "Referer": "https://example.com/page"])
        #expect(items[1].audio == nil)
    }

    @Test func galleryDLReturnsOnlyUniqueVideoItems() throws {
        let json = Data(#"""
            [[2,null,{"title":"Gallery"}],
             [3,"https://example.com/picture.jpg",{"extension":"jpg"}],
             [3,"https://example.com/stream?id=88",{"extension":"mp4","filename":"Clip one"}],
             [3,"https://example.com/stream?id=88",{"extension":"mp4"}],
             [3,"https://example.com/clip.webm",{}],
             [3,"file:///clip.mp4",{"extension":"mp4"}]]
            """#.utf8)
        let items = try VideoPageResolver.galleryDLItems(json)
        #expect(items.map(\.title) == ["Clip one", "clip.webm"])
        #expect(items.allSatisfy { $0.audio == nil })
    }

    @Test func ytDLPRefreshPreservesItemIdentityAndReadsTheSelectedVideoFormat() throws {
        let first = Data(#"""
            {"id":"item-42","extractor_key":"Example","title":"Before","requested_formats":[{"url":"https://cdn.example.com/audio?token=old","vcodec":"none","acodec":"opus","format_id":"audio","vbr":32},{"url":"https://cdn.example.com/video?token=old","vcodec":"av01","acodec":"none","format_id":"video","width":1920,"height":1080,"fps":59.94,"vbr":3250.5}]}
            """#.utf8)
        let refreshed = Data(#"""
            {"id":"item-42","extractor_key":"Example","title":"After","url":"https://cdn.example.com/muxed?token=new","vcodec":"h264","acodec":"aac","format_id":"muxed","width":"unknown","tbr":4000}
            """#.utf8)
        let item = try #require(VideoPageResolver.ytDLPItems(first).first)
        let replacement = try #require(VideoPageResolver.ytDLPItems(refreshed).first)
        let identity = try #require(item.itemID)
        #expect(replacement.itemID == identity)
        #expect(item.selectedFormat?.id == "video")
        #expect(item.selectedFormat?.width == 1920)
        #expect(item.selectedFormat?.height == 1080)
        #expect(item.selectedFormat?.fps == 59.94)
        #expect(item.selectedFormat?.codec == "av01")
        #expect(item.selectedFormat?.videoBitrateKbps == 3250.5)
        #expect(replacement.selectedFormat?.id == "muxed")
        #expect(replacement.selectedFormat?.width == nil)
        #expect(replacement.selectedFormat?.videoBitrateKbps == nil)
    }

    @Test func ytDLPFallsBackToAnItemPageAndRejectsSignedMediaAndPlaylistURLs() throws {
        let json = Data(#"""
            {"webpage_url":"https://example.com/watch?v=42","url":"https://cdn.example.com/clip?token=abc","vcodec":"h264"}
            {"webpage_url":"https://example.com/watch?v=42","url":"https://cdn.example.com/clip?token=xyz","vcodec":"h264"}
            {"id":"signed-filename","extractor_key":"Generic","webpage_url":"https://cdn.example.com/clip?token=abc","url":"https://cdn.example.com/clip?token=xyz","vcodec":"h264"}
            {"webpage_url":"https://example.com/collection","playlist_webpage_url":"https://example.com/collection","url":"https://cdn.example.com/other?token=xyz","vcodec":"h264"}
            """#.utf8)
        let items = VideoPageResolver.ytDLPItems(json)
        try #require(items.count == 4)
        let identity = try #require(items[0].itemID)
        #expect(items[1].itemID == identity)
        #expect(items[2].itemID == nil)
        #expect(items[3].itemID == nil)
    }

    @Test func galleryDLUsesExplicitMediaIDsAndDropsAmbiguousPageIdentity() throws {
        let json = Data(#"""
            [[3,"https://cdn.example.com/one.mp4?signature=old",{"category":"example","media_id":42,"height":720}],
             [3,"https://cdn.example.com/two.mp4",{"webpage_url":"https://example.com/gallery"}],
             [3,"https://cdn.example.com/three.mp4",{"webpage_url":"https://example.com/gallery"}],
             [3,"https://cdn.example.com/four.mp4",{"category":"example","id":99}]]
            """#.utf8)
        let refreshed = Data(#"""
            [[3,"https://cdn.example.com/one.mp4?signature=new",{"category":"example","media_id":"42"}]]
            """#.utf8)
        let items = try VideoPageResolver.galleryDLItems(json)
        try #require(items.count == 4)
        let identity = try #require(items[0].itemID)
        let replacement = try #require(VideoPageResolver.galleryDLItems(refreshed).first)
        #expect(replacement.itemID == identity)
        #expect(items[0].selectedFormat?.height == 720)
        #expect(items.dropFirst().allSatisfy { $0.itemID == nil })
        #expect(items.dropFirst().allSatisfy { $0.selectedFormat == nil })
    }

    @Test func galleryDLReportsAuthenticationErrorsWithoutReturningToolOutput() {
        let json = Data(#"""
            [[-1,{"error":"AuthRequired","message":"Log in at https://example.com/watch?token=secret"}]]
            """#.utf8)
        do {
            _ = try VideoPageResolver.galleryDLItems(json)
            Issue.record("Expected sign-in failure")
        } catch {
            #expect(error as? VideoPageResolver.Failure == .signInRequired)
            #expect(!error.localizedDescription.contains("token=secret"))
        }
    }

    @Test @MainActor func opensSplitHTTPTracksAndSeeksOnTheSameTimeline() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("track.wav")
        try await Task.detached {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            for n in 0..<Int(buffer.frameLength) {
                samples[n] = Float(sin(Double(n) * 2 * .pi * 440 / format.sampleRate))
            }
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            try file.write(from: buffer)
        }.value

        let server = try RangeServer(resources: [
            "/video.mp4": Data(contentsOf: Fixtures.url(Fixtures.fragmented)),
            "/audio.wav": Data(contentsOf: wav),
        ], path: "/watch")
        server.requiredHeader = ("User-Agent", "FrameScrub Test")
        let headers = ["User-Agent": "FrameScrub Test"]
        let video = ResolvedVideo(
            title: "Split tracks",
            video: .init(url: server.url.deletingLastPathComponent().appendingPathComponent("video.mp4"), headers: headers),
            audio: .init(url: server.url.deletingLastPathComponent().appendingPathComponent("audio.wav"), headers: headers))
        var config = Config()
        config.autoplay = false
        config.cacheSizeMiB = 4
        let player = PlayerCore(config: config, enableAudio: false, cacheCompression: false)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        defer { player.close() }
        let prepare = player.preparation(for: server.url, resolved: video)
        let prepared = try await Task.detached {
            let prepared = try prepare()
            let audio = try #require(prepared.externalAudio)
            try audio.seek(toSeconds: 1.5)
            let decoded = try audio.nextBuffer()
            let first = try #require(decoded)
            #expect(abs(first.startSeconds - 1.5) < 0.001)
            #expect(first.buffer.frameLength > 0)
            return prepared
        }.value
        player.open(prepared)
        #expect(player.url == server.url)
        try #require(await eventually { player.displayedFrame == 0 })
        let index = try #require(player.index)
        let target = index.frameNumber(forSeconds: 1.5)
        try #require(target > 0)
        player.seek(toFrame: target)
        try #require(await eventually { player.displayedFrame == target })
        #expect(Set(server.requests.map(\.path)) == ["/video.mp4", "/audio.wav"])
    }
}
