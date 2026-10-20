import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct KeyframeThumbnailTests {
    @Test func picksTheKeyframeAtOrBeforeThePositionAndKnowsTheLength() throws {
        let result = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.withAudioGOP25), at: 2.5))
        #expect(abs(result.duration - 4) < 0.1)
        #expect(result.picture.extent == CGRect(x: 0, y: 0, width: 640, height: 360))
        #expect(abs(result.seconds - 2) < 0.05)   // keyframes every second
    }

    @Test func withoutAPositionItLooksTenPercentIn() throws {
        let result = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.h264), at: nil))
        #expect(result.seconds == 0)   // 10 % of 20 s is 2 s; the keyframe before it is the first
        #expect(abs(result.duration - 20) < 0.1)
    }

    @Test func thePictureIsUprightWithSquarePixels() throws {
        let rotated = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.rotated), at: 1))
        #expect(rotated.picture.extent.size == CGSize(width: 360, height: 640))
        let anamorphic = try #require(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.anamorphic), at: 0))
        #expect(abs(anamorphic.picture.extent.width / anamorphic.picture.extent.height - 720 * 64 / 45 / 576.0) < 0.01)
    }

    @Test func aFileThatCannotBeDecodedHasNone() throws {
        #expect(KeyframeThumbnail.make(url: Fixtures.url(Fixtures.noDecoder), at: 1) == nil)
    }

    @Test func theRecentFilesWorkerSavesPicturesAndReportsLengths() async throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let worker = RecentThumbnailer(store: store, callbackQueue: DispatchQueue(label: "test"))
        let url = Fixtures.url(Fixtures.withAudioGOP25)
        let duration: Double = await withCheckedContinuation { continuation in
            worker.start([RecentThumbnailer.Job(url: url, seconds: 1)]) { _, duration in continuation.resume(returning: duration) }
        }
        #expect(abs(duration - 4) < 0.1)
        #expect(store.image(for: url) != nil)
    }
}
