import LogiHIDPP

/// What the player asks of the Logitech mouse's wheel (free spin design): the wheel mode while the player is in
/// front, and Precision Scroll (the high-resolution wheel) over the video on free spin only. Ratchet notches are
/// already whole events, so Precision Scroll has nothing to add there.
public struct WheelWants: Equatable, Sendable {
    /// The mode FrameScrub wants the wheel in, or nil: leave the mouse's own mode alone.
    public let wheelMode: WheelMode?
    /// Whether the vertical wheel should be in high resolution.
    public let highResolution: Bool

    /// - Parameters:
    ///   - precision: `wheel-precision=yes`; with `no` nothing is wanted.
    ///   - freeSpin: the chosen mode (`wheelFreeSpin`): free spin (true) or ratchet.
    ///   - playerInFront: the app is active and the player window is key, with no sheet and no start screen.
    ///   - overVideo: the pointer is over the video, not the seek bar, playlist or another window above it.
    public init(precision: Bool, freeSpin: Bool, playerInFront: Bool, overVideo: Bool) {
        let inFront = precision && playerInFront
        wheelMode = inFront ? (freeSpin ? .freeSpin : .ratchet) : nil
        highResolution = inFront && overVideo && freeSpin
    }
}
