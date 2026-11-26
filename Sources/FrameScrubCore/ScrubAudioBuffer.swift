import Foundation

/// Two channels of Float32 samples, as `AudioDecoder` produces them (standard non-interleaved stereo).
public struct StereoSamples: Equatable, Sendable {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    public var count: Int { left.count }
}

/// What the buffer can give for a piece: not decoded yet, covered but without sound (before the audio starts, a gap,
/// after its end), or samples (with silence where the audio has none).
public enum AudioSlice: Equatable, Sendable {
    case notReady, silent, samples(StereoSamples)
}

/// Decoded audio around the frame on screen for scrub audio (spec §3.1), addressed by sample index on the video
/// timeline. A decode run starts after a decoder seek; everything from its start to the end of its last buffer is
/// covered, so a jump between two buffers of one run is a real gap in the audio (silence), not missing data.
public struct ScrubAudioBuffer {
    private struct Chunk {
        var start: Int
        var samples: StereoSamples
        var end: Int { start + samples.count }
    }

    private struct Run {
        var start: Int
        var end: Int
        var chunks: [Chunk] = []
    }

    public let sampleRate: Double
    public let window: Double
    private var runs: [Run] = []

    public init(sampleRate: Double, window: Double = 5) {
        self.sampleRate = sampleRate
        self.window = window
    }

    private func index(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// `seconds` as a sample index, rounded as every bound in the buffer is.
    func sampleIndex(_ seconds: Double) -> Int { index(seconds) }

    public mutating func beginRun(atSeconds seconds: Double) {
        let at = index(seconds)
        runs.append(Run(start: at, end: at))
    }

    public mutating func append(_ samples: StereoSamples, startSeconds: Double) {
        guard !runs.isEmpty, samples.count > 0, samples.right.count == samples.count else { return }
        let chunk = Chunk(start: index(startSeconds), samples: samples)
        runs[runs.count - 1].chunks.append(chunk)
        runs[runs.count - 1].end = max(runs[runs.count - 1].end, chunk.end)
    }

    /// The decoder ran out: everything after the current run's end is covered silence.
    public mutating func endOfAudio() {
        guard !runs.isEmpty else { return }
        runs[runs.count - 1].end = Int.max
    }

    func canContinue(at sample: Int) -> Bool { runs.last?.end == sample }

    public mutating func reset() {
        runs.removeAll()
    }

    /// Drops data farther than `window` from `seconds`.
    public mutating func trim(around seconds: Double) {
        let low = index(seconds - window), high = index(seconds + window)
        runs = runs.compactMap { run in
            guard run.start < run.end else { return nil }
            if low <= run.start, run.end <= high { return run }
            var run = run
            run.start = max(run.start, low)
            run.end = min(run.end, high)
            guard run.start < run.end else { return nil }
            run.chunks.removeAll { $0.end <= run.start || $0.start >= run.end }
            return run
        }
    }

    /// Covered sample ranges (merged): the filler plans in whole samples, so it never asks for less than one.
    var coveredIndices: [Range<Int>] { mergedIndices }

    private var mergedIndices: [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in runs.map({ $0.start..<$0.end }).filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Covered time ranges (merged), for the filler to plan its next run.
    public var covered: [Range<Double>] {
        mergedIndices.map { range in
            let end = range.upperBound == Int.max ? Double.infinity : Double(range.upperBound) / sampleRate
            return Double(range.lowerBound) / sampleRate..<end
        }
    }

    private func indices(fromSeconds start: Double, length: Double) -> Range<Int> {
        let first = index(start)
        return first..<(first + max(1, index(length)))
    }

    func isReady(fromSeconds start: Double, length: Double) -> Bool {
        covers(indices(fromSeconds: start, length: length))
    }

    private func covers(_ wanted: Range<Int>) -> Bool {
        mergedIndices.contains { $0.lowerBound <= wanted.lowerBound && wanted.upperBound <= $0.upperBound }
    }

    public func slice(fromSeconds start: Double, length: Double) -> AudioSlice {
        let wanted = indices(fromSeconds: start, length: length)
        guard covers(wanted) else { return .notReady }
        var out = zeros(count: wanted.count)
        let any = copySamples(in: wanted, into: &out) { _ in }
        return any ? .samples(out) : .silent
    }

    /// A contiguous copy of `t ± radius` for the tape (spec §6а): gaps and what is not decoded are silence, and
    /// sound ramps over 3 ms where it meets them (and at the copy's ends), so the tape never clicks on an edge.
    public func snapshot(aroundSeconds t: Double, radius: Double) -> TapeSnapshot {
        let first = index(t - radius), last = index(t + radius)
        let wanted = first..<max(first, last)
        var out = zeros(count: wanted.count)
        var filled = IndexSet()
        _ = copySamples(in: wanted, into: &out) { filled.insert(integersIn: $0) }
        let ramp = max(1, Int((0.003 * sampleRate).rounded()))
        for span in filled.rangeView {
            let headEnd = min(span.upperBound, span.lowerBound + ramp)
            for i in span.lowerBound..<headEnd {
                let distance = min(i - span.lowerBound, span.upperBound - i - 1)
                let gain = Float(distance) / Float(ramp)
                out.left[i] *= gain
                out.right[i] *= gain
            }
            for i in max(headEnd, span.upperBound - ramp)..<span.upperBound {
                let gain = Float(span.upperBound - i - 1) / Float(ramp)
                out.left[i] *= gain
                out.right[i] *= gain
            }
        }
        return TapeSnapshot(startSeconds: Double(first) / sampleRate, sampleRate: sampleRate, samples: out)
    }

    private func zeros(count: Int) -> StereoSamples {
        StereoSamples(left: Array(repeating: 0, count: count), right: Array(repeating: 0, count: count))
    }

    /// Copy whole spans. Visit the earliest data last so it wins when runs overlap.
    private func copySamples(in wanted: Range<Int>, into out: inout StereoSamples, span: (Range<Int>) -> Void) -> Bool {
        var any = false
        out.left.withUnsafeMutableBufferPointer { left in
            out.right.withUnsafeMutableBufferPointer { right in
                for run in runs.reversed() {
                    let low = max(run.start, wanted.lowerBound), high = min(run.end, wanted.upperBound)
                    guard low < high else { continue }
                    for chunk in run.chunks.reversed() {
                        let lower = max(chunk.start, low), upper = min(chunk.end, high)
                        guard lower < upper else { continue }
                        let destination = lower - wanted.lowerBound, source = lower - chunk.start
                        let count = upper - lower
                        chunk.samples.left.withUnsafeBufferPointer {
                            (left.baseAddress! + destination).update(from: $0.baseAddress! + source, count: count)
                        }
                        chunk.samples.right.withUnsafeBufferPointer {
                            (right.baseAddress! + destination).update(from: $0.baseAddress! + source, count: count)
                        }
                        span(destination..<(destination + count))
                        any = true
                    }
                }
            }
        }
        return any
    }
}

/// An immutable stretch of PCM the tape reads from (spec §6а), at any fractional position.
public final class TapeSnapshot: @unchecked Sendable {
    public let startSeconds: Double
    public let sampleRate: Double
    private let left: [Float]
    private let right: [Float]

    public init(startSeconds: Double, sampleRate: Double, samples: StereoSamples) {
        self.startSeconds = startSeconds
        self.sampleRate = sampleRate
        left = samples.left
        right = samples.right
    }

    /// Linear interpolation between the two nearest samples; silence outside.
    public func sample(atSeconds t: Double) -> (Float, Float) {
        let x = (t - startSeconds) * sampleRate
        guard x.isFinite, x >= 0, x < Double(left.count - 1) else { return (0, 0) }
        let i = Int(x)
        let frac = Float(x - Double(i))
        return (left[i] + (left[i + 1] - left[i]) * frac, right[i] + (right[i + 1] - right[i]) * frac)
    }
}

/// Linear fade-in and fade-out so a piece starts and ends without a click (spec §2).
public enum SnippetFades {
    public static func apply(to samples: inout StereoSamples, sampleRate: Double, fade: Double) {
        let duration = Double(samples.count) / sampleRate
        let n = min(Int((min(fade, duration / 4) * sampleRate).rounded()), samples.count / 2)
        guard n > 0 else { return }
        for i in 0..<n {
            let gain = Float(i) / Float(n)
            let tail = samples.count - 1 - i
            samples.left[i] *= gain
            samples.right[i] *= gain
            samples.left[tail] *= gain
            samples.right[tail] *= gain
        }
    }
}
