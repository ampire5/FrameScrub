import AVFoundation
import Foundation
import Testing
@testable import FrameScrubCore

/// Records pieces instead of playing them; each piece "ends" 1 ms later.
final class RecordingSink: SnippetSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(samples: StereoSamples, sampleRate: Double)] = []

    var pieces: [(samples: StereoSamples, sampleRate: Double)] { lock.withLock { recorded } }

    func playSnippet(_ samples: StereoSamples, sampleRate: Double, ended: @escaping @Sendable () -> Void) {
        lock.withLock { recorded.append((samples, sampleRate)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.001) { ended() }
    }
}

/// Records pieces but never reports their end, like a node whose engine stopped.
final class SilentEndSink: SnippetSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var pieces: Int { lock.withLock { count } }
    func playSnippet(_ samples: StereoSamples, sampleRate: Double, ended: @escaping @Sendable () -> Void) {
        lock.withLock { count += 1 }
    }
}

/// Records what the tape is told.
final class RecordingTapeSink: TapeSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedControls: [TapeControl] = []
    private var recordedSnapshots: [TapeSnapshot] = []
    var controls: [TapeControl] { lock.withLock { recordedControls } }
    var snapshots: [TapeSnapshot] { lock.withLock { recordedSnapshots } }
    func setTapeSnapshot(_ snapshot: TapeSnapshot) { lock.withLock { recordedSnapshots.append(snapshot) } }
    func setTapeControl(_ control: TapeControl) { lock.withLock { recordedControls.append(control) } }
}

@Suite(.serialized) @MainActor struct ScrubAudioTests {
    private func makeWithTape(sink: RecordingSink, tape: RecordingTapeSink) throws -> ScrubAudio {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let scrub = ScrubAudio(decoder: decoder, sink: sink, tape: tape, shouldYield: { false })
        scrub.length = 0.08
        scrub.fileOpened()
        return scrub
    }

    @Test func quickFramesDriveTheTape() async throws {
        let sink = RecordingSink(), tape = RecordingTapeSink()
        let scrub = try makeWithTape(sink: sink, tape: tape)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 1.0)
        scrub.frameShown(seconds: 1.04)
        scrub.frameShown(seconds: 1.08)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.pieces.count <= 1)                    // only the first frame may be a piece
        let last = try #require(tape.controls.last)
        #expect(last.running && last.target == 1.08)
    }

    @Test func pitchTravelsInTheControl() async throws {
        let sink = RecordingSink(), tape = RecordingTapeSink()
        let scrub = try makeWithTape(sink: sink, tape: tape)
        defer { scrub.stop() }
        scrub.pitch = .natural
        scrub.userActed()
        scrub.frameShown(seconds: 1.0)
        scrub.frameShown(seconds: 1.04)
        #expect(tape.controls.last?.running == true && tape.controls.last?.pitch == .natural)
        scrub.pitch = .tape   // while the tape runs: sent at once
        #expect(tape.controls.last?.running == true && tape.controls.last?.pitch == .tape)
    }

    @Test func isolatedStepIsAPiece() async throws {
        let sink = RecordingSink(), tape = RecordingTapeSink()
        let scrub = try makeWithTape(sink: sink, tape: tape)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 1.0)
        #expect(await eventually { sink.pieces.count == 1 })
        try await Task.sleep(for: .milliseconds(400))      // longer than the tape's hold: a new single step
        scrub.frameShown(seconds: 1.04)
        #expect(await eventually { sink.pieces.count == 2 })
        #expect(!tape.controls.contains { $0.running })
    }

    @Test func playbackStopsTheTape() async throws {
        let sink = RecordingSink(), tape = RecordingTapeSink()
        let scrub = try makeWithTape(sink: sink, tape: tape)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 1.0)
        scrub.frameShown(seconds: 1.04)
        #expect(tape.controls.last?.running == true)
        scrub.playbackStarted()
        #expect(tape.controls.last?.running == false)
    }

    @Test func snapshotFollowsTheFrame() async throws {
        let sink = RecordingSink(), tape = RecordingTapeSink()
        let scrub = try makeWithTape(sink: sink, tape: tape)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 2.0)
        scrub.frameShown(seconds: 2.04)
        #expect(await eventually {
            tape.snapshots.contains { snapshot in
                (0..<48).map { abs(snapshot.sample(atSeconds: 2.04 + Double($0) / 48000).0) }.max()! > 0.01
                    && (0..<48).map { abs(snapshot.sample(atSeconds: 2.5 + Double($0) / 48000).0) }.max()! > 0.01
            }
        })
    }

    @Test func nextRunLooksAheadWhileTheTapeRuns() {
        var buffer = ScrubAudioBuffer(sampleRate: 48000)
        buffer.beginRun(atSeconds: 1.5)
        let zeros = [Float](repeating: 0, count: 48000)
        buffer.append(StereoSamples(left: zeros, right: zeros), startSeconds: 1.5)     // 1.5…2.5 s
        #expect(ScrubAudio.nextRun(in: buffer, focus: 2, ahead: 0) == nil)
        let forward = ScrubAudio.nextRun(in: buffer, focus: 2, ahead: 1)
        #expect(forward?.from == 2.5 && forward?.to == 3.5 && forward?.reset == false)
        let backward = ScrubAudio.nextRun(in: buffer, focus: 2, ahead: -1)
        #expect(backward?.from == 0.5 && backward?.to == 1.5 && backward?.reset == false)
    }

    private func make(_ fixture: String, sink: RecordingSink) throws -> ScrubAudio {
        let decoder = try AudioDecoder(url: Fixtures.url(fixture), zeroSeconds: 0)
        let scrub = ScrubAudio(decoder: decoder, sink: sink, shouldYield: { false })
        scrub.length = 0.08
        scrub.fileOpened()
        return scrub
    }

    /// `count` samples of the left channel from `seconds`, decoded by a fresh decoder.
    private func reference(_ fixture: String, from seconds: Double, count: Int) throws -> [Float] {
        let decoder = try AudioDecoder(url: Fixtures.url(fixture), zeroSeconds: 0)
        try decoder.seek(toSeconds: seconds)
        var out: [Float] = []
        while out.count < count, let chunk = try decoder.nextBuffer() {
            let buffer = chunk.buffer
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return Array(out.prefix(count))
    }

    @Test func stepPlaysThePieceFromTheFrame() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.withAudio, sink: sink)
        defer { scrub.stop() }
        scrub.frameShown(seconds: 1.0)          // opening frame: quiet, but the buffer fills around it
        scrub.userActed()
        scrub.frameShown(seconds: 1.04)
        #expect(await eventually { sink.pieces.count == 1 })
        let piece = try #require(sink.pieces.first)
        #expect(piece.sampleRate == 48000)
        #expect(piece.samples.count == 3840)
        let expected = try reference(Fixtures.withAudio, from: 1.04, count: 3840)
        let middle = 400..<3400                  // away from the fades
        let worst = middle.map { abs(piece.samples.left[$0] - expected[$0]) }.max() ?? 1
        #expect(worst < 1e-3)
    }

    @Test func noPieceWhilePlayingOrDisabledOrMuted() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.withAudio, sink: sink)
        defer { scrub.stop() }
        scrub.frameShown(seconds: 1.0)
        scrub.userActed()
        scrub.playbackStarted()
        scrub.frameShown(seconds: 1.2)
        scrub.userActed()
        scrub.playbackStopped()
        scrub.enabled = false
        scrub.userActed()
        scrub.frameShown(seconds: 1.24)
        scrub.enabled = true
        scrub.audible = false
        scrub.frameShown(seconds: 1.28)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.pieces.isEmpty)
        scrub.audible = true
        scrub.frameShown(seconds: 1.32)
        #expect(await eventually { sink.pieces.count == 1 })
    }

    @Test func framesBeforeTheAudioAreSilent() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.audioLate, sink: sink)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 0.5)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.pieces.isEmpty)
        scrub.frameShown(seconds: 2.5)
        #expect(await eventually { sink.pieces.count == 1 })
    }

    @Test func stopSilencesLateCallbacks() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.withAudio, sink: sink)
        scrub.userActed()
        scrub.frameShown(seconds: 3.5)
        scrub.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(sink.pieces.isEmpty)
    }

    /// 29.97 fps frame times fall between samples; the filler must still go idle (review: busy loop).
    @Test func fillerSettlesOnANTSCFrameTime() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.withAudio, sink: sink)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 31 * 1001 / 30000)
        try await Task.sleep(for: .milliseconds(1000))
        let settled = scrub.runsDecoded
        try await Task.sleep(for: .milliseconds(500))
        #expect(settled <= 4)
        #expect(scrub.runsDecoded == settled)
        #expect(sink.pieces.count == 1)
    }

    /// Only the core around the frame is decoded eagerly: the network is not read seconds beyond the picture (review).
    @Test func fillsOnlyAroundTheFrame() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.withAudio, sink: sink)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 2.0)
        #expect(await eventually { sink.pieces.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        let covered = scrub.coveredSeconds
        #expect(covered.count == 1)
        #expect((covered.first?.lowerBound ?? 0) >= 1.45 && (covered.first?.upperBound ?? 9) <= 2.6)
    }

    /// A piece whose end never arrives must not silence the rest of the file.
    @Test func aLostEndStillLetsTheNextFrameSound() async throws {
        let sink = SilentEndSink()
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let scrub = ScrubAudio(decoder: decoder, sink: sink, shouldYield: { false })
        defer { scrub.stop() }
        scrub.length = 0.08
        scrub.fileOpened()
        scrub.userActed()
        scrub.frameShown(seconds: 1.0)
        #expect(await eventually { sink.pieces == 1 })
        scrub.frameShown(seconds: 1.04)
        #expect(await eventually(timeout: 2) { sink.pieces == 2 })
    }

    @Test func farJumpRefillsTheWindow() async throws {
        let sink = RecordingSink()
        let scrub = try make(Fixtures.withAudio, sink: sink)
        defer { scrub.stop() }
        scrub.userActed()
        scrub.frameShown(seconds: 0.2)
        #expect(await eventually { sink.pieces.count == 1 })
        scrub.frameShown(seconds: 3.8)
        #expect(await eventually { sink.pieces.count == 2 })
        let expected = try reference(Fixtures.withAudio, from: 3.8, count: 3840)
        let worst = (400..<3400).map { abs(sink.pieces[1].samples.left[$0] - expected[$0]) }.max() ?? 1
        #expect(worst < 1e-3)
    }
}
