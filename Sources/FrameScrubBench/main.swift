import Foundation

/// `FrameScrubBench <bench> [arguments]`: benches of FrameScrub's windows, written down in docs/bench.
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "filters-pipeline": ArtifactFilterPipelineBench.main()
case "filter-order": ArtifactFilterOrderBench.main(Array(arguments.dropFirst()))
case "filter-images": ArtifactFilterBench.images(Array(arguments.dropFirst()))
case "filter-fixtures": ArtifactFilterBench.fixtures(Array(arguments.dropFirst()))
case "filters": ArtifactFilterBench.main()
case "settings": SettingsBench.main(Array(arguments.dropFirst()))
case "playlist-strip": PlaylistStripBench.main(Array(arguments.dropFirst()))
case "slots": SlotsBench.main(Array(arguments.dropFirst()))
default: fail("usage: FrameScrubBench settings [--rounds N] [--settle MS] [--shots DIR] [--start ID]\n"
            + "       FrameScrubBench playlist-strip [--rows N] [--rounds N]\n"
            + "       FrameScrubBench slots [--rounds N]")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
