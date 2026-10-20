/// What to do with a scene start found for a press, given where the playhead is now: a search over the NAS takes a
/// second or so, and playback moves on meanwhile.
public enum SceneJumpPolicy {
    public enum Decision: Equatable, Sendable {
        case jump(Int)
        /// Find again from the current position, for the same press.
        case searchAgain
        /// Nothing to jump to: "No next scene" / "No previous scene".
        case noScene
    }

    /// Finds again per press, so a fast-playing file cannot keep the search going forever.
    public static let maxRetries = 3

    /// A found start stands while it lies on the pressed side of the playhead: forward strictly ahead of what is on
    /// screen (never a rewind), backward behind it. Otherwise find again from the current position, at most
    /// `maxRetries` times (`retries`: finds again already made for this press), then give up.
    public static func decide(found: Int, direction: Int, currentPosition: Int, retries: Int) -> Decision {
        if direction > 0 ? found > currentPosition : found < currentPosition { return .jump(found) }
        return retries < maxRetries ? .searchAgain : .noScene
    }
}
