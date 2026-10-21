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
#   Scripts/render-screens.sh [-o OUT_DIR] [-s WxH] [-a light|dark|both] [-S results|home|help|categories|cleanup|both] [-t FIXTURE_DIR] [-T STATE]
#
#   -o  output directory                     (default .build/renders)
#   -s  render size in points                (default 1000x720)
#   -a  appearances to render                (default both)
#   -S  screens to render                    (default results; both is home and
#       results; help, categories, and cleanup are the sheet contents, and
#       cleanup scans its own sample tree)
#   -t  scan this directory instead of the generated fixture
#   -T  finished (default), scanning, or stopped — the screen a cancelled scan
#       leaves behind. scanning and stopped both need a directory large enough
#       that the scan is still running, or has gathered something, when the frame
#       is taken
#   -c  capture the screen alone, with no window around it (default: the window)
#
# Inside an agent sandbox, where SwiftPM cannot nest its own sandbox, the build is
# retried with --disable-sandbox automatically. Set WILLYDISK_NO_SANDBOX=1 to skip
# the first attempt.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/renders"
SIZE="1000x720"
APPEARANCE="both"
SCREEN="results"
STATE="finished"
FIXTURE=()
MODE=(--window)

while getopts "o:s:a:S:t:T:ch" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    s) SIZE="$OPTARG" ;;
    a) APPEARANCE="$OPTARG" ;;
    S) SCREEN="$OPTARG" ;;
    t) FIXTURE=(--fixture "$OPTARG") ;;
    T) STATE="$OPTARG" ;;
    c) MODE=(--content) ;;
    h) sed -n '2,24p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

BUILD_FLAGS=()
SWIFTC_FLAGS=()

# A sandboxed agent cannot nest SwiftPM's own sandbox and cannot write the shared
# module cache, so it gets a cache inside the build directory instead.
use_sandboxless_flags() {
  BUILD_FLAGS=(--disable-sandbox)
  SWIFTC_FLAGS=(-disable-sandbox -module-cache-path "$ROOT/.build/render-module-cache")
}

if [[ -n "${WILLYDISK_NO_SANDBOX:-}" ]]; then
  use_sandboxless_flags
fi

echo "==> Building"
if ! build_output=$(swift build --package-path "$ROOT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} 2>&1); then
  printf '%s\n' "$build_output"
  if [[ -z "${WILLYDISK_NO_SANDBOX:-}" && "$build_output" == *sandbox_apply* ]]; then
    echo "==> SwiftPM cannot nest its own sandbox here; retrying with --disable-sandbox"
    use_sandboxless_flags
    swift build --package-path "$ROOT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
  else
    exit 1
  fi
fi

# The renderer goes in the build directory beside `WillyDisk_DiskUI.bundle`, so
# the UI's `Bundle.module` resolves its resources exactly as it does in the app.
echo "==> Compiling the renderer"
xcrun swiftc ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} \
  -I "$ROOT/.build/debug" -L "$ROOT/.build/debug" -lDiskUI -lDiskCore \
  -o "$ROOT/.build/debug/render-screens" \
  "$ROOT/Scripts/RenderScreens/main.swift"

echo "==> Rendering"
"$ROOT/.build/debug/render-screens" --out "$OUT" --size "$SIZE" --appearance "$APPEARANCE" --screen "$SCREEN" --state "$STATE" "${MODE[@]}" ${FIXTURE[@]+"${FIXTURE[@]}"}
