import Testing
@testable import FrameScrubCore

struct FeedbackTests {
    @Test(arguments: [
        (Feedback.play, "play.fill", nil),
        (.pause, "pause.fill", nil),
        (.seek(5), "forward.fill", nil),          // the time is in the OSD line
        (.seek(-60), "backward.fill", nil),
        (.speed(1.1), "speedometer", "1.1\u{00D7}"),
        (.speed(2), "speedometer", "2\u{00D7}"),
        (.speed(1 / 1.1), "speedometer", "0.91\u{00D7}"),
        (.speed(-2), "backward.fill", "\u{25C0} \u{2212}2\u{00D7}"),   // ◀ −2×
        (.speed(-1), "backward.fill", "\u{25C0} \u{2212}1\u{00D7}"),
        (.volume(0), "speaker.fill", "0 %"),
        (.volume(20), "speaker.wave.1.fill", "20 %"),
        (.volume(50), "speaker.wave.2.fill", "50 %"),
        (.volume(100), "speaker.wave.3.fill", "100 %"),
        (.mute(true), "speaker.slash.fill", nil),
        (.revert, "arrow.uturn.backward", nil),
        (.endOfFile, "stop.fill", nil),
        (.playlistNext, "forward.end.fill", nil),
        (.sceneNext, "chevron.forward.2", nil),
        (.scenePrevious, "chevron.backward.2", nil),
    ] as [(Feedback, String, String?)])
    func iconAndCaption(_ feedback: Feedback, symbol: String, caption: String?) {
        #expect(feedback.symbolName == symbol)
        #expect(feedback.caption == caption)
    }

    @Test func seeksSitOnTheirSideOfTheVideo() {
        #expect(Feedback.seek(-5).placement == .leading)
        #expect(Feedback.seek(5).placement == .trailing)
        #expect(Feedback.pause.placement == .center)
        #expect(Feedback.volume(50).placement == .center)
        #expect(Feedback.sceneNext.placement == .center && Feedback.scenePrevious.placement == .center)
    }
}
