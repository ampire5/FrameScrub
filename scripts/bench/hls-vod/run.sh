#!/usr/bin/env bash
# Run from any directory: bash scripts/bench/hls-vod/run.sh [URL [frames]]
set -euo pipefail
cd "$(dirname "$0")/../../.."
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/framescrub-hls-probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT

ffmpeg_prefix=$(brew --prefix ffmpeg)
ffmpeg_lib="$ffmpeg_prefix/lib"
target_macos=$(sw_vers -productVersion)
core=Sources/FrameScrubCore
bitpack=Sources/CNV12Bitpack
xcrun clang -mmacosx-version-min="$target_macos" -O2 -I "$bitpack/include" -c "$bitpack/Bitpack.c" -o "$probe_dir/Bitpack.o"
xcrun swiftc -O -swift-version 6 -target "$(uname -m)-apple-macosx$target_macos" \
    -module-cache-path "$probe_dir/module-cache" \
    -I Sources/CFFmpeg -I "$ffmpeg_prefix/include" -I "$bitpack/include" \
    -L "$ffmpeg_lib" -Xlinker -rpath -Xlinker "$ffmpeg_lib" \
    "$core"/{ColorAttachments,DecodedFrame,DecoderBackend,FFmpegBackend,FFmpegError,FrameCache,NALUnits,PackedNV12Frame,ReorderQueue,SoftwareFrameConverter,TimelineClickMotion,TimelineProjection,VTBackend}.swift \
    scripts/bench/hls-vod/main.swift "$probe_dir/Bitpack.o" -o "$probe_dir/probe"

if [[ $# -eq 0 ]]; then
    python3 scripts/bench/hls-vod/smoke.py "$probe_dir/probe"
else
    "$probe_dir/probe" "$@"
fi
