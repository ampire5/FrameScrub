import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct KeyframeThumbnailTests {
    @Test func identityDateMatchesTheListingDate() throws {
        let url = makeTemporaryDirectory().appendingPathComponent("video.mp4")
        try Data().write(to: url)
        let identity = try #require(MediaFileIdentity.read(url))
        let listed = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(identity.modificationDate == listed)
    }
    @Test(arguments: ["", "not a video"])
    func aDamagedFileReportsFailureAndDoesNotBlockTheNextPoster(payload: String) throws {
        let directory = makeTemporaryDirectory()
        let bad = directory.appendingPathComponent("damaged.mp4")
        try Data(payload.utf8).write(to: bad)
        let worker = RecentThumbnailer(store: ThumbnailStore(directory: directory.appendingPathComponent("pictures")),
                                       callbackQueue: DispatchQueue(label: "test.thumbnail-completion"))
        let failed = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        worker.start([.init(url: bad, seconds: nil), .init(url: Fixtures.url(Fixtures.withAudioGOP25), seconds: nil)],
                     failed: { url, failure in
                         #expect(url == bad)
                         #expect(failure.marksUnreadable)
                         failed.signal()
                     }) { url, _ in
            #expect(url == Fixtures.url(Fixtures.withAudioGOP25))
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(failed.wait(timeout: .now() + 1) == .success)
        worker.cancel()
    }

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
            worker.start([RecentThumbnailer.Job(url: url, seconds: 1)]) { _, facts in continuation.resume(returning: facts.duration ?? 0) }
        }
        #expect(abs(duration - 4) < 0.1)
        #expect(store.image(for: url) != nil)
    }

    /// A kept poster without facts: a probe brings them and makes no picture.
    @Test func aFactsOnlyJobProbesWithoutAPicture() async throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let worker = RecentThumbnailer(store: store, callbackQueue: DispatchQueue(label: "test"))
        let url = Fixtures.url(Fixtures.h264)
        let codec: String? = await withCheckedContinuation { continuation in
            worker.start([RecentThumbnailer.Job(url: url, seconds: nil, factsOnly: true)]) { _, facts in
                continuation.resume(returning: facts.codec)
            }
        }
        #expect(codec == "H.264")
        #expect(store.image(for: url) == nil)
    }
}
