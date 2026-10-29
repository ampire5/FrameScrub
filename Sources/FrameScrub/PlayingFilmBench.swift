import AppKit
import FrameScrubCore

/// Actual PlayerCore + film decoder: uninterrupted initial playback, then cached sample-wheel navigation.
@MainActor enum PlayingFilmBench {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.finishLaunching()
        let arg = CommandLine.arguments.firstIndex(of: "--fixture")!
        let url = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
        let savedHeight = UserDefaults.standard.object(forKey: "timeline-film-height")
        UserDefaults.standard.set(48, forKey: "timeline-film-height")
        let window = FilmBenchWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true
        let bar = SeekBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 124))
        window.contentView!.addSubview(bar)
        window.orderFrontRegardless()
        bar.setFilmMode(.lens, save: false)
        bar.setFilmRevealed(true)
        var config = Config(); config.autoplay = true; config.cacheSizeMiB = 400
        let core = PlayerCore(config: config, enableAudio: false)
        let observer = FilmBenchObserver()
        core.delegate = observer
        try! core.open(url)
        let loader = FilmstripPreviewLoader(url: url, index: core.index!, rotation: 0, width: 320,
            cache: core.readCache, policy: .network)
        loader.mayRead = {
            guard bar.showsFilmstrip, !bar.isThumbnailInteraction else { return false }
            if core.isPaused { return true }
            let next = min(core.frameCount - 1, core.position + core.direction)
            return core.cache.contains(core.position) && core.cache.contains(max(0, next))
        }
        var images: [Double] = []
        let start = ProcessInfo.processInfo.systemUptime
        loader.onImage = { image, seconds in
            precondition(!core.isPaused, "Fixture must fill while still playing")
            bar.setFilmstripImage(image, seconds: seconds)
            images.append(seconds)
            print(String(format: "playing-film-image\t%.3f s\t%.1f ms", seconds,
                (ProcessInfo.processInfo.systemUptime - start) * 1000))
        }
        bar.onFilmstripRequest = { loader.request($0) }
        func refresh() {
            bar.updateTimeline(index: core.index, duration: core.durationSeconds, paused: core.isPaused,
                uprightSize: CGSize(width: 1920, height: 1080), previewSettle: 0.25)
            bar.update(frameCount: core.frameCount, position: core.position, cached: [], loopA: nil, loopB: nil, text: "playing bench")
            loader.resume()
        }
        observer.onChange = { refresh() }
        core.onIndexReady = { loader.updateIndex($0); refresh() }
        refresh()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            core.tick()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let expected = [0.0, 250.0 / 30, 500.0 / 30]
        precondition(!core.isPaused && core.position > 0, "Playback must advance without pausing")
        precondition(expected.allSatisfy { time in images.contains { abs($0 - time) < 1e-9 } },
            "All three visible fixture keyframes must arrive without pause or pointer input")
        precondition(Set(images).count == images.count, "Playing must not repeatedly replace the same thumbnail")
        let cached = images.count
        for (magnification, area) in [(1.0, 0.08), (3.8, 0.75)] {
            bar.configureLens(seconds: 1, focus: area, crop: 0.7, magnification: magnification, density: 2.75, save: false)
            let until = Date().addingTimeInterval(0.3)
            while Date() < until { core.tick(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        precondition(images.count == cached, "Magnification and area must reuse the existing thumbnail cache")
        print("lens-cache-check\tpassed: strength and area changed, no new thumbnail delivery")
        bar.modeControl.onSettings?()
        precondition(bar.isInteracting && !bar.isThumbnailInteraction, "Settings must hold reveal without blocking live preview")
        bar.resetFilmstrip()
        let refill = Date().addingTimeInterval(1)
        while images.count < cached + expected.count, Date() < refill {
            core.tick(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(images.count > cached, "The film must fill while its settings dropdown remains open")
        bar.modeControl.onSettings?()
        print("lens-live-preview-check\tpassed: open dropdown allows thumbnail delivery")
        let position = core.position
        bar.setFilmMode(.overview, save: false)
        bar.setFilmMode(.segment, save: false)
        bar.setFilmMode(.lens, save: false)
        precondition(core.position == position && !core.isPaused, "Changing timeline view must not seek or pause")
        let pauseDeadline = Date().addingTimeInterval(0.2)
        while Date() < pauseDeadline { core.tick(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        bar.setFilmMode(.segment, save: false)
        bar.onFilmScrubBegan = { core.pause() }
        bar.onFilmSeek = { time in core.seek(toFrame: core.index!.frameNumber(forSeconds: time)) }
        let before = core.positionSeconds, imageCount = images.count
        let drawn = TimelineFilmLayout(width: 876, height: 48, aspect: 16.0 / 9, duration: core.durationSeconds,
            center: before, secondsPerThumbnail: 1, focusFraction: 0.75, cropStrength: 0.7,
            mode: .segment, magnification: 3.8).cells.compactMap(\.seconds)
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0)!
        wheel.location = CGPoint(x: 450, y: NSScreen.screens[0].frame.height - 50)
        bar.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        precondition(core.isPaused && core.positionSeconds < before)
        precondition(drawn.contains { abs($0 - core.positionSeconds) < 1.0 / 30 }, "Wheel must choose a sample already on the film")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(!bar.isAnimatingFilm, "Wheel motion must finish without an idle timer")
        precondition(images.count == imageCount, "Wheel browsing existing pictures must not regenerate thumbnails")
        print("sample-wheel-check\tpassed: displayed sample selected, paused, cached, transition stopped")
        print("playing-film-check\tpassed: playing, advancing samples, all keyframes, no input, 250 ms batch dwell")
        loader.stop(); core.close(); window.orderOut(nil)
        if let savedHeight { UserDefaults.standard.set(savedHeight, forKey: "timeline-film-height") }
        else { UserDefaults.standard.removeObject(forKey: "timeline-film-height") }
        exit(0)
    }
}

/// A controlled visible surface for scheduler tests even when the desktop is covered by the calling app.
private final class FilmBenchWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

private final class FilmBenchObserver: PlayerCoreDelegate {
    var onChange: (() -> Void)?
    func player(_ player: PlayerCore, display frame: DecodedFrame) { onChange?() }
    func playerStateDidChange(_ player: PlayerCore) { onChange?() }
    func player(_ player: PlayerCore, showOSD text: String) {}
}
