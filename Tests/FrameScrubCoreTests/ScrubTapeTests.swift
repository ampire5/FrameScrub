import AVFoundation
import QuartzCore
import Testing
@testable import FrameScrubCore

@Suite struct ScrubTapeTests {
    /// Renders `seconds` of the tape offline and returns the left channel.
    private func render(_ tape: ScrubTape, format: AVAudioFormat, seconds: Double) throws -> [Float] {
        let engine = AVAudioEngine()
        engine.attach(tape.node)
        engine.connect(tape.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        var out: [Float] = []
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        while Double(out.count) < seconds * format.sampleRate {
            _ = try engine.renderOffline(1024, to: buffer)
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return out
    }

    /// A new snapshot arriving while the tape plays (silence before, sound now) crossfades instead of clicking.
    @Test func aNewSnapshotCrossfades() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let tape = ScrubTape(format: format)
        let silence = [Float](repeating: 0, count: 96000)
        tape.setTapeSnapshot(TapeSnapshot(startSeconds: 0, sampleRate: 48000, samples: StereoSamples(left: silence, right: silence)))
        tape.setTapeControl(TapeControl(target: 1, shownAt: CACurrentMediaTime(), frameVelocity: 1, running: true))
        let engine = AVAudioEngine()
        engine.attach(tape.node)
        engine.connect(tape.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var out: [Float] = []
        func render(_ blocks: Int) throws {
            for _ in 0..<blocks {
                _ = try engine.renderOffline(512, to: buffer)
                out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
        }
        try render(4)
        let tone = (0..<96000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.5 }
        tape.setTapeSnapshot(TapeSnapshot(startSeconds: 0, sampleRate: 48000, samples: StereoSamples(left: tone, right: tone)))
        try render(4)
        let steps = zip(out.dropFirst(), out).map { abs($0 - $1) }
        #expect((steps.max() ?? 1) < 0.05)
        #expect((out.suffix(500).map(abs).max() ?? 0) > 0.2)
    }

    @Test func rendersTheSnapshotAndFallsSilentWhenStopped() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let tape = ScrubTape(format: format)
        let tone = (0..<96000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.5 }
        tape.setTapeSnapshot(TapeSnapshot(startSeconds: 0, sampleRate: 48000, samples: StereoSamples(left: tone, right: tone)))
        tape.setTapeControl(TapeControl(target: 1, shownAt: CACurrentMediaTime(), frameVelocity: 1, running: true))
        let playing = try render(tape, format: format, seconds: 0.05)
        #expect((playing.suffix(1000).map(abs).max() ?? 0) > 0.2)
        tape.setTapeControl(TapeControl(target: 1, shownAt: CACurrentMediaTime(), frameVelocity: 1, running: false))
        let stopped = try render(tape, format: format, seconds: 0.05)
        #expect((stopped.suffix(1000).map(abs).max() ?? 1) == 0)
    }

    // MARK: Natural pitch (spec §6б)

    /// One offline engine around a tape; `render` follows a frame moving `speed`× real time, refreshing the control
    /// every block like quick frames would.
    private final class Rig {
        let tape: ScrubTape
        let engine = AVAudioEngine()
        let buffer: AVAudioPCMBuffer
        var target = 0.5

        init(pitch: ScrubPitch) throws {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
            tape = ScrubTape(format: format)
            let tone = (0..<96000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.5 }
            tape.setTapeSnapshot(TapeSnapshot(startSeconds: 0, sampleRate: 48000, samples: StereoSamples(left: tone, right: tone)))
            engine.attach(tape.node)
            engine.connect(tape.node, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
            buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        }

        func render(seconds: Double, speed: Double, pitch: ScrubPitch) throws -> [Float] {
            var out: [Float] = []
            while Double(out.count) < seconds * 48000 {
                tape.setTapeControl(TapeControl(target: target, shownAt: CACurrentMediaTime(), frameVelocity: speed,
                                                running: true, pitch: pitch))
                _ = try engine.renderOffline(512, to: buffer)
                out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                target += speed * 512 / 48000
            }
            return out
        }

        deinit { engine.stop() }
    }

    private static func pitch(_ samples: [Float]) -> Double {
        let part = Array(samples.dropFirst(2400))
        let crossings = zip(part, part.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        return Double(crossings) / 2 / (Double(part.count) / 48000)
    }

    @Test(arguments: [ScrubPitch.tape, .natural]) func naturalModeKeepsThePitch(pitch: ScrubPitch) throws {
        let rig = try Rig(pitch: pitch)
        let out = try rig.render(seconds: 0.25, speed: 2, pitch: pitch)
        let heard = Self.pitch(out)
        if pitch == .natural { #expect(abs(heard - 440) < 20, "\(heard) Hz") } else { #expect(abs(heard - 880) < 30, "\(heard) Hz") }
    }

    @Test func switchingModeWhilePlayingDoesNotClick() throws {
        let rig = try Rig(pitch: .tape)
        var out = try rig.render(seconds: 0.1, speed: 2, pitch: .tape)
        out += try rig.render(seconds: 0.1, speed: 2, pitch: .natural)
        out += try rig.render(seconds: 0.1, speed: 2, pitch: .tape)
        let steps = zip(out.dropFirst(), out).map { abs($0 - $1) }
        #expect((steps.max() ?? 1) < 0.1)
        #expect((out.suffix(1000).map(abs).max() ?? 0) > 0.2)
    }
}
