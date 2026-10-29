import AppKit
import FrameScrubCore

StartupTrace.mark("main")

if CommandLine.arguments.contains("--bench-timeline") { MainActor.assumeIsolated { SeekBarBench.run() } }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
