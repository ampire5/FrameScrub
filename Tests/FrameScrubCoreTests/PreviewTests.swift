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
        provider.onUnavailable = { unavailable.mutate { $0 = true } }
        provider.request(seconds: 1)
        #expect(await eventually { unavailable.value })
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
