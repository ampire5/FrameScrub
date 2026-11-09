import Foundation
import FrameScrubCore

/// Owns the authored cut while the player owns at most one active media session.
@MainActor final class VirtualCutSession {
    final class Warm {
        let source: VirtualCutSource
        let cancellation = OpenCancellation()
        var prepared: PreparedOpen?
        var url: URL?
        var origin: FileOrigin?

        init(source: VirtualCutSource) { self.source = source }
    }

    let key: String
    let cut: VirtualCut
    var playback: VirtualCutPlayback
    var openingSource: VirtualCutSource?
    var openTicket: UUID?
    var loadedSource: VirtualCutSource?
    var direction = 1
    var scrubOpen: DispatchWorkItem?
    var deferredScrub: VirtualCutPlayback.Request?
    var warm: Warm?
    var warmedForSpan: Int?
    var filmSamples: [Double: [Double]] = [:]

    func stopWarming() {
        warm?.cancellation.cancel()
        warm?.prepared?.discard()
        warm = nil
    }

    init(key: String, cut: VirtualCut, timeline: VirtualCutTimeline) {
        self.key = key
        self.cut = cut
        playback = VirtualCutPlayback(timeline: timeline)
    }
}
