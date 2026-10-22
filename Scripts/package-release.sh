#!/usr/bin/env bash
#
# package-release.sh — assemble the GitHub release assets from the built bundle.
#
# Usage:   bash Scripts/package-release.sh
# Output:  .build/release/WillyDisk-<VERSION>-arm64.zip
#          .build/release/WillyDisk-<VERSION>-arm64.zip.sha256
#          .build/release/WillyDisk-<VERSION>-x86_64.zip
#          .build/release/WillyDisk-<VERSION>-x86_64.zip.sha256
#
# WILLYDISK_ARCHS overrides the architectures to build (default: arm64 x86_64).
#
# Inside an agent sandbox, where SwiftPM cannot nest its own sandbox:
#          WILLYDISK_NO_SANDBOX=1 bash Scripts/package-release.sh
#
# The artifacts are unsigned and not notarized. `bundle-app.sh` ad-hoc signs each
# bundle only so macOS will run it on Apple Silicon; there is no Developer ID
# certificate. This script packages each slice with ditto, expands the archive
# again to check what a downloader receives, and writes the SHA-256s the release
# page publishes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: VERSION must be one to three period-separated numbers, not '$APP_VERSION'." >&2
    exit 1
fi

ARCHS="${WILLYDISK_ARCHS:-arm64 x86_64}"
for ARCH in $ARCHS; do
    case "$ARCH" in
        arm64|x86_64) ;;
        *)
            echo "error: WILLYDISK_ARCHS entries must be arm64 or x86_64, not '$ARCH'." >&2
            exit 1
            ;;
    esac
done

OUT_DIR="$ROOT_DIR/.build/release"
STAGE_ROOT="$ROOT_DIR/.build/release-stage"
HOST_ARCH="$(uname -m)"
VERIFY_DIR=""

cleanup() {
    if [ -n "$VERIFY_DIR" ]; then
        rm -rf "$VERIFY_DIR"
    fi
    rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"

for ARCH in $ARCHS; do
    echo
    echo "=== $ARCH ==="

    APP_BUNDLE="$ROOT_DIR/.build/WillyDisk-$ARCH.app"
    WILLYDISK_ARCH="$ARCH" bash "$SCRIPT_DIR/bundle-app.sh"

    if [ ! -d "$APP_BUNDLE" ]; then
        echo "error: the $ARCH bundle is missing at $APP_BUNDLE." >&2
        exit 1
    fi

    # The bundle carries the version from VERSION; a mismatch would label the
    # archive as something it is not.
    BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw \
        "$APP_BUNDLE/Contents/Info.plist")"
    if [ "$BUNDLE_VERSION" != "$APP_VERSION" ]; then
        echo "error: the $ARCH bundle reports $BUNDLE_VERSION but VERSION says $APP_VERSION." >&2
        exit 1
    fi

    # Stage the bundle under the name the archive should expand to; the
    # architecture belongs in the download's name, not in the .app's.
    STAGE_DIR="$STAGE_ROOT/$ARCH"
    mkdir -p "$STAGE_DIR"
    mv "$APP_BUNDLE" "$STAGE_DIR/WillyDisk.app"

    ZIP_NAME="WillyDisk-$APP_VERSION-$ARCH.zip"
    ZIP="$OUT_DIR/$ZIP_NAME"
    rm -f "$ZIP" "$ZIP.sha256"

    # ditto, not zip: a plain zip can drop the extended attributes and resource
    # forks the code signature seals over, and the expanded app would then fail
    # verification.
    ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/WillyDisk.app" "$ZIP"

    # Verify what a downloader receives, not just what is on disk: expand the
    # archive and check the architecture, the version, and the ad-hoc signature.
    VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/willydisk-release.XXXXXX")"
    ditto -x -k "$ZIP" "$VERIFY_DIR"

    EXPANDED="$VERIFY_DIR/WillyDisk.app"
    if [ ! -d "$EXPANDED" ]; then
        echo "error: the $ARCH archive does not expand to WillyDisk.app." >&2
        exit 1
    fi
    EXPANDED_VERSION="$(plutil -extract CFBundleShortVersionString raw \
        "$EXPANDED/Contents/Info.plist")"
    if [ "$EXPANDED_VERSION" != "$APP_VERSION" ]; then
        echo "error: the $ARCH archive reports $EXPANDED_VERSION but VERSION says $APP_VERSION." >&2
        exit 1
    fi
    PACKAGED_ARCHS="$(lipo -archs "$EXPANDED/Contents/MacOS/WillyDisk")"
    if [ "$PACKAGED_ARCHS" != "$ARCH" ]; then
        echo "error: the $ARCH archive contains '$PACKAGED_ARCHS'." >&2
        exit 1
    fi
    if ! codesign --verify --strict "$EXPANDED" 2>/dev/null; then
        echo "error: the $ARCH archive lost the bundle's ad-hoc signature; package it with ditto." >&2
        exit 1
    fi

    # The same executable serves the command line, and that path runs before
    # SwiftUI exists. Only the host's own slice can be executed here; a
    # cross-built slice is checked by lipo and codesign above.
    if [ "$ARCH" = "$HOST_ARCH" ]; then
        if ! "$EXPANDED/Contents/MacOS/WillyDisk" scan --help >/dev/null 2>&1; then
            echo "error: the packaged $ARCH binary does not run." >&2
            exit 1
        fi
    else
        echo "Skipping the run check: this host is $HOST_ARCH."
    fi

    ( cd "$OUT_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" )
    rm -rf "$VERIFY_DIR"
    VERIFY_DIR=""

    echo "Packaged $ZIP"
done

echo
echo "Release assets in $OUT_DIR:"
for ARCH in $ARCHS; do
    DIGEST="$(awk '{print $1}' "$OUT_DIR/WillyDisk-$APP_VERSION-$ARCH.zip.sha256")"
    echo "  WillyDisk-$APP_VERSION-$ARCH.zip  $DIGEST"
done
echo "These builds are unsigned and not notarized; do not describe them as signed or verified."
