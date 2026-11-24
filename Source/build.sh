#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${1:-$SCRIPT_DIR/../Shinchan Monitor.app}"
BUILD_DIR="$(mktemp -d /tmp/shinchan-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
xcrun clang -O2 -target arm64-apple-macos13.0 -c "$SCRIPT_DIR/NativeSensors.c" -o "$BUILD_DIR/NativeSensors.o"
xcrun clang -O2 -target arm64-apple-macos13.0 -c "$SCRIPT_DIR/OfflineSecurity.c" -o "$BUILD_DIR/OfflineSecurity.o"
cp "$SCRIPT_DIR/ShinchanMonitor.swift" "$BUILD_DIR/main.swift"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "${SHINCHAN_MODULE_CACHE:-$BUILD_DIR/module-cache}" \
  -lsandbox -framework AppKit -framework IOKit -framework Metal -framework ServiceManagement -framework UserNotifications \
  -import-objc-header "$SCRIPT_DIR/NativeSensors.h" "$BUILD_DIR/NativeSensors.o" "$BUILD_DIR/OfflineSecurity.o" \
  "$BUILD_DIR/main.swift" "$SCRIPT_DIR/AlertEngine.swift" "$SCRIPT_DIR/AlertUI.swift" -o "$APP_DIR/Contents/MacOS/ShinchanMonitor"
cp "$SCRIPT_DIR/Assets/spritesheet.png" "$APP_DIR/Contents/Resources/spritesheet.png"
cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/ShinchanMonitor"
codesign --force --sign - "$APP_DIR"
echo "Built: $APP_DIR"
