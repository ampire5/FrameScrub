import Foundation

/// The scrub tape's natural pitch (scrub audio spec §6б): granular WSOLA. Two overlapping 40 ms Hann grains, a new
/// one every 20 ms, each read at ±1× (slower below 0.5×, so the pitch drops there instead of the sound smearing)
/// around the tape's position; each new grain moves up to ±10 ms to where it best continues the one before, so the
/// two sound in phase. No delay: a grain's middle meets the tape position when the middle plays. Every buffer is made
/// in `init`; `next` neither allocates nor frees, so it can run on the render thread.
public struct GrainStretcher {
    private struct Grain {
        var start: Double   // media seconds read at phase 0
        var rate: Double    // media seconds per output second, signed
        var phase: Int
    }

    /// Below this speed the grains read slower and the pitch drops in proportion.
    static let naturalFrom = 0.5
    /// The slowest read rate: a grain never freezes on one sample.
    static let minimumRate = 0.02
    private static let grainSeconds = 0.040
    private static let searchSeconds = 0.010
    private static let searchRate = 12000.0

    /// Output samples a grain lasts and between grain starts.
    let length: Int
    let hop: Int
    private let sampleRate: Double
    private let window: [Float]
    private let decimation: Int
    private let reach: Int   // search steps either side of the nominal start
    private let overlap: Int // decimated samples compared
    private var template: [Float]
    private var candidates: [Float]
    private var older: Grain?
    private var newer: Grain?
    private var sign = 1.0
    /// The newest grain's nominal and chosen start (tests check the search with it).
    private(set) var lastGrain: (nominal: Double, chosen: Double, rate: Double)?

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int((Self.grainSeconds * sampleRate / 2).rounded()))
        length = hop * 2
        let length = length
        window = (0..<length).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(length))) }
        decimation = max(1, Int((sampleRate / Self.searchRate).rounded()))
        reach = max(1, Int((Self.searchSeconds * sampleRate / Double(decimation)).rounded()))
        overlap = max(1, hop / decimation)
        template = [Float](repeating: 0, count: overlap)
        candidates = [Float](repeating: 0, count: 2 * reach + overlap)
    }

    /// The read rate inside a grain for the tape's `velocity`; `previous` gives the direction when it is 0.
    static func readRate(velocity: Double, previous: Double) -> Double {
        let sign = velocity > 0 ? 1.0 : velocity < 0 ? -1.0 : previous < 0 ? -1.0 : 1.0
        return sign * max(minimumRate, min(1, abs(velocity) / naturalFrom))
    }

    /// Drops the grains: the next sample starts a fresh grain at its window's peak, without a search.
    public mutating func restart() {
        older = nil
        newer = nil
    }

    /// One output sample at tape `position` (media seconds) moving at `velocity` (media seconds per second).
    public mutating func next(position: Double, velocity: Double,
                              read: (Double) -> (Float, Float)) -> (Float, Float) {
        if newer == nil {
            let rate = Self.readRate(velocity: velocity, previous: sign)
            sign = rate < 0 ? -1 : 1
            let start = position - rate * Double(hop) / sampleRate
            newer = Grain(start: start, rate: rate, phase: hop)
            lastGrain = (start, start, rate)
        }
        if let current = newer, current.phase >= hop {
            older = current
            newer = startGrain(position: position, velocity: velocity, after: current, read: read)
        }
        let (ol, or) = play(older, read: read)
        let (nl, nr) = play(newer, read: read)
        older?.phase += 1
        newer?.phase += 1
        return (ol + nl, or + nr)
    }

    private func play(_ grain: Grain?, read: (Double) -> (Float, Float)) -> (Float, Float) {
        guard let grain, grain.phase < length else { return (0, 0) }
        let (l, r) = read(grain.start + grain.rate * Double(grain.phase) / sampleRate)
        let w = window[grain.phase]
        return (l * w, r * w)
    }

    private mutating func startGrain(position: Double, velocity: Double, after old: Grain,
                                     read: (Double) -> (Float, Float)) -> Grain {
        let rate = Self.readRate(velocity: velocity, previous: sign)
        sign = rate < 0 ? -1 : 1
        let nominal = position + (velocity - rate) * Double(hop) / sampleRate
        let step = Double(decimation) / sampleRate
        func mono(_ t: Double) -> Float { let (l, r) = read(t); return (l + r) / 2 }
        // What the old grain plays during the overlap, against what the new one would play from each candidate start.
        var templateEnergy = 0.0
        for j in 0..<overlap {
            let v = mono(old.start + old.rate * (Double(hop) / sampleRate + Double(j) * step))
            template[j] = v
            templateEnergy += Double(v * v)
        }
        var best = reach
        if templateEnergy >= 1e-8 {
            for i in 0..<candidates.count { candidates[i] = mono(nominal + rate * Double(i - reach) * step) }
            var energy = 0.0
            for j in 0..<overlap { energy += Double(candidates[j] * candidates[j]) }
            let epsilon = 1e-9 * Double(overlap)
            var bestScore = -Double.infinity
            for k in 0...(2 * reach) {
                if k > 0 {
                    let gone = Double(candidates[k - 1]), came = Double(candidates[k + overlap - 1])
                    energy = max(0, energy - gone * gone + came * came)
                }
                var dot = 0.0
                for j in 0..<overlap { dot += Double(template[j] * candidates[j + k]) }
                let score = dot / (energy + epsilon).squareRoot()
                if score > bestScore + 1e-9 || (abs(score - bestScore) <= 1e-9 && abs(k - reach) < abs(best - reach)) {
                    bestScore = score
                    best = k
                }
            }
        }
        let chosen = nominal + rate * Double(best - reach) * step
        lastGrain = (nominal, chosen, rate)
        return Grain(start: chosen, rate: rate, phase: 0)
    }
}
