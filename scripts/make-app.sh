#!/usr/bin/env bash
# Packages FrameScrub for $DEPS_ARCH (the Mac's architecture unless set, scripts/deps-env.sh).
# FFmpeg is FrameScrub's own, linked in statically (scripts/build-deps.sh): the app needs no Homebrew.
# Usage: scripts/make-app.sh [--preview | --release | --install]
set -euo pipefail
mode=${1:---preview}
if [[ $# -gt 1 || ( "$mode" != --preview && "$mode" != --release && "$mode" != --install ) ]]; then
    echo "Usage: $0 [--preview | --release | --install]" >&2
    exit 2
fi
cd "$(dirname "$0")/.."
. scripts/deps-env.sh
swift build -c release --triple "$DEPS_TRIPLE"
name=FrameScrub
if [[ "$mode" == --preview ]]; then
    name="FrameScrub Preview"
fi
app="$PWD/build/$name.app"
if [[ "$mode" == --install ]]; then
    install_dir="$HOME/Applications"
    mkdir -p "$install_dir"
    stage=$(mktemp -d "$install_dir/.framescrub-install.XXXXXX")
    trap 'if [[ ! -e "$stage/previous" && ! -L "$stage/previous" ]]; then rm -rf "$stage"; fi' EXIT
    app="$stage/FrameScrub.app"
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin=$app/Contents/MacOS/FrameScrub
built=$(swift build -c release --triple "$DEPS_TRIPLE" --show-bin-path)/FrameScrub
cp "$built" "$bin"
# Include Core's prepared grain banks; never rely on the developer's build directory.
cp -R "$(dirname "$built")/FrameScrub_FrameScrubCore.bundle" "$app/Contents/Resources/"
# Keep debug symbols next to the bundle for symbolicating crash reports.
symbols="build/$name.dSYM"
mkdir -p build
rm -rf "$symbols"
dsymutil "$built" -o "$symbols" >/dev/null 2>&1 || echo "warning: no $symbols (dsymutil failed)" >&2
strip "$bin"
[[ $(lipo -archs "$bin") == "$DEPS_ARCH" ]] || { echo "error: FrameScrub is $(lipo -archs "$bin"), not $DEPS_ARCH" >&2; exit 1; }
# The app must run on a Mac without Homebrew: the binary links system libraries only.
outside=$(otool -L "$bin" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//' | grep -vE '^(/usr/lib/|/System/)' || true)
[[ -z "$outside" ]] || { echo "error: FrameScrub links outside the system:"$'\n'"$outside" >&2; exit 1; }
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ "$mode" == --preview ]]; then
    plist="$app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string local.framescrub.preview "$plist"
    plutil -replace CFBundleName -string "$name" "$plist"
    plutil -replace CFBundleDisplayName -string "$name" "$plist"
    plutil -remove CFBundleURLTypes "$plist"
    plutil -remove CFBundleDocumentTypes "$plist"
fi
# Which build this is (About FrameScrub, Settings › General; BuildInfo): the commit, its branch and date, whether the
# tree had uncommitted changes, and when it was built.
bake() { plutil -insert "$1" -string "$2" "$app/Contents/Info.plist"; }
bake FSBuildHash "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
bake FSBuildBranch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
bake FSBuildCommitDate "$(git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || true)"
bake FSBuildDirty "$([[ -n $(git status --porcelain 2>/dev/null) ]] && echo 1 || echo 0)"
bake FSBuildDate "$(date '+%Y-%m-%d %H:%M')"
# App icon: the Icon Composer package is compiled by actool into Assets.car (Liquid Glass icon, CFBundleIconName)
# plus AppIcon.icns (CFBundleIconFile, for older readers). actool ships with Xcode, not with the Command Line
# Tools; without it the prerendered Resources/AppIcon.icns (scripts/make-icns.sh) is used.
if xcrun --find actool >/dev/null 2>&1; then
    icon_tmp=$(mktemp -d)
    # Absolute paths: actool runs in a long-lived helper that resolves relative paths against its own directory.
    xcrun actool "$PWD/Resources/Icons/AppIcon.icon" --compile "$app/Contents/Resources" --platform macosx \
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
# Third-party shader adaptation notices travel with standalone app bundles.
mkdir -p "$app/Contents/Resources/Licenses/libplacebo"
cp third_party/libplacebo/LICENSE third_party/libplacebo/SOURCE "$app/Contents/Resources/Licenses/libplacebo/"
# Signed with the local identity "Local Code Signing" (login keychain) when present: the designated requirement is then
# the bundle ID and the certificate, the same for every build, so TCC grants (network volumes, Accessibility) survive
# rebuilds; ad hoc it is the build's own hash, and every new build must be allowed again.
if security find-identity -p codesigning | grep -q '"Local Code Signing"'; then
    codesign --force --sign "Local Code Signing" "$app"
else
    echo "warning: no \"Local Code Signing\" identity: signed ad hoc, TCC grants must be given again" >&2
    codesign --force --sign - "$app"
fi
if [[ "$mode" == --install ]]; then
    installed="$install_dir/FrameScrub.app"
    if [[ -e "$installed" || -L "$installed" ]]; then
        mv "$installed" "$stage/previous"
    fi
    if ! mv "$app" "$installed"; then
        if [[ -e "$stage/previous" || -L "$stage/previous" ]]; then
            mv "$stage/previous" "$installed" || echo "Previous installation is at $stage/previous" >&2
        fi
        exit 1
    fi
    rm -rf "$stage/previous"
    echo "Installed to $installed"
    swift scripts/set-url-handler.swift "$installed"
else
    echo "Built $app"
fi
