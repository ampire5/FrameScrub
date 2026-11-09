import Foundation
import FrameScrubCore

/// Owns the authored cut while the player owns at most one active media session.
@MainActor final class VirtualCutSession {
    final class Warm {
        let source: VirtualCutSource
        let span: Int
        let cancellation = OpenCancellation()
        var prepared: PreparedOpen?
        var preparationStarted = false
        var preview: PreviewProvider?
        var previewRequested = false
        var landingFrame: DecodedFrame?
        var url: URL?
        var origin: FileOrigin?

        init(source: VirtualCutSource, span: Int) {
            self.source = source
            self.span = span
        }
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
    var waitingForFirstPicture = false
    var awaitingPicture: VirtualCutPlayback.Request?
    var retryPictureAfterIndex: VirtualCutPlayback.Request?
    private var indexes: [(source: VirtualCutSource, index: FrameIndex)] = []

    func rememberIndex(_ index: FrameIndex, for source: VirtualCutSource) {
        guard index.isExact else { return }
        indexes.removeAll { $0.source == source }
        indexes.append((source, index))
        // At most four sources and about 8 MiB of timestamps and keyframe offsets per cut.
        while indexes.count > 4 ||
                indexes.reduce(0, { $0 + $1.index.frameCount + $1.index.keyframes.count }) > 1_048_576 {
            indexes.removeFirst()
        }
    }

    func reusedIndex(for source: VirtualCutSource) -> FrameIndex? {
        guard let offset = indexes.firstIndex(where: { $0.source == source }) else { return nil }
        let item = indexes.remove(at: offset)
        indexes.append(item)
        return item.index
    }

    func stopWarming() {
        warm?.preview?.stop()
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
