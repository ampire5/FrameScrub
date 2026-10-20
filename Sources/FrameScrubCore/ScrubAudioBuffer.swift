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
        guard !runs.isEmpty, samples.count > 0 else { return }
        let chunk = Chunk(start: index(startSeconds), samples: samples)
        runs[runs.count - 1].chunks.append(chunk)
        runs[runs.count - 1].end = max(runs[runs.count - 1].end, chunk.end)
    }

    /// The decoder ran out: everything after the current run's end is covered silence.
    public mutating func endOfAudio() {
        guard !runs.isEmpty else { return }
        runs[runs.count - 1].end = Int.max
    }

    public mutating func reset() {
        runs.removeAll()
    }

    /// Drops data farther than `window` from `seconds`.
    public mutating func trim(around seconds: Double) {
        let low = index(seconds - window), high = index(seconds + window)
        runs = runs.compactMap { run in
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

    public func slice(fromSeconds start: Double, length: Double) -> AudioSlice {
        let first = index(start), count = max(1, index(length))
        let wanted = first..<(first + count)
        guard mergedIndices.contains(where: { $0.lowerBound <= wanted.lowerBound && wanted.upperBound <= $0.upperBound }) else {
            return .notReady
        }
        let (out, any, _) = samples(in: wanted)
        return any ? .samples(out) : .silent
    }

    /// A contiguous copy of `t ± radius` for the tape (spec §6а): gaps and what is not decoded are silence, and
    /// sound ramps over 3 ms where it meets them (and at the copy's ends), so the tape never clicks on an edge.
    public func snapshot(aroundSeconds t: Double, radius: Double) -> TapeSnapshot {
        let first = index(t - radius), last = index(t + radius)
        var (out, _, filled) = samples(in: first..<max(first, last))
        let ramp = max(1, Int((0.003 * sampleRate).rounded()))
        var gains = [Float](repeating: 1, count: filled.count)
        var lastEmpty = -1
        for i in filled.indices {
            if !filled[i] { lastEmpty = i; continue }
            gains[i] = min(1, Float(i - lastEmpty - 1) / Float(ramp))
        }
        var nextEmpty = filled.count
        for i in filled.indices.reversed() {
            if !filled[i] { nextEmpty = i; continue }
            gains[i] = min(gains[i], Float(nextEmpty - i - 1) / Float(ramp))
            if gains[i] < 1 {
                out.left[i] *= gains[i]
                out.right[i] *= gains[i]
            }
        }
        return TapeSnapshot(startSeconds: Double(first) / sampleRate, sampleRate: sampleRate, samples: out)
    }

    /// The samples of `wanted` (zeros where nothing is stored), whether any were stored, and which.
    private func samples(in wanted: Range<Int>) -> (samples: StereoSamples, any: Bool, filled: [Bool]) {
        let count = wanted.count, first = wanted.lowerBound
        var out = StereoSamples(left: Array(repeating: 0, count: count), right: Array(repeating: 0, count: count))
        var filled = Array(repeating: false, count: count)
        var any = false
        for run in runs {
            for chunk in run.chunks {
                // Only what the run covers; the first data stored for a sample wins.
                let lower = max(chunk.start, run.start, wanted.lowerBound)
                let upper = min(chunk.end, run.end, wanted.upperBound)
                guard lower < upper else { continue }
                for i in lower..<upper where !filled[i - first] {
                    out.left[i - first] = chunk.samples.left[i - chunk.start]
                    out.right[i - first] = chunk.samples.right[i - chunk.start]
                    filled[i - first] = true
                    any = true
                }
            }
        }
        return (out, any, filled)
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
