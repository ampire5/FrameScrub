import Foundation

/// Presentation only. The player has already sought to the destination.
public struct TimelineClickMotion: Sendable {
    public static let maximumFramePreviewDistance = 240
    public let duration: Double
    private let initialOffset: Double
    private let skipsMiddle: Bool

    public init(from origin: Double, arrival: TimelineProjection, durationScale: Double = 1) {
        let distance = arrival.offset(for: origin) - arrival.focusOffset
        let travel = min(1, abs(distance) / max(1, arrival.halfWidth))
        duration = (0.08 + 0.08 * sqrt(travel)) * durationScale
        skipsMiddle = arrival.halfWidth > 0 && abs(distance) > arrival.halfWidth
        if skipsMiddle {
            // Start the coast within a quarter of a viewport and dissolve the old view over its first few frames.
            let side = distance < 0 ? -1.0 : 1.0
            let entry = arrival.focusOffset + side * arrival.halfWidth / 2
            initialOffset = arrival.time(at: entry) - arrival.center
        } else {
            initialOffset = origin - arrival.center
        }
    }

    public func sample(elapsed: Double, target: Double) -> (center: Double, outgoingOpacity: Double) {
        let progress = min(1, max(0, elapsed / duration))
        let remaining = 1 - progress
        let fade = skipsMiddle ? max(0, 1 - elapsed / 0.045) : 0
        return (target + initialOffset * remaining * remaining * remaining, fade * fade)
    }
}

public struct FilmSeekPreviewSettings: Sendable {
    public static let durationRange = 100.0...300.0
    public static let rates = [30, 60, 120]
    public let milliseconds: Double
    public let rateIndex: Int
    public var motionScale: Double { milliseconds / 180 }

    public init(milliseconds: Double = 180, rateIndex: Int = 1) {
        self.milliseconds = milliseconds.isFinite
            ? min(Self.durationRange.upperBound, max(Self.durationRange.lowerBound, milliseconds))
            : 180
        self.rateIndex = Self.rates.indices.contains(rateIndex) ? rateIndex : 1
    }
}

/// Fit ready pictures into the existing seek deadline, reserving time for playback and input.
public struct FilmSeekRenderBudget: Sendable {
    public let count: Int
    public let duration: Double

    public init(available: Int, thumbnails: Bool, refreshInterval: Double, renderCost: Double,
                settings: FilmSeekPreviewSettings = .init()) {
        let deadline = settings.milliseconds / 1000
        let minimumSpacing = max(thumbnails ? 0.03 : 0, 1 / Double(FilmSeekPreviewSettings.rates[settings.rateIndex]))
        let spacing = max(minimumSpacing, refreshInterval, renderCost * 1.25)
        guard spacing.isFinite, spacing <= deadline / 2 else {
            count = 0
            duration = 0
            return
        }
        let fitting = min(available, Int((deadline / spacing + 1e-9).rounded(.down)))
        count = fitting >= 2 ? fitting : 0
        duration = min(deadline, Double(count) * spacing)
    }

    /// Keep the start and end of the ready sequence when dropping intermediates.
    public func select<Picture>(_ pictures: [Picture]) -> [Picture] {
        select(pictures[...], count: count)
    }

    public func selectFrames(_ frames: [Int], target: Int) -> [Int] {
        guard count >= 4, count < frames.count, let last = frames.last, abs(last - target) == 1 else {
            return select(frames)
        }
        let direction = last < target ? 1 : -1
        var arrivalCount = 1
        while arrivalCount < min(3, count - 2),
              frames[frames.count - arrivalCount - 1] == last - direction * arrivalCount {
            arrivalCount += 1
        }
        guard arrivalCount >= 2 else { return select(frames) }
        return select(frames.dropLast(arrivalCount), count: count - arrivalCount) + frames.suffix(arrivalCount)
    }

    private func select<Picture>(_ pictures: ArraySlice<Picture>, count: Int) -> [Picture] {
        guard count >= 2, count <= pictures.count else { return [] }
        let skipped = Double(pictures.count - count)
        return (0..<count).map { slot in
            let progress = Double(slot) / Double(count - 1)
            return pictures[pictures.startIndex + slot + Int(skipped * progress * (2 - progress))]
        }
    }
}
