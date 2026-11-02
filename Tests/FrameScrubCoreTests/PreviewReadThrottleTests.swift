import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PreviewReadThrottleTests {
    @Test func firstReadIsImmediateAndMovingPointerCannotPostponeAllReads() {
        var throttle = PreviewReadThrottle(interval: 0.25)
        #expect(throttle.delay(at: 10) == 0)
        throttle.started(at: 10)
        #expect(abs(throttle.delay(at: 10.05) - 0.2) < 0.0001)
        // Newer requests replace one another during the wait; at the deadline
        // the latest request must be allowed, rather than waiting another 250 ms.
        #expect(throttle.delay(at: 10.25) == 0)
        throttle.started(at: 10.25)
        #expect(abs(throttle.delay(at: 10.3) - 0.2) < 0.0001)
    }
    @Test func localPreviewsHaveNoArtificialWait() {
        var throttle = PreviewReadThrottle(interval: 0)
        throttle.started(at: 10)
        #expect(throttle.delay(at: 10.001) == 0)
    }
}

extension PreviewReadThrottleTests {
    @Test @MainActor func cachedImageBypassesAColdReadWaitingForItsSlot() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let provider = PreviewProvider(url: source.url, index: index, rotationClockwise: 0, widthPixels: 160, policy: .network)
        defer { provider.stop() }
        var received: [Double] = []
        provider.onImage = { received.append($0.requestedSeconds) }
        provider.request(seconds: 0)
        #expect(await eventually { received.count == 1 })
        provider.request(seconds: 10)   // another keyframe: waits for the network read slot
        try await Task.sleep(for: .milliseconds(25))
        provider.request(seconds: 0.1) // already cached; must not queue behind that cold read
        #expect(await eventually(timeout: 0.12) { received.contains(0.1) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.last == 0.1)   // old cold request must not replace the newer cached image
    }
}
