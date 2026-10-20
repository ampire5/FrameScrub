import Testing
import LogiHIDPP
@testable import FrameScrubCore

@Suite struct MouseSettingsTests {
    @Test func hapticDefaultsMatchSpec() {
        let expected: [(HapticEvent, String)] = [
            (.step, "whisper-collision"), (.detent, "damp-collision"), (.limit, "sharp-collision"),
            (.longArmed, "damp-state-change"), (.toggle, "sharp-state-change"), (.end, "sharp-collision strong"),
            (.keyframe, "whisper-collision"), (.mark, "subtle-collision"), (.done, "completed"), (.error, "angry-alert"),
        ]
        #expect(expected.map(\.0) == HapticEvent.allCases)
        let config = Config()
        for (event, text) in expected {
            #expect(event.configKey == "haptic-" + event.rawValue)
            #expect(config.text(forKey: event.configKey) == text, "\(event)")
            #expect(HapticChoice.text(config.haptics.choice(for: event)) == text, "\(event)")
        }
        #expect(HapticEvent.longArmed.configKey == "haptic-long-armed")
        #expect(config.haptics.choice(for: .end) == HapticChoice(pattern: .sharpCollision, strong: true))
    }

    @Test func hapticNoneIsAChoiceOfNothing() {
        var settings = HapticSettings()
        settings.choices[.step] = .some(nil)
        #expect(settings.choice(for: .step) == nil)
        #expect(settings.choices[.step] != nil)   // present, and nothing
    }

    @Test func panelForceIsLinearOverTheMouseRange() {
        let range: ClosedRange<UInt16> = 3799...6316
        #expect(PanelForceSetting.percent(0).value(range: range, defaultValue: 4749) == 3799)
        #expect(PanelForceSetting.percent(100).value(range: range, defaultValue: 4749) == 6316)
        #expect(PanelForceSetting.percent(50).value(range: range, defaultValue: 4749) == 5058)   // 3799 + 1258.5 rounded
        #expect(PanelForceSetting.factoryDefault.value(range: range, defaultValue: 4749) == 4749)
        #expect(PanelForceSetting.keep.value(range: range, defaultValue: 4749) == nil)
        #expect(PanelForceSetting.percent(250).value(range: range, defaultValue: 4749) == 6316)
    }

    @Test func panelForceTextRoundTrips() {
        for s in [PanelForceSetting.keep, .factoryDefault, .percent(0), .percent(42), .percent(100)] {
            #expect(PanelForceSetting.parse(s.text) == s)
        }
        #expect(PanelForceSetting.parse("DEFAULT") == .factoryDefault)
        #expect(PanelForceSetting.parse("101") == nil && PanelForceSetting.parse("-1") == nil && PanelForceSetting.parse("firm") == nil)
    }

    @Test func sideButtonsModeRawValues() {
        #expect(SideButtonsMode.allCases.map(\.rawValue) == ["watch", "take", "system"])
    }
}
