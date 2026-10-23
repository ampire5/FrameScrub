import AVFoundation
import QuartzCore
import Testing
@testable import FrameScrubCore

@Suite struct AudioTests {
    @Test func clockFollowsHostTimeAndRate() {
        var now = 100.0
        let clock = PlaybackClock(now: { now })
        clock.start(at: 10)
        now += 2
        #expect(clock.seconds == 12)
        clock.rate = 2
        now += 1
        #expect(clock.seconds == 14)
        clock.stop()
        now += 5
        #expect(clock.seconds == 14)
        #expect(!clock.isRunning)
    }

    @Test func clockPrefersAudioTimeWhileRunning() {
        let clock = PlaybackClock(now: { 0 })
        clock.audioSeconds = { 42 }
        #expect(clock.seconds == 0)
        clock.start(at: 1)
        #expect(clock.seconds == 42)
    }

    @Test func decodesWholeTrack() throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        #expect(decoder.sampleRate == 48_000)
        #expect(decoder.format.channelCount == 2)
        var total = 0
        while let chunk = try decoder.nextBuffer() { total += Int(chunk.buffer.frameLength) }
        #expect(abs(total - 4 * 48_000) < 4096)
    }

    @Test func seekTrimsToRequestedTime() throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        try decoder.seek(toSeconds: 2)
        let first = try #require(try decoder.nextBuffer())
        #expect(abs(first.startSeconds - 2) < 0.001)
        var total = Int(first.buffer.frameLength)
        while let chunk = try decoder.nextBuffer() { total += Int(chunk.buffer.frameLength) }
        #expect(abs(total - 2 * 48_000) < 4096)
    }

    /// Frames whose channel count changes mid-stream (joined recordings) go through a resampler set up for them, not
    /// the one built for the first layout: that one read a missing channel plane and crashed (2026-10-19).
    @Test func decodesAcrossLayoutChange() throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.layoutChange), zeroSeconds: 0)
        var total = 0
        while let chunk = try decoder.nextBuffer() { total += Int(chunk.buffer.frameLength) }
        #expect(abs(total - 4 * 48_000) < 4096)
        try decoder.seek(toSeconds: 3)
        let after = try #require(try decoder.nextBuffer())
        #expect(abs(after.startSeconds - 3) < 0.05)
    }

    @Test func failsWithoutAudio() {
        #expect(throws: FFmpegError.self) {
            try AudioDecoder(url: Fixtures.url(Fixtures.h264), zeroSeconds: 0)
        }
    }

    /// Audio that starts later than requested (here: before the start of the track) must not
    /// run early: the reported time follows the first chunk actually scheduled.
    @Test func outputTimeStartsAtFirstScheduledChunk() async throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let output: AudioOutput
        do { output = try AudioOutput(decoder: decoder) } catch { return }   // no audio engine here: skip
        output.volume = 0
        defer { output.stop() }
        let started = CACurrentMediaTime()
        output.play(fromSeconds: -1)
        #expect(await eventually(timeout: 3) { output.currentSeconds != nil })
        let heard = try #require(output.currentSeconds)
        let elapsed = CACurrentMediaTime() - started
        // Running early (the bug) would report about -1 s. The upper bound is the wall time
        // since play(), so a slow, loaded test run cannot fail it.
        #expect(heard >= -0.05 && heard <= elapsed + 0.05, "heard \(heard) s after \(elapsed) s")
    }

    /// An output device change (Bluetooth headphones switching profile, another device chosen) stops the engine;
    /// the output starts it again and asks for playback to be scheduled anew, so the sound comes back.
    @Test func outputRestartsAfterDeviceChange() async throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let output: AudioOutput
        do { output = try AudioOutput(decoder: decoder) } catch { return }   // no audio engine here: skip
        output.volume = 0
        defer { output.stop() }
        output.onRestart = { output.play(fromSeconds: 1) }   // PlayerCore: playback restarts from the frame on screen
        output.play(fromSeconds: 0)
        #expect(await eventually(timeout: 3) { output.currentSeconds != nil })
        output.simulateDeviceChange()
        #expect(await eventually(timeout: 3) { (output.currentSeconds ?? 0) >= 1 })
        #expect(output.isEngineRunning)
    }

    @Test func outputPlayStartsAStoppedEngine() async throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let output: AudioOutput
        do { output = try AudioOutput(decoder: decoder) } catch { return }   // no audio engine here: skip
        output.volume = 0
        defer { output.stop() }
        output.simulateDeviceChange(notify: false)   // a change whose notification restarted nothing
        output.play(fromSeconds: 0)
        #expect(await eventually(timeout: 3) { output.currentSeconds != nil })
    }

    @Test func outputSurvivesRapidPlayPause() throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let output: AudioOutput
        do { output = try AudioOutput(decoder: decoder) } catch { return }   // no audio engine here: skip
        output.volume = 0
        var sawTime = false
        for i in 0..<20 {
            output.play(fromSeconds: Double(i % 3) * 0.5)
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.01)
                if output.currentSeconds != nil { sawTime = true }
            }
            output.pause()
            Thread.sleep(forTimeInterval: 0.02)
        }
        output.stop()
        #expect(sawTime)
    }

    /// The main thread never waits for the engine: while a call into AVFAudio hangs (an output that stalls), play,
    /// pause, the rate, the volume, a scrub piece and the time heard all return at once.
    @Test func mainThreadCallsNeverWaitForTheEngine() throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let output: AudioOutput
        do { output = try AudioOutput(decoder: decoder) } catch { return }   // no audio engine here: skip
        output.volume = 0
        defer { output.stop() }
        output.occupyEngineQueue(seconds: 1)
        let started = CACurrentMediaTime()
        output.play(fromSeconds: 1)
        output.rate = 1.5
        output.volume = 0
        _ = output.currentSeconds
        _ = output.isStarting
        output.playSnippet(StereoSamples(left: [Float](repeating: 0, count: 480), right: [Float](repeating: 0, count: 480)),
                           sampleRate: 48_000) {}
        output.pause()
        output.play(fromSeconds: 2)
        #expect(CACurrentMediaTime() - started < 0.1)
    }

    /// AVFAudio raising inside a call (Swift cannot catch it; it ended the app) is caught: the engine is rebuilt, the
    /// player is asked to start again, and the sound comes back.
    @Test func aRaiseInsideTheEngineIsCaughtAndTheSoundComesBack() async throws {
        let decoder = try AudioDecoder(url: Fixtures.url(Fixtures.withAudio), zeroSeconds: 0)
        let output: AudioOutput
        do { output = try AudioOutput(decoder: decoder) } catch { return }   // no audio engine here: skip
        output.volume = 0
        defer { output.stop() }
        nonisolated(unsafe) var restarts = 0
        output.onRestart = { restarts += 1; output.play(fromSeconds: 1) }
        output.play(fromSeconds: 0)
        #expect(await eventually(timeout: 3) { output.currentSeconds != nil })
        output.simulateRaise()
        #expect(await eventually(timeout: 3) { restarts == 1 })
        #expect(await eventually(timeout: 3) { (output.currentSeconds ?? 0) >= 1 })
        #expect(output.isEngineRunning)
    }
}
