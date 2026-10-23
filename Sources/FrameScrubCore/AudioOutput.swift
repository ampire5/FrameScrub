import AVFoundation
import os

/// Plays an AudioDecoder through AVAudioEngine (player → time-pitch → mixer) and reports the
/// media time actually being heard. Decoding runs on a private serial queue. A second player node plays scrub audio
/// pieces straight into the mixer: same volume, always 1×.
public final class AudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let snippetPlayer = AVAudioPlayerNode()
    private let tape: ScrubTape
    private let decoder: AudioDecoder
    private let feedQueue = DispatchQueue(label: "framescrub.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0
    private var startSeconds = 0.0
    private var starting = false
    /// Main thread, after a device change stopped the engine and it runs again: the playback's queued sound is
    /// gone, so playback that was running must be started again (PlayerCore: from the frame on screen).
    public var onRestart: (() -> Void)?
    private var deviceObserver: NSObjectProtocol?
    private static let logger = Logger(subsystem: "local.framescrub", category: "Audio")

    public init(decoder: AudioDecoder) throws {
        self.decoder = decoder
        tape = ScrubTape(format: decoder.format)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: decoder.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: decoder.format)
        engine.attach(snippetPlayer)
        engine.connect(snippetPlayer, to: engine.mainMixerNode, format: decoder.format)
        engine.attach(tape.node)
        engine.connect(tape.node, to: engine.mainMixerNode, format: decoder.format)
        engine.prepare()
        try engine.start()
        snippetPlayer.play()
        // A change of the output's sample rate or channels (Bluetooth headphones switching profile, another
        // device chosen) stops the engine for good; nothing plays until it is started again.
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Self.logger.notice("Audio: configuration change, engine running \(self.engine.isRunning), output \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
            guard self.restartEngine() else { return }
            self.onRestart?()
        }
    }

    deinit {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
    }

    /// Playback rates AVAudioUnitTimePitch supports.
    public static let rateRange: ClosedRange<Double> = (1.0 / 32)...32

    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = min(max(newValue, Float(Self.rateRange.lowerBound)), Float(Self.rateRange.upperBound)) }
    }

    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Seconds on the video timeline being heard now; nil while stopped or still starting.
    public var currentSeconds: Double? {
        guard player.isPlaying, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return lock.withLock { startSeconds } + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Asked to play and not heard yet: the feed is still seeking and decoding its first piece. False once the sound
    /// runs, and when the feed gave up (no sound there, a failure) or playback was paused.
    public var isStarting: Bool { lock.withLock { starting } }

    public func play(fromSeconds seconds: Double) {
        _ = restartEngine()   // a device change whose restart failed: try again when asked to play
        let current = lock.withLock { () -> Int in
            generation += 1
            startSeconds = seconds
            starting = true
            player.stop()
            return generation
        }
        feedQueue.async { [self] in feed(from: seconds, generation: current) }
    }

    public func pause() {
        lock.withLock {
            generation += 1
            starting = false
            player.stop()
        }
    }

    public func stop() {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        deviceObserver = nil
        pause()
        engine.stop()
    }

    /// Starts the engine again if a device change stopped it; true when it was stopped and runs now. Main thread.
    private func restartEngine() -> Bool {
        guard deviceObserver != nil, !engine.isRunning else { return false }
        do {
            try engine.start()
        } catch {
            Self.logger.error("Audio: restart after a device change failed: \(error, privacy: .public)")   // the next change or play() tries again
            return false
        }
        snippetPlayer.play()
        return true
    }

    var isEngineRunning: Bool { engine.isRunning }

    /// Tests: what Core Audio does on a device change — the engine stops itself, then the notification is posted.
    func simulateDeviceChange(notify: Bool = true) {
        engine.stop()
        if notify { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine) }
    }

    private func isCurrent(_ g: Int) -> Bool { lock.withLock { generation == g } }

    private func feed(from seconds: Double, generation g: Int) {
        // However the feed ends before the sound runs, it is no longer starting.
        defer { lock.withLock { if generation == g { starting = false } } }
        do {
            try decoder.seek(toSeconds: seconds)
        } catch {
            Self.logger.error("Audio: seek to \(seconds) s failed: \(error, privacy: .public)")
            return
        }
        let slots = DispatchSemaphore(value: 8)
        var started = false
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
            // Check, schedule and play atomically with generation changes (play/pause stop the
            // player under the same lock), so a stale feed never touches the player.
            let proceed = lock.withLock { () -> Bool in
                guard generation == g else { return false }
                player.scheduleBuffer(chunk.buffer) { slots.signal() }
                if !started {
                    // Start only once data is queued, timed from the first chunk: audio that
                    // begins later than requested (e.g. a late-starting track) must not run early.
                    startSeconds = chunk.startSeconds
                    player.play()
                    started = true
                    starting = false
                }
                return true
            }
            if !proceed {
                slots.signal()   // return the unused slot so the semaphore is balanced at dealloc
                return
            }
        }
    }
}

extension AudioOutput: SnippetSink {
    public func playSnippet(_ samples: StereoSamples, sampleRate: Double, ended: @escaping @Sendable () -> Void) {
        let format = decoder.format
        // A device change stops the engine; play() on a stopped engine raises (review).
        guard engine.isRunning, sampleRate == format.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            ended()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: samples.count) }
        samples.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: samples.count) }
        if !snippetPlayer.isPlaying { snippetPlayer.play() }
        snippetPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in ended() }
    }
}

extension AudioOutput: TapeSink {
    public func setTapeSnapshot(_ snapshot: TapeSnapshot) { tape.setTapeSnapshot(snapshot) }
    public func setTapeControl(_ control: TapeControl) { tape.setTapeControl(control) }
}
