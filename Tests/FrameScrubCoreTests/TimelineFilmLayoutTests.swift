import Testing
@testable import FrameScrubCore

@Suite struct TimelineFilmLayoutTests {
    private func layout(_ mode: TimelineFilmMode = .lens, center: Double = 720, crop: Double = 0.7,
                        width: Double = 900) -> TimelineFilmLayout {
        TimelineFilmLayout(width: width, height: 48, aspect: 16.0 / 9, duration: 2400, center: center,
                           secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: crop, mode: mode)
    }
    @Test func wholeFileKeepsEverySampleWhileMagnifierMoves() {
        let a = layout(), b = layout(center: 721), c = layout(center: 900)
        #expect(a.cells.map(\.id) == b.cells.map(\.id))
        #expect(a.cells.map(\.seconds) == b.cells.map(\.seconds))
        #expect(a.cells.map(\.seconds) == c.cells.map(\.seconds))
        #expect(a.cells.first!.offset == b.cells.first!.offset)
        #expect(a.cells.first!.width == b.cells.first!.width)
        #expect(a.cells.last!.offset == c.cells.last!.offset)
        #expect(a.playheadOffset < b.playheadOffset)
    }
    @Test func overviewIsStationaryAndSharesTheLensPictures() {
        let a = layout(.overview), b = layout(.overview, center: 1200), lens = layout()
        #expect(a.cells.map(\.seconds) == lens.cells.map(\.seconds))
        #expect(a.cells.map(\.offset) == b.cells.map(\.offset))
        #expect(a.cells.map(\.width) == b.cells.map(\.width))
        #expect(a.playheadOffset != b.playheadOffset)
    }
    @Test func segmentMovesExistingPicturesInsteadOfChangingTheirTimes() {
        let a = layout(.segment), b = layout(.segment, center: 720.1)
        let shared = a.cells.filter { cell in b.cells.contains { $0.id == cell.id } }
        #expect(shared.count >= a.cells.count - 2)
        for cell in a.cells where abs(cell.offset) < 300 {
            guard let moved = b.cells.first(where: { $0.id == cell.id }) else { continue }
            #expect(cell.seconds == moved.seconds)
            #expect(moved.offset < cell.offset)
        }
        #expect(a.playheadOffset == 0 && b.playheadOffset == 0)
    }
    @Test func projectionIsMonotonicAndReversibleForAllViews() {
        for mode in TimelineFilmMode.allCases {
            let value = layout(mode)
            var previous = -1.0
            for x in stride(from: -400.0, through: 400, by: 4) {
                let time = value.lens.time(at: x)
                #expect(time >= previous)
                #expect(abs(value.lens.offset(for: time) - x) < 0.00001)
                previous = time
            }
        }
    }
    @Test func moreDensityFitsMoreStablePicturesAndTheLensEnlargesLocally() {
        let full = TimelineFilmLayout(width: 900, height: 48, aspect: 16.0 / 9, duration: 2400, center: 720,
            secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7, outsideDensity: 1)
        let dense = layout(), plain = layout(.overview)
        #expect(dense.cells.count > full.cells.count)
        #expect(dense.cells.contains { $0.width > plain.cells[0].width * 1.5 })
        #expect(dense.cells.contains { $0.cropped })
    }
    @Test func magnificationAndAreaOnlyReprojectExistingPictures() {
        func model(_ strength: Double, _ area: Double) -> TimelineFilmLayout {
            TimelineFilmLayout(width: 900, height: 48, aspect: 16.0 / 9, duration: 2400, center: 720,
                secondsPerThumbnail: 1, focusFraction: area, cropStrength: 0.7,
                magnification: strength, outsideDensity: 2.75)
        }
        let weak = model(1, 0.3), strong = model(3.8, 0.3), wide = model(3.8, 0.6)
        #expect(weak.cells.map(\.seconds) == strong.cells.map(\.seconds))
        #expect(strong.cells.map(\.seconds) == wide.cells.map(\.seconds))
        #expect(strong.cells.map(\.width).max()! > weak.cells.map(\.width).max()!)
        let x = strong.playheadOffset + 200
        #expect(strong.lens.position(forBaseline: x) != wide.lens.position(forBaseline: x))
    }
    @Test func densityDoesNotOverrideMagnificationAndCropDoesNotResample() {
        func model(_ density: Double, _ crop: Double) -> TimelineFilmLayout {
            TimelineFilmLayout(width: 900, height: 48, aspect: 16.0 / 9, duration: 2400, center: 720,
                secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: crop,
                magnification: 2, outsideDensity: density)
        }
        #expect(model(4, 0.7).cells.count > model(1, 0.7).cells.count)
        #expect(model(4, 0.7).lens.magnification == model(1, 0.7).lens.magnification)
        #expect(model(2, 0).cells.map(\.seconds) == model(2, 1).cells.map(\.seconds))
        #expect(model(2, 0).cells.map(\.width) == model(2, 1).cells.map(\.width))
    }
    @Test func independentParameterExtremesKeepInverseMappingValid() {
        for mode in TimelineFilmMode.allCases {
            for strength in [1.0, 3.8] {
                for area in [0.08, 0.75] {
                    let value = TimelineFilmLayout(width: 900, height: 48, aspect: 16.0 / 9, duration: 2400,
                        center: 720, secondsPerThumbnail: 1, focusFraction: area, cropStrength: 0.7,
                        mode: mode, magnification: strength, outsideDensity: 4)
                    for time in [1.0, 700, 720, 740, 2399] {
                        let x = value.lens.offset(for: time)
                        #expect(abs(value.lens.time(at: x) - time) < 0.00001)
                    }
                }
            }
        }
    }
    @Test func slotsAreContiguousAndBoundedAndClicksUseThePaintedSample() {
        for mode in TimelineFilmMode.allCases {
            for width in [80.0, 320, 900, 2560, 8192] {
                let value = layout(mode, width: width)
                #expect(value.cells.count <= TimelineFilmLayout.maximumCells)
                var edge = -width / 2
                for cell in value.cells {
                    #expect(abs(cell.offset - cell.width / 2 - edge) < 0.00001)
                    #expect(cell.width > 0 && cell.width.isFinite)
                    #expect(value.cell(at: cell.offset)?.seconds == cell.seconds)
                    edge = cell.offset + cell.width / 2
                }
                #expect(abs(edge - width / 2) < 0.00001)
            }
        }
    }
    @Test func onlySegmentLeavesTheExhaustedSideEmpty() {
        let segment = layout(.segment, center: 0)
        #expect(segment.cells.filter { $0.offset < -40 }.allSatisfy { $0.seconds == nil })
        #expect(layout(.lens, center: 0).cells.allSatisfy { $0.seconds != nil })
    }
    @Test func malformedGeometryStaysBounded() {
        let value = TimelineFilmLayout(width: .infinity, height: -1, aspect: .nan, duration: .nan, center: .nan,
            secondsPerThumbnail: 0, focusFraction: 4, cropStrength: -1)
        #expect(value.cells.count <= TimelineFilmLayout.maximumCells)
        #expect(value.cells.allSatisfy { $0.offset.isFinite && $0.width.isFinite })
    }
    @Test func lensShouldersNeverBecomeNarrowerThanTheOutsideFilm() {
        for strength in [1.0, 2.75, 3.8] {
            let value = TimelineFilmLayout(width: 900, height: 48, aspect: 16.0 / 9, duration: 2400,
                center: 720, secondsPerThumbnail: 1, focusFraction: 0.4, cropStrength: 0.7,
                mode: .segment, magnification: strength, outsideDensity: 4)
            let outside = value.cells.dropFirst().dropLast().map(\.width).suffix(3).max()!
            for cell in value.cells.dropFirst().dropLast() { #expect(cell.width >= outside - 0.00001) }
            let right = value.cells.filter { $0.offset >= 0 }.dropLast()
            for (near, far) in zip(right, right.dropFirst()) { #expect(near.width >= far.width - 0.00001) }
        }
    }
    @Test func wheelVisitsOnlyAvailableDisplayedSamplesAndStopsAtTheirEnds() {
        let value = layout()
        let times = value.cells.compactMap(\.seconds)
        let available = Set([times[3], times[5], times[7]])
        #expect(value.stepSample(from: times[3], by: 1, available: available) == times[5])
        #expect(value.stepSample(from: times[7], by: -1, available: available) == times[5])
        #expect(value.stepSample(from: times[7], by: 1, available: available) == nil)
        #expect(value.stepSample(from: times[3], by: -1, available: available) == nil)
        #expect(value.stepSample(from: times[3], by: 50, available: available) == times[7])
        #expect(value.stepSample(from: times[5], by: -50, available: available) == times[3])
        #expect(value.stepSample(from: times[3], by: 1, available: []) == nil)
    }
    @Test func wheelRecognisesTheSampleAfterVideoFrameRounding() {
        let value = layout()
        let times = value.cells.compactMap(\.seconds), available = Set(times)
        #expect(value.stepSample(from: times[5] - 0.02, by: 1, available: available, tolerance: 1.0 / 24) == times[6])
        #expect(value.stepSample(from: times[5] - 0.02, by: -1, available: available, tolerance: 1.0 / 24) == times[4])
    }
}
