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


    @Test func sideButtonsModeRawValues() {
        #expect(SideButtonsMode.allCases.map(\.rawValue) == ["watch", "take", "system"])
    }
}
