import AppKit
import CoreVideo
import FrameScrubCore

/// Real decoder workers, the playback cache, and VideoView's physical presentation callback.
@MainActor
final class CacheScrubBench: PlayerCoreDelegate {
    private struct Input {
        let number: Int
        let direction: Int
        let started: CFTimeInterval
        let tier: String
        var presented: Double?
        var previewOrigin: Int?
        var preview: Double?
        var previewDistance: Int?
        var nearPreview: Double?
        var cachedPreview: Double?
    }

    private let core: PlayerCore
    private let window: NSWindow
    private let videoView = VideoView()
    private let paced: Bool
    private let measuresDelivery: Bool
    private var inputs: [Input] = []
    private var pending: Int?
    private var waiter: CheckedContinuation<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var formats = Set<String>()
    private var maximumPacked = 0
    private var lastUpper: Int?
    private var boundaryChanges = 0
    private var decodeActivityChanges = 0
    private var lastInsertions = 0
    private var measuresMaskLoad = false
    private var seekPreviewPool: PreviewImagePool?
    private var showCachedSeekPreview = false

    private init(compressed: Bool, paced: Bool, remote: Bool, jumps: Bool, measuresDelivery: Bool, scrubSound: Bool) {
        var config = Config()
        config.cacheSizeMiB = remote && !jumps ? 16 : 256
        config.autoplay = false
        config.networkMode = jumps ? .auto : .no
        if remote || jumps { config.volume = 0 }
        core = PlayerCore(config: config, enableAudio: remote || jumps || scrubSound, cacheCompression: compressed)
        self.paced = paced
        self.measuresDelivery = measuresDelivery
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let bounds = CGRect(x: 0, y: 0, width: 1280 / scale, height: 720 / scale)
        window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "FrameScrub cache bench"
        window.center()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = videoView
        videoView.scaleMode = .bilinear
        videoView.sharpen = 0
        videoView.diagnosticPlaybackChanged(playing: false)
        videoView.onTick = { [weak core] in core?.tick() }
        core.delegate = self
        if !measuresDelivery {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func launch() -> Never {
        let args = CommandLine.arguments
        let modes = ["burst", "burst-dense", "burst-headless", "burst-audio", "burst-audio-headless", "ack",
                     "forward-headless", "fast-forward-headless", "reverse-headless", "reverse-preview-headless", "reverse-preview-ungated-headless", "reverse-mask-headless", "idle-headless",
                     "jump", "jump-headless", "jump-burst", "local-seek", "local-seek-screen", "local-seek-cached-screen", "local-seek-same-gop-headless", "scrub-audio"]
        guard let index = args.firstIndex(of: "--bench-cache-scrub"), args.count == index + 4,
              ["plain", "compressed"].contains(args[index + 2]), modes.contains(args[index + 3]) else {
            fail("Usage: FrameScrub --bench-cache-scrub VIDEO_PATH_OR_URL plain|compressed \(modes.joined(separator: "|"))")
        }
        let mode = args[index + 3]
        let jumps = mode.hasPrefix("jump")
        let scrubSound = mode.hasPrefix("burst-audio")
        let location = args[index + 1]
        let remote = URL(string: location).flatMap { ByteSources.isRemote($0) ? $0 : nil }
        if scrubSound || mode.hasPrefix("local-seek") || mode == "scrub-audio", remote != nil {
            fail("\(mode) requires a local file")
        }
        let url = remote ?? URL(filePath: location)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        Task { @MainActor in
            if mode == "scrub-audio" {
                do {
                    try await runScrubAudio(url)
                    await withCheckedContinuation { continuation in
                        PlaybackDiagnostics.shared.flush { continuation.resume() }
                    }
                    fflush(nil)
                    exit(0)
                } catch { fail(String(describing: error)) }
            }
            let sustainedStep = switch mode {
            case "forward-headless": 1
            case "fast-forward-headless": 4
            case "reverse-headless", "reverse-preview-headless", "reverse-preview-ungated-headless", "reverse-mask-headless": -1
            default: 0
            }
            let measuresDelivery = (mode.hasSuffix("-headless") && !jumps) || mode == "local-seek"
            let bench = CacheScrubBench(compressed: args[index + 2] == "compressed", paced: mode.hasPrefix("burst") || sustainedStep != 0,
                                        remote: remote != nil, jumps: jumps, measuresDelivery: measuresDelivery, scrubSound: scrubSound)
            do {
                if mode == "local-seek-same-gop-headless" { try await bench.runSameGOPSeeks(url) }
                else if mode.hasPrefix("local-seek") { try await bench.runLocalSeeks(url, warmPreviews: mode == "local-seek-cached-screen") }
                else if mode == "idle-headless" { try await bench.runIdle(url) }
                else if jumps { try await bench.runJumps(url, headless: mode != "jump", burst: mode == "jump-burst") }
                else {
                    try await bench.run(url, awaitsScrubSound: scrubSound, sustainedStep: sustainedStep,
                                        inputHz: mode == "burst-dense" ? 119 : 59, load: mode)
                }
                await withCheckedContinuation { continuation in
                    PlaybackDiagnostics.shared.flush { continuation.resume() }
                }
                bench.videoView.stop()
                bench.core.close()
                bench.window.orderOut(nil)
                fflush(nil)
                exit(0)
            } catch {
                await withCheckedContinuation { continuation in
                    PlaybackDiagnostics.shared.flush { continuation.resume() }
                }
                fail(String(describing: error))
            }
        }
        app.run()
        fail("Benchmark run loop ended")
    }

    private final class AudioProbe: SnippetSink, TapeSink, Sendable {
        func playSnippet(_ samples: StereoSamples, sampleRate: Double, ended: @escaping @Sendable () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(samples.count) / sampleRate, execute: ended)
        }
        func setTapeControl(_ control: TapeControl) {}
        func setTapeSnapshot(_ snapshot: TapeSnapshot) {
            // Read a PCM sample across the same publication boundary as the tape.
            PlaybackDiagnostics.shared.record("snapshot_probe", Double(abs(snapshot.sample(atSeconds: snapshot.startSeconds + 2).0)),
                                              group: "scrub.audio.bench")
        }
    }

    private static func runScrubAudio(_ url: URL) async throws {
        let probe = AudioProbe()
        let decoder = try AudioDecoder(url: url, zeroSeconds: 0)
        let scrub = ScrubAudio(decoder: decoder, sink: probe, tape: probe, batchLocalReads: true, shouldYield: { false })
        defer { scrub.stop() }
        scrub.fileOpened()
        scrub.userActed()
        let clock = ContinuousClock()
        let wall = CACurrentMediaTime()
        let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let start = clock.now
        for i in 0..<480 {
            try await clock.sleep(until: start + .microseconds(i * 16_667))
            let offset = i % 120 < 90 ? i % 120 : 180 - i % 120
            let seconds = 3 + Double(i / 120) * 6 + Double(offset) / 30
            let before = PlaybackDiagnostics.now()
            scrub.frameShown(seconds: seconds)
            PlaybackDiagnostics.shared.record("frame_shown_ms", (PlaybackDiagnostics.now() - before) * 1000,
                                              group: "scrub.audio.bench")
        }
        try await Task.sleep(for: .milliseconds(350))
        let cpuSeconds = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpu) / 1e9
        print("scrubAudio actions=480 CPU_s=\(cpuSeconds) elapsed_s=\(CACurrentMediaTime() - wall)")
    }

    private func openIndexedLocalFixture(_ url: URL) async throws -> FrameIndex {
        let prepare = core.preparation(for: url)
        core.open(try await Task.detached(priority: .userInitiated) { try prepare() }.value)
        let deadline = ContinuousClock.now + .seconds(10)
        while core.index?.isExact != true || core.displayedFrame != 0 {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Could not open and index local fixture") }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let index = core.index else { throw Failure(message: "Missing exact index") }
        return index
    }

    /// Alternate cold paused jumps among long GOPs. A burst supersedes a seek, then
    /// eight acknowledged backward steps expose the edge of the ready window.
    private func runLocalSeeks(_ url: URL, warmPreviews: Bool) async throws {
        if !measuresDelivery {
            try await Task.sleep(for: .milliseconds(350))
            guard window.occlusionState.contains(.visible) else { throw Failure(message: "Benchmark window is occluded") }
        }
        let index = try await openIndexedLocalFixture(url)
        let starts = index.keyframes + [index.frameCount]
        let longGroups = zip(starts, starts.dropFirst()).compactMap { start, end in
            end - start >= 120 ? start..<end : nil
        }
        let groups = warmPreviews ? Array(longGroups.prefix(6)) : longGroups
        guard groups.count >= 3 else { throw Failure(message: "local-seek requires at least three GOPs of 120 frames or more") }
        func coldTarget(in group: Range<Int>) throws -> Int {
            let late = group.lowerBound + 4 * group.count / 5
            let earliest = group.lowerBound + group.count / 2
            guard let target = stride(from: late, through: earliest, by: -1).first(where: { !core.cache.isResolved($0) }) else {
                throw Failure(message: "Could not find a cold target in \(group)")
            }
            return target
        }
        if warmPreviews {
            let pool = PreviewImagePool(url: url, rotationClockwise: 0)
            let provider = PreviewProvider(url: url, index: index, rotationClockwise: 0, widthPixels: 320,
                                           qos: .utility, imagePool: pool)
            for key in groups.map(\.upperBound) where key < index.frameCount {
                try Task.checkCancellation()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    provider.onRequestFinished = { continuation.resume() }
                    provider.request(seconds: index.seconds(forFrame: key))
                }
            }
            provider.stop()
            seekPreviewPool = pool
            showCachedSeekPreview = ProcessInfo.processInfo.environment["FRAMESCRUB_BENCH_HIDE_CACHED_SEEK"] != "1"
        }
        let started = CACurrentMediaTime()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for round in 0..<24 {
            let burst = round % 2 == 1
            let slot = round % groups.count
            let group = warmPreviews ? (slot.isMultiple(of: 2) ? groups.count - 1 - slot / 2 : slot / 2) : slot
            if burst {
                core.seek(toFrame: try coldTarget(in: groups[(group + 1) % groups.count]))
                try await Task.sleep(for: .milliseconds(3))
            }
            let target = try coldTarget(in: groups[group])
            let origin = core.displayedFrame ?? core.position
            inputs.append(Input(number: target, direction: target > origin ? 1 : -1, started: CACurrentMediaTime(),
                                tier: burst ? "superseding" : "single", previewOrigin: origin))
            pending = inputs.count - 1
            core.seek(toFrame: target)
            try await awaitExactLocalPicture()
            for _ in 0..<8 {
                inputs.append(Input(number: core.position - 1, direction: -1, started: CACurrentMediaTime(), tier: "step"))
                pending = inputs.count - 1
                core.scrub(by: -1)
                try await awaitExactLocalPicture()
            }
        }
        for tier in ["single", "superseding", "step"] {
            let group = inputs.filter { $0.tier == tier }
            report(group, name: tier)
            if tier != "step" {
                let preview = group.map { input in
                    var result = input
                    result.presented = input.preview
                    return result
                }
                report(preview, name: "\(tier)-preview")
                let near = group.map { input in
                    var result = input
                    result.presented = input.nearPreview
                    return result
                }
                report(near, name: "\(tier)-within-48-frames")
                let distances = group.compactMap(\.previewDistance).sorted()
                if !distances.isEmpty {
                    print("\(tier)-preview target_distance_frames_p50=\(distances[distances.count / 2]) " +
                          "min=\(distances[0]) max=\(distances[distances.count - 1])")
                }
            }
        }
        if warmPreviews {
            let backward = inputs.filter { $0.tier != "step" && $0.direction < 0 }
            report(backward.map { input in
                var result = input
                result.presented = input.cachedPreview
                return result
            }, name: "backward-cached-preview")
        }
        let seconds = CACurrentMediaTime() - started
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStarted) / 1e7 / seconds
        print("decoder=\(core.playbackDecoderKind?.rawValue ?? "unknown") processCPU=\(cpu) endMiB=\(Double(core.cache.usedBytes) / 1048576)")
    }

    /// Supersede an in-flight click without leaving its GOP, in both directions.
    private func runSameGOPSeeks(_ url: URL) async throws {
        let index = try await openIndexedLocalFixture(url)
        let starts = index.keyframes + [index.frameCount]
        let groups = zip(starts, starts.dropFirst()).compactMap { start, end in
            end - start >= 200 ? start..<end : nil
        }
        guard groups.count >= 3 else { throw Failure(message: "Same-GOP seeks require at least three 200-frame GOPs") }
        let started = CACurrentMediaTime()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for round in 0..<36 {
            let group = groups[round % groups.count]
            let low = group.lowerBound + group.count / 2
            let high = group.lowerBound + 4 * group.count / 5
            let forward = (round / groups.count + round % groups.count).isMultiple(of: 2)
            let (first, target) = forward ? (low, high) : (high, low)
            guard !core.cache.isResolved(first), !core.cache.isResolved(target) else {
                throw Failure(message: "Expected two cold seek targets in \(group)")
            }
            core.seek(toFrame: first)
            try await Task.sleep(for: .milliseconds(3))
            inputs.append(Input(number: target, direction: forward ? 1 : -1, started: CACurrentMediaTime(),
                                tier: forward ? "same-gop-forward" : "same-gop-backward"))
            pending = inputs.count - 1
            core.seek(toFrame: target)
            try await awaitExactLocalPicture()
        }
        for tier in ["same-gop-forward", "same-gop-backward"] {
            report(inputs.filter { $0.tier == tier }, name: tier)
        }
        let seconds = CACurrentMediaTime() - started
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStarted) / 1e7 / seconds
        print("decoder=\(core.playbackDecoderKind?.rawValue ?? "unknown") processCPU=\(cpu) elapsed_s=\(seconds)")
    }

    private func awaitExactLocalPicture() async throws {
        guard let pending else { return }
        await awaitPresentation(pending, deadline: .seconds(3))
        guard inputs[pending].presented != nil else {
            let frame = inputs[pending].number
            throw Failure(message: "Exact frame \(frame) missed its deadline (position \(core.position), shown \(core.displayedFrame ?? -1), ready \(core.cache.hasReadyFrame(frame)), undecodable \(core.cache.isUndecodable(frame)))")
        }
    }

    private struct Failure: Error { let message: String }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        fflush(nil)
        exit(1)
    }

    private func runIdle(_ url: URL) async throws {
        let prepare = core.preparation(for: url)
        core.open(try await Task.detached { try prepare() }.value)
        let deadline = ContinuousClock.now + .seconds(6)
        while (!core.cache.hasReadyFrame(0) || core.index?.isExact != true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard core.cache.hasReadyFrame(0), core.index?.isExact == true else { throw Failure(message: "Idle fixture did not open") }
        try await Task.sleep(for: .seconds(1))
        let activity = core.cache.activity.decodedInsertions
        let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let start = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(3))
        let elapsed = CACurrentMediaTime() - start
        let idleCPU = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpu) / 1e6
        guard core.cache.activity.decodedInsertions == activity else { throw Failure(message: "Cache was still filling during idle") }
        let input = CACurrentMediaTime()
        inputs.append(Input(number: 1, direction: 1, started: input, tier: "idle"))
        pending = 0
        core.scrub(by: 1)
        await awaitPresentation(0)
        guard let firstStep = inputs[0].presented else { throw Failure(message: "First step after idle was not delivered") }
        print("idle_seconds=\(elapsed) idle_cpu_ms=\(idleCPU) first_step_ms=\(firstStep)")
    }

    private func run(_ url: URL, awaitsScrubSound: Bool, sustainedStep: Int, inputHz: Double, load: String) async throws {
        try await Task.sleep(for: .milliseconds(350))
        guard measuresDelivery || window.occlusionState.contains(.visible) else {
            throw Failure(message: "Benchmark window is occluded")
        }
        let prepare = core.preparation(for: url)
        let prepared = try await Task.detached(priority: .userInitiated) { try prepare() }.value
        core.open(prepared)
        let deadline = ContinuousClock.now + .seconds(6)
        let streaming = core.info?.isHLS == true
        while ((!streaming && core.index?.isExact != true) || !core.cache.hasReadyFrame(core.position)),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        guard streaming || core.index?.isExact == true, core.frameCount >= 72 else {
            throw Failure(message: "Benchmark needs a seekable HLS VOD or exact file index with at least 72 frames")
        }
        if awaitsScrubSound {
            while !core.hasScrubAudio, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard core.hasScrubAudio else { throw Failure(message: "Scrub audio did not attach") }
        }
        if streaming, core.info?.audioStreamIndex != nil {
            while !core.hasAudio, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(15))
            }
            guard core.hasAudio else { throw Failure(message: "HLS audio did not attach") }
            core.play()
            while (core.displayedFrame ?? 0) < 12, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard (core.displayedFrame ?? 0) >= 12 else { throw Failure(message: "HLS playback did not advance") }
            core.pause()
            print("hls_playback=advanced audio=attached")
        }
        let sustainedSteps = 288
        let origin = sustainedStep < 0 ? min(core.frameCount - 1, sustainedSteps + 35) : 20
        if sustainedStep > 0, core.frameCount <= origin + sustainedSteps * sustainedStep {
            throw Failure(message: "Sustained forward scrub needs at least \(origin + sustainedSteps * sustainedStep + 1) frames")
        }
        if sustainedStep < 0, origin < sustainedSteps {
            throw Failure(message: "Sustained reverse scrub needs at least \(sustainedSteps + 1) frames")
        }
        core.seek(toFrame: origin)
        while !core.cache.hasReadyFrame(origin), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard core.cache.hasReadyFrame(origin) else { throw Failure(message: "Could not warm the starting frame") }
        try await Task.sleep(for: .milliseconds(100))
        measuresMaskLoad = load == "reverse-mask-headless"
        if measuresMaskLoad { videoView.setSubjectFocus(.black) }
        let sidePreview: PreviewProvider?
        if load.hasPrefix("reverse-preview"), let index = core.index {
            sidePreview = PreviewProvider(url: url, index: index, rotationClockwise: 0, widthPixels: 320,
                                          readCache: core.readCache, qos: .utility,
                                          imagePool: PreviewImagePool(url: url, rotationClockwise: 0, capacity: 1),
                                          frameCache: core.cache, exactSample: true,
                                          shouldYield: load == "reverse-preview-headless" ? core.previewShouldYield : nil)
        } else {
            sidePreview = nil
        }
        defer { sidePreview?.stop() }
        let before = core.cache.activity
        lastInsertions = before.decodedInsertions
        let started = CACurrentMediaTime()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for round in 0..<(sustainedStep == 0 ? 3 : 1) {
            for step in sustainedStep == 0 ? [1, -1] : [sustainedStep] {
                let direction = step > 0 ? 1 : -1
                for _ in 0..<(sustainedStep == 0 ? 48 : sustainedSteps) {
                    if paced {
                        let until = started + Double(inputs.count) / inputHz - CACurrentMediaTime()
                        if until > 0 { try await Task.sleep(for: .seconds(until)) }
                    }
                    guard measuresDelivery || window.occlusionState.contains(.visible) else {
                        throw Failure(message: "Window became occluded on round \(round + 1)")
                    }
                    var target = core.position + step
                    while core.cache.isUndecodable(target), (0..<core.frameCount).contains(target + direction) {
                        target += direction
                    }
                    let residence = core.cache.residency(target)
                    let tier = residence.ready ? "ready" : residence.packed ? "packed" : "miss"
                    inputs.append(Input(number: target, direction: direction, started: CACurrentMediaTime(), tier: tier))
                    let request = inputs.count - 1
                    pending = request
                    core.scrub(by: step)
                    if let sidePreview, inputs.count % 4 == 1 {
                        let frame = 450 + (inputs.count / 4 % 3) * 250
                        sidePreview.request(seconds: core.index!.seconds(forFrame: frame))
                    }
                    if !paced { await awaitPresentation(request) }
                }
            }
        }
        if paced, let pending {
            await awaitPresentation(pending)
            if inputHz > 59, inputs[pending].presented == nil {
                throw Failure(message: "The final input did not reach the screen after the dense burst")
            }
        }
        try await Task.sleep(for: .milliseconds(75))
        let seconds = CACurrentMediaTime() - started
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStarted) / 1e7 / seconds
        let after = core.cache.activity
        if let sidePreview { print("side_preview_decodes=\(sidePreview.decodeCount)") }
        print("endpoint=\(measuresDelivery ? "delegate" : "screen") formats=\(formats.sorted().joined(separator: ",")) decoder=\(core.playbackDecoderKind?.rawValue ?? "unknown") hz=\(window.screen?.maximumFramesPerSecond ?? 0) " +
              "decodedDuring=\(after.decodedInsertions - before.decodedInsertions) packedDuring=\(after.demotions - before.demotions) " +
              "restoredDuring=\(after.promotions - before.promotions) maxPacked=\(maximumPacked) boundaryChanges=\(boundaryChanges) " +
              "activeFillIntervals=\(decodeActivityChanges) processCPU=\(cpu) effectiveHz=\(Double(inputs.count) / seconds) " +
              "endFrames=\(core.cache.count) endMiB=\(Double(core.cache.usedBytes) / 1048576)")
        for direction in [1, -1] {
            let selected = inputs.filter { $0.direction == direction }
            report(selected, name: direction > 0 ? "forward" : "backward")
            for tier in ["ready", "packed", "miss"] {
                let group = selected.filter { $0.tier == tier }
                if !group.isEmpty { report(group, name: "\(direction > 0 ? "forward" : "backward")-\(tier)") }
            }
        }
        if !measuresDelivery {
            let inputAges = inputs.indices.compactMap { index -> Int? in
                guard let latency = inputs[index].presented else { return nil }
                let shown = inputs[index].started + latency / 1000
                return inputs.dropFirst(index + 1).prefix { $0.started <= shown }.count
            }.sorted()
            if !inputAges.isEmpty {
                let p95 = inputAges[Int(ceil(0.95 * Double(inputAges.count))) - 1]
                print("newer_inputs_at_exact_presentation_p95=\(p95)")
            }
        }
        guard measuresDelivery || (after.decodedInsertions > before.decodedInsertions && boundaryChanges > 0) else {
            throw Failure(message: "Trace did not exercise moving boundaries and live filling")
        }
    }

    /// Same seek and play entry points as a timeline click followed by Space.
    private func runJumps(_ url: URL, headless: Bool, burst: Bool) async throws {
        try await Task.sleep(for: .milliseconds(350))
        guard headless || window.occlusionState.contains(.visible) else { throw Failure(message: "Benchmark window is occluded") }
        if headless {
            videoView.onTick = nil
            window.orderOut(nil)
        }
        let prepared: PreparedOpen
        if ByteSources.isRemote(url), !VideoPageResolver.isDirectMedia(url) {
            let cancellation = OpenCancellation()
            let video = try await Task.detached {
                try VideoPageResolver.resolve(url, preferBitrate: true, cancellation: cancellation).first
            }.value
            guard let video else { throw Failure(message: "No extracted video") }
            let prepare = core.preparation(for: url, cancellation: cancellation, resolved: video)
            prepared = try await Task.detached { try prepare() }.value
        } else {
            let prepare = core.preparation(for: url)
            prepared = try await Task.detached { try prepare() }.value
        }
        core.open(prepared)
        let openDeadline = ContinuousClock.now + .seconds(12)
        while (!core.hasAudio || core.displayedFrame != 0), ContinuousClock.now < openDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard core.hasAudio, core.displayedFrame == 0,
              let index = core.index, core.durationSeconds > 10 else {
            throw Failure(message: "Jump trace requires a first picture, audio, and at least ten seconds of media")
        }
        let targets = burst ? [0.81, 0.22, 0.47] : [0.22, 0.81, 0.47, 0.22, 0.81, 0.47]
        for fraction in targets {
            core.pause()
            let target = index.frameNumber(forSeconds: core.durationSeconds * fraction)
            let residence = core.cache.residency(target)
            let tier = residence.ready ? "ready" : residence.packed ? "packed" : "miss"
            let before = core.readCache?.stats
            if burst {
                for old in [0.15, 0.65] {
                    core.seek(toFrame: index.frameNumber(forSeconds: core.durationSeconds * old))
                    try await Task.sleep(for: .milliseconds(120))
                }
            }
            let start = CACurrentMediaTime()
            inputs.append(Input(number: target, direction: 1, started: start, tier: tier))
            pending = inputs.count - 1
            core.seek(toFrame: target)
            core.play()
            var landed: Double?, moving: Double?, filled: Double?
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if headless { core.tick() }
                let elapsed = (CACurrentMediaTime() - start) * 1000
                if landed == nil, core.displayedFrame == target { landed = elapsed }
                if landed != nil, moving == nil, let displayed = core.displayedFrame,
                   displayed > target, displayed < target + 60 {
                    moving = elapsed
                }
                if filled == nil, (target...target + 8).allSatisfy(core.cache.contains) { filled = elapsed }
                if landed != nil, moving != nil, filled != nil { break }
                try await Task.sleep(for: .milliseconds(headless ? 8 : 4))
            }
            let after = core.readCache?.stats
            let requests = (after?.requests ?? 0) - (before?.requests ?? 0)
            let hits = (after?.hits ?? 0) - (before?.hits ?? 0)
            let waits = (after?.waits ?? 0) - (before?.waits ?? 0)
            let bytes = (after?.bytesFromFile ?? 0) - (before?.bytesFromFile ?? 0)
            let shown = inputs.last?.presented ?? -1
            print(String(format: "jump=%d tier=%@ landed_ms=%.1f shown_ms=%.1f moving_ms=%.1f ahead8_cached_ms=%.1f byte_requests=%d byte_hits=%d byte_waits=%d read_MiB=%.2f",
                         target, tier, landed ?? -1, shown, moving ?? -1, filled ?? -1,
                         requests, hits, waits, Double(bytes) / 1048576))
            fflush(nil)
            guard landed != nil, moving != nil else { throw Failure(message: "Jump did not land and resume in time") }
            core.pause()
        }
    }

    private func awaitPresentation(_ request: Int, deadline: Duration = .milliseconds(700)) async {
        if inputs[request].presented != nil { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                if !Task.isCancelled { self?.completeWait() }
            }
        }
    }

    private func completeWait() {
        timeout?.cancel()
        timeout = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }

    private func report(_ inputs: [Input], name: String) {
        let values = inputs.compactMap(\.presented).sorted()
        func percentile(_ fraction: Double) -> Double {
            values.isEmpty ? .nan : values[Int(ceil(Double(values.count) * fraction)) - 1]
        }
        print(String(format: "%@ requests=%d %@=%d missed=%d p50_ms=%.2f p95_ms=%.2f p99_ms=%.2f max_ms=%.2f",
                     name, inputs.count, measuresDelivery ? "delivered" : "shown", values.count, inputs.count - values.count,
                     percentile(0.50), percentile(0.95), percentile(0.99), values.last ?? .nan))
    }

    func player(_ player: PlayerCore, previewBackwardSeek frames: ClosedRange<Int>) {
        guard showCachedSeekPreview, let pending, inputs[pending].number == frames.lowerBound,
              let index = player.index, let info = player.info,
              let preview = seekPreviewPool?.seekPreview(url: info.url, rotationClockwise: info.rotationClockwise,
                                                        index: index, frames: frames),
              videoView.previewCachedSeek(preview.image, target: frames.lowerBound) else { return }
        videoView.onBenchPresented = { [weak self] time in
            guard let self else { return }
            let elapsed = (time - inputs[pending].started) * 1000
            guard elapsed >= 0, inputs[pending].presented.map({ elapsed < $0 }) ?? true else { return }
            inputs[pending].cachedPreview = elapsed
            self.recordPreview(pending, distance: preview.frame - frames.lowerBound, at: time)
        }
    }

    func player(_ player: PlayerCore, display frame: DecodedFrame) {
        if measuresMaskLoad { videoView.show(frame, playing: false) }
        if let pending, inputs[pending].number == frame.number {
            let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            formats.insert(String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) }, as: UTF8.self))
            if measuresDelivery {
                if inputs[pending].presented == nil {
                    inputs[pending].presented = (CACurrentMediaTime() - inputs[pending].started) * 1000
                    completeWait()
                }
                return
            }
            videoView.onBenchPresented = { [weak self] time in
                guard let self, inputs[pending].presented == nil, time >= inputs[pending].started else { return }
                inputs[pending].presented = (time - inputs[pending].started) * 1000
                if self.pending == pending { self.completeWait() }
            }
        } else if let pending, let origin = inputs[pending].previewOrigin,
                  abs(frame.number - inputs[pending].number) < abs(origin - inputs[pending].number) {
            let distance = abs(frame.number - inputs[pending].number)
            if measuresDelivery {
                recordPreview(pending, distance: distance, at: CACurrentMediaTime())
            } else {
                videoView.onBenchPresented = { [weak self] time in self?.recordPreview(pending, distance: distance, at: time) }
            }
        } else {
            videoView.onBenchPresented = nil
        }
        if !measuresDelivery { videoView.show(frame, playing: !player.isPaused) }
    }

    private func recordPreview(_ request: Int, distance: Int, at time: CFTimeInterval) {
        let elapsed = (time - inputs[request].started) * 1000
        guard elapsed >= 0, inputs[request].presented.map({ elapsed < $0 }) ?? true else { return }
        if inputs[request].preview == nil {
            inputs[request].preview = elapsed
            inputs[request].previewDistance = distance
        }
        if distance <= 48, inputs[request].nearPreview == nil { inputs[request].nearPreview = elapsed }
    }

    func playerStateDidChange(_ player: PlayerCore) {
        videoView.updateFilmSeekPreview(position: player.position, paused: player.isPaused,
                                        unavailable: player.cache.isUndecodable(player.position))
        guard !inputs.isEmpty else { return }
        maximumPacked = max(maximumPacked, core.cache.packedFrameCount)
        let upper = core.cache.cachedRanges().last?.upperBound
        if lastUpper != upper {
            boundaryChanges += 1
            lastUpper = upper
        }
        let insertions = core.cache.activity.decodedInsertions
        if lastInsertions != insertions {
            decodeActivityChanges += 1
            lastInsertions = insertions
        }
    }
    func player(_ player: PlayerCore, showOSD text: String) {}
}
