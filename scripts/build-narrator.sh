#!/bin/bash
# Build the narrator helper (#57): Narrator/.build/release/unread-narrator,
# with mlx's Metal library beside it.
#
# Needs Xcode, not just the Command Line Tools: mlx-swift declares Swift tools
# 6.3, and Unread's own toolchain is 6.2. Unread itself keeps scripts/build.sh.
#
# mlx's Metal kernels normally compile with Xcode's Metal Toolchain, a separate
# download. Instead this takes the prebuilt mlx.metallib from PyPI's mlx-metal
# wheel for the mlx version mlx-swift 0.33.0 embeds (0.32.4), checked against
# its sha256 and cached in ~/Library/Caches/Unread. No Python needed.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${NARRATOR_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "error: no Xcode at $DEVELOPER_DIR (set NARRATOR_DEVELOPER_DIR)" >&2
    exit 1
fi

(cd Narrator && swift build -c release --build-system native "$@")

WHEEL_URL="https://files.pythonhosted.org/packages/54/8c/9754dd6c4db485037f59cc8be6495738e14cdeb8bf19d5bddb5e96da890f/mlx_metal-0.32.4-py3-none-macosx_15_0_arm64.whl"
WHEEL_SHA256="9f0a3cc26d89724434d9684932fc6f3e4e83669d2a895d858ed2c8a55eb84e8b"
CACHE="$HOME/Library/Caches/Unread/narrator"
WHEEL="$CACHE/$(basename "$WHEEL_URL")"

if ! echo "$WHEEL_SHA256  $WHEEL" | shasum -a 256 -c --status 2>/dev/null; then
    mkdir -p "$CACHE"
    echo "Fetching $(basename "$WHEEL_URL")"
    curl -fsSL --retry 3 -o "$WHEEL.part" "$WHEEL_URL"
    if ! echo "$WHEEL_SHA256  $WHEEL.part" | shasum -a 256 -c --status; then
        rm -f "$WHEEL.part"
        echo "error: $(basename "$WHEEL_URL") doesn't match its sha256" >&2
        exit 1
    fi
    mv "$WHEEL.part" "$WHEEL"
fi

OUT="Narrator/.build/release"
if ! unzip -p "$WHEEL" mlx/lib/mlx.metallib | cmp -s - "$OUT/mlx.metallib"; then
    unzip -p "$WHEEL" mlx/lib/mlx.metallib > "$OUT/mlx.metallib.part"
    mv "$OUT/mlx.metallib.part" "$OUT/mlx.metallib"
fi
echo "Built $OUT/unread-narrator (+ mlx.metallib)"
