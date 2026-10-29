import AppKit
import Filmstrip
import FilmstripModel
import Foundation
import FrameScrubCore
import SlotChrome
import WebKit

/// `FrameScrubBench slots [--rounds N]` (docs/bench/2026-10-28-slot-capsule.md): the main thread's work of a slot's
/// capsule and tabs — `SlotCapsuleView` over three tab views in a real window on screen, 400 × 900 pt: the playlist
/// strip (`FilmstripRowsView`, 500 rows) and two blank pages (`WKWebView`, about:blank). A tab's view is shown and the
/// others hidden, as `SlotView.setViews` does. Each action ends with a Core Animation flush, so the commit is counted.
/// Per round: the capsule shown and hidden 50 times; the first visit of each page tab (made, loaded, shown) and 20
/// returns between the three tabs; the filter field opened and closed 20 times. `SlotView` and `SlotsController` live
/// in the app target: their part (a dictionary walk, a few properties) is not in it.
enum SlotsBench {
    static func main(_ arguments: [String]) -> Never {
        var rounds = 5
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--rounds", let n = args.popFirst().flatMap(Int.init), n > 0 { rounds = n; continue }
            fail("slots: unknown argument \(arg)")
        }
        MainActor.assumeIsolated { run(rounds: rounds) }
        exit(0)
    }

    @MainActor private static func run(rounds: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        window.autorecalculatesKeyViewLoop = true
        window.makeKeyAndOrderFront(nil)
        app.activate()
        spin(300)
        let host = window.contentView!

        print("action\tround\tp50 ms\tp99 ms\tmax ms\tn")
        for round in 1...rounds {
            let panel = NSView(frame: host.bounds)
            panel.autoresizingMask = [.width, .height]
            host.addSubview(panel)
            let strip = FilmstripRowsView(frame: panel.bounds)
            strip.autoresizingMask = [.width, .height]
            strip.layout = FilmstripRows(itemCount: 500, aspects: Array(repeating: nil, count: 500), length: 900,
                                             width: 400, rowPicture: 220, currentPicture: 388, cardHeight: 60,
                                             captionHeight: FilmstripRowsView.captionHeight,
                                             currentCaptionHeight: FilmstripRowsView.currentCaptionHeight)
            panel.addSubview(strip)
            strip.show(offset: strip.layout.centre(of: 250), current: 250, expansion: 1, animated: false)
            let capsule = SlotCapsuleView(edge: .right)
            capsule.frame = CGRect(x: 6, y: 900 - 6 - SlotCapsuleView.height, width: 388, height: SlotCapsuleView.height)
            capsule.autoresizingMask = [.minYMargin, .width]
            panel.addSubview(capsule)
            var views: [String: NSView] = ["playlist": strip]
            func tabs(_ shown: String) -> [SlotTab] {
                [SlotTab(id: "playlist", symbol: "play.rectangle", letter: nil, name: "Playlist", selected: shown == "playlist"),
                 SlotTab(id: "plugin:A", symbol: nil, letter: "A", name: "A", selected: shown == "plugin:A"),
                 SlotTab(id: "plugin:B", symbol: nil, letter: "B", name: "B", selected: shown == "plugin:B")]
            }
            func show(_ id: String) {
                for (key, view) in views {
                    let visible = key == id
                    if view.isHidden == visible { view.isHidden = !visible }
                    view.setAccessibilityElement(visible)
                }
                capsule.tabs = tabs(id)
                capsule.tools = id == "playlist"
                    ? [SlotTool(id: "filter", symbol: "magnifyingglass", tip: "Filter (⌘F)", action: {}),
                       SlotTool(id: "order", symbol: "arrow.up.arrow.down", tip: "Order", menu: { NSMenu() })]
                    : []
            }
            show("playlist")
            capsule.setVisible(true, animated: false)
            spin(100)

            var times: [Double] = []
            for i in 0..<100 { times.append(measure { capsule.setVisible(i % 2 == 1, animated: false) }) }
            report("capsule shown / hidden", round, times)
            capsule.setVisible(true, animated: false)

            times = []
            for id in ["plugin:A", "plugin:B"] {
                times.append(measure {
                    let page = WKWebView(frame: panel.bounds)
                    page.autoresizingMask = [.width, .height]
                    page.setValue(false, forKey: "drawsBackground")
                    panel.addSubview(page, positioned: .below, relativeTo: capsule)
                    page.load(URLRequest(url: URL(string: "about:blank")!))
                    views[id] = page
                    show(id)
                })
                spin(200)   // the page's load runs between the visits, as it would
            }
            report("tab, first visit (page made)", round, times)

            times = []
            let cycle = ["playlist", "plugin:A", "plugin:B"]
            for i in 0..<60 { times.append(measure { show(cycle[i % 3]) }) }
            report("tab, return", round, times)
            show("playlist")

            times = []
            for _ in 0..<20 {
                times.append(measure { capsule.beginFilter(text: "") })
                times.append(measure { capsule.endFilter() })
            }
            report("filter field open / close", round, times)

            panel.removeFromSuperview()
            spin(100)
        }
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
