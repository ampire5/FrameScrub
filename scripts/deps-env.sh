# Sourced by the build scripts from the package root (lts/macos26, LTS_POLICY.md). The LTS app is x86_64: on Apple
# Silicon the scripts run themselves again under Rosetta, so SwiftPM builds and tests x86_64. SwiftPM's CFFmpeg module
# (Package.swift, unchanged) finds FrameScrub's own static FFmpeg ahead of Homebrew's: scripts/deps.sh downloads the
# prebuilt one (or builds it, scripts/build-deps.sh) the first time.
export FRAMESCRUB_DEPS="${FRAMESCRUB_DEPS:-$PWD/.deps/x86_64}"
export PKG_CONFIG_PATH="$FRAMESCRUB_DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
scripts/deps.sh fetch
