import Foundation
import Testing
@testable import FrameScrubCore

struct NetworkPolicyTests {
    @Test func theModeDecidesWhenItIsNotAuto() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        #expect(NetworkPolicy.resolve(.yes, url: url) == .network)
        #expect(NetworkPolicy.resolve(.no, url: URL(string: "https://example.com/a.mp4")!) == .local)
    }

    @Test func autoLooksAtTheVolume() {
        #expect(!NetworkPolicy.isOnNetworkVolume(URL(fileURLWithPath: NSTemporaryDirectory())))
        #expect(NetworkPolicy.isOnNetworkVolume(URL(string: "https://example.com/a.mp4")!))
        #expect(NetworkPolicy.resolve(.auto, url: URL(fileURLWithPath: "/nonexistent/a.mp4")) == .local)
    }

    @Test func theNetworkPolicyReadsGently() {
        let n = NetworkPolicy.network, l = NetworkPolicy.local
        #expect(n.readAheadSeconds > l.readAheadSeconds)
        #expect(!n.sideReadAhead && l.sideReadAhead)
        #expect(n.barSamples < l.barSamples && n.barsDelay > 0 && n.previewSettle > 0)
        #expect(n.frameAheadSeconds != nil && l.frameAheadSeconds == nil)
    }
}
