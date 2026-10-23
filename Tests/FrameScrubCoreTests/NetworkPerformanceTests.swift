import CoreImage
import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import FrameScrubCore

/// A NAS: every read waits `latency`, transfers share `bytesPerSecond`.
final class SlowNASByteSource: ByteSource, @unchecked Sendable {
    private let base: FileByteSource
    private let latency: Double
    private let bytesPerSecond: Double
    private let lock = NSLock()
    private var busyUntil = 0.0
    init(url: URL, latency: Double = 0.030, bytesPerSecond: Double = 100e6) throws {
        base = try FileByteSource(url: url)
        self.latency = latency
        self.bytesPerSecond = bytesPerSecond
    }
    var size: Int64 { base.size }
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        Thread.sleep(forTimeInterval: latency)
        let wait = lock.withLock { () -> Double in
            let now = CACurrentMediaTime()
            busyUntil = max(now, busyUntil) + Double(count) / bytesPerSecond
            return busyUntil - now
        }
        Thread.sleep(forTimeInterval: wait)
        return try base.read(at: offset, count: count, into: buffer)
    }
}

/// One minute of noisy 4K HEVC 10-bit at ~30 Mbit/s (MP4 and MKV), made once per machine.
enum NetworkFixtures {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framescrub-perf", isDirectory: true)
    static var mp4: URL { directory.appendingPathComponent("hevc4k_30mbps.mp4") }
    static var mkv: URL { directory.appendingPathComponent("hevc4k_30mbps.mkv") }

    static func make() throws {
        guard !FileManager.default.fileExists(atPath: mkv.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run(["-f", "lavfi", "-i", "testsrc2=s=3840x2160:r=30", "-t", "60", "-vf", "noise=alls=12:allf=t,format=p010le",
                 "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-b:v", "30M", "-g", "60", "-tag:v", "hvc1", mp4.path])
        try run(["-i", mp4.path, "-c", "copy", mkv.path])
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-v", "error", "-y"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
    }
}

final class TimedDelegate: PlayerCoreDelegate {
    var shown: [(time: Double, frame: Int)] = []
    func player(_ player: PlayerCore, display frame: DecodedFrame) { shown.append((CACurrentMediaTime(), frame.number)) }
    func playerStateDidChange(_ player: PlayerCore) {}
    func player(_ player: PlayerCore, showOSD text: String) {}
}

final class CountingDelegate: PlayerCoreDelegate {
    var shown: [Int] = []
    func player(_ player: PlayerCore, display frame: DecodedFrame) { shown.append(frame.number) }
    func playerStateDidChange(_ player: PlayerCore) {}
    func player(_ player: PlayerCore, showOSD text: String) {}
}

/// Opt-in: FRAMESCRUB_PERF=1 swift test --filter NetworkPerformanceTests
/// (FRAMESCRUB_PERF_FILE=/Volumes/… also measures that real file, read as is; FRAMESCRUB_PERF_STEPS=8,-4 picks the
/// scrub steps of `realFileScrubFreezes`, FRAMESCRUB_PERF_SOFTWARE=1 makes `realFileDecodeSpeed` use the software decoder,
/// FRAMESCRUB_PERF_FFMPEG_VT=1 FFmpeg's VideoToolbox hwaccel instead of our own session.)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF"] != nil))
@MainActor struct NetworkPerformanceTests {
    private func run(_ url: URL, throttled: Bool = true) async throws -> String {
        var config = Config()
        config.cacheSizeMiB = 2048
        let player = PlayerCore(config: config, enableAudio: false,
                                byteSource: { url, _ -> ByteSource in throttled ? try SlowNASByteSource(url: url) : try FileByteSource(url: url) })
        let delegate = CountingDelegate()
        player.delegate = delegate
        defer { player.close() }
        let opened = CACurrentMediaTime()
        try player.open(url)

        // Single seeks right after opening (the index may still be approximate).
        for _ in 0..<5 {
            player.perform(.seek(5, .byConfig))
            _ = await eventually(timeout: 30) { !player.seekTimer.isRunning }
        }
        let singles = player.seekTimer.recent
        // A held key from the start: 20 seeks of 2 s, 50 ms apart (stays inside the one-minute file).
        player.seekFromBar(toFrame: 0)
        _ = await eventually(timeout: 30) { !player.seekTimer.isRunning }
        let before = delegate.shown.count
        for _ in 0..<20 {
            player.perform(.seek(2, .byConfig))
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = await eventually(timeout: 60) { !player.seekTimer.isRunning }
        let series = player.seekTimer.recent.last ?? -1
        let intermediate = max(0, delegate.shown.count - before - 1)
        _ = await eventually(timeout: 300) { player.index?.isExact == true || player.indexStatus == .failed }
        let indexTime = CACurrentMediaTime() - opened
        let ms = { (s: Double) in String(format: "%.0f", s * 1000) }
        return "\(url.lastPathComponent): singles \(singles.map(ms).joined(separator: "/")) ms; "
            + "held key: last target after \(ms(series)) ms, \(intermediate) intermediate frames; "
            + "exact index after \(String(format: "%.1f", indexTime)) s (\(player.indexStatus.text)); "
            + (player.readCache?.stats.text ?? "")
    }

    @Test func nasMP4() async throws {
        try NetworkFixtures.make()
        print("NAS " + (try await run(NetworkFixtures.mp4)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFile() async throws {
        let path = ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"]!
        print("REAL " + (try await run(URL(fileURLWithPath: path), throttled: false)))
    }

    /// Fast scrubbing on a real file: 2 s of trackpad events at 60 Hz, `step` frames each. Reports how many events
    /// had the exact frame on screen, how far the shown frame lagged, and how long the exact frame took after the stop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFileScrubbing() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"]!)
        var config = Config()
        config.cacheSizeMiB = 2048
        let player = PlayerCore(config: config, enableAudio: false)
        let delegate = CountingDelegate()
        player.delegate = delegate
        defer { player.close() }
        try player.open(url)
        _ = await eventually(timeout: 60) { player.index?.isExact == true }
        var start = player.index!.frameNumber(forSeconds: 60)
        for step in [1, 2, 4, 8] {
            player.seek(toFrame: start)
            _ = await eventually(timeout: 10) { player.displayedFrame == start }
            try await Task.sleep(for: .milliseconds(500))
            var exact = 0, lag = 0, events = 0
            for _ in 0..<120 {
                player.scrub(by: step)
                try await Task.sleep(for: .milliseconds(16))
                events += 1
                if player.displayedFrame == player.position { exact += 1 }
                lag += player.position - (player.displayedFrame ?? player.position)
            }
            let stopped = CACurrentMediaTime()
            _ = await eventually(timeout: 30) { player.displayedFrame == player.position }
            let settle = CACurrentMediaTime() - stopped
            print(String(format: "SCRUB step %d (%.0f fps of video): exact %d/%d, mean lag %.1f frames, exact after stop %.0f ms",
                         step, Double(step) * 60, exact, events, Double(lag) / Double(events), settle * 1000))
            // Straight back at 120 fps of video over what was just scrubbed.
            var backExact = 0
            for _ in 0..<60 {
                player.scrub(by: -2)
                try await Task.sleep(for: .milliseconds(16))
                if player.displayedFrame == player.position { backExact += 1 }
            }
            print("SCRUB   back step -2: exact \(backExact)/60")
            start = player.position + 600
        }
    }

    @Test func nasMKV() async throws {
        try NetworkFixtures.make()
        print("NAS " + (try await run(NetworkFixtures.mkv)))
    }

    /// What the screen does during fast scrubbing on a real file: 2 s of events at 60 Hz from a spot not yet
    /// decoded, forward and backward. Reports picture changes, the longest time the picture stood still
    /// while the user kept scrubbing, how far it lagged, and how long the exact frame took after the stop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFileScrubFreezes() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"]!)
        let player = PlayerCore(config: Config(), enableAudio: false)
        let delegate = TimedDelegate()
        player.delegate = delegate
        defer { player.close() }
        try player.open(url)
        _ = await eventually(timeout: 60) { player.index?.isExact == true }
        var spot = player.index!.frameNumber(forSeconds: 60)
        for step in (ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_STEPS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [4, 8, 16, -1, -2, -4, -8]) {
            player.seek(toFrame: spot)
            _ = await eventually(timeout: 10) { player.displayedFrame == spot }
            try await Task.sleep(for: .seconds(1))
            delegate.shown.removeAll()
            var exact = 0, lag = 0
            let began = CACurrentMediaTime()
            for _ in 0..<120 {
                player.scrub(by: step)
                try await Task.sleep(for: .milliseconds(16))
                if player.displayedFrame == player.position { exact += 1 }
                lag += abs(player.position - (player.displayedFrame ?? player.position))
            }
            let stopped = CACurrentMediaTime()
            _ = await eventually(timeout: 30) { player.displayedFrame == player.position }
            let settle = CACurrentMediaTime() - stopped
            let times = [began] + delegate.shown.map(\.time).filter { $0 < stopped } + [stopped]
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            print(String(format: "FREEZE step %+d (%.0f fps of video): %d picture changes, longest still %.0f ms, p90 %.0f ms; "
                         + "exact %d/120, mean lag %.1f frames, exact after stop %.0f ms",
                         step, Double(step) * 60, times.count - 2, gaps.last! * 1000, gaps[Int(Double(gaps.count - 1) * 0.9)] * 1000,
                         exact, Double(lag) / 120, settle * 1000) + " " + player.statsText.split(separator: "\n").filter { $0.hasPrefix("Decoder") }.joined())
            spot = player.position + 3000
        }
    }

    /// `hwdec`: playing a real file for 8 s (the decoder in use, CPU, frames shown on time), then pausing and
    /// scrubbing fast forward (stalls, as in `realFileScrubFreezes`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFilePlaybackThenScrub() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"]!)
        var config = Config()
        if let value = ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_HWDEC"] { config.hwdec = HardwareDecoding(rawValue: value)! }
        let player = PlayerCore(config: config, enableAudio: false)
        let delegate = TimedDelegate()
        player.delegate = delegate
        defer { player.close() }
        try player.open(url)
        _ = await eventually(timeout: 60) { player.index?.isExact == true }
        let spot = player.index!.frameNumber(forSeconds: 60)
        player.seek(toFrame: spot)
        _ = await eventually(timeout: 10) { player.displayedFrame == spot }
        try await Task.sleep(for: .seconds(1))
        func decoder() -> String { player.statsText.split(separator: "\n").first { $0.hasPrefix("Decoder") }.map(String.init) ?? "" }
        print("PLAY paused: \(decoder())")
        player.play()
        let ticker = Task { @MainActor in
            while !Task.isCancelled { player.tick(); try? await Task.sleep(for: .milliseconds(4)) }
        }
        try await Task.sleep(for: .seconds(2))
        let start = player.position
        let cpu = cpuSeconds(), wall = CACurrentMediaTime()
        delegate.shown.removeAll()
        try await Task.sleep(for: .seconds(6))
        let cores = (cpuSeconds() - cpu) / (CACurrentMediaTime() - wall)
        let times = delegate.shown.map(\.time)
        let longest = zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? 0
        print(String(format: "PLAY 6 s: %d frames shown of %d played, longest gap %.0f ms, CPU %.2f cores; %@",
                     delegate.shown.count, player.position - start, longest * 1000, cores, decoder()))
        ticker.cancel()
        player.pause()
        try await Task.sleep(for: .milliseconds(300))
        delegate.shown.removeAll()
        let began = CACurrentMediaTime()
        for _ in 0..<120 {
            player.scrub(by: 8)
            try await Task.sleep(for: .milliseconds(16))
        }
        let stopped = CACurrentMediaTime()
        let scrubTimes = [began] + delegate.shown.map(\.time).filter { $0 < stopped } + [stopped]
        let gaps = zip(scrubTimes.dropFirst(), scrubTimes).map { $0 - $1 }
        print(String(format: "PLAY then scrub +8: %d picture changes, longest still %.0f ms; %@",
                     scrubTimes.count - 2, (gaps.max() ?? 0) * 1000, decoder()))
    }

    /// Reverse playback (spec §7) through the whole player on a real file: for each speed of FRAMESCRUB_REV_SPEEDS
    /// (default 1,2,4), 20 s backward from FRAMESCRUB_REV_FROM seconds (default 900, then 300 s lower for each speed),
    /// frames shown per second against the speed's need, stills over 100 ms, the longest still and the level in stats.
    /// Heavy: run only with the external memory watchdog.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil
                   && ProcessInfo.processInfo.environment["FRAMESCRUB_REV_SPEEDS"] != nil))
    func realFileReverse() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["FRAMESCRUB_PERF_FILE"]!)
        let speeds = env["FRAMESCRUB_REV_SPEEDS"]!.split(separator: ",").compactMap { Double($0) }
        var from = env["FRAMESCRUB_REV_FROM"].flatMap(Double.init) ?? 900
        var config = Config()
        config.cacheSizeMiB = 2048
        let player = PlayerCore(config: config, enableAudio: false)
        let delegate = TimedDelegate()
        player.delegate = delegate
        defer { player.close() }
        try player.open(url)
        _ = await eventually(timeout: 60) { player.index?.isExact == true }
        let fps = player.info?.frameRate ?? 30
        for speed in speeds {
            let spot = player.index!.frameNumber(forSeconds: from)
            from -= 300
            player.seek(toFrame: spot)
            _ = await eventually(timeout: 10) { player.displayedFrame == spot }
            delegate.shown.removeAll()
            let began = CACurrentMediaTime()
            player.perform(.shuttleBack)
            while player.speed < speed { player.perform(.shuttleBack) }
            var level = ""
            while CACurrentMediaTime() - began < 20 {
                player.tick()
                if CACurrentMediaTime() - began > 10, level.isEmpty {
                    level = player.statsText.split(separator: "\n").first { $0.hasPrefix("Speed") }.map(String.init) ?? ""
                }
                try await Task.sleep(for: .milliseconds(4))
            }
            player.perform(.shuttleStop)
            let times = delegate.shown.map(\.time)
            let first = (times.first ?? began) - began
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
            print(String(format: "REVERSE −%g× %@: shown %.0f fps (needed %.0f), stills > 100 ms: %d, longest still %.0f ms, first frame after %.0f ms; %@",
                         speed, url.lastPathComponent, Double(times.count) / max(20 - first, 1), speed * fps,
                         gaps.filter { $0 > 0.1 }.count, (gaps.max() ?? 0) * 1000, first * 1000, level))
        }
    }

    /// Raw decoder speed on a real file: every frame, and a pre-roll from a keyframe with non-reference frames skipped.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFileDecodeSpeed() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"]!)
        let index = try MediaSource.containerIndex(url: url, readCache: nil) ?? MediaSource(url: url).buildIndex()
        let env = ProcessInfo.processInfo.environment
        let decoder = try VideoDecoder(source: MediaSource(url: url), index: index,
                                       preferHardware: env["FRAMESCRUB_PERF_SOFTWARE"] == nil,
                                       allowVideoToolboxBackend: env["FRAMESCRUB_PERF_FFMPEG_VT"] == nil)
        let start = index.keyframe(atOrBefore: min(index.frameNumber(forSeconds: 120), index.frameCount / 3))
        let next = index.keyframe(after: start)!
        try decoder.seek(toFrame: start)
        var t = CACurrentMediaTime()
        for _ in start..<next { _ = try decoder.nextFrame() }
        let cold = Double(next - start) / (CACurrentMediaTime() - t)
        try decoder.seek(toFrame: start)
        t = CACurrentMediaTime()
        let cpuBefore = cpuSeconds()
        for _ in start..<next { _ = try decoder.nextFrame() }
        let all = Double(next - start) / (CACurrentMediaTime() - t)
        let cpuPerFrame = (cpuSeconds() - cpuBefore) / Double(next - start)
        t = CACurrentMediaTime()
        try decoder.seek(toFrame: next - 1)   // pre-roll over the whole GOP
        _ = try decoder.nextFrame()
        let preroll = CACurrentMediaTime() - t
        print(String(format: "DECODE %@ (%@): GOP of %d frames, all frames %.0f fps (first read %.0f fps), pre-roll to its last frame %.0f ms (%.0f fps); CPU %.2f ms per frame",
                     decoder.codecName, decoder.backendKind.rawValue, next - start, all, cold, preroll * 1000, Double(next - start) / preroll, cpuPerFrame * 1000))
    }

    /// Scene cuts in a stretch of a real file, frames in order sampled as the player does, at most 30 a second
    /// (every second frame at 50/60 fps) (FRAMESCRUB_PERF_FROM / _SECONDS, default 600 / 240);
    /// FRAMESCRUB_PERF_CUTS=224.66,… (seconds from the stretch start) are the cuts it must find, and no others.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFileSceneCuts() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["FRAMESCRUB_PERF_FILE"]!)
        let from = env["FRAMESCRUB_PERF_FROM"].flatMap(Double.init) ?? 600
        let length = env["FRAMESCRUB_PERF_SECONDS"].flatMap(Double.init) ?? 240
        let index = try MediaSource.containerIndex(url: url, readCache: nil) ?? MediaSource(url: url).buildIndex()
        let source = try MediaSource(url: url)
        let decoder = try VideoDecoder(source: source, index: index, preferHardware: false)
        let step = max(1, Int((source.frameRate / 30 - 1e-6).rounded(.up)))
        let first = index.frameNumber(forSeconds: from)
        let last = min(index.frameCount - 1, index.frameNumber(forSeconds: from + length))
        try decoder.seek(toFrame: first)
        var detector = SceneCutDetector()
        var previous: SceneSignature?
        var cuts: [(seconds: Double, difference: Double)] = []
        var others: [Double] = []
        var signatureTime = 0.0, slowest = 0.0
        for n in first...last {
            guard let frame = try decoder.nextFrame() else { break }
            guard (n - first) % step == 0 else { continue }
            let image = FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: true)
            let t = CACurrentMediaTime()
            let signature = SceneSignature.of(image)
            let spent = CACurrentMediaTime() - t
            signatureTime += spent
            slowest = max(slowest, spent)
            let difference = previous.map { $0.difference(signature) } ?? 0
            if detector.isCut(signature), n > first {
                cuts.append((index.seconds(forFrame: n) - from, difference))
            } else if n > first {
                others.append(difference)
            }
            previous = signature
        }
        let count = Double((last - first) / step + 1)
        print(String(format: "SCENES %@ %.0f…%.0f s: %d frames, every %d compared; cuts %@; largest non-cuts %@; signature %.2f ms mean, %.2f ms max",
                     url.lastPathComponent, from, from + length, last - first + 1, step,
                     cuts.map { String(format: "%.2f s (%.1f)", $0.seconds, $0.difference) }.joined(separator: ", "),
                     others.sorted(by: >).prefix(5).map { String(format: "%.1f", $0) }.joined(separator: ", "),
                     signatureTime / count * 1000, slowest * 1000))
        if let expected = env["FRAMESCRUB_PERF_CUTS"] {
            let seconds = expected.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            #expect(cuts.count == seconds.count)
            for s in seconds { #expect(cuts.contains { abs($0.seconds - s) <= 0.1 }, "no cut near \(s) s") }
        }
    }

    /// Scene-jump calibration on a stretch of a real file (FRAMESCRUB_PERF_RANGE=start-end seconds, default 0-240):
    /// the look of every keyframe in it, three passes on fresh decoders without a shared read cache — VideoToolbox
    /// (first reads of the file), software, VideoToolbox again (both after the reads the first pass made; FRAMESCRUB_PERF_FIRST=sw
    /// swaps the decoders) — timed per
    /// keyframe (seek + read + decode + signature). Then ffmpeg `select='gt(scene,0.3)'` over the stretch gives the
    /// real cuts (run last so it warms no reads). Prints `PAIR t1 t2 diff(VT) diff(SW) label cuts histogram-distance` for every two bright
    /// keyframes in a row (dark ones between skipped), `CUT` for every ffmpeg cut, and a `SUMMARY`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil))
    func realFileSceneKeyframes() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["FRAMESCRUB_PERF_FILE"]!)
        let range = (env["FRAMESCRUB_PERF_RANGE"] ?? "0-240").split(separator: "-").compactMap { Double($0) }
        let (start, end) = (range[0], range[1])
        let indexed = CACurrentMediaTime()
        let index = try MediaSource.containerIndex(url: url, readCache: nil) ?? MediaSource(url: url).buildIndex()
        let indexTime = CACurrentMediaTime() - indexed
        let keyframes = index.keyframes.filter { index.seconds(forFrame: $0) >= start && index.seconds(forFrame: $0) <= end }
        let name = url.lastPathComponent

        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
        }
        func pass(hardware: Bool) throws -> (looks: [KeyframeLook], ms: [Double]) {
            let looks = try KeyframeLooks(url: url, index: index, rotationClockwise: 0, readCache: nil, preferHardware: hardware)
            var result: [KeyframeLook] = [], ms: [Double] = []
            for k in keyframes {
                let t = CACurrentMediaTime()
                result.append(try looks.look(at: k))
                ms.append((CACurrentMediaTime() - t) * 1000)
            }
            return (result, ms)
        }
        let vtFirst = env["FRAMESCRUB_PERF_FIRST"] != "sw"
        let first = try pass(hardware: vtFirst)
        let second = try pass(hardware: !vtFirst)
        let third = try pass(hardware: vtFirst)
        let (vtPass, software) = vtFirst ? (first, second) : (second, first)

        // Ground truth: ffmpeg's cuts (pts_time is from the -ss point).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-nostats", "-ss", "\(start)", "-t", "\(end - start)", "-i", url.path,
                             "-an", "-vf", "select='gt(scene,0.3)',showinfo", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        let ffmpegStarted = CACurrentMediaTime()
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let ffmpegTime = CACurrentMediaTime() - ffmpegStarted
        let cuts = output.split(separator: "\n").compactMap { line -> Double? in
            guard line.contains("Parsed_showinfo"), let r = line.range(of: "pts_time:") else { return nil }
            return Double(line[r.upperBound...].prefix { !$0.isWhitespace }).map { $0 + start }
        }
        for c in cuts { print(String(format: "CUT %@ %.3f", name, c)) }

        // Two bright keyframes in a row; "cut" when an ffmpeg cut lies in (t1, t2].
        let slack = (index.seconds(forFrame: 1) - index.seconds(forFrame: 0)) / 2
        // Exploratory second measure: distance of 16-bin colour histograms of the signatures, 0…100.
        func histogramDistance(_ x: SceneSignature, _ y: SceneSignature) -> Double {
            var h = [Int](repeating: 0, count: 96)
            for (i, v) in x.rgb.enumerated() { h[(i % 3) * 32 + Int(v) / 16] += 1 }
            for (i, v) in y.rgb.enumerated() { h[(i % 3) * 32 + 16 + Int(v) / 16] += 1 }
            var sum = 0
            for c in 0..<3 { for bin in 0..<16 { sum += abs(h[c * 32 + bin] - h[c * 32 + 16 + bin]) } }
            return Double(sum) / Double(2 * x.rgb.count) * 100
        }
        let bright = keyframes.indices.filter { if case .picture = vtPass.looks[$0] { return true } else { return false } }
        var same: [Double] = [], cut: [Double] = []
        for (a, b) in zip(bright, bright.dropFirst()) {
            guard case .picture(let s1) = vtPass.looks[a], case .picture(let s2) = vtPass.looks[b] else { continue }
            let t1 = index.seconds(forFrame: keyframes[a]), t2 = index.seconds(forFrame: keyframes[b])
            let swDiff: Double
            if case .picture(let w1) = software.looks[a], case .picture(let w2) = software.looks[b] { swDiff = w1.difference(w2) } else { swDiff = .nan }
            let difference = s1.difference(s2)
            // ffmpeg's times can lie a tick past the keyframe the cut is on: half a frame of slack.
            let inside = cuts.filter { $0 > t1 + slack && $0 <= t2 + slack }
            if inside.isEmpty { same.append(difference) } else { cut.append(difference) }
            print(String(format: "PAIR %@ %.3f %.3f %.2f %.2f %@ %d %.1f", name, t1, t2, difference, swDiff,
                         inside.isEmpty ? "same" : "cut", inside.count, histogramDistance(s1, s2)))
        }
        let gaps = zip(keyframes.dropFirst(), keyframes).map { index.seconds(forFrame: $0) - index.seconds(forFrame: $1) }
        let dark = vtPass.looks.filter { $0 == .dark }.count
        let darkSW = software.looks.filter { $0 == .dark }.count
        func timing(_ label: String, _ ms: [Double]) -> String {
            String(format: "%@ median %.1f p90 %.1f max %.1f ms", label, percentile(ms, 0.5), percentile(ms, 0.9), ms.max() ?? .nan)
        }
        print(String(format: "SUMMARY %@ %.0f-%.0f s: %d keyframes (interval median %.2f s, max %.2f s), %d dark (SW %d), %d ffmpeg cuts (ffmpeg %.0f s), index %.1f s; "
                     + "same pairs %d max %.2f p99 %.2f p95 %.2f; cut pairs %d min %.2f p5 %.2f",
                     name, start, end, keyframes.count, percentile(gaps, 0.5), gaps.max() ?? .nan, dark, darkSW, cuts.count, ffmpegTime, indexTime,
                     same.count, same.max() ?? .nan, percentile(same, 0.99), percentile(same, 0.95),
                     cut.count, cut.min() ?? .nan, percentile(cut, 0.05)))
        let (a, b) = vtFirst ? ("VT", "SW") : ("SW", "VT")
        print("SUMMARY \(name) per keyframe: " + [timing("\(a) cold", first.ms), timing(b, second.ms), timing("\(a) warm", third.ms)].joined(separator: "; "))
    }

    /// Near-duplicate calibration on a stretch of a real file (FRAMESCRUB_PERF_FROM / _SECONDS, default 600 / 120):
    /// cell differences of neighbouring frames (noise), the changed share at several noise levels, and how many
    /// frames a 1 fps export would keep at several thresholds.
    /// Thumbnails and signatures of a stretch sampled every FRAMESCRUB_PERF_STEP seconds (default 0.25), written to
    /// FRAMESCRUB_PERF_DUMP for looking at the near-duplicate thresholds by eye.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil
                   && ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_DUMP"] != nil))
    func realFileDuplicateDump() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["FRAMESCRUB_PERF_FILE"]!)
        let out = URL(fileURLWithPath: env["FRAMESCRUB_PERF_DUMP"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let from = env["FRAMESCRUB_PERF_FROM"].flatMap(Double.init) ?? 600
        let length = env["FRAMESCRUB_PERF_SECONDS"].flatMap(Double.init) ?? 60
        let step = env["FRAMESCRUB_PERF_STEP"].flatMap(Double.init) ?? 0.25
        let index = try MediaSource.containerIndex(url: url, readCache: nil) ?? MediaSource(url: url).buildIndex()
        let decoder = try VideoDecoder(source: MediaSource(url: url), index: index, preferHardware: true)
        let first = index.frameNumber(forSeconds: from)
        let last = min(index.frameCount - 1, index.frameNumber(forSeconds: from + length))
        let wanted = Set(ExportSelection.perSecond(1 / step).frames(in: first...last, index: index))
        try decoder.seek(toFrame: first)
        let context = CIContext(options: [.cacheIntermediates: false])
        var signatures = Data()
        var numbers: [Int] = []
        while let frame = try decoder.nextFrame(), frame.number <= last {
            guard wanted.contains(frame.number) else { continue }
            let image = FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: true)
            signatures.append(contentsOf: SceneSignature.of(image).rgb)
            let scale = 320 / image.extent.width
            let thumb = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let jpeg = context.jpegRepresentation(of: thumb, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7])
            try jpeg?.write(to: out.appendingPathComponent(String(format: "f%06d.jpg", frame.number)))
            numbers.append(frame.number)
        }
        try signatures.write(to: out.appendingPathComponent("signatures.bin"))
        try numbers.map(String.init).joined(separator: "\n").write(to: out.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        print("DUMP \(numbers.count) frames to \(out.path)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_FILE"] != nil
                   && ProcessInfo.processInfo.environment["FRAMESCRUB_PERF_DUPLICATES"] != nil))
    func realFileDuplicates() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["FRAMESCRUB_PERF_FILE"]!)
        let from = env["FRAMESCRUB_PERF_FROM"].flatMap(Double.init) ?? 600
        let length = env["FRAMESCRUB_PERF_SECONDS"].flatMap(Double.init) ?? 120
        let index = try MediaSource.containerIndex(url: url, readCache: nil) ?? MediaSource(url: url).buildIndex()
        let decoder = try VideoDecoder(source: MediaSource(url: url), index: index, preferHardware: true)
        let first = index.frameNumber(forSeconds: from)
        let last = min(index.frameCount - 1, index.frameNumber(forSeconds: from + length))
        try decoder.seek(toFrame: first)
        var signatures: [SceneSignature] = []
        for _ in first...last {
            guard let frame = try decoder.nextFrame() else { break }
            signatures.append(.of(FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: true)))
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let cells = zip(signatures, signatures.dropFirst()).flatMap { $0.cellDifferences($1) }.map(Double.init)
        print(String(format: "DUPES %@ %.0f…%.0f s, %d frames; neighbour cell difference p50 %.0f p90 %.0f p99 %.0f p99.9 %.0f",
                     url.lastPathComponent, from, from + length, signatures.count,
                     percentile(cells, 0.5), percentile(cells, 0.9), percentile(cells, 0.99), percentile(cells, 0.999)))
        let second = max(1, index.frameNumber(forSeconds: from + 1) - first)
        for noise in [4, 8, 12, 16, 24, 32] {
            let neighbours = zip(signatures, signatures.dropFirst()).map { $0.changedShare($1, noise: noise) * 100 }
            let apart = zip(signatures, signatures.dropFirst(second)).map { $0.changedShare($1, noise: noise) * 100 }
            var kept: [String] = []
            for threshold in [1.0, 2, 5, 10, 20, 40] {
                var last: SceneSignature?
                var count = 0
                for s in stride(from: 0, to: signatures.count, by: second) {
                    if let l = last, l.changedShare(signatures[s], noise: noise) * 100 < threshold { continue }
                    last = signatures[s]
                    count += 1
                }
                kept.append(String(format: "%g%%→%d", threshold, count))
            }
            print(String(format: "DUPES noise %2d: neighbours %% p50 %.1f p90 %.1f p99 %.1f; 1 s apart p10 %.1f p50 %.1f p90 %.1f; 1 fps keeps %@ of %d",
                         noise, percentile(neighbours, 0.5), percentile(neighbours, 0.9), percentile(neighbours, 0.99),
                         percentile(apart, 0.1), percentile(apart, 0.5), percentile(apart, 0.9),
                         kept.joined(separator: " "), (signatures.count + second - 1) / second))
        }
    }
}

/// User and system CPU time of this process so far.
private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}
