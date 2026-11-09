import Testing
@testable import FrameScrubCore

@Suite struct MediaFormatTests {
    private func format(_ name: String) throws -> MediaFormat { try MediaSource(url: Fixtures.url(name)).format }

    @Test func describesVideoCodecProfileLevelAndBitRate() throws {
        let h264 = try format(Fixtures.h264)
        #expect(h264.videoText == "h264 High L4.0, yuv420p, 9.9 Mbit/s")
        #expect(h264.audioText == "none")
        #expect(h264.containerText == "QuickTime / MOV, 9.9 Mbit/s overall")
        #expect(try format(Fixtures.hevc10).videoText == "hevc Main 10 L5.0, yuv420p10le, 40.0 Mbit/s")
    }

    @Test func describesAudio() throws {
        #expect(try format(Fixtures.withAudio).audioText == "aac LC, 48 kHz, mono, 70 kbit/s")
    }

    @Test func fallsBackToTheFileBitRateWhenTheStreamHasNone() throws {
        // This fixture has no stream bit rate or audio. Its overall rate varies with encoder parallelism.
        let av1 = try format(Fixtures.av1)
        #expect(av1.videoBitRate == 0)
        #expect(av1.audio == nil)
        #expect(av1.fileBitRate > 0)
        let rate = MediaFormat.rate(av1.fileBitRate)
        #expect(av1.videoText == "av1 Main L4.0, yuv420p, ≈\(rate)")
        #expect(av1.containerText == "Matroska / WebM, \(rate) overall")
    }

    @Test func formatsRates() {
        #expect(MediaFormat.rate(69_634) == "70 kbit/s")
        #expect(MediaFormat.rate(24_972_298) == "25.0 Mbit/s")
    }
}
