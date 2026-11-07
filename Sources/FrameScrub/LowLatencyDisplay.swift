import AppKit
import CoreImage
import FrameScrubCore

/// Display-only Apple effects. Native frames stay in PlayerCore/cache; this owns at most one
/// current result and one running + one replaceable pending request, never a second clock.
@MainActor final class LowLatencyDisplay {
    var onChange: (() -> Void)?
    private var processingStatus = "Apple LL: off"
    var noiseOnPause = false
    var status: String { noiseOnPause ? "Temporal Noise: on pause; " + processingStatus : processingStatus }
    private(set) var image: CIImage?
    var displayHeadroom = 1.0 {
        didSet {
            guard displayHeadroom != oldValue, let result, result.hasEffectImage else { return }
            image = oriented(selectedPhase.map { result.intermediates[$0] } ?? result.current)
            onChange?()
        }
    }
    var didUpscale: Bool { result?.scaleFactor != nil }
    private var settings = LowLatencyVideoSettings()
    private var epoch: UInt64 = 0
    private var identity: Identity?
    private var result: LowLatencyVideoProcessor.Output?
    private var start = 0.0, end = 0.0
    private var selectedPhase: Int?
    private var rotation = 0
    private var lastFrameNumber: Int?
    private var idleToken: UInt64 = 0
    private var refinementStarted = 0.0

    private struct Identity: Equatable {
        var source: ObjectIdentifier
        var next: ObjectIdentifier?
        var noiseReferences: [ObjectIdentifier]
        var settings: LowLatencyVideoSettings
        var ratio: Int
        var rotation: Int
        var start: Double
        var end: Double
    }
    private enum Work: @unchecked Sendable { case process(LowLatencyVideoProcessor.Request), reset }
    private struct Completion: @unchecked Sendable {
        var output: LowLatencyVideoProcessor.Output?
        var error: String?
        var milliseconds: Double = 0
    }
    private let work: LatestVideoWork<Work, Completion>

    init() {
        let processor = LowLatencyVideoProcessor()
        work = LatestVideoWork { value in
            switch value {
            case .reset: processor.reset(); return Completion()
            case let .process(request):
                let started = ContinuousClock.now
                do {
                    let output = try await processor.process(request)
                    let duration = started.duration(to: .now).components
                    return Completion(output: output, milliseconds: Double(duration.seconds)*1000 + Double(duration.attoseconds)/1e15)
                } catch { return Completion(error: String(describing: error)) }
            }
        }
        work.onResult = { [weak self] value, completion in
            guard let self, case .process = value else { return }
            if let output = completion.output {
                result = output; processingStatus = output.status
                if PlaybackDiagnostics.enabled {
                    PlaybackDiagnostics.shared.record("ll_work_ms", completion.milliseconds, group: output.status)
                    PlaybackDiagnostics.shared.record("ll_results", 1, group: output.status)
                    if output.hasEffectImage, refinementStarted > 0 {
                        PlaybackDiagnostics.shared.record("ll_refinement_ms", (CACurrentMediaTime() - refinementStarted)*1000, group: output.status)
                    }
                }
                selectedPhase = nil
                image = output.hasEffectImage ? oriented(output.current) : nil
            } else { result = nil; image = nil; processingStatus = "Apple LL failed: \(completion.error ?? "unknown error")" }
            onChange?()
            idleToken &+= 1
            let token = idleToken
            // One-shot release; no repeating timer while paused. Output buffers stay immutable/alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, idleToken == token else { return }
                work.submit(.reset)
            }
        }
    }

    func clear() {
        epoch &+= 1; idleToken &+= 1; identity = nil; lastFrameNumber = nil; result = nil; image = nil; selectedPhase = nil
        work.invalidate(); work.submit(.reset)
        processingStatus = settings.enabled ? "Apple LL: waiting" : "Apple LL: off"
        onChange?()
    }

    func request(frame: DecodedFrame, next: DecodedFrame?, start: Double, end: Double,
                 settings: LowLatencyVideoSettings, ratio: Double, rotation: Int, noiseReferences: [TemporalNoiseReference] = []) {
        if self.settings != settings { self.settings = settings; clear() }
        guard settings.enabled else { return }
        if let previous = lastFrameNumber, frame.number != previous, frame.number != previous + 1 { clear() }
        lastFrameNumber = frame.number
        let ratio = ratio.isFinite ? max(0, min(ratio, 64)) : 1
        let key = Identity(source: ObjectIdentifier(frame.pixelBuffer), next: next.map { ObjectIdentifier($0.pixelBuffer) },
                           noiseReferences: noiseReferences.map { ObjectIdentifier($0.frame.pixelBuffer) }, settings: settings, ratio: Int((ratio*100).rounded()), rotation: rotation, start: start, end: end)
        guard key != identity else { return }
        idleToken &+= 1
        if PlaybackDiagnostics.enabled,
           identity?.source != key.source || identity?.ratio != key.ratio || identity?.rotation != key.rotation
            || identity?.start != key.start || identity?.end != key.end {
            refinementStarted = CACurrentMediaTime()
        }
        identity = key; self.start = start; self.end = end; self.rotation = rotation
        result = nil; image = nil; selectedPhase = nil
        processingStatus = settings.noiseActive && settings.noiseMode == .paused ? "Temporal Noise: waiting for frame to settle" : "Apple LL: processing / original"
        work.submit(.process(.init(frame: frame, next: next, start: start, end: end,
                                   settings: settings, ratio: ratio, epoch: epoch, noiseReferences: noiseReferences)),
                    after: settings.noiseActive && settings.noiseMode == .paused ? 0.12 : 0)
    }

    func tick(at time: Double) {
        guard let result, result.hasEffectImage else { return }
        let phase = LLPresentation.phaseIndex(at: time, start: start, end: end, count: result.intermediates.count)
        guard phase != selectedPhase else { return }
        selectedPhase = phase
        image = oriented(phase.map { result.intermediates[$0] } ?? result.current)
        if PlaybackDiagnostics.enabled, phase != nil { PlaybackDiagnostics.shared.record("ll_intermediate_selected", 1, group: result.status) }
        onChange?()
    }

    private func oriented(_ buffer: CVPixelBuffer) -> CIImage {
        let range = result?.dynamicRange ?? .sdr
        let frame = DecodedFrame(number: 0, pts: 0, pixelBuffer: buffer, dynamicRange: range)
        return FrameImageRenderer.displayImage(for: frame, rotationClockwise: rotation,
                                              plan: ToneMapPlan.resolve(range: range, displayHeadroom: displayHeadroom))
    }
}
