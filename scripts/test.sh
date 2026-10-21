#!/usr/bin/env bash
# Runs the tests as x86_64 against FrameScrub's own FFmpeg (lts/macos26). Arguments go to `swift test`.
# On Apple Silicon the build is native (a cross build for x86_64) and only the tests run under Rosetta: the compiler
# under Rosetta took most of CI's time. Needs the fixtures (scripts/make-fixtures.sh, which uses Homebrew's ffmpeg
# tool, or the `fixtures` artifact of a CI run).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/deps-env.sh
if [[ $(uname -m) == x86_64 ]]; then
    swift test --triple "$LTS_TRIPLE" "$@"
else
    swift build --build-tests --triple "$LTS_TRIPLE"
    arch -x86_64 swift test --skip-build --triple "$LTS_TRIPLE" "$@"
fi
