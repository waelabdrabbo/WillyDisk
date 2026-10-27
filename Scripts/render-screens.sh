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
#   Scripts/render-screens.sh [-o OUT_DIR] [-s WxH] [-a light|dark|both] [-S results|home|search|help|settings|update|update-ready|categories|coverage|cleanup|duplicates|moved|reclaim|history|both] [-t FIXTURE_DIR] [-T STATE] [-l LOCALE]
#
#   -o  output directory                     (default .build/renders)
#   -s  render size in points                (default 1000x720)
#   -a  appearances to render                (default both)
#   -l  interface language: en, ar, or en-XA (default en)
#   -S  screens to render                    (default results; both is home and
#       results; search is the results screen with a whole-scan search open;
#       categories is the results screen in Categories mode; coverage is the
#       coverage sheet; help and settings are the sheet and preferences contents;
#       update and update-ready are the software-update sheet and its ready
#       state; cleanup, duplicates, and moved are
#       the cleanup sheet's tabs, and they
#       scan the same sample tree; reclaim is that sheet with its move
#       confirmation over it; history is the scan-history comparison over three
#       sample runs)
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
LOCALE="en"
STATE="finished"
FIXTURE=()
MODE=(--window)

while getopts "o:s:a:S:t:T:l:ch" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    s) SIZE="$OPTARG" ;;
    a) APPEARANCE="$OPTARG" ;;
    S) SCREEN="$OPTARG" ;;
    t) FIXTURE=(--fixture "$OPTARG") ;;
    T) STATE="$OPTARG" ;;
    l) LOCALE="$OPTARG" ;;
    c) MODE=(--content) ;;
    h) sed -n '2,28p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

BUILD_FLAGS=()

# A sandboxed agent cannot nest SwiftPM's own sandbox.
use_sandboxless_flags() {
  BUILD_FLAGS=(--disable-sandbox)
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

# The renderer is the package's `render-screens` product. SwiftPM builds it in
# the same directory as the UI's resource bundle, so its `Bundle.module` resolves
# exactly as it does in the app, and it links the package itself — the older
# build system keeps no library archives a hand-written `swiftc` could link.
echo "==> Building the renderer"
swift build --package-path "$ROOT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --product render-screens

bin_path="$(swift build --package-path "$ROOT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)"
if [[ -z "$bin_path" || ! -x "$bin_path/render-screens" ]]; then
  echo "error: SwiftPM did not produce $bin_path/render-screens" >&2
  exit 1
fi

echo "==> Rendering"
"$bin_path/render-screens" --out "$OUT" --size "$SIZE" --appearance "$APPEARANCE" --screen "$SCREEN" --state "$STATE" --locale "$LOCALE" "${MODE[@]}" ${FIXTURE[@]+"${FIXTURE[@]}"}
