import CFFmpeg
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct SmokeTests {
    @Test func linksFFmpeg() {
        #expect(avformat_version() >> 16 == UInt32(LIBAVFORMAT_VERSION_MAJOR))
        #expect(!FFmpegInfo.versionString.isEmpty)
    }

    @Test func fixturesExist() {
        for name in Fixtures.all {
            let path = Fixtures.directory.appendingPathComponent(name).path
            #expect(FileManager.default.fileExists(atPath: path), "missing \(name)")
        }
    }
}
