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

    @Test func aLateWriteForTheReopenedSceneRequiresFreshServerDetails() {
        var requests = StashDetailsRequests()
        let oldRead = requests.begin(sceneID: "1")
        requests.cancel()
        _ = requests.begin(sceneID: "1")
        #expect(!requests.accepts(sceneID: "1", token: oldRead))
        #expect(requests.shouldRefresh(afterWriteFor: "1"))
    }

    @Test func completedWritesDoNotReloadAnotherOrClosedScene() {
        var requests = StashDetailsRequests()
        _ = requests.begin(sceneID: "2")
        #expect(!requests.shouldRefresh(afterWriteFor: "1"))
        requests.cancel()
        #expect(!requests.shouldRefresh(afterWriteFor: "2"))
    }
    @Test func repeatedDetailReadsKeepTheActivityVisit() throws {
        var requests = StashDetailsRequests()
        let firstRead = requests.begin(sceneID: "1")
        let visit = try #require(requests.currentVisit)
        let refreshedRead = requests.begin(sceneID: "1")
        #expect(refreshedRead != firstRead)
        #expect(!requests.accepts(sceneID: "1", token: firstRead))
        #expect(requests.currentVisit == visit)
    }

    /// A save can succeed and refresh details before the same batch's add-play request fails.
    @Test func aFailureAfterSuccessfulWriteRefreshStillBelongsToThisVisit() throws {
        var requests = StashDetailsRequests()
        _ = requests.begin(sceneID: "1")
        let writingVisit = try #require(requests.currentVisit)
        #expect(requests.shouldRefresh(afterWriteFor: "1"))
        _ = requests.begin(sceneID: "1")
        #expect(requests.acceptsActivityFailure(sceneID: "1", visit: writingVisit))
        #expect(!requests.acceptsActivityFailure(sceneID: "2", visit: writingVisit))
    }

    @Test func reopeningTheSameSceneDoesNotRetryAnEarlierVisitFailure() throws {
        var requests = StashDetailsRequests()
        _ = requests.begin(sceneID: "1")
        let oldVisit = try #require(requests.currentVisit)
        requests.cancel()
        #expect(requests.currentVisit == nil)
        _ = requests.begin(sceneID: "1")
        let newVisit = try #require(requests.currentVisit)
        #expect(newVisit != oldVisit)
        #expect(!requests.acceptsActivityFailure(sceneID: "1", visit: oldVisit))
        #expect(requests.acceptsActivityFailure(sceneID: "1", visit: newVisit))
    }

    @Test func closedScenesAndMissingVisitNeverReceiveFailedWrites() throws {
        var requests = StashDetailsRequests()
        #expect(!requests.acceptsActivityFailure(sceneID: "1", visit: nil))
        _ = requests.begin(sceneID: "1")
        let visit = try #require(requests.currentVisit)
        requests.cancel()
        #expect(!requests.acceptsActivityFailure(sceneID: "1", visit: visit))
        #expect(!requests.acceptsActivityFailure(sceneID: "1", visit: nil))
    }

}
