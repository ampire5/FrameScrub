import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct OnDemandVideoTests {
    @Test func descriptorRemainsReadableAfterTheSenderClosesIt() throws {
        let url = Fixtures.url(Fixtures.vfr)
        let sender = try FileHandle(forReadingFrom: url)
        let source = try FileByteSource(duplicatingReadOnlyDescriptor: sender.fileDescriptor)
        let reference = try sender.read(upToCount: 32)
        try sender.close()

        var header = Data(count: 32)
        let count = try header.withUnsafeMutableBytes {
            try source.read(at: 0, count: $0.count, into: $0.baseAddress!)
        }
        #expect(count == 32)
        #expect(header == reference)
    }

    @Test func writableDescriptorsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0]).write(to: url)
        let sender = try FileHandle(forUpdating: url)
        #expect(throws: FFmpegError.self) {
            try FileByteSource(duplicatingReadOnlyDescriptor: sender.fileDescriptor)
        }
    }

    @Test(arguments: [(Fixtures.h264, 250), (Fixtures.vfr, 70), (Fixtures.fragmented, 70), (Fixtures.hevc10, 60)])
    func adjacentFramesUsePresentationOrder(_ fixture: String, _ position: Int) throws {
        let (_, index) = try openIndexed(fixture)
        let url = Fixtures.url(fixture)
        let sender = try FileHandle(forReadingFrom: url)
        let session = try OnDemandVideo(url: URL(fileURLWithPath: "/fixture.mp4"),
                                        source: FileByteSource(duplicatingReadOnlyDescriptor: sender.fileDescriptor),
                                        preferHardware: false)
        try sender.close()
        let landed = try #require(try session.seek(to: index.seconds(forFrame: position)))
        #expect(landed.pts == index.pts(forFrame: position))
        #expect(readFrameNumber(landed.pixelBuffer) == position)

        let beforeBoundary = index.seconds(forFrame: position) - index.timeBase
        let before = try #require(try session.seek(to: beforeBoundary))
        #expect(before.pts == index.pts(forFrame: position - 1))
        #expect(readFrameNumber(before.pixelBuffer) == position - 1)
        #expect(try session.next()?.pts == index.pts(forFrame: position))

        for delta in [-1, -2] {
            let frame = try #require(try session.previous())
            #expect(frame.pts == index.pts(forFrame: position + delta))
            #expect(readFrameNumber(frame.pixelBuffer) == position + delta)
        }
        for delta in [-1, 0, 1] {
            let frame = try #require(try session.next())
            #expect(frame.pts == index.pts(forFrame: position + delta))
            #expect(readFrameNumber(frame.pixelBuffer) == position + delta)
        }
    }

    @Test func audioReadsThroughTheSameDescriptorAsVideo() throws {
        let url = Fixtures.url(Fixtures.withAudio)
        let handle = try FileHandle(forReadingFrom: url)
        let video = try OnDemandVideo(url: URL(fileURLWithPath: "/descriptor.mp4"),
                                      source: FileByteSource(duplicatingReadOnlyDescriptor: handle.fileDescriptor),
                                      preferHardware: false)
        try handle.close()
        let frame = try #require(try video.seek(to: 1))
        let audio = try #require(try video.makeAudioDecoder())
        try audio.seek(toSeconds: video.time(of: frame))
        let samples = try #require(try audio.nextBuffer())
        #expect(samples.buffer.frameLength > 0)
        #expect(abs(samples.startSeconds - video.time(of: frame)) < 0.03)
        #expect(try video.next() != nil)
    }

    @Test func silentVideoDoesNotOpenAnAudioStream() throws {
        let url = Fixtures.url(Fixtures.vfr)
        let video = try OnDemandVideo(url: url, source: FileByteSource(url: url), preferHardware: false)
        #expect(try video.makeAudioDecoder() == nil)
    }

    @Test func scrubbingRecentlyDecodedFramesDoesNotRereadTheFile() throws {
        let url = Fixtures.url(Fixtures.h264)
        let reads = try ReadCache(url: url, budgetBytes: 0)
        let video = try OnDemandVideo(url: url, readCache: reads, preferHardware: false)
        let anchor = try #require(try video.seek(to: 7.5))
        #expect(readFrameNumber(anchor.pixelBuffer) == 225)
        let requests = reads.stats.requests

        for number in stride(from: 224, through: 215, by: -1) {
            let frame = try #require(try video.previous())
            #expect(readFrameNumber(frame.pixelBuffer) == number)
        }
        for number in 216...225 {
            let frame = try #require(try video.next())
            #expect(readFrameNumber(frame.pixelBuffer) == number)
        }
        let middle = try #require(try video.seek(to: 219.5 / 30))
        #expect(readFrameNumber(middle.pixelBuffer) == 219)
        let after = try #require(try video.next())
        #expect(readFrameNumber(after.pixelBuffer) == 220)
        #expect(reads.stats.requests == requests)
    }

    @Test func fourKTenBitHistoryEvictsOldFramesAndRefillsExactly() throws {
        let url = Fixtures.url(Fixtures.hevc10)
        let reads = try ReadCache(url: url, budgetBytes: 0)
        let video = try OnDemandVideo(url: url, readCache: reads, preferHardware: false)
        let anchor = try #require(try video.seek(to: 70.0 / 30))
        #expect(readFrameNumber(anchor.pixelBuffer) == 70)
        let firstReads = reads.stats.requests

        let previous = try #require(try video.previous())
        #expect(readFrameNumber(previous.pixelBuffer) == 69)
        #expect(reads.stats.requests == firstReads)

        // Two P010 frames fit the window, but three exceed its byte budget.
        let refilled = try #require(try video.previous())
        #expect(readFrameNumber(refilled.pixelBuffer) == 68)
        #expect(reads.stats.requests > firstReads)
        let refillReads = reads.stats.requests
        let successor = try #require(try video.next())
        #expect(readFrameNumber(successor.pixelBuffer) == 69)
        #expect(reads.stats.requests == refillReads)
    }

    @Test func steppingAtTheEdgesDoesNotMoveTheCursor() throws {
        let (_, index) = try openIndexed(Fixtures.vfr)
        let url = Fixtures.url(Fixtures.vfr)
        let session = try OnDemandVideo(url: url, source: FileByteSource(url: url), preferHardware: false)
        let first = try #require(try session.next())
        #expect(first.pts == index.pts(forFrame: 0))
        #expect(try session.previous() == nil)
        #expect(try session.next()?.pts == index.pts(forFrame: 1))
        let last = try #require(try session.seek(to: .greatestFiniteMagnitude))
        #expect(last.pts == index.pts(forFrame: index.frameCount - 1))
        #expect(try session.next() == nil)
        #expect(try session.previous()?.pts == index.pts(forFrame: index.frameCount - 2))
    }
}
