#!/usr/bin/env bash
# Builds FrameScrub's own FFmpeg for the lts/macos26 line (LTS_POLICY.md): FFmpeg and dav1d, x86_64, static, into
# .deps/x86_64 (or $FRAMESCRUB_DEPS). Homebrew builds no Intel bottles any more, so the Intel app links its decoders in
# and needs no Homebrew at run time. Decoders, demuxers and muxers only: FrameScrub encodes nothing, its clips are
# stream copies. Runs on an Intel Mac and on Apple Silicon (a cross build). A finished build is kept: delete the
# directory, or change a version below, to build again.
# Needs: brew install nasm meson ninja pkgconf
set -euo pipefail
cd "$(dirname "$0")/.."
ffmpeg_version=9.0.2
dav1d_version=1.5.4
min=26.0
prefix=${FRAMESCRUB_DEPS:-$PWD/.deps/x86_64}
stamp="ffmpeg $ffmpeg_version, dav1d $dav1d_version, macOS $min"
if [[ -f "$prefix/.stamp" && $(<"$prefix/.stamp") == "$stamp" ]]; then
    echo "FFmpeg ($stamp) already in $prefix"
    exit 0
fi
rm -rf "$prefix"
src=$prefix/src
mkdir -p "$src"
jobs=$(sysctl -n hw.ncpu)
# Only this prefix: Homebrew's arm64 libraries must not leak into the x86_64 link.
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
unset PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET=$min

git -c advice.detachedHead=false clone -q --depth 1 -b "$dav1d_version" https://github.com/videolan/dav1d "$src/dav1d"
git -c advice.detachedHead=false clone -q --depth 1 -b "n$ffmpeg_version" https://github.com/FFmpeg/FFmpeg "$src/ffmpeg"

# A cross file even on an Intel Mac: Meson otherwise takes the CPU from its (possibly arm64) Python.
cat >"$src/x86_64.meson" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
nasm = 'nasm'

[built-in options]
c_args = ['-mmacosx-version-min=$min']
c_link_args = ['-mmacosx-version-min=$min']

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
meson setup "$src/dav1d/build" "$src/dav1d" --cross-file "$src/x86_64.meson" --prefix "$prefix" --libdir lib \
    --buildtype release --default-library static -Denable_tools=false -Denable_tests=false >/dev/null
ninja -C "$src/dav1d/build" install >/dev/null

(
    cd "$src/ffmpeg"
    ./configure --prefix="$prefix" --arch=x86_64 --target-os=darwin --enable-cross-compile --cc="clang -arch x86_64" \
        --extra-cflags="-mmacosx-version-min=$min" --extra-ldflags="-mmacosx-version-min=$min" \
        --pkg-config=pkg-config --pkg-config-flags=--static --enable-static --disable-shared \
        --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
        --enable-libdav1d --disable-programs --disable-doc --disable-avdevice --disable-avfilter --disable-network \
        --disable-encoders >/dev/null
    make -j"$jobs" >/dev/null
    make install >/dev/null
)

# SwiftPM reads only `Libs`: each .pc gets its whole static link line there (pkg-config --static), keeping the flags
# SwiftPM allows (-L, -l, -framework).
pcdir=$prefix/lib/pkgconfig
for pc in "$pcdir"/*.pc; do
    name=$(basename "$pc" .pc)
    libs=$(pkg-config --static --libs "$name" | tr ' ' '\n' | awk '
        framework { print "-framework " $0; framework = 0; next }
        $0 == "-framework" { framework = 1; next }
        /^-[lL]/ { print }' | awk '!seen[$0]++' | tr '\n' ' ')
    awk -v libs="$libs" '/^Libs:/ { print "Libs: " libs; next } /^(Libs|Requires)\.private:/ { next } { print }' \
        "$pc" >"$pc.flat"
done
for pc in "$pcdir"/*.pc; do mv "$pc.flat" "$pc"; done

lipo -archs "$prefix/lib/libavcodec.a" | grep -qx x86_64 \
    || { echo "error: libavcodec.a is not x86_64 only: $(lipo -archs "$prefix/lib/libavcodec.a")" >&2; exit 1; }
rm -rf "$src"
echo "$stamp" >"$prefix/.stamp"
echo "FFmpeg ($stamp) installed in $prefix"
