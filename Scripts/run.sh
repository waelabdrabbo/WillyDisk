#!/usr/bin/env bash
#
# run.sh — build and launch WillyDisk with the *correct* window chrome.
#
# Usage:   bash Scripts/run.sh                 # debug build (default)
#          CONFIGURATION=release bash Scripts/run.sh
#
# Why not `swift run WillyDisk`? SwiftPM stamps the executable's
# LC_BUILD_VERSION `sdk` field with the deployment target (macOS 14) rather than
# the SDK it linked against. On macOS 26+ that makes AppKit draw the *legacy*
# pre-Tahoe window chrome — old traffic-light style and a centered title/toolbar
# that does not line up with the buttons. The bundle path restamps the SDK
# (see Scripts/bundle-app.sh), so launching through this script gives the modern
# macOS 26+/27 window. Use it instead of `swift run` when you want to eyeball the
# real chrome.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIGURATION="${CONFIGURATION:-debug}" bash "$SCRIPT_DIR/bundle-app.sh"

open "$ROOT_DIR/.build/WillyDisk.app"
