import CoreGraphics
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PreviewTests {
    // MARK: LatestOnlyWorker

    @Test func onlyTheLatestSubmissionRunsWhileTheWorkerIsBusy() async throws {
        let started = Locked(false)
        let release = DispatchSemaphore(value: 0)
        let handled = Locked<[Int]>([])
        let worker = LatestOnlyWorker<Int>(label: "test") { value in
            handled.mutate { $0.append(value) }
            if value == 1 { started.mutate { $0 = true }; release.wait() }
        }
        worker.submit(1)
        #expect(await eventually { started.value })     // 1 is running and blocked
        for value in 2...10 { worker.submit(value) }    // 2…9 are overwritten
        release.signal()
        #expect(await eventually { handled.value == [1, 10] })
    }

    // MARK: LRUCache

    @Test func theLeastRecentlyUsedEntryIsEvicted() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache.set(1, "a"); cache.set(2, "b")
        #expect(cache.get(1) == "a")                    // 1 is now the most recent
        cache.set(3, "c")                               // evicts 2
        #expect(cache.get(2) == nil)
        #expect(cache.get(1) == "a" && cache.get(3) == "c")
        #expect(cache.count == 2)
    }

    // MARK: VideoDecoder.seekToKeyframe

    @Test func seekToKeyframeReturnsTheKeyframeNotTheTarget() throws {
        let (source, index) = try openIndexed(Fixtures.h264)             // keyframes 0 / 250 / 500
        let decoder = try VideoDecoder(source: source, index: index)
        for (target, keyframe) in [(360, 250), (499, 250), (500, 500), (10, 0), (599, 500)] {
            try decoder.seekToKeyframe(near: target)
            let frame = try #require(try decoder.nextFrame())
            #expect(readFrameNumber(frame.pixelBuffer) == keyframe, "target \(target)")
        }
    }

    // MARK: Thumbnails

    @Test func thumbnailsFitTheRequestedBoxAndAreNeverEnlarged() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try VideoDecoder(source: source, index: index)
        let frame = try #require(try decoder.nextFrame())
        let renderer = FrameImageRenderer()
        let small = try #require(renderer.thumbnail(for: frame, rotationClockwise: 0, width: 240))
        #expect(small.width == 240 && small.height == 135)
        let huge = try #require(renderer.thumbnail(for: frame, rotationClockwise: 0, width: 5000))
        #expect(huge.width == 1920)
    }

    @Test func hdrAndRotatedFramesRender() throws {
        let (hdrSource, hdrIndex) = try openIndexed(Fixtures.hevc10)
        let hdr = try #require(try VideoDecoder(source: hdrSource, index: hdrIndex).nextFrame())
        #expect(FrameImageRenderer().thumbnail(for: hdr, rotationClockwise: 0, width: 200) != nil)
        let (rotSource, rotIndex) = try openIndexed(Fixtures.rotated)
        let rotated = try #require(try VideoDecoder(source: rotSource, index: rotIndex).nextFrame())
        let image = try #require(FrameImageRenderer().thumbnail(for: rotated, rotationClockwise: 270, width: 90))
        #expect(image.width == 51 && image.height == 90)   // fitted into a 90 x 90 box
    }

    // MARK: PreviewProvider

    @Test(arguments: [true, false])
    func foldedMissDoesNotPoisonLaterRequests(readyOnly: Bool) async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.noDecoder), index: index,
            rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let images = collect(provider)
        let finished = Locked(false), unavailable = Locked(false)
        provider.onRequestFinished = { finished.mutate { $0 = true } }
        provider.onUnavailable = { unavailable.mutate { $0 = true } }
        provider.request(seconds: 12, readyOnly: readyOnly, speculative: !readyOnly)
        #expect(await eventually { finished.value })
        #expect(images.value.isEmpty && !unavailable.value && provider.decodeCount == 0)
        provider.request(seconds: 12)
        #expect(await eventually { unavailable.value })
    }

    @Test func providersShareThumbnailsWithoutDecodingAgain() async throws {
        let url = Fixtures.url(Fixtures.h264)
        let (_, index) = try openIndexed(Fixtures.h264)
        let pool = PreviewImagePool(url: url, rotationClockwise: 0)
        let hover = PreviewProvider(url: url, index: index, rotationClockwise: 0, widthPixels: 320, imagePool: pool)
        let film = PreviewProvider(url: url, index: index, rotationClockwise: 0, widthPixels: 160, imagePool: pool)
        defer { hover.stop(); film.stop() }
        let first = collect(hover), second = collect(film)
        hover.request(seconds: 9)
        #expect(await eventually { first.value.count == 1 })
        #expect(film.canReuse(seconds: 10))
        film.request(seconds: 10)
        #expect(await eventually { second.value.count == 1 })
        #expect(film.decodeCount == 0)
        #expect(abs(try #require(second.value.first).frameSeconds - 250.0 / 30) < 0.00001)
    }

    @Test func smallFilmImageDoesNotReduceHoverResolution() async throws {
        let url = Fixtures.url(Fixtures.h264)
        let (_, index) = try openIndexed(Fixtures.h264)
        let pool = PreviewImagePool(url: url, rotationClockwise: 0)
        let film = PreviewProvider(url: url, index: index, rotationClockwise: 0, widthPixels: 80, imagePool: pool)
        let hover = PreviewProvider(url: url, index: index, rotationClockwise: 0, widthPixels: 320, imagePool: pool)
        defer { film.stop(); hover.stop() }
        let first = collect(film), second = collect(hover)
        film.request(seconds: 9)
        #expect(await eventually { first.value.count == 1 })
        #expect(!hover.canReuse(seconds: 9))
        hover.request(seconds: 9)
        #expect(await eventually { second.value.count == 1 })
        #expect(try #require(second.value.first).image.width == 320)
        #expect(hover.decodeCount == 1)
    }

    @Test func matchingPlaybackFrameAvoidsOpeningPreviewDecoder() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seekToKeyframe(near: 360)
        let frame = try #require(try decoder.nextFrame())
        let cache = FrameCache(budgetBytes: 32 * 1024 * 1024)
        cache.insert(frame)
        // The URL cannot be decoded: a delivered image must have come from the playback cache.
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.noDecoder), index: index,
            rotationClockwise: 0, widthPixels: 160, frameCache: cache)
        defer { provider.stop() }
        let images = collect(provider)
        #expect(provider.canReuse(seconds: 12))
        provider.request(seconds: 12, readyOnly: true)
        #expect(await eventually { images.value.count == 1 })
        #expect(provider.decodeCount == 0)
        #expect(abs(try #require(images.value.first).frameSeconds - 250.0 / 30) < 0.00001)
    }

    @Test func nearbyPlaybackFramesAndApproximateNumbersCannotMasqueradeAsKeyframes() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seek(toFrame: 251)
        let frame = try #require(try decoder.nextFrame())
        let cache = FrameCache(budgetBytes: 32 * 1024 * 1024)
        cache.insert(frame)
        let exact = PreviewProvider(url: Fixtures.url(Fixtures.h264), index: index,
            rotationClockwise: 0, widthPixels: 160, frameCache: cache)
        let approximate = PreviewProvider(url: Fixtures.url(Fixtures.h264),
            index: .approximate(startPTS: 0, ticksPerFrame: 1, frameCount: 600, timeBase: 1.0 / 30),
            rotationClockwise: 0, widthPixels: 160, frameCache: cache)
        defer { exact.stop(); approximate.stop() }
        #expect(!exact.canReuse(seconds: 12))
        #expect(!approximate.canReuse(seconds: 251.0 / 30))
    }

    @Test func poolHonoursSourceRotationResolutionAndBounds() throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let frame = try #require(try VideoDecoder(source: source, index: index).nextFrame())
        let image = try #require(FrameImageRenderer().thumbnail(for: frame, rotationClockwise: 0, width: 160))
        let url = Fixtures.url(Fixtures.h264)
        let pool = PreviewImagePool(url: url, rotationClockwise: 0, capacity: 2)
        pool.set(image, pts: 0, widthPixels: 160)
        #expect(pool.image(pts: 0, widthPixels: 80) != nil)
        #expect(pool.image(pts: 0, widthPixels: 320) == nil)
        for (sourceURL, rotation) in [(Fixtures.url(Fixtures.withAudio), 0), (url, 90)] {
            let provider = PreviewProvider(url: sourceURL, index: index, rotationClockwise: rotation,
                widthPixels: 80, imagePool: pool)
            #expect(!provider.canReuse(seconds: 0))
            provider.stop()
        }
        pool.set(image, pts: 250, widthPixels: 160)
        pool.set(image, pts: 500, widthPixels: 160)
        #expect(pool.image(pts: 0, widthPixels: 80) == nil)
        #expect(pool.count == 2)
        let tiny = PreviewImagePool(url: url, rotationClockwise: 0, budgetBytes: 1)
        tiny.set(image, pts: 0, widthPixels: 160)
        #expect(tiny.count == 0)
        let budget = PreviewImagePool(url: url, rotationClockwise: 0,
            budgetBytes: image.bytesPerRow * image.height * 2)
        for pts: Int64 in [0, 250, 500] { budget.set(image, pts: pts, widthPixels: 160) }
        #expect(budget.count == 2 && budget.image(pts: 0, widthPixels: 160) == nil)
    }

    @Test func approximateDecodeIsReusedByActualPTSAfterExactIndexArrives() async throws {
        let url = Fixtures.url(Fixtures.h264)
        let approximate = try MediaSource(url: url).approximateIndex()
        let (_, exact) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: url, index: approximate, rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let images = collect(provider)
        provider.request(seconds: 12)
        #expect(await eventually { images.value.count == 1 })
        provider.updateIndex(exact)
        provider.request(seconds: 9)
        #expect(await eventually { images.value.count == 2 })
        #expect(provider.decodeCount == 1)
        #expect(abs(try #require(images.value.last).frameSeconds - 250.0 / 30) < 0.00001)
    }

    @Test func stoppingSuppressesQueuedImageAndCompletion() async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.h264), index: index,
            rotationClockwise: 0, widthPixels: 160, policy: .network)
        let images = collect(provider)
        let completions = Locked(0)
        provider.onRequestFinished = { completions.mutate { $0 += 1 } }
        provider.request(seconds: 9)
        provider.stop()
        try await Task.sleep(for: .milliseconds(350))
        #expect(images.value.isEmpty && completions.value == 0)
        #expect(provider.decodeCount == 0)
    }

    @Test func aFailedRequestStillReleasesTheSequentialLoader() async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.noDecoder), index: index, rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let finished = Locked(false)
        provider.onRequestFinished = { finished.mutate { $0 = true } }
        provider.request(seconds: 1)
        #expect(await eventually { finished.value })
    }

    private func collect(_ provider: PreviewProvider) -> Locked<[PreviewImage]> {
        let images = Locked<[PreviewImage]>([])
        provider.onImage = { image in images.mutate { $0.append(image) } }
        return images
    }

    @Test func aRequestProducesAThumbnailOfThePrecedingKeyframe() async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.h264), index: index, rotationClockwise: 0, widthPixels: 200)
        defer { provider.stop() }
        let images = collect(provider)
        provider.request(seconds: 12.0)                 // frame 360 → keyframe 250 at 8.333 s
        #expect(await eventually { !images.value.isEmpty })
        let image = try #require(images.value.last)
        #expect(image.image.width == 200)
        #expect(abs(image.requestedSeconds - 12.0) < 1e-9)
        #expect(abs(image.frameSeconds - 250.0 / 30) < 0.05)
    }

    @Test func theSameKeyframeIsServedFromTheCache() async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.h264), index: index, rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let images = collect(provider)
        provider.request(seconds: 9.0)
        #expect(await eventually { images.value.count == 1 })
        provider.request(seconds: 10.0)                 // same GOP
        #expect(await eventually { images.value.count == 2 })
        #expect(provider.decodeCount == 1)
    }

    @Test func manyQuickRequestsDecodeOnlyAFew() async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.h264), index: index, rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let images = collect(provider)
        for i in 0..<40 { provider.request(seconds: Double(i) * 0.5) }
        #expect(await eventually { images.value.last.map { abs($0.requestedSeconds - 19.5) < 1e-9 } ?? false })
        #expect(provider.decodeCount < 10)
    }

    @Test func worksWithAnApproximateIndex() async throws {
        let approximate = try MediaSource(url: Fixtures.url(Fixtures.h264)).approximateIndex()
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.h264), index: approximate, rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let images = collect(provider)
        provider.request(seconds: 12.0)
        #expect(await eventually { !images.value.isEmpty })
    }

    @Test func aFileTheDecoderCannotOpenReportsUnavailable() async throws {
        let (_, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: Fixtures.url(Fixtures.noDecoder), index: index, rotationClockwise: 0, widthPixels: 160)
        defer { provider.stop() }
        let unavailable = Locked(false)
        let completed = Locked(0)
        provider.onUnavailable = { unavailable.mutate { $0 = true } }
        provider.onRequestFinished = { completed.mutate { $0 += 1 } }
        provider.request(seconds: 1)
        #expect(await eventually { unavailable.value && completed.value == 1 })
        provider.request(seconds: 2)
        #expect(await eventually { completed.value == 2 })
    }
}

/// A value shared between the test and a background queue.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
