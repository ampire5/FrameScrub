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
}
