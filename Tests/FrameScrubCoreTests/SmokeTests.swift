import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct SmokeTests {
    @Test func linksFFmpeg() {
        #expect(FFmpegInfo.versionString.hasPrefix("9"))
    }

    @Test func fixturesExist() {
        for name in Fixtures.all {
            let path = Fixtures.directory.appendingPathComponent(name).path
            #expect(FileManager.default.fileExists(atPath: path), "missing \(name)")
        }
    }
}
