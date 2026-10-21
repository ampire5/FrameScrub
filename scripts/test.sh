#!/usr/bin/env bash
# Runs the tests as x86_64 against FrameScrub's own FFmpeg (lts/macos26). Arguments go to the testing library
# (`--filter`, `--skip`, `--no-parallel`, as for `swift test`). Needs the fixtures (scripts/make-fixtures.sh, which uses
# Homebrew's ffmpeg tool, or the `fixtures` artifact of a CI run).
# On Apple Silicon the build is native (a cross build for x86_64) and only the test bundle runs under Rosetta, through
# SwiftPM's own swift-testing helper: `swift test` itself under Rosetta spent minutes compiling the manifests again.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/deps-env.sh
if [[ $(uname -m) == x86_64 ]]; then
    swift test --triple "$LTS_TRIPLE" "$@"
    exit
fi
swift build --build-tests --triple "$LTS_TRIPLE"
helper=$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper
bundle=$(swift build --triple "$LTS_TRIPLE" --show-bin-path)/FrameScrubPackageTests.xctest/Contents/MacOS/FrameScrubPackageTests
if [[ -x "$helper" && -f "$bundle" ]]; then
    arch -x86_64 "$helper" --test-bundle-path "$bundle" --testing-library swift-testing "$@"
else
    arch -x86_64 swift test --skip-build --triple "$LTS_TRIPLE" "$@"
fi
