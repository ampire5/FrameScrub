import StashKit

/// What the app knows about the scene on screen from Stash: being read, read, or why it could not be.
public enum StashDetailsState: Equatable, Sendable {
    case reading
    case loaded(StashSceneDetails)
    case failed(String)
}

/// Which scene's answer is still wanted: answers for any other scene are dropped.
public struct StashDetailsRequests: Sendable {
    private var current: (sceneID: String, token: Int)?
    private var last = 0
    private var visit = 0

    public init() {}

    /// A new request supersedes every earlier one, for the same scene as well.
    public mutating func begin(sceneID: String) -> Int {
        last += 1
        current = (sceneID, last)
        return last
    }

    /// The scene is left (⌘W, a plain file): no answer is wanted any more.
    public mutating func cancel() {
        current = nil
        visit += 1
    }

    /// A committed write changes the server even when it belonged to an earlier visit. Refresh a currently
    /// displayed scene from the server instead of applying a possibly already included delta to its new snapshot.
    public func shouldRefresh(afterWriteFor sceneID: String) -> Bool { current?.sceneID == sceneID }

    /// The current details-read identity. Refreshing server details supersedes earlier reads.
    public var currentToken: Int? { current?.token }

    /// Playback visit identity, stable across details refreshes and invalidated only when the scene is left.
    public var currentVisit: Int? { current == nil ? nil : visit }

    /// A failed activity write returns to the same visit's retry state even if a successful write refreshed details.
    public func acceptsActivityFailure(sceneID: String, visit: Int?) -> Bool {
        guard let visit else { return false }
        return current?.sceneID == sceneID && currentVisit == visit
    }

    public func accepts(sceneID: String, token: Int) -> Bool {
        current?.sceneID == sceneID && current?.token == token
    }
}
