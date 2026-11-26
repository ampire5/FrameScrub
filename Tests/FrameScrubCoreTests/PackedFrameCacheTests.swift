import CoreVideo
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PackedFrameCacheTests {
    private func frame(number: Int) throws -> DecodedFrame {
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 130, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &result)
        try #require(status == 0)
        let buffer = try #require(result)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == 0)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                for x in 0..<130 {
                    base[row * stride + x] = UInt8((x / 32) * 12 + row % 4 + (plane == 0 ? 5 : (x % 2) * 117))
                }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return DecodedFrame(number: number, pts: 73, pixelBuffer: buffer, dynamicRange: .sdr, pictureType: "B")
    }

    @Test func restoresFullRangePaddedNV12WithMetadata() throws {
        let source = try frame(number: 37)
        let packed = try #require(PackedNV12Frame(source))
        let restored = try #require(packed.restore())
        #expect(packed.byteSize < source.byteSize)
        #expect(restored.number == 37 && restored.pts == 73 && restored.pictureType == "B")
        #expect(CVPixelBufferGetPixelFormatType(restored.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(CVBufferCopyAttachment(restored.pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) != nil)
        for buffer in [source.pixelBuffer, restored.pixelBuffer] { CVPixelBufferLockBaseAddress(buffer, .readOnly) }
        defer { for buffer in [source.pixelBuffer, restored.pixelBuffer] { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) } }
        for plane in 0..<2 {
            let a = CVPixelBufferGetBaseAddressOfPlane(source.pixelBuffer, plane)!
            let b = CVPixelBufferGetBaseAddressOfPlane(restored.pixelBuffer, plane)!
            for row in 0..<CVPixelBufferGetHeightOfPlane(source.pixelBuffer, plane) {
                let aRow = a + row * CVPixelBufferGetBytesPerRowOfPlane(source.pixelBuffer, plane)
                let bRow = b + row * CVPixelBufferGetBytesPerRowOfPlane(restored.pixelBuffer, plane)
                #expect(memcmp(aRow, bRow, 130) == 0)
            }
        }
    }

    @Test func distantFrameStaysResidentAndReturnsToReadyWindow() async throws {
        let cache = FrameCache(budgetBytes: 1 << 20, packsNV12: true)
        cache.observeTierChanges { _, _ in }
        cache.setFocus(0, backShare: 0.5)
        cache.insert(try frame(number: 0))
        cache.insert(try frame(number: 30))
        try await waitUntil { cache.packedFrameCount == 1 }
        #expect(cache.frame(0) != nil)
        #expect(cache.frame(30) == nil)
        #expect(!cache.hasReadyFrame(30) && cache.contains(30))
        #expect(cache.isResolved(30))
        #expect(cache.cachedRanges() == [0...0, 30...30])
        cache.setFocus(30, backShare: 0.5)
        try await waitUntil { cache.frame(30) != nil }
        #expect(cache.frame(30)?.pts == 73)

        // A fresh frame can pack five steps away while the restored picture
        // stays ready seven steps away. The latter can pack again at ten steps.
        cache.setFocus(23, backShare: 0.5)
        cache.insert(try frame(number: 23))
        cache.insert(try frame(number: 18))
        try await waitUntil { cache.residency(18).packed }
        #expect(cache.hasReadyFrame(30))
        cache.setFocus(20, backShare: 0.5)
        cache.insert(try frame(number: 20))
        try await waitUntil { cache.residency(30).packed }

        cache.removeAll()
        #expect(cache.count == 0 && cache.usedBytes == 0)
    }

    @Test func coarseForwardScrubbingPacksHistoryAndKeepsLookaheadReady() async throws {
        let cache = FrameCache(budgetBytes: 1 << 20, packsNV12: true)
        cache.observeTierChanges { _, _ in }
        cache.setFocus(30, backShare: 0.25, keepsForwardFramesReady: true)
        cache.insert(try frame(number: 30))
        cache.insert(try frame(number: 45))
        cache.insert(try frame(number: 15))
        try await waitUntil { cache.residency(15).packed }
        #expect(cache.hasReadyFrame(45))

        cache.setFocus(30, backShare: 0.25)
        try await waitUntil { cache.residency(45).packed }
    }

    @Test func exactClipStaysReadyUntilTheBudgetCanNoLongerHoldIt() async throws {
        let focus = try frame(number: 0)
        let distant = try frame(number: 30)
        let index = FrameIndex(pts: (0..<64).map(Int64.init), keyframePTS: [0], timeBase: 1)
        let cache = FrameCache(budgetBytes: 96 * focus.byteSize, packsNV12: true)
        let filler = CacheFiller(url: URL(filePath: "/unused"), index: index, cache: cache,
                                 estimatedFrameBytes: focus.byteSize, playbackLookahead: 60)
        filler.updateIndex(index, clearCache: false)
        cache.observeTierChanges { _, _ in }
        cache.insert(focus)
        cache.insert(distant)

        try await Task.sleep(for: .milliseconds(120))
        #expect(cache.hasReadyFrame(30))
        #expect(cache.activity.demotions == 0)

        cache.budgetBytes = 16 * focus.byteSize
        try await waitUntil { cache.packedFrameCount == 1 }
        #expect(cache.contains(30))
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !done() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(done())
    }
}
