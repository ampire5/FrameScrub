import AppKit
import FrameScrubCore

StartupTrace.mark("main")

if CommandLine.arguments.contains("--bench-timeline") { MainActor.assumeIsolated { SeekBarBench.run() } }
if CommandLine.arguments.contains("--bench-home-updates") { MainActor.assumeIsolated { HomeUpdatesBench.run() } }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if CommandLine.arguments.contains("--bench-close-window") { MainActor.assumeIsolated { WindowCloseBench.install() } }
app.run()
