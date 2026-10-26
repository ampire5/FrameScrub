import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import FrameScrubCore

final class RecordingDelegate: PlayerCoreDelegate {
    var frames: [DecodedFrame] = []
    var messages: [String] = []
    func player(_ player: PlayerCore, display frame: DecodedFrame) { frames.append(frame) }
    func playerStateDidChange(_ player: PlayerCore) {}
    func player(_ player: PlayerCore, showOSD text: String) { messages.append(text) }
    var copied: [(data: Data, frame: Int, note: String?)] = []
    func player(_ player: PlayerCore, copyImage data: Data, frame: Int, note: String?) { copied.append((data, frame, note)) }
    var reachedEnd = false
    func playerDidReachEnd(_ player: PlayerCore) { reachedEnd = true }
    var feedback: [Feedback] = []
    func player(_ player: PlayerCore, showFeedback feedback: Feedback) { self.feedback.append(feedback) }
}

/// The haptic events a player emitted.
final class HapticLog {
    var events: [HapticEvent] = []
    /// The seeks' `.step`s (`onSeekHaptic`), which the app plays for mouse input only.
    var seekSteps: [HapticEvent] = []
}

@Suite(.serialized) @MainActor struct PlayerCoreTests {
    private func makePlayer(now: @escaping () -> Double = CACurrentMediaTime,
                            configure: (inout Config) -> Void = { _ in },
                            resumeStore: ResumeStore? = nil, fixture: String = Fixtures.h264,
                            beforeOpen: (PlayerCore) -> Void = { _ in }) throws -> (PlayerCore, RecordingDelegate, URL) {
        let root = makeTemporaryDirectory()
        var config = Config()
        config.cacheSizeMiB = 400
        config.frameDirectory = root.path + "/%{video-name}"
        configure(&config)
        let player = PlayerCore(config: config, enableAudio: false,
                                fallbackRoot: root.appendingPathComponent("fallback"), now: now,
                                resumeStore: resumeStore)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        beforeOpen(player)
        try player.open(Fixtures.url(fixture))
        return (player, delegate, root)
    }

    /// A file read on another thread (`preparation`) opens like `open(url)`, over the file open until then; a
    /// preparation that is discarded leaves the player as it was.
    @Test func aPreparedOpenReplacesTheFileOnScreen() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        let other = Fixtures.url(Fixtures.withAudio)
        let prepare = player.preparation(for: other)
        let prepared = try await Task.detached { try prepare() }.value
        #expect(player.url == Fixtures.url(Fixtures.h264))   // nothing changed while it was read
        let unused = try await Task.detached { try prepare() }.value
        unused.discard()
        delegate.frames.removeAll()
        player.open(prepared)
        #expect(player.url == other)
        #expect(player.info?.width == 640)
        #expect(await eventually { !delegate.frames.isEmpty })
        #expect(delegate.frames.first.map { readFrameNumber($0.pixelBuffer) } == 0)
    }

    /// Making a preparation touches nothing (the window makes it on the main thread): a missing file fails only when
    /// the preparation runs.
    @Test func aPreparationReadsNothingUntilItRuns() async throws {
        let (player, _, root) = try makePlayer()
        defer { player.close() }
        let prepare = player.preparation(for: root.appendingPathComponent("missing.mp4"))
        await #expect(throws: (any Error).self) { try await Task.detached { try prepare() }.value }
        #expect(player.url == Fixtures.url(Fixtures.h264))
    }

    /// A cancelled preparation reads nothing more: it ends with `ECANCELED` and the player is untouched.
    @Test func aCancelledPreparationStops() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        let cancellation = OpenCancellation()
        cancellation.cancel()
        let prepare = player.preparation(for: Fixtures.url(Fixtures.withAudio), cancellation: cancellation)
        let error = await #expect(throws: POSIXError.self) { try await Task.detached { try prepare() }.value }
        #expect(error?.code == .ECANCELED)
        #expect(player.url == Fixtures.url(Fixtures.h264))
    }

    // MARK: Scrub audio

    /// The scrub audio is set up beside the video; these tests start once it is in.
    private func scrubAudioPlayer(_ configure: (inout Config) -> Void = { _ in }) async throws -> (PlayerCore, RecordingSink) {
        let sink = RecordingSink()
        let (player, _, _) = try makePlayer(configure: configure, fixture: Fixtures.withAudio,
                                            beforeOpen: { $0.snippetSinkOverride = sink })
        #expect(await eventually { player.hasScrubAudio })
        return (player, sink)
    }

    @Test func frameStepInPauseSoundsOnce() async throws {
        let (player, sink) = try await scrubAudioPlayer()
        defer { player.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.pieces.isEmpty)              // the opening frame is quiet
        player.perform(.frameStep)
        #expect(await eventually { sink.pieces.count == 1 })
        #expect(sink.pieces.first?.samples.count == 3840)
    }

    @Test func stepAfterPauseSounds() async throws {
        let (player, sink) = try await scrubAudioPlayer()
        defer { player.close() }
        player.perform(.cyclePause)
        try await Task.sleep(for: .milliseconds(300))
        player.perform(.cyclePause)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.pieces.isEmpty)              // neither playing nor pausing makes pieces
        player.perform(.frameStep)
        #expect(await eventually { sink.pieces.count == 1 })
    }

    /// `.` during playback pauses and steps: the user asked for that frame, so it sounds (review).
    @Test func frameStepDuringPlaybackSounds() async throws {
        let (player, sink) = try await scrubAudioPlayer()
        defer { player.close() }
        player.perform(.cyclePause)
        try await Task.sleep(for: .milliseconds(300))
        player.perform(.frameStep)
        #expect(await eventually { sink.pieces.count == 1 })
    }

    @Test func scrubAudioOffOrMutedIsSilent() async throws {
        let (player, sink) = try await scrubAudioPlayer { $0.scrubAudio = false }
        defer { player.close() }
        player.perform(.frameStep)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.pieces.isEmpty)
        var config = player.config
        config.scrubAudio = true
        player.apply(config)
        player.perform(.cycleMute)
        player.perform(.frameStep)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.pieces.isEmpty)
        player.perform(.cycleMute)
        player.perform(.frameStep)
        #expect(await eventually { sink.pieces.count == 1 })
    }

    /// A frame that is not decoded yet reaches the screen when the decoder inserts it, not through a redraw.
    @Test func aFrameArrivingAfterTheSeekSounds() async throws {
        let (player, sink) = try await scrubAudioPlayer()
        defer { player.close() }
        player.perform(.seek(3.6, .exact))        // nothing is decoded yet: frame 90 comes from the decoder
        #expect(await eventually { sink.pieces.count == 1 })
    }

    @Test func scrubAudioLengthComesFromTheConfig() async throws {
        let (player, sink) = try await scrubAudioPlayer { $0.scrubAudioLengthMs = 200 }
        defer { player.close() }
        player.scrub(by: 3)
        #expect(await eventually { sink.pieces.count == 1 })
        #expect(sink.pieces.first?.samples.count == 9600)
    }

    /// Indexed, and a picture of the file on screen. Playing waits for the file's first picture before its clock runs
    /// (`restartClock`), so a test that moves the clock by hand and expects `tick()` to follow it starts only once
    /// that picture is in: on a slow or busy machine (CI) it came after the index, and the first ticks did nothing.
    private func ready(_ player: PlayerCore) async -> Bool {
        await eventually { player.index?.isExact == true && player.displayedFrame != nil }
    }

    /// Playing, and the clock running: it starts once the frame playback starts on is on screen (`restartClock`).
    private func running(_ player: PlayerCore) async -> Bool {
        await eventually { player.tick(); return player.clock.isRunning }
    }

    private func shownNumber(_ delegate: RecordingDelegate) -> Int? {
        delegate.frames.last.map { readFrameNumber($0.pixelBuffer) }
    }

    private func temporaryStore() -> ResumeStore {
        ResumeStore(url: makeTemporaryDirectory().appendingPathComponent("positions.json"))
    }

    @Test func applyingANewVolumeChangesThePlayerVolume() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        var config = player.config
        config.volume = 40
        player.apply(config)
        #expect(player.volume == 40)
        config.cacheSizeMiB = 128
        player.apply(config)                       // volume untouched by a different change
        #expect(player.volume == 40)
        player.perform(.addVolume(10))
        player.apply(config)                       // same config again: do not undo the user's volume change
        #expect(player.volume == 50)
    }

    @Test func theExactIndexIsAnnounced() async throws {
        var announced: FrameIndex?
        let (player, _, _) = try makePlayer(beforeOpen: { $0.onIndexReady = { announced = $0 } })
        defer { player.close() }
        #expect(await eventually { announced != nil })
        #expect(announced?.isExact == true)
    }

    @Test func applyingAnUnrelatedChangeKeepsThePressureReducedCacheBudget() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(player.cache.budgetBytes == 400 << 20)
        player.setMemoryPressureFactor(0.5)
        #expect(player.cache.budgetBytes == 200 << 20)
        var config = player.config
        config.sharpen = 0.5
        player.apply(config)                       // not a cache change: the lowered budget stays
        #expect(player.cache.budgetBytes == 200 << 20)
        config.cacheSizeMiB = 100
        player.apply(config)                       // a new size is scaled by the active factor
        #expect(player.cache.budgetBytes == 50 << 20)
        player.setMemoryPressureFactor(1)
        #expect(player.cache.budgetBytes == 100 << 20)
    }

    @Test func copyFrameWithoutAVideoSaysSoAndLeavesNothingPending() {
        let player = PlayerCore(config: Config(), enableAudio: false,
                                fallbackRoot: makeTemporaryDirectory(), resumeStore: nil)
        let delegate = RecordingDelegate()
        player.delegate = delegate
        player.perform(.copyFrame)
        #expect(delegate.messages == ["No video open"])
        #expect(delegate.copied.isEmpty)
    }

    @Test func copyFrameDeliversPNGDataToTheDelegate() async throws {
        let (player, delegate, _) = try makePlayer(configure: { $0.saveUpscaler = .lanczos })
        defer { player.close() }
        player.seek(toFrame: 5)
        player.perform(.copyFrame)
        #expect(await eventually { delegate.copied.count == 1 })
        #expect(delegate.copied[0].frame == 5)
        #expect(delegate.copied[0].note == nil)
        let image = try #require(CGImageSourceCreateWithData(delegate.copied[0].data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 1920)
    }

    @Test func copyFrameForAFrameThatIsNotDecodedYetWaitsForIt() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.seek(toFrame: 590)                    // far from the cached start
        player.perform(.copyFrame)
        #expect(await eventually { delegate.copied.count == 1 })
        #expect(delegate.copied[0].frame == 590)
    }

    @Test func movingOnCancelsAPendingCopy() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.seek(toFrame: 590)
        player.perform(.copyFrame)
        player.seek(toFrame: 3)                      // the user moved on before frame 590 arrived
        #expect(await eventually { delegate.messages.contains("Copy cancelled") || delegate.copied.count == 1 })
        #expect(delegate.copied.allSatisfy { $0.frame != 590 } || delegate.messages.contains("Copy cancelled"))
    }

    @Test func revealTargetIsNilUntilSomethingExistsThenTheSavedFile() async throws {
        let (player, delegate, root) = try makePlayer()
        defer { player.close() }
        #expect(player.revealTarget == nil)
        #expect(player.savedCount == 0)
        player.seek(toFrame: 5)
        player.perform(.screenshot)
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("Saved:") } })
        #expect(player.savedCount == 1)
        let saved = try #require(player.lastSavedURL)
        #expect(saved.path.hasPrefix(root.path))
        #expect(player.revealTarget == saved)
        #expect(player.statsText.contains("Saved: 1"))
    }

    @Test func revealTargetFallsBackToTheFrameFolderWhenItExists() throws {
        let (player, _, root) = try makePlayer()
        defer { player.close() }
        let folder = root.appendingPathComponent("h264_cfr_gop250")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(player.revealTarget?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func endOfFileNotifiesDelegate() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 590)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 1
        player.tick()
        #expect(player.isPaused)
        #expect(delegate.reachedEnd)
    }

    @Test func resumesWhereLeftOff() throws {
        let store = temporaryStore()
        do {
            let (player, _, _) = try makePlayer(resumeStore: store)
            player.seek(toFrame: 300)
            player.perform(.abLoop)
            player.seek(toFrame: 310)
            player.perform(.abLoop)
            player.seek(toFrame: 300)
            player.close()
        }
        #expect(store.entry(for: Fixtures.url(Fixtures.h264))?.position == 10)
        #expect(store.entry(for: Fixtures.url(Fixtures.h264))?.duration == 20)   // the start screen's progress bar
        let (player, delegate, _) = try makePlayer(resumeStore: store)
        defer { player.close() }
        #expect(player.position == 300)
        #expect(player.loopA == 300 && player.loopB == 310)
        #expect(delegate.messages.contains("Resumed at 00:00:10.000"))
    }

    @Test func fallbackPositionWhenNothingRemembered() throws {
        let url = Fixtures.url(Fixtures.h264)
        let empty = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory(),
                               resumeStore: temporaryStore())
        try empty.open(url, fallbackPosition: 2)
        #expect(empty.position == 60)
        empty.close()
        let store = temporaryStore()
        store.save(ResumeEntry(position: 1), for: url)
        let remembered = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory(), resumeStore: store)
        try remembered.open(url, fallbackPosition: 2)
        #expect(remembered.position == 30)
        remembered.close()
        let nearEnd = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory(),
                                 resumeStore: temporaryStore())
        try nearEnd.open(url, fallbackPosition: 16)
        defer { nearEnd.close() }
        #expect(nearEnd.position == 0)
    }

    /// An open that lands on a time of its own (a page's `t`, even 0) does not seek to the remembered position first
    /// nor announce it; the remembered A-B range still comes back.
    @Test func aLandingTimeSkipsTheRememberedPosition() throws {
        let url = Fixtures.url(Fixtures.h264)
        let store = temporaryStore()
        store.save(ResumeEntry(position: 10, loopA: 2, loopB: 3), for: url)
        let delegate = RecordingDelegate()
        let player = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory(), resumeStore: store)
        player.delegate = delegate
        defer { player.close() }
        try player.open(url, fallbackPosition: 5, landingTime: 0)
        #expect(player.position == 0)
        #expect(player.loopA == 60 && player.loopB == 90)
        #expect(!delegate.messages.contains { $0.hasPrefix("Resumed at") })
        player.applyLanding(LinkTarget(time: 0))
        #expect(player.position == 0)
    }

    @Test func nearTheEndStartsFromTheBeginning() throws {
        let store = temporaryStore()
        store.save(ResumeEntry(position: 19), for: Fixtures.url(Fixtures.h264))
        let (player, _, _) = try makePlayer(resumeStore: store)
        defer { player.close() }
        #expect(player.position == 0)
    }

    @Test func opensPausedUnlessAutoplay() throws {
        let (paused, _, _) = try makePlayer()
        defer { paused.close() }
        #expect(paused.isPaused)
        let (playing, _, _) = try makePlayer(configure: { $0.autoplay = true })
        defer { playing.close() }
        #expect(!playing.isPaused)
    }

    /// The clock waits for the file's first picture, so playback starts on it instead of chasing a running clock.
    @Test func playbackClockWaitsForTheFirstPicture() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.autoplay = true })
        defer { player.close() }
        #expect(!player.isPaused)
        if player.displayedFrame == nil { #expect(!player.clock.isRunning) }
        #expect(await eventually { player.displayedFrame != nil })
        #expect(player.clock.isRunning)
        #expect(player.displayedFrame == 0)
    }

    /// A stand-in near the target is on screen, not the target itself: the clock (and with it the sound) waits for the
    /// frame playback starts on, so the picture never trails the sound at the start.
    @Test func playbackClockWaitsForTheFrameItStartsOn() async throws {
        let now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 240)   // same GOP as the frame on screen: decoded from frame 0 on, a stand-in shows first
        player.play()
        #expect(player.clock.isRunning == (player.displayedFrame == 240), "shown \(String(describing: player.displayedFrame))")
        #expect(await eventually { player.tick(); return player.displayedFrame == 240 })
        #expect(player.clock.isRunning)
        #expect(player.clock.seconds == player.index?.seconds(forFrame: 240))
        #expect(self.shownNumber(delegate) == 240)
    }

    /// A new file opened at a time and played at once from a slow source (a share, a stream): the exact index and
    /// frames before the target arrive first and a stand-in shows, but the clock waits for the target itself.
    @Test func playingAFileJustOpenedAtATimeStartsOnItsFrame() async throws {
        let now = 1000.0
        let url = Fixtures.url(Fixtures.h264)
        let size = try FileByteSource(url: url).size
        var config = Config()
        config.cacheSizeMiB = 400
        let player = PlayerCore(config: config, enableAudio: false, fallbackRoot: makeTemporaryDirectory(), now: { now },
                                byteSource: { url, _ in ThrottledByteSource(try FileByteSource(url: url), bytesPerSecond: Int(size / 3)) })
        let delegate = RecordingDelegate()
        player.delegate = delegate
        defer { player.close() }
        try player.open(url)
        player.applyLanding(LinkTarget(time: 8))   // frame 240, in the first GOP
        player.play()
        #expect(await eventually(timeout: 30) { player.tick(); return player.clock.isRunning })
        #expect(player.displayedFrame == 240, "stand-ins shown: \(delegate.frames.map { readFrameNumber($0.pixelBuffer) })")
        #expect(self.shownNumber(delegate) == 240)
    }

    /// Locked segments that play on to the next: the sound's first moments must not put the playhead a frame before the
    /// segment (the player's time is negative until its first sample is heard), from where playback jumped back to the
    /// segment's start and started the sound again, over and over: a buzz. Needs an audio device.
    @Test func soundStartingAtASegmentStartStartsOnce() async throws {
        let player = PlayerCore(config: Config(), enableAudio: true, fallbackRoot: makeTemporaryDirectory())
        defer { player.close() }
        try player.open(Fixtures.url(Fixtures.withAudio))
        guard await eventually(timeout: 3, { player.hasAudio }) else { return }   // no audio device here
        player.applyLanding(LinkTarget(time: 1.0, segments: [1.0...1.6, 2.4...3.0], advance: .next))
        player.play()
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 0.45 {   // inside the first segment (0.6 s)
            player.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.audioPlayCalls == 1)
        #expect(player.position >= 25 && player.position <= 40)
    }

    /// The clock follows the sound: while the sound is still starting it holds the start (both begin together), but
    /// not for longer than `audioStartLimit`.
    @Test func clockHoldsWhileTheSoundStarts() {
        var now = 0.0
        var starting = true
        var heard: Double?
        let clock = PlaybackClock(now: { now })
        clock.audioSeconds = { heard }
        clock.audioStarting = { starting }
        clock.start(at: 10)
        now += 0.3
        #expect(clock.seconds == 10)
        starting = false
        heard = 10.05
        now += 0.05
        #expect(clock.seconds == 10.05)
        // A sound that never starts holds the clock for the limit only, then the host clock runs on from the start.
        clock.start(at: 20)
        heard = nil
        starting = true
        now += clock.audioStartLimit - 0.01
        #expect(clock.seconds == 20)
        now += 0.5
        #expect(abs(clock.seconds - 20.5) < 1e-9)
    }

    @Test func autoplayStartsAfterTheResumePosition() throws {
        let store = temporaryStore()
        store.save(ResumeEntry(position: 10), for: Fixtures.url(Fixtures.h264))
        let (player, _, _) = try makePlayer(configure: { $0.autoplay = true }, resumeStore: store)
        defer { player.close() }
        #expect(!player.isPaused)
        #expect(player.position > 0)
    }

    @Test func playbackWaitingForTheFirstPictureKeepsTheResumePosition() throws {
        let store = temporaryStore()
        store.save(ResumeEntry(position: 10), for: Fixtures.url(Fixtures.h264))
        let (player, _, _) = try makePlayer(configure: { $0.autoplay = true }, resumeStore: store)
        defer { player.close() }
        player.tick()   // a display refresh before the first picture: the clock has not started yet
        #expect(player.position == 300)
    }

    @Test func resumeCanBeTurnedOff() throws {
        let store = temporaryStore()
        store.save(ResumeEntry(position: 10), for: Fixtures.url(Fixtures.h264))
        let (player, _, _) = try makePlayer(configure: { $0.resumePlayback = false }, resumeStore: store)
        defer { player.close() }
        #expect(player.position == 0)
    }

    @Test func positionSaveKeepsColor() throws {
        let store = temporaryStore()
        let video = Fixtures.url(Fixtures.h264)
        let values = ["auto-color": "yes", "auto-color-strength": "0.4"]
        store.setColor(values, for: video)
        let (player, _, _) = try makePlayer(resumeStore: store)
        player.seek(toFrame: 270)
        player.close()
        #expect(store.entry(for: video)?.position == 9)
        #expect(store.color(for: video) == values)
    }

    @Test func colorSurvivesWithResumeTurnedOff() throws {
        let store = temporaryStore()
        let video = Fixtures.url(Fixtures.h264)
        let values = ["vibrance-on": "yes"]
        store.setColor(values, for: video)
        let (player, _, _) = try makePlayer(configure: { $0.resumePlayback = false }, resumeStore: store)
        player.seek(toFrame: 270)
        player.close()
        #expect(store.color(for: video) == values)
        #expect(store.entry(for: video)?.position == 0)
    }

    @Test func opensAndShowsFirstFrame() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        #expect(player.frameCount == 600)
        #expect(await eventually { player.displayedFrame == 0 })
        #expect(shownNumber(delegate) == 0)
    }

    @Test func seeksStepsAndScrubs() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.perform(.seek(5, .exact))
        #expect(player.position == 150)
        #expect(await eventually { player.displayedFrame == 150 })
        #expect(shownNumber(delegate) == 150)

        for _ in 0..<3 { player.perform(.frameBackStep) }
        #expect(player.position == 147)
        #expect(await eventually { player.displayedFrame == 147 })
        #expect(shownNumber(delegate) == 147)

        player.scrub(by: -20)
        #expect(player.position == 127)
        #expect(player.isPaused)
        #expect(await eventually { player.displayedFrame == 127 })
        #expect(delegate.messages.last?.hasPrefix("Frame 127") == true)
    }

    @Test func abLoopConfinesTheCacheAndClearingItReleasesIt() async throws {
        let (player, _, _) = try makePlayer()   // keyframes 0/250/500
        defer { player.close() }
        player.seek(toFrame: 320)
        player.perform(.abLoop)
        player.seek(toFrame: 300)
        player.perform(.abLoop)
        #expect(player.loopA == 300 && player.loopB == 320)
        player.seek(toFrame: 310)
        #expect(await eventually { (250...320).allSatisfy(player.cache.contains) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!player.cache.contains(321) && !player.cache.contains(249))
        player.perform(.abLoop)   // clears
        #expect(player.loopA == nil)
        #expect(await eventually { player.cache.contains(321) && player.cache.contains(249) })
    }

    @Test func abLoopAndRangeExport() async throws {
        let (player, delegate, root) = try makePlayer()
        defer { player.close() }
        player.seek(toFrame: 120)
        player.perform(.abLoop)
        player.seek(toFrame: 100)
        player.perform(.abLoop)
        #expect(player.loopA == 100)
        #expect(player.loopB == 120)
        player.perform(.exportRange)
        #expect(player.isExporting)
        #expect(await eventually(timeout: 30) { !player.isExporting })
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("h264_cfr_gop250").path)
        #expect(files.count == 21)
        #expect(delegate.messages.last == "Exported 21 frames")
    }

    @Test func exportWithoutRangeExplains() throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.perform(.exportRange)
        #expect(!player.isExporting)
        #expect(delegate.messages.last == "Set an A-B range first")
    }

    @Test func savesCurrentFrame() async throws {
        let (player, delegate, root) = try makePlayer()
        defer { player.close() }
        player.seek(toFrame: 42)
        let haptics = record(player)
        player.perform(.screenshot)
        let expected = root.appendingPathComponent("h264_cfr_gop250/h264_cfr_gop250_f000042_00-00-01.400.jpg")
        #expect(await eventually { FileManager.default.fileExists(atPath: expected.path) })
        #expect(await eventually { delegate.messages.last?.hasPrefix("Saved:") == true })
        #expect(haptics.events == [.done])
    }

    @Test func playsByClockAndLoops() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))

        player.perform(.cyclePause)
        #expect(!player.isPaused)
        #expect(await running(player))
        now += 1
        player.tick()
        #expect(player.position == 30)

        player.perform(.cyclePause)
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 10)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 1                       // would be frame 40, past B = 20
        player.tick()
        #expect(player.position == 10)
        #expect(await running(player))
        now += 0.2
        player.tick()
        #expect(player.position == 16)
    }

    @Test func speedAndVolumeCommands() throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.perform(.multiplySpeed(2))
        #expect(player.speed == 2)
        #expect(player.clock.rate == 2)
        player.perform(.setSpeed(1))
        player.perform(.addVolume(-10))
        #expect(player.volume == 90)
        player.perform(.cycleMute)
        #expect(player.isMuted)
        #expect(delegate.feedback == [.speed(2), .speed(1), .volume(90), .mute(true)])
        #expect(delegate.messages.isEmpty)        // the HUD carries these, not the text OSD
    }

    @Test func transportCommandsShowFeedback() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.perform(.cyclePause)
        player.perform(.cyclePause)
        player.perform(.seek(5, .exact))
        player.perform(.seek(-1, .exact))
        now += 10                                  // a new seek series
        player.perform(.revertSeek)
        player.perform(.frameStep)                 // frame steps: text only, no icon
        player.perform(.keyframeStep)
        #expect(delegate.feedback == [.play, .pause, .seek(5), .seek(-1), .revert])
    }

    @Test func goToJumpsToATimeOrAFrameAndCanBeReverted() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.goTo(.seconds(10.5))                 // 30 fps: frame 315
        #expect(player.position == 315)
        player.goTo(.frame(42))
        #expect(player.position == 42)
        #expect(delegate.messages.last?.hasPrefix("Frame 42 / 599") == true)
        player.goTo(.frame(10_000))                 // past the end: the last frame
        #expect(player.position == 599)
        player.goTo(.seconds(3600))
        #expect(player.position == 599)
        player.goTo(.frame(100))
        player.perform(.revertSeek)
        #expect(player.position == 599)             // each go-to is a jump of its own
    }

    @Test func holdingForSpeedPlaysFasterAndRestores() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.holdSpeed = 3 })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.multiplySpeed(1.5))
        player.beginHoldSpeed()                     // paused: plays while held
        #expect(!player.isPaused)
        #expect(player.speed == 3)
        player.beginHoldSpeed()                     // a second press while held changes nothing
        player.endHoldSpeed()
        #expect(player.isPaused)
        #expect(player.speed == 1.5)
        player.perform(.cyclePause)                 // playing: keeps playing after the hold
        player.beginHoldSpeed()
        player.endHoldSpeed()
        #expect(!player.isPaused)
        #expect(player.speed == 1.5)
        player.endHoldSpeed()                       // a stray release is ignored
        #expect(player.speed == 1.5)
    }

    // MARK: keep-speed

    @Test func speedCarriesToTheNextFile() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.perform(.stepSpeed(1))
        player.perform(.stepSpeed(1))
        #expect(player.speed == 1.5)
        delegate.feedback.removeAll()
        try player.open(Fixtures.url(Fixtures.h264))
        #expect(player.speed == 1.5 && player.direction == 1)
        #expect(player.clock.rate == 1.5)
        #expect(delegate.feedback == [.speed(1.5)])   // shown, so a faster file is no surprise
        player.perform(.setSpeed(1))
        delegate.feedback.removeAll()
        try player.open(Fixtures.url(Fixtures.h264))
        #expect(player.speed == 1 && player.clock.rate == 1)
        #expect(delegate.feedback.isEmpty)            // 1×: nothing to show
    }

    @Test func reverseAndShuttleSpeedDoNotCarry() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.shuttleBack)
        player.perform(.stepSpeed(1))                 // backward at 1.25×
        #expect(player.direction == -1 && player.speed == 1.25 && player.clock.rate == -1.25)
        try player.open(Fixtures.url(Fixtures.h264))
        #expect(player.direction == 1 && player.speed == 1.25 && player.clock.rate == 1.25)
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.shuttleForward)
        player.perform(.shuttleForward)
        #expect(player.speed == 2)                    // the shuttle's speed, not one the user chose with [ ]
        delegate.feedback.removeAll()
        try player.open(Fixtures.url(Fixtures.h264))
        #expect(player.speed == 1 && player.direction == 1 && player.clock.rate == 1)
        #expect(delegate.feedback.isEmpty)
    }

    @Test func holdSpeedDoesNotCarry() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.holdSpeed = 3 })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.stepSpeed(1))                 // 1.25
        player.beginHoldSpeed()                       // paused: plays at 3× while held
        #expect(player.speed == 3)
        try player.open(Fixtures.url(Fixtures.h264))
        #expect(player.speed == 1.25 && player.clock.rate == 1.25)
        #expect(player.isPaused)                      // autoplay is off: the hold's playing stays with the old file
        player.endHoldSpeed()                         // the key comes up after the open: nothing to put back
        #expect(player.speed == 1.25 && player.isPaused)
        player.beginHoldSpeed()                       // a new hold in the new file works as before
        #expect(player.speed == 3 && !player.isPaused)
        player.endHoldSpeed()
        #expect(player.speed == 1.25 && player.isPaused)
    }

    @Test func keepSpeedNoResetsOnOpen() async throws {
        let (player, delegate, _) = try makePlayer(configure: { $0.keepSpeed = false })
        defer { player.close() }
        player.perform(.stepSpeed(1))
        #expect(player.speed == 1.25)
        delegate.feedback.removeAll()
        try player.open(Fixtures.url(Fixtures.h264))
        #expect(player.speed == 1 && player.direction == 1 && player.clock.rate == 1)
        #expect(delegate.feedback.isEmpty)
    }

    /// The sound is set up beside the video: when it comes in it plays at the kept speed. Needs an audio device.
    @Test func keptSpeedReachesTheSound() async throws {
        let player = PlayerCore(config: Config(), enableAudio: true, fallbackRoot: makeTemporaryDirectory())
        defer { player.close() }
        try player.open(Fixtures.url(Fixtures.h264))   // no sound: 50× is allowed
        player.perform(.setSpeed(50))
        #expect(player.speed == 50)
        try player.open(Fixtures.url(Fixtures.withAudio))
        #expect(player.speed == AudioOutput.rateRange.upperBound)   // the sound's range from the start
        #expect(player.clock.rate == AudioOutput.rateRange.upperBound)
        player.perform(.setSpeed(1.5))
        try player.open(Fixtures.url(Fixtures.withAudio))
        #expect(player.speed == 1.5 && player.clock.rate == 1.5)
        guard await eventually(timeout: 3, { player.hasAudio }) else { return }   // no audio device here
        #expect(player.audioRate == 1.5)
        #expect(player.speed == 1.5 && player.clock.rate == 1.5)
    }

    @Test func reachingTheEndShowsStop() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 595)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 5
        player.tick()
        #expect(delegate.feedback.last == .endOfFile)
    }

    @Test func loopWithBAtLastFrameWrapsAtEnd() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 590)
        player.perform(.abLoop)
        player.seek(toFrame: 599)
        player.perform(.abLoop)
        #expect(player.loopA == 590 && player.loopB == 599)
        player.seek(toFrame: 590)
        player.perform(.cyclePause)
        #expect(!player.isPaused)
        #expect(await running(player))
        now += 1                       // well past the end of the file
        player.tick()
        #expect(player.position == 590)
        #expect(!player.isPaused)
    }

    @Test func playOnceStopsAtBAndStartsAgainFromA() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .once })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 10)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 1                       // would be frame 40, past B = 20
        player.tick()
        #expect(player.position == 20)
        #expect(player.isPaused)
        #expect(delegate.feedback.last == .pause)
        player.perform(.cyclePause)    // play again from B: the range starts over
        #expect(player.position == 10)
        #expect(!player.isPaused)
        #expect(await running(player))
        now += 0.2
        player.tick()
        #expect(player.position == 16)
    }

    @Test func playOnceFromPastBPlaysOn() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .once })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 30)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 1
        player.tick()
        #expect(player.position == 60)
        #expect(!player.isPaused)
    }

    @Test func playOnceWithBAtLastFrameStopsThereWithoutEndOfFile() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .once })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 590)
        player.perform(.abLoop)
        player.seek(toFrame: 599)
        player.perform(.abLoop)
        player.seek(toFrame: 590)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 1
        player.tick()
        #expect(player.position == 599)
        #expect(player.isPaused)
        #expect(!delegate.reachedEnd)
    }

    @Test func frameTextCountsFromA() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        #expect(!player.frameText.contains("A"))
        player.seek(toFrame: 100)
        player.perform(.abLoop)
        #expect(player.frameText.contains(" · A ") || player.frameText.hasSuffix(" · A"))
        player.seek(toFrame: 130)
        #expect(player.frameText.contains(" · A+30 f (1.00 s)"))
        player.seek(toFrame: 90)
        #expect(player.frameText.contains(" · A−10 f (−0.33 s)"))
        player.seek(toFrame: 160)
        player.perform(.abLoop)
        #expect(delegate.messages.last?.hasSuffix("(60 f, 2.00 s)") == true)
        #expect(player.statsText.contains("A-B: 00:00:03.333 – 00:00:05.333, 60 f (2.00 s), loop"))
        player.perform(.abLoop)
        #expect(!player.frameText.contains("A"))
        #expect(!player.statsText.contains("A-B:"))
    }

    @Test func showsDecodeErrorOnceAndInStats() async throws {
        let player = PlayerCore(config: Config(), enableAudio: false, fallbackRoot: makeTemporaryDirectory())
        let delegate = RecordingDelegate()
        player.delegate = delegate
        defer { player.close() }
        try player.open(Fixtures.url(Fixtures.noDecoder))
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("Decode error: ") } })
        player.seek(toFrame: 200)
        try await Task.sleep(for: .milliseconds(300))
        #expect(delegate.messages.filter { $0.hasPrefix("Decode error: ") }.count == 1)
        #expect(player.statsText.contains("Last decode error: "))
    }

    @Test func ignoresAnEmptyExactIndex() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.indexReady(FrameIndex(pts: [], keyframePTS: [], timeBase: 1.0 / 15360), session: player.session, status: .scanned(seconds: 0))
        #expect(player.frameCount == 600)
        player.seek(toFrame: 42)
        #expect(player.position == 42)
    }

    @Test func screenshotWhilePlayingSavesTheDisplayedFrame() async throws {
        var now = 1000.0
        let (player, delegate, root) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true && player.displayedFrame == 0 })
        player.perform(.cyclePause)
        now += 10                      // frame 300: not decoded yet, frame 0 stays on screen
        player.tick()
        #expect(player.position == 300)
        let shown = try #require(player.displayedFrame)
        #expect(shown != 300)
        player.perform(.screenshot)
        now += 0.1
        player.tick()
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("Saved:") } })
        #expect(!delegate.messages.contains("Save cancelled"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("h264_cfr_gop250").path)
        #expect(files.count == 1)
        #expect(files.first?.hasPrefix(String(format: "h264_cfr_gop250_f%06d_", shown)) == true)
    }

    @Test func speedRangeFollowsAudio() async throws {
        let player = PlayerCore(config: Config(), enableAudio: true, fallbackRoot: makeTemporaryDirectory())
        defer { player.close() }
        try player.open(Fixtures.url(Fixtures.withAudio))
        _ = await eventually(timeout: 3) { player.hasAudio }   // set up beside the video
        let range = player.hasAudio ? (1.0 / 32)...32 : 0.01...100   // no audio device: video-only limits
        player.perform(.setSpeed(100))
        #expect(player.speed == range.upperBound)
        #expect(player.clock.rate == range.upperBound)
        player.perform(.setSpeed(0.001))
        #expect(player.speed == range.lowerBound)

        try player.open(Fixtures.url(Fixtures.h264))
        #expect(!player.hasAudio)
        player.perform(.setSpeed(100))
        #expect(player.speed == 100)
        player.perform(.setSpeed(0.001))
        #expect(player.speed == 0.01)
    }

    @Test func pendingScreenshotIsCancelledWhenMovingAway() throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.seek(toFrame: 400)      // far from the cached window: still decoding
        player.perform(.screenshot)
        #expect(delegate.messages.last == "Saving…")
        player.perform(.screenshot)    // same pending frame: no-op
        #expect(delegate.messages.filter { $0 == "Saving…" }.count == 1)
        let haptics = record(player)
        player.seek(toFrame: 10)
        #expect(delegate.messages.last == "Save cancelled")
        #expect(haptics.events.isEmpty)   // from `tick`, outside any input: no `.error`
    }

    @Test func keyframeSeekLandsOnKeyframes() async throws {
        let (player, delegate, _) = try makePlayer(configure: { $0.seekMode = .keyframe })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.seek(5, .byConfig))
        #expect(player.position == 250)
        #expect(delegate.messages.last?.hasSuffix(" K") == true)
        player.perform(.seek(5, .exact))
        #expect(player.position == 400)
        player.perform(.seek(-5, .byConfig))
        #expect(player.position == 250)
        player.seekFromBar(toFrame: 480)
        #expect(player.position == 500)
    }

    @Test func barSeekOntoCurrentKeyframeStaysPut() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.seekMode = .keyframe })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seekFromBar(toFrame: 250)
        #expect(player.position == 250)
        for _ in 0..<3 {
            player.seekFromBar(toFrame: 250)
            #expect(player.position == 250)
        }
    }

    @Test func barDragOverOneSpotLandsOnTheSameKeyframe() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.seekMode = .keyframe })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        for frame in [20, 25, 30, 25, 20] {
            player.seekFromBar(toFrame: frame)
            #expect(player.position == 0)
        }
        for frame in [140, 130, 200, 130] {
            player.seekFromBar(toFrame: frame)
            #expect(player.position == 250)
        }
    }

    @Test func exactSeekModeKeepsFrameAccuracy() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.seekMode = .exact })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.seek(5, .byConfig))
        #expect(player.position == 150)
        player.perform(.seek(5, .keyframes))
        #expect(player.position == 250)
        player.seekFromBar(toFrame: 480)
        #expect(player.position == 480)
    }

    @Test func applyUpdatesSettingsLive() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        var config = player.config
        config.cacheSizeMiB = 100
        config.seekMode = .exact
        player.apply(config)
        #expect(player.cache.budgetBytes == 100 << 20)
        #expect(player.config.seekMode == .exact)
    }

    @Test func exportRangeUsesConfiguredSelection() async throws {
        let (player, delegate, root) = try makePlayer(configure: { $0.exportMode = .every; $0.exportEvery = 10 })
        defer { player.close() }
        player.seek(toFrame: 100)
        player.perform(.abLoop)
        player.seek(toFrame: 120)
        player.perform(.abLoop)
        #expect(player.exportCount(for: .every(10)) == 3)
        player.perform(.exportRange)
        #expect(await eventually(timeout: 30) { !player.isExporting })
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("h264_cfr_gop250").path)
        #expect(files.count == 3)
        #expect(delegate.messages.last == "Exported 3 frames")
    }

    @Test func sharpExportReportsSkippedWindows() async throws {
        let (player, delegate, root) = try makePlayer(configure: {
            $0.exportMode = .every
            $0.exportEvery = 10
            $0.exportSharp = true
            $0.exportSkipBlurry = true
        })
        defer { player.close() }
        player.seek(toFrame: 100)
        player.perform(.abLoop)
        player.seek(toFrame: 120)
        player.perform(.abLoop)
        player.perform(.exportRange)
        #expect(await eventually(timeout: 30) { !player.isExporting })
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("h264_cfr_gop250").path)
        #expect(delegate.messages.last == PlayerCore.exportSummary(ExportResult(written: files.count, blurry: 3 - files.count)))
    }

    /// A clip queue whose fake writer records its jobs and blocks until `release()`.
    private final class BlockingClips: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ClipJob] = []
        private let started = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        var jobs: [ClipJob] { lock.withLock { seen } }
        lazy var queue = ClipQueue { [self] job, _ in
            lock.withLock { seen.append(job) }
            started.signal()
            gate.wait()
            return ClipResult(url: job.directory.appendingPathComponent("x.mp4"), leadIn: 0)
        }
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 10) == .success }
        func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
    }

    private func setRange(_ player: PlayerCore, _ a: Int, _ b: Int) {
        player.seek(toFrame: a)
        player.perform(.abLoop)
        player.seek(toFrame: b)
        player.perform(.abLoop)
    }

    /// Marks frames `a`…`b` with I and O.
    private func setMark(_ player: PlayerCore, _ a: Int, _ b: Int) {
        player.seek(toFrame: a)
        player.perform(.markIn)
        player.seek(toFrame: b)
        player.perform(.markOut)
    }

    @Test func saveClipQueuesTheMarkAndClearsIt() async throws {
        let (player, delegate, root) = try makePlayer(configure: { $0.clipTemplate = "clip_%{start}"; $0.clipReadLimitMB = 7 })
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        #expect(await eventually { player.index?.isExact == true })
        let index = try #require(player.index)
        setRange(player, 10, 20)                       // the loop is not what c saves, and it stays
        setMark(player, 300, 400)
        player.perform(.saveClip)
        #expect(clips.waitUntilStarted())
        let job = try #require(clips.jobs.first)
        #expect(job.ranges == [ClipRange(startPTS: index.pts(forFrame: 300), endPTS: index.pts(forFrame: 400),
                                         keyframePTS: index.pts(forFrame: 250))])
        #expect(job.aFrame == 300)
        #expect(job.aSeconds == index.seconds(forFrame: 300))
        #expect(job.endSeconds == index.seconds(forFrame: 400))
        #expect(job.template == "clip_%{start}")
        #expect(job.readLimit == 7_000_000)
        #expect(job.directory.path == root.appendingPathComponent("h264_cfr_gop250").path)
        #expect(job.fallbackDirectory.path == root.appendingPathComponent("fallback/h264_cfr_gop250").path)
        #expect(player.marks.isEmpty)
        #expect(player.loopA == 10 && player.loopB == 20)
        #expect(delegate.messages.last == "Clip queued")

        setMark(player, 100, 120)
        player.perform(.saveClip)
        #expect(delegate.messages.last == "Clip queued · 1 waiting")
        clips.release(2)
    }

    @Test func saveClipWithoutMarks() throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        setRange(player, 10, 20)
        player.perform(.saveClip)
        #expect(delegate.messages.last == "Mark a range first")
        #expect(clips.queue.waitingCount == 0 && !clips.queue.isBusy)
    }

    @Test func marksAreSetMovedDeletedAndUndone() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.markIn)
        #expect(delegate.messages.last == "Mark 1 in: 00:00:10.000 · clip starts 1.67 s earlier")
        player.seek(toFrame: 400)
        player.perform(.markOut)
        #expect(delegate.messages.last == "Mark 1: 00:00:10.000 – 00:00:13.333 (3.33 s)")
        #expect(player.marks.segments == [CutSegment(start: 300, end: 400)])
        player.perform(.markSnap)   // at 400, inside: start 300 → keyframe 250 (500 is past the end)
        #expect(player.marks.segments[0].start == 250)
        #expect(delegate.messages.last == "Mark 1 in: 00:00:08.333 (keyframe)")
        #expect(player.frameText.contains(" · mark 1/1"))
        #expect(player.statsText.contains("Marks: 1 · 00:00:05.000 total"))
        player.undoMarks()
        #expect(player.marks.segments[0].start == 300)
        #expect(delegate.messages.last == "Undo: Mark 1 in: 00:00:08.333 (keyframe)")
        player.redoMarks()
        #expect(player.marks.segments[0].start == 250 && delegate.messages.last?.hasPrefix("Redo: ") == true)
        player.perform(.markDelete)
        #expect(player.marks.isEmpty && delegate.messages.last == "Mark 1 deleted")
        player.perform(.markDelete)
        #expect(delegate.messages.last == "No mark here")
        #expect(player.canUndoMarks && !player.canRedoMarks)
    }

    @Test func markEdgesLoopAndClear() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 100, 150)
        setMark(player, 300, 350)
        player.seek(toFrame: 200)
        player.perform(.markNext)
        #expect(await eventually { player.position == 300 })
        player.perform(.markPrev)
        #expect(await eventually { player.position == 150 })
        player.seek(toFrame: 0)
        player.perform(.markPrev)
        #expect(delegate.messages.last == "No mark before")
        player.perform(.markLoop)
        #expect(delegate.messages.last == "Set an A-B range first")
        setRange(player, 500, 550)
        player.perform(.markLoop)
        #expect(player.marks.segments.count == 3 && player.loopA == 500)
        player.perform(.markClear)
        #expect(player.marks.isEmpty && delegate.messages.last == "All marks deleted (3)")
    }

    // MARK: Edge drag

    @Test func edgeDragMovesTheStartWithThePlayheadAndCommitsAsOneUndo() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 300, 400)
        player.seek(toFrame: 300)
        player.scrubEdge(.start, by: -10)
        #expect(player.position == 290 && player.marks.segments == [CutSegment(start: 290, end: 400)])
        #expect(player.edgeDrag?.original.segments == [CutSegment(start: 300, end: 400)])
        player.scrubEdge(.start, by: -5)
        #expect(player.position == 285 && player.marks.segments == [CutSegment(start: 285, end: 400)])
        player.endEdgeDrag()
        #expect(player.edgeDrag == nil)
        #expect(delegate.messages.last == "Start 00:00:09.500 · f285")
        player.undoMarks()
        #expect(player.marks.segments == [CutSegment(start: 300, end: 400)])
        #expect(delegate.messages.last == "Undo: Mark start moved")
        player.undoMarks()   // the next step back is O, not a part of the drag
        #expect(player.marks.segments.isEmpty && player.marks.open == 300)
    }

    @Test func edgeDragMovesTheEnd() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 300, 400)
        player.seek(toFrame: 400)
        player.scrubEdge(.end, by: 20)
        player.endEdgeDrag()
        #expect(player.position == 420 && player.marks.segments == [CutSegment(start: 300, end: 420)])
        #expect(delegate.messages.last == "End 00:00:14.000 · f420")
        player.undoMarks()
        #expect(delegate.messages.last == "Undo: Mark end moved")
    }

    @Test func cancelledEdgeDragPutsTheMarkBackWithoutHistory() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 300, 400)
        player.seek(toFrame: 350)
        player.scrubEdge(.end, by: 20)
        #expect(player.marks.segments == [CutSegment(start: 300, end: 370)])
        player.cancelEdgeDrag()
        #expect(player.edgeDrag == nil && player.marks.segments == [CutSegment(start: 300, end: 400)])
        player.cancelEdgeDrag()   // no drag: nothing
        player.endEdgeDrag()
        #expect(player.marks.segments == [CutSegment(start: 300, end: 400)])
        player.undoMarks()        // straight to O
        #expect(player.marks.segments.isEmpty && player.marks.open == 300)
        #expect(player.canUndoMarks)
    }

    @Test func edgeDragStopsAtTheNeighbourAndKeepsItsEdge() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 100, 150)
        setMark(player, 300, 350)
        player.seek(toFrame: 300)
        let haptics = record(player)
        player.scrubEdge(.start, by: -200)
        #expect(player.position == 152 && player.marks.segments[1].start == 152)   // a frame before the neighbour
        #expect(haptics.events == [.keyframe, .limit])   // passed keyframe 250, then the bound
        player.scrubEdge(.start, by: -10)
        #expect(player.position == 152 && player.marks.segments[1].start == 152)
        #expect(haptics.events == [.keyframe, .limit])   // pushing against the bound: no second limit
        player.scrubEdge(.end, by: 5)   // the drag keeps the edge it began with
        #expect(player.position == 157 && player.marks.segments == [CutSegment(start: 100, end: 150),
                                                                     CutSegment(start: 157, end: 350)])
        player.scrubEdge(.start, by: 500)
        #expect(player.position == 349 && player.marks.segments[1] == CutSegment(start: 349, end: 350))
        #expect(haptics.events.filter { $0 == .limit }.count == 2)   // away and back: a new arrival
    }

    @Test func edgeDragWithoutASegmentScrubsThenMarks() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 300, 400)
        player.seek(toFrame: 200)
        player.scrubEdge(.start, by: 10)
        #expect(player.position == 210 && player.marks.segments == [CutSegment(start: 300, end: 400)])
        player.endEdgeDrag()
        #expect(player.marks.open == 210 && delegate.messages.last?.hasPrefix("Mark 1 in: 00:00:07.000") == true)
        player.seek(toFrame: 450)
        player.scrubEdge(.end, by: 10)
        player.endEdgeDrag()   // O closes the open start at the final frame
        #expect(player.marks.segments == [CutSegment(start: 210, end: 460)])
    }

    @Test func aMarkEditCancelsTheEdgeDragFirst() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 100, 150)
        setMark(player, 300, 400)
        player.seek(toFrame: 400)
        player.scrubEdge(.end, by: -10)
        #expect(player.marks.segments[1] == CutSegment(start: 300, end: 390))
        player.perform(.markDelete)
        #expect(player.edgeDrag == nil && delegate.messages.last == "Mark 2 deleted")
        #expect(player.marks.segments == [CutSegment(start: 100, end: 150)])
        player.scrubEdge(.end, by: -5)   // the button is still held: a new drag, here a plain scrub
        #expect(player.position == 385 && player.marks.segments == [CutSegment(start: 100, end: 150)])
        player.cancelEdgeDrag()
        #expect(player.marks.segments == [CutSegment(start: 100, end: 150)])
        player.undoMarks()               // the delete is one step, of the marks before the drag
        #expect(player.marks.segments == [CutSegment(start: 100, end: 150), CutSegment(start: 300, end: 400)])
        #expect(delegate.messages.last == "Undo: Mark 2 deleted")
    }

    @Test func undoDuringAnEdgeDragCancelsItFirst() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 300, 400)
        player.seek(toFrame: 300)
        player.scrubEdge(.start, by: -10)
        player.undoMarks()               // one real step: O of the marks before the drag
        #expect(player.edgeDrag == nil && player.marks.segments.isEmpty && player.marks.open == 300)
        #expect(delegate.messages.last == "Undo: Mark 1: 00:00:10.000 – 00:00:13.333 (3.33 s)")
        player.endEdgeDrag()             // the button's release: no drag left, nothing recorded
        #expect(player.canRedoMarks)
        player.redoMarks()
        #expect(player.marks.segments == [CutSegment(start: 300, end: 400)] && player.marks.open == nil)
    }

    @Test func openingAnotherFileCancelsTheEdgeDrag() throws {
        let store = temporaryStore()
        let (player, _, _) = try makePlayer(resumeStore: store)
        defer { player.close() }
        setMark(player, 100, 150)
        player.seek(toFrame: 100)
        player.scrubEdge(.start, by: -10)
        #expect(player.marks.segments == [CutSegment(start: 90, end: 150)])
        try player.open(Fixtures.url(Fixtures.withAudio))
        #expect(player.edgeDrag == nil)
        try player.open(Fixtures.url(Fixtures.h264))   // the remembered marks are the ones before the drag
        #expect(player.marks.segments == [CutSegment(start: 100, end: 150)])
    }

    @Test func cQueuesOneJobPerSegmentAndClearsTheMarks() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 100, 150)
        setMark(player, 300, 350)
        player.perform(.saveClip)   // clip-mode=separate
        #expect(delegate.messages.last == "2 clips queued")
        #expect(player.marks.isEmpty)
        #expect(clips.waitUntilStarted())
        #expect(clips.queue.remainingCount == 2)
        player.undoMarks()
        #expect(player.marks.segments.count == 2)
        clips.release(2)
    }

    @Test func joinedAndInvertedAreOneJob() async throws {
        let (player, delegate, _) = try makePlayer(configure: { $0.clipTemplate = "c" })
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        #expect(await eventually { player.index?.isExact == true })
        let index = try #require(player.index)
        setMark(player, 100, 150)
        setMark(player, 300, 350)
        player.saveMarks(.joined)
        #expect(delegate.messages.last == "Joined clip queued")
        #expect(clips.waitUntilStarted())
        #expect(clips.jobs[0].template == "c_joined" && clips.jobs[0].ranges.count == 2)
        clips.release()
        setMark(player, 100, 150)
        setMark(player, 300, 350)
        player.saveMarks(.inverted)
        #expect(clips.waitUntilStarted())
        let inverted = clips.jobs[1]
        #expect(inverted.template == "c_cut")
        // 0…99, then from the first keyframe after 150 (250) to 299, then after 350 (500) to the end.
        #expect(inverted.ranges.map(\.startPTS) == [0, 250, 500].map(index.pts(forFrame:)))
        #expect(inverted.ranges.map(\.endPTS) == [99, 299, 599].map(index.pts(forFrame:)))
        clips.release()
    }

    @Test func clipSummaryCountsTheLeadIns() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        #expect(player.clipSummary() == nil)
        setMark(player, 300, 400)                       // keyframe 250: 50 frames of lead-in
        player.seek(toFrame: 510)
        player.perform(.markIn)
        player.seek(toFrame: 530)                       // the open mark counts, closed here; keyframe 500: 10 frames
        let summary = try #require(player.clipSummary())
        #expect(summary.segments == 2 && summary.separateClips == 2)
        #expect(abs(summary.separateLeadIn - 2) < 0.001 && abs(summary.separateSeconds - 6) < 0.001)
        #expect(abs(summary.joinedLeadIn - 2) < 0.001 && abs((summary.joinedSeconds ?? 0) - 6) < 0.001)
        // Outside: 0…299 and 500…509 (after 530 there is no keyframe to start on).
        #expect(abs((summary.invertedSeconds ?? 0) - 308.0 / 30) < 0.001)
    }

    @Test func invertedNeedsTheExactIndex() throws {
        let (player, delegate, _) = try makePlayer(beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        setMark(player, 10, 20)
        player.saveMarks(.inverted)
        #expect(delegate.messages.last == "Wait for the index to finish")
        #expect(player.marks.segments.count == 1 && !clips.queue.isBusy)
        setMark(player, 40, 50)
        #expect(player.clipSummary()?.joinedSeconds == nil && player.clipSummary()?.invertedSeconds == nil)
        player.saveMarks(.joined)      // two segments might share a keyframe nobody knows yet
        #expect(delegate.messages.last == "Wait for the index to finish")
        #expect(player.marks.segments.count == 2 && !clips.queue.isBusy)
    }

    @Test func anOpenMarkIsClosedAtThePlayheadOnSave() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        #expect(await eventually { player.index?.isExact == true })
        let index = try #require(player.index)
        player.seek(toFrame: 100)
        player.perform(.markIn)
        player.seek(toFrame: 200)
        player.perform(.saveClip)
        #expect(clips.waitUntilStarted())
        #expect(clips.jobs[0].endPTS == index.pts(forFrame: 200))
        #expect(delegate.messages.last == "Clip queued")
        setMark(player, 400, 450)
        player.seek(toFrame: 300)
        player.perform(.markIn)
        player.seek(toFrame: 250)
        player.perform(.saveClip)
        #expect(delegate.messages.last == "Clip queued · 1 waiting\nOpen mark left out")
        #expect(player.marks.open == 300 && player.marks.segments.isEmpty)
        clips.release(2)
    }

    @Test func playMarksJumpsOverTheGapsAndStopsAfterTheLast() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        setMark(player, 10, 20)
        setMark(player, 100, 110)
        player.seek(toFrame: 0)
        player.perform(.playMarks)
        #expect(player.playMarksOnly && delegate.messages.last == "Play marks only: on")
        player.perform(.cyclePause)
        #expect(player.position == 10)
        #expect(await running(player))
        now += 0.5                     // frame 25, past 20: on to the next segment
        player.tick()
        #expect(player.position == 100)
        #expect(await running(player))
        now += 1                       // past 110, the last one
        player.tick()
        #expect(player.position == 110 && player.isPaused)
        player.perform(.cyclePause)    // play again from the end of the last: the marks start over
        #expect(player.position == 10 && !player.isPaused)
        player.perform(.playMarks)
        #expect(!player.playMarksOnly && delegate.messages.last == "Play marks only: off")
    }

    @Test func playMarksFromPastTheLastStartsAtTheFirst() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 10, 20)
        player.seek(toFrame: 300)
        player.perform(.cyclePause)
        player.perform(.playMarks)     // switched on while playing
        #expect(player.position == 10 && !player.isPaused)
    }

    @Test func playMarksIgnoresTheLoop() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        setRange(player, 12, 14)
        setMark(player, 10, 20)
        player.seek(toFrame: 10)
        player.perform(.playMarks)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 0.2                     // frame 16: past B = 14, but the loop does not act
        player.tick()
        #expect(player.position == 16)
    }

    @Test func playMarksWithoutMarksStaysOff() throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.perform(.playMarks)
        #expect(!player.playMarksOnly && delegate.messages.last == "No marks to play")
    }

    @Test func marksAreRememberedWithThePosition() throws {
        let store = temporaryStore()
        let (player, _, _) = try makePlayer(resumeStore: store)
        setMark(player, 100, 150)
        player.seek(toFrame: 300)
        player.perform(.markIn)
        player.close()
        let (again, _, _) = try makePlayer(resumeStore: store)
        defer { again.close() }
        #expect(again.marks == CutMarks(segments: [CutSegment(start: 100, end: 150)], open: 300))
    }

    @Test func marksFollowTheExactIndex() async throws {
        let (player, _, _) = try makePlayer(beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        try player.open(Fixtures.url(Fixtures.vfr))
        let approximate = try #require(player.index)
        setMark(player, 40, 80)
        let pts = [40, 80].map(approximate.pts(forFrame:))
        let exact = try MediaSource(url: Fixtures.url(Fixtures.vfr)).buildIndex()
        player.indexReady(exact, session: player.session, status: .scanned(seconds: 0))
        let segment = try #require(player.marks.segments.first)
        #expect([segment.start, segment.end] == pts.map(exact.nearestFrameNumber(forPTS:)))
        #expect(segment.start != 40 || segment.end != 80)   // the VFR file numbers its frames differently
    }

    @Test func clipSavedMessageMentionsTheLeadInOnlyWhenItMatters() {
        #expect(PlayerCore.clipSavedMessage(name: "x.mp4", leadIn: 1.43) == "Clip saved: x.mp4 (+1.4 s before A)")
        #expect(PlayerCore.clipSavedMessage(name: "x.mp4", leadIn: 0.03) == "Clip saved: x.mp4")
    }

    @Test func statsShowClips() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        let clips = BlockingClips()
        player.clipQueue = clips.queue
        #expect(!player.statsText.contains("Clips:"))
        setMark(player, 300, 400)
        player.perform(.saveClip)
        #expect(clips.waitUntilStarted())
        setMark(player, 100, 120)
        player.perform(.saveClip)
        #expect(player.statsText.contains("Clips: saving 1 · 1 waiting"))
        clips.release(2)
    }

    @Test func exportSummaryNamesWhatWasSkipped() {
        #expect(PlayerCore.exportSummary(ExportResult(written: 52)) == "Exported 52 frames")
        #expect(PlayerCore.exportSummary(ExportResult(written: 1, blurry: 3)) == "Exported 1 frame, 3 blurry skipped")
        #expect(PlayerCore.exportSummary(ExportResult(written: 52, blurry: 33, duplicates: 140))
                == "Exported 52 frames, 33 blurry and 140 duplicates skipped")
        #expect(PlayerCore.exportSummary(ExportResult(written: 2, duplicates: 1)) == "Exported 2 frames, 1 duplicate skipped")
    }

    @Test func statsShowTheSharpnessOfTheShownFrame() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index != nil && player.cache.frame(player.position) != nil })
        #expect(player.statsText.contains("Sharpness: "))
        #expect(await eventually { player.statsText.range(of: #"Sharpness: \d+"#, options: .regularExpression) != nil })
    }

    @Test func screenshotUsesSaveScale() async throws {
        let (player, delegate, root) = try makePlayer(configure: { $0.saveScale = 2; $0.saveUpscaler = .lanczos })
        defer { player.close() }
        player.seek(toFrame: 5)
        player.perform(.screenshot)
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("Saved:") } })
        let directory = root.appendingPathComponent("h264_cfr_gop250")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        #expect(files[0].hasSuffix("_x2.jpg"))
    }

    @Test(.disabled(if: isVirtualMachine, "a VM has no frame processor: the network reports ready, then fails"))
    func osdMentionsLanczosWhenTheNetworkCannotBeUsed() async throws {
        let (player, delegate, _) = try makePlayer(configure: { $0.saveScale = 2; $0.saveUpscaler = .ml })
        defer { player.close() }
        player.seek(toFrame: 5)
        player.perform(.screenshot)    // 1920 px source: fits the network, so this fails only without the model
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("Saved:") } })
        let message = try #require(delegate.messages.last { $0.hasPrefix("Saved:") })
        if MLUpscaler.availability(width: 1920, height: 1080) == .ready {
            #expect(!message.contains("Upscaled with Lanczos"))
        } else {
            #expect(message.contains("Upscaled with Lanczos (model not downloaded)"))
        }
    }

    @Test func screenshotFitsTheScreenOnceItsSizeIsKnown() async throws {
        let (player, delegate, root) = try makePlayer(configure: { $0.saveScale = .fitScreen; $0.saveUpscaler = .lanczos })
        defer { player.close() }
        player.screenPixelSize = CGSize(width: 2560, height: 1440)
        player.seek(toFrame: 5)
        player.perform(.screenshot)
        #expect(await eventually { delegate.messages.contains { $0.hasPrefix("Saved:") } })
        let directory = root.appendingPathComponent("h264_cfr_gop250")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        #expect(file.hasSuffix("_2560x1440.jpg"))
    }

    @Test func statsShowSeekReadAndIndexLines() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.seek(5, .byConfig))
        #expect(await eventually { player.seekTimer.recent.count == 1 })
        #expect(player.statsText.contains("Seek: "))
        #expect(player.statsText.contains("Read cache: "))
        #expect(player.statsText.contains("Index: container ("))
    }

    @Test func memoryPressureAlsoShrinksTheReadCache() throws {
        let (player, _, _) = try makePlayer(configure: { $0.readCacheMiB = 256 })
        defer { player.close() }
        player.setMemoryPressureFactor(0.25)
        #expect(player.readCache?.budgetBytes == 64 << 20)
    }

    @Test func mp4IndexComesFromTheContainer() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        guard case .container = player.indexStatus else { Issue.record("\(player.indexStatus)"); return }
    }

    @Test func keyframeSeekLandsWithoutAnExactIndex() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.seekMode = .keyframe }, beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        player.perform(.seek(5, .byConfig))                 // target 150 → lands on 250
        #expect(await eventually { player.position == 250 })
        #expect(player.index?.isExact == false)
        player.perform(.seek(-1, .byConfig))                // never against the direction
        #expect(await eventually { player.position == 0 })
    }

    @Test func aSeekSeriesShowsFramesOnTheWayAndNeverBackwards() async throws {
        let (player, delegate, _) = try makePlayer(configure: { $0.seekMode = .exact; $0.cacheSizeMiB = 64 })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true && player.displayedFrame == 0 })
        let start = delegate.frames.count
        for _ in 0..<12 {
            player.perform(.seek(1, .byConfig))
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually { player.displayedFrame == player.position })
        let shown = delegate.frames[start...].map(\.number)
        #expect(shown.count >= 2)                    // something on the way, then the target
        #expect(shown == shown.sorted())             // forward only
        #expect(shown.last == player.position)
    }

    @Test func keyframeStepsMoveBetweenKeyframes() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.keyframeStep)
        #expect(player.position == 250)
        #expect(delegate.messages.last?.contains(" · K") == true)
        player.perform(.keyframeStep)
        #expect(player.position == 500)
        player.perform(.keyframeBackStep)
        #expect(player.position == 250)
        player.perform(.seek(1, .exact))
        player.perform(.keyframeBackStep)                  // from inside a GOP: its own keyframe
        #expect(player.position == 250)
        player.perform(.keyframeBackStep)
        player.perform(.keyframeBackStep)                  // nothing before frame 0
        #expect(player.position == 0)
    }

    @Test func keyframeStepWorksBeforeTheExactIndex() async throws {
        let (player, _, _) = try makePlayer(beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        player.perform(.keyframeStep)
        #expect(await eventually { player.position == 250 })
        #expect(player.index?.isExact == false)
    }

    @Test func revertSeekGoesBackAndForth() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.revertSeek)                        // nothing to revert yet
        #expect(player.position == 0)
        player.perform(.seek(5, .exact))
        #expect(player.position == 150)
        player.perform(.frameStep)                         // steps do not count as seeks
        #expect(player.position == 151)
        player.perform(.revertSeek)
        #expect(player.position == 0)
        player.perform(.revertSeek)
        #expect(player.position == 151)
    }

    @Test func aQuickSeekSeriesRevertsToWhereItStarted() async throws {
        var clock = 100.0
        let (player, _, _) = try makePlayer(now: { clock })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.perform(.seek(5, .exact))
        clock += 0.3
        player.perform(.seek(5, .exact))                   // same series: the origin stays at 0
        #expect(player.position == 300)
        clock += 2
        player.perform(.seek(-1, .exact))                  // a new series starts at 300
        player.perform(.revertSeek)
        #expect(player.position == 300)
        player.perform(.revertSeek)
        #expect(player.position == 270)
    }

    @Test func frameStepShowsTheFrameType() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true && player.displayedFrame == 0 })
        player.perform(.frameStep)
        #expect(await eventually { delegate.messages.last.map { $0.hasPrefix("Frame 1 ") && ($0.contains(" · B") || $0.contains(" · P")) } == true })
        player.perform(.frameBackStep)
        #expect(await eventually { delegate.messages.last?.hasPrefix("Frame 0 ") == true })
        #expect(delegate.messages.last?.contains(" · K") == true)
    }

    @Test func hwdecPicksTheDecoderAndAppliesWhileRunning() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.statsText.contains("Decoder: h264 (VideoToolbox)") })
        var config = player.config
        config.hwdec = .no
        player.apply(config)
        player.seek(toFrame: 400)
        #expect(await eventually { player.statsText.contains("Decoder: h264 (software)") })
        #expect(await eventually { player.displayedFrame == 400 })
    }

    // MARK: Reverse playback (reverse playback spec §2–3)

    @Test func playsBackwardAndStopsAtTheStart() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 60)
        // The clock starts with the first picture on screen: a slow machine may not have shown frame 60 yet.
        #expect(await eventually { self.shownNumber(delegate) == 60 })
        let shownBefore = delegate.frames.count
        player.perform(.shuttleBack)
        #expect(!player.isPaused && player.direction == -1 && player.speed == 1)
        #expect(delegate.feedback.last == .speed(-1))
        now += 1
        player.tick()
        #expect(player.position == 30)
        #expect(await eventually { player.tick(); return self.shownNumber(delegate) == 30 })
        let shown = delegate.frames[shownBefore...].map { readFrameNumber($0.pixelBuffer) }
        #expect(shown == shown.sorted(by: >), "frames shown out of order: \(shown)")
        now += 2
        player.tick()
        #expect(player.position == 0 && player.isPaused)
        #expect(delegate.messages.last == "Start of file")
    }

    @Test func shuttleKeysFollowTheTable() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.shuttleForward)
        #expect(!player.isPaused && player.direction == 1 && player.speed == 1)
        player.perform(.shuttleForward)
        #expect(player.speed == 2 && player.clock.rate == 2)
        player.perform(.shuttleBack)
        #expect(player.direction == -1 && player.speed == 1 && player.clock.rate == -1)
        player.perform(.shuttleBack)
        #expect(player.speed == 2 && player.clock.rate == -2)
        player.perform(.shuttleStop)
        #expect(player.isPaused)
        player.perform(.cyclePause)   // resumes the last direction at 1×
        #expect(!player.isPaused && player.direction == -1 && player.speed == 1)
        player.perform(.multiplySpeed(2))
        #expect(player.direction == -1 && player.clock.rate == -2)
    }

    @Test func pingPongTurnsAtBothEnds() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .pingPong })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 10)
        player.perform(.cyclePause)
        #expect(await running(player))
        now += 0.5                     // frame 25, past B
        player.tick()
        #expect(player.position == 20 && player.direction == -1 && !player.isPaused)
        #expect(await running(player))
        now += 0.5                     // 15 frames back from B: frame 5, below A
        player.tick()
        #expect(player.position == 10 && player.direction == 1 && !player.isPaused)
    }

    @Test func loopBackwardJumpsToB() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 15)
        player.perform(.shuttleBack)
        #expect(await running(player))
        now += 0.3                     // frame 6, below A
        player.tick()
        #expect(player.position == 20 && player.direction == -1 && !player.isPaused)
    }

    @Test func onceBackwardPausesOnAAndStartsAgainFromB() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .once })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 15)
        player.perform(.shuttleBack)
        #expect(await running(player))
        now += 0.3
        player.tick()
        #expect(player.position == 10 && player.isPaused)
        player.perform(.cyclePause)    // backward again from A: the range starts over at B
        #expect(player.position == 20 && !player.isPaused && player.direction == -1)
    }

    @Test func playMarksOnlyBackward() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        setMark(player, 10, 20)
        setMark(player, 40, 50)
        player.perform(.playMarks)
        player.seek(toFrame: 45)
        player.perform(.shuttleBack)
        #expect(await running(player))
        now += 0.2                     // frame 39, below the mark 40…50
        player.tick()
        #expect(player.position == 20 && !player.isPaused)
        #expect(await running(player))
        now += 0.4                     // 12 frames back from 20: below the first mark
        player.tick()
        #expect(player.position == 10 && player.isPaused)
        player.seek(toFrame: 30)
        player.perform(.shuttleBack)   // from a gap backward: the end of the mark below
        #expect(player.position == 20)
    }

    @Test func pauseAfterReverseStepsWithoutWaiting() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 300)
        player.perform(.shuttleBack)
        #expect(await running(player))
        now += 1
        player.tick()
        #expect(player.position == 270)
        player.perform(.shuttleStop)
        #expect(player.isPaused)
        #expect(await eventually { player.cache.contains(271) && player.cache.contains(269) })
        player.perform(.frameStep)
        #expect(player.displayedFrame == 271)
        #expect(self.shownNumber(delegate) == 271)
    }

    @Test func holdSpeedWhileBackwardRestoresBackward() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.shuttleBack)
        player.beginHoldSpeed()
        #expect(player.speed == player.config.holdSpeed && player.direction == -1 && player.clock.rate == -player.config.holdSpeed)
        player.endHoldSpeed()
        #expect(player.speed == 1 && player.direction == -1 && !player.isPaused && player.clock.rate == -1)
    }

    @Test func frameStepWhilePlayingBackwardPauses() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.shuttleBack)
        player.perform(.frameBackStep)
        #expect(player.isPaused && player.position == 299)
    }

    @Test func clockIgnoresAudioWhileBackward() {
        var now = 0.0
        let clock = PlaybackClock(now: { now })
        clock.audioSeconds = { 5 }
        clock.followsAudio = false
        clock.rate = -1
        clock.start(at: 10)
        now += 1
        #expect(clock.seconds == 9)
        clock.followsAudio = true
        #expect(clock.seconds == 5)
    }

    // MARK: Reverse playback, final review fixes

    @Test func farSeekWhilePlayingNeverShowsAnOldFrame() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 100)
        player.perform(.cyclePause)
        #expect(await eventually { player.cache.contains(130) })
        now += 0.1
        player.tick()
        player.seek(toFrame: 500)
        now += 0.1
        player.tick()
        let shown = shownNumber(delegate) ?? 0
        #expect(!(110...499).contains(shown), "showed frame \(shown) from the old place")
    }

    @Test func playMarksOnWhileBackwardGoesToTheMarkBelow() async throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 100, 200)
        setMark(player, 400, 500)
        player.seek(toFrame: 350)
        player.perform(.shuttleBack)
        player.perform(.playMarks)
        #expect(player.position == 200)
    }

    @Test func releasingHoldKeepsAPingPongTurn() async throws {
        var now = 1000.0
        let (player, _, _) = try makePlayer(now: { now }, configure: { $0.abLoop = .pingPong })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 10)
        player.perform(.abLoop)
        player.seek(toFrame: 20)
        player.perform(.abLoop)
        player.seek(toFrame: 10)
        player.perform(.cyclePause)
        #expect(await running(player))
        player.beginHoldSpeed()        // 2×
        now += 0.3                     // frame 28, past B
        player.tick()
        #expect(player.direction == -1)
        player.endHoldSpeed()
        #expect(player.direction == -1 && player.speed == 1 && !player.isPaused)
    }

    @Test func seekWhilePlayingBackwardKeepsGoingBackward() async throws {
        var now = 1000.0
        let (player, delegate, _) = try makePlayer(now: { now })
        defer { player.close() }
        #expect(await ready(player))
        player.seek(toFrame: 300)
        player.perform(.shuttleBack)
        player.seek(toFrame: 150)
        #expect(player.direction == -1 && !player.isPaused)
        #expect(await eventually { player.tick(); return self.shownNumber(delegate) == 150 })
        now += 0.5
        player.tick()
        #expect(player.position == 135)
    }

    // MARK: Speed step

    @Test func speedStepsByAQuarterOnTheGrid() async throws {
        let (player, delegate, _) = try makePlayer()
        defer { player.close() }
        player.perform(.stepSpeed(1))
        #expect(player.speed == 1.25 && delegate.feedback.last == .speed(1.25))
        player.perform(.stepSpeed(1))
        #expect(player.speed == 1.5)
        player.perform(.stepSpeed(-1))
        #expect(player.speed == 1.25)
        player.perform(.multiplySpeed(1.1 / 1.25))   // 1.1×: between steps
        player.perform(.stepSpeed(1))
        #expect(abs(player.speed - 1.25) < 1e-9)
        player.perform(.setSpeed(0.5))
        player.perform(.stepSpeed(-1))
        #expect(player.speed == 0.25)
        player.perform(.stepSpeed(-1))   // never below one step
        #expect(player.speed == 0.25)
    }

    @Test func speedStepFollowsTheSettingAndKeepsTheDirection() async throws {
        let (player, _, _) = try makePlayer(configure: { $0.speedStep = 0.1 })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        player.seek(toFrame: 300)
        player.perform(.shuttleBack)
        player.perform(.stepSpeed(1))
        #expect(abs(player.speed - 1.1) < 1e-9 && player.direction == -1 && abs(player.clock.rate + 1.1) < 1e-9)
    }

    // MARK: Haptics

    private func record(_ player: PlayerCore) -> HapticLog {
        let log = HapticLog()
        player.onHaptic = { log.events.append($0) }
        player.onSeekHaptic = { log.seekSteps.append($0) }
        return log
    }

    @Test func speedStepsPlayADetentAt1xAndALimitAtTheEnds() throws {
        let (player, _, _) = try makePlayer(configure: { $0.speedStep = 0.1 })
        defer { player.close() }
        player.perform(.setSpeed(0.9))
        let haptics = record(player)
        player.perform(.stepSpeed(1))                 // 0.9 → 1.0: onto 1×
        #expect(haptics.events == [.detent])
        player.perform(.stepSpeed(1))                 // 1.0 → 1.1: away from it
        #expect(haptics.events == [.detent, .step])
        player.perform(.setSpeed(1.05))               // between steps: down onto 1×, then away from it
        haptics.events.removeAll()
        player.perform(.stepSpeed(-1))
        player.perform(.stepSpeed(-1))
        #expect(haptics.events == [.detent, .step] && abs(player.speed - 0.9) < 1e-9)
        player.perform(.setSpeed(0.1))
        haptics.events.removeAll()
        player.perform(.stepSpeed(-1))                // the lowest step of the grid
        #expect(haptics.events == [.limit] && abs(player.speed - 0.1) < 1e-9)
        player.perform(.setSpeed(100))
        haptics.events.removeAll()
        player.perform(.stepSpeed(1))                 // past the speed range
        #expect(haptics.events == [.limit] && player.speed == 100)
    }

    @Test func volumeStepsAndLimits() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        let haptics = record(player)
        #expect(player.volume == 100)
        player.perform(.addVolume(2))
        #expect(haptics.events == [.limit])
        player.perform(.addVolume(-2))
        #expect(haptics.events == [.limit, .step] && player.volume == 98)
        player.perform(.addVolume(-200))
        #expect(haptics.events == [.limit, .step, .limit] && player.volume == 0)
    }

    @Test func aStepAgainstTheLastFrameBumpsOncePerPush() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        player.seek(toFrame: 599)
        let haptics = record(player)
        player.inputIsFresh = true
        player.perform(.frameStep)
        #expect(haptics.events == [.end] && player.position == 599)
        player.inputIsFresh = false                   // the key's auto-repeat
        player.perform(.frameStep)
        #expect(haptics.events == [.end])
        player.inputIsFresh = true                    // a new press
        player.perform(.frameStep)
        #expect(haptics.events == [.end, .end])
        player.inputIsFresh = false
        player.perform(.frameBackStep)                // a step that moves resets the bump
        player.perform(.frameStep)
        #expect(haptics.events == [.end, .end])       // frame steps that move are quiet
        player.perform(.frameStep)
        #expect(haptics.events == [.end, .end, .end])
        player.scrub(by: 5)                           // a scrub into the same end, not fresh: nothing
        #expect(haptics.events == [.end, .end, .end])
    }

    @Test func seeksStepAndBumpAtTheStart() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        let haptics = record(player)
        player.perform(.seek(-10, .exact))            // at frame 0 already
        #expect(haptics.events == [.end] && haptics.seekSteps.isEmpty)
        player.perform(.seek(10, .exact))
        #expect(haptics.events == [.end] && haptics.seekSteps == [.step] && player.position == 300)
        player.inputIsFresh = false
        player.perform(.seek(-10, .exact))            // moved back to 0: a step
        player.perform(.seek(-10, .exact))            // and there, after a move, the first push bumps
        #expect(haptics.events == [.end, .end] && haptics.seekSteps == [.step, .step])
        player.perform(.keyframeBackStep)             // the same push, not fresh
        player.perform(.frameBackStep)
        #expect(haptics.events == [.end, .end])
        player.perform(.frameStep)                    // forward moves; nothing for a frame step
        player.inputIsFresh = true
        player.perform(.frameBackStep)
        player.perform(.frameBackStep)
        #expect(haptics.events == [.end, .end, .end] && haptics.seekSteps == [.step, .step])
    }

    @Test func aSeekStepGoesOnlyToTheSeekHaptic() throws {
        let (player, _, _) = try makePlayer()
        defer { player.close() }
        var general: [HapticEvent] = []
        player.onHaptic = { general.append($0) }
        player.onSeekHaptic = nil                     // nobody plays seek steps: a seek that moves is silent
        player.perform(.seek(10, .exact))
        #expect(general.isEmpty && player.position == 300)
        player.perform(.stepSpeed(1))                 // other steps still go to `onHaptic`
        #expect(general == [.step])
    }

    @Test func aPlainWheelScrubTicksOnKeyframesAndMarks() async throws {
        var t = 100.0
        let (player, _, _) = try makePlayer(now: { t })
        defer { player.close() }
        #expect(await eventually { player.index?.isExact == true })
        setMark(player, 270, 280)
        player.seek(toFrame: 230)
        let haptics = record(player)
        player.scrub(by: 30)                          // the trackpad and the seek bar: no ticks
        #expect(haptics.events.isEmpty && player.position == 260)
        player.seek(toFrame: 230)
        t += 1
        player.scrub(by: 30, ticks: true)             // passes keyframe 250
        #expect(haptics.events == [.keyframe])
        t += 0.01
        player.scrub(by: 20, ticks: true)             // passes mark start 270, but within 40 ms
        #expect(haptics.events == [.keyframe] && player.position == 280)
        t += 1
        player.scrub(by: -20, ticks: true)            // back over the mark start 270 (280 itself is left, not passed)
        #expect(haptics.events == [.keyframe, .mark])
        t += 1
        player.scrub(by: -5, ticks: true)             // 260 → 255: nothing
        #expect(haptics.events == [.keyframe, .mark])
        player.perform(.abLoop)                       // A at 255
        player.seek(toFrame: 240)
        t += 1
        player.scrub(by: 20, ticks: true)             // 240 → 260: A (255) beats keyframe 250 in the same step
        #expect(haptics.events == [.keyframe, .mark, .mark])
    }

    @Test func refusalsPlayTheError() throws {
        let (player, delegate, _) = try makePlayer(beforeOpen: { $0.keepApproximateIndex = true })
        defer { player.close() }
        let haptics = record(player)
        player.perform(.markNext)
        #expect(delegate.messages.last == "No mark after" && haptics.events == [.error])
        player.perform(.markPrev)
        player.perform(.markDelete)
        player.perform(.markClear)
        player.perform(.playMarks)
        player.perform(.markSnap)
        player.perform(.markLoop)
        player.perform(.exportRange)
        #expect(delegate.messages.suffix(7) == ["No mark before", "No mark here", "No marks", "No marks to play",
                                                "Wait for the index to finish", "Set an A-B range first",
                                                "Set an A-B range first"])
        #expect(haptics.events == Array(repeating: .error, count: 8))
        player.perform(.markIn)                       // a mark edit that works: nothing
        player.perform(.markDelete)
        #expect(haptics.events.count == 8)
    }
}
