#!/bin/bash
# Prepares the optional RobustVideoMatting models for Subject Focus (FrameScrub and Loupe), see docs/subject-focus-rvm.md.
# Nothing here is part of the build: the apps work without the models (Vision's masks), and pick them up when present.
#
#   scripts/rvm/prepare-models.sh [dest]
#
# Needs uv (brew install uv) and ~3 GB of disk for a throwaway Python environment (PyTorch, coremltools) in a temp dir.
# Pinned: the RVM source commit and the weights' SHA-256, so the models are always the same.
set -euo pipefail
dest=${1:-"$HOME/Library/Application Support/RobustVideoMatting"}
here=$(cd "$(dirname "$0")" && pwd)
commit=53d74c6826735f01f4406b5ca9075eee27bec094
weights_sha=3c7c1d92033f7c38d6577c481d13a195d7d80a159b960f4f3119ac7b534cf4f8
work=$(mktemp -d -t rvm-export)
trap 'rm -rf "$work"' EXIT

command -v uv >/dev/null || { echo "error: uv not found (brew install uv)" >&2; exit 1; }
echo "RVM source at $commit"
git -C "$work" init -q src
git -C "$work/src" fetch -q --depth 1 https://github.com/PeterL1n/RobustVideoMatting.git "$commit"
git -C "$work/src" checkout -q FETCH_HEAD
mkdir -p "$work/weights"
curl -sSL -o "$work/weights/rvm_mobilenetv3.pth" \
    https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3.pth
echo "$weights_sha  $work/weights/rvm_mobilenetv3.pth" | shasum -a 256 -c - >/dev/null \
    || { echo "error: the weights' checksum does not match" >&2; exit 1; }
cp "$here/export.py" "$work/"
uv venv -q -p 3.12 "$work/.venv"
uv pip install -q -p "$work/.venv/bin/python" torch==2.7.0 torchvision==0.22.0 coremltools==8.3 numpy

mkdir -p "$dest"
# Playback (landscape, portrait) and the still frame on pause (finer), MobileNetV3: measured on M4 Max 3.5 / 7 ms a frame
# on the neural engine; ResNet50 was no steadier and 2–5× slower (docs/subject-focus-rvm.md).
for size in 512x288 288x512 768x432 432x768; do
    w=${size%x*}; h=${size#*x}
    (cd "$work" && .venv/bin/python export.py mobilenetv3 "$w" "$h" 1 "$work/rvm_mnv3_$size.mlpackage" 2>&1 | grep -E "^saved|Error")
    rm -rf "$dest/rvm_mnv3_$size.mlpackage"
    mv "$work/rvm_mnv3_$size.mlpackage" "$dest/"
done
# Photos (Loupe): the frame at 1536×1024 (portrait 1024×1536), the network at half of it, RVM's own refiner back to full
# size; ~22 ms a pass, 5 passes a photo. Cleaner than without the refiner at full size (a wall taken for a person) and
# than ResNet50 (a blanket kept, a lamp in the hand lost) on the test shoot.
for size in 1536x1024 1024x1536; do
    w=${size%x*}; h=${size#*x}
    (cd "$work" && .venv/bin/python export.py mobilenetv3 "$w" "$h" 0.5 "$work/rvm_mnv3_${size}_ds0.5.mlpackage" 2>&1 | grep -E "^saved|Error")
    rm -rf "$dest/rvm_mnv3_${size}_ds0.5.mlpackage"
    mv "$work/rvm_mnv3_${size}_ds0.5.mlpackage" "$dest/"
done
echo "Models in $dest"
