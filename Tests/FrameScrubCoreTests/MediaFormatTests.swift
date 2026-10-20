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
        // Matroska stores no per-stream bit rate; the file has only video, so its rate is the video's.
        let av1 = try format(Fixtures.av1)
        #expect(av1.videoText == "av1 Main L4.0, yuv420p, ≈6.1 Mbit/s")
        #expect(av1.containerText.hasPrefix("Matroska / WebM, "))
    }

    @Test func formatsRates() {
        #expect(MediaFormat.rate(69_634) == "70 kbit/s")
        #expect(MediaFormat.rate(24_972_298) == "25.0 Mbit/s")
    }
}
