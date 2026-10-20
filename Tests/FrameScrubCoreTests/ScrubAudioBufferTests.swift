import Testing
@testable import FrameScrubCore

@Suite struct ScrubAudioBufferTests {
    private let rate = 48000.0

    /// Samples whose value is their absolute sample index, so a slice's values tell where it came from.
    private func ramp(fromSeconds start: Double, seconds: Double) -> StereoSamples {
        let first = Int((start * rate).rounded())
        let values = (0..<Int((seconds * rate).rounded())).map { Float(first + $0) }
        return StereoSamples(left: values, right: values)
    }

    private func samples(_ slice: AudioSlice) -> StereoSamples? {
        if case let .samples(s) = slice { return s }
        return nil
    }

    @Test func sliceInsideARun() throws {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        let s = try #require(samples(buffer.slice(fromSeconds: 0.5, length: 0.08)))
        #expect(s.left.count == 3840 && s.right.count == 3840)
        #expect(s.left.first == 24000 && s.left.last == 27839)
    }

    @Test func sliceNotDecodedYet() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        #expect(buffer.slice(fromSeconds: 0.95, length: 0.08) == .notReady)
        #expect(buffer.slice(fromSeconds: 2, length: 0.08) == .notReady)
    }

    @Test func gapInsideARunIsSilence() throws {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        buffer.append(ramp(fromSeconds: 1.5, seconds: 0.5), startSeconds: 1.5)
        #expect(buffer.slice(fromSeconds: 1.1, length: 0.08) == .silent)
        let s = try #require(samples(buffer.slice(fromSeconds: 0.97, length: 0.08)))
        #expect(s.left.first == 46560)
        #expect(s.left.suffix(2400).allSatisfy { $0 == 0 })   // 1.0…1.05 s
        #expect(s.left[1439] == 47999)
    }

    @Test func audioStartingLaterIsSilentBefore() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 2, seconds: 1), startSeconds: 2)
        #expect(buffer.slice(fromSeconds: 0.5, length: 0.08) == .silent)
    }

    @Test func endOfAudioCoversTheRest() throws {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        buffer.endOfAudio()
        let s = try #require(samples(buffer.slice(fromSeconds: 0.98, length: 0.08)))
        #expect(s.left.first == 47040)
        #expect(s.left.suffix(2880).allSatisfy { $0 == 0 })
        #expect(buffer.slice(fromSeconds: 3, length: 0.08) == .silent)
    }

    @Test func trimDropsOutsideTheWindow() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 12), startSeconds: 0)
        buffer.trim(around: 6)
        #expect(buffer.covered == [1..<11])
        #expect(buffer.slice(fromSeconds: 0.5, length: 0.08) == .notReady)
    }

    @Test func separateRunsMerge() throws {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        buffer.beginRun(atSeconds: 1)
        buffer.append(ramp(fromSeconds: 1, seconds: 1), startSeconds: 1)
        #expect(buffer.covered == [0..<2])
        let s = try #require(samples(buffer.slice(fromSeconds: 0.98, length: 0.08)))
        #expect(s.left == (47040..<(47040 + 3840)).map(Float.init))
    }

    @Test func resetForgetsEverything() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        buffer.reset()
        #expect(buffer.covered.isEmpty)
        #expect(buffer.slice(fromSeconds: 0.5, length: 0.08) == .notReady)
    }

    /// The filler's plan settles in a few runs for every frame time, also between samples (review: busy loop).
    @Test func nextRunSettlesForNTSCFrameTimes() {
        for rate in [44100.0, 48000.0] {
            for fps in [30000.0 / 1001, 24000.0 / 1001] {
                for n in 0..<600 {
                    let focus = Double(n) / fps
                    var buffer = ScrubAudioBuffer(sampleRate: rate)
                    var runs = 0
                    while let run = ScrubAudio.nextRun(in: buffer, focus: focus), runs < 5 {
                        runs += 1
                        if run.reset { buffer.reset() }
                        buffer.beginRun(atSeconds: run.from)
                        let first = buffer.sampleIndex(run.from), count = buffer.sampleIndex(run.to) - first
                        let zeros = [Float](repeating: 0, count: max(count, 0))
                        buffer.append(StereoSamples(left: zeros, right: zeros), startSeconds: run.from)
                        buffer.trim(around: focus)
                    }
                    #expect(runs < 5, "rate \(rate) fps \(fps) frame \(n)")
                    if runs >= 5 { return }
                }
            }
        }
    }

    @Test func snapshotFillsGapsWithSilence() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 0)
        buffer.append(ramp(fromSeconds: 0, seconds: 1), startSeconds: 0)
        buffer.append(ramp(fromSeconds: 1.5, seconds: 1.5), startSeconds: 1.5)
        let snapshot = buffer.snapshot(aroundSeconds: 1.25, radius: 0.5)    // 0.75…1.75 s
        #expect(snapshot.sample(atSeconds: 0.8).0 == 38400)
        #expect(snapshot.sample(atSeconds: 1.2) == (0, 0))
        #expect(snapshot.sample(atSeconds: 1.6).1 == 76800)
    }

    /// Where decoded sound meets silence the snapshot ramps over 3 ms, so the tape does not click (review).
    @Test func snapshotRampsAtDataEdges() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 1)
        let ones = [Float](repeating: 1, count: 48000)
        buffer.append(StereoSamples(left: ones, right: ones), startSeconds: 1)      // 1…2 s, nothing around it
        let snapshot = buffer.snapshot(aroundSeconds: 1.5, radius: 1)
        #expect(snapshot.sample(atSeconds: 1).0 < 0.05)
        #expect(snapshot.sample(atSeconds: 1 + 72 / rate).0 > 0.4 && snapshot.sample(atSeconds: 1 + 72 / rate).0 < 0.6)
        #expect(snapshot.sample(atSeconds: 1.5).0 == 1)
        #expect(snapshot.sample(atSeconds: 2 - 1 / rate).0 < 0.05)
    }

    @Test func interpolatesBetweenSamples() {
        let values: [Float] = (0..<100).map(Float.init)
        let snapshot = TapeSnapshot(startSeconds: 0, sampleRate: rate, samples: StereoSamples(left: values, right: values))
        #expect(snapshot.sample(atSeconds: 10.5 / rate) == (10.5, 10.5))
        #expect(snapshot.sample(atSeconds: 98 / rate) == (98, 98))
    }

    @Test func outsideTheSnapshotIsSilent() {
        let values: [Float] = Array(repeating: 1, count: 100)
        let snapshot = TapeSnapshot(startSeconds: 1, sampleRate: rate, samples: StereoSamples(left: values, right: values))
        #expect(snapshot.sample(atSeconds: 0.5) == (0, 0))
        #expect(snapshot.sample(atSeconds: 1 + 200 / rate) == (0, 0))
        #expect(snapshot.sample(atSeconds: .nan) == (0, 0))
        #expect(snapshot.sample(atSeconds: .infinity) == (0, 0))
        #expect(snapshot.sample(atSeconds: 1 + 50 / rate) == (1, 1))
    }

    @Test func notDecodedIsSilentInTheSnapshot() {
        var buffer = ScrubAudioBuffer(sampleRate: rate)
        buffer.beginRun(atSeconds: 2)
        buffer.append(ramp(fromSeconds: 2, seconds: 1), startSeconds: 2)
        let snapshot = buffer.snapshot(aroundSeconds: 2, radius: 1)          // 1…3 s, only 2…3 decoded
        #expect(snapshot.sample(atSeconds: 1.5) == (0, 0))
        #expect(snapshot.sample(atSeconds: 2.5).0 == 120000)
    }

    @Test func fadesStartAndEndAtZero() {
        func faded(_ seconds: Double) -> StereoSamples {
            let n = Int((seconds * rate).rounded())
            var s = StereoSamples(left: Array(repeating: 1, count: n), right: Array(repeating: 1, count: n))
            SnippetFades.apply(to: &s, sampleRate: rate, fade: 0.005)
            return s
        }
        let piece = faded(0.08)
        #expect(piece.left.first == 0 && piece.left.last == 0 && piece.right.first == 0 && piece.right.last == 0)
        #expect(piece.left[1920] == 1)
        #expect(piece.left[239] < 1 && piece.left[240] == 1)     // 5 ms = 240 samples
        let short = faded(0.012)                                    // a quarter of 12 ms = 3 ms = 144 samples
        #expect(short.left[143] < 1 && short.left[144] == 1)
        #expect(short.left.last == 0)
    }
}
