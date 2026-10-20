import Testing
@testable import FrameScrubCore

struct GoToTargetTests {
    @Test(arguments: [
        ("1:23", GoToTarget.seconds(83)),
        ("1:23.456", .seconds(83.456)),
        ("1:02:03.5", .seconds(3723.5)),
        ("83.4", .seconds(83.4)),
        ("83,4", .seconds(83.4)),          // a decimal comma, as typed on a Russian layout
        ("  42 ", .seconds(42)),
        ("0", .seconds(0)),
        ("f1234", .frame(1234)),
        ("F1234", .frame(1234)),
        ("#1234", .frame(1234)),
        ("# 12", .frame(12)),
    ] as [(String, GoToTarget)])
    func parses(_ text: String, expected: GoToTarget) {
        #expect(GoToTarget.parse(text) == expected)
    }

    @Test(arguments: ["", "abc", "-5", "1:", ":30", "1:60", "1:2:3:4", "f", "f-3", "f1.5", "1:23x", "1::2"])
    func rejects(_ text: String) {
        #expect(GoToTarget.parse(text) == nil)
    }
}
