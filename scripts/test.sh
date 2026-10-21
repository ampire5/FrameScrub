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
    # The bundle finds swift-testing where swift test would point it; DYLD_* goes through arch's -e, as /usr/bin/arch
    # drops it from its own environment.
    platform=$(xcrun --show-sdk-platform-path)/Developer
    arch -x86_64 -e DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" -e DYLD_LIBRARY_PATH="$platform/usr/lib" \
        "$helper" --test-bundle-path "$bundle" --testing-library swift-testing "$@"
else
    arch -x86_64 swift test --skip-build --triple "$LTS_TRIPLE" "$@"
fi
