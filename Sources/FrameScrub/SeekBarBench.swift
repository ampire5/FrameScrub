import AppKit
import Darwin
import FrameScrubCore
import QuartzCore

/// A bench of the actual app view, not a duplicate UI in the bench target.
@MainActor enum SeekBarBench {
    static func run() -> Never {
        if CommandLine.arguments.contains("--bench-playing-film") { PlayingFilmBench.run() }
        if CommandLine.arguments.contains("--bench-film-loader") { runLoader() }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.finishLaunching()
        let thumbnailBox = NSRect(x: 10, y: 20, width: 160, height: 90)
        let portrait = FilmstripThumbnailView.fittedRect(aspect: 9.0 / 16, in: thumbnailBox)
        precondition(abs(portrait.width / portrait.height - 9.0 / 16) < 0.00001 && portrait.height == 90)
        let wide = FilmstripThumbnailView.fittedRect(aspect: 2.35, in: thumbnailBox)
        precondition(abs(wide.width / wide.height - 2.35) < 0.00001 && wide.width == 160)
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
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.darkGray.cgColor
        window.makeKeyAndOrderFront(nil)
        app.activate()
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
                bar = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 124))
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
                narrow.append(measure { bar.setFrameSize(NSSize(width: 320, height: 124)); refresh(bar, step.isMultiple(of: 2) ? 0 : 71999) })
                returns.append(measure { bar.setFrameSize(NSSize(width: 900, height: 124)); refresh(bar, 24000) })
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
                bar.setFrameSize(NSSize(width: width, height: 124)); refresh(bar, position)
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
                bar.setFrameSize(NSSize(width: 900, height: 124))
                bar.resetFilmstrip()
                bar.updateTimeline(index: fixture, duration: 20, paused: true, uprightSize: size)
                bar.update(frameCount: 600, position: 300, cached: [], loopA: nil, loopB: nil, text: "aspect")
                bar.layoutSubtreeIfNeeded()
                for time in [0.0, 250.0 / 30, 500.0 / 30] {
                    bar.setFilmstripImage(cg, seconds: time)
                    precondition(!bar.needsDisplay, "A delivered image must paint without a new input event")
                }
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 450, y: 50), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                bar.mouseMoved(with: event)
                precondition(!bar.filmHover.isHidden && bar.filmHover.frame.height > 48, "Hover must enlarge the cached frame")
                precondition(bar.hitTest(NSPoint(x: 450, y: 50)) === bar, "Hover must pass through seek input")
                if let arg = CommandLine.arguments.firstIndex(of: "--shots") {
                    let directory = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
                    let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                    bar.cacheDisplay(in: bar.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(aspect < 1 ? "portrait-hover.png" : "wide-hover.png"))
                }
                bar.mouseExited(with: event)
                precondition(bar.filmHover.isHidden, "Hover must disappear on exit")
            }
            print("aspect-hover-checks\tpassed: portrait, wide, cached enlargement, seek passthrough, exit")
            bar.setFilmRevealed(false)
            bar.setPlaybackControlsVisible(true)
            precondition(!bar.showsFilmstrip, "Playback reveal must not open film")
            bar.updateFilmPointer(NSPoint(x: 450, y: 50))
            precondition(bar.showsFilmstrip, "Entering the film zone must open it")
            bar.updateFilmPointer(nil); spin(0.6)
            precondition(!bar.showsFilmstrip, "Film must fold promptly after leaving")
            bar.toggleFilmPin(); bar.updateFilmPointer(nil); spin(0.6)
            precondition(bar.showsFilmstrip && bar.filmPinned, "Pinned film must stay without mouse activity")
            bar.toggleFilmPin()
            bar.setFilmRevealed(true)
            var seeks: [Double] = []
            bar.onFilmSeek = { seeks.append($0) }
            func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            }
            bar.mouseDown(with: mouse(.leftMouseDown, 600))
            bar.mouseDragged(with: mouse(.leftMouseDragged, 602))
            bar.mouseUp(with: mouse(.leftMouseUp, 602))
            precondition(seeks.count == 1 && seeks[0] > 10, "Click jitter must choose the clicked cell, not start a centre drag")
            bar.mouseMoved(with: mouse(.mouseMoved, 600))
            let upperPoint = NSPoint(x: bar.filmHover.frame.midX, y: bar.filmHover.frame.maxY - 1)
            precondition(!bar.filmHover.isHidden && bar.filmHover.frame.contains(upperPoint))
            precondition(bar.hitTest(upperPoint) === bar, "The visible enlargement above the cells must receive film input")
            seeks = []
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let upper = NSEvent.mouseEvent(with: type, location: upperPoint, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                if type == .leftMouseDown { bar.mouseDown(with: upper) } else { bar.mouseUp(with: upper) }
            }
            precondition(seeks.count == 1 && seeks[0] > 10, "Clicking an enlarged frame's upper part must seek that frame")
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
                cg.location = CGPoint(x: 450, y: NSScreen.screens[0].frame.height - 50)
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
            precondition(!bar.filmHover.isHidden && abs(bar.filmHover.seconds - scaled.cell(at: 150)!.seconds!) < 0.00001,
                "Option-scroll must refresh the enlarged picture's selected sample without pointer movement")
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
            bar.updateFilmPointer(NSPoint(x: 450, y: 50))
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
            for density in [1.0, 2.75, 4] {
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
            if let arg = CommandLine.arguments.firstIndex(of: "--shots") {
                let bitmap = controls.view.bitmapImageRepForCachingDisplay(in: controls.view.bounds)!
                controls.view.cacheDisplay(in: controls.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[arg + 1]).appendingPathComponent("lens-controls.png"))
            }
            controls.view.removeFromSuperview()
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
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: edge, y: 50), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                bar.mouseMoved(with: event)
                precondition(!bar.filmHover.isHidden, "An edge picture must still reveal its full preview")
                for rect in bar.transport.occupiedRects + [bar.modeControl.frame] {
                    precondition(!bar.filmHover.frame.intersects(rect), "Enlarged previews must avoid visible controls")
                }
                for button in transportButtons(bar.transport) {
                    let local = bar.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    precondition(bar.hitTest(local) === button, "A thumbnail must never take a transport button's hit")
                }
                let button = transportButtons(bar.transport).first { $0.toolTip == (edge < 450 ? "Back 10 seconds" : "Full screen") }!
                let local = bar.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                let enter = NSEvent.mouseEvent(with: .mouseMoved, location: bar.convert(local, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                bar.mouseMoved(with: enter)
                precondition(bar.filmHover.isHidden, "Moving directly from the film into a control must dismiss the hover")
            }
            print("edge-controls-checks\tpassed: no overlap, all buttons hit, direct transition clears hover")
            let tuning = bar.modeControl.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Lens settings" }!
            for round in 1...10 {
                bar.setFilmRevealed(true); bar.setPlaybackControlsVisible(true); bar.layoutSubtreeIfNeeded()
                let cost = measure { tuning.performClick(nil) }
                precondition(bar.isInteracting, "The on-film tuning button must open the live controls")
                report("lens-dropdown-open", round, [cost])
                tuning.performClick(nil)
                let deadline = Date().addingTimeInterval(2)
                while bar.isInteracting, Date() < deadline { spin(0.02) }
                precondition(!bar.isInteracting, "Closing the dropdown must release the timeline")
            }
            print("stable-view-checks\tpassed: on-film selection, no seek, mode capsule holds reveal, motion shots")
        }
        for (key, value) in [("timeline-film-height", savedHeight), ("timeline-controls-always", savedControls),
                             ("timeline-film-pinned", savedPinned), savedMode] + savedLens {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        window.orderOut(nil)
        exit(0)
    }

    private static func runLoader() -> Never {
        let arg = CommandLine.arguments.firstIndex(of: "--fixture")!
        let fixture = FrameIndex(pts: (0..<600).map(Int64.init), keyframePTS: [0, 250, 500], timeBase: 1.0 / 30)
        let loader = FilmstripPreviewLoader(url: URL(fileURLWithPath: CommandLine.arguments[arg + 1]), index: fixture,
            rotation: 0, width: 320, cache: nil, policy: .network)
        var mayRead = !CommandLine.arguments.contains("--expect-resume")
        loader.mayRead = { mayRead }
        var arrivals: [Double] = []
        let start = ProcessInfo.processInfo.systemUptime
        loader.onImage = { _, _ in
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
        if CommandLine.arguments.contains("--expect-batch") {
            precondition(arrivals[2] - arrivals[0] < 0.25, "One settled film must not pay a dwell per thumbnail")
        }
        loader.stop(); exit(0)
    }
}
