#!/usr/bin/env bash
# Builds build/FrameScrub.app (release, for scripts/deps.arch: arm64 on main, x86_64 on lts/macos26). FFmpeg is
# FrameScrub's own, linked in statically (scripts/build-deps.sh): the app needs no Homebrew.
# Usage: scripts/make-app.sh [--install]   (--install copies the app to ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/deps-env.sh
swift build -c release --triple "$DEPS_TRIPLE"
app=build/FrameScrub.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin=$app/Contents/MacOS/FrameScrub
built=$(swift build -c release --triple "$DEPS_TRIPLE" --show-bin-path)/FrameScrub
cp "$built" "$bin"
# The symbols go to build/FrameScrub.dSYM, for symbolicating crash reports, not into the app (~6 MB less).
rm -rf build/FrameScrub.dSYM
dsymutil "$built" -o build/FrameScrub.dSYM >/dev/null 2>&1 || echo "warning: no build/FrameScrub.dSYM (dsymutil failed)" >&2
strip "$bin"
[[ $(lipo -archs "$bin") == "$DEPS_ARCH" ]] || { echo "error: FrameScrub is $(lipo -archs "$bin"), not $DEPS_ARCH" >&2; exit 1; }
# The app must run on a Mac without Homebrew: the binary links system libraries only.
outside=$(otool -L "$bin" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//' | grep -vE '^(/usr/lib/|/System/)' || true)
[[ -z "$outside" ]] || { echo "error: FrameScrub links outside the system:"$'\n'"$outside" >&2; exit 1; }
cp Resources/Info.plist "$app/Contents/Info.plist"
# App icon: the Icon Composer package is compiled by actool into Assets.car (Liquid Glass icon, CFBundleIconName)
# plus AppIcon.icns (CFBundleIconFile, for older readers). actool ships with Xcode, not with the Command Line
# Tools; without it the prerendered Resources/AppIcon.icns (scripts/make-icns.sh) is used.
if xcrun --find actool >/dev/null 2>&1; then
    icon_tmp=$(mktemp -d)
    # Absolute paths: actool runs in a long-lived helper that resolves relative paths against its own directory.
    xcrun actool "$PWD/Resources/Icons/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" --platform macosx \
        --minimum-deployment-target 15.0 --app-icon AppIcon \
        --output-partial-info-plist "$icon_tmp/partial.plist" >"$icon_tmp/actool.log" 2>&1 \
        || { cat "$icon_tmp/actool.log" >&2; echo "error: actool failed to compile the app icon" >&2; exit 1; }
    for f in Assets.car AppIcon.icns; do
        [[ -f "$app/Contents/Resources/$f" ]] || { echo "error: actool did not produce $f" >&2; exit 1; }
    done
    # The `app-icon` alternates: only their .icns is kept, as Contents/Resources/AppIcons/<name>.icns, which the app
    # sets as its Dock icon while it runs (the bundle's icon stays the horse in Finder).
    mkdir -p "$app/Contents/Resources/AppIcons"
    for package in Resources/Icons/Alternates/*.icon; do
        [[ -e "$package" ]] || continue
        name=$(basename "$package" .icon)
        mkdir -p "$icon_tmp/$name"
        xcrun actool "$PWD/$package" --compile "$icon_tmp/$name" --platform macosx \
            --minimum-deployment-target 15.0 --app-icon "$name" \
            --output-partial-info-plist "$icon_tmp/$name.plist" >"$icon_tmp/actool.log" 2>&1 \
            || { cat "$icon_tmp/actool.log" >&2; echo "error: actool failed to compile $package" >&2; exit 1; }
        [[ -f "$icon_tmp/$name/$name.icns" ]] || { echo "error: actool did not produce $name.icns" >&2; exit 1; }
        cp "$icon_tmp/$name/$name.icns" "$app/Contents/Resources/AppIcons/"
    done
    rm -rf "$icon_tmp"
else
    echo "warning: actool not found (needs Xcode); using the prerendered Resources/AppIcon.icns (no app-icon alternates)" >&2
    cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi
# Document icons per video format, one picture per size.
cp Resources/DocumentIcons/*.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "Built $app"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/FrameScrub.app"
    cp -R "$app" "$HOME/Applications/"
    echo "Installed to ~/Applications/FrameScrub.app"
fi
