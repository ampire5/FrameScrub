#!/usr/bin/env bash
# Renders the Icon Composer package Resources/Icons/AppIcon.icon (Default appearance) and packs it into
# Resources/AppIcon.icns: the fallback icon make-app.sh uses when actool (Xcode) is not available.
set -euo pipefail
cd "$(dirname "$0")/.."
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || { echo "error: ictool not found (needs Xcode with Icon Composer)" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set=$work/AppIcon.iconset
mkdir -p "$set"
for s in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((s * scale)); suffix=$([[ $scale == 2 ]] && echo "@2x" || true)
        "$ictool" Resources/Icons/AppIcon.icon --export-image --output-file "$set/icon_${s}x${s}${suffix}.png" \
            --platform macOS --rendition Default --width $px --height $px --scale 1 >/dev/null
    done
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
