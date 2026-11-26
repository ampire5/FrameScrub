import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct OpenLinkTests {
    private func link(_ string: String) -> URL { URL(string: string)! }

    @Test func decodesWhatJavaScriptEncodeURIComponentProduces() {
        // encodeURIComponent("/Volumes/F$/Видео 2024/a #1 100% & b.mp4")
        let encoded = "%2FVolumes%2FF%24%2F%D0%92%D0%B8%D0%B4%D0%B5%D0%BE%202024%2Fa%20%231%20100%25%20%26%20b.mp4"
        let url = OpenLink.fileURL(from: link("framescrub://open?path=" + encoded))
        #expect(url?.path == "/Volumes/F$/Видео 2024/a #1 100% & b.mp4")
        #expect(url?.isFileURL == true)
    }

    @Test func keepsAPlusSignInThePath() {
        let url = OpenLink.fileURL(from: link("framescrub://open?path=%2Fa%2Fb%2Bc.mp4"))
        #expect(url?.path == "/a/b+c.mp4")
    }

    @Test func takesThePathAmongOtherParameters() {
        let url = OpenLink.fileURL(from: link("framescrub://open?x=1&path=%2Fa.mp4&y=2"))
        #expect(url?.path == "/a.mp4")
    }

    @Test func anotherHostIsNotOurs() {
        #expect(OpenLink.fileURL(from: link("framescrub://other?path=/a")) == nil)
    }

    @Test func withoutAPathThereIsNothingToOpen() {
        #expect(OpenLink.fileURL(from: link("framescrub://open")) == nil)
        #expect(OpenLink.fileURL(from: link("framescrub://open?path=")) == nil)
    }

    @Test func aRelativePathIsRefused() {
        #expect(OpenLink.fileURL(from: link("framescrub://open?path=rel/a")) == nil)
    }

    @Test func aFileURLPassesThrough() {
        let url = link("file:///a.mp4")
        #expect(OpenLink.fileURL(from: url) == url)
    }

    @Test func anotherSchemeIsRefused() {
        #expect(OpenLink.fileURL(from: link("https://open?path=/a")) == nil)
    }

    @Test func readsTimeSegmentAndPlugin() {
        let target = OpenLink.target(from: link(
            "framescrub://open?path=%2Fa.mp4&t=12.5&seg=10-16&plugin=http%3A%2F%2Fhost%3A8000%2Fp%2F%3Fq%3D1"))
        #expect(target?.file?.path == "/a.mp4")
        #expect(target?.time == 12.5)
        #expect(target?.segments == [10...16])
        #expect(target?.plugin?.absoluteString == "http://host:8000/p/?q=1")
        #expect(target?.start == 12.5)
    }

    /// The file of a link is taken as a file without asking the disk (a share answers each question over the network).
    @Test func aLinksFileIsNotLookedUp() {
        let dir = FileManager.default.temporaryDirectory.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(OpenLink.target(from: link("framescrub://open?path=\(dir)"))?.file?.hasDirectoryPath == false)
    }

    @Test func aSegmentAloneStartsAtItsBeginning() {
        let target = OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4&seg=3.5-9"))
        #expect(target?.time == nil)
        #expect(target?.start == 3.5)
    }

    @Test func badExtrasAreIgnoredButTheFileStillOpens() {
        let target = OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4&t=-4&seg=9-3&plugin=file%3A%2F%2F%2Fx"))
        #expect(target?.file?.path == "/a.mp4")
        #expect(target?.time == nil)
        #expect(target?.segments == [])
        #expect(target?.plugin == nil)
    }

    @Test func aSceneIsNamedByItsStashID() {
        let target = OpenLink.target(from: link("framescrub://open?scene=42&t=3&seg=1-5"))
        #expect(target?.subject == .stashScene(id: "42"))
        #expect(target?.sceneID == "42")
        #expect(target?.file == nil)
        #expect(target?.landing == LinkTarget(time: 3, segments: [1...5]))
        #expect(OpenLink.fileURL(from: link("framescrub://open?scene=42")) == nil)
        #expect(OpenLink.target(from: link("framescrub://open?scene=")) == nil)
        #expect(OpenLink.target(from: link("framescrub://open?scene=%20")) == nil)
        // A path wins over a scene; a bad path is not rescued by a scene.
        #expect(OpenLink.target(from: link("framescrub://open?scene=7&path=%2Fa.mp4"))?.subject == .file(link("file:///a.mp4")))
        #expect(OpenLink.target(from: link("framescrub://open?scene=7&path=rel")) == nil)
        #expect(OpenLink.target(from: link("file:///a.mp4"))?.sceneID == nil)
    }

    @Test func decodesAWebURLWithItsOwnQueryAndLandingOptions() throws {
        let page = link("HTTPS://example.com/watch/a%20b?v=3&token=z%2B%2F#clip")
        let encoded = page.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = link("framescrub://open?url=\(encoded)&t=3.5&seg=1-5,7-9&lock=0&adv=next&plugin=https%3A%2F%2Fplugin.example%2F")
        let target = try #require(OpenLink.target(from: url))
        #expect(target.subject == .web(page))
        #expect(target.landing == LinkTarget(time: 3.5, segments: [1...5, 7...9], lock: false, advance: .next))
        #expect(target.plugin == link("https://plugin.example/"))
        #expect(OpenLink.fileURL(from: url) == nil)
    }

    @Test func aWebURLMustHaveAnHTTPOrHTTPSHost() {
        for bad in ["", "file:///a.mp4", "ftp://example.com/a", "http:///watch", "https:watch", "/watch"] {
            let encoded = bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            #expect(OpenLink.target(from: link("framescrub://open?url=\(encoded)")) == nil, "\(bad)")
        }
    }

    @Test func aWebURLHasLowerPrecedenceThanAPathOrScene() {
        let page = "url=https%3A%2F%2Fexample.com%2Fwatch"
        #expect(OpenLink.target(from: link("framescrub://open?\(page)&scene=7&path=%2Fa.mp4"))?.subject == .file(link("file:///a.mp4")))
        #expect(OpenLink.target(from: link("framescrub://open?\(page)&scene=7"))?.subject == .stashScene(id: "7"))
        #expect(OpenLink.target(from: link("framescrub://open?\(page)&path=rel")) == nil)
    }

    @Test func segmentText() {
        #expect(OpenLink.segment(from: "1-2") == 1...2)
        #expect(OpenLink.segment(from: "1.25 - 7") == 1.25...7)
        #expect(OpenLink.segment(from: "5") == nil)
        #expect(OpenLink.segment(from: "a-b") == nil)
        #expect(OpenLink.segment(from: "4-4") == nil)
    }
}

extension OpenLinkTests {
    @Test func landingCarriesTimeAndSegment() {
        let target = OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4&t=2&seg=1-5"))
        #expect(target?.landing == LinkTarget(time: 2, segments: [1...5]))
        #expect(OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4"))?.landing.isEmpty == true)
    }

    @Test func timeAndSegmentWriteThroughToTheLanding() {
        var target = OpenLink.Target(file: link("file:///a.mp4"))
        target.time = 4
        target.segments = [1...9]
        #expect(target.landing == LinkTarget(time: 4, segments: [1...9]))
        #expect(target == OpenLink.Target(file: link("file:///a.mp4"), time: 4, segments: [1...9]))
    }
}

extension OpenLinkTests {
    @Test func readsSegmentListLockAndAdvance() {
        let target = OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4&seg=10-20,35.5-40&lock=0&adv=next"))
        #expect(target?.segments == [10...20, 35.5...40])
        #expect(target?.landing.lock == false)
        #expect(target?.landing.advance == .next)
        #expect(target?.start == 10)
        let plain = OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4&seg=10-20&lock=1&adv=repeat"))
        #expect(plain?.segments == [10...20])
        #expect(plain?.landing.lock == true)
        #expect(plain?.landing.advance == .repeating)
    }

    @Test func badListLockAndAdvanceAreIgnored() {
        let target = OpenLink.target(from: link("framescrub://open?path=%2Fa.mp4&seg=10-20,x&lock=2&adv=sideways"))
        #expect(target?.file?.path == "/a.mp4")
        #expect(target?.segments == [])
        #expect(target?.landing.lock == nil)
        #expect(target?.landing.advance == nil)
    }
}

@Test func playbackHandoffCanRequirePausedLanding() throws {
    let request = try #require(URL(string: "framescrub://open?path=/sample.mp4&t=1.25&paused=1"))
    let landing = try #require(OpenLink.target(from: request)?.landing)
    #expect(landing.time == 1.25)
    #expect(landing.paused == true)
    #expect(!landing.isEmpty)

    let normal = try #require(URL(string: "framescrub://open?path=/sample.mp4"))
    #expect(OpenLink.target(from: normal)?.landing.paused == nil)
}

@MainActor
@Test func pausedHandoffRetainsVFRPresentationTimeAfterIndexing() async throws {
    let (_, exact) = try openIndexed(Fixtures.vfr)
    let url = Fixtures.url(Fixtures.vfr)
    let approximate = try MediaSource(url: url).approximateIndex()
    let frame = try #require((0..<exact.frameCount).first { n in
        let t = exact.seconds(forFrame: n)
        let estimated = approximate.pts(forFrame: approximate.frameNumber(forSeconds: t))
        return exact.nearestFrameNumber(forPTS: estimated) != n
    })
    let time = exact.seconds(forFrame: frame)
    var config = Config()
    config.autoplay = true
    let player = PlayerCore(config: config, enableAudio: false, fallbackRoot: makeTemporaryDirectory())
    defer { player.close() }
    let open = player.preparation(for: url)
    let prepared = try await Task.detached { try open() }.value
    player.open(prepared, landingTime: time, startPaused: true)
    player.applyLanding(LinkTarget(time: time, paused: true))
    #expect(player.isPaused)
    #expect(player.displayedFrame == nil)
    #expect(await eventually { player.index?.isExact == true })
    #expect(await eventually { player.displayedFrame == frame })
    #expect(player.position == frame)
    #expect(player.isPaused)
}
