# Sourced by the build scripts from the package root. FrameScrub builds for $DEPS_ARCH ($DEPS_TRIPLE): the Mac's own
# architecture unless set; `DEPS_ARCH=x86_64` on Apple Silicon is a cross build for Intel Macs on macOS 26
# (scripts/test.sh then runs the tests under Rosetta). SwiftPM's CFFmpeg module (Package.swift, unchanged) finds
# FrameScrub's own static FFmpeg ahead of Homebrew's: scripts/deps.sh downloads the prebuilt one (or builds it, scripts/build-deps.sh) the first time.
DEPS_ARCH=${DEPS_ARCH:-$(uname -m)}
export DEPS_ARCH DEPS_TRIPLE=$DEPS_ARCH-apple-macosx26.0
export FRAMESCRUB_DEPS="${FRAMESCRUB_DEPS:-$PWD/.deps/$DEPS_ARCH}"
export PKG_CONFIG_PATH="$FRAMESCRUB_DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
scripts/deps.sh fetch
