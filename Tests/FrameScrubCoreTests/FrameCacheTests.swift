import CoreVideo
import Testing
@testable import FrameScrubCore

@Suite struct FrameCacheTests {
    private static let buffer: CVPixelBuffer = {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        return pb!
    }()

    private func frame(_ n: Int, bytes: Int = 100) -> DecodedFrame {
        DecodedFrame(number: n, pts: Int64(n), pixelBuffer: Self.buffer, dynamicRange: .sdr, byteSize: bytes)
    }

    @Test func storesAndReplacesFrames() {
        let cache = FrameCache(budgetBytes: 10_000)
        cache.insert(frame(5))
        #expect(cache.frame(5)?.number == 5)
        #expect(cache.contains(5))
        #expect(!cache.contains(6))
        #expect(cache.usedBytes == 100)
        cache.insert(frame(5))
        #expect(cache.usedBytes == 100)
        #expect(cache.averageFrameBytes == 100)
    }

    @Test func averageFrameBytesReflectsCurrentContents() {
        let cache = FrameCache(budgetBytes: 1_000_000)
        #expect(cache.averageFrameBytes == nil)
        for n in 0..<10 { cache.insert(frame(n, bytes: 100)) }
        cache.removeAll()
        #expect(cache.averageFrameBytes == nil)
        cache.insert(frame(0, bytes: 1000))
        #expect(cache.averageFrameBytes == 1000)
    }

    @Test func evictsFramesFarthestFromFocus() {
        let cache = FrameCache(budgetBytes: 1000)
        cache.setFocus(50, backShare: 0.5)
        for n in 0..<100 {
            cache.insert(frame(n))
            #expect(cache.usedBytes <= 1000)
        }
        #expect(cache.count == 10)
        #expect(cache.contains(50))
        for n in 0..<100 where cache.contains(n) { #expect(abs(n - 50) <= 6) }
    }

    @Test func backShareKeepsMoreHistory() {
        let cache = FrameCache(budgetBytes: 2000)   // 20 frames
        cache.setFocus(100, backShare: 0.75)
        for n in 50..<150 { cache.insert(frame(n)) }
        let behind = (50..<100).filter(cache.contains).count
        let ahead = (101..<150).filter(cache.contains).count
        #expect((13...16).contains(behind))
        #expect((3...6).contains(ahead))
    }

    @Test func shrinkingBudgetEvicts() {
        let cache = FrameCache(budgetBytes: 1000)
        cache.setFocus(0, backShare: 0.6)
        for n in 0..<10 { cache.insert(frame(n)) }
        cache.budgetBytes = 500
        #expect(cache.count == 5)
        #expect((0..<5).allSatisfy(cache.contains))
    }

    @Test func resolvedRunSpansUndecodableFrames() {
        let cache = FrameCache(budgetBytes: 10_000)
        for n in [10, 11, 13, 14] { cache.insert(frame(n)) }
        cache.markUndecodable(12)
        #expect(cache.resolvedRun(around: 13) == 10...14)
        #expect(cache.resolvedRun(around: 15) == nil)
        #expect(cache.isResolved(12))
        #expect(cache.isUndecodable(12))
        #expect(!cache.contains(12))
        #expect(cache.cachedRanges() == [10...11, 13...14])
    }

    @Test func nearestAvailablePrefersCloserThenLower() {
        let cache = FrameCache(budgetBytes: 10_000)
        cache.insert(frame(10))
        cache.insert(frame(20))
        #expect(cache.nearestAvailable(to: 14)?.number == 10)
        #expect(cache.nearestAvailable(to: 16)?.number == 20)
        #expect(cache.nearestAvailable(to: 15)?.number == 10)
    }

    @Test func removeAllClearsEverything() {
        let cache = FrameCache(budgetBytes: 10_000)
        cache.insert(frame(1))
        cache.markUndecodable(2)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.usedBytes == 0)
        #expect(!cache.isResolved(2))
    }

    @Test func nearestWithinARange() {
        let cache = FrameCache(budgetBytes: 10_000)
        for n in [10, 14, 20] { cache.insert(frame(n)) }
        #expect(cache.nearest(to: 15, within: 12...18)?.number == 14)
        #expect(cache.nearest(to: 19, within: 15...20)?.number == 20)
        #expect(cache.nearest(to: 16, within: 15...19) == nil)
    }
}
