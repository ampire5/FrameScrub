import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ContainerIndexTests {
    @Test(arguments: [Fixtures.h264, Fixtures.hevc10, Fixtures.vfr, Fixtures.withAudio, Fixtures.rotated,
                      Fixtures.fragmented, Fixtures.editList])
    func matchesTheScanWithoutReadingFrameData(_ name: String) throws {
        let url = Fixtures.url(name)
        let scan = try MediaSource(url: url).buildIndex()
        let cache = try ReadCache(url: url, budgetBytes: 0)
        let index = try #require(try MediaSource.containerIndex(url: url, readCache: cache))
        #expect(index.frameCount == scan.frameCount)
        #expect(index.keyframes == scan.keyframes)
        #expect(index.zeroPTS == scan.zeroPTS)
        #expect((0..<scan.frameCount).allSatisfy { index.pts(forFrame: $0) == scan.pts(forFrame: $0) })
        #expect(cache.stats.bytesFromFile < 2 << 20)   // the header only
    }

    @Test(arguments: [Fixtures.av1, Fixtures.noDecoder])
    func otherContainersFallBack(_ name: String) throws {
        #expect(try MediaSource.containerIndex(url: Fixtures.url(name), readCache: nil) == nil)
    }

    @Test func checksRejectMismatches() {
        #expect(MediaSource.acceptsContainerIndex(packets: 600, declaredFrames: 600, lastFrameSeconds: 19.9, durationSeconds: 20))
        #expect(!MediaSource.acceptsContainerIndex(packets: 0, declaredFrames: 0, lastFrameSeconds: 0, durationSeconds: 0))
        #expect(!MediaSource.acceptsContainerIndex(packets: 590, declaredFrames: 600, lastFrameSeconds: 19.9, durationSeconds: 20))
        #expect(!MediaSource.acceptsContainerIndex(packets: 300, declaredFrames: 0, lastFrameSeconds: 9.9, durationSeconds: 20))
        #expect(MediaSource.acceptsContainerIndex(packets: 600, declaredFrames: 0, lastFrameSeconds: 19.2, durationSeconds: 20))
    }
}
