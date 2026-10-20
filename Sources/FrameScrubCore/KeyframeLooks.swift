import CoreImage
import Foundation

/// Looks at single keyframes for the scene jumps: whether one is too dark to tell or what its signature is, and
/// which keyframe lies next to it. Has its own decoder and demuxer, so playback is untouched. Not thread-safe:
/// use it from one queue.
///
/// Every decode and look drains its own autorelease pool: the Core Image / CoreVideo objects made per frame hold the
/// decoder's IOSurface frames until the pool drains, and those count against VTDecoderXPCService, not this process —
/// a long search on one queue item piled up gigabytes there.
final class KeyframeLooks {
    private let decoder: VideoDecoder
    private let rotation: Int
    private(set) var cached: [Int: KeyframeLook] = [:]
    /// The real pts of the keyframes met so far (approximate index): its own estimates can lie a tick or more off.
    private var keyframePTS: [Int: Int64] = [:]
    /// Set once a keyframe could only be reached by seeking forward to its pts.
    private var filesKeyframesLate = false
    /// The number of the frame the last `look` analysed (for tests).
    private(set) var lastDecodedFrame: Int?

    /// Replaced when the exact index arrives. Frame numbers of an approximate index are estimates, so the looks
    /// cached under them are dropped.
    var index: FrameIndex {
        didSet {
            decoder.index = index
            if index.isExact != oldValue.isExact {
                cached.removeAll()
                keyframePTS.removeAll()
                filesKeyframesLate = false
            }
        }
    }

    init(url: URL, index: FrameIndex, rotationClockwise: Int, readCache: ReadCache?, preferHardware: Bool) throws {
        decoder = try VideoDecoder(source: MediaSource(url: url, readCache: readCache), index: index,
                                   preferHardware: preferHardware)
        rotation = rotationClockwise
        self.index = index
    }

    /// The keyframe at or before `frame`. An approximate index knows no keyframes: the demuxer seeks to the real one
    /// and the keyframe decoded there is it.
    func keyframe(atOrBefore frame: Int) throws -> Int {
        if index.isExact { return index.keyframe(atOrBefore: frame) }
        return try autoreleasepool { try seekKeyframe(atOrBefore: frame) }
    }

    private func seekKeyframe(atOrBefore frame: Int) throws -> Int {
        // Some demuxers (an edit list, B-frames) place a keyframe a few frames after its pts: look past `frame` first, and
        // when that lands on a later keyframe than `frame`, back at the plain estimate.
        try decoder.seekToKeyframe(atOrBeforePTS: searchPTS(frame) + Self.demuxerShiftFrames * frameTicks(near: frame))
        var landed = try landedKeyframe()
        if landed.map({ $0.number > frame }) ?? true {
            try decoder.seekToKeyframe(atOrBeforePTS: searchPTS(frame))
            landed = try landedKeyframe()
        }
        guard let landed else { throw KeyframeLooksError.noFrame(frame) }
        keyframePTS[landed.number] = landed.pts
        return landed.number
    }

    /// The keyframe strictly after (`direction` > 0) or before (< 0) `keyframe`; nil at the edge of the file.
    func neighbour(of keyframe: Int, direction: Int) throws -> Int? {
        if index.isExact {
            return direction > 0 ? index.keyframe(after: keyframe) : keyframe > 0 ? index.keyframe(atOrBefore: keyframe - 1) : nil
        }
        // The keyframe's own pts bounds the seek, not the index's estimate of it: that can lie a tick off and land on it again.
        // A demuxer that files a keyframe a few frames away from its pts lands on the keyframe itself: move the bound on.
        let now = keyframePTS[keyframe] ?? index.pts(forFrame: keyframe)
        let ticks = frameTicks(near: keyframe)
        for shift in [0] + Self.retryShiftFrames {
            let from = now + Int64(direction * shift) * ticks
            // With no keyframe that way the decoder lands on the last / first frame, which is no neighbour unless it is a
            // keyframe too and lies strictly beyond `keyframe`.
            let landed: DecodedFrame? = try autoreleasepool {
                try decoder.seekToKeyframe(towardPTS: index.pts(forFrame: keyframe + direction), fromPTS: from, direction: direction)
                return try landedKeyframe()
            }
            guard let landed else { return nil }
            if landed.number == keyframe { continue }
            guard landed.pictureType == "I", direction > 0 ? landed.number > keyframe : landed.number < keyframe else { return nil }
            keyframePTS[landed.number] = landed.pts
            return landed.number
        }
        return nil
    }

    /// Dark, or the 64×36 signature of the keyframe; remembered per frame number.
    func look(at keyframe: Int) throws -> KeyframeLook {
        if let known = cached[keyframe] { return known }
        let look: KeyframeLook = try autoreleasepool {
            let frame = try decodeKeyframe(keyframe)
            lastDecodedFrame = frame.number
            let image = FrameImageRenderer.image(for: frame, rotationClockwise: rotation, toneMapToSDR: true)
            return ColorCorrection.isTooDarkToAnalyse(image) ? .dark : .picture(SceneSignature.of(image))
        }
        cached[keyframe] = look
        return look
    }

    /// The first frames of the hard cuts among the frames from `keyframe` to `last`: each frame whose signature differs
    /// from the frame before by `SceneCutDetector.defaultThreshold`. Decodes them all, from a seek to `keyframe` on;
    /// throws `CancellationError` as soon as `isCancelled()` says so (asked before every frame).
    func cuts(from keyframe: Int, through last: Int, isCancelled: () -> Bool) throws -> [Int] {
        guard !isCancelled() else { throw CancellationError() }
        var (number, previous) = try autoreleasepool {
            let frame = try decodeKeyframe(keyframe)
            return (frame.number, signature(of: frame))
        }
        var cuts = [Int]()
        lastCheckedFrames = keyframe...keyframe
        while number < last {
            guard !isCancelled() else { throw CancellationError() }
            // nil at the end of the file or past `last`; no signature for a frame that is not newer (skipped).
            let decoded: (number: Int, signature: SceneSignature?)? = try autoreleasepool {
                guard let next = try decoder.nextFrame(), next.number <= last else { return nil }
                return (next.number, next.number > number ? signature(of: next) : nil)
            }
            guard let decoded else { break }
            guard let current = decoded.signature else { continue }
            number = decoded.number
            if previous.difference(current) >= SceneCutDetector.defaultThreshold { cuts.append(number) }
            previous = current
            lastCheckedFrames = keyframe...number
        }
        return cuts
    }

    /// The frames the last `cuts` compared (for tests).
    private(set) var lastCheckedFrames: ClosedRange<Int>?

    private func signature(of frame: DecodedFrame) -> SceneSignature {
        SceneSignature.of(FrameImageRenderer.image(for: frame, rotationClockwise: rotation, toneMapToSDR: true))
    }

    /// Seeks to `keyframe` and decodes it; the decoder is left right after it.
    private func decodeKeyframe(_ keyframe: Int) throws -> DecodedFrame {
        let pts = keyframePTS[keyframe] ?? index.pts(forFrame: keyframe)
        var landed: DecodedFrame?
        // A file whose keyframes the demuxer files after their pts (edit list, B-frames) is sought forward from the start
        // once one such keyframe was met: the backward seek would land on the keyframe before every time.
        for forward in filesKeyframesLate ? [true, false] : [false, true] {
            if forward {
                try decoder.seekToKeyframe(towardPTS: pts, fromPTS: pts - 1, direction: 1)
            } else {
                try decoder.seekToKeyframe(atOrBeforePTS: keyframePTS[keyframe] ?? searchPTS(keyframe))
            }
            landed = try landedKeyframe(expecting: keyframe)
            if landed?.number == keyframe {
                if forward { filesKeyframesLate = true }
                break
            }
        }
        guard let frame = landed else { throw KeyframeLooksError.noFrame(keyframe) }
        // Never the look of another keyframe under this one's number.
        guard frame.number == keyframe else { throw KeyframeLooksError.wrongFrame(wanted: keyframe, got: frame.number) }
        keyframePTS[keyframe] = frame.pts
        return frame
    }

    /// Output frames to look through for the keyframe after a seek: leading pictures of an open GOP come out before it.
    private static let leadingLimit = 32
    /// How far past a keyframe's pts a demuxer may file it (edit lists, B-frame delay), in frames.
    private static let demuxerShiftFrames: Int64 = 6
    /// The frames to move a seek bound on by, one try each, while the demuxer keeps landing on the keyframe itself.
    private static let retryShiftFrames = [2, 3, 4, 6, 8]

    /// Ticks of one frame at `frame`, from the index.
    private func frameTicks(near frame: Int) -> Int64 {
        let low = max(frame - 1, 0), high = min(frame + 1, index.frameCount - 1)
        guard high > low else { return 1 }
        return max((index.pts(forFrame: high) - index.pts(forFrame: low)) / Int64(high - low), 1)
    }

    /// Where to seek for the keyframe at or before `frame`: half a frame past the index's estimate of its pts, so
    /// an estimate a little early still lands on the keyframe and a later keyframe is out of reach.
    private func searchPTS(_ frame: Int) -> Int64 {
        let low = max(frame - 1, 0), high = min(frame + 1, index.frameCount - 1)
        let estimate = index.pts(forFrame: frame)
        guard high > low else { return estimate }
        return estimate + (index.pts(forFrame: high) - index.pts(forFrame: low)) / Int64(2 * (high - low))
    }

    /// The keyframe decoded first after a seek, past the leading pictures an open GOP outputs before it (they are
    /// presented earlier). With `expecting` a frame number: the first frame from it on. Without: the first "I"
    /// picture (a decoder that reports no picture types has only its first frame to offer).
    private func landedKeyframe(expecting number: Int? = nil) throws -> DecodedFrame? {
        var first: DecodedFrame?
        for _ in 0..<Self.leadingLimit {
            guard let frame = try decoder.nextFrame() else { break }
            first = first ?? frame
            if let number {
                if frame.number >= number { return frame }
                if frame.pictureType == "I" { break }   // an earlier keyframe: the seek landed before this one
            } else {
                if frame.pictureType == "I" { return frame }
                if frame.pictureType == nil { break }
            }
        }
        return number == nil ? first : nil
    }
}

enum KeyframeLooksError: Error, CustomStringConvertible {
    case noFrame(Int)
    case wrongFrame(wanted: Int, got: Int)

    var description: String {
        switch self {
        case let .noFrame(frame): "no keyframe decoded at frame \(frame)"
        case let .wrongFrame(wanted, got): "keyframe \(wanted) decoded as frame \(got)"
        }
    }
}
