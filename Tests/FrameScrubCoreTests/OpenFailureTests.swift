import Foundation
import Testing
import CFFmpeg
@testable import FrameScrubCore

@Suite struct OpenFailureTests {
    @Test(arguments: [
        (FFmpegError(-ENOENT, "open a.mp4") as Error, OpenFailure.Kind.notFound),
        (FFmpegError(-EACCES, "open a.mp4"), .noAccess),
        (FFmpegError(-ETIMEDOUT, "read stream info"), .network),
        (FFmpegError(-EHOSTDOWN, "open a.mp4"), .network),
        (FFmpegError(-ENOTCONN, "open a.mp4"), .network),
        (FFmpegError(-EIO, "read stream info"), .readError),
        (POSIXError(.EIO), .readError),
        (POSIXError(.ENETDOWN), .network),
        (FFmpegError(cff_averror_invaliddata(), "open a.mp4"), .damaged),
        (FFmpegError(cff_averror_stream_not_found(), "find video stream"), .noVideo),
        (FFmpegError(-1, "allocate demuxer"), .other),
        (CocoaError(.fileReadUnknown), .other),
    ])
    func classifies(_ error: Error, _ kind: OpenFailure.Kind) {
        #expect(OpenFailure(error).kind == kind)
    }

    @Test func keepsTheTechnicalText() {
        let failure = OpenFailure(FFmpegError(-ENOENT, "open a.mp4"))
        #expect(failure.detail == "open a.mp4: No such file or directory")
        #expect(FFmpegError(-ENOENT, "open a.mp4").localizedDescription == "open a.mp4: No such file or directory")
        #expect(!failure.reason.isEmpty)
    }

    @Test func aMissingFileFailsAsNotFound() {
        let player = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory())
        defer { player.close() }
        do {
            try player.open(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mp4"))
            Issue.record("opened a missing file")
        } catch {
            #expect(OpenFailure(error).kind == .notFound)
        }
    }

    @Test func aTextFileIsDamaged() throws {
        let file = makeTemporaryDirectory().appendingPathComponent("fake.mp4")
        try Data(repeating: 0x41, count: 4096).write(to: file)
        let player = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory())
        defer { player.close() }
        do {
            try player.open(file)
            Issue.record("opened a file of letters")
        } catch {
            #expect(OpenFailure(error).kind == .damaged)
        }
    }

    @Test func ownReasonIsShown() {
        let failure = OpenFailure(reason: #"No share for S:\Media\a.mp4"#, detail: "Mount the share")
        #expect(failure.reason == #"No share for S:\Media\a.mp4"#)
        #expect(failure.detail == "Mount the share")
        #expect(failure.kind == .other)
    }
}
