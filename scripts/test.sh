#!/usr/bin/env bash
# Runs the tests as x86_64 against FrameScrub's own FFmpeg (lts/macos26). Arguments go to `swift test`.
# Needs the fixtures (scripts/make-fixtures.sh, which uses Homebrew's ffmpeg tool).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == x86_64 ]] || exec arch -x86_64 /bin/bash "$0" "$@"
. scripts/deps-env.sh
swift test "$@"
