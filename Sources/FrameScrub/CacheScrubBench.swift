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
    }

    private let core: PlayerCore
    private let window: NSWindow
    private let videoView = VideoView()
    private let paced: Bool
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

    private init(compressed: Bool, paced: Bool) {
        var config = Config()
        config.cacheSizeMiB = 256
        config.autoplay = false
        config.networkMode = .no
        core = PlayerCore(config: config, enableAudio: false, cacheCompression: compressed)
        self.paced = paced
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
        core.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func launch() -> Never {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--bench-cache-scrub"), args.count == index + 4,
              ["plain", "compressed"].contains(args[index + 2]), ["burst", "ack"].contains(args[index + 3]) else {
            fail("Usage: FrameScrub --bench-cache-scrub VIDEO plain|compressed burst|ack")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        Task { @MainActor in
            let bench = CacheScrubBench(compressed: args[index + 2] == "compressed", paced: args[index + 3] == "burst")
            do {
                try await bench.run(URL(filePath: args[index + 1]))
                bench.videoView.stop()
                bench.core.close()
                bench.window.orderOut(nil)
                fflush(nil)
                exit(0)
            } catch { fail(String(describing: error)) }
        }
        app.run()
        fail("Benchmark run loop ended")
    }

    private struct Failure: Error { let message: String }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        fflush(nil)
        exit(1)
    }

    private func run(_ url: URL) async throws {
        try await Task.sleep(for: .milliseconds(350))
        guard window.occlusionState.contains(.visible) else { throw Failure(message: "Benchmark window is occluded") }
        let prepare = core.preparation(for: url)
        let prepared = try await Task.detached(priority: .userInitiated) { try prepare() }.value
        core.open(prepared)
        let deadline = ContinuousClock.now + .seconds(6)
        while (core.index?.isExact != true || !core.cache.hasReadyFrame(core.position)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        guard core.index?.isExact == true, core.frameCount >= 72 else {
            throw Failure(message: "Benchmark needs an exact index with at least 72 frames")
        }
        let origin = 20
        core.seek(toFrame: origin)
        while !core.cache.hasReadyFrame(origin), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard core.cache.hasReadyFrame(origin) else { throw Failure(message: "Could not warm the starting frame") }
        try await Task.sleep(for: .milliseconds(100))
        let before = core.cache.activity
        lastInsertions = before.decodedInsertions
        let started = CACurrentMediaTime()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for round in 0..<3 {
            for direction in [1, -1] {
                for _ in 0..<48 {
                    if paced {
                        let until = started + Double(inputs.count) / 59 - CACurrentMediaTime()
                        if until > 0 { try await Task.sleep(for: .seconds(until)) }
                    }
                    guard window.occlusionState.contains(.visible) else {
                        throw Failure(message: "Window became occluded on round \(round + 1)")
                    }
                    var target = core.position + direction
                    while core.cache.isUndecodable(target), (0..<core.frameCount).contains(target + direction) {
                        target += direction
                    }
                    let residence = core.cache.residency(target)
                    let tier = residence.ready ? "ready" : residence.packed ? "packed" : "miss"
                    inputs.append(Input(number: target, direction: direction, started: CACurrentMediaTime(), tier: tier))
                    let request = inputs.count - 1
                    pending = request
                    core.scrub(by: direction)
                    if !paced { await awaitPresentation(request) }
                }
            }
        }
        if paced, let pending { await awaitPresentation(pending) }
        try await Task.sleep(for: .milliseconds(75))
        let seconds = CACurrentMediaTime() - started
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStarted) / 1e7 / seconds
        let after = core.cache.activity
        print("formats=\(formats.sorted().joined(separator: ",")) decoder=\(core.playbackDecoderKind?.rawValue ?? "unknown") hz=\(window.screen?.maximumFramesPerSecond ?? 0) " +
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
        guard after.decodedInsertions > before.decodedInsertions, boundaryChanges > 0 else {
            throw Failure(message: "Trace did not exercise moving boundaries and live filling")
        }
    }

    private func awaitPresentation(_ request: Int) async {
        if inputs[request].presented != nil { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
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
        print(String(format: "%@ requests=%d shown=%d missed=%d p50_ms=%.2f p95_ms=%.2f p99_ms=%.2f max_ms=%.2f",
                     name, inputs.count, values.count, inputs.count - values.count,
                     percentile(0.50), percentile(0.95), percentile(0.99), values.last ?? .nan))
    }

    func player(_ player: PlayerCore, display frame: DecodedFrame) {
        if let pending, inputs[pending].number == frame.number {
            let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            formats.insert(String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) }, as: UTF8.self))
            videoView.onBenchPresented = { [weak self] time in
                guard let self, inputs[pending].presented == nil, time >= inputs[pending].started else { return }
                inputs[pending].presented = (time - inputs[pending].started) * 1000
                if self.pending == pending { self.completeWait() }
            }
        } else {
            videoView.onBenchPresented = nil
        }
        videoView.show(frame, playing: false)
    }

    func playerStateDidChange(_ player: PlayerCore) {
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
