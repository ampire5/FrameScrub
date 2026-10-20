import Foundation

/// Decides which shown frame gets a piece of scrub audio (spec §2, §3.2). A sounding piece is never interrupted;
/// when it ends, the latest frame shown meanwhile plays if it has not sounded yet. A frame whose audio is not decoded
/// waits and plays once it is, only if it is still the latest. Quiet after a file opens and after playback stops,
/// until the user acts; nothing while playing.
public struct ScrubAudioPicker {
    public enum Event: Equatable, Sendable {
        case fileOpened, userActed, playbackStarted, playbackStopped
        case frameShown(Double), snippetEnded, audioReady
        /// The tape played this frame (spec §6а): it must not sound again as a piece.
        case heardOnTape(Double)
    }

    /// Not playing and not quiet: a frame shown now may sound (as a piece or on the tape).
    public var canSound: Bool { !quiet && !playing }

    private var quiet = true
    private var playing = false
    private var sounding = false
    private var latest: Double?
    private var lastPlayed: Double?
    private var waiting: Double?

    public init() {}

    /// Seconds of the frame to play now, or nil. `isReady(s)` = the buffer can slice a piece at `s` (silent counts as
    /// ready). The caller plays the piece; if its slice is silent it sends `.snippetEnded` right away.
    public mutating func handle(_ event: Event, isReady: (Double) -> Bool) -> Double? {
        switch event {
        case .fileOpened:
            self = ScrubAudioPicker()
            return nil
        case .userActed:
            quiet = false
            return nil
        case .playbackStarted:
            playing = true
            latest = nil
            waiting = nil
            return nil
        case .playbackStopped:
            playing = false
            quiet = true
            return nil
        case let .frameShown(seconds):
            guard !playing, !quiet else { return nil }
            latest = seconds
            guard !sounding, seconds != lastPlayed else { return nil }
            return start(seconds, isReady)
        case .snippetEnded:
            sounding = false
            guard !playing, let next = latest, next != lastPlayed else { return nil }
            return start(next, isReady)
        case let .heardOnTape(seconds):
            latest = seconds
            lastPlayed = seconds
            waiting = nil
            return nil
        case .audioReady:
            guard !playing, !sounding, let next = waiting, next == latest else { return nil }
            return start(next, isReady)
        }
    }

    private mutating func start(_ seconds: Double, _ isReady: (Double) -> Bool) -> Double? {
        guard isReady(seconds) else {
            waiting = seconds
            return nil
        }
        sounding = true
        lastPlayed = seconds
        waiting = nil
        return seconds
    }
}
