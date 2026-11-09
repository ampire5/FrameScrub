import Testing
import CoreVideo
import CoreMedia
import VideoToolbox
@testable import FrameScrubCore

@Suite struct LowLatencyVideoTests {
    @Test func adaptiveScaleUsesSupportedFactorsWithoutReducingSource() {
        #expect(LLScaleChoice.auto.factor(supported: [1.5, 2, 4], ratio: 1) == nil)
        #expect(LLScaleChoice.auto.factor(supported: [1.5, 2, 4], ratio: 1.7) == 2)
        #expect(LLScaleChoice.auto.factor(supported: [1.5, 2, 4], ratio: 5) == 4)
        #expect(LLScaleChoice.auto.factor(supported: [], ratio: 3) == nil)
        #expect(LLScaleChoice.x2.factor(supported: [1.5], ratio: 2) == nil)
        #expect(LLScaleChoice.x4.factor(supported: [1.5, 2, 4], ratio: 1) == 4)
        #expect(LLScaleChoice.off.factor(supported: [2], ratio: 2) == nil)
    }

    @Test func settingsRoundTripAndRetiredOptionsStayInactive() {
        let (config, warnings) = Config.parse("ll-sr=1.5\nll-interpolation=4\nsr-still=yes\ndeblock=yes\nsave-upscaler=ml\n")
        #expect(warnings.isEmpty)
        #expect(config.lowLatency.scale == .x1_5)
        #expect(config.lowLatency.intermediateFrames == 3)
        #expect(config.saveUpscaler == .lanczos)
        let (again, _) = Config.parse("ll-sr=\(config.text(forKey: "ll-sr")!)\nll-interpolation=\(config.text(forKey: "ll-interpolation")!)")
        #expect(again.lowLatency == config.lowLatency)
        let (bad, errors) = Config.parse("ll-sr=3\nll-interpolation=3")
        #expect(errors.count == 2)
        #expect(!bad.lowLatency.enabled)
    }

    @Test func intermediateSelectionDoesNotRunAheadOfClock() {
        #expect(LLPresentation.phaseIndex(at: 0.999, start: 1, end: 1.04, count: 3) == nil)
        #expect(LLPresentation.phaseIndex(at: 1.009, start: 1, end: 1.04, count: 3) == nil)
        #expect(LLPresentation.phaseIndex(at: 1.011, start: 1, end: 1.04, count: 3) == 0)
        #expect(LLPresentation.phaseIndex(at: 1.031, start: 1, end: 1.04, count: 3) == 2)
        #expect(LLPresentation.phaseIndex(at: 1.041, start: 1, end: 1.04, count: 3) == nil)
    }

    @Test func onlyConsecutiveForwardFramesAreInterpolated() {
        #expect(LLPresentation.canInterpolate(frame: 10, next: 11, start: 1, end: 1.04, playing: true, speed: 1, direction: 1))
        #expect(!LLPresentation.canInterpolate(frame: 10, next: 12, start: 1, end: 1.08, playing: true, speed: 1, direction: 1))
        #expect(!LLPresentation.canInterpolate(frame: 10, next: 11, start: 1, end: 1.04, playing: false, speed: 1, direction: 1))
        #expect(!LLPresentation.canInterpolate(frame: 10, next: 11, start: 1, end: 1.04, playing: true, speed: 2, direction: 1))
        #expect(!LLPresentation.canInterpolate(frame: 10, next: 11, start: 1, end: 1.04, playing: true, speed: 1, direction: -1))
    }
}

@Suite(.serialized) struct LowLatencyVideoProcessorTests {
    func frame(_ number: Int, luma: UInt8, width: Int = 272, height: Int = 480) throws -> DecodedFrame {
        var b: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b) == 0)
        let buffer = try #require(b)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)*height)
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)*(height/2))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return DecodedFrame(number: number, pts: Int64(number), pixelBuffer: buffer, dynamicRange: .sdr)
    }
    @Test func unsupported4KPreservesNativeBuffer() async throws {
        let source = try frame(0, luma: 48, width: 3840, height: 2160)
        var settings = LowLatencyVideoSettings(); settings.scale = .x2
        let output = try await LowLatencyVideoProcessor().process(.init(frame: source, next: nil, start: 0, end: 1/30,
                                                                        settings: settings, ratio: 2))
        // This host does not support 4K LL SR; if a future host does, validate its native output instead.
        if output.scaleFactor == nil {
            #expect(output.current === source.pixelBuffer)
            #expect(!output.hasEffectImage)
            #expect(output.status.contains("unsupported"))
        } else {
            #expect(CVPixelBufferGetWidth(output.current) == 7680)
        }
    }

    @Test func hdrBypassNeverBecomesAnEffectImage() async throws {
        let original = try frame(0, luma: 48)
        let hdr = DecodedFrame(number: 0, pts: 0, pixelBuffer: original.pixelBuffer, dynamicRange: .pq)
        var settings = LowLatencyVideoSettings(); settings.scale = .x2; settings.intermediateFrames = 1
        let output = try await LowLatencyVideoProcessor().process(.init(frame: hdr, next: nil, start: 0, end: 1/30,
                                                                        settings: settings, ratio: 2))
        #expect(!output.hasEffectImage)
        #expect(output.scaleFactor == nil)
        #expect(output.current === original.pixelBuffer)
        #expect(output.status.contains("HDR bypass"))
    }

    @Test(.disabled(if: isVirtualMachine, "Paravirtual VideoToolbox reports support but cannot process these frames"),
          .enabled(if: VTLowLatencySuperResolutionScalerConfiguration.isSupported && VTLowLatencyFrameInterpolationConfiguration.isSupported),
          arguments: [1, 3])
    func realSRAndInterpolationProduceOwnedOutputs(_ count: Int) async throws {
        let processor = LowLatencyVideoProcessor()
        var settings = LowLatencyVideoSettings(); settings.scale = .x2; settings.intermediateFrames = count
        let first = try frame(0, luma: 48), second = try frame(1, luma: 192)
        let result = try await processor.process(.init(frame: first, next: second, start: 0, end: 1/30,
                                                      settings: settings, ratio: 2))
        #expect(result.scaleFactor == 2)
        #expect(CVPixelBufferGetWidth(result.current) == 544)
        #expect(CVPixelBufferGetHeight(result.current) == 960)
        #expect(result.intermediates.count == count)
        #expect(result.status.contains("LL SR ×2"))
        #expect(result.status.contains("LL FI ×\(count + 1)"))
        let next = try await processor.process(.init(frame: second, next: nil, start: 1/30, end: 2/30,
                                                    settings: settings, ratio: 2))
        func y(_ b: CVPixelBuffer) -> UInt8 {
            CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            return CVPixelBufferGetBaseAddressOfPlane(b, 0)!.load(as: UInt8.self)
        }
        #expect(y(result.current) < 100)
        #expect(Int(y(next.current)) - Int(y(result.current)) > 32)
        #expect(y(result.current) < 100) // retained output cannot alias the next pool allocation
    }
}

private actor LLWorkGate {
    var started: [Int] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func run(_ n: Int) async -> Int {
        started.append(n)
        if n == 1 { await withCheckedContinuation { continuation = $0 } }
        return n * 10
    }
    func release() { continuation?.resume(); continuation = nil }
}
@Suite @MainActor struct LowLatencyVideoQueueTests {
    @Test func replacesPendingWorkAndRejectsInvalidatedResult() async throws {
        let gate = LLWorkGate()
        let queue = LatestVideoWork<Int, Int> { await gate.run($0) }
        var results: [Int] = []
        queue.onResult = { _, value in results.append(value) }
        queue.submit(1)
        for _ in 0..<100 { if await gate.started == [1] { break }; try await Task.sleep(for: .milliseconds(5)) }
        queue.submit(2)
        queue.invalidate()
        queue.submit(3)
        queue.submit(4)
        await gate.release()
        for _ in 0..<100 { if results == [40] { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.started == [1, 4])
        #expect(results == [40])
    }
}

@Suite(.serialized) struct TemporalNoiseTests {
    @Test func configurationRoundTripsAndRejectsInvalidStrength() {
        let (config, warnings) = Config.parse("temporal-noise=yes\ntemporal-noise-strength=0.7")
        #expect(warnings.isEmpty)
        #expect(config.lowLatency.noiseEnabled && config.lowLatency.noiseStrength == 0.7)
        #expect(config.lowLatency.enabled)
        let (bad, errors) = Config.parse("temporal-noise-strength=1.1")
        #expect(errors.count == 1)
        #expect(!bad.lowLatency.noiseEnabled)
    }
    @Test func missingReferencesAndZeroStrengthKeepTheOriginal() async throws {
        let frame = try LowLatencyVideoProcessorTests().frame(5, luma: 96)
        var settings = LowLatencyVideoSettings(); settings.noiseEnabled = true
        let worker = LowLatencyVideoProcessor()
        let absent = try await worker.process(.init(frame: frame, next: nil, start: 5/30, end: 6/30,
                                                    settings: settings, ratio: 1))
        #expect(!absent.hasEffectImage)
        #expect(absent.status.contains("reference"))
        settings.noiseStrength = 0
        let zero = try await worker.process(.init(frame: frame, next: nil, start: 5/30, end: 6/30,
                                                  settings: settings, ratio: 1))
        #expect(zero.current === frame.pixelBuffer)
        #expect(!zero.hasEffectImage)
    }
    @Test func referencesExcludeGapsWrongSizesAndDifferentRange() throws {
        let make = LowLatencyVideoProcessorTests(), current = try make.frame(10, luma: 96)
        let past = try make.frame(9, luma: 96), next = try make.frame(11, luma: 96)
        let far = try make.frame(12, luma: 96), wrong = try make.frame(11, luma: 96, width: 640, height: 480)
        let candidates: [TemporalNoiseReference] = [.init(frame: past, seconds: 0.9), .init(frame: far, seconds: 1.2),
            .init(frame: wrong, seconds: 1.1), .init(frame: current, seconds: 1)]
        #expect(TemporalNoiseFilter.references(frame: current, seconds: 1, candidates: candidates).map { $0.frame.number } == [9])
        #expect(TemporalNoiseFilter.references(frame: current, seconds: 1, candidates: candidates + [.init(frame: next, seconds: 1.1)]).map { $0.frame.number } == [9, 11, 12])
    }

    @Test(.enabled(if: VTTemporalNoiseFilterConfiguration.isSupported))
    func nativeHDRKeepsTenBitFormatAndRange() async throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        let decoder = try VideoDecoder(source: source, index: index)
        let first = try #require(try decoder.nextFrame()), next = try #require(try decoder.nextFrame())
        var settings = LowLatencyVideoSettings(); settings.noiseEnabled = true
        let output = try await LowLatencyVideoProcessor().process(.init(frame: first, next: nil,
            start: index.seconds(forFrame: first.number), end: index.seconds(forFrame: next.number), settings: settings, ratio: 1,
            noiseReferences: [.init(frame: next, seconds: index.seconds(forFrame: next.number))]))
        #expect(output.noiseApplied)
        #expect(output.dynamicRange == .hlg)
        #expect(CVPixelBufferGetPixelFormatType(output.current) == kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange)
        #expect(CVPixelBufferGetWidth(output.current) == 3840)
        let transfer = CVBufferCopyAttachment(output.current, kCVImageBufferTransferFunctionKey, nil) as? String
        #expect(transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    @Test(.enabled(if: VTTemporalNoiseFilterConfiguration.isSupported))
    func realNative4KOutputKeepsSizeAndOwnership() async throws {
        let make = LowLatencyVideoProcessorTests()
        let first = try make.frame(0, luma: 80, width: 3840, height: 2160)
        let second = try make.frame(1, luma: 84, width: 3840, height: 2160)
        var settings = LowLatencyVideoSettings(); settings.noiseEnabled = true
        let result = try await LowLatencyVideoProcessor().process(.init(frame: first, next: nil, start: 0, end: 1/30,
            settings: settings, ratio: 1, noiseReferences: [.init(frame: second, seconds: 1/30)]))
        #expect(result.noiseApplied)
        #expect(result.hasEffectImage)
        #expect(result.scaleFactor == nil)
        #expect(result.current !== first.pixelBuffer)
        #expect(CVPixelBufferGetWidth(result.current) == 3840)
        #expect(CVPixelBufferGetHeight(result.current) == 2160)
        #expect(result.status.contains("Temporal Noise"))
    }
}

private actor DeferredVideoLog {
    var values: [Int] = []
    func run(_ value: Int) -> Int { values.append(value); return value }
}
@Suite @MainActor struct TemporalNoiseSettleTests {
    @Test func waitsForTheLatestFrameAndInvalidationDropsDeferredWork() async throws {
        let log = DeferredVideoLog()
        let work = LatestVideoWork<Int, Int> { await log.run($0) }
        var delivered: [Int] = []
        work.onResult = { _, value in delivered.append(value) }
        // One actor turn: scheduler contention must not turn nominal20ms sleeps into22s waits.
        // Deferred callbacks cannot run until this turn yields; obsolete requests must never start.
        work.submit(1, after: 0.08)
        work.submit(2, after: 0.08)
        work.invalidate()
        work.submit(3, after: 0.04)
        for _ in 0..<100 { if delivered == [3] { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await log.values == [3])
        #expect(delivered == [3])
    }
    @Test func pausedModeKeepsOtherEffectsAndAlwaysModeEnablesNoiseDuringPlayback() {
        var settings = LowLatencyVideoSettings(); settings.noiseEnabled = true; settings.scale = .x2
        #expect(settings.forPlayback(playing: false).noiseActive)
        #expect(!settings.forPlayback(playing: true).noiseActive)
        #expect(settings.forPlayback(playing: true).scale == .x2)
        settings.noiseMode = .always
        #expect(settings.forPlayback(playing: true).noiseActive)
    }
}
