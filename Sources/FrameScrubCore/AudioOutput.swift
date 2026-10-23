import AVFoundation
import ObjCCatch
import os
import QuartzCore

/// Plays an AudioDecoder through AVAudioEngine (player → time-pitch → mixer) and reports the
/// media time actually being heard. A second player node plays scrub audio pieces straight into the mixer: same
/// volume, always 1×.
///
/// Threads: every call into the engine and its nodes runs on one serial queue (`engineQueue`); decoding runs on
/// another (`feedQueue`). The main thread never calls into AVFAudio and never waits for either queue: its requests
/// (play, pause, stop, rate, volume, a scrub piece) are queued with a generation number, and what it reads every
/// display refresh (the time heard, whether the sound is starting) comes from a small state the engine queue keeps
/// up to date. A call that blocks inside AVFAudio (an output that stalls) then holds up the sound, not the app.
/// AVFAudio reports misuse by raising Objective-C exceptions, which Swift cannot catch: the engine calls go through
/// `FSCatchException`, and a raise is logged with its reason and the engine rebuilt instead of the app ending.
public final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let snippetPlayer = AVAudioPlayerNode()
    private let tape: ScrubTape
    private let decoder: AudioDecoder
    private let format: AVAudioFormat
    private let feedQueue = DispatchQueue(label: "framescrub.audio", qos: .userInteractive)
    private let engineQueue = DispatchQueue(label: "framescrub.audio-engine", qos: .userInteractive)

    /// What the main thread reads and the queues update. Plain values only: the lock is never held across a call
    /// into AVFAudio.
    private struct State {
        var generation = 0
        /// The playback sound was asked for and is not heard yet.
        var starting = false
        /// Media seconds of the first sample of the current playback.
        var startSeconds = 0.0
        /// The latest sample of the player's time (media seconds since `startSeconds`) and the host time it was
        /// rendered at; nil until the sound is heard.
        var heardSeconds: Double?
        var heardAtHost = 0.0
        var rate: Float = 1
        var volume: Float = 1
        var stopped = false
        /// Engine rebuilds after a raise, for giving up when they keep failing.
        var rebuilds: [Double] = []
        var broken = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Engine queue only: samples the player's time while it plays.
    private var sampler: DispatchSourceTimer?
    /// Engine queue only: the generation whose sound the player plays.
    private var playingGeneration = -1

    /// Main thread, after the engine was started again (a device change stopped it, or it was rebuilt after a raise):
    /// the playback's queued sound is gone, so playback that was running must be started again (PlayerCore: from the
    /// frame on screen).
    public var onRestart: (() -> Void)?
    private var deviceObserver: NSObjectProtocol?
    private static let logger = Logger(subsystem: "local.framescrub", category: "Audio")
    /// How far the time heard is carried forward on the host clock past its latest sample (taken every 10 ms); beyond
    /// that the clock waits for the sound, which has stalled.
    private static let carryLimit = 0.1

    public init(decoder: AudioDecoder) throws {
        self.decoder = decoder
        format = decoder.format
        tape = ScrubTape(format: decoder.format)
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(snippetPlayer)
        engine.attach(tape.node)
        connectNodes()
        engine.prepare()
        try engine.start()
        snippetPlayer.play()
        // A change of the output's sample rate or channels (Bluetooth headphones switching profile, another
        // device chosen) stops the engine for good; nothing plays until it is started again.
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            engineQueue.async {
                Self.logger.notice("Audio: configuration change, engine running \(self.engine.isRunning), output \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
                guard self.restartEngine() else { return }
                DispatchQueue.main.async { self.onRestart?() }
            }
        }
    }

    deinit {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
    }

    private func connectNodes() {
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.connect(snippetPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(tape.node, to: engine.mainMixerNode, format: format)
    }

    /// Playback rates AVAudioUnitTimePitch supports.
    public static let rateRange: ClosedRange<Double> = (1.0 / 32)...32

    public var rate: Float {
        get { state.withLock { $0.rate } }
        set {
            let value = min(max(newValue, Float(Self.rateRange.lowerBound)), Float(Self.rateRange.upperBound))
            state.withLock { s in
                // The time heard so far stays; from here on it runs at the new rate.
                if let heard = s.heardSeconds {
                    let now = CACurrentMediaTime()
                    s.heardSeconds = heard + min(max(now - s.heardAtHost, 0), Self.carryLimit) * Double(s.rate)
                    s.heardAtHost = now
                }
                s.rate = value
            }
            engineQueue.async { [self] in timePitch.rate = value }
        }
    }

    public var volume: Float {
        get { state.withLock { $0.volume } }
        set {
            state.withLock { $0.volume = newValue }
            engineQueue.async { [self] in engine.mainMixerNode.outputVolume = newValue }
        }
    }

    /// Seconds on the video timeline being heard now; nil while stopped or still starting (right after the player
    /// starts its time is negative until the first sample reaches the output). Carried forward from the latest
    /// sample of the player's time.
    public var currentSeconds: Double? {
        let s = state.withLock { $0 }
        guard let heard = s.heardSeconds else { return nil }
        let carried = min(max(CACurrentMediaTime() - s.heardAtHost, 0), Self.carryLimit) * Double(s.rate)
        return s.startSeconds + heard + carried
    }

    /// Asked to play and not heard yet: the feed is still seeking and decoding its first piece, or the output has
    /// not reached it. False once the sound is heard, and when the feed gave up (no sound there, a failure) or
    /// playback was paused.
    public var isStarting: Bool { state.withLock { $0.starting } }

    /// Tests: how often playback sound was (re)started.
    private(set) var playCalls = 0
    /// Starts of the playback sound in the last second, for noticing a loop that keeps starting it (a buzz).
    private var recentPlays: [Double] = []

    /// Main thread; returns at once.
    public func play(fromSeconds seconds: Double) {
        playCalls += 1
        noteStart()
        let g = state.withLock { s -> Int? in
            guard !s.stopped, !s.broken else { return nil }
            s.generation += 1
            s.starting = true
            s.startSeconds = seconds
            s.heardSeconds = nil
            return s.generation
        }
        guard let g else { return }
        engineQueue.async { [self] in
            _ = restartEngine()   // a device change whose restart failed: try again when asked to play
            stopPlayer()
        }
        feedQueue.async { [self] in feed(from: seconds, generation: g) }
    }

    /// Main thread; returns at once.
    public func pause() {
        state.withLock { s in
            s.generation += 1
            s.starting = false
            s.heardSeconds = nil
        }
        engineQueue.async { [self] in stopPlayer() }
    }

    /// Main thread; returns at once. The engine stops on its own queue.
    public func stop() {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        deviceObserver = nil
        pause()
        state.withLock { $0.stopped = true }
        engineQueue.async { [self] in _ = FSCatchException { engine.stop() } }
    }

    private func noteStart() {
        let now = CACurrentMediaTime()
        recentPlays.append(now)
        recentPlays.removeAll { $0 < now - 1 }
        if recentPlays.count == 8 { Self.logger.notice("Audio: playback sound started 8 times within a second") }
    }

    // MARK: Engine queue

    private func stopPlayer() {
        sampler?.cancel()
        sampler = nil
        playingGeneration = -1
        _ = engineCall("stop") { player.stop() }
    }

    /// Starts the engine again if it is stopped (a device change); true when it was stopped and runs now.
    private func restartEngine() -> Bool {
        guard !state.withLock({ $0.stopped || $0.broken }), !engine.isRunning else { return false }
        do {
            try engine.start()
        } catch {
            Self.logger.error("Audio: restart after a device change failed: \(error, privacy: .public)")   // the next change or play() tries again
            return false
        }
        _ = engineCall("snippet play") { snippetPlayer.play() }
        return true
    }

    /// Runs a call into AVFAudio, catching what it raises: the exception is logged and the engine rebuilt (playback
    /// then starts again from the frame on screen through `onRestart`). False when it raised.
    private func engineCall(_ what: StaticString, _ call: () -> Void) -> Bool {
        guard let exception = FSCatchException(call) else { return true }
        Self.logger.error("Audio: \(what, privacy: .public) raised \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public); engine running \(self.engine.isRunning)")
        rebuildEngine()
        return false
    }

    /// After a raise: the engine is taken down and wired again. Given up (no more playback sound for this file; the
    /// clock then runs on the host time) when it keeps raising: more than three rebuilds within half a minute.
    private func rebuildEngine() {
        let now = CACurrentMediaTime()
        let giveUp = state.withLock { s -> Bool in
            s.rebuilds = s.rebuilds.filter { $0 > now - 30 } + [now]
            s.heardSeconds = nil
            s.starting = false
            s.generation += 1   // the feed running now ends
            if s.rebuilds.count > 3 { s.broken = true }
            return s.broken
        }
        sampler?.cancel()
        sampler = nil
        playingGeneration = -1
        _ = FSCatchException { player.stop() }   // its scheduled pieces end (their completions free the feed's slots)
        _ = FSCatchException { engine.stop() }
        if giveUp {
            Self.logger.error("Audio: the engine keeps failing; no playback sound for this file")
            return
        }
        if let raised = FSCatchException({
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.disconnectNodeOutput(snippetPlayer)
            engine.disconnectNodeOutput(tape.node)
            connectNodes()
            engine.prepare()
        }) {
            Self.logger.error("Audio: rewiring raised \(raised.name.rawValue, privacy: .public): \(raised.reason ?? "no reason", privacy: .public)")
        }
        do {
            try engine.start()
        } catch {
            Self.logger.error("Audio: starting the rebuilt engine failed: \(error, privacy: .public)")
            return
        }
        _ = FSCatchException { snippetPlayer.play() }
        Self.logger.notice("Audio: engine rebuilt")
        DispatchQueue.main.async { [weak self] in self?.onRestart?() }
    }

    /// Schedules a decoded piece of generation `g` and starts the player with the first one; false when it was not
    /// scheduled.
    private func schedule(_ buffer: AVAudioPCMBuffer, startSeconds: Double, generation g: Int,
                          played: @escaping @Sendable () -> Void) -> Bool {
        guard state.withLock({ $0.generation == g }) else { return false }
        let first = playingGeneration != g
        if first {
            if !engine.isRunning { _ = restartEngine() }
            guard engine.isRunning else {
                Self.logger.error("Audio: the engine is not running; playback sound not started")
                state.withLock { if $0.generation == g { $0.starting = false } }
                return false
            }
        }
        guard engineCall("scheduleBuffer", { player.scheduleBuffer(buffer, completionHandler: played) }) else { return false }
        guard first else { return true }
        guard engineCall("play", { player.play() }) else { return true }   // scheduled: the rebuild's stop frees it
        playingGeneration = g
        // Timed from the first piece: audio that begins later than requested (e.g. a late-starting track) must not
        // run early.
        state.withLock { s in if s.generation == g { s.startSeconds = startSeconds } }
        startSampler(generation: g)
        return true
    }

    /// Every 10 ms while the player plays, its time for the main thread (`currentSeconds`).
    private func startSampler(generation g: Int) {
        sampler?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample(generation: g) }
        sampler = timer
        timer.resume()
    }

    private func sample(generation g: Int) {
        guard playingGeneration == g, let nodeTime = player.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        let seconds = Double(playerTime.sampleTime) / playerTime.sampleRate
        guard seconds >= 0 else { return }   // not heard yet
        let host = AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
        state.withLock { s in
            guard s.generation == g else { return }
            s.heardSeconds = seconds
            s.heardAtHost = host
            s.starting = false
        }
    }

    // MARK: Feed queue

    private func isCurrent(_ g: Int) -> Bool { state.withLock { $0.generation == g } }

    private func feed(from seconds: Double, generation g: Int) {
        guard isCurrent(g) else { return }
        var queued = false
        // A feed that ends before anything was queued leaves nothing to start: no longer starting.
        defer { if !queued { state.withLock { if $0.generation == g { $0.starting = false } } } }
        do {
            try decoder.seek(toSeconds: seconds)
        } catch {
            Self.logger.error("Audio: seek to \(seconds) s failed: \(error, privacy: .public)")
            return
        }
        let slots = DispatchSemaphore(value: 8)
        while isCurrent(g) {
            let chunk: (buffer: AVAudioPCMBuffer, startSeconds: Double)?
            do {
                chunk = try autoreleasepool(invoking: { try decoder.nextBuffer() })   // a pool per buffer: the feed runs for the whole playback
            } catch {
                Self.logger.error("Audio: decoding after \(seconds) s failed: \(error, privacy: .public)")
                return
            }
            guard let chunk else { return }   // the end of the sound
            while slots.wait(timeout: .now() + 0.25) == .timedOut {
                if !isCurrent(g) { return }
            }
            let buffer = chunk.buffer, start = chunk.startSeconds
            engineQueue.async { [self] in
                if !schedule(buffer, startSeconds: start, generation: g, played: { slots.signal() }) {
                    slots.signal()   // not scheduled: its slot is free again
                }
            }
            queued = true
        }
    }
}

extension AudioOutput {
    /// Tests: whether the engine runs, read on its queue.
    var isEngineRunning: Bool { engineQueue.sync { engine.isRunning } }

    /// Tests: what Core Audio does on a device change — the engine stops itself, then the notification is posted.
    func simulateDeviceChange(notify: Bool = true) {
        engineQueue.sync { engine.stop() }
        if notify { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine) }
    }

    /// Tests: a call into AVFAudio that hangs (an output that stalls) holds the engine queue this long.
    func occupyEngineQueue(seconds: Double) {
        engineQueue.async { Thread.sleep(forTimeInterval: seconds) }
    }

    /// Tests: a raise inside AVFAudio on the engine queue.
    func simulateRaise() {
        engineQueue.async { [self] in
            _ = engineCall("test") { NSException(name: .internalInconsistencyException, reason: "test", userInfo: nil).raise() }
        }
    }
}

extension AudioOutput: SnippetSink {
    /// Main thread; returns at once.
    public func playSnippet(_ samples: StereoSamples, sampleRate: Double, ended: @escaping @Sendable () -> Void) {
        let format = decoder.format
        guard sampleRate == format.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            ended()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: samples.count) }
        samples.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: samples.count) }
        engineQueue.async { [self] in
            // A device change stops the engine; a piece for a stopped engine is not heard.
            guard !state.withLock({ $0.stopped }), engine.isRunning,
                  engineCall("snippet play", { if !snippetPlayer.isPlaying { snippetPlayer.play() } }),
                  engineCall("snippet scheduleBuffer", {
                      snippetPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in ended() }
                  }) else {
                ended()
                return
            }
        }
    }
}

extension AudioOutput: TapeSink {
    public func setTapeSnapshot(_ snapshot: TapeSnapshot) { tape.setTapeSnapshot(snapshot) }
    public func setTapeControl(_ control: TapeControl) { tape.setTapeControl(control) }
}
