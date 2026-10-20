import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct GrainStretcherTests {
    private static let rate = 48000.0

    private static func sine(_ frequency: Double) -> (Double) -> (Float, Float) {
        { t in let v = Float(sin(2 * .pi * frequency * t)) * 0.5; return (v, v) }
    }

    /// Runs the stretcher like the tape: the position moves `speed` media seconds per second.
    private static func drive(_ stretcher: inout GrainStretcher, from start: Double, speed: Double, seconds: Double,
                              read: (Double) -> (Float, Float)) -> [Float] {
        var position = start
        var out: [Float] = []
        for _ in 0..<Int(seconds * rate) {
            out.append(stretcher.next(position: position, velocity: speed, read: read).0)
            position += speed / rate
        }
        return out
    }

    /// Fundamental from zero crossings over the samples after `settle` seconds.
    private static func pitch(_ samples: [Float], settle: Double = 0.05) -> Double {
        let part = Array(samples.dropFirst(Int(settle * rate)))
        let crossings = zip(part, part.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        return Double(crossings) / 2 / (Double(part.count) / rate)
    }

    @Test(arguments: [1.0, 2.0, 4.0, -2.0]) func keepsThePitch(speed: Double) {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        let out = Self.drive(&stretcher, from: 5, speed: speed, seconds: 0.55, read: Self.sine(440))
        #expect(abs(Self.pitch(out) - 440) < 15, "\(Self.pitch(out)) Hz at \(speed)×")
    }

    @Test func halvesThePitchAtAQuarterSpeed() {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        let out = Self.drive(&stretcher, from: 5, speed: 0.25, seconds: 0.55, read: Self.sine(440))
        #expect(abs(Self.pitch(out) - 220) < 10, "\(Self.pitch(out)) Hz")
    }

    @Test(arguments: [1.0, 2.0]) func constantSignalStaysLevel(speed: Double) {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        let out = Self.drive(&stretcher, from: 5, speed: speed, seconds: 0.3) { _ in (0.5, 0.5) }
        #expect(out.allSatisfy { abs($0 - 0.5) < 0.01 }, "\(out.min()!)…\(out.max()!)")
    }

    @Test func readRateFollowsTheSpeed() {
        #expect(GrainStretcher.readRate(velocity: 2, previous: 1) == 1)
        #expect(GrainStretcher.readRate(velocity: -1, previous: 1) == -1)
        #expect(GrainStretcher.readRate(velocity: 0.25, previous: 1) == 0.5)
        #expect(GrainStretcher.readRate(velocity: -0.1, previous: 1) == -0.2)
        #expect(GrainStretcher.readRate(velocity: 0, previous: -1) == -0.02)
        #expect(GrainStretcher.readRate(velocity: 0.001, previous: 1) == 0.02)
    }

    /// A rising sawtooth (slow rise, sharp drop) read backward falls slowly instead.
    @Test(arguments: [1.0, -1.0]) func reversedPlaysTheSoundBackward(speed: Double) {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        let saw: (Double) -> (Float, Float) = { t in
            let v = Float((t * 100).truncatingRemainder(dividingBy: 1)) - 0.5
            return (v, v)
        }
        let out = Array(Self.drive(&stretcher, from: 5, speed: speed, seconds: 0.3, read: saw).dropFirst(2400))
        let rising = Double(zip(out, out.dropFirst()).filter { $1 > $0 }.count) / Double(out.count - 1)
        if speed > 0 { #expect(rising > 0.8, "\(rising)") } else { #expect(rising < 0.2, "\(rising)") }
    }

    /// Successive grains line up in phase: each start is a whole number of periods from the old grain's continuation.
    @Test func searchLandsOnAWholePeriod() {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        var grains: [(nominal: Double, chosen: Double, rate: Double)] = []
        var position = 5.0
        for _ in 0..<Int(0.3 * Self.rate) {
            _ = stretcher.next(position: position, velocity: 1.5, read: Self.sine(440))
            position += 1.5 / Self.rate
            if let grain = stretcher.lastGrain, grains.last.map({ $0 != grain }) ?? true { grains.append(grain) }
        }
        #expect(grains.count > 10)
        let period = 1 / 440.0, hop = stretcher.hop
        for (old, new) in zip(grains.dropFirst(), grains.dropFirst(2)) {
            let offset = (new.chosen - (old.chosen + old.rate * Double(hop) / Self.rate))
                .truncatingRemainder(dividingBy: period)
            let error = min(abs(offset), period - abs(offset))
            #expect(error < 1.5 * 4 / Self.rate, "\(error * 1000) ms")
        }
    }

    @Test func turningDirectionStaysBounded() {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        var position = 5.0
        var out: [Float] = []
        for turn in 0..<10 {
            let speed = turn % 2 == 0 ? 2.0 : -2.0
            out += Self.drive(&stretcher, from: position, speed: speed, seconds: 0.2, read: Self.sine(440))
            position += speed * 0.2
        }
        #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func restartDropsOldGrains() {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        let step: (Double) -> (Float, Float) = { t in t < 4 ? (0, 0) : (0.5, 0.5) }
        _ = Self.drive(&stretcher, from: 1, speed: 1, seconds: 0.1, read: step)
        stretcher.restart()
        let out = Self.drive(&stretcher, from: 5, speed: 1, seconds: 0.04, read: step)
        #expect(out.allSatisfy { abs($0 - 0.5) < 0.01 }, "\(out.min()!)…\(out.max()!)")
    }

    @Test func silenceKeepsTheNominalStart() {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        var position = 5.0
        for _ in 0..<Int(0.2 * Self.rate) {
            let out = stretcher.next(position: position, velocity: 2, read: { _ in (0, 0) })
            #expect(out.0 == 0 && out.1 == 0)
            position += 2 / Self.rate
            if let grain = stretcher.lastGrain { #expect(grain.chosen == grain.nominal) }
        }
    }

    @Test func crawlIsContinuous() {
        var stretcher = GrainStretcher(sampleRate: Self.rate)
        let out = Self.drive(&stretcher, from: 5, speed: 0.05, seconds: 0.5, read: Self.sine(440))
        #expect(out.allSatisfy { $0.isFinite })
        let jump = zip(out, out.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        #expect(jump < 0.05, "\(jump)")
    }
}
