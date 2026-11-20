import Foundation
import Synchronization
import Testing
@testable import FrameScrubCore

@Suite struct PathAvailabilityTests {
    /// A share that does not answer must not hold the start screen: the check gives up after `timeout` (nil). The
    /// answer for "/slow" being nil shows the deadline won over the 6 s check; wall time is not measured, since a
    /// full parallel run can hold the waiting task back for many seconds.
    @Test func existenceCheckTimesOut() async {
        let result = await PathAvailability.check(["/slow", "/here", "/gone"], timeout: .seconds(1)) { path in
            if path == "/slow" { Thread.sleep(forTimeInterval: 6) }
            return path == "/here"
        }
        #expect(result["/slow"] == .some(nil))
        #expect(result["/here"] == .some(true))
        #expect(result["/gone"] == .some(false))
    }

    @Test func aBlockedDirectoryDoesNotHoldHealthyPathsOrStartAnotherReadOnRefresh() async {
        let checks = PathAvailability.DirectoryChecks(limit: 2)
        let release = DispatchSemaphore(value: 0)
        let slowReads = Mutex(0)
        let read: @Sendable (String) -> Bool = { path in
            if path == "/slow", slowReads.withLock({ count in
                count += 1
                return count == 1
            }) { release.wait() }
            return true
        }
        let pending = Task { await checks.check(["/slow"], timeout: .seconds(90), read: read) }
        #expect(await eventually(timeout: 30) { slowReads.withLock { $0 } == 1 })
        let refreshed = await checks.check(["/slow", "/near", "/later"], timeout: .seconds(90), read: read)
        release.signal()
        #expect(refreshed == ["/near": true, "/later": true])
        #expect(await pending.value == ["/slow": true])
        #expect(slowReads.withLock { $0 } == 1)
    }

}
