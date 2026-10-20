import Foundation
import QuartzCore

/// Where the tape gets its sound and its target (spec §6а): `AudioOutput` in the app, a recorder in tests.
public protocol TapeSink: AnyObject {
    /// Any thread.
    func setTapeSnapshot(_ snapshot: TapeSnapshot)
    /// Main thread.
    func setTapeControl(_ control: TapeControl)
}

/// Where scrub audio pieces go: `AudioOutput` in the app, a recorder in tests.
public protocol SnippetSink: AnyObject {
    /// Plays one piece at 1×; `ended` is called once when it has been heard (any thread).
    func playSnippet(_ samples: StereoSamples, sampleRate: Double, ended: @escaping @Sendable () -> Void)
}

/// A short piece of the file's sound on every frame change in pause (scrub audio spec §3.1). Its own decoder fills a
/// ±5 s buffer around the frame on screen on a background queue; `ScrubAudioPicker` decides which frame sounds.
/// Frames changing faster than every 0.15 s drive the tape instead (spec §6а).
/// Main-thread API. Call `stop()` before dropping it: the filler holds it until then.
public final class ScrubAudio: @unchecked Sendable {   // shared state under `lock`, the rest main-thread only
    /// `scrub-audio`.
    public var enabled = true { didSet { updateActive() } }
    /// Not muted and volume above 0: otherwise nothing is prepared (spec §2).
    public var audible = true { didSet { updateActive() } }
    /// Seconds, from `scrub-audio-length`.
    public var length = 0.08
    /// How the tape sounds (spec §6б); a change reaches a running tape at once.
    public var pitch = ScrubPitch.tape {
        didSet {
            guard let tape, var control = tapeControl, control.running, control.pitch != pitch else { return }
            control.pitch = pitch
            tapeControl = control
            tape.setTapeControl(control)
        }
    }

    private static let fade = 0.005
    private static let core = 0.5        // decoded first around the frame (spec §3.1)
    private static let idleWait = 0.5
    private static let lostEndMargin = 0.3
    private static let tapeAhead = 1.0       // decoded beyond the core in the direction of travel (spec §6а)
    private static let tapeRadius = 2.0      // the tape's snapshot around the frame
    private static let tapeLinger = 0.3      // the filler keeps looking ahead this long after the last quick frame

    private let sink: SnippetSink
    private let tape: TapeSink?
    private var lastShownAt: Double?          // main thread
    private var frameVelocity = FrameVelocity()
    private var tapeControl: TapeControl?     // main thread: the last one sent
    private let decoder: AudioDecoder    // filler queue only
    private let shouldYield: () -> Bool
    private let queue = DispatchQueue(label: "framescrub.scrub-audio", qos: .userInitiated)
    private let wakeUp = DispatchSemaphore(value: 0)
    private var picker = ScrubAudioPicker()   // main thread
    private var pieceID = 0                   // main thread: the piece whose end is awaited

    // Shared with the filler, under `lock`.
    private let lock = NSLock()
    private var buffer: ScrubAudioBuffer
    private var focus: Double?
    private var playing = false
    private var active = true
    private var stopped = false
    private var generation = 0
    private var runs = 0
    private var ahead = 0.0                   // seconds beyond the core the filler decodes (tape running)
    private var aheadUntil = 0.0              // host seconds
    /// Decode runs so far (tests: the filler must go idle once the window is full).
    var runsDecoded: Int { lock.withLock { runs } }
    /// What the buffer holds (tests).
    var coveredSeconds: [Range<Double>] { lock.withLock { buffer.covered } }

    public init(decoder: AudioDecoder, sink: SnippetSink, tape: TapeSink? = nil, shouldYield: @escaping () -> Bool) {
        self.decoder = decoder
        self.sink = sink
        self.tape = tape
        self.shouldYield = shouldYield
        buffer = ScrubAudioBuffer(sampleRate: decoder.sampleRate)
        queue.async { [self] in fill() }
    }

    // MARK: Events (main thread)

    public func fileOpened() { feed(.fileOpened) }
    public func userActed() { feed(.userActed) }

    public func playbackStarted() {
        lock.withLock { playing = true }
        stopTape()
        feed(.playbackStarted)
    }

    public func playbackStopped() {
        lock.withLock { playing = false }
        wakeUp.signal()
        feed(.playbackStopped)
    }

    public func frameShown(seconds: Double) {
        let now = CACurrentMediaTime()
        let quick = lastShownAt.map { now - $0 < TapeMotion.activeFor } ?? false
        lastShownAt = now
        let velocity = frameVelocity.shown(seconds, at: now)
        let toTape = tape != nil && quick && enabled && audible && picker.canSound
        lock.withLock {
            focus = seconds
            if toTape {
                ahead = velocity < 0 ? -Self.tapeAhead : Self.tapeAhead
                aheadUntil = now + Self.tapeLinger
            }
        }
        wakeUp.signal()
        guard enabled && audible else { return }
        if toTape, let tape {
            let control = TapeControl(target: seconds, shownAt: now, frameVelocity: velocity, running: true, pitch: pitch)
            tapeControl = control
            tape.setTapeControl(control)
            feed(.heardOnTape(seconds))
        } else {
            feed(.frameShown(seconds))
        }
    }

    /// Fades the tape out within 5 ms (playback started, scrub audio off, closing).
    private func stopTape() {
        guard let tape, var control = tapeControl, control.running else { return }
        control.running = false
        tapeControl = control
        tape.setTapeControl(control)
    }

    /// Ends decoding; pieces and callbacks still in flight are ignored.
    public func stop() {
        stopTape()
        lock.withLock {
            stopped = true
            generation += 1
        }
        wakeUp.signal()
    }

    private func updateActive() {
        let now = enabled && audible
        lock.withLock { active = now }
        if now { wakeUp.signal() } else { stopTape() }
    }

    private func feed(_ event: ScrubAudioPicker.Event) {
        guard !lock.withLock({ stopped }) else { return }
        let length = self.length
        let seconds = picker.handle(event) { at in
            lock.withLock { buffer.slice(fromSeconds: at, length: length) } != .notReady
        }
        if let seconds { play(seconds) }
    }

    private func play(_ seconds: Double) {
        let (slice, current) = lock.withLock { (buffer.slice(fromSeconds: seconds, length: length), generation) }
        guard case var .samples(samples) = slice else {
            feed(.snippetEnded)     // silent (or trimmed meanwhile): nothing to hear, the next frame may sound
            return
        }
        SnippetFades.apply(to: &samples, sampleRate: decoder.sampleRate, fade: Self.fade)
        pieceID += 1
        let piece = pieceID
        // The first of the sink's end and a fallback a little after the piece's length ends it: a lost callback
        // (an engine stopped by a device change) must not silence the rest of the file (review).
        let end = { [weak self] in
            guard let self, self.pieceID == piece, self.lock.withLock({ self.generation == current }) else { return }
            self.pieceID += 1
            self.feed(.snippetEnded)
        }
        sink.playSnippet(samples, sampleRate: decoder.sampleRate) { DispatchQueue.main.async(execute: end) }
        DispatchQueue.main.asyncAfter(deadline: .now() + length + Self.lostEndMargin, execute: end)
    }

    // MARK: Filler (private queue)

    /// The next stretch to decode around `focus`, or nil when it is covered: ±0.5 s around the frame (a reset when
    /// the frame itself is not covered). Planned in whole samples, as the buffer rounds its bounds. Only this core is
    /// decoded eagerly — stepping extends it as the frame moves, and the window only limits what is kept — so a jump
    /// reads about a second of the file, not ten (review: network cost).
    /// `ahead` (seconds, signed) extends the core in the direction of travel while the tape runs (spec §6а).
    static func nextRun(in buffer: ScrubAudioBuffer, focus: Double, ahead: Double = 0)
        -> (from: Double, to: Double, reset: Bool)? {
        let at = buffer.sampleIndex(focus), core = buffer.sampleIndex(Self.core)
        let extra = buffer.sampleIndex(abs(ahead))
        let low = max(0, at - core - (ahead < 0 ? extra : 0)), high = at + core + (ahead > 0 ? extra : 0)
        func seconds(_ index: Int) -> Double { Double(index) / buffer.sampleRate }
        guard let around = buffer.coveredIndices.first(where: { $0.contains(at) }) else {
            return (seconds(low), seconds(high), true)
        }
        if around.upperBound < high { return (seconds(around.upperBound), seconds(high), false) }
        if around.lowerBound > low { return (seconds(low), seconds(around.lowerBound), false) }
        return nil
    }

    private func fill() {
        var failedAt: Double?
        var stalledAt: Double?   // a run that added nothing: idle until the frame moves, never spin
        var publishedAround: Double?
        while true {
            let (isStopped, focus, idle, buffer, aheadNow) = lock.withLock {
                (stopped, self.focus, playing || !active, self.buffer, CACurrentMediaTime() < aheadUntil ? ahead : 0)
            }
            if isStopped { return }
            guard let focus, !idle else {
                _ = wakeUp.wait(timeout: .now() + Self.idleWait)
                continue
            }
            if let failed = failedAt, abs(focus - failed) <= buffer.window {
                _ = wakeUp.wait(timeout: .now() + Self.idleWait)
                continue
            }
            failedAt = nil
            if let stalled = stalledAt, stalled == focus {
                _ = wakeUp.wait(timeout: .now() + Self.idleWait)
                continue
            }
            stalledAt = nil
            if shouldYield() {
                Thread.sleep(forTimeInterval: 0.02)   // the picture waits for a seek: leave it the network
                continue
            }
            if aheadNow != 0, publishedAround.map({ abs($0 - focus) > 0.25 }) ?? true {
                publishSnapshot(around: focus)
                publishedAround = focus
            }
            guard let run = Self.nextRun(in: buffer, focus: focus, ahead: aheadNow) else {
                _ = wakeUp.wait(timeout: .now() + (aheadNow != 0 ? 0.02 : Self.idleWait))
                continue
            }
            do {
                try decode(from: run.from, to: run.to, reset: run.reset, focus: focus)
            } catch {
                print("Scrub audio: \(error)")
                failedAt = focus
            }
            let current = lock.withLock {
                self.buffer.trim(around: self.focus ?? focus)
                if self.buffer.coveredIndices == buffer.coveredIndices { stalledAt = focus }
                return generation
            }
            if aheadNow != 0 {
                publishSnapshot(around: lock.withLock { self.focus } ?? focus)   // new sound ahead of the tape
                publishedAround = focus
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.generation == current }) else { return }
                self.feed(.audioReady)
            }
        }
    }

    private func publishSnapshot(around seconds: Double) {
        guard let tape else { return }
        let snapshot = lock.withLock { buffer.snapshot(aroundSeconds: seconds, radius: Self.tapeRadius) }
        tape.setTapeSnapshot(snapshot)
    }

    private func decode(from: Double, to: Double, reset: Bool, focus: Double) throws {
        lock.withLock { runs += 1 }
        try decoder.seek(toSeconds: from)
        lock.withLock {
            if reset { buffer.reset() }
            buffer.beginRun(atSeconds: from)
        }
        while true {
            let next = try autoreleasepool { try decoder.nextBuffer() }
            guard let chunk = next else {
                lock.withLock { buffer.endOfAudio() }
                return
            }
            let pcm = chunk.buffer
            let count = Int(pcm.frameLength)
            let samples = StereoSamples(left: Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: count)),
                                        right: Array(UnsafeBufferPointer(start: pcm.floatChannelData![1], count: count)))
            let (moved, isStopped) = lock.withLock { () -> (Bool, Bool) in
                buffer.append(samples, startSeconds: chunk.startSeconds)
                // A jump out of the window while decoding: stop here and plan around the new frame.
                return (abs((self.focus ?? focus) - focus) > buffer.window, stopped)
            }
            if isStopped || moved || chunk.startSeconds + Double(count) / decoder.sampleRate >= to { return }
        }
    }
}
