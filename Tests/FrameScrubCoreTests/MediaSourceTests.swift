import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct MediaSourceTests {
    @Test func readsStreamInfo() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.h264))
        #expect(source.width == 1920)
        #expect(source.height == 1080)
        #expect(abs(source.frameRate - 30) < 0.01)
        #expect(source.audioStreamIndex == nil)
        #expect(source.bitDepth == 8)
        #expect(source.rotationClockwise == 0)
        #expect(abs(source.durationSeconds - 20) < 0.1)
    }

    @Test func buildsExactIndex() throws {
        let index = try MediaSource(url: Fixtures.url(Fixtures.h264)).buildIndex()
        #expect(index.isExact)
        #expect(index.frameCount == 600)
        #expect(index.keyframes == [0, 250, 500])
    }

    @Test func approximateIndexMatchesConstantFrameRate() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.h264))
        let approximate = source.approximateIndex()
        #expect(approximate.frameCount == 600)
        #expect(approximate.agrees(with: try MediaSource(url: Fixtures.url(Fixtures.h264)).buildIndex()))
    }

    @Test func indexesVariableFrameRate() throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.vfr))
        let index = try MediaSource(url: Fixtures.url(Fixtures.vfr)).buildIndex()
        #expect(index.frameCount == 120)
        #expect(abs(index.seconds(forFrame: 59) - 118.0 / 60) < 1e-6)
        #expect(abs(index.seconds(forFrame: 61) - 121.0 / 60) < 1e-6)
        #expect(!source.approximateIndex().agrees(with: index))
    }

    @Test func detectsAudioRotationAndBitDepth() throws {
        #expect(try MediaSource(url: Fixtures.url(Fixtures.withAudio)).audioStreamIndex != nil)
        #expect(try MediaSource(url: Fixtures.url(Fixtures.rotated)).rotationClockwise == 270)
        #expect(try MediaSource(url: Fixtures.url(Fixtures.hevc10)).bitDepth == 10)
    }

    @Test func failsOnMissingFile() {
        #expect(throws: FFmpegError.self) {
            try MediaSource(url: URL(fileURLWithPath: "/nonexistent/video.mp4"))
        }
    }

    @Test func scanReportsProgressAndYields() throws {
        var fractions: [Double] = []
        var yields = 0
        let index = try MediaSource(url: Fixtures.url(Fixtures.av1)).buildIndex(
            shouldYield: { yields += 1; return yields < 3 }, progress: { fractions.append($0) })
        #expect(index.frameCount == 120)
        #expect(yields >= 3)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }
}
