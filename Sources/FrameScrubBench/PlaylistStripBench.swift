import AppKit
import Filmstrip
import FilmstripModel
import Foundation
import FrameScrubCore
import HomeChrome
import HomeScreenModel

/// `FrameScrubBench playlist-strip [--rows N] [--rounds N]` (docs/bench/2026-10-27-playlist-strip.md): the main thread's
/// work of the playlist strip's surface — `FilmstripRowsView` in a real window on screen, 360 × 900 pt, its rows'
/// text from `PlaylistRowFacts`, the scroll from `FilmstripScroll`, a card of `NSTextField`s as the app builds it —
/// over N rows (default 500; a third with facts, three aspects). Each action ends with a Core Animation flush, so the
/// commit is counted. Per round: the strip shown (first time in round 1, again after); 2 000 scroll events of a sweep
/// (p50 / p99 / max); 100 steps of the browsed row with the card rebuilt; 20 filter changes N → 40 → N. The app's glue
/// (`PlaylistStripView`: off-main reads, timers) is not in it: it lives in the app target.
enum PlaylistStripBench {
    static func main(_ arguments: [String]) -> Never {
        var count = 500, rounds = 5
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--rows", let n = args.popFirst().flatMap(Int.init), n > 0 { count = n; continue }
            if arg == "--rounds", let n = args.popFirst().flatMap(Int.init), n > 0 { rounds = n; continue }
            fail("playlist-strip: unknown argument \(arg)")
        }
        MainActor.assumeIsolated { run(count: count, rounds: rounds) }
        exit(0)
    }

    private static let aspectCycle: [Double?] = [16.0 / 9, 4.0 / 3, 2.39]

    @MainActor private static func run(count: Int, rounds: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        window.makeKeyAndOrderFront(nil)
        app.activate()
        spin(300)

        let titles = (0..<count).map { "Video number \($0) with a fairly long name.mkv" }
        let lines = (0..<count).map { i -> PlaylistRowFacts in
            let facts = i % 3 == 0 ? FileFacts(width: 3840, height: 2160, duration: Double(600 + i), codec: "HEVC", fps: 25) : nil
            return PlaylistRowFacts(facts: facts, resume: i % 4 == 0 ? ResumeEntry(position: 100) : nil,
                                    size: 1_000_000_000 + Int64(i), date: Date())
        }
        let aspects = (0..<count).map { $0 % 3 == 0 ? aspectCycle[$0 / 3 % 3] : nil }

        print("action\tround\tp50 ms\tp99 ms\tmax ms\tn")
        for round in 1...rounds {
            var strip: FilmstripRowsView!
            var card: NSStackView!
            var scroll = FilmstripScroll()
            var browsed = count / 2
            func layout(_ n: Int) -> FilmstripRows {
                FilmstripRows(itemCount: n, aspects: Array(aspects.prefix(n)), length: 900, width: 360, rowPicture: 96,
                              currentPicture: 344, cardHeight: 90)
            }
            func fillRows(_ n: Int) {
                for item in strip.visibleItems where item < n {
                    strip.setRow(item, title: titles[item], detail: lines[item].detail, progress: lines[item].progress)
                }
            }
            func fillCard() {
                for view in card.arrangedSubviews { view.removeFromSuperview() }
                for (i, line) in ([titles[browsed]] + lines[browsed].card).enumerated() {
                    let field = NSTextField(wrappingLabelWithString: line)
                    field.maximumNumberOfLines = i == 0 ? 2 : 1
                    field.font = i == 0 ? Chrome.Text.font(.label, weight: .semibold) : Chrome.Text.digits(.small)
                    card.addArrangedSubview(field)
                }
            }

            // Shown: made and laid out (round 1), or unhidden and laid out again (later rounds measure "again").
            let shown = measure {
                strip = FilmstripRowsView(frame: NSRect(x: 0, y: 0, width: 360, height: 900))
                card = NSStackView()
                card.orientation = .vertical
                card.alignment = .leading
                strip.card = card
                window.contentView?.addSubview(strip)
                strip.layout = layout(count)
                fillCard()
                strip.show(offset: strip.layout.centre(of: browsed), current: browsed, expansion: 1, animated: false)
                fillRows(count)
            }
            spin(100)
            let again = measure {
                strip.isHidden = true
                strip.isHidden = false
                strip.show(offset: strip.layout.centre(of: browsed), current: browsed, expansion: 0.999, animated: false)
                fillRows(count)
            }
            report("show strip (first)", round, [shown])
            report("show strip (again)", round, [again])

            // A sweep: 2 000 trackpad events, 6 pt each, down and back, as one gesture.
            var times: [Double] = []
            for i in 0..<2000 {
                let delta = i < 1000 ? -6.0 : 6.0
                times.append(measure {
                    let outcome = scroll.event(fingerDelta: delta, crossDelta: 0, phase: i == 0 ? .began : .changed,
                                               momentum: [], layout: strip.layout, current: browsed, now: Double(i) / 120)
                    if let item = outcome.item { browsed = item }
                    strip.show(offset: scroll.offset ?? strip.layout.centre(of: browsed), current: browsed,
                               expansion: 0, animated: false)
                    fillRows(count)
                })
            }
            scroll.settle()
            report("scroll event", round, times)

            // The browsed row moves by one (↓ in the filter): the card rebuilt, the strip moved, animated.
            times = []
            for i in 0..<100 {
                times.append(measure {
                    browsed = min(count - 1, max(0, browsed + (i < 50 ? 1 : -1)))
                    fillCard()
                    strip.show(offset: strip.layout.centre(of: browsed), current: browsed, expansion: 1, animated: true)
                    fillRows(count)
                })
            }
            report("browse by one", round, times)

            // The filter: N rows → 40 → N (a new layout, the rows remapped, the window filled again).
            times = []
            for i in 0..<20 {
                let n = i % 2 == 0 ? min(40, count) : count
                times.append(measure {
                    let map = Dictionary(uniqueKeysWithValues: (0..<min(n, count)).map { ($0, $0) })
                    strip.remap(map)
                    strip.layout = layout(n)
                    browsed = min(browsed, n - 1)
                    strip.show(offset: strip.layout.centre(of: browsed), current: browsed, expansion: 1, animated: false)
                    fillRows(n)
                })
            }
            report("filter change", round, times)
            strip.removeFromSuperview()
            spin(100)
        }
        // At rest: nothing of the strip's runs.
        let rest = measure { spin(1000) }
        print(String(format: "rest (1 s, run loop only)\t-\t%.2f\t-\t-\t1", rest))
    }

    /// Main-thread CPU ms of `body` and the Core Animation commit it caused.
    @MainActor private static func measure(_ body: () -> Void) -> Double {
        let t0 = threadCPU()
        body()
        CATransaction.flush()
        return threadCPU() - t0
    }

    private static func report(_ action: String, _ round: Int, _ times: [Double]) {
        let sorted = times.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        print(String(format: "%@\t%d\t%.2f\t%.2f\t%.2f\t%d", action, round, at(0.5), at(0.99), sorted.last ?? 0, times.count))
    }

    @MainActor private static func spin(_ ms: Int) {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: min(end, Date().addingTimeInterval(0.05)),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }
}
