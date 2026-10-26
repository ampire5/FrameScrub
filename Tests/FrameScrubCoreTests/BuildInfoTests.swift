import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct BuildInfoTests {
    private let baked: [String: Any] = [
        "FSBuildHash": "793b52f", "FSBuildBranch": "experiments", "FSBuildCommitDate": "2026-10-26 07:40",
        "FSBuildDirty": "1", "FSBuildDate": "2026-10-26 08:01",
    ]

    @Test func readsWhatMakeAppBaked() throws {
        let info = try #require(BuildInfo(infoDictionary: baked))
        #expect(info == BuildInfo(hash: "793b52f", branch: "experiments", commitDate: "2026-10-26 07:40", dirty: true,
                                  buildDate: "2026-10-26 08:01"))
    }

    @Test func oneLineSaysWhichBuild() throws {
        let info = try #require(BuildInfo(infoDictionary: baked))
        #expect(info.line == "experiments 793b52f + uncommitted changes · committed 2026-10-26 07:40 · built 2026-10-26 08:01")
        var clean = baked
        clean["FSBuildDirty"] = "0"
        #expect(BuildInfo(infoDictionary: clean)?.line == "experiments 793b52f · committed 2026-10-26 07:40 · built 2026-10-26 08:01")
    }

    @Test func aBuildWithoutTheKeysSaysSo() {
        #expect(BuildInfo(infoDictionary: [:]) == nil)
        #expect(BuildInfo(infoDictionary: ["FSBuildHash": ""]) == nil)
        #expect(BuildInfo.line(of: nil) == "Development build (not made by scripts/make-app.sh)")
    }
}
