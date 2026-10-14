#!/usr/bin/env bash
#
# Render WillyDisk's screens offscreen to PNGs.
#
# The real views are driven by a real scan of a generated fixture tree, so a UI
# change can be reviewed from the files this writes. No window is opened and no
# Screen Recording permission is needed, which is what makes it usable in a
# locked session and inside an agent sandbox.
#
# Usage:
#   Scripts/render-screens.sh [-o OUT_DIR] [-s WxH] [-a light|dark|both] [-S results|home|both] [-t FIXTURE_DIR]
#
#   -o  output directory                     (default .build/renders)
#   -s  render size in points                (default 1088x816)
#   -a  appearances to render                (default both)
#   -S  screens to render                    (default results)
#   -t  scan this directory instead of the generated fixture
#   -c  capture the screen alone, with no window around it (default: the window)
#
# Inside an agent sandbox, where SwiftPM cannot nest its own sandbox, run it as:
#   WILLYDISK_NO_SANDBOX=1 Scripts/render-screens.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/renders"
SIZE="1088x816"
APPEARANCE="both"
SCREEN="results"
FIXTURE=()
MODE=(--window)

while getopts "o:s:a:S:t:ch" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    s) SIZE="$OPTARG" ;;
    a) APPEARANCE="$OPTARG" ;;
    S) SCREEN="$OPTARG" ;;
    t) FIXTURE=(--fixture "$OPTARG") ;;
    c) MODE=(--content) ;;
    h) sed -n '2,21p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

BUILD_FLAGS=()
SWIFTC_FLAGS=()
if [[ -n "${WILLYDISK_NO_SANDBOX:-}" ]]; then
  BUILD_FLAGS=(--disable-sandbox)
  # A sandboxed agent cannot write the shared module cache, so it gets one
  # inside the build directory; everyone else uses the system cache.
  SWIFTC_FLAGS=(-disable-sandbox -module-cache-path "$ROOT/.build/render-module-cache")
fi

echo "==> Building"
swift build --package-path "$ROOT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}

echo "==> Compiling the renderer"
xcrun swiftc ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} \
  -I "$ROOT/.build/debug" -L "$ROOT/.build/debug" -lDiskUI -lDiskCore \
  -o "$ROOT/.build/render-screens" \
  "$ROOT/Scripts/RenderScreens/main.swift"

echo "==> Rendering"
"$ROOT/.build/render-screens" --out "$OUT" --size "$SIZE" --appearance "$APPEARANCE" --screen "$SCREEN" "${MODE[@]}" ${FIXTURE[@]+"${FIXTURE[@]}"}
