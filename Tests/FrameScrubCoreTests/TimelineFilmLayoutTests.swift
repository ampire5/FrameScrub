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
    @Test func nearbyClickCoastsToTheCurrentPlayhead() {
        let destination = layout(.segment, center: 722).lens
        let motion = TimelineClickMotion(from: 720, arrival: destination)
        let start = motion.sample(elapsed: 0, target: 722)
        let middle = motion.sample(elapsed: motion.duration / 2, target: 722)
        let end = motion.sample(elapsed: motion.duration, target: 723)
        #expect(start.center == 720)
        #expect(start.outgoingOpacity == 0)
        #expect(middle.center > 721.5 && middle.center < 722)
        #expect(end.center == 723)
        #expect(motion.duration < TimelineClickMotion(from: 0, arrival: destination).duration)
    }

    @Test func aFlickCoastsButHoldingBeforeReleaseStopsOnTheSelectedFrame() throws {
        let projection = layout(.segment).lens
        var drag = TimelineFilmDrag(lens: projection, lastFrameSeconds: 2399, pointer: 400, timestamp: 0)
        drag.move(to: 390, at: 0.02)
        drag.move(to: 380, at: 0.04)
        drag.move(to: 370, at: 0.06)
        let coast = try #require(drag.release(at: 0.07))
        #expect(abs(coast.seconds(at: 0) - drag.seconds) < 1e-8)
        let middle = coast.seconds(at: coast.duration / 2)
        let end = coast.seconds(at: coast.duration)
        #expect(drag.seconds < middle && middle < end)
        #expect(middle - drag.seconds > end - middle)
        #expect(drag.release(at: 0.12) == nil)
    }

    @Test func anEdgeStretchesVisuallyAndTheFirstReverseMovementLeavesIt() {
        let projection = layout(.segment, center: 0).lens
        var drag = TimelineFilmDrag(lens: projection, lastFrameSeconds: 2399, pointer: 400, timestamp: 0)
        drag.move(to: 440, at: 0.02)
        #expect(drag.seconds == 0)
        #expect(drag.stretch > 0 && drag.stretch < 10)
        drag.move(to: 439, at: 0.04)
        #expect(drag.seconds > 0)
        #expect(drag.stretch == 0)

        let caught = TimelineFilmDrag(lens: projection, lastFrameSeconds: 2399, pointer: 400, timestamp: 0, caught: true)
        #expect(caught.hasMoved)
        #expect(caught.release(at: 0) == nil)
    }

    @Test func slowDragCanFindAMarkAndReversingLeavesItImmediately() {
        let lens = layout(.segment).lens
        let mark = lens.time(at: 3.5)
        var slow = TimelineFilmDrag(lens: lens, lastFrameSeconds: 2399, pointer: 400, timestamp: 0,
                                    markSeconds: [mark])
        var fast = slow
        slow.move(to: 390, at: 0.2)
        slow.move(to: 388, at: 0.24)
        fast.move(to: 390, at: 0.01)
        #expect(slow.seconds == mark)
        #expect(slow.stretch < 0)
        #expect(fast.seconds > mark)
        slow.move(to: 389, at: 0.26)
        #expect(slow.seconds < mark)
    }

    @Test func fineDraggingRemainsPreciseOnTheWholeFile() {
        let lens = layout(.overview).lens
        var drag = TimelineFilmDrag(lens: lens, lastFrameSeconds: 2399, pointer: 400, timestamp: 0,
                                    frameSeconds: 1.0 / 30)
        drag.move(to: 391, at: 0.2)
        #expect(abs(drag.seconds - lens.center - 0.1) < 0.001)
    }

    @Test func sparsePreviewKeepsConsecutiveArrivalFramesInBothDirections() {
        let forward = [2, 4, 6, 13, 17, 18, 19]
        let reverse = [27, 25, 23, 16, 13, 12, 11]
        let budget = FilmSeekRenderBudget(available: 7, thumbnails: false,
                                          refreshInterval: 1.0 / 60, renderCost: 0.004,
                                          settings: .init(milliseconds: 100))
        #expect(budget.selectFrames(forward, target: 20) == [2, 4, 13, 17, 18, 19])
        #expect(Array(budget.selectFrames(reverse, target: 10).suffix(3)) == [13, 12, 11])
    }

    @Test func smootherSettingsUseMoreReadyFramesWithoutOverrunningTheDeadline() {
        let ready = Array((1..<100).reversed())
        let light = FilmSeekRenderBudget(available: ready.count, thumbnails: false,
                                         refreshInterval: 1.0 / 120, renderCost: 0.004,
                                         settings: .init(milliseconds: 180, rateIndex: 0))
        let smooth = FilmSeekRenderBudget(available: ready.count, thumbnails: false,
                                           refreshInterval: 1.0 / 120, renderCost: 0.004,
                                           settings: .init(milliseconds: 240, rateIndex: 2))
        let frames = smooth.select(ready)
        #expect(frames.count > light.count)
        #expect(frames.first == ready.first && frames.last == ready.last)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 > $1 })
        #expect(smooth.duration <= 0.24)
    }

    @Test func seekPreviewYieldsToRenderCostRefreshRateAndCacheMisses() {
        let ready = [9, 7, 6, 4, 3, 1]
        let quick = FilmSeekPreviewSettings(milliseconds: 100)
        let fast = FilmSeekRenderBudget(available: ready.count, thumbnails: false,
                                        refreshInterval: 1.0 / 120, renderCost: 0.005, settings: quick)
        let busy = FilmSeekRenderBudget(available: ready.count, thumbnails: false,
                                        refreshInterval: 1.0 / 60, renderCost: 0.030, settings: quick)
        let slowDisplay = FilmSeekRenderBudget(available: ready.count, thumbnails: false,
                                               refreshInterval: 1.0 / 25, renderCost: 0.005, settings: quick)
        #expect(fast.select(ready).count > busy.select(ready).count)
        #expect(busy.select(ready) == [9, 1])
        #expect(slowDisplay.select(ready) == [9, 1])
        #expect(fast.duration <= 0.10 && busy.duration <= 0.10)
        #expect(FilmSeekRenderBudget(available: 1, thumbnails: false,
                                     refreshInterval: 1.0 / 120, renderCost: 0.005).count == 0)
        #expect(FilmSeekRenderBudget(available: 3, thumbnails: true,
                                     refreshInterval: 1.0 / 60, renderCost: 0.050, settings: quick).count == 0)
    }

    @Test func distantClickCoastsOnlyThroughTheArrivalNeighborhood() {
        for (origin, target) in [(0.0, 2400.0), (2400.0, 0.0)] {
            let destination = layout(.segment, center: target).lens
            let motion = TimelineClickMotion(from: origin, arrival: destination)
            let start = motion.sample(elapsed: 0, target: target)
            let middle = motion.sample(elapsed: motion.duration / 2, target: target)
            #expect(start.outgoingOpacity == 1)
            #expect(abs(start.center - target) < 20)
            #expect(middle.outgoingOpacity == 0)
            #expect(abs(middle.center - target) < abs(start.center - target))
            #expect(motion.sample(elapsed: 1, target: target).center == target)
        }
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
    @Test func densityAboveFourAddsSamplesWithoutExceedingTheVisibleLimit() {
        for mode in TimelineFilmMode.allCases {
            func model(_ density: Double, width: Double = 900) -> TimelineFilmLayout {
                TimelineFilmLayout(width: width, height: 96, aspect: 2.35, duration: 2400, center: 720,
                    secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7,
                    mode: mode, outsideDensity: density)
            }
            #expect(model(8).cells.count > model(4).cells.count)
            #expect(model(8, width: 8192).cells.count <= TimelineFilmLayout.maximumCells)
            #expect(model(1e6).cells.map(\.seconds) == model(8).cells.map(\.seconds))
        }
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
