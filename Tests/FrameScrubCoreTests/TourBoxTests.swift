import Testing
@testable import FrameScrubCore

struct TourBoxTests {
    @Test func optInConfigurationRoundTripsWithoutChangingMouseScrub() {
        let (config, warnings) = Config.parse("tourbox=yes\ntourbox-frames-per-pulse=0.25\ntourbox-accel=yes\ntourbox-accel-start=15\ntourbox-fast-multiplier=4\ntourbox-scroll-points=2\nscrub-accel=no")
        #expect(warnings.isEmpty)
        #expect(config.text(forKey: "tourbox") == "yes")
        #expect(config.text(forKey: "tourbox-frames-per-pulse") == "0.25")
        #expect(Config().text(forKey: "tourbox") == "no")
        #expect(Config().text(forKey: "tourbox-accel") == "yes")
        #expect(Config().text(forKey: "tourbox-frames-per-pulse") == "1")
        #expect(config.text(forKey: "tourbox-accel") == "yes")
        #expect(config.text(forKey: "tourbox-accel-start") == "15")
        #expect(config.text(forKey: "tourbox-fast-multiplier") == nil)
        #expect(config.text(forKey: "tourbox-scroll-points") == "2")
        let (_, invalid) = Config.parse("tourbox-frames-per-pulse=0\ntourbox-frames-per-pulse=nan\ntourbox-accel-start=0\ntourbox-accel-start=nan")
        #expect(invalid.count == 4)
    }
    @Test func coalescedEventsKeepBothDirectionsAndButtons() {
        var r = TourBoxRouter()
        #expect(r.receive([34, 162, 35, 163, 42, 170, 10, 138], at: 1, profile: .viewing) == [
            .command(.playlistPrev), .command(.playlistNext), .command(.screenshot), .toggleFilmstrip
        ])
    }

    @Test func modifierRotationConsumesItsTapAndClick() {
        var r = TourBoxRouter()
        #expect(r.receive([0, 196, 128], at: 1, profile: .viewing) == [.command(.addVolume(2))])
        #expect(r.receive([3, 132, 131], at: 2, profile: .viewing) == [.command(.stepSpeed(-1))])
        #expect(r.receive([3, 201, 131], at: 3, profile: .viewing).isEmpty)
        #expect(r.receive([3, 131], at: 4, profile: .viewing) == [.command(.setSpeed(1))])
        #expect(r.receive([0, 128], at: 5, profile: .viewing).isEmpty)
    }

    @Test func topTapIsImmediateAndHoldRestoresWithoutAPauseTap() {
        var r = TourBoxRouter()
        #expect(r.receive([2, 130], at: 1, profile: .viewing) == [.command(.cyclePause)])
        #expect(r.nextDeadline == nil)
        #expect(r.receive([2, 2], at: 2, profile: .viewing).isEmpty)
        #expect(r.flush(at: 2.39).isEmpty)
        #expect(r.flush(at: 2.41) == [.beginSpeedHold])
        #expect(r.flush(at: 3).isEmpty)
        #expect(r.receive([130, 130], at: 3, profile: .viewing) == [.endSpeedHold])
    }

    @Test func profileChordFiresOnceAndConsumesBothButtons() {
        for pair: [UInt8] in [[2, 42], [42, 2]] {
            var r = TourBoxRouter()
            #expect(r.receive(pair, at: 1, profile: .viewing).isEmpty)
            #expect(r.flush(at: 1.59).isEmpty)
            #expect(r.flush(at: 1.61) == [.command(.cycleMouseProfile)])
            #expect(r.flush(at: 2).isEmpty)
            #expect(r.receive([130, 170], at: 2, profile: .editing).isEmpty)
            #expect(r.nextDeadline == nil)
        }
    }

    @Test func editingTapSetsMarkButRotationCommitsOneEdgeEdit() {
        var r = TourBoxRouter()
        #expect(r.receive([34, 162, 35, 163], at: 1, profile: .editing) == [.command(.markIn), .command(.markOut)])
        #expect(r.receive([34, 196, 196, 162], at: 2, profile: .editing) == [
            .edge(.start, 1), .edge(.start, 1), .endEdge
        ])
        #expect(r.receive([35, 132], at: 3, profile: .editing) == [.edge(.end, -1)])
        #expect(r.cancel() == [.cancelEdge])
        #expect(r.receive([163], at: 4, profile: .editing).isEmpty)
    }

    @Test func slowKnobAccumulatesFractionsAndReversalDropsCarry() {
        var r = TourBoxRouter()
        r.framesPerPulse = 0.5
        #expect(r.receive([196], at: 1, profile: .viewing).isEmpty)
        #expect(r.receive([196], at: 1.15, profile: .viewing) == [.scrub(1)])
        #expect(r.receive([196], at: 1.3, profile: .viewing).isEmpty)
        #expect(r.receive([132], at: 1.4, profile: .viewing).isEmpty)
        #expect(r.receive([132], at: 1.55, profile: .viewing) == [.scrub(-1)])
    }

    @Test func fastKnobAcceleratesButReverseAndPauseRestartSlowly() {
        var r = TourBoxRouter()
        r.framesPerPulse = 0.5
        r.accelerates = true
        var frames = 0
        for i in 0..<20 {
            for action in r.receive([196], at: 1 + Double(i) * 0.01, profile: .viewing) {
                if case let .scrub(n) = action { frames += n }
            }
        }
        #expect(frames > 20)
        #expect(r.receive([132], at: 1.2, profile: .viewing).isEmpty)
        #expect(r.receive([196], at: 2, profile: .viewing).isEmpty)
        #expect(r.receive([196], at: 2.15, profile: .viewing) == [.scrub(1)])
    }

    @Test func cancellationDropsPendingTapAndHeldModifiers() {
        var r = TourBoxRouter()
        _ = r.receive([2, 130, 3], at: 1, profile: .viewing)
        #expect(r.cancel().isEmpty)
        #expect(r.flush(at: 2).isEmpty)
        #expect(r.receive([201], at: 3, profile: .viewing) == [.filmScroll(-4)])
    }

    @Test func verySlowTurningStillAccumulatesAFrame() {
        var r = TourBoxRouter()
        r.framesPerPulse = 0.5
        #expect(r.receive([196], at: 1, profile: .viewing).isEmpty)
        #expect(r.receive([196], at: 1.5, profile: .viewing) == [.scrub(1)])
    }

    @Test func topRotationHasNoZoomOrSceneBindingAndSuppressesTap() {
        var r = TourBoxRouter()
        #expect(r.receive([2, 196, 201, 130], at: 1, profile: .viewing).isEmpty)
        #expect(r.flush(at: 2).isEmpty)
        #expect(r.receive([196], at: 3, profile: .viewing) == [.scrub(1)])
    }

    @Test func coalescedSlowPulsesDoNotManufactureAcceleration() {
        var r = TourBoxRouter()
        r.accelerates = true
        #expect(r.receive([196, 196, 196, 196], at: 1, profile: .viewing) == [.scrub(1), .scrub(1), .scrub(1), .scrub(1)])
    }

    @Test func verticalWheelDirectionIsConsistentAcrossModifiers() {
        var r = TourBoxRouter()
        #expect(r.receive([201, 137], at: 1, profile: .viewing) == [
            .filmScroll(-4), .filmScroll(4)
        ])
        #expect(r.receive([0, 201, 137, 128], at: 2, profile: .viewing) == [
            .command(.seek(-60, .byConfig)), .command(.seek(60, .byConfig))
        ])
        #expect(r.receive([2, 201, 137, 130], at: 3, profile: .viewing).isEmpty)
        #expect(r.receive([3, 201, 137, 131], at: 4, profile: .viewing).isEmpty)
    }

    @Test func accelerationKeepsSlowStepsPreciseAndGrowsWithRotationSpeed() {
        func frames(rate: Double) -> [Int] {
            var r = TourBoxRouter()
            r.accelerates = true
            return (0..<120).map { i in
                r.receive([196], at: 1 + Double(i) / rate, profile: .viewing).reduce(0) {
                    if case let .scrub(n) = $1 { return $0 + n }; return $0
                }
            }
        }
        #expect(frames(rate: 10).allSatisfy { $0 == 1 })
        let gentle = frames(rate: 15)
        #expect(gentle.allSatisfy { (1...2).contains($0) })
        let medium = frames(rate: 30), fast = frames(rate: 60), veryFast = frames(rate: 120)
        #expect(medium.suffix(20).reduce(0,+) > 30)
        #expect(fast.suffix(20).reduce(0,+) > medium.suffix(20).reduce(0,+) * 2)
        #expect(veryFast.suffix(20).reduce(0,+) > fast.suffix(20).reduce(0,+) * 3)
        #expect(frames(rate: 1000).allSatisfy { (1...64).contains($0) })
    }

    @Test func slowingDownImmediatelyRestoresSingleFrameControl() {
        var r = TourBoxRouter()
        r.accelerates = true
        for i in 0..<60 { _ = r.receive([196], at: 1 + Double(i)*0.01, profile: .viewing) }
        #expect(r.receive([196], at: 1.74, profile: .viewing) == [.scrub(1)])
        #expect(r.receive([132], at: 1.75, profile: .viewing) == [.scrub(-1)])
        #expect(r.receive([196], at: 2.2, profile: .viewing) == [.scrub(1)])
    }

    @Test func steadyCoalescedPulsesStillAccelerateAtTheirActualArrivalRate() {
        func tailFrames(batchSize: Int) -> Int {
            var r = TourBoxRouter()
            r.accelerates = true
            var total = 0
            for batch in 0..<(200 / batchSize) {
                let actions = r.receive(Array(repeating: 196, count: batchSize),
                                        at: 1 + Double(batch * batchSize) / 100, profile: .viewing)
                if batch * batchSize >= 100 {
                    total += actions.reduce(0) { if case let .scrub(n) = $1 { return $0 + n }; return $0 }
                }
            }
            return total
        }
        let singles = tailFrames(batchSize: 1), grouped = tailFrames(batchSize: 10)
        #expect(grouped > 2000)
        #expect(abs(grouped - singles) < 100)
    }

    @Test func disablingAccelerationMakesKnobLinearAtEverySpeed() {
        for interval in [0.005, 0.05, 0.5] {
            var r = TourBoxRouter()
            r.accelerates = false
            for i in 0..<30 {
                #expect(r.receive([196], at: 1 + Double(i) * interval, profile: .viewing) == [.scrub(1)])
            }
        }
        var r = TourBoxRouter()
        r.framesPerPulse = 3
        #expect(r.receive([132, 132], at: 1, profile: .viewing) == [.scrub(-3), .scrub(-3)])
    }

    @Test func shortTapResetsSpeedButChordsAndDuplicatesDoNotReset() {
        var r = TourBoxRouter()
        #expect(r.receive([3, 3], at: 1, profile: .viewing).isEmpty)
        #expect(r.receive([131, 131], at: 1.1, profile: .viewing) == [.command(.setSpeed(1))])
        #expect(r.receive([3, 196, 131], at: 2, profile: .viewing) == [.command(.stepSpeed(1))])
        #expect(r.receive([3, 201, 131], at: 3, profile: .viewing).isEmpty)
        #expect(r.receive([3, 0, 131, 128], at: 4, profile: .viewing).isEmpty)
    }

    @Test func tourAlwaysSavesOnReleaseUnlessUsedForTheProfileChord() {
        var r = TourBoxRouter()
        #expect(r.receive([42], at: 1, profile: .viewing).isEmpty)
        #expect(r.receive([170], at: 1.1, profile: .viewing) == [.command(.screenshot)])
        #expect(r.receive([42], at: 2, profile: .viewing).isEmpty)
        #expect(r.flush(at: 3).isEmpty)
        #expect(r.receive([170], at: 3, profile: .viewing) == [.command(.screenshot)])
        #expect(r.nextDeadline == nil)
    }

    @Test func abortedProfileChordNeverPlaysSavesOrTogglesVibrance() {
        var r = TourBoxRouter()
        #expect(r.receive([2, 42], at: 1, profile: .viewing).isEmpty)
        #expect(r.receive([130, 170], at: 1.2, profile: .viewing).isEmpty)
        #expect(r.flush(at: 2).isEmpty)
        _ = r.receive([42, 2], at: 3, profile: .viewing)
        _ = r.cancel()
        #expect(r.flush(at: 4).isEmpty)
        #expect(r.receive([130, 170], at: 4, profile: .viewing).isEmpty)
    }

    @Test func joiningTourEndsTopSpeedHoldBeforeStartingProfileChord() {
        var r = TourBoxRouter()
        _ = r.receive([2], at: 1, profile: .viewing)
        #expect(r.flush(at: 1.41) == [.beginSpeedHold])
        #expect(r.receive([42], at: 1.5, profile: .viewing) == [.endSpeedHold])
        #expect(r.flush(at: 2.11) == [.command(.cycleMouseProfile)])
        #expect(r.receive([170, 130], at: 2.2, profile: .editing).isEmpty)
        _ = r.receive([2], at: 3, profile: .viewing)
        _ = r.flush(at: 3.41)
        #expect(r.cancel() == [.endSpeedHold])
    }

    @Test func tallKnobChangesVolumeWithoutScrubbing() {
        var r = TourBoxRouter()
        #expect(r.receive([0,196,132,128], at:1, profile:.viewing) == [.command(.addVolume(2)), .command(.addVolume(-2))])
    }

    @Test func correctionTogglesRepeatOnTargetPressWhileTallStaysDown() {
        var r = TourBoxRouter()
        #expect(r.receive([0], at:1, profile:.viewing).isEmpty)
        for _ in 0..<3 {
            #expect(r.receive([34,34], at:2, profile:.viewing) == [.command(.toggleAutoColor)])
            #expect(r.receive([162], at:2.1, profile:.viewing).isEmpty)
            #expect(r.receive([35], at:2.2, profile:.viewing) == [.command(.toggleVibrance)])
            #expect(r.receive([163], at:2.3, profile:.viewing).isEmpty)
        }
        #expect(r.receive([128], at:3, profile:.viewing).isEmpty)
    }

    @Test func topChordsActOnPressAndRepeatWithoutReleasingTheirModifier() {
        for modifier: UInt8 in [0,3] {
            var r = TourBoxRouter()
            _ = r.receive([modifier], at:1, profile:.viewing)
            for _ in 0..<3 {
                #expect(r.receive([2,2], at:2, profile:.viewing) == (modifier == 0 ? [.command(.cycleMute)] : [.reversePlayback]))
                #expect(r.nextDeadline == nil)
                #expect(r.flush(at:3).isEmpty)
                #expect(r.receive([130], at:3.1, profile:.viewing).isEmpty)
            }
            #expect(r.receive([modifier+128], at:4, profile:.viewing).isEmpty)
        }
    }

    @Test func tallAndCButtonsToggleColoursInEitherPressOrderWithoutNavigating() {
        for (presses, command): ([UInt8], Command) in [([0,34], .toggleAutoColor), ([34,0], .toggleAutoColor),
                                                        ([0,35], .toggleVibrance), ([35,0], .toggleVibrance)] {
            var r = TourBoxRouter()
            #expect(r.receive(presses, at: 1, profile: .viewing) == [.command(command)])
            #expect(r.receive([128,162,163], at: 1.1, profile: .viewing).isEmpty)
        }
    }

    @Test func viewingCButtonsNavigateOnReleaseOrAdjustColourWithKnob() {
        var r = TourBoxRouter()
        #expect(r.receive([34], at: 1, profile: .viewing).isEmpty)
        #expect(r.receive([162], at: 1.1, profile: .viewing) == [.command(.playlistPrev)])
        #expect(r.receive([35], at: 2, profile: .viewing).isEmpty)
        #expect(r.receive([163], at: 2.1, profile: .viewing) == [.command(.playlistNext)])
        #expect(r.receive([34,196,132,162], at: 3, profile: .viewing) == [
            .colorStrength(.autoColor, 0.05), .colorStrength(.autoColor, -0.05)])
        #expect(r.receive([35,196,132,163], at: 4, profile: .viewing) == [
            .colorStrength(.vibrance, 0.05), .colorStrength(.vibrance, -0.05)])
    }
    @Test func knobClickTogglesModeOnPressOnceAndModifiersSuppressIt() {
        var r = TourBoxRouter()
        #expect(r.receive([55,55], at:1, profile:.viewing) == [.toggleAcceleration])
        #expect(r.receive([183,183], at:1.1, profile:.viewing).isEmpty)
        for modifier: UInt8 in [0,3] {
            #expect(r.receive([modifier,55,183,modifier+128], at:2, profile:.viewing).isEmpty)
        }
        #expect(r.receive([10,10,138,138], at:3, profile:.viewing) == [.toggleFilmstrip])
    }

    @Test func applyingModeChangePreservesHeldClickAndResetsAcceleration() {
        var r = TourBoxRouter()
        for i in 0..<60 { _ = r.receive([196], at:1+Double(i)*0.01, profile:.viewing) }
        #expect(r.receive([55], at:2, profile:.viewing) == [.toggleAcceleration])
        r.accelerates = false
        #expect(r.receive([55,183], at:2.1, profile:.viewing).isEmpty)
        #expect(r.receive([196], at:2.2, profile:.viewing) == [.scrub(1)])
        #expect(r.receive([55], at:3, profile:.viewing) == [.toggleAcceleration])
        r.accelerates = true
        #expect(r.receive([183,196], at:3.1, profile:.viewing) == [.scrub(1)])
    }
}
