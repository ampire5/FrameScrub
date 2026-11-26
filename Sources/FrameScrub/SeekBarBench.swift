import AppKit
import Darwin
import FrameScrubCore
import QuartzCore

/// A bench of the actual app view, not a duplicate UI in the bench target.
@MainActor enum SeekBarBench {
    static func run() -> Never {
        if CommandLine.arguments.contains("--bench-keyframe-cost") { runKeyframeCost() }
        if CommandLine.arguments.contains("--bench-film-prewarm") { runPrewarm() }
        if CommandLine.arguments.contains("--bench-navigation-ribbon") { PlayerWindowController.runNavigationRibbonBench() }
        if CommandLine.arguments.contains("--bench-playing-film") { PlayingFilmBench.run() }
        if CommandLine.arguments.contains("--bench-film-loader") { runLoader() }
        if CommandLine.arguments.contains("--bench-film-click-cache") { runClickCache() }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.finishLaunching()
        let thumbnailBox = NSRect(x: 10, y: 20, width: 160, height: 90)
        let portrait = FilmstripThumbnail.fittedRect(aspect: 9.0 / 16, in: thumbnailBox)
        precondition(abs(portrait.width / portrait.height - 9.0 / 16) < 0.00001 && portrait.height == 90)
        let wide = FilmstripThumbnail.fittedRect(aspect: 2.35, in: thumbnailBox)
        precondition(abs(wide.width / wide.height - 2.35) < 0.00001 && wide.width == 160)
        checkThumbnailCrop()
        let savedHeight = UserDefaults.standard.object(forKey: "timeline-film-height")
        let savedControls = UserDefaults.standard.object(forKey: "timeline-controls-always")
        let savedPinned = UserDefaults.standard.object(forKey: "timeline-film-pinned")
        let savedLens = ["timeline-lens-seconds", "timeline-lens-focus", "timeline-lens-crop",
                         "timeline-lens-magnification", "timeline-lens-density"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        let savedMode = ("timeline-film-mode", UserDefaults.standard.object(forKey: "timeline-film-mode"))
        UserDefaults.standard.removeObject(forKey: savedMode.0)
        for (key, _) in savedLens { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: "timeline-film-pinned")
        UserDefaults.standard.removeObject(forKey: "timeline-film-height")
        UserDefaults.standard.removeObject(forKey: "timeline-controls-always")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 350),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true
        let host = window.contentView!
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.darkGray.cgColor
        window.makeKeyAndOrderFront(nil)
        app.activate()
        let geometryBar = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 130))
        host.addSubview(geometryBar)
        let filmPoint = NSPoint(x: 450, y: 8), filmMargin = NSPoint(x: 450, y: 60)
        if CommandLine.arguments.contains("--verify-film-fold-hover") {
            geometryBar.updateFilmPointer(filmPoint)
            precondition(geometryBar.showsFilmstrip)
            geometryBar.toggleFilmVisibility()
            geometryBar.updateFilmPointer(filmPoint)
            precondition(!geometryBar.showsFilmstrip, "Folding should suppress the current hover")
            geometryBar.updateFilmPointer(nil)
            geometryBar.updateFilmPointer(filmPoint)
            precondition(geometryBar.showsFilmstrip, "A fresh hover should reveal the folded strip again")
            geometryBar.updateFilmPointer(nil)
            geometryBar.toggleFilmVisibility()
            geometryBar.toggleFilmVisibility()
            geometryBar.updateFilmPointer(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(geometryBar.showsFilmstrip, "A keyboard reveal must wait for the pointer to reach the strip")
            geometryBar.updateFilmPointer(filmPoint)
            geometryBar.updateFilmPointer(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(!geometryBar.showsFilmstrip, "Leaving after entering should fold the keyboard-revealed strip")
            print("film-fold-hover: suppression, keyboard reveal and pointer exit passed")
            exit(EXIT_SUCCESS)
        }
        geometryBar.setPlaybackControlsVisible(false)
        geometryBar.updateFilmPointer(NSPoint(x: 450, y: 120))
        precondition(!geometryBar.showsFilmstrip, "Movement over the video must not reveal film")
        geometryBar.updateFilmPointer(NSPoint(x: 450, y: 47))
        precondition(geometryBar.showsFilmstrip, "Entering the future film area must reveal it immediately")
        geometryBar.setPlaybackControlsVisible(true)
        precondition(geometryBar.showsFilmstrip && geometryBar.hitTest(filmPoint) === geometryBar &&
                     geometryBar.hitTest(filmMargin) === geometryBar, "The edge opens the film and its hover margin")
        precondition(geometryBar.transport.frame.minY == 52 && geometryBar.modeControl.frame.midY == geometryBar.transport.frame.midY &&
                     geometryBar.preferredHeight == 93, "Wide controls and preview must stay close to the film")
        geometryBar.updateTimeline(index: nil, duration: 20, paused: true)
        var hoveredFractions: [Double?] = []
        var trackSeeks: [Double] = []
        var trackSeekWasContinuous: [Bool] = []
        var scrubEnds = 0
        var filmSeeks: [Double] = []
        geometryBar.onHover = { hoveredFractions.append($0) }
        geometryBar.onSeek = { fraction in
            trackSeeks.append(fraction)
            trackSeekWasContinuous.append(geometryBar.isContinuousSeek)
        }
        geometryBar.onScrubEnded = { scrubEnds += 1 }
        geometryBar.onFilmSeek = { filmSeeks.append($0) }
        func sendPointer(_ type: NSEvent.EventType, at point: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            switch type {
            case .mouseMoved: geometryBar.mouseMoved(with: event)
            case .leftMouseDown: geometryBar.mouseDown(with: event)
            case .leftMouseDragged: geometryBar.mouseDragged(with: event)
            default: geometryBar.mouseUp(with: event)
            }
        }
        let aboveFilm = NSPoint(x: filmPoint.x, y: 76)
        for point in [filmPoint, filmMargin, aboveFilm] { sendPointer(.mouseMoved, at: point) }
        precondition(geometryBar.filmCursorX == aboveFilm.x, "The film must show its target before a preview arrives")
        let targets = hoveredFractions.compactMap { $0 }
        precondition(targets.count == 3 && targets.allSatisfy { $0 == targets.first },
                     "The film and the margin above it must share one continuous hover target")
        let nearby = NSPoint(x: aboveFilm.x + 1, y: aboveFilm.y)
        sendPointer(.mouseMoved, at: nearby)
        precondition((hoveredFractions.last.flatMap { $0 } ?? 0) > targets[0], "Hover time must advance within the same thumbnail cell")
        sendPointer(.mouseMoved, at: aboveFilm)
        sendPointer(.leftMouseDown, at: aboveFilm)
        sendPointer(.leftMouseUp, at: aboveFilm)
        precondition(trackSeeks.isEmpty && filmSeeks.count == 1 && filmSeeks[0] == targets[0] * 20,
                     "Clicking in the film margin must seek to the time shown by the preview")
        let progressPoint = NSPoint(x: 231, y: 3)
        sendPointer(.mouseMoved, at: progressPoint)
        precondition(geometryBar.overviewHoverFraction == 0.25 && geometryBar.filmCursorX == nil &&
                     hoveredFractions.last == .some(0.25), "Overview hover must use the same linear scale as a click")
        sendPointer(.leftMouseDown, at: progressPoint)
        sendPointer(.leftMouseUp, at: progressPoint)
        precondition(trackSeeks == [0.25] && filmSeeks.count == 1,
                     "The progress rail must seek linearly below the film projection")
        trackSeeks.removeAll()
        trackSeekWasContinuous.removeAll()
        sendPointer(.mouseMoved, at: NSPoint(x: 450, y: 125))
        precondition(hoveredFractions.last == .some(nil), "Leaving the film must dismiss its preview")
        precondition(geometryBar.filmCursorX == nil, "Leaving the film must also dismiss its seek cursor")
        precondition(geometryBar.overviewHoverFraction == nil, "Leaving the film must dismiss its overview target")
        let clickIndex = FrameIndex(pts: (0..<4800).map(Int64.init), keyframePTS: [0], timeBase: 1.0 / 240)
        func updateClickPosition(_ frame: Int) {
            geometryBar.update(frameCount: clickIndex.frameCount, position: frame, cached: [], loopA: nil, loopB: nil,
                               text: "film click")
        }
        geometryBar.updateTimeline(index: clickIndex, duration: 20, paused: true)
        updateClickPosition(1200)
        let click = NSPoint(x: 360, y: 24)
        sendPointer(.mouseMoved, at: click)
        updateClickPosition(1920)
        let projection = TimelineFilmLayout(width: 876, height: 48, aspect: 16.0 / 9, duration: 20, center: 8,
                                            secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7).lens
        let expected = clickIndex.frameNumber(forSeconds: projection.time(at: click.x - 450))
        var landed: Int?
        geometryBar.onFilmSeek = { seconds in
            let frame = clickIndex.frameNumber(forSeconds: seconds)
            landed = frame
            updateClickPosition(frame)
        }
        geometryBar.onFilmClickPreview = geometryBar.onFilmSeek
        geometryBar.displayIfNeeded()
        sendPointer(.leftMouseDown, at: click)
        sendPointer(.leftMouseUp, at: click)
        precondition(landed == expected, "The click must use the current projection after it moves under a stationary pointer")
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        precondition(abs(geometryBar.filmPlayheadX - click.x) <= 1,
                     "The settled playhead must stay over the clicked position in the lens")
        geometryBar.updateTimeline(index: clickIndex, duration: 20, paused: false)
        updateClickPosition(expected + 1)
        let followingProjection = TimelineFilmLayout(width: 876, height: 48, aspect: 16.0 / 9, duration: 20,
            center: clickIndex.seconds(forFrame: expected + 1), secondsPerThumbnail: 1, focusFraction: 0.3,
            cropStrength: 0.7).lens
        precondition(geometryBar.filmPlayheadX == (450 + followingProjection.focusOffset).rounded(),
                     "The lens must follow the playhead when playback resumes")
        geometryBar.updateTimeline(index: nil, duration: 20, paused: true)
        updateClickPosition(0)
        geometryBar.onFilmSeek = nil
        geometryBar.onFilmClickPreview = nil
        geometryBar.setPlaybackControlsVisible(false)
        precondition(geometryBar.hitTest(filmPoint) === geometryBar && geometryBar.hitTest(filmMargin) == nil,
                     "Hiding playback controls must leave the film in place")
        geometryBar.toggleFilmVisibility()
        geometryBar.updateFilmPointer(filmPoint)
        precondition(geometryBar.isInRevealZone(filmPoint) && !geometryBar.showsFilmstrip,
                     "The edge must reveal only the timeline after the strip was explicitly folded")
        geometryBar.setPlaybackControlsVisible(true)
        let foldedMargin = NSPoint(x: 450, y: 26)
        sendPointer(.mouseMoved, at: foldedMargin)
        precondition(hoveredFractions.last == .some(0.5), "The folded track must accept hover above its visible line")
        sendPointer(.leftMouseDown, at: foldedMargin)
        precondition(trackSeeks == [0.5], "The folded track must seek throughout its hover band")
        sendPointer(.leftMouseUp, at: foldedMargin)
        precondition(trackSeekWasContinuous == [false] && scrubEnds == 0, "A click must remain immediate")
        sendPointer(.leftMouseDown, at: foldedMargin)
        let dragTarget = NSPoint(x: foldedMargin.x + 100, y: foldedMargin.y)
        sendPointer(.leftMouseDragged, at: dragTarget)
        sendPointer(.leftMouseUp, at: dragTarget)
        precondition(trackSeekWasContinuous == [false, false, true] && scrubEnds == 1,
                     "An overview drag must flag its move and flush only on release")
        geometryBar.onSeek = nil
        geometryBar.setFilmRevealed(true, force: true)
        let handleIndex = FrameIndex(pts: (0..<480).map(Int64.init), keyframePTS: [0], timeBase: 1.0 / 24)
        geometryBar.updateTimeline(index: handleIndex, duration: 20, paused: true)
        geometryBar.update(frameCount: 480, position: 48, cached: [], loopA: nil, loopB: nil,
                           marks: [48...96], text: "coincident handles")
        geometryBar.setCutEdges(VirtualCutFragmentEdges(rangeID: "fixture", start: 2, end: 4))
        var nativeCommits = 0
        var cutCommits = 0
        geometryBar.onMarkDragBegin = { _ in true }
        geometryBar.onMarkDragEnd = { if $0 { nativeCommits += 1 } }
        geometryBar.onCutEdgeCommit = { _, _, _, _ in cutCommits += 1 }
        guard let native = geometryBar.markHandlePoint(for: .segment(frame: 48, edge: .start)),
              let authored = geometryBar.cutEdgePoint(for: .start) else {
            preconditionFailure("Expected both editing handles")
        }
        for start in [native, authored] {
            let end = NSPoint(x: start.x + 30, y: start.y)
            sendPointer(.leftMouseDown, at: start)
            sendPointer(.leftMouseDragged, at: end)
            sendPointer(.leftMouseUp, at: end)
        }
        precondition(nativeCommits == 1 && cutCommits == 1, "Coincident handles must route independently")
        let ribbon = NavigationRibbonView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))
        ribbon.record(from: 12, to: 90, duration: 120, at: 10)
        ribbon.record(from: 90, to: 104, duration: 120, at: 10.5)
        precondition(ribbon.journey?.origin == 12 && ribbon.journey?.target == 104,
                     "A series retains its first origin and updates the actual landing")
        precondition(ribbon.journey?.displacement == "+1:32", "The readout shows cumulative displacement")
        ribbon.record(from: 104, to: 104, duration: 120, at: 10.6)
        precondition(ribbon.journey?.target == 104, "An end bump must not invent a journey")
        ribbon.record(from: 104, to: 34, duration: 120, at: 13)
        precondition(ribbon.journey?.origin == 104 && ribbon.journey?.target == 34,
                     "An idle gap begins a fresh journey, including backward jumps")
        precondition(ribbon.journey?.displacement == "−1:10" &&
                     NavigationJourney(origin: 10, target: 8.76, duration: 20).displacement == "−1.2 s",
                     "Reverse movement keeps its sign in the time and seconds formats")
        precondition(TimelinePositionText.position(763.2, duration: 2538) == "12:43.2 / 42:18" &&
                     TimelinePositionText.position(0.2, duration: 0.8) == "0:00.2 / 0:00.8")
        ribbon.showWithFullFilm(true)
        precondition(!ribbon.isPresenting && ribbon.journey?.target == 34,
                     "Opening the full film transfers the same journey instead of duplicating it")
        ribbon.showWithFullFilm(false)
        precondition(ribbon.isPresenting, "Folding during a journey restores the compact view")
        ribbon.clear()
        precondition(ribbon.journey == nil, "Closing the source discards the journey")
        let navigationIndex = FrameIndex(pts: (0..<240).map(Int64.init), keyframePTS: [0, 48, 96, 144, 192], timeBase: 1.0 / 24)
        geometryBar.updateTimeline(index: navigationIndex, duration: 10, paused: true)
        let context = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let cached = context.makeImage()!
        for time in [0.0, 2, 4, 6, 8] { geometryBar.setFilmstripImage(cached, seconds: time) }
        let before = geometryBar.navigationProjection(near: 4.5)
        let after = geometryBar.navigationProjection(near: 5.5)
        precondition(before.pictures == after.pictures && before.fraction == 0.25 && after.fraction == 0.75,
                     "The film must move with time between keyframes, using the same pictures")
        let boundary = geometryBar.navigationProjection(near: 6)
        precondition(boundary.fraction == 0 && before.pictures[4] === boundary.pictures[3],
                     "A thumbnail reaches the playhead without jumping when the sample window advances")
        let start = geometryBar.navigationProjection(near: 0)
        precondition(start.pictures.prefix(3).allSatisfy { $0 == nil } && start.fraction == 0,
                     "The beginning keeps the first frame under the playhead")
        precondition(start.placeholderIndices.allSatisfy { $0 >= 3 }, "Do not draw placeholders before the file starts")
        geometryBar.navigationScale = .wide
        let wideProjection = geometryBar.navigationProjection(near: 3)
        precondition(wideProjection.fraction == 0.5 && wideProjection.pictures[4] === boundary.pictures[3],
                     "The wider scale covers more time across the same view")
        geometryBar.navigationScale = .near
        geometryBar.samplesFilmstripByTime = true
        geometryBar.setFilmstripImage(cached, seconds: 4.8)
        let storyboard = geometryBar.navigationProjection(near: 4.1)
        precondition(storyboard.pictures[4] != nil &&
                     storyboard.pictures == geometryBar.navigationProjection(near: 4.9).pictures,
                     "A ready fallback stays in the same slot while the storyboard moves")
        geometryBar.samplesFilmstripByTime = false
        let ruler = TimelineFilmLayout(width: 800, height: 48, aspect: 16.0 / 9, duration: 100,
                                       center: 50, secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7).lens
        let rulerMarks = FilmstripRuler.marks(in: ruler, around: 50)
        precondition(rulerMarks.count == 2 && rulerMarks[0].delta == -rulerMarks[1].delta,
                     "A centered Lens should show the same interval on both sides")
        precondition(rulerMarks.allSatisfy { abs(ruler.time(at: $0.offset) - (50 + $0.delta)) < 0.000_001 },
                     "Each ruler mark must point at the real seek time under the Lens")
        let atStart = FilmstripRuler.marks(in: ruler, around: 0)
        precondition(atStart.count == 1 && atStart[0].delta > 0, "The ruler must end at the file boundary")
        let irregular = NavigationRibbonView.Projection(pictures: Array(repeating: nil, count: 7),
            fraction: 0.5, sampleTimes: [nil, 0, 1, 4, 10, 12, nil])
        precondition(irregular.visibleDuration(pitch: 50, width: 150, duration: 20) == 11,
                     "Mini coverage must follow the visible keyframe times, including unequal intervals")
        precondition(irregular.visibleDuration(pitch: 50, width: 100, duration: 20) == 8.5,
                     "Narrowing the clip must interpolate its partial edge cells")
        precondition(irregular.visibleDuration(pitch: 50, width: 350, duration: 20) == 20,
                     "Coverage must stop at the start and end of the file")
        geometryBar.samplesFilmstripByTime = true
        let clipped = geometryBar.navigationProjection(near: 4.9)
        precondition(clipped.visibleDuration(pitch: 50, width: 250, duration: 10).map { abs($0 - 5) < 0.000_001 } == true,
                     "Storyboard coverage must follow its real one-second sample intervals")
        geometryBar.samplesFilmstripByTime = false
        let edgeIndex = FrameIndex(pts: (0..<600).map(Int64.init),
                                   keyframePTS: [0, 48, 96, 144, 192, 240, 336, 360, 432, 480, 528],
                                   timeBase: 1.0 / 24)
        geometryBar.updateTimeline(index: edgeIndex, duration: 25, paused: true)
        let beyondTileCenter = geometryBar.navigationProjection(near: 9.8)
        precondition(beyondTileCenter.visibleDuration(pitch: 50, width: 250, duration: 25)
                        .map { abs($0 - 11.4) < 0.000_001 } == true,
                     "A partial edge beyond the last drawn tile center must use the next keyframe, not the end of the file")
        geometryBar.updateTimeline(index: navigationIndex, duration: 10, paused: true)
        let wideCaption = FilmstripReadout(time: 1148.2, duration: 7398, anchor: 100,
                                          in: NSRect(x: 0, y: 9, width: 260, height: 17))!
        let narrowCaption = FilmstripReadout(time: 1148.2, duration: 7398, anchor: 100,
                                            in: NSRect(x: 40, y: 9, width: 95, height: 17))!
        precondition(wideCaption.currentRect.midX == 100 && narrowCaption.currentRect == wideCaption.currentRect &&
                     narrowCaption.timeRect == narrowCaption.currentRect && wideCaption.timeRect.width > wideCaption.currentRect.width,
                     "The current time stays centered as the total duration drops out")
        print("filmstrip-scale-check\tpassed: projected ruler, uneven mini coverage, anchored current time")
        precondition(geometryBar.transport.occupiedRects.count == 1, "The transport must occupy one compact region")
        let transport = geometryBar.transport
        transport.layoutSubtreeIfNeeded()
        transport.update(volume: 40, muted: false, paused: true, speed: 1)
        var wheelVolumes: [Double] = []
        transport.onVolume = { wheelVolumes.append($0) }
        precondition(transport.adjustVolume(by: 1, at: NSPoint(x: 119, y: 17), precise: false))
        precondition(!transport.adjustVolume(by: 1, at: NSPoint(x: 49, y: 17), precise: false))
        precondition(wheelVolumes == [42], "The speaker owns the wheel; playback buttons leave volume unchanged")
        geometryBar.setFilmRevealed(false, force: true)
        geometryBar.scrollFilm(by: 24, reveal: false)
        precondition(geometryBar.isScrollingFoldedFilm && !geometryBar.showsFilmstrip,
                     "Controller scrubbing can keep the film folded for compact feedback")
        geometryBar.cancelFilmScroll()
        geometryBar.removeFromSuperview()
        print("timeline-hover-routing-check\tpassed: compact controls, continuous film preview, matching click, larger folded-track target")
        if let arg = CommandLine.arguments.firstIndex(of: "--shots"), CommandLine.arguments.indices.contains(arg + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ribbon.frame = NSRect(x: 12, y: 100, width: 460, height: Config().navigationFilmstripHeight)
            host.addSubview(ribbon)
            ribbon.record(from: 134.2, to: 1117.6, duration: 1530, frames: {
                .init(delta: Int(($1 - $0) * 24), position: (Int($1 * 24), 36_719))
            })
            let colors: [NSColor] = [.systemTeal, .systemBlue, .systemOrange, .systemIndigo, .systemPurple, .systemGreen, .systemPink]
            let pictures = colors.map { color in
                NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in
                    NSGradient(starting: color.withAlphaComponent(0.3), ending: color)?.draw(in: rect, angle: 65)
                    return true
                }
            }.map(Optional.some)
            ribbon.layoutSubtreeIfNeeded()
            func capture(_ view: NSView, _ name: String) {
                window.displayIfNeeded()
                CATransaction.flush()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
            func waitForLensClose() {
                let deadline = Date().addingTimeInterval(1)
                while geometryBar.isInteracting, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                precondition(!geometryBar.isInteracting, "Closing settings must release the timeline")
            }
            ribbon.setProjection(.init(pictures: pictures, fraction: 0.25), geometry: .identity)
            RunLoop.current.run(until: Date().addingTimeInterval(0.28))
            capture(ribbon, "navigation.png")
            let row = ribbon.subviews.flatMap { $0.layer?.sublayers ?? [] }.first { $0.sublayers?.count == pictures.count }
            precondition(row != nil, "Expected a row of persistent tile layers")
            let tile = row!.sublayers!.sorted { $0.position.x < $1.position.x }[3]
            func position() -> CGFloat { row!.affineTransform().tx + tile.position.x }
            ribbon.setProjection(.init(pictures: pictures, fraction: 0.49), geometry: .identity)
            let beforeMiddle = position()
            ribbon.setProjection(.init(pictures: pictures, fraction: 0.51), geometry: .identity)
            precondition(beforeMiddle - position() > 0 && beforeMiddle - position() < 3,
                         "Crossing a thumbnail midpoint should only move the strip by the input distance")
            ribbon.setProjection(.init(pictures: pictures, fraction: 0.99), geometry: .identity)
            let edge = position()
            let shifted = Array(pictures.dropFirst()) + [nil]
            ribbon.setProjection(.init(pictures: shifted, fraction: 0.01), geometry: .identity)
            precondition(edge - position() > 0 && edge - position() < 3,
                         "Advancing the sample window should keep the same visible tile in place")
            ribbon.record(from: 1117.6, to: 1118.6, duration: 1530, frames: {
                .init(delta: Int(($1 - $0) * 24), position: (Int($1 * 24), 36_719))
            })
            let sampleTimes: [Double?] = [1098, 1103, 1109, 1113, 1115, 1119.8, 1123, 1129, 1133]
            ribbon.setProjection(.init(pictures: pictures, fraction: 0.75, sampleTimes: sampleTimes), geometry: .identity)
            capture(ribbon, "navigation-offset.png")
            let inStrip = ribbon.convert(NSPoint(x: ribbon.bounds.midX, y: 12), to: nil)
            precondition(ribbon.updatePointer(inStrip), "Hover should expose the compact controls")
            let anchor = ribbon.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Filmstrip settings" }!
            precondition(geometryBar.showMiniLensControls(relativeTo: anchor))
            ribbon.setSettingsOpen(true)
            let popupViews = NSApp.windows.compactMap(\.contentView).flatMap { descendants(of: $0) }
            let miniSize = popupViews.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Mini Strip width" }!
            precondition(!miniSize.isHiddenOrHasHiddenAncestor && !geometryBar.showsFilmstrip,
                         "The shared settings should open directly on mini dimensions without unfolding the full filmstrip")
            var miniSizeChanged = false
            geometryBar.onMiniFilmSizeChange = { width, height in miniSizeChanged = width == 75 && height == 106 }
            miniSize.doubleValue = 75
            NSApp.sendAction(miniSize.action!, to: miniSize.target, from: miniSize)
            precondition(miniSizeChanged, "The Mini Strip width slider must apply the configured size")
            if let popup = miniSize.window?.contentView { capture(popup, "timeline-settings-mini.png") }
            let tabs = popupViews.compactMap { $0 as? NSSegmentedControl }.first {
                $0.segmentCount == 2 && $0.label(forSegment: 1) == "Mini Strip"
            }!
            tabs.selectedSegment = 0
            NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let stretch = descendants(of: tabs.window!.contentView!).compactMap { $0 as? NSSlider }.first {
                $0.accessibilityLabel() == "Thumbnail stretch"
            }!
            precondition(!stretch.isHiddenOrHasHiddenAncestor && miniSize.window == nil &&
                         (tabs.window?.frame.height ?? 0) > 500,
                         "Both strips must get fitting controls from the same Filmstrip tab")
            if let popup = stretch.window?.contentView { capture(popup, "timeline-settings-film.png") }
            tabs.selectedSegment = 1
            NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            precondition((tabs.window?.frame.height ?? .infinity) < 260, "The mini settings should return to their compact height")
            geometryBar.closeMiniLensControls()
            ribbon.setSettingsOpen(false)
            waitForLensClose()
            host.addSubview(geometryBar)
            geometryBar.setFilmRevealed(true, force: true)
            let lens = geometryBar.modeControl.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Lens settings" }!
            NSApp.sendAction(lens.action!, to: lens.target, from: lens)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            precondition((tabs.window?.frame.height ?? 0) > 500 &&
                         !stretch.isHiddenOrHasHiddenAncestor && stretch.window === tabs.window,
                         "Opening full film settings after closing the mini panel must restore the taller size")
            NSApp.sendAction(lens.action!, to: lens.target, from: lens)
            waitForLensClose()
            geometryBar.setFilmRevealed(false, force: true)
            geometryBar.removeFromSuperview()
            let scaleKey = "navigation-filmstrip-scale"
            let savedScale = UserDefaults.standard.object(forKey: scaleKey)
            defer { UserDefaults.standard.set(savedScale, forKey: scaleKey) }
            let toggle = ribbon.subviews.compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Navigation filmstrip scale"
            }!
            precondition(toggle.title.hasPrefix(ribbon.scale.title + " · ") && toggle.title.hasSuffix(" s"),
                         "The mini scale button should show the span for an irregular keyframe row")
            let initial = ribbon.scale
            var changedScale = false
            ribbon.onScaleChanged = { changedScale = true }
            toggle.performClick(nil)
            precondition(changedScale && ribbon.scale != initial)
            toggle.performClick(nil)
            capture(ribbon, "navigation-controls.png")
            ribbon.configureThumbnailFit(crop: 0, stretch: 0)
            capture(ribbon, "navigation-fit.png")
            ribbon.configureThumbnailFit(crop: 0, stretch: 1)
            capture(ribbon, "navigation-stretch.png")
            ribbon.configureThumbnailFit(crop: 1, stretch: 0)
            ribbon.frame.size.width = 260
            ribbon.layoutSubtreeIfNeeded()
            capture(ribbon, "navigation-narrow.png")
            ribbon.setPictureAspect(9.0 / 16)
            let radius = ribbon.sampleRadius
            precondition(radius > NavigationRibbonView.Projection.defaultRadius,
                         "Portrait thumbnails should use more cells in the same viewport")
            let portrait = NSImage(size: NSSize(width: 90, height: 160), flipped: false) { rect in
                NSGradient(starting: .systemTeal, ending: .systemBlue)?.draw(in: rect, angle: 65)
                return true
            }
            ribbon.setProjection(.init(pictures: Array(repeating: portrait, count: 2 * radius + 1), fraction: 0.25),
                                 geometry: .identity)
            let laidOut = row?.sublayers?.sorted { $0.position.x < $1.position.x } ?? []
            precondition(laidOut.count == 2 * radius + 1 && laidOut[0].bounds.width <= laidOut[0].bounds.height * 9 / 16 &&
                         abs(laidOut[1].position.x - laidOut[0].position.x - laidOut[0].bounds.width - 2) < 0.01,
                         "Portrait thumbnails must pack with the normal two-point gap")
            capture(ribbon, "navigation-portrait.png")
            ribbon.setPictureAspect(16.0 / 9)
            ribbon.clear()
            precondition(toggle.isHidden && !ribbon.isPresenting, "Closing the ribbon removes its controls")
            ribbon.removeFromSuperview()

            host.addSubview(geometryBar)
            geometryBar.setCutEdges(nil)
            geometryBar.setFilmMode(.lens, save: false)
            geometryBar.setPlaybackControlsVisible(true)
            geometryBar.setFilmRevealed(true, force: true)
            geometryBar.update(frameCount: 240, position: 120, cached: [], loopA: nil, loopB: nil, text: "Position")
            geometryBar.navigationJourney = NavigationJourney(origin: 1, target: 5, duration: 10, frames: .init(delta: 96))
            for (slot, picture) in pictures.prefix(5).enumerated() {
                if let source = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    geometryBar.setFilmstripImage(source, seconds: Double(slot * 2))
                }
            }
            sendPointer(.mouseMoved, at: NSPoint(x: 713, y: 24))
            precondition(geometryBar.filmCursorX == 713, "Capture the preview cursor separately from the playhead")
            capture(geometryBar, "film-position.png")
            sendPointer(.mouseMoved, at: NSPoint(x: geometryBar.filmPlayheadX, y: 24))
            precondition(geometryBar.filmCursorX == geometryBar.filmPlayheadX, "Capture the cursor over the playhead")
            capture(geometryBar, "film-position-overlap.png")
            sendPointer(.mouseMoved, at: NSPoint(x: 713, y: 3))
            precondition(geometryBar.overviewHoverFraction != nil && geometryBar.filmCursorX == nil)
            capture(geometryBar, "film-overview-hover.png")
            geometryBar.frame.size.width = 420
            geometryBar.layoutSubtreeIfNeeded()
            sendPointer(.mouseMoved, at: NSPoint(x: 348, y: 24))
            capture(geometryBar, "film-position-narrow.png")

            let source = VirtualCutSource(kind: .scene, locator: "1", version: "original")
            let cut = VirtualCutTimeline(ranges: [
                VirtualCutRange(id: "a", source: source, start: 10, end: 13),
                VirtualCutRange(id: "b", source: source, start: 70, end: 77)
            ])!
            geometryBar.setCutTimeline(cut)
            geometryBar.updateVirtualCut(time: 5, span: 1, paused: true, previewSettle: 0)
            precondition(geometryBar.accessibilityValue() as? String == "0:05.0 / 0:10 · Fragment 2 / 2")
            for (span, picture) in pictures.prefix(2).enumerated() {
                if let source = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    geometryBar.setCutPoster(source, span: span)
                }
            }
            sendPointer(.mouseMoved, at: NSPoint(x: 365, y: 24))
            capture(geometryBar, "film-position-cut.png")
            geometryBar.navigationJourney = nil
            let background = NSImageView(frame: host.bounds)
            background.image = NSImage(size: host.bounds.size, flipped: false) { rect in
                NSGradient(starting: .systemIndigo, ending: .systemYellow)?.draw(in: rect, angle: 0)
                return true
            }
            background.imageScaling = .scaleAxesIndependently
            host.addSubview(background, positioned: .below, relativeTo: geometryBar)
            host.addSubview(ribbon)
            ribbon.frame.origin.y = 193
            ribbon.record(from: 4, to: 30, duration: 68)
            ribbon.setProjection(.init(pictures: pictures, fraction: 0.25), geometry: .identity)
            ribbon.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.28))
            capture(host, "timeline-glass-over-color.png")
            ribbon.clear()
            ribbon.removeFromSuperview()
            background.removeFromSuperview()
            geometryBar.removeFromSuperview()
        }
        if CommandLine.arguments.contains("--timeline-input-only") { exit(EXIT_SUCCESS) }
        let index = FrameIndex(pts: (0..<72000).map(Int64.init), keyframePTS: Set(stride(from: 0, to: 72000, by: 48).map(Int64.init)),
                               timeBase: 1.0 / 24)
        func now() -> Double { var time = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time); return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9 }
        func measure(_ body: () -> Void) -> Double { let start = now(); body(); CATransaction.flush(); return (now() - start) * 1000 }
        func report(_ name: String, _ round: Int, _ values: [Double]) {
            let sorted = values.sorted()
            print(String(format: "%@\t%d\t%.3f\t%.3f\t%.3f", name, round, sorted[sorted.count / 2],
                         sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.last!))
        }
        func refresh(_ bar: SeekBarView, _ position: Int) {
            bar.updateTimeline(index: index, duration: 3000, paused: true)
            bar.update(frameCount: 72000, position: position, cached: [], loopA: nil, loopB: nil, text: "bench")
            bar.layoutSubtreeIfNeeded(); bar.displayIfNeeded()
        }
        print("action\tround\tp50 ms\tp99 ms\tmax ms")
        var finalBar: SeekBarView?
        func spin(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let event = NSApp.nextEvent(matching: .any, until: min(end, Date().addingTimeInterval(0.01)),
                                               inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            }
        }
        for round in 1...5 {
            var bar: SeekBarView!
            let created = measure {
                bar = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 130))
                precondition(!bar.showsFilmstrip)
                bar.setPlaybackControlsVisible(true)
                precondition(!bar.showsFilmstrip, "Mouse playback chrome must not reveal film")
                bar.setFilmRevealed(true)
                host.addSubview(bar); refresh(bar, 24000)
            }
            report("first-layout", round, [created])
            var updates: [Double] = [], narrow: [Double] = [], returns: [Double] = [], reveals: [Double] = []
            for step in 0..<50 {
                updates.append(measure { refresh(bar, 24000 + step) })
                narrow.append(measure { bar.setFrameSize(NSSize(width: 320, height: bar.preferredHeight)); refresh(bar, step.isMultiple(of: 2) ? 0 : 71999) })
                returns.append(measure { bar.setFrameSize(NSSize(width: 900, height: bar.preferredHeight)); refresh(bar, 24000) })
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 50, y: 10), modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 0, pressure: 0) {
                    reveals.append(measure { bar.mouseMoved(with: event) })
                }
            }
            report("position-update", round, updates); report("narrow-boundary", round, narrow); report("return-wide", round, returns)
            report("reveal", round, reveals)
            if round < 5 { bar.removeFromSuperview() } else { finalBar = bar }
        }
        if let bar = finalBar, let arg = CommandLine.arguments.firstIndex(of: "--shots"), CommandLine.arguments.indices.contains(arg + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, width, position) in [("start", 900, 0), ("end", 900, 71999), ("narrow", 320, 24000)] {
                bar.setFrameSize(NSSize(width: CGFloat(width), height: bar.frame.height))
                bar.setFrameSize(NSSize(width: CGFloat(width), height: bar.preferredHeight))
                refresh(bar, position)
                if let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                    bar.cacheDisplay(in: bar.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
                }
            }
        }
        if let bar = finalBar {
            bar.setFilmRevealed(false, force: true)
            bar.setPlaybackControlsVisible(false)
            bar.layoutSubtreeIfNeeded()
            bar.needsDisplay = false
            let lateImage = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { rect in
                NSColor.gray.setFill(); rect.fill(); return true
            }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            bar.setFilmstripImage(lateImage, seconds: 0)
            precondition(!bar.needsDisplay, "Late thumbnail delivery must not redraw folded film")
            var hiddenRequests: [[Double]] = []
            bar.onFilmstripRequest = { hiddenRequests.append($0) }
            bar.updateTimeline(index: index, duration: 3000, paused: false)
            bar.update(frameCount: 72000, position: 10001, cached: [], loopA: nil, loopB: nil, text: "hidden")
            precondition(!bar.needsDisplay, "Playback ticks must not redraw hidden film and progress")
            spin(0.35)
            precondition(hiddenRequests.allSatisfy(\.isEmpty), "Folded film must not start thumbnail work")
            precondition(!bar.isAnimatingFilm, "Folded film must have no motion timer")
            bar.onFilmstripRequest = nil
            bar.setPlaybackControlsVisible(true)
            bar.setFilmRevealed(true)
            print("hidden-film-check\tpassed: late image cached without redraw, playback quiet, no requests or motion")
        }
        if let bar = finalBar, !CommandLine.arguments.contains("--offscreen") {
            window.makeKeyAndOrderFront(nil); app.activate()
            let visibleDeadline = Date().addingTimeInterval(3)
            while !window.occlusionState.contains(.visible), Date() < visibleDeadline { spin(0.05) }
            precondition(window.occlusionState.contains(.visible), "Interaction checks need an unobscured window")
            var requests: [[Double]] = []
            bar.onFilmstripRequest = { requests.append($0) }
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            func height(_ value: Int) {
                let item = bar.menu(for: event)!.items.first { $0.tag == value && $0.action != nil }!
                _ = bar.perform(item.action!, with: item)
                bar.layoutSubtreeIfNeeded()
            }
            refresh(bar, 10000)
            height(0)
            requests = []
            spin(0.35)
            precondition(requests.allSatisfy(\.isEmpty), "Hidden film must cancel queued thumbnail requests")
            height(36)
            func buttons(_ view: NSView) -> [NSButton] {
                view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) }
            }
            let volume = buttons(bar.transport).first { $0.toolTip == "Volume" }!
            volume.performClick(nil)
            bar.mouseExited(with: event)
            requests = []
            spin(0.7)
            precondition(requests.allSatisfy(\.isEmpty), "A held popover must suppress background requests")
            volume.performClick(nil)
            // AppKit closes its popover asynchronously; the bar's delay starts after didClose, then fades.
            let hideDeadline = Date().addingTimeInterval(3)
            while bar.transport.alphaValue >= 0.01, Date() < hideDeadline { spin(0.05) }
            precondition(requests.contains { !$0.isEmpty }, "Closing the popover must resume missing thumbnails")
            if bar.transport.alphaValue >= 0.01 {
                let point = bar.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                FileHandle.standardError.write(Data("hide diagnostic: alpha=\(bar.transport.alphaValue) holding=\(bar.transport.holding) interacting=\(bar.isInteracting) pointer=\(point) bounds=\(bar.bounds)\n".utf8))
            }
            precondition(bar.transport.alphaValue < 0.01, "Closing a popover outside the bar must restart hiding")
            print("interaction-checks\tpassed: hide-cancels, hold-defers, close-resumes, close-hides")
            // Optional integration smoke test with scripts/make-fixtures.sh's 600-frame H.264 fixture.
            if let arg = CommandLine.arguments.firstIndex(of: "--fixture"), CommandLine.arguments.indices.contains(arg + 1) {
                let fixture = FrameIndex(pts: (0..<600).map(Int64.init), keyframePTS: [0, 250, 500], timeBase: 1.0 / 30)
                let loader = FilmstripPreviewLoader(url: URL(fileURLWithPath: CommandLine.arguments[arg + 1]),
                    index: fixture, rotation: 0, width: 160, cache: nil,
                    policy: CommandLine.arguments.contains("--film-network") ? .network : .local)
                var loaded = 0
                let loadingStart = ProcessInfo.processInfo.systemUptime
                loader.mayRead = { bar.showsFilmstrip && !bar.isInteracting }
                loader.onImage = { image, seconds in
                    loaded += 1; bar.setFilmstripImage(image, seconds: seconds)
                    print(String(format: "film-image\t%d\t%.3f ms", loaded,
                                 (ProcessInfo.processInfo.systemUptime - loadingStart) * 1000))
                }
                bar.resetFilmstrip()
                bar.onFilmstripRequest = { loader.request($0) }
                bar.updateTimeline(index: fixture, duration: 20, paused: true)
                bar.update(frameCount: 600, position: 300, cached: [], loopA: nil, loopB: nil, text: "fixture")
                let deadline = Date().addingTimeInterval(5)
                while loaded < 3, Date() < deadline { spin(0.05) }
                precondition(loaded >= 3, "Actual decoder must deliver the three visible fixture keyframes")
                loader.stop()
                print("thumbnail-integration\tpassed: \(loaded) images delivered by utility decoder")
            }
        }
        if let bar = finalBar, CommandLine.arguments.contains("--offscreen") {
            bar.setFilmRevealed(true)
            let fixture = FrameIndex(pts: (0..<600).map(Int64.init), keyframePTS: [0, 250, 500], timeBase: 1.0 / 30)
            for aspect in [9.0 / 16, 2.35] {
                let size = NSSize(width: 160 * aspect, height: 160)
                let image = NSImage(size: size, flipped: false) { rect in
                    NSColor.systemTeal.setFill(); rect.fill()
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.midX - 30, y: rect.midY - 30, width: 60, height: 60)).fill()
                    return true
                }
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                bar.setFrameSize(NSSize(width: 900, height: bar.preferredHeight))
                bar.resetFilmstrip()
                bar.updateTimeline(index: fixture, duration: 20, paused: true, uprightSize: size)
                bar.update(frameCount: 600, position: 300, cached: [], loopA: nil, loopB: nil, text: "aspect")
                bar.layoutSubtreeIfNeeded()
                for time in [0.0, 250.0 / 30, 500.0 / 30] {
                    bar.setFilmstripImage(cg, seconds: time)
                    precondition(!bar.needsDisplay, "A delivered image must paint without a new input event")
                }
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 450, y: 24), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                bar.mouseMoved(with: event)
                precondition(bar.filmPointer != nil, "Hover must stay on the timeline")
                precondition(bar.hitTest(NSPoint(x: 450, y: 24)) === bar, "Hover must pass through seek input")
                if let arg = CommandLine.arguments.firstIndex(of: "--shots") {
                    let directory = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
                    let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                    bar.cacheDisplay(in: bar.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(aspect < 1 ? "portrait-hover.png" : "wide-hover.png"))
                }
                bar.mouseExited(with: event)
                precondition(bar.filmPointer == nil, "The hover marker must disappear on exit")
            }
            print("aspect-hover-checks\tpassed: portrait, wide, hover marker, seek passthrough, exit")
            bar.setFilmRevealed(false)
            bar.setPlaybackControlsVisible(true)
            precondition(!bar.showsFilmstrip, "Playback reveal must not open film")
            bar.updateFilmPointer(NSPoint(x: 450, y: 8))
            precondition(bar.showsFilmstrip, "Entering the film zone must open it")
            bar.updateFilmPointer(nil); spin(0.6)
            precondition(!bar.showsFilmstrip, "Film must fold promptly after leaving")
            bar.toggleFilmPin(); bar.updateFilmPointer(nil); spin(0.6)
            precondition(bar.showsFilmstrip && bar.filmPinned, "Pinned film must stay without mouse activity")
            bar.toggleFilmPin()
            bar.setPlaybackControlsVisible(true)
            bar.setFilmRevealed(true)
            var seeks: [Double] = []
            bar.onFilmSeek = { seeks.append($0) }
            func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 24), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            }
            let marginX = bar.transport.frame.maxX + 16
            bar.mouseDown(with: mouse(.leftMouseDown, marginX))
            bar.mouseDragged(with: mouse(.leftMouseDragged, marginX + 2))
            bar.mouseUp(with: mouse(.leftMouseUp, marginX + 2))
            precondition(seeks.count == 1 && seeks[0] > 10, "Click jitter must seek to the clicked position without starting a centre drag")
            bar.mouseMoved(with: mouse(.mouseMoved, marginX))
            var trackSeeks: [Double] = []
            bar.onSeek = { trackSeeks.append($0) }
            let marginPoint = NSPoint(x: marginX, y: 60)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let marginEvent = NSEvent.mouseEvent(with: type, location: marginPoint, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                if type == .leftMouseDown { bar.mouseDown(with: marginEvent) } else { bar.mouseUp(with: marginEvent) }
            }
            precondition(trackSeeks.isEmpty && seeks.count == 2 && seeks[0] == seeks[1],
                         "The margin must seek to the same time as the row below it")
            bar.onSeek = nil
            bar.mouseDown(with: mouse(.leftMouseDown, 600))
            bar.mouseDragged(with: mouse(.leftMouseDragged, 620))
            bar.updateFilmPointer(nil)
            let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 600, y: 250), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            bar.mouseUp(with: outside); spin(0.6)
            precondition(!bar.showsFilmstrip, "Releasing a drag outside must rearm hiding")
            bar.setFilmRevealed(true)
            func wheel(_ x: Int32, _ y: Int32, option: Bool = false) -> NSEvent {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
                if option { cg.flags = .maskAlternate }
                cg.location = CGPoint(x: 450, y: NSScreen.screens[0].frame.height - 24)
                return NSEvent(cgEvent: cg)!
            }
            var scrubs = 0
            bar.onFilmScrubBegan = { scrubs += 1 }
            seeks = []
            bar.scrollWheel(with: wheel(0, 1))
            precondition(seeks.count == 1 && seeks[0] < 10, "A vertical wheel notch must choose the previous drawn sample")
            precondition(scrubs == 1, "Beginning a film scroll must switch playback to paused scrubbing")
            let shown = Set(TimelineFilmLayout(width: 876, height: 48, aspect: 2.35, duration: 20, center: 10,
                secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7).cells.compactMap(\.seconds))
            precondition(shown.contains(seeks[0]))
            seeks = []
            for _ in 0..<10 { bar.scrollWheel(with: wheel(1, 0)) }
            precondition(seeks.count > 1 && seeks.allSatisfy { shown.contains($0) }, "Mouse wheel must select the existing drawn samples")
            precondition(zip(seeks, seeks.dropFirst()).allSatisfy { $0 > $1 }, "Each notch must select the next sample, with no repeats at the end")
            bar.mouseMoved(with: mouse(.mouseMoved, 600))
            bar.scrollWheel(with: wheel(0, 1, option: true))
            let scaled = TimelineFilmLayout(width: 876, height: 48, aspect: 2.35, duration: 20, center: 10,
                secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7, outsideDensity: 2.75 * exp(-0.2))
            precondition(bar.filmPointer == nil && scaled.cell(at: 150)?.seconds != nil,
                         "Changing density must clear the old hover target while preserving samples")
            bar.configureLens(seconds: 1, focus: 0.3, crop: 0.7, magnification: 2.75, density: 2.75, save: false)
            bar.cancelInteraction()
            let beforeOption = scrubs
            bar.scrollWheel(with: wheel(0, 1, option: true))
            precondition(scrubs == beforeOption, "Option adjustment alone must not pause")
            bar.scrollWheel(with: wheel(0, -1))
            precondition(scrubs == beforeOption + 1, "Releasing Option during a wheel gesture must pause on its first seek")
            bar.cancelInteraction()
            let rightClick = mouse(.rightMouseDown, 450)
            let disabled = bar.menu(for: rightClick)!.items.first { $0.title == "Hide Filmstrip" }!
            _ = bar.perform(disabled.action!, with: disabled)
            bar.updateFilmPointer(NSPoint(x: 450, y: 8))
            precondition(!bar.showsFilmstrip && !bar.filmstripEnabled)
            UserDefaults.standard.set(true, forKey: "timeline-film-pinned")
            UserDefaults.standard.set(48, forKey: "timeline-film-height")
            let restored = SeekBarView(frame: .zero)
            var collapsedHeight: CGFloat?
            restored.onHeightChange = { collapsedHeight = $0 }
            restored.toggleFilmVisibility()
            precondition(collapsedHeight == 76 && !restored.showsFilmstrip, "A saved pin must fold with layout immediately")
            print("input-visibility-checks\tpassed: separate reveal, edge, leave, pin, click jitter, both scroll axes, disabled film")
            let medium = bar.menu(for: rightClick)!.items.first { $0.title == "Medium Thumbnails" }!
            _ = bar.perform(medium.action!, with: medium)
            bar.setFrameSize(NSSize(width: 900, height: 140))
            let pattern = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
                NSColor.systemTeal.setFill(); rect.fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 130, y: 60, width: 60, height: 60)).fill()
                return true
            }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            for density in [1.0, 2.75, 4, 8] {
                bar.configureLens(seconds: 1, focus: 0.3, crop: 0.7, magnification: 2.75, density: density, save: false)
                bar.updateTimeline(index: index, duration: 3000, paused: true, uprightSize: NSSize(width: 320, height: 180))
                bar.update(frameCount: 72000, position: 24000, cached: [], loopA: nil, loopB: nil, text: "density")
                bar.layoutSubtreeIfNeeded()
                let model = TimelineFilmLayout(width: 876, height: 64, aspect: 16.0 / 9, duration: 3000,
                    center: 1000, secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 0.7, outsideDensity: density)
                var deliveries: [Double] = []
                for time in Set(model.cells.compactMap(\.seconds).map {
                    index.seconds(forFrame: index.keyframe(atOrBefore: index.frameNumber(forSeconds: $0)))
                }) { deliveries.append(measure { bar.setFilmstripImage(pattern, seconds: time) }) }
                report("density-delivery-\(density)", 1, deliveries)
                print("density-count\tdensity=\(density)\tcells=\(model.cells.count)")
                if let arg = CommandLine.arguments.firstIndex(of: "--shots") {
                    let directory = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
                    let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                    bar.cacheDisplay(in: bar.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("density-\(density).png"))
                }
            }
            bar.setFrameSize(NSSize(width: 2560, height: 140))
            bar.configureLens(seconds: 1, focus: 0.3, crop: 1, save: false)
            bar.updateTimeline(index: index, duration: 3000, paused: true, uprightSize: NSSize(width: 90, height: 160))
            var wideUpdates: [Double] = []
            for step in 0..<50 {
                wideUpdates.append(measure {
                    bar.update(frameCount: 72000, position: 24000 + step, cached: [], loopA: nil, loopB: nil, text: "dense")
                    bar.layoutSubtreeIfNeeded(); bar.displayIfNeeded()
                })
            }
            let maximum = TimelineFilmLayout(width: 2536, height: 64, aspect: 9.0 / 16, duration: 3000,
                center: 1000, secondsPerThumbnail: 1, focusFraction: 0.3, cropStrength: 1)
            precondition(maximum.cells.count == TimelineFilmLayout.maximumCells)
            report("adaptive-65-cells", 1, wideUpdates)
            var sliderUpdates: [Double] = []
            for step in 0..<50 {
                sliderUpdates.append(measure {
                    bar.configureLens(seconds: 1, focus: 0.3 + Double(step) / 500, crop: 0.7,
                                      magnification: 1 + Double(step) / 20, density: 2.75)
                    bar.displayIfNeeded()
                })
            }
            report("lens-live-settings", 1, sliderUpdates)
            window.setContentSize(NSSize(width: 900, height: 480))
            let controls = TimelineLensControls()
            let opened = measure { controls.setValues(seconds: 1, focus: 0.3, crop: 0.7); host.addSubview(controls.view) }
            report("lens-controls-first", 1, [opened])
            let densitySlider = descendants(of: controls.view).compactMap { $0 as? NSSlider }.first {
                $0.accessibilityLabel() == "Outside density"
            }!
            controls.setValues(seconds: 1, focus: 0.3, crop: 0.7, density: 8)
            precondition(densitySlider.doubleValue == 8, "The density slider must accept and restore 8×")
            precondition(descendants(of: controls.view).compactMap { $0 as? NSSlider }.contains {
                $0.accessibilityLabel() == "Filmstrip height"
            }, "Film settings must expose the strip height beside the lens controls")
            let heightSlider = descendants(of: controls.view).compactMap { $0 as? NSSlider }.first {
                $0.accessibilityLabel() == "Filmstrip height"
            }!
            controls.onHeightChange = { bar.configureFilmHeight($0) }
            var heightUpdates: [Double] = []
            for height in [36.0, 96, 57] {
                heightUpdates.append(measure {
                    heightSlider.doubleValue = height
                    NSApp.sendAction(heightSlider.action!, to: heightSlider.target, from: heightSlider)
                    bar.setFrameSize(NSSize(width: 2560, height: bar.preferredHeight))
                    bar.layoutSubtreeIfNeeded(); bar.displayIfNeeded()
                })
                precondition(bar.preferredHeight == height + 45, "Slider must resize the actual film live")
                precondition(UserDefaults.standard.double(forKey: "timeline-film-height") == height)
            }
            let resized = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 140))
            resized.setFilmRevealed(true)
            precondition(resized.preferredHeight == 102, "A new timeline must restore the chosen 57 pt height")
            let reset = descendants(of: controls.view).compactMap { $0 as? NSButton }.first { $0.title == "Reset" }!
            // This standalone content controller has no popover visibility hold. Animated performClick pumps
            // unrelated auto-hide timers; send the real reset action directly to test its resize/persistence.
            NSApp.sendAction(reset.action!, to: reset.target, from: reset)
            precondition(bar.preferredHeight == 93 && heightSlider.doubleValue == 48, "Reset must restore 48 pt")
            report("film-height-live-65-cells", 1, heightUpdates)
            print("film-height-check\tpassed: native slider, live geometry, persisted restore, reset")
            if let arg = CommandLine.arguments.firstIndex(of: "--shots") {
                let bitmap = controls.view.bitmapImageRepForCachingDisplay(in: controls.view.bounds)!
                controls.view.cacheDisplay(in: controls.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[arg + 1]).appendingPathComponent("lens-controls.png"))
            }
            controls.view.removeFromSuperview()
            controls.onHeightChange = nil
            bar.configureFilmHeight(64, save: false)
            bar.setFrameSize(NSSize(width: 900, height: 140))
            bar.configureLens(seconds: 1, focus: 0.3, crop: 0.7, magnification: 2.75, density: 2.75, save: false)
            var prepared = Set<Double>()
            for mode in TimelineFilmMode.allCases {
                bar.setFilmMode(mode, save: false)
                let positions = mode == .segment ? [24000, 24006, 24012] : [24000, 25200, 26400]
                for (step, position) in positions.enumerated() {
                    bar.updateTimeline(index: index, duration: 3000, paused: true, uprightSize: NSSize(width: 320, height: 180))
                    bar.update(frameCount: 72000, position: position, cached: [], loopA: nil, loopB: nil, text: "motion")
                    let model = TimelineFilmLayout(width: 876, height: 64, aspect: 16.0 / 9, duration: 3000,
                        center: index.seconds(forFrame: position), secondsPerThumbnail: 1, focusFraction: 0.3,
                        cropStrength: 0.7, mode: mode)
                    for seconds in model.cells.compactMap(\.seconds) {
                        let key = index.seconds(forFrame: index.keyframe(atOrBefore: index.frameNumber(forSeconds: seconds)))
                        guard prepared.insert(key).inserted else { continue }
                        let frame = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
                            NSColor(calibratedHue: (key / 17).truncatingRemainder(dividingBy: 1), saturation: 0.55,
                                    brightness: 0.65, alpha: 1).setFill(); rect.fill()
                            NSColor.white.setFill()
                            NSBezierPath(ovalIn: NSRect(x: 130, y: 60, width: 60, height: 60)).fill()
                            return true
                        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                        bar.setFilmstripImage(frame, seconds: key)
                    }
                    bar.setPlaybackControlsVisible(true); bar.layoutSubtreeIfNeeded(); bar.displayIfNeeded()
                    if let arg = CommandLine.arguments.firstIndex(of: "--shots") {
                        let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                        bar.cacheDisplay(in: bar.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: CommandLine.arguments[arg + 1]).appendingPathComponent("mode-\(mode.rawValue)-\(step).png"))
                    }
                }
            }
            let seeksBefore = seeks.count
            bar.modeControl.onSelect?(.lens)
            precondition(bar.filmMode == .lens && seeks.count == seeksBefore, "View selection must not seek")
            bar.layoutSubtreeIfNeeded()
            bar.updateFilmPointer(bar.convert(NSPoint(x: bar.modeControl.frame.midX, y: bar.modeControl.frame.midY), to: nil))
            spin(0.6)
            precondition(bar.showsFilmstrip, "Hovering the mode capsule must hold the film open")
            bar.setPlaybackControlsVisible(true); bar.layoutSubtreeIfNeeded()
            func transportButtons(_ view: NSView) -> [NSButton] {
                view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? transportButtons($0) }
            }
            for edge in [30.0, 870] {
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: edge, y: 24), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                bar.mouseMoved(with: event)
                precondition(bar.filmPointer != nil, "An edge cell must accept hover")
                for button in transportButtons(bar.transport) {
                    let local = bar.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    precondition(bar.hitTest(local) === button, "A thumbnail must never take a transport button's hit")
                }
                let expectedTooltip = edge < 450 ? "Back 10 seconds" : "Enter Full Screen"
                guard let button = transportButtons(bar.transport).first(where: { $0.toolTip == expectedTooltip }) else {
                    preconditionFailure("Missing transport control: \(expectedTooltip)")
                }
                let local = bar.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                let enter = NSEvent.mouseEvent(with: .mouseMoved, location: bar.convert(local, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                bar.mouseMoved(with: enter)
                precondition(bar.filmPointer == nil, "Moving directly from the film into a control must clear the hover marker")
            }
            print("edge-controls-checks\tpassed: no overlap, all buttons hit, direct transition clears hover")
            if bar.filmPinned { bar.toggleFilmPin() }
            bar.setFilmRevealed(true); bar.setPlaybackControlsVisible(true); bar.layoutSubtreeIfNeeded()
            let pin = bar.modeControl.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Pin Filmstrip (⇧⌘L)" }!
            let pinPoint = bar.convert(NSPoint(x: pin.bounds.midX, y: pin.bounds.midY), from: pin)
            precondition(bar.hitTest(pinPoint) === pin, "The strip's pin button must take its own hit")
            pin.performClick(nil)
            precondition(bar.filmPinned && bar.showsFilmstrip && pin.state == .on &&
                         UserDefaults.standard.bool(forKey: "timeline-film-pinned"), "The on-strip pin must latch and persist")
            pin.performClick(nil)
            precondition(!bar.filmPinned && pin.state == .off, "The same button must unpin the strip")
            let tuning = bar.modeControl.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Lens settings" }!
            for round in 1...10 {
                bar.setFilmRevealed(true); bar.setPlaybackControlsVisible(true); bar.layoutSubtreeIfNeeded()
                let cost = measure { tuning.performClick(nil) }
                precondition(bar.isInteracting, "The on-film tuning button must open the live controls")
                report("lens-dropdown-open", round, [cost])
                if round == 1 {
                    func sliders(in view: NSView) -> [NSSlider] {
                        view.subviews.flatMap { ($0 as? NSSlider).map { [$0] } ?? sliders(in: $0) }
                    }
                    let liveHeight = NSApp.windows.compactMap(\.contentView).flatMap { sliders(in: $0) }.first {
                        $0.accessibilityLabel() == "Filmstrip height" && $0.window?.isVisible == true
                    }!
                    liveHeight.doubleValue = 75
                    NSApp.sendAction(liveHeight.action!, to: liveHeight.target, from: liveHeight)
                    bar.setFrameSize(NSSize(width: 900, height: bar.preferredHeight)); bar.layoutSubtreeIfNeeded()
                    precondition(bar.preferredHeight == 120 && bar.isInteracting,
                                 "The retained popover must remain open while resizing its owner")
                }
                tuning.performClick(nil)
                let deadline = Date().addingTimeInterval(2)
                while bar.isInteracting, Date() < deadline { spin(0.02) }
                precondition(!bar.isInteracting, "Closing the dropdown must release the timeline")
            }
            print("stable-view-checks\tpassed: on-film selection, no seek, mode capsule holds reveal, motion shots")

            bar.setFilmMode(.overview, save: false)
            bar.setFilmRevealed(true)
            refresh(bar, 24000)
            bar.update(frameCount: 72000, position: 24000, cached: [], loopA: nil, loopB: nil,
                       marks: [36000...45000], text: "edge drag")
            var grabbed: MarkEdgeHandle?
            var movedTo: Double?
            var committed: Bool?
            bar.onMarkDragBegin = { grabbed = $0; return true }
            bar.onMarkDragMove = { movedTo = $0 }
            bar.onMarkDragEnd = { committed = $0 }
            let edge = MarkEdgeHandle.segment(frame: 36000, edge: .start)
            let handle = bar.markHandlePoint(for: edge)!
            func handleEvent(_ type: NSEvent.EventType, displacement: CGFloat = 0) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: handle.x + displacement, y: handle.y),
                    modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            }
            bar.mouseDown(with: handleEvent(.leftMouseDown))
            bar.mouseDragged(with: handleEvent(.leftMouseDragged, displacement: 40))
            bar.mouseUp(with: handleEvent(.leftMouseUp, displacement: 40))
            precondition(grabbed == edge &&
                         movedTo.map { $0 > 1500 } == true && committed == true && !bar.isDraggingMark,
                         "Dragging the green handle must edit that boundary and commit on release")
            print("mark-handle-check\tpassed: exact boundary selected, pointer move, release commits")
        }
        for (key, value) in [("timeline-film-height", savedHeight), ("timeline-controls-always", savedControls),
                             ("timeline-film-pinned", savedPinned), savedMode] + savedLens {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        window.orderOut(nil)
        exit(0)
    }

    private static func checkThumbnailCrop() {
        func drawThumbnail(source size: NSSize, output bounds: NSRect, vertical: Bool) -> NSBitmapImageRep {
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.green.setFill()
                rect.fill()
                NSColor.red.setFill()
                if vertical {
                    NSRect(x: 0, y: 0, width: rect.width, height: 4).fill()
                    NSRect(x: 0, y: rect.maxY - 4, width: rect.width, height: 4).fill()
                } else {
                    NSRect(x: 0, y: 0, width: 4, height: rect.height).fill()
                    NSRect(x: rect.maxX - 4, y: 0, width: 4, height: rect.height).fill()
                }
                return true
            }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width),
                                          pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            FilmstripThumbnail.draw(image, geometry: .identity, in: bounds, opacity: 1, cropSides: true)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        let portrait = drawThumbnail(source: NSSize(width: 16, height: 32),
                                     output: NSRect(x: 0, y: 0, width: 32, height: 16), vertical: true)
        precondition([0, 15].allSatisfy {
            guard let color = portrait.colorAt(x: 16, y: $0) else { return false }
            return color.redComponent > 0.75 && color.greenComponent < 0.25
        }, "Thumbnail crop must preserve the top and bottom of a portrait frame")
        let wide = drawThumbnail(source: NSSize(width: 32, height: 16),
                                 output: NSRect(x: 0, y: 0, width: 16, height: 16), vertical: false)
        precondition([0, 15].allSatisfy {
            guard let color = wide.colorAt(x: $0, y: 8) else { return false }
            return color.greenComponent > 0.75 && color.redComponent < 0.25
        }, "Thumbnail crop must still remove the side edges of a wide frame")
    }

    private final class ClickCacheWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState {
            if CommandLine.arguments.contains("--simulate-visible") { return .visible }
            return super.occlusionState
        }
    }

    private static func runClickCache() -> Never {
        setbuf(stdout, nil)
        let arg = CommandLine.arguments.firstIndex(of: "--fixture")!
        let url = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
        let source = try! MediaSource(url: url)
        let index = try! source.buildIndex()
        let decoder = try! VideoDecoder(source: source, index: index)
        let cache = FrameCache(budgetBytes: 32 << 20)
        let target = 500
        try! decoder.seekToKeyframe(near: target)
        cache.insert(try! decoder.nextFrame()!)
        let targetTime = index.seconds(forFrame: target)
        UserDefaults.standard.setVolatileDomain([
            "timeline-click-inertia": true, "timeline-click-preview-frames": false,
            "timeline-film-mode": TimelineFilmMode.lens.rawValue, "timeline-film-height": 48
        ], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = ClickCacheWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true
        window.makeKeyAndOrderFront(nil)
        app.activate()
        func wait(_ seconds: Double, until ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !ready(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        wait(3) { window.occlusionState.contains(.visible) }
        guard window.occlusionState.contains(.visible) else {
            print("film click cache bench requires a visible window")
            exit(EXIT_FAILURE)
        }

        for round in 1...5 {
            let bar = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 130))
            window.contentView!.addSubview(bar)
            bar.setFilmRevealed(true, force: true)
            let loader = FilmstripPreviewLoader(url: url, index: index, rotation: 0, width: 160,
                                                cache: nil, policy: .network, frameCache: cache)
            loader.mayRead = { bar.allowsVisibleFilmstripRequests }
            loader.mayReuse = { bar.allowsReadyFilmstripRequests }
            bar.onFilmstripRequest = { loader.request($0) }
            bar.onReadyFilmstripRequest = { loader.request($0, readyOnly: true) }
            bar.updateTimeline(index: index, duration: 20, paused: true)
            func update(_ frame: Int) {
                bar.update(frameCount: index.frameCount, position: frame, cached: [], loopA: nil, loopB: nil, text: "click cache")
            }
            update(0)
            bar.layoutSubtreeIfNeeded()
            var clicked = false
            bar.onFilmSeek = { _ in clicked = true; update(target) }
            let point = NSPoint(x: 450, y: 10)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            }
            var landed = false
            var arrivedDuringMotion = false
            let start = ProcessInfo.processInfo.systemUptime
            loader.onImage = { image, seconds in
                bar.setFilmstripImage(image, seconds: seconds)
                guard seconds == targetTime else { return }
                landed = true
                arrivedDuringMotion = bar.isAnimatingFilm
                print(String(format: "film-click-cache round=%d ready_ms=%.2f during_motion=%@ decodes=%d",
                             round, (ProcessInfo.processInfo.systemUptime - start) * 1000,
                             arrivedDuringMotion.description, loader.decodeCount))
            }
            let clickCPUStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            bar.mouseDown(with: event(.leftMouseDown))
            bar.mouseUp(with: event(.leftMouseUp))
            let clickCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - clickCPUStart) / 1_000_000
            precondition(clicked, "The film must handle the click")
            let animated = bar.isAnimatingFilm
            print(String(format: "film-click animated=%@ main_cpu_ms=%.2f", animated.description, clickCPU))
            wait(2) { landed }
            precondition(landed && loader.decodeCount == 0)
            if CommandLine.arguments.contains("--expect-before-settle") {
                precondition(animated ? arrivedDuringMotion : ProcessInfo.processInfo.systemUptime - start < 0.25,
                             "A ready thumbnail should arrive before the cold batch settles")
            }
            loader.stop()
            bar.onReadyFilmstripRequest = nil
            bar.onFilmstripRequest = nil
            bar.removeFromSuperview()
        }
        exit(EXIT_SUCCESS)
    }

    private static func runLoader() -> Never {
        setbuf(stdout, nil)
        let arg = CommandLine.arguments.firstIndex(of: "--fixture")!
        let url = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
        let source = try! MediaSource(url: url)
        let fixture = try! source.buildIndex()
        let readyFirst = CommandLine.arguments.contains("--expect-ready-first")
        let playbackCache = FrameCache(budgetBytes: 32 * 1024 * 1024)
        if readyFirst {
            let decoder = try! VideoDecoder(source: source, index: fixture)
            try! decoder.seekToKeyframe(near: 500)
            playbackCache.insert(try! decoder.nextFrame()!)
        }
        let loader = FilmstripPreviewLoader(url: URL(fileURLWithPath: CommandLine.arguments[arg + 1]), index: fixture,
            rotation: 0, width: 320, cache: nil, policy: .network, frameCache: playbackCache)
        var mayRead = !CommandLine.arguments.contains("--expect-resume")
        loader.mayRead = { mayRead }
        var arrivals: [Double] = []
        var sampleTimes: [Double] = []
        let start = ProcessInfo.processInfo.systemUptime
        loader.onImage = { _, seconds in
            sampleTimes.append(seconds)
            arrivals.append(ProcessInfo.processInfo.systemUptime - start)
            print(String(format: "film-image\t%d\t%.3f ms", arrivals.count, arrivals.last! * 1000))
        }
        loader.request([250.0 / 30, 0, 500.0 / 30])
        if CommandLine.arguments.contains("--expect-resume") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            precondition(arrivals.isEmpty, "Foreground work must defer film reads")
            mayRead = true
            loader.resume()
        }
        let deadline = Date().addingTimeInterval(5)
        while arrivals.count < 3, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(arrivals.count == 3)
        if readyFirst {
            precondition(sampleTimes.first == 500.0 / 30, "A reusable last sample must arrive before decoding earlier misses")
            precondition(loader.decodeCount == 2, "The cached playback keyframe must not be decoded again")
            print("ready-first-check\tpassed: playback keyframe first, two decodes for three pictures")
        }
        if CommandLine.arguments.contains("--expect-batch") {
            precondition(arrivals[2] - arrivals[0] < 0.25, "One settled film must not pay a dwell per thumbnail")
        }
        print("film-decodes\t\(loader.decodeCount)")
        loader.stop(); exit(0)
    }

    private static func runPrewarm() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.finishLaunching()
        let arg = CommandLine.arguments.firstIndex(of: "--fixture")!
        let url = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
        let source = try! MediaSource(url: url)
        let index = try! source.buildIndex()
        let saved = ["timeline-film-height", "timeline-film-pinned"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        UserDefaults.standard.set(48, forKey: "timeline-film-height")
        UserDefaults.standard.set(false, forKey: "timeline-film-pinned")
        let window = FilmBenchWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true
        let bar = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 130))
        window.contentView!.addSubview(bar); window.orderFrontRegardless()
        bar.setFilmMode(.lens, save: false)
        bar.updateTimeline(index: index, duration: 20, paused: true, previewSettle: 0)
        bar.update(frameCount: 600, position: 0, cached: [], loopA: nil, loopB: nil, text: "prewarm")
        bar.layoutSubtreeIfNeeded(); bar.displayIfNeeded()
        let times = bar.prewarmFilmstripTimes(center: 0)
        precondition(times.count >= 2 && times.count <= TimelineFilmLayout.maximumCells)
        let ready = times[0]
        let paused = CommandLine.arguments.contains("--paused-prewarm")
        let network = CommandLine.arguments.contains("--network")
        let slowNetwork = CommandLine.arguments.contains("--slow-network")
        var policy: NetworkPolicy = network || slowNetwork ? .network : .local
        if slowNetwork { policy.previewSettle = .leastNonzeroMagnitude }
        let cache = FrameCache(budgetBytes: 32 * 1024 * 1024)
        let decoder = try! VideoDecoder(source: source, index: index)
        try! decoder.seekToKeyframe(near: index.frameNumber(forSeconds: ready))
        cache.insert(try! decoder.nextFrame()!)
        let loader = FilmstripPreviewLoader(url: url, index: index, rotation: 0, width: 320, cache: nil,
                                           policy: policy, frameCache: cache)
        var blocked = true
        loader.mayRead = { !blocked && bar.showsFilmstrip }
        loader.mayPrewarm = { _ in !blocked && !bar.showsFilmstrip }
        var images: [Double] = []
        let started = ProcessInfo.processInfo.systemUptime
        loader.onImage = { image, seconds in
            bar.setFilmstripImage(image, seconds: seconds)
            if !bar.showsFilmstrip { precondition(!bar.needsDisplay, "Prewarming must not invalidate folded film") }
            images.append(seconds)
            print(String(format: "prewarm-image\t%.3f s\t%.3f ms\tshown=%d", seconds,
                         (ProcessInfo.processInfo.systemUptime - started) * 1000, bar.showsFilmstrip ? 1 : 0))
        }
        bar.onFilmstripRequest = { loader.request($0) }
        func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        loader.prewarm(times, paused: paused)
        spin(0.05)
        precondition(images.isEmpty && loader.decodeCount == 0, "Foreground work must defer preparation")
        blocked = false; loader.resume()
        let warmDeadline = Date().addingTimeInterval(3)
        let expected = paused ? Array(times.prefix(slowNetwork ? 2 : times.count)) : [ready]
        while images.count < expected.count, Date() < warmDeadline { spin(0.01) }
        if expected.count < times.count { spin(0.15) }
        precondition(images == expected && loader.decodeCount == expected.count - 1 && !bar.showsFilmstrip,
                     "Preparation should fill paused strips, stop after a slow network sample, and only reuse while playing")
        precondition(!bar.prewarmFilmstripTimes(center: 0).contains(ready), "Prepared picture must enter the view cache")
        bar.setFilmRevealed(true); bar.layoutSubtreeIfNeeded()
        let visibleDeadline = Date().addingTimeInterval(3)
        while images.count < times.count, Date() < visibleDeadline { spin(0.01) }
        precondition(images.count == times.count && images.filter { $0 == ready }.count == 1)
        precondition(loader.decodeCount == times.count - 1, "Reveal must reuse the prepared picture and decode only misses")
        print("prewarm-check\tpassed: \(expected.count)/\(times.count) pictures before reveal, foreground gate and no hidden redraw")
        loader.stop(); window.orderOut(nil)
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        exit(0)
    }

    private static func runKeyframeCost() -> Never {
        let arg = CommandLine.arguments.firstIndex(of: "--fixture")!
        let url = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
        DispatchQueue.global(qos: .utility).async {
            let source = try! MediaSource(url: url)
            let index = try! source.buildIndex()
            let keys = try! VideoDecoder(source: MediaSource(url: url), index: index)
            let exact = try! VideoDecoder(source: MediaSource(url: url), index: index)
            for round in 1...5 {
                for keyOnly in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let decoder = keyOnly ? keys : exact
                    let start = ProcessInfo.processInfo.systemUptime
                    for target in [125, 375, 575] {
                        if keyOnly { try! decoder.seekToKeyframe(near: target) }
                        else { try! decoder.seek(toFrame: target) }
                        precondition(try! decoder.nextFrame() != nil)
                    }
                    print(String(format: "decode-cost\t%@\t%d\t%.3f ms", keyOnly ? "keyframe" : "exact", round,
                                 (ProcessInfo.processInfo.systemUptime - start) * 1000))
                }
            }
            exit(0)
        }
        RunLoop.main.run()
        fatalError("Unreachable")
    }
}
