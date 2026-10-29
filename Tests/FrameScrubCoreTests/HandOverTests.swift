import Foundation
import Testing
@testable import FrameScrubCore

/// A second launch hands its file to the running FrameScrub by a distributed notification that every running copy
/// hears; a copy takes only what its own bundle sent (a dev build beside the installed app, 2026-10-27).
@Suite struct HandOverTests {
    private let installed = "/Users/x/Applications/FrameScrub.app"
    private let dev = "/Users/x/Projects/GitHub/FrameScrub-strip/build/FrameScrub.app"

    @Test func ownBundleIsAccepted() {
        let info = HandOver.userInfo(path: "/v/a.mp4", link: nil, bundle: installed)
        #expect(info["path"] == "/v/a.mp4" && info[HandOver.bundleKey] == installed)
        #expect(HandOver.isForUs(info, ownBundle: installed))
    }

    @Test func otherBundleIsRefused() {
        #expect(!HandOver.isForUs(HandOver.userInfo(path: "/v/a.mp4", link: nil, bundle: installed), ownBundle: dev))
    }

    @Test func noteWithoutBundleIsAccepted() {
        #expect(HandOver.isForUs(["path": "/v/a.mp4"], ownBundle: dev))
        #expect(HandOver.isForUs(nil, ownBundle: dev))
    }

    @Test func pathsCompareStandardized() {
        let info = HandOver.userInfo(path: nil, link: nil, bundle: "/Users/x/Applications/../Applications/FrameScrub.app/")
        #expect(HandOver.isForUs(info, ownBundle: installed))
    }

    @Test func linkIsCarried() throws {
        let link = try #require(URL(string: "framescrub://open?scene=12"))
        #expect(HandOver.userInfo(path: nil, link: link, bundle: dev)["link"] == "framescrub://open?scene=12")
    }

    /// The single-instance key: two builds of the same app (one bundle identifier) are two apps, so a launch never
    /// hands its file to the other build, which would now refuse it.
    @Test func instanceKeyIsTheBundlePath() {
        #expect(HandOver.instanceKey(bundlePath: installed + "/", executablePath: "/x") == installed)
        #expect(HandOver.instanceKey(bundlePath: dev, executablePath: nil) != HandOver.instanceKey(bundlePath: installed,
                                                                                                    executablePath: nil))
        #expect(HandOver.instanceKey(bundlePath: nil, executablePath: "/usr/local/bin/fs") == "/usr/local/bin/fs")
        #expect(HandOver.instanceKey(bundlePath: nil, executablePath: nil) == nil)
    }
}
