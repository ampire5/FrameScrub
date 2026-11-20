import AppKit
import CoreImage
import FrameScrubCore
import os
import SwiftUI

struct EnginePlaybackView: View {
    @ObservedObject var service: EnginePlayerService

    var body: some View {
        VStack(spacing: 0) {
            let media = service.mediaID, frame = service.submission, time = service.position
            PlaybackPictureView(image: service.image, mediaID: media, submission: frame, service: service) {
                service.didSubmit(media: media, frame: frame, time: time)
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    transportButton("Previous frame", icon: "backward.frame.fill") { service.step(-1) { _ in } }
                    transportButton(service.playing ? "Pause" : "Play",
                                    icon: service.playing ? "pause.fill" : "play.fill",
                                    help: service.playing ? "Pause (Space)" : "Play (Space)",
                                    action: service.togglePlayback)
                    transportButton("Next frame", icon: "forward.frame.fill") { service.step(1) { _ in } }
                }
                Slider(value: Binding(get: { service.scrubbing ? service.scrubPosition : service.position },
                                      set: { value, _ in service.scrub(to: value) }),
                       in: 0...max(service.duration, 0.001), onEditingChanged: service.editScrub) {
                    Text("Seek")
                }
                .labelsHidden()
                .accessibilityLabel("Seek")
                .help("Click or drag to seek")
                .disabled(service.duration <= 0)
                ViewThatFits(in: .horizontal) {
                    Text("\(timeLabel(service.scrubbing ? service.scrubPosition : service.position)) / \(timeLabel(service.duration))")
                        .fixedSize()
                    Text(timeLabel(service.scrubbing ? service.scrubPosition : service.position))
                        .fixedSize()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    transportButton(service.muted ? "Unmute" : "Mute",
                                    icon: service.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        service.toggleMute()
                    }
                    Slider(value: Binding(get: { service.volume }, set: { value, _ in service.setVolume(value) }), in: 0...100) {
                        Text("Volume")
                    }
                    .labelsHidden()
                    .frame(width: 60)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(service.volume.rounded())) percent")
                    .help("Volume")
                }
                Menu {
                    Toggle("Auto Color", isOn: Binding(get: { service.autoColorEnabled },
                                                       set: { value, _ in service.setAutoColor(value) }))
                    Divider()
                    Button("Vibrance Off") { service.setVibrance(0) }
                    Button("Low vibrance") { service.setVibrance(0.25) }
                    Button("Medium vibrance") { service.setVibrance(0.5) }
                    Button("High vibrance") { service.setVibrance(0.75) }
                } label: {
                    Label("Color", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                }
                .accessibilityLabel("Color")
                .help("Color")
                .fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            // The host keeps its filmstrip hit area outside this row.
            .frame(height: 48)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
        }
        .overlay(alignment: .top) {
            if let error = service.playbackError {
                Text(error).padding(8).background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
        }
        .onDisappear { service.close() }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let time = Duration.seconds(max(0, seconds))
        return time.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func transportButton(_ name: String, icon: String, help: String? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help ?? name)
    }
}

/// The scene owns one decoder worker and at most one future picture. AppKit/UI state stays on main.
final class EnginePlayerService: NSObject, PlaybackService, ObservableObject, @unchecked Sendable {
    private struct Picture {
        let image: CGImage
        let time: Double
        let duration: Double
        var playCount = 1
    }

    private enum Command {
        case open(FileHandle), seek(Double), relativeSeek(Double), step(Int), next, audio
    }

    private enum Result {
        case picture(Picture?), audio(AudioOutput?)
    }

    @Published private(set) var image: CGImage?
    weak var pictureView: PictureView?
    private(set) var mediaID = 0
    private(set) var submission = 0
    private var lastSubmission = 0
    private var presentedTime: Double?
    private var awaitingFirstFrame: ((String) -> Void)?

    func didSubmit(media: Int, frame: Int, time: Double) {
        guard mediaID == media, frame > lastSubmission else { return }
        lastSubmission = frame
        presentedTime = time
        let reply = awaitingFirstFrame
        awaitingFirstFrame = nil
        reply?("ready")
    }

    private struct ColorSettings {
        let vibrance: Double
        let autoRequest: UUID?
    }

    private var vibrance = UserDefaults.standard.double(forKey: "playback-vibrance")
    private var lastVibrance = UserDefaults.standard.object(forKey: "playback-vibrance-strength") as? Double ?? 0.5
    @Published private(set) var autoColorEnabled = false
    private var autoColorRequest: UUID?
    // Accessed only on the decode queue. The same analysis is reused throughout one enable cycle.
    private var analyzedAutoColor: (request: UUID, steps: [ColorCorrection.Step])?

    func togglePlaybackColor(_ automatic: Bool) {
        DispatchQueue.main.async {
            guard self.image != nil else { return }
            if automatic {
                self.setAutoColor(!self.autoColorEnabled)
            } else {
                self.setVibrance(self.vibrance == 0 ? self.lastVibrance : 0)
            }
        }
    }

    func setAutoColor(_ enabled: Bool) {
        guard autoColorEnabled != enabled else { return }
        autoColorEnabled = enabled
        autoColorRequest = enabled ? UUID() : nil
        if !playing, image != nil { seek(position) { _ in } }
    }

    func setVibrance(_ amount: Double) {
        vibrance = amount
        if amount > 0 {
            lastVibrance = amount
            UserDefaults.standard.set(amount, forKey: "playback-vibrance-strength")
        }
        UserDefaults.standard.set(amount, forKey: "playback-vibrance")
        if !playing, image != nil { seek(position) { _ in } }
    }
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published private(set) var playbackError: String?
    @Published private(set) var muted = false
    @Published private(set) var volume = 100.0
    private var gestures = GestureRouter(inputMap: InputMap(layout: .classic), scrubSettings: .init())

    func toggleMute() {
        muted.toggle()
        applyVolume()
    }

    func setVolume(_ level: Double) {
        guard level.isFinite else { return }
        muted = false
        adjustVolume(to: level)
    }

    private func adjustVolume(to level: Double) {
        volume = min(max(level, 0), 100)
        applyVolume()
    }

    private func applyVolume() { audio?.volume = muted ? 0 : Float(volume / 100) }

    private static func inputModifiers(_ flags: UInt) -> Modifiers {
        let flags = NSEvent.ModifierFlags(rawValue: flags)
        var result: Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.ctrl) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.command) { result.insert(.meta) }
        return result
    }

    func playbackKeys(_ reply: @escaping ([String]) -> Void) {
        DispatchQueue.main.async {
            let keys = self.gestures.inputMap.bindings.flatMap { chord, command -> [String] in
                guard !chord.isPointerChord else { return [] }
                switch command {
                case .cyclePause, .seek, .frameStep, .frameBackStep, .addVolume, .cycleMute,
                     .toggleAutoColor, .toggleVibrance: break
                default: return []
                }
                var flags: NSEvent.ModifierFlags = []
                if chord.modifiers.contains(.shift) { flags.insert(.shift) }
                if chord.modifiers.contains(.ctrl) { flags.insert(.control) }
                if chord.modifiers.contains(.alt) { flags.insert(.option) }
                if chord.modifiers.contains(.meta) { flags.insert(.command) }
                if chord.key.count == 1 { return ["\(flags.rawValue):=\(chord.key)"] }
                return chord.virtualKeyCodes.map { "\(flags.rawValue):#\($0)" }
            }
            reply(keys)
        }
    }

    func playbackKey(_ keyCode: UInt16, characters: String, flags: UInt, repeating: Bool) {
        guard let chord = KeyChord.fromKeyEvent(keyCode: keyCode, characters: characters,
                                               modifiers: Self.inputModifiers(flags)) else { return }
        DispatchQueue.main.async {
            guard self.image != nil, let command = self.gestures.inputMap.command(for: chord) else { return }
            self.performPlaybackInput(command, repeating: repeating)
        }
    }

    func playbackScroll(_ x: Double, y: Double, time: Double, flags: UInt,
                        precise: Bool, began: Bool, phased: Bool, momentum: Bool, notches: UInt16,
                        reply: @escaping () -> Void) {
        guard x.isFinite, y.isFinite, time.isFinite else { reply(); return }
        let sample = ScrollSample(deltaX: x, deltaY: y, precise: precise, momentum: momentum, began: began,
                                  time: time, modifiers: Self.inputModifiers(flags), phased: phased)
        DispatchQueue.main.async {
            defer { reply() }
            guard self.image != nil else { return }
            let actions = self.gestures.route(sample) {
                if self.playing { self.stopClock() }
            }
            let count = precise ? 1 : Int(notches)
            for action in actions {
                switch action {
                case .scrubFrames(let frames, _): self.step(frames * count) { _ in }
                case .command(.addVolume(let delta)): self.adjustVolume(to: self.volume + delta * Double(count))
                case .command(.seek(let delta, _)): self.seekRelative(delta * Double(count))
                case .command(let command): self.performPlaybackInput(command)
                default: break
                }
            }
        }
    }

    func cancelPlaybackScroll() {
        DispatchQueue.main.async {
            self.gestures.resetScroll()
            self.pictureView?.cancelRightClick()
        }
    }

    private func performPlaybackInput(_ command: FrameScrubCore.Command, repeating: Bool = false) {
        switch command {
        case .cyclePause where !repeating: if playing { pause() } else { play() }
        case .seek(let delta, _): seekRelative(delta)
        case .frameStep: step(1) { _ in }
        case .frameBackStep: step(-1) { _ in }
        case .addVolume(let delta): adjustVolume(to: volume + delta)
        case .cycleMute where !repeating: toggleMute()
        case .toggleAutoColor where !repeating: setAutoColor(!autoColorEnabled)
        case .toggleVibrance where !repeating: setVibrance(vibrance == 0 ? lastVibrance : 0)
        default: break
        }
    }

    private func seekRelative(_ delta: Double) {
        guard delta.isFinite else { return }
        stopClock()
        pending = nil
        var offset = min(max(delta, -duration), duration)
        if let (command, _) = queued, case .relativeSeek(let earlier) = command { offset += earlier }
        enqueue(.relativeSeek(min(max(offset, -duration), duration))) { _ in }
    }

    private struct InputSettings {
        let scrub: ScrubSettings
        let map: InputMap
        let volume: Double

        static func load() -> Self {
            // Foundation's home directory can be the extension's sandbox container.
            // The sandbox grants read access to the standalone configuration files in the account's home.
            let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
            let directory = home.map { URL(fileURLWithPath: $0).appendingPathComponent(".config/framescrub", isDirectory: true) }
                ?? Config.directory
            let config = Config.load(from: directory.appendingPathComponent("framescrub.conf")).0
            func read(_ name: String) -> String {
                (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            let map = InputMap.build(layout: config.keyLayout, userText: read("input.conf"),
                                     profile: config.mouseProfile, profileText: read(config.mouseProfile.fileName))
            return Self(scrub: config.scrub, map: map, volume: config.volume)
        }
    }
    @Published private(set) var scrubbing = false
    @Published private(set) var scrubPosition = 0.0

    func editScrub(_ editing: Bool) {
        if editing {
            stopClock()
            scrubPosition = position
        }
        scrubbing = editing
    }

    func scrub(to seconds: Double) {
        guard seconds.isFinite else { return }
        scrubPosition = seconds
        requestSeek(seconds) { _ in }
    }

    private let work = DispatchQueue(label: "spike.framescrub.decode", qos: .userInitiated)
    private let context = CIContext() // worker only
    private var decoder: OnDemandVideo? // worker only
    private var decodedTime: Double? // worker only
    private var animation: AnimatedImagePlayback? // worker only
    private var gifPlayCount = 1 // worker only
    private struct InputState {
        var generation = 0
        var cache: ReadCache?
    }
    private let input = OSAllocatedUnfairLock(initialState: InputState())

    private let clock = PlaybackClock()
    private var lastAudioProgress: (media: Double, host: Double)?
    private var audioStartHost = 0.0
    private var audio: AudioOutput?
    private var checkedAudio = false
    private var pending: Picture?
    private var armed: Task<Void, Never>?
    private var queued: (Command, (String) -> Void)?
    private var busy = false
    private var needsCleanup = false
    private var ended = false
    private var openPlayCount = 1
    private var remainingPlays = 1
    private var generation = 0

    func handshake(_ reply: @escaping (Int, Int32) -> Void) {
        reply(playbackVersion, ProcessInfo.processInfo.processIdentifier)
    }

    func open(_ file: FileHandle, reply: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            self.reset()
            self.enqueue(.open(file), reply)
        }
    }

    func step(_ count: Int, reply: @escaping (String) -> Void) {
        guard count != 0 else { status(reply); return }
        DispatchQueue.main.async {
            self.pictureView?.cancelRightClick()
            self.stopClock()
            if count == 1, !self.busy, self.queued == nil, let pending = self.pending {
                self.pending = nil
                self.present(pending)
                reply(self.statusText)
                return
            }
            self.pending = nil
            var steps = count
            if let (command, _) = self.queued, case .step(let earlier) = command {
                let (combined, overflow) = earlier.addingReportingOverflow(count)
                steps = overflow ? (count > 0 ? Int.max : Int.min) : combined
            }
            self.enqueue(.step(steps), reply)
        }
    }

    func seek(_ seconds: Double, reply: @escaping (String) -> Void) {
        guard seconds.isFinite else { reply("Invalid time"); return }
        DispatchQueue.main.async { self.requestSeek(seconds, reply: reply) }
    }

    private func requestSeek(_ seconds: Double, reply: @escaping (String) -> Void) {
        stopClock()
        pending = nil
        enqueue(.seek(seconds), reply)
    }

    func togglePlayback() {
        DispatchQueue.main.async { self.togglePicturePlayback() }
    }

    @MainActor func togglePicturePlayback() {
        if playing { stopClock() } else { startPlaying() }
    }

    func play() { DispatchQueue.main.async { self.startPlaying() } }

    private func startPlaying() {
        guard !playing, image != nil else { return }
        playing = true
        if ended {
            ended = false
            remainingPlays = openPlayCount
            enqueue(.seek(0)) { _ in }
        } else {
            pump()
        }
    }

    func pause() { DispatchQueue.main.async { self.stopClock() } }
    func close() { DispatchQueue.main.async { self.reset(); self.pump() } }
    func playbackTime(_ reply: @escaping (Double) -> Void) {
        DispatchQueue.main.async { reply(self.presentedTime ?? -1) }
    }

    func status(_ reply: @escaping (String) -> Void) {
        DispatchQueue.main.async { reply(self.statusText) }
    }

    private var statusText: String {
        "FrameScrub time=\(position) playing=\(playing) audio=\(audio?.currentSeconds.map(String.init(describing:)) ?? "none")"
    }

    private func enqueue(_ command: Command, _ reply: @escaping (String) -> Void) {
        queued?.1("Superseded")
        queued = (command, reply)
        pump()
    }

    private func stopClock() {
        armed?.cancel()
        armed = nil
        clock.stop()
        audio?.pause()
        playing = false
    }

    private func reset() {
        generation += 1
        mediaID += 1
        autoColorEnabled = false
        autoColorRequest = nil
        submission += 1
        presentedTime = nil
        playbackError = nil
        awaitingFirstFrame?("Closed")
        awaitingFirstFrame = nil
        stopClock()
        audio?.stop()
        audio = nil
        checkedAudio = false
        ended = false
        openPlayCount = 1
        remainingPlays = 1
        pending = nil
        image = nil
        duration = 0
        position = 0
        queued?.1("Closed")
        queued = nil
        let requested = generation
        let old = input.withLock { state -> ReadCache? in
            defer { state = InputState(generation: requested) }
            return state.cache
        }
        old?.close()
        needsCleanup = true
    }

    private func pump() {
        guard !busy else { return }
        if needsCleanup {
            needsCleanup = false
            busy = true
            work.async {
                self.decoder = nil
                self.decodedTime = nil
                self.animation = nil
                self.gifPlayCount = 1
                DispatchQueue.main.async {
                    self.busy = false
                    self.pump()
                }
            }
            return
        }
        if let (command, reply) = queued {
            queued = nil
            run(command, reply)
            return
        }
        guard playing else { return }
        if !checkedAudio {
            run(.audio) { _ in }
            return
        }
        if !clock.isRunning {
            let output = audio
            clock.audioSeconds = { [weak output] in output?.currentSeconds }
            clock.audioStarting = { [weak output] in output?.isStarting == true }
            output?.volume = muted ? 0 : Float(volume / 100)
            output?.play(fromSeconds: position, until: duration > 0 ? duration : nil)
            clock.followsAudio = true
            lastAudioProgress = nil
            audioStartHost = ProcessInfo.processInfo.systemUptime
            clock.start(at: position)
        }
        releaseStalledAudioClock()
        if let pending {
            whenDue(pending.time) {
                self.pending = nil
                self.present(pending)
                self.pump()
            }
        } else if ended {
            whenDue(duration) {
                if self.remainingPlays == 1 {
                    self.stopClock()
                } else {
                    if self.remainingPlays > 1 { self.remainingPlays -= 1 }
                    self.clock.stop()
                    self.ended = false
                    self.enqueue(.seek(0)) { _ in }
                }
            }
        } else {
            run(.next) { _ in }
        }
    }

    private func releaseStalledAudioClock() {
        guard clock.followsAudio, let audio else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let heard = audio.currentSeconds else {
            if audio.isStarting, now - audioStartHost >= clock.audioStartLimit {
                clock.followsAudio = false
                audio.pause()
                clock.start(at: position)
            }
            return
        }
        if let previous = lastAudioProgress, heard <= previous.media {
            guard now - previous.host >= clock.audioStartLimit else { return }
            // Audio can end before the video. Continue from the last heard time when its clock stops.
            clock.followsAudio = false
            audio.pause()
            clock.start(at: max(position, heard))
        } else {
            lastAudioProgress = (heard, now)
        }
    }

    private func whenDue(_ target: Double, _ action: @escaping () -> Void) {
        guard armed == nil else { return }
        let delay = target - clock.seconds
        guard delay > 0 else {
            action()
            return
        }
        // With audio, recheck its media clock while it starts or reads behind the video.
        let interval = audio == nil || !clock.followsAudio ? delay : min(delay, 1.0 / 30.0)
        armed = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            self.armed = nil
            self.pump()
        }
    }

    private func present(_ picture: Picture) {
        submission += 1
        position = picture.time
        duration = picture.duration
        image = picture.image
    }

    private func execute(_ command: Command, generation requested: Int, anchor: Double, color: ColorSettings) throws -> Result {
        let input = self.input
        let cancelled = { input.withLock { $0.generation != requested } }
        if cancelled() { throw CancellationError() }
        let frame: DecodedFrame?
        switch command {
        case .open(let file):
            let source = try FileByteSource(duplicatingReadOnlyDescriptor: file.fileDescriptor)
            var header = [UInt8](repeating: 0, count: 12)
            let count = try header.withUnsafeMutableBytes { bytes in
                try source.read(at: 0, count: bytes.count, into: bytes.baseAddress!)
            }
            let gif = count >= 10 && (header.prefix(6).elementsEqual("GIF89a".utf8)
                || header.prefix(6).elementsEqual("GIF87a".utf8))
            let webP = count == 12 && header.prefix(4).elementsEqual("RIFF".utf8)
                && header.suffix(4).elementsEqual("WEBP".utf8)
            if webP {
                let playback = try AnimatedImagePlayback(source: source, isCancelled: cancelled)
                animation = playback
                return .picture(animationPicture(try playback.frame(at: 0), in: playback, color: color))
            }
            if gif {
                let width = Int(header[6]) | Int(header[7]) << 8
                let height = Int(header[8]) | Int(header[9]) << 8
                guard width > 0, height > 0, width <= AnimatedImagePlayback.maximumCanvasPixels / height else {
                    throw AnimatedImagePlayback.DecodingError.canvasSizeLimit
                }
                gifPlayCount = try AnimatedImagePlayback.gifPlayCount(in: source)
            }
            let url = URL(fileURLWithPath: gif ? "/animation.gif" : "/video")
            let bytes = try ReadCache(url: url, budgetBytes: gif ? 2 * ReadCache.blockSize : 0, source: source)
            guard input.withLock({ state in
                guard state.generation == requested else { return false }
                state.cache = bytes
                return true
            }) else { throw CancellationError() }
            decoder = try OnDemandVideo(url: url, readCache: bytes, preferHardware: !gif)
            frame = try decoder?.next(isCancelled: cancelled)
        case .seek(let value), .relativeSeek(let value):
            let seconds: Double
            if case .relativeSeek = command { seconds = max(0, anchor + value) } else { seconds = value }
            if let animation { return .picture(animationPicture(try animation.seek(to: seconds), in: animation, color: color)) }
            frame = try decoder?.seek(to: seconds, isCancelled: cancelled)
        case .step(let count):
            guard count != 0 else { return .picture(nil) }
            if let animation {
                if animation.currentFrame?.seconds != anchor { _ = try animation.seek(to: anchor) }
                var reached: AnimatedImagePlayback.Frame?
                for _ in 0..<count.magnitude {
                    guard let next = try count < 0 ? animation.previous() : animation.next() else { break }
                    reached = next
                }
                return .picture(reached.map { animationPicture($0, in: animation, color: color) })
            }
            if decodedTime != anchor { _ = try decoder?.seek(to: anchor, isCancelled: cancelled) }
            var reached: DecodedFrame?
            for _ in 0..<count.magnitude {
                let next = try count < 0 ? decoder?.previous(isCancelled: cancelled) : decoder?.next(isCancelled: cancelled)
                guard let next else { break }
                reached = next
            }
            frame = reached
        case .next:
            if let animation { return .picture(try animation.next().map { animationPicture($0, in: animation, color: color) }) }
            frame = try decoder?.next(isCancelled: cancelled)
        case .audio:
            guard let audioDecoder = try decoder?.makeAudioDecoder() else { return .audio(nil) }
            return .audio(try AudioOutput(decoder: audioDecoder))
        }
        guard let frame, let decoder else { return .picture(nil) }
        decodedTime = decoder.time(of: frame)
        var pixels = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let rotation = (decoder.rotationClockwise % 360 + 360) % 360
        switch rotation {
        case 90: pixels = pixels.oriented(.right)
        case 180: pixels = pixels.oriented(.down)
        case 270: pixels = pixels.oriented(.left)
        default: break
        }
        let sar = decoder.sampleAspect
        if sar.isFinite, sar > 0, sar != 1 {
            let transform = (rotation == 90 || rotation == 270)
                ? CGAffineTransform(scaleX: 1, y: sar) : CGAffineTransform(scaleX: sar, y: 1)
            pixels = pixels.transformed(by: transform)
        }
        pixels = correction(for: pixels, settings: color).apply(to: pixels)
        guard let image = context.createCGImage(pixels, from: pixels.extent) else { return .picture(nil) }
        return .picture(Picture(image: image, time: decoder.time(of: frame),
                                duration: max(0, decoder.duration.isFinite ? decoder.duration : 0),
                                playCount: gifPlayCount))
    }

    private func correction(for image: CIImage, settings: ColorSettings) -> ColorCorrection {
        if let request = settings.autoRequest {
            if analyzedAutoColor?.request != request {
                analyzedAutoColor = (request, ColorCorrection.autoAdjustment(for: image))
            }
        } else {
            analyzedAutoColor = nil
        }
        return ColorCorrection(vibrance: settings.vibrance, auto: analyzedAutoColor?.steps ?? [])
    }

    private func animationPicture(_ frame: AnimatedImagePlayback.Frame, in animation: AnimatedImagePlayback,
                                  color: ColorSettings) -> Picture {
        let image: CGImage
        if color.vibrance != 0 || color.autoRequest != nil {
            let pixels = CIImage(cgImage: frame.image)
            let adjusted = correction(for: pixels, settings: color).apply(to: pixels)
            image = context.createCGImage(adjusted, from: adjusted.extent) ?? frame.image
        } else {
            image = frame.image
        }
        return Picture(image: image, time: frame.seconds, duration: animation.duration,
                       playCount: animation.totalPlayCount ?? 0)
    }

    private func run(_ command: Command, _ reply: @escaping (String) -> Void) {
        busy = true
        let requested = generation
        let color = ColorSettings(vibrance: vibrance, autoRequest: autoColorRequest)
        let anchor = position
        work.async {
            let result = Swift.Result { try self.execute(command, generation: requested, anchor: anchor, color: color) }
            let settings: InputSettings?
            if case .open = command, case .success(.picture(.some)) = result {
                settings = InputSettings.load()
            } else {
                settings = nil
            }
            DispatchQueue.main.async {
                self.busy = false
                defer { self.pump() }
                guard self.generation == requested else {
                    if case .success(.audio(let output)) = result { output?.stop() }
                    reply("Superseded")
                    return
                }
                if case .audio = command {
                    self.checkedAudio = true
                    if case .success(.audio(let output)) = result {
                        self.audio = output
                        output?.onRestart = { [weak self] in
                            guard let self, self.playing else { return }
                            self.clock.stop()
                            self.pump()
                        }
                    }
                    reply(self.statusText)
                    return
                }
                switch result {
                case .success(.picture(let picture)):
                    if case .next = command {
                        if self.queued == nil {
                            self.pending = picture
                            self.ended = picture == nil
                        }
                    } else if let picture {
                        if case .open = command {
                            if let settings {
                                self.gestures = GestureRouter(inputMap: settings.map, scrubSettings: settings.scrub)
                                self.setVolume(settings.volume)
                            }
                            self.openPlayCount = picture.playCount
                            self.remainingPlays = picture.playCount
                            self.awaitingFirstFrame = reply
                        }
                        self.present(picture)
                        self.ended = false
                    }
                    if case .open = command, picture != nil { return }
                    reply(self.statusText)
                case .failure(let error):
                    self.stopClock()
                    self.playbackError = "Playback stopped. Try opening the file in FrameScrub."
                    reply("FrameScrub decode failed: \(error)")
                case .success(.audio):
                    break
                }
            }
        }
    }
}
