#!/usr/bin/env bash
# Runs the tests for $DEPS_ARCH (scripts/deps-env.sh) against FrameScrub's own FFmpeg. Arguments go to the testing
# library (`--filter`, `--skip`, `--no-parallel`, as for `swift test`). Needs the fixtures (scripts/make-fixtures.sh, which uses
# Homebrew's ffmpeg tool, or the `fixtures` artifact of a CI run).
# On screen: build errors, the failing expectations as they happen and a summary of the failed tests; the whole
# output is in .build/test.log (scripts/test-report.sh). TEST_VERBOSE=1 shows everything, as CI does.
# For the Mac's own architecture, `swift test`. For x86_64 on Apple Silicon (`DEPS_ARCH=x86_64`, CI's x86_64 job) the
# build is native (a cross build) and only the test bundle runs under Rosetta, through SwiftPM's own swift-testing helper: `swift test`
# itself under Rosetta spent minutes compiling the manifests again.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/deps-env.sh
. scripts/test-report.sh
if [[ $(uname -m) == "$DEPS_ARCH" ]]; then
    report_tests FrameScrub swift test --triple "$DEPS_TRIPLE" "$@"
    exit
fi
report_build "FrameScrub (build)" swift build --build-tests --triple "$DEPS_TRIPLE"
helper=$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper
bundle=$(swift build --triple "$DEPS_TRIPLE" --show-bin-path)/FrameScrubPackageTests.xctest/Contents/MacOS/FrameScrubPackageTests
if [[ -x "$helper" && -f "$bundle" ]]; then
    # The bundle finds swift-testing where swift test would point it; DYLD_* goes through arch's -e, as /usr/bin/arch
    # drops it from its own environment.
    platform=$(xcrun --show-sdk-platform-path)/Developer
    report_tests FrameScrub arch "-$DEPS_ARCH" -e DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" \
        -e DYLD_LIBRARY_PATH="$platform/usr/lib" "$helper" --test-bundle-path "$bundle" --testing-library swift-testing "$@"
else
    report_tests FrameScrub arch "-$DEPS_ARCH" swift test --skip-build --triple "$DEPS_TRIPLE" "$@"
fi
