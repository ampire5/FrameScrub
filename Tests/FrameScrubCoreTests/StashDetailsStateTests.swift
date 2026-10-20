import Testing
@testable import FrameScrubCore

@Suite struct StashDetailsStateTests {
    @Test func staleAnswerIsDropped() {
        var requests = StashDetailsRequests()
        let a = requests.begin(sceneID: "1")
        let b = requests.begin(sceneID: "2")
        #expect(!requests.accepts(sceneID: "1", token: a))
        #expect(requests.accepts(sceneID: "2", token: b))
        requests.cancel()
        #expect(!requests.accepts(sceneID: "2", token: b))
    }

    @Test func sameSceneAgainIsANewRequest() {
        var requests = StashDetailsRequests()
        let first = requests.begin(sceneID: "1")
        let second = requests.begin(sceneID: "1")
        #expect(!requests.accepts(sceneID: "1", token: first))
        #expect(requests.accepts(sceneID: "1", token: second))
    }

    /// A write started as the scene was left has no request to apply to, even once the scene is open again.
    @Test func leftSceneHasNoCurrentRequest() {
        var requests = StashDetailsRequests()
        #expect(requests.currentToken == nil)
        let first = requests.begin(sceneID: "1")
        #expect(requests.currentToken == first)
        requests.cancel()
        let atLeave = requests.currentToken
        #expect(atLeave == nil)
        let reopened = requests.begin(sceneID: "1")
        #expect(requests.currentToken == reopened)
        #expect(reopened != first)
        #expect(!requests.accepts(sceneID: "1", token: first))
    }
}
