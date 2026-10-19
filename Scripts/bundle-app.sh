#!/usr/bin/env bash
#
# bundle-app.sh — build WillyDisk and assemble a launchable .app bundle.
#
# Usage:   bash Scripts/bundle-app.sh            # release bundle
#          CONFIGURATION=debug bash Scripts/bundle-app.sh
# Output:  .build/WillyDisk.app  (launch with: open .build/WillyDisk.app)
#
# Inside an agent sandbox, where SwiftPM cannot nest its own sandbox:
#          WILLYDISK_NO_SANDBOX=1 bash Scripts/bundle-app.sh
#
# The bundle contains Contents/MacOS/WillyDisk, the original app icon, and an
# Info.plist carrying LSMinimumSystemVersion 14.0, CFBundleIdentifier, and
# NSHighResolutionCapable.
set -euo pipefail

# Resolve the repository root (the directory containing Package.swift).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="WillyDisk"
BIN_PATH="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME"
APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME.app"
ICON_SRC="$ROOT_DIR/Resources/AppIcon.icns"

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

echo "Building $APP_NAME ($CONFIGURATION)…"
BUILD_FLAGS=()
if [[ -n "${WILLYDISK_NO_SANDBOX:-}" ]]; then
    BUILD_FLAGS=(--disable-sandbox)
fi
swift build -c "$CONFIGURATION" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "${LINK_SDK_FLAGS[@]}"

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

cp "$BIN_PATH" "$STAGED_BIN"
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"

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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>WillyDisk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 WillyDisk.</string>
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
echo "Launch with: open \"$APP_BUNDLE\""
