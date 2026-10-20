/// "Skipped frames" in the stats: frames replaced by the next one before they reached the screen. Redrawing
/// a frame that is already on screen (a fade, a setting change) neither counts nor hides a skip.
public struct SkippedFrameCounter: Sendable {
    public private(set) var skipped = 0
    private var undrawn = false

    public init() {}

    public mutating func frameArrived() {
        if undrawn { skipped += 1 }
        undrawn = true
    }

    public mutating func frameDrawn() { undrawn = false }

    public mutating func reset() { self = SkippedFrameCounter() }
}
