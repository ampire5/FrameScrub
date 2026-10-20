import Foundation
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
}
