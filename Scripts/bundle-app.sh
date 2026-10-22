#!/usr/bin/env bash
#
# bundle-app.sh — build WillyDisk and assemble a launchable .app bundle.
#
# Usage:   bash Scripts/bundle-app.sh            # release bundle
#          CONFIGURATION=debug bash Scripts/bundle-app.sh
#          WILLYDISK_ARCH=x86_64 bash Scripts/bundle-app.sh
# Output:  .build/WillyDisk.app  (launch with: open .build/WillyDisk.app)
#
# WILLYDISK_ARCH cross-builds one slice and writes .build/WillyDisk-<arch>.app
# under its own scratch path, so the release pipeline can assemble both an
# arm64 and an x86_64 archive without the products overwriting each other.
#
# Inside an agent sandbox, where SwiftPM cannot nest its own sandbox:
#          WILLYDISK_NO_SANDBOX=1 bash Scripts/bundle-app.sh
#
# The bundle contains Contents/MacOS/WillyDisk, the rounded app icon the Finder
# draws, the UI resource bundle that carries the circular in-app mark, and an
# Info.plist carrying LSMinimumSystemVersion 14.0, CFBundleIdentifier,
# NSHighResolutionCapable, and the version read from the repository's VERSION file.
set -euo pipefail

# Resolve the repository root (the directory containing Package.swift).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="WillyDisk"
REQUESTED_ARCH="${WILLYDISK_ARCH:-}"
ARCH="${REQUESTED_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "error: WILLYDISK_ARCH must be arm64 or x86_64, not '$ARCH'." >&2
        exit 1
        ;;
esac
APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME.app"
if [ -n "$REQUESTED_ARCH" ]; then
    APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME-$ARCH.app"
fi
BIN_PATH="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME"
ICON_SRC="$ROOT_DIR/Resources/AppIcon.icns"
UI_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/WillyDisk_DiskUI.bundle"

# The marketing version has one source: the repository's VERSION file. Nothing
# else may state a version, so About, the bundle and a future DMG cannot drift
# apart. CFBundleVersion is the build counter, taken from the commit count so
# successive builds order chronologically.
VERSION_FILE="$ROOT_DIR/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "error: missing version source at $VERSION_FILE" >&2
    exit 1
fi
APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: VERSION must be one to three period-separated numbers, not '$APP_VERSION'." >&2
    exit 1
fi
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER="1"
fi

# Minimum supported OS — must match `platforms: [.macOS(.v14)]` in Package.swift.
DEPLOYMENT_TARGET="14.0"

# ---------------------------------------------------------------------------
# Window chrome / Liquid Glass: record the real linked SDK.
#
# macOS 26+ (Tahoe and later) gates the *window chrome* — traffic-light style,
# titlebar/toolbar layout, window corner radius, and the automatic "modern"
# rendering of standard controls — on a "linked-on-or-after" check against the
# `sdk` field of the executable's LC_BUILD_VERSION load command.
#
# SwiftPM stamps that field with the *deployment target* (14.0) rather than the
# SDK it actually linked against. A binary carrying `sdk 14.0` is therefore
# treated as a pre-Tahoe app and AppKit draws the legacy window: old traffic
# lights, and a centered title/toolbar that does not line up with the buttons.
#
# Two independent guards keep the shipped bundle on the modern chrome:
#   1. link with an explicit `-platform_version` so `minos` stays at the
#      deployment target while `sdk` records the real SDK, and
#   2. restamp the staged binary with `vtool` after copying, which does not
#      depend on linker-flag ordering.
# The stamp is then verified and the build fails loudly if it is wrong.
# ---------------------------------------------------------------------------
SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || true)"
LINK_SDK_FLAGS=()
if [ -n "$SDK_VERSION" ]; then
    LINK_SDK_FLAGS=(-Xlinker -platform_version -Xlinker macos
                    -Xlinker "$DEPLOYMENT_TARGET" -Xlinker "$SDK_VERSION")
fi

echo "Building $APP_NAME $APP_VERSION ($BUILD_NUMBER, $CONFIGURATION, $ARCH)…"
BUILD_FLAGS=()
if [[ -n "${WILLYDISK_NO_SANDBOX:-}" ]]; then
    BUILD_FLAGS=(--disable-sandbox)
fi
ARCH_FLAGS=()
if [ -n "$REQUESTED_ARCH" ]; then
    ARCH_FLAGS=(--scratch-path "$ROOT_DIR/.build/bundle-$ARCH"
                --triple "$ARCH-apple-macosx$DEPLOYMENT_TARGET")
fi
swift build -c "$CONFIGURATION" \
    ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} \
    ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} \
    "${LINK_SDK_FLAGS[@]}"
if [ -n "$REQUESTED_ARCH" ]; then
    BIN_DIR="$(swift build -c "$CONFIGURATION" \
        ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} \
        --show-bin-path 2>/dev/null | tail -1)"
    BIN_PATH="$BIN_DIR/$APP_NAME"
    UI_BUNDLE="$BIN_DIR/WillyDisk_DiskUI.bundle"
fi

CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
STAGED_BIN="$MACOS_DIR/$APP_NAME"

echo "Assembling $APP_BUNDLE …"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ ! -f "$ICON_SRC" ]; then
    echo "error: missing app icon at $ICON_SRC" >&2
    exit 1
fi
if [ ! -d "$UI_BUNDLE" ]; then
    echo "error: missing UI resource bundle at $UI_BUNDLE (run swift build first)" >&2
    exit 1
fi

cp "$BIN_PATH" "$STAGED_BIN"
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
# The in-app mark lives in DiskUI's resource bundle; copying it here is what lets
# the hero, Help, and About resolve it from `Bundle.main`'s resource path.
cp -R "$UI_BUNDLE" "$RESOURCES_DIR/"
if [ ! -f "$RESOURCES_DIR/WillyDisk_DiskUI.bundle/Contents/Resources/AppMark.png" ]; then
    echo "error: the UI resource bundle does not carry AppMark.png" >&2
    exit 1
fi

# Guard 2: restamp after staging and before signing. vtool warns that rewriting
# the Mach-O invalidates the (ad-hoc) signature; that is expected — we re-sign
# the bundle below and verify the stamp immediately after.
if [ -n "$SDK_VERSION" ]; then
    xcrun vtool -set-build-version macos "$DEPLOYMENT_TARGET" "$SDK_VERSION" \
        -replace -output "$STAGED_BIN" "$STAGED_BIN" 2>/dev/null
fi

# Verify the binary advertises the SDK it was actually built against, not the
# deployment target; otherwise macOS 26+ renders the legacy window chrome.
BUILT_SDK="$(xcrun vtool -show-build "$STAGED_BIN" 2>/dev/null | awk '/ sdk /{print $2; exit}')"
echo "Linked SDK stamp: minos $DEPLOYMENT_TARGET / sdk ${BUILT_SDK:-unknown}"
if [ -z "$SDK_VERSION" ]; then
    echo "warning: could not determine the macOS SDK version; window chrome may" >&2
    echo "         fall back to the legacy (pre-Tahoe) appearance." >&2
elif [ "$BUILT_SDK" != "$SDK_VERSION" ]; then
    echo "error: expected LC_BUILD_VERSION sdk $SDK_VERSION but the binary reports '${BUILT_SDK:-unknown}'." >&2
    echo "       macOS would fall back to the legacy window chrome (old traffic lights)." >&2
    exit 1
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WillyDisk</string>
    <key>CFBundleDisplayName</key>
    <string>WillyDisk</string>
    <key>CFBundleIdentifier</key>
    <string>com.willydisk.app</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>WillyDisk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Wael Abdrabbo.</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so local Gatekeeper does not reject the bundle. Signing must come
# after the SDK restamp above, since mutating the Mach-O invalidates a signature.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "Done: $APP_BUNDLE"
if [ "$ARCH" != "$(uname -m)" ]; then
    echo "Built for $ARCH; run it on a $ARCH Mac (this host is $(uname -m))."
else
    echo "Launch with: open \"$APP_BUNDLE\""
fi
