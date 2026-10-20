#!/usr/bin/env bash
# Prints FrameScrub's launch and open timeline for one video.
# Usage: scripts/measure-startup.sh <video> [seconds to run, default 5]
# Each run is killed, so it leaves no resume position or thumbnail behind. A file read once is in the system's
# cache: a cold measurement needs a file not opened since the last restart of the network share.
set -euo pipefail
cd "$(dirname "$0")/.."
video=$1
wait=${2:-5}
swift build -c release >/dev/null
bin="$(swift build -c release --show-bin-path)/FrameScrub"
# The first launch of a new binary waits 0.3–0.6 s for the system's code check: keep that out of the timeline.
env -u FRAMESCRUB_STARTUP_TRACE "$bin" /nonexistent-framescrub-warmup.mp4 >/dev/null 2>&1 &
pid=$!
sleep 2
kill -9 "$pid" 2>/dev/null || true
log=$(mktemp)
FRAMESCRUB_STARTUP_TRACE=1 "$bin" "$video" 2>"$log" &
pid=$!
sleep "$wait"
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
grep '^\[startup\]' "$log" || true
rm -f "$log"
