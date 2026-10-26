import Foundation
import HomeScreenModel
import Testing
@testable import FrameScrubCore

/// A video card's facts from the open its poster needs anyway (file-cards spec, HomeScreenKit).
@Suite struct VideoFactsTests {
    @Test func theStreamOfAnH264File() throws {
        let f = try #require(VideoFacts.probe(url: Fixtures.url(Fixtures.h264)))
        #expect(f.width == 1920 && f.height == 1080)
        #expect(f.codec == "H.264")
        #expect(abs((f.fps ?? 0) - 30) < 0.01)
        #expect(abs((f.duration ?? 0) - 20) < 0.1)
        #expect(f.hdr == false)
        #expect(FileFactsText.stream(f) == "1080p · H.264 · 30 fps")
    }

    @Test func hlgIsHDRAndRotationIsUpright() throws {
        let hevc = try #require(VideoFacts.probe(url: Fixtures.url(Fixtures.hevc10)))
        #expect(hevc.codec == "HEVC" && hevc.hdr == true && FileFactsText.resolution(hevc) == "4K")
        let rotated = try #require(VideoFacts.probe(url: Fixtures.url(Fixtures.rotated)))
        #expect(rotated.width == 360 && rotated.height == 640)
    }

    @Test func thePosterBringsTheSameFacts() throws {
        let result = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.h264), at: nil))
        #expect(result.facts == VideoFacts.probe(url: Fixtures.url(Fixtures.h264)))
    }

    @Test func codecNames() {
        #expect(VideoFacts.codec("hevc") == "HEVC" && VideoFacts.codec("prores") == "ProRes" && VideoFacts.codec("xyz") == "XYZ")
    }
}
