import Foundation

/// `FrameScrubBench <bench> [arguments]`: benches of FrameScrub's windows, written down in docs/bench.
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "settings": SettingsBench.main(Array(arguments.dropFirst()))
default: fail("usage: FrameScrubBench settings [--rounds N] [--settle MS] [--shots DIR] [--start ID]")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
