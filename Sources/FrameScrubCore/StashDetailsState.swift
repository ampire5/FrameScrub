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

    public init() {}

    /// A new request supersedes every earlier one, for the same scene as well.
    public mutating func begin(sceneID: String) -> Int {
        last += 1
        current = (sceneID, last)
        return last
    }

    /// The scene is left (⌘W, a plain file): no answer is wanted any more.
    public mutating func cancel() { current = nil }

    /// The request whose answer is wanted now; nil once the scene is left. A write to Stash notes it when it starts,
    /// so a write that ends after the scene was left (and maybe opened again) does not change the details on screen.
    public var currentToken: Int? { current?.token }

    public func accepts(sceneID: String, token: Int) -> Bool {
        current?.sceneID == sceneID && current?.token == token
    }
}
