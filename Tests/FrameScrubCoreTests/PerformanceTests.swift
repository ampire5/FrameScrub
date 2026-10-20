import CoreImage
import Foundation
import Metal
import QuartzCore
import Testing
@testable import FrameScrubCore

/// Opt-in: FRAMESCRUB_PERF=1 swift test --filter PerformanceTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FRAMESCRUB_PERF"] != nil))
struct PerformanceTests {
    struct Result {
        var hits = 0
        var missLatencies: [Double] = []
        var all: [Double] = []
        var wrong = 0
        var framesInBudget = 0
        var p99: Double { all.sorted()[Int(Double(all.count - 1) * 0.99)] }
        var summary: String {
            let m = missLatencies.sorted()
            let med = m.isEmpty ? 0 : m[m.count / 2]
            return "\(all.count) steps, ~\(framesInBudget) frames in budget, hits \(hits), misses \(m.count) "
                + "(median \(String(format: "%.1f", med * 1000)) ms, max \(String(format: "%.1f", (m.last ?? 0) * 1000)) ms), "
                + "p99 \(String(format: "%.2f", p99 * 1000)) ms, wrong frames \(wrong)"
        }
    }

    /// Scrubs backward one frame every 16 ms (60 steps/s). Latency = time from just before
    /// setFocus until the frame is in the cache (polled at 0.5 ms); frame identity is verified.
    /// Spec target: p99 < 16 ms once the window is warm.
    private func backwardScrub(_ name: String, budgetMiB: Int, from start: Int, to end: Int, passes: Int) async throws -> Result {
        let (source, index) = try openIndexed(name)
        let cache = FrameCache(budgetBytes: budgetMiB << 20)
        let filler = CacheFiller(url: source.url, index: index, cache: cache,
                                 estimatedFrameBytes: source.estimatedFrameBytes, playbackLookahead: 60)
        filler.start()
        defer { filler.stop() }

        var result = Result()
        for _ in 0..<passes {
            filler.setFocus(start, mode: .paused)
            _ = await eventually(timeout: 10) { cache.contains(start) }
            try await Task.sleep(for: .seconds(1))   // warm the backward window
            for n in stride(from: start - 1, through: end, by: -1) {
                let begin = Date()
                filler.setFocus(n, mode: .paused, direction: -1)
                var frame = cache.frame(n)
                if frame != nil { result.hits += 1 }
                while frame == nil && Date().timeIntervalSince(begin) < 5 {
                    try await Task.sleep(for: .microseconds(500))
                    frame = cache.frame(n)
                }
                let latency = Date().timeIntervalSince(begin)
                if latency > 0.001 || frame == nil { result.missLatencies.append(latency) }
                result.all.append(latency)
                if let frame, readFrameNumber(frame.pixelBuffer) == n {} else { result.wrong += 1 }
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        result.framesInBudget = (budgetMiB << 20) / max(cache.averageFrameBytes ?? 1, 1)
        return result
    }

    @Test func backwardScrub1080p() async throws {
        let r = try await backwardScrub(Fixtures.h264, budgetMiB: 300, from: 599, to: 10, passes: 1)
        print("1080p H.264 backward scrub: \(r.summary)")
        #expect(r.wrong == 0)
        #expect(r.p99 < 0.016)
    }

    @Test func backwardScrub4KHDR() async throws {
        let r = try await backwardScrub(Fixtures.hevc10, budgetMiB: 768, from: 119, to: 0, passes: 3)
        print("4K HEVC HLG backward scrub: \(r.summary)")
        #expect(r.wrong == 0)
        #expect(r.p99 < 0.016)
    }

    /// Cost of the on-screen colour correction on a 4K frame (backlog §6): GPU time per drawn frame
    /// with and without it, and the one-off analysis behind `V`.
    @Test func colorCorrection4K() throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seek(toFrame: 10)
        let frame = try #require(try decoder.nextFrame())
        let image = FrameImageRenderer.displayImage(for: frame, rotationClockwise: 0, plan: .toSDR)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 3840, height: 2160, mipmapped: false)
        descriptor.usage = [.shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        func median(_ correction: ColorCorrection) throws -> Double {
            var times: [Double] = []
            for _ in 0..<40 {
                let buffer = try #require(queue.makeCommandBuffer())
                let start = CACurrentMediaTime()
                _ = try context.startTask(toRender: correction.apply(to: image),
                                          to: CIRenderDestination(mtlTexture: texture, commandBuffer: buffer))
                buffer.commit()
                buffer.waitUntilCompleted()
                times.append(CACurrentMediaTime() - start)
            }
            return times.sorted()[times.count / 2] * 1000
        }
        let start = CACurrentMediaTime()
        let auto = ColorCorrection.autoAdjustment(for: image)
        let analysis = (CACurrentMediaTime() - start) * 1000
        let plain = try median(.identity)
        let vibrance = try median(ColorCorrection(vibrance: 0.5))
        let both = try median(ColorCorrection(vibrance: 0.5, auto: auto))
        print(String(format: "4K colour correction: plain %.2f ms, vibrance %.2f ms, auto+vibrance %.2f ms (%@); analysis %.0f ms",
                     plain, vibrance, both, auto.map(\.name).joined(separator: ", "), analysis))
        #expect(both - plain < 4)
    }
}
