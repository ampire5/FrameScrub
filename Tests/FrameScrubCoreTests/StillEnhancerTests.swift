import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import FrameScrubCore

private final class FakeUpscaler: StillUpscaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _upscaled = 0, _downloads = 0
    var state: MLAvailability = .ready
    var delay: Duration = .zero
    var failDownload = false
    var throwButBecomeReady = false
    var downloadDelay: Duration = .zero

    var upscaled: Int { lock.withLock { _upscaled } }
    var downloads: Int { lock.withLock { _downloads } }

    func availability(width: Int, height: Int) -> MLAvailability { state }
    func downloadModel() async throws {
        lock.withLock { _downloads += 1 }
        try await Task.sleep(for: downloadDelay)
        if throwButBecomeReady { state = .ready; throw MLUpscaleError.unavailable }
        if failDownload { throw MLUpscaleError.unavailable }
        state = .ready
    }
    func upscale4x(_ image: CIImage) async throws -> CIImage {
        try await Task.sleep(for: delay)
        lock.withLock { _upscaled += 1 }
        return ImageScaling.lanczos(image, scale: 4)
    }
}

@MainActor private final class RecordingEnhancerDelegate: StillEnhancerDelegate {
    var enhanced: [Int] = []
    var enhancedPTS: [Int64] = []
    var messages: [String] = []
    var requests = 0
    var answer = ModelDownloadChoice.download
    var disabled = false
    func stillEnhancer(_ e: StillEnhancer, requestModelDownload decide: @escaping (ModelDownloadChoice) -> Void) {
        requests += 1
        decide(answer)
    }
    func stillEnhancer(_ e: StillEnhancer, didEnhanceFrame number: Int, pts: Int64, image: CIImage) {
        enhanced.append(number)
        enhancedPTS.append(pts)
    }
    func stillEnhancer(_ e: StillEnhancer, message: String) { messages.append(message) }
    func stillEnhancerDidDisable(_ e: StillEnhancer) { disabled = true }
}

@Suite(.serialized) @MainActor struct StillEnhancerTests {
    private func frame(_ number: Int, range: DynamicRange = .sdr, pts: Int64? = nil) throws -> DecodedFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return DecodedFrame(number: number, pts: pts ?? Int64(number), pixelBuffer: try #require(buffer), dynamicRange: range)
    }

    private func make(_ fake: FakeUpscaler, limit: Int = 8) -> (StillEnhancer, RecordingEnhancerDelegate) {
        let enhancer = StillEnhancer(upscaler: fake, settleDelay: 0.05, minimumRatio: 1.2, cacheLimit: limit)
        let delegate = RecordingEnhancerDelegate()
        enhancer.delegate = delegate
        return (enhancer, delegate)
    }

    @Test func pausedFrameIsEnhancedAfterItSettles() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(delegate.enhanced.isEmpty)    // not before the settle delay
        #expect(await eventually { delegate.enhanced == [5] })
        #expect(delegate.messages == ["SR"])
    }

    @Test func playingOrSmallScaleOrDisabledDoNothing() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(1), isPaused: false, rotationClockwise: 0, ratio: 3)
        enhancer.update(frame: try frame(2), isPaused: true, rotationClockwise: 0, ratio: 1.2)   // needs > 1.2
        enhancer.isEnabled = false
        enhancer.update(frame: try frame(3), isPaused: true, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.enhanced.isEmpty)
        #expect(fake.upscaled == 0)
    }

    @Test func movingOnBeforeTheDelayCancels() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        enhancer.update(frame: try frame(6), isPaused: false, rotationClockwise: 0, ratio: 3)   // playback resumed
        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.enhanced.isEmpty)
    }

    @Test func aResultThatArrivesAfterCancellationIsDropped() async throws {
        let fake = FakeUpscaler()
        fake.delay = .milliseconds(150)
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { fake.state == .ready && enhancer.isWorking })
        enhancer.update(frame: try frame(6), isPaused: false, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(350))
        #expect(delegate.enhanced.isEmpty)
    }

    @Test func tooLargeSourcesAreSkippedSilently() async throws {
        let fake = FakeUpscaler()
        fake.state = .tooLarge
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.enhanced.isEmpty)
        #expect(delegate.messages.isEmpty)
        #expect(delegate.requests == 0)
    }

    @Test func repeatedUpdatesOfTheSameFrameUpscaleOnce() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        let shown = try frame(5)
        for _ in 0..<4 { enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3) }
        #expect(await eventually { delegate.enhanced == [5] })
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)    // cached: immediate
        #expect(delegate.enhanced == [5, 5])
        #expect(fake.upscaled == 1)
    }

    @Test func cacheKeepsTheLastEightFrames() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake, limit: 8)
        for n in 0..<9 {
            enhancer.update(frame: try frame(n), isPaused: true, rotationClockwise: 0, ratio: 3)
            #expect(await eventually { delegate.enhanced.last == n })
        }
        #expect(fake.upscaled == 9)
        enhancer.update(frame: try frame(8), isPaused: true, rotationClockwise: 0, ratio: 3)   // still cached
        #expect(fake.upscaled == 9)
        enhancer.update(frame: try frame(0), isPaused: true, rotationClockwise: 0, ratio: 3)   // evicted: recomputed
        #expect(await eventually { fake.upscaled == 10 })
    }

    @Test func modelDownloadIsRequestedOnceAndThenUsed() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        let (enhancer, delegate) = make(fake)
        delegate.answer = .download
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
        #expect(delegate.requests == 1)
        #expect(fake.downloads == 1)
        #expect(delegate.messages.contains { $0.hasPrefix("Downloading") })
    }

    @Test func notNowAsksOnlyOncePerSession() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        let (enhancer, delegate) = make(fake)
        delegate.answer = .notNow
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.requests == 1 })
        enhancer.update(frame: try frame(6), isPaused: true, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.requests == 1)
        #expect(delegate.enhanced.isEmpty)
        #expect(fake.downloads == 0)
    }

    @Test func neverDisablesSR() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        let (enhancer, delegate) = make(fake)
        delegate.answer = .never
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.disabled })
        #expect(!enhancer.isEnabled)
        #expect(fake.downloads == 0)
    }

    @Test func failedDownloadReportsOncePerSession() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        fake.failDownload = true
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("SR model download failed") } })
        enhancer.update(frame: try frame(6), isPaused: true, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.messages.filter { $0.hasPrefix("SR model download failed") }.count == 1)
        #expect(delegate.enhanced.isEmpty)
    }

    @Test func downloadThatThrowsButLeavesTheModelReadyIsSuccess() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        fake.throwButBecomeReady = true
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
        #expect(fake.downloads == 1)
        #expect(!delegate.messages.contains { $0.hasPrefix("SR model download failed") })
    }

    @Test func hdrFramesAreNotEnhanced() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5, range: .hlg), isPaused: true, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.enhanced.isEmpty)
        #expect(fake.upscaled == 0)
    }

    @Test func movingOnDuringDownloadDoesNotCancelIt() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        fake.downloadDelay = .milliseconds(150)
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { fake.downloads == 1 })
        enhancer.update(frame: try frame(6), isPaused: false, rotationClockwise: 0, ratio: 3)   // cancels the frame task
        try await Task.sleep(for: .milliseconds(350))
        #expect(!delegate.messages.contains { $0.hasPrefix("SR model download failed") })
        #expect(enhancer.isEnabled)
        #expect(fake.state == .ready)
        enhancer.update(frame: try frame(6), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [6] })
        #expect(fake.downloads == 1)
    }

    @Test func aStaleFrameCanRetryAfterTheDownloadFinished() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: false)
        fake.downloadDelay = .milliseconds(150)
        let (enhancer, delegate) = make(fake)
        let shown = try frame(5)
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { fake.downloads == 1 })
        enhancer.update(frame: try frame(6), isPaused: false, rotationClockwise: 0, ratio: 3)
        try await Task.sleep(for: .milliseconds(350))
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
    }

    @Test func aFinishedAttemptLetsTheSameFrameRetryWithoutAnyCancel() async throws {
        let fake = FakeUpscaler()
        fake.state = .modelNotReady(downloading: true)
        let (enhancer, delegate) = make(fake)
        let shown = try frame(5)
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.messages == ["SR model is downloading…"] && !enhancer.isWorking })
        fake.state = .ready
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
    }

    @Test func aRenumberedPictureIsNotServedFromTheCache() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5, pts: 500), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
        enhancer.update(frame: try frame(5, pts: 500), isPaused: true, rotationClockwise: 0, ratio: 3)   // hit
        #expect(delegate.enhanced == [5, 5])
        #expect(fake.upscaled == 1)
        enhancer.update(frame: try frame(5, pts: 900), isPaused: true, rotationClockwise: 0, ratio: 3)   // other picture
        #expect(delegate.enhanced == [5, 5])
        #expect(await eventually { fake.upscaled == 2 })
        #expect(await eventually { delegate.enhancedPTS == [500, 500, 900] })
    }

    @Test func anInFlightResultIsNotDeliveredForAnotherPicture() async throws {
        let fake = FakeUpscaler()
        fake.delay = .milliseconds(150)
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5, pts: 500), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { enhancer.isWorking })
        enhancer.update(frame: try frame(5, pts: 900), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(delegate.enhancedPTS == [900])
    }

    @Test func resetClearsTheCacheAndPendingWork() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
        enhancer.reset()
        enhancer.update(frame: try frame(5), isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { fake.upscaled == 2 })
    }

    @Test func purgingTheCacheMakesTheSameFrameBeUpscaledAgain() async throws {
        let fake = FakeUpscaler()
        let (enhancer, delegate) = make(fake)
        let shown = try frame(5)
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { delegate.enhanced == [5] })
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)    // cached: no second run
        #expect(fake.upscaled == 1)
        enhancer.purgeCache()
        enhancer.update(frame: shown, isPaused: true, rotationClockwise: 0, ratio: 3)
        #expect(await eventually { fake.upscaled == 2 })
    }
}
